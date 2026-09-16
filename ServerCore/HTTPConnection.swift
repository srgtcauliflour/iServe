import Foundation
import Network

/// Owns exactly one accepted `NWConnection`: reads bounded chunks, feeds them to
/// an `HTTPRequestParser`, dispatches a completed request through the shared
/// `HTTPRouter`, writes one response, then closes.
///
/// v0.1 does not support keep-alive or pipelining: every connection serves at most
/// one response before being cancelled. That keeps this first transport
/// implementation's lifecycle simple and trivially bounded; a later issue can add
/// persistent connections behind an ADR if the product needs them.
actor HTTPConnection {
    nonisolated let id = UUID()

    private let connection: NWConnection
    private let router: any HTTPRouter
    private let limits: HTTPServerLimits
    private let requestLog: RequestLog?
    private let onClose: @Sendable (UUID) -> Void

    private var parser: HTTPRequestParser
    private var idleTimeoutTask: Task<Void, Never>?
    private var lifetimeTimeoutTask: Task<Void, Never>?
    private var streamingFile: FileChunkReader?
    private var uploadState: UploadState?
    private var didClose = false
    private var didRespond = false

    /// Everything `HTTPConnection` tracks while streaming a POST upload's
    /// body straight to disk (v0.2). One struct rather than several loose
    /// optionals so `close()`/failure paths can't forget to clean up part
    /// of it.
    private struct UploadState {
        let request: HTTPRequest
        let directoryPath: String
        var parser: MultipartFormDataParser
        let contentLength: Int
        var bytesConsumed = 0
        var currentFileWriter: FileChunkWriter?
        var currentFileURL: URL?
        var uploadedFileNames: [String] = []
    }

    init(
        connection: NWConnection,
        router: any HTTPRouter,
        limits: HTTPServerLimits,
        requestLog: RequestLog? = nil,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.limits = limits
        self.requestLog = requestLog
        self.onClose = onClose
        self.parser = HTTPRequestParser(limits: limits.parserLimits)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleState(state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        scheduleLifetimeTimeout()
        scheduleIdleTimeout()
        receiveMore()
    }

    /// Cancels the connection and any pending timeouts. Safe to call more than
    /// once; only the first call has any effect.
    func close() {
        guard !didClose else { return }
        didClose = true
        idleTimeoutTask?.cancel()
        lifetimeTimeoutTask?.cancel()
        idleTimeoutTask = nil
        lifetimeTimeoutTask = nil
        streamingFile?.close()
        streamingFile = nil
        discardIncompleteUpload()
        connection.cancel()
        onClose(id)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            close()
        default:
            break
        }
    }

    private func receiveMore() {
        guard !didClose, !didRespond else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: limits.readChunkSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, didError: error != nil) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, didError: Bool) {
        guard !didClose, !didRespond else { return }
        if didError {
            close()
            return
        }
        if let data, !data.isEmpty {
            resetIdleTimeout()
            if uploadState != nil {
                processUploadBytes(data)
                guard !didRespond, !didClose else { return }
            } else {
                do {
                    if let request = try parser.feed(data) {
                        let leftover = parser.drainRemainder()
                        respond(to: request, leftoverBodyBytes: leftover)
                        guard !didRespond, !didClose else { return }
                    }
                } catch {
                    respond(withParseError: error)
                    return
                }
            }
        }
        if isComplete {
            close()
            return
        }
        receiveMore()
    }

    private func respond(to request: HTTPRequest, leftoverBodyBytes: Data) {
        switch request.method {
        case "GET", "HEAD":
            respond(with: router.route(request), suppressBody: request.method == "HEAD", request: request)
        case "POST":
            beginUpload(for: request, leftoverBodyBytes: leftoverBodyBytes)
        default:
            respond(with: .notImplemented(method: request.method), request: request)
        }
    }

    private func respond(withParseError error: Error) {
        guard let parseError = error as? HTTPRequestParser.ParseError else {
            respond(with: .badRequest())
            return
        }
        switch parseError {
        case .requestLineTooLong:
            respond(with: .uriTooLong())
        case .headerLineTooLong, .tooManyHeaders, .headerSectionTooLarge:
            respond(with: .requestHeaderFieldsTooLarge())
        case .malformedRequestLine, .malformedHeaderLine, .unsupportedVersion:
            respond(with: .badRequest())
        }
    }

    private func respond(with response: HTTPResponse, suppressBody: Bool = false, request: HTTPRequest? = nil) {
        guard !didClose, !didRespond else { return }
        didRespond = true
        // The idle-read timeout only guards the request-reading phase; once a
        // response begins, backpressure on the send (and the connection-lifetime
        // cap) is what bounds things, so a slow-but-progressing file transfer
        // isn't cut short by a timer meant for a client that stalls mid-request.
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil

        if let request, let requestLog {
            let bytes = suppressBody ? 0 : Self.declaredBodyLength(response.body)
            Task {
                await requestLog.record(method: request.method, path: request.target, status: response.status, bytes: bytes)
            }
        }

        let head = response.headEncoded()
        switch response.body {
        case .empty:
            sendFinal(head)
        case .data(let data):
            var payload = head
            if !suppressBody { payload.append(data) }
            sendFinal(payload)
        case .file(let file):
            guard !suppressBody else {
                sendFinal(head)
                return
            }
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    Task { await self.close() }
                    return
                }
                Task { await self.beginStreaming(file) }
            })
        }
    }

    private func sendFinal(_ payload: Data) {
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { await self.close() }
        })
    }

    private func beginStreaming(_ file: HTTPFileBody) {
        guard !didClose else { return }
        guard let reader = FileChunkReader(url: file.url, chunkSize: limits.writeChunkSize) else {
            close()
            return
        }
        streamingFile = reader
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard !didClose, let reader = streamingFile else { return }
        let chunk: Data?
        do {
            chunk = try reader.nextChunk()
        } catch {
            finishStreaming()
            return
        }
        guard let chunk else {
            finishStreaming()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { await self.sendNextChunk() }
        })
    }

    private func finishStreaming() {
        streamingFile?.close()
        streamingFile = nil
        close()
    }

    // MARK: - Uploads

    /// Called once headers are parsed for a POST. Authorizes the whole
    /// request up front — target is a directory, `Content-Type` names a
    /// multipart boundary, `Content-Length` is present and within
    /// `limits.maxUploadBytes`, and `router.authorizeUpload` accepts the
    /// directory — before reading a single body byte. Anything short of
    /// that responds immediately and never touches the body at all;
    /// v0.1 has no keep-alive to preserve, so there's no need to drain and
    /// discard bytes the client is still sending.
    private func beginUpload(for request: HTTPRequest, leftoverBodyBytes: Data) {
        guard let path = Self.pathIgnoringQuery(request.target), path.hasSuffix("/") else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let contentType = request.headers["Content-Type"],
              let boundary = Self.multipartBoundary(from: contentType) else {
            respond(with: .badRequest("Expected multipart/form-data"), request: request)
            return
        }
        guard let contentLengthText = request.headers["Content-Length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            respond(with: .lengthRequired(), request: request)
            return
        }
        guard contentLength <= limits.maxUploadBytes else {
            respond(with: .payloadTooLarge(), request: request)
            return
        }
        guard router.authorizeUpload(directoryPath: path) else {
            respond(with: .notFound(), request: request)
            return
        }

        uploadState = UploadState(
            request: request,
            directoryPath: path,
            parser: MultipartFormDataParser(boundary: boundary),
            contentLength: contentLength
        )
        guard !leftoverBodyBytes.isEmpty else { return }
        processUploadBytes(leftoverBodyBytes)
    }

    /// Feeds newly received bytes into the active upload's multipart
    /// parser, bounded to at most this upload's declared `Content-Length`
    /// regardless of how much more the client actually sends.
    private func processUploadBytes(_ data: Data) {
        guard var state = uploadState else { return }

        let remainingAllowed = max(0, state.contentLength - state.bytesConsumed)
        let consuming = Data(data.prefix(remainingAllowed))
        state.bytesConsumed += consuming.count

        let events: [MultipartFormDataParser.Event]
        do {
            events = try state.parser.feed(consuming)
        } catch {
            uploadState = state
            failUpload()
            return
        }
        uploadState = state

        for event in events {
            handle(uploadEvent: event)
            guard uploadState != nil else { return } // a prior event already finished/failed the request
        }

        if let current = uploadState, current.bytesConsumed >= current.contentLength {
            // Every declared body byte has arrived but the parser never
            // reported .finished - a truncated or malformed body.
            failUpload()
        }
    }

    private func handle(uploadEvent event: MultipartFormDataParser.Event) {
        guard var state = uploadState else { return }
        switch event {
        case .partBegan(_, let filename):
            guard let filename, !filename.isEmpty,
                  let fileURL = router.authorizeUploadedFile(directoryPath: state.directoryPath, filename: filename),
                  let writer = FileChunkWriter(url: fileURL, maxBytes: limits.maxUploadBytes) else {
                state.currentFileWriter = nil
                state.currentFileURL = nil
                uploadState = state
                return
            }
            state.currentFileWriter = writer
            state.currentFileURL = fileURL
            uploadState = state

        case .partBodyChunk(let chunk):
            guard let writer = state.currentFileWriter else { return }
            do {
                try writer.write(chunk)
            } catch {
                writer.close()
                if let url = state.currentFileURL { try? FileManager.default.removeItem(at: url) }
                state.currentFileWriter = nil
                state.currentFileURL = nil
                uploadState = state
                failUpload()
            }

        case .partEnded:
            if let writer = state.currentFileWriter, let url = state.currentFileURL {
                writer.close()
                state.uploadedFileNames.append(url.lastPathComponent)
            }
            state.currentFileWriter = nil
            state.currentFileURL = nil
            uploadState = state

        case .finished:
            uploadState = state
            finishUpload()
        }
    }

    private func finishUpload() {
        guard let state = uploadState else { return }
        uploadState = nil
        let response: HTTPResponse = state.uploadedFileNames.isEmpty
            ? .badRequest("No file was uploaded")
            : .redirect(to: state.directoryPath, status: 303, reason: "See Other")
        respond(with: response, request: state.request)
    }

    private func failUpload() {
        guard let state = uploadState else { return }
        discardIncompleteUpload()
        respond(with: .badRequest("Upload failed"), request: state.request)
    }

    /// Closes and deletes whatever file the active upload was mid-write on,
    /// then clears upload state entirely. Already-completed files from
    /// earlier parts in the same request are left in place — a failure is
    /// reported for the request as a whole, but doesn't retroactively
    /// undo parts that had already finished successfully.
    private func discardIncompleteUpload() {
        guard let state = uploadState else { return }
        state.currentFileWriter?.close()
        if let url = state.currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        uploadState = nil
    }

    private static func pathIgnoringQuery(_ target: String) -> String? {
        guard !target.isEmpty else { return nil }
        guard let queryIndex = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<queryIndex])
    }

    private static func multipartBoundary(from contentType: String) -> String? {
        let parts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let kind = parts.first, kind.caseInsensitiveCompare("multipart/form-data") == .orderedSame else {
            return nil
        }
        for parameter in parts.dropFirst() where parameter.lowercased().hasPrefix("boundary=") {
            var value = String(parameter.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func scheduleIdleTimeout() {
        idleTimeoutTask?.cancel()
        let timeout = limits.idleTimeout
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.close()
        }
    }

    private func resetIdleTimeout() {
        scheduleIdleTimeout()
    }

    private static func declaredBodyLength(_ body: HTTPResponseBody) -> Int {
        switch body {
        case .empty:
            return 0
        case .data(let data):
            return data.count
        case .file(let file):
            return file.length
        }
    }

    private func scheduleLifetimeTimeout() {
        let timeout = limits.maxConnectionLifetime
        lifetimeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.close()
        }
    }
}
