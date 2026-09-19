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
    /// Upper bound on one WebDAV `PUT`'s total body size (v0.3,
    /// `docs/adr/0005-webdav-write-operations.md`) — checked and enforced
    /// exactly like `maxUploadBytes`, just kept as its own field since a
    /// `PUT` and a browser upload are authorized by different
    /// `ServerProfile` capabilities and could reasonably diverge later.
    var maxWebDAVPutBytes: Int
    /// Upper bound on a PHP-destined POST body (v0.4,
    /// `docs/adr/0009-php-runtime-feasibility.md`) — buffered whole into
    /// memory before being handed to the PHP executor (there is no
    /// streaming-to-disk step here the way an ordinary upload has), so
    /// this is deliberately far smaller than `maxUploadBytes`: sized for
    /// realistic form/JSON-API request bodies, and small enough to leave
    /// most of the PHP worker's own `memory_limit` free for the script
    /// itself rather than for just holding its own input. This also caps
    /// how large a `$_FILES` upload *through PHP* can be (v0.4's own
    /// deliverable) — a real, deliberate v0.4 scope limit: small uploads a
    /// script processes itself work fine, but a multi-hundred-MB file
    /// doesn't fit the whole-body-buffered-in-memory design here the way
    /// it does through the ordinary (streamed-to-disk) upload path.
    /// Revisiting that would mean teaching PHP's rfc1867 handling to read
    /// progressively from the connection rather than a single in-memory
    /// buffer — a larger change, not a tweak to this number. Not
    /// coincidentally close to PHP's own compiled-in `post_max_size=8M`
    /// default, which the bridge doesn't override.
    var maxPHPPostBodyBytes: Int
    /// Upper bound on the password-only login form's POST body (v0.3,
    /// `docs/adr/0008-password-only-cookie-login.md`) — just a password
    /// and a redirect path, never file content, so this is a small
    /// control-plane cap like `maxZipSelectionBytes`, not a transfer-size
    /// limit.
    var maxLoginBodyBytes: Int
    /// Upper bound on concurrent connections from a single remote address
    /// (v0.3, `docs/adr/0006-connection-and-rate-limits.md`) — independent
    /// of `maxConcurrentConnections`, so one client can never consume every
    /// connection slot and starve every other device on the same network.
    var maxConnectionsPerAddress: Int
    /// Upper bound on how many connections a single remote address may
    /// *open* within `addressRateWindow`, regardless of how quickly each
    /// finishes. Since v0.1 has no keep-alive (one connection serves
    /// exactly one request), this is also this server's per-address
    /// request-rate limit — see the ADR for why the two collapse into one.
    var maxConnectionsPerAddressPerWindow: Int
    var addressRateWindow: TimeInterval
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
        maxWebDAVPutBytes: 4 * 1024 * 1024 * 1024,
        maxPHPPostBodyBytes: 8 * 1024 * 1024,
        maxLoginBodyBytes: 4 * 1024,
        maxConnectionsPerAddress: 16,
        maxConnectionsPerAddressPerWindow: 120,
        addressRateWindow: 10,
        parserLimits: .default
    )
}

