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
    /// `nil` means every request is let through unchecked — see
    /// `ServerCore/ServerCredentials.swift`.
    private let credentials: ServerCredentials?
    private let onClose: @Sendable (UUID) -> Void

    private var parser: HTTPRequestParser
    private var idleTimeoutTask: Task<Void, Never>?
    private var lifetimeTimeoutTask: Task<Void, Never>?
    private var streamingFile: FileChunkReader?
    private var uploadState: UploadState?
    private var zipDownloadState: ZipDownloadState?
    /// A ZIP built for the *current* response, in the app's own temporary
    /// directory rather than the served root. Set just before responding
    /// with it, deleted in `close()` — the one place every termination
    /// path (a clean finish, a client disconnect mid-stream, a timeout)
    /// already funnels through — so it's cleaned up exactly once no matter
    /// how the connection ends.
    private var pendingZipCleanupURL: URL?
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

    /// Everything tracked while accumulating a "download selected as ZIP"
    /// POST body (v0.3) — just a small list of selected names, so unlike
    /// `UploadState` this only ever buffers in memory, bounded by
    /// `limits.maxZipSelectionBytes`.
    private struct ZipDownloadState {
        let request: HTTPRequest
        let directoryPath: String
        let contentLength: Int
        var buffer = Data()
    }

    init(
        connection: NWConnection,
        router: any HTTPRouter,
        limits: HTTPServerLimits,
        requestLog: RequestLog? = nil,
        credentials: ServerCredentials? = nil,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.limits = limits
        self.requestLog = requestLog
        self.credentials = credentials
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
        zipDownloadState = nil
        if let pendingZipCleanupURL {
            try? FileManager.default.removeItem(at: pendingZipCleanupURL)
            self.pendingZipCleanupURL = nil
        }
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
            } else if zipDownloadState != nil {
                processZipDownloadBytes(data)
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

    /// `docs/SECURITY.md`'s mandatory pipeline: authenticate before
    /// authorizing a capability, so this runs before the method switch —
    /// GET/HEAD never reach `router.route(_:)`, and POST never reaches
    /// `beginUpload`/`beginZipDownload`, without the right credentials.
    /// Nothing about the request has been authorized yet at this point, so
    /// no body byte has been read either way.
    private func respond(to request: HTTPRequest, leftoverBodyBytes: Data) {
        if let credentials, !Self.isAuthorized(request, credentials: credentials) {
            respond(with: .unauthorized(), request: request)
            return
        }
        switch request.method {
        case "GET", "HEAD":
            respond(with: router.route(request), suppressBody: request.method == "HEAD", request: request)
        case "POST":
            if Self.isFormURLEncoded(request.headers["Content-Type"]) {
                beginZipDownload(for: request, leftoverBodyBytes: leftoverBodyBytes)
            } else {
                beginUpload(for: request, leftoverBodyBytes: leftoverBodyBytes)
            }
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
        guard let reader = FileChunkReader(url: file.url, offset: file.offset, length: file.length, chunkSize: limits.writeChunkSize) else {
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

    // MARK: - ZIP downloads

    /// Called once headers are parsed for a POST whose `Content-Type` is
    /// `application/x-www-form-urlencoded` — a directory listing's
    /// "Download Selected" form (`Handlers/DirectoryListingRenderer.swift`).
    /// Authorized the same way an upload is: target is a directory,
    /// `Content-Length` is present and within `limits.maxZipSelectionBytes`
    /// (this body is just a list of names, never file content, so the cap
    /// is small), and `router.authorizeZipDownload` accepts the directory —
    /// all before reading a single body byte.
    private func beginZipDownload(for request: HTTPRequest, leftoverBodyBytes: Data) {
        guard let path = Self.pathIgnoringQuery(request.target), path.hasSuffix("/") else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let contentLengthText = request.headers["Content-Length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            respond(with: .lengthRequired(), request: request)
            return
        }
        guard contentLength > 0 else {
            respond(with: .badRequest("No items selected"), request: request)
            return
        }
        guard contentLength <= limits.maxZipSelectionBytes else {
            respond(with: .payloadTooLarge(), request: request)
            return
        }
        guard router.authorizeZipDownload(directoryPath: path) else {
            respond(with: .notFound(), request: request)
            return
        }

        zipDownloadState = ZipDownloadState(request: request, directoryPath: path, contentLength: contentLength)
        guard !leftoverBodyBytes.isEmpty else { return }
        processZipDownloadBytes(leftoverBodyBytes)
    }

    /// Buffers newly received bytes for the active selection body, bounded
    /// to at most its declared `Content-Length` regardless of how much more
    /// the client actually sends — the same discipline as upload bytes,
    /// just accumulated in memory since this body is always small.
    private func processZipDownloadBytes(_ data: Data) {
        guard var state = zipDownloadState else { return }
        let remainingAllowed = max(0, state.contentLength - state.buffer.count)
        state.buffer.append(data.prefix(remainingAllowed))
        zipDownloadState = state
        if state.buffer.count >= state.contentLength {
            finishZipDownloadBody()
        }
    }

    private func finishZipDownloadBody() {
        guard let state = zipDownloadState else { return }
        zipDownloadState = nil
        let names = Self.parseSelectedNames(from: state.buffer)
        guard !names.isEmpty else {
            respond(with: .badRequest("No items selected"), request: state.request)
            return
        }
        guard names.count <= limits.maxZipEntryCount else {
            respond(with: .payloadTooLarge(), request: state.request)
            return
        }
        guard let urls = router.resolveZipEntries(directoryPath: state.directoryPath, names: names) else {
            respond(with: .notFound(), request: state.request)
            return
        }
        Task { await self.buildAndStreamZip(urls, directoryPath: state.directoryPath, request: state.request) }
    }

    /// Builds the archive in the app's own temporary directory — never
    /// inside the served root, since it isn't part of what the user chose
    /// to share — then responds with it as a `.file` body exactly like any
    /// other download. `close()` deletes the temp file once this response
    /// (successful or not) is fully done with it.
    private func buildAndStreamZip(_ urls: [URL], directoryPath: String, request: HTTPRequest) async {
        guard !didClose, !didRespond else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iserve-download-\(UUID().uuidString).zip")
        do {
            try ArchiveManager.createArchive(
                containing: urls, at: tempURL, maxUncompressedBytes: limits.maxZipUncompressedBytes
            )
        } catch ArchiveManager.ArchiveError.selectionTooLarge {
            try? FileManager.default.removeItem(at: tempURL)
            respond(with: .payloadTooLarge(), request: request)
            return
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            respond(with: .badRequest("Could not create the archive"), request: request)
            return
        }
        guard !didClose, !didRespond else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let size = attributes[.size] as? Int else {
            try? FileManager.default.removeItem(at: tempURL)
            respond(with: .internalServerError(), request: request)
            return
        }
        pendingZipCleanupURL = tempURL
        respond(with: .attachment(url: tempURL, length: size, filename: Self.zipFilename(for: directoryPath)), request: request)
    }

    /// Derives a human-readable download filename from the directory's
    /// request path — "/Photos/" -> "Photos.zip", root "/" -> "Download.zip".
    private static func zipFilename(for directoryPath: String) -> String {
        let trimmed = directoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? ""
        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        return (decoded.isEmpty ? "Download" : decoded) + ".zip"
    }

    /// Parses an `application/x-www-form-urlencoded` body for every
    /// `select=<name>` pair, form-urldecoding each value. Anything else in
    /// the body (a different field, a malformed pair) is ignored rather
    /// than rejecting the whole request.
    private static func parseSelectedNames(from data: Data) -> [String] {
        guard let bodyString = String(data: data, encoding: .utf8) else { return [] }
        var names: [String] = []
        for pair in bodyString.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "select", let decoded = formURLDecode(String(parts[1])) else {
                continue
            }
            names.append(decoded)
        }
        return names
    }

    private static func formURLDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func isFormURLEncoded(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let base = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return base.caseInsensitiveCompare("application/x-www-form-urlencoded") == .orderedSame
    }

    // MARK: - Authentication (v0.3, optional HTTP Basic Auth)

    /// `credentials` is password-only (`ServerCore/ServerCredentials.swift`):
    /// a client's Basic header still names a username, but it's decoded and
    /// discarded rather than checked.
    private static func isAuthorized(_ request: HTTPRequest, credentials: ServerCredentials) -> Bool {
        guard let header = request.headers["Authorization"], header.hasPrefix("Basic ") else {
            return false
        }
        let encoded = header.dropFirst("Basic ".count)
        guard let data = Data(base64Encoded: String(encoded)),
              let decoded = String(data: data, encoding: .utf8) else {
            return false
        }
        let suppliedPassword: String
        if let colonIndex = decoded.firstIndex(of: ":") {
            suppliedPassword = String(decoded[decoded.index(after: colonIndex)...])
        } else {
            suppliedPassword = decoded
        }
        return constantTimeEquals(suppliedPassword, credentials.password)
    }

    /// A byte-for-byte comparison that always examines every byte of the
    /// longer operand, rather than returning as soon as a mismatch is
    /// found the way an ordinary `==` does — otherwise a sufficiently
    /// patient remote attacker could recover the password one byte at a
    /// time from response timing.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var mismatch: UInt8 = lhsBytes.count == rhsBytes.count ? 0 : 1
        for index in 0..<max(lhsBytes.count, rhsBytes.count) {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            mismatch |= left ^ right
        }
        return mismatch == 0
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
