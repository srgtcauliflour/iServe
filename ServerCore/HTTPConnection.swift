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
    private let onClose: @Sendable (UUID) -> Void

    private var parser: HTTPRequestParser
    private var idleTimeoutTask: Task<Void, Never>?
    private var lifetimeTimeoutTask: Task<Void, Never>?
    private var didClose = false
    private var didRespond = false

    init(
        connection: NWConnection,
        router: any HTTPRouter,
        limits: HTTPServerLimits,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.limits = limits
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
                respond(with: .badRequest())
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
            respond(with: router.route(request), suppressBody: request.method == "HEAD")
        default:
            respond(with: .notImplemented(method: request.method))
        }
    }

    private func respond(with response: HTTPResponse, suppressBody: Bool = false) {
        guard !didClose, !didRespond else { return }
        didRespond = true
        var payload = response.headEncoded()
        if !suppressBody {
            payload.append(response.body)
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { await self.close() }
        })
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

    private func scheduleLifetimeTimeout() {
        let timeout = limits.maxConnectionLifetime
        lifetimeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.close()
        }
    }
}