/// Owns the `NWListener` lifecycle and every accepted `HTTPConnection`.
///
/// `start()`/`stop()` are deterministic and repeatable: `stop()` always cancels the
/// listener, awaits its actual `.cancelled` state (not just the `cancel()` call
/// returning — the underlying socket tears down asynchronously) and every live
/// connection's cancellation, before returning, so a subsequent `start()` begins
/// from a clean, empty state with no lingering OS-level socket from the previous
/// listener. A connection beyond
/// `limits.maxConcurrentConnections`, or beyond one remote address's own
/// `maxConnectionsPerAddress`/`maxConnectionsPerAddressPerWindow` (v0.3,
/// `docs/adr/0006-connection-and-rate-limits.md`), is cancelled immediately
/// rather than queued, so accepted-connection memory stays bounded
/// regardless of load and no single client can starve every other one.
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
    /// Resumed once `listener` actually reaches `.cancelled` — see `stop()`.
    private var stopContinuation: CheckedContinuation<Void, Never>?
    /// Per-remote-address admission bookkeeping for
    /// `docs/adr/0006-connection-and-rate-limits.md`'s two additional
    /// limits — see `AddressConnectionTracker`. Keyed by
    /// `Self.remoteAddress(for:)`, never by port, so every socket from the
    /// same client collapses to one entry.
    private var addressTracker: AddressConnectionTracker

    private let router: any HTTPRouter
    private let limits: HTTPServerLimits
    private let requestLog: RequestLog?
    /// `nil` (the default) means every request is let through unchecked —
    /// see `ServerCore/ServerCredentials.swift`.
    private let credentials: ServerCredentials?
    /// Shared across every accepted `HTTPConnection` (v0.3, password-only
    /// cookie login — `docs/adr/0008-password-only-cookie-login.md`).
    /// Cleared on `stop()`, never persisted, same as `credentials` itself.
    private let sessionTokens = SessionTokenStore()

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
        self.addressTracker = AddressConnectionTracker(
            maxConnectionsPerAddress: limits.maxConnectionsPerAddress,
            maxConnectionsPerAddressPerWindow: limits.maxConnectionsPerAddressPerWindow,
            addressRateWindow: limits.addressRateWindow
        )
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

    /// Cancels the listener, awaits its actual `.cancelled` state (not just
    /// the `cancel()` call returning — `NWListener` tears down its
    /// underlying socket asynchronously), and awaits every live
    /// connection's cancellation before returning. Safe to call
    /// repeatedly, including before the first `start()`. Awaiting the real
    /// teardown, rather than firing `cancel()` and moving on, is what makes
    /// an immediate subsequent `start()` reliable: without it, a new
    /// listener can begin accepting connections while the OS is still
    /// releasing the previous one's socket, which is exactly the kind of
    /// gap that shows up as intermittent client-side connection failures
    /// in a rapid stop-then-start test.
    func stop() async {
        if let listener {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stopContinuation = continuation
                listener.cancel()
            }
        }
        for connection in connections.values {
            await connection.close()
        }
        connections.removeAll()
        addressTracker.removeAll()
        await sessionTokens.removeAll()
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: ServerError.listenerFailed("stopped before ready"))
        }
        state = .idle
    }

    /// Three independent caps, checked in order, before an `HTTPConnection`
    /// is ever `start()`ed or tracked in `connections`: the existing global
    /// `maxConcurrentConnections`, then (v0.3,
    /// `docs/adr/0006-connection-and-rate-limits.md`) a per-address
    /// concurrent cap and a per-address rolling-window rate limit via
    /// `addressTracker` — constructing the `HTTPConnection` itself first
    /// only to get its `id` for that check is side-effect-free, since
    /// `init` does no I/O and `start()` is what actually begins reading.
    /// Any rejection is silent — `connection.cancel()`, no response —
    /// consistent with how the global cap has always been enforced; only
    /// `requestLog` records that it happened.
    private func accept(_ connection: NWConnection) async {
        guard connections.count < limits.maxConcurrentConnections else {
            connection.cancel()
            await requestLog?.recordRejectedConnection()
            return
        }

        let httpConnection = HTTPConnection(
            connection: connection,
            router: router,
            limits: limits,
            requestLog: requestLog,
            credentials: credentials,
            sessionTokens: sessionTokens
        ) { [weak self] id in
            guard let self else { return }
            Task { await self.remove(id) }
        }

        let address = Self.remoteAddress(for: connection)
        if let address, !addressTracker.tryAdmit(id: httpConnection.id, address: address) {
            connection.cancel()
            await requestLog?.recordRejectedConnection()
            return
        }

        connections[httpConnection.id] = httpConnection
        Task { await httpConnection.start() }
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
        addressTracker.remove(id)
    }

    /// The remote peer's host, ignoring port, so every socket from the same
    /// client address collapses to one key. `nil` only for an endpoint
    /// shape an accepted inbound TCP connection should never actually have
    /// (`NWListener` always hands `accept(_:)` a `.hostPort` endpoint) —
    /// callers treat that as "skip per-address limiting," never as a reason
    /// to refuse the connection outright.
    private static func remoteAddress(for connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        return "\(host)"
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
            if let stopContinuation {
                self.stopContinuation = nil
                stopContinuation.resume()
            }
        case .cancelled:
            listener = nil
            if state != .idle { state = .idle }
            if let stopContinuation {
                self.stopContinuation = nil
                stopContinuation.resume()
            }
        default:
            break
        }
    }
}
