import Foundation
import Network

/// Conservative, independently tunable bounds for every listener/connection this
/// server core creates. See `docs/SECURITY.md`: request/header limits and timeouts
/// are mandatory, and receive/send buffering must never be unbounded.
struct HTTPServerLimits: Sendable {
    var maxConcurrentConnections: Int
    var idleTimeout: TimeInterval
    var maxConnectionLifetime: TimeInterval
    var readChunkSize: Int
    /// Bound on each chunk read from a static file and handed to the network
    /// send; keeps memory use roughly constant regardless of file size.
    var writeChunkSize: Int
    /// Upper bound on one POST upload's total body size (checked against
    /// `Content-Length` before any body bytes are read, and re-enforced
    /// while writing in case that header understated the truth) — guards
    /// against the storage exhaustion `docs/SECURITY.md` calls out as a
    /// threat to test.
    var maxUploadBytes: Int
    /// Upper bound on a "download selected as ZIP" POST body — just a list
    /// of selected names from a directory listing's form, never file
    /// content, so this is a small control-plane cap (like a header limit),
    /// not a transfer-size limit.
    var maxZipSelectionBytes: Int
    /// Upper bound on how many items one ZIP-download request may select —
    /// bounds how much directory-walking/compression work a single request
    /// can trigger, independent of any one item's size.
    var maxZipEntryCount: Int
    /// Upper bound on the total *uncompressed* bytes a generated ZIP may
    /// contain — checked while walking the selection (`Transfer/ArchiveManager.swift`),
    /// so an oversized request is rejected without finishing (or fully
    /// paying for) the compression work.
    var maxZipUncompressedBytes: Int
    var parserLimits: HTTPRequestParser.Limits

    static let `default` = HTTPServerLimits(
        maxConcurrentConnections: 32,
        idleTimeout: 15,
        // Generous enough for a real file transfer to finish: the idle timeout
        // (reset on every read, cancelled once a response begins) is what
        // guards the request-reading phase, not this. This only bounds a
        // connection that never makes progress at all.
        maxConnectionLifetime: 600,
        readChunkSize: 8 * 1024,
        writeChunkSize: 64 * 1024,
        maxUploadBytes: 4 * 1024 * 1024 * 1024,
        maxZipSelectionBytes: 32 * 1024,
        maxZipEntryCount: 500,
        maxZipUncompressedBytes: 4 * 1024 * 1024 * 1024,
        parserLimits: .default
    )
}

/// Owns the `NWListener` lifecycle and every accepted `HTTPConnection`.
///
/// `start()`/`stop()` are deterministic and repeatable: `stop()` always cancels the
/// listener and awaits every live connection's cancellation before returning, so a
/// subsequent `start()` begins from a clean, empty state. A connection beyond
/// `limits.maxConcurrentConnections` is cancelled immediately rather than queued,
/// so accepted-connection memory stays bounded regardless of load.
actor HTTPServer {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    enum ServerError: Error, Sendable, Equatable {
        case alreadyRunning
        case listenerFailed(String)
    }

    private(set) var state: State = .idle
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    private let router: any HTTPRouter
    private let limits: HTTPServerLimits
    private let requestLog: RequestLog?
    /// `nil` (the default) means every request is let through unchecked —
    /// see `ServerCore/ServerCredentials.swift`.
    private let credentials: ServerCredentials?

    init(
        router: any HTTPRouter = NotFoundRouter(),
        limits: HTTPServerLimits = .default,
        requestLog: RequestLog? = nil,
        credentials: ServerCredentials? = nil
    ) {
        self.router = router
        self.limits = limits
        self.requestLog = requestLog
        self.credentials = credentials
    }

    /// Starts listening on `port` (default: any available port, the normal case
    /// for a server session) and returns the bound port once the listener is ready.
    func start(port: NWEndpoint.Port = .any) async throws -> UInt16 {
        guard listener == nil else { throw ServerError.alreadyRunning }
        state = .starting

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: port)
        } catch {
            state = .failed("listener could not be created")
            throw ServerError.listenerFailed("listener could not be created")
        }
        listener = newListener

        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                Task { await self.accept(connection) }
            }
            newListener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                Task { await self.handleListenerState(newState) }
            }
            newListener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Cancels the listener and awaits every live connection's cancellation before
    /// returning. Safe to call repeatedly, including before the first `start()`.
    func stop() async {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            await connection.close()
        }
        connections.removeAll()
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: ServerError.listenerFailed("stopped before ready"))
        }
        state = .idle
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < limits.maxConcurrentConnections else {
            connection.cancel()
            return
        }
        let httpConnection = HTTPConnection(
            connection: connection,
            router: router,
            limits: limits,
            requestLog: requestLog,
            credentials: credentials
        ) { [weak self] id in
            guard let self else { return }
            Task { await self.remove(id) }
        }
        connections[httpConnection.id] = httpConnection
        Task { await httpConnection.start() }
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            guard let startContinuation else { return }
            self.startContinuation = nil
            let port = listener?.port?.rawValue ?? 0
            state = .running(port: port)
            startContinuation.resume(returning: port)
        case .failed(let error):
            let message = String(describing: error)
            state = .failed(message)
            if let startContinuation {
                self.startContinuation = nil
                startContinuation.resume(throwing: ServerError.listenerFailed(message))
            }
            listener?.cancel()
            listener = nil
        case .cancelled:
            listener = nil
            if state != .idle { state = .idle }
        default:
            break
        }
    }
}
