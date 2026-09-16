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
    private var didClose = false
    private var didRespond = false

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
            do {
                if let request = try parser.feed(data) {
                    respond(to: request)
                    return
                }
            } catch {
                respond(withParseError: error)
                return
            }
        }
        if isComplete {
            close()
            return
        }
        receiveMore()
    }

    private func respond(to request: HTTPRequest) {
        switch request.method {
        case "GET", "HEAD":
            respond(with: router.route(request), suppressBody: request.method == "HEAD", request: request)
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
