import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ServerCoordinator {
    enum State: Equatable {
        case noFolder
        case ready
        case starting
        case running(endpoint: String)
        case error(String)
        case unavailable
    }

    /// One `alternateEndpoints` entry - everything the primary `state`
    /// endpoint doesn't surface (other interfaces, IPv6).
    struct DiscoveredEndpoint: Identifiable, Equatable {
        let address: NetworkInterfaceAddress
        /// What copying this row should copy: a full `http://` URL for
        /// IPv4, matching the primary endpoint's format - but just the raw
        /// address for IPv6, since a zone-id link-local address
        /// (`fe80::1%en0`) isn't reliably usable as a URL host across HTTP
        /// clients, so building one here isn't worth the risk of it being
        /// silently wrong.
        let copyValue: String
        var id: String { address.id }
    }

    private(set) var state: State
    /// Defaults to `.fileSharing` — browsing and downloads, no uploads —
    /// matching this app's behavior before server profiles existed. Per
    /// `docs/SECURITY.md`, a write capability is never implied just by
    /// selecting a folder and starting the server, so this must never
    /// default to `.fileDrop`/`.fullAccess` on its own. Changing it while
    /// running has no effect on the current session — only the next
    /// `start()` reads it; `ServerDashboard` disables the picker while
    /// running to avoid that confusion. See `ServerCore/ServerProfile.swift`.
    var profile: ServerProfile = .fileSharing
    /// Off by default, and — unlike `profile` — never persisted: per
    /// `docs/adr/0002-http-basic-authentication.md`, a plaintext passphrase
    /// isn't something this app keeps at rest, so both this and `password`
    /// reset each launch and must be re-entered to re-enable protection.
    /// Changing either while running has no effect on the current session,
    /// same as `profile`.
    var requiresPassword = false
    var password = ""
    /// Off by default, and orthogonal to `profile` — ADR-0009's capability
    /// gating: PHP execution is never implied just by a profile allowing
    /// directory listing, only by this explicit toggle *and* that profile
    /// condition both holding (see `LiveServerService.start`). Has no
    /// effect at all in the ordinary `iServe` build, which never links the
    /// PHP bridge in (`#if canImport(PHPBridge)` below) — the toggle exists
    /// there but a `.php` file keeps serving as a plain static file
    /// regardless. Changing this while running has no effect on the
    /// current session, same as `profile`/`requiresPassword`.
    var phpExecutionEnabled = false
    let folders: FolderRootManager
    private let service: any ServerService
    private let ipAddressProvider: @Sendable () -> String?
    private let networkAddressProvider: @Sendable () -> [NetworkInterfaceAddress]
    private let deviceNameProvider: @MainActor @Sendable () -> String
    private let bonjourAdvertiser: BonjourAdvertiser
    private(set) var runningPort: UInt16?
    #if canImport(PHPBridge)
    /// Only ever non-nil while a session with `phpExecutionEnabled` is
    /// running, in the `iServeWithPHP` build alone (see `phpExecutionEnabled`'s
    /// doc comment) — constructed fresh in `start()`, torn down in
    /// `stopServing()`, exactly like `LiveServerService`'s own `httpServer`.
    private var phpWorker: PHPWorker?
    #endif

    init(
        service: any ServerService = UnconfiguredServerService(),
        folders: FolderRootManager = FolderRootManager(),
        ipAddressProvider: @escaping @Sendable () -> String? = LocalNetworkAddress.preferredIPv4Address,
        networkAddressProvider: @escaping @Sendable () -> [NetworkInterfaceAddress] = LocalNetworkAddress.allAddresses,
        // @MainActor, unlike ipAddressProvider above: UIDevice.current is
        // itself main-actor-isolated, so a plain @Sendable closure wrapping
        // it can't reference it at all. Calling it stays synchronous since
        // every call site here is already MainActor-isolated (inside
        // start()'s Task, which inherits that isolation).
        deviceNameProvider: @escaping @MainActor @Sendable () -> String = { UIDevice.current.name },
        bonjourAdvertiser: BonjourAdvertiser = BonjourAdvertiser()
    ) {
        self.service = service
        self.folders = folders
        self.ipAddressProvider = ipAddressProvider
        self.networkAddressProvider = networkAddressProvider
        self.deviceNameProvider = deviceNameProvider
        self.bonjourAdvertiser = bonjourAdvertiser
        self.state = folders.selectedURL == nil ? .noFolder : .ready
    }

    /// The current session's sanitized request telemetry, or `nil` when not running.
    var requestLog: RequestLog? { service.requestLog }

    /// Bonjour/mDNS advertisement state for the current session — purely a
    /// discoverability convenience alongside `state`'s IP-based endpoint,
    /// never required for it: a `.failed` advertisement never affects
    /// whether the server itself is reachable by address.
    var bonjourState: BonjourAdvertiser.State { bonjourAdvertiser.state }

    /// Every other LAN-reachable address sharing `state`'s running port -
    /// alternates worth trying if the primary endpoint isn't reachable from
    /// a particular device (a secondary interface, an IPv6-only peer).
    /// `HTTPServer` binds to `.any` (every interface), so all of these
    /// reach the same running server. Excludes whichever address `state`'s
    /// own endpoint is already built from. Empty when not running.
    var alternateEndpoints: [DiscoveredEndpoint] {
        guard let runningPort, case .running(let primaryEndpoint) = state else { return [] }
        return networkAddressProvider().compactMap { candidate in
            switch candidate.family {
            case .ipv4:
                let endpoint = "http://\(candidate.address):\(runningPort)/"
                guard endpoint != primaryEndpoint else { return nil }
                return DiscoveredEndpoint(address: candidate, copyValue: endpoint)
            case .ipv6:
                return DiscoveredEndpoint(address: candidate, copyValue: candidate.address)
            }
        }
    }

    var statusTitle: String {
        switch state {
        case .noFolder: "No folder selected"
        case .ready: folders.folderName.map { "\($0) ready" } ?? "Folder ready"
        case .starting: "Starting…"
        case .running: "Running"
        case .error: "Server error"
        case .unavailable: "Server stopped"
        }
    }

    func selectFolder(_ url: URL) {
        // Future active transfers must stop before replacing their root authority.
        stopServing()
        folders.select(url)
        state = folderState()
    }

    func restoreFolder() {
        stopServing()
        folders.restore()
        state = folderState()
    }

    func forgetFolder() {
        stopServing()
        folders.forget()
        state = folderState()
    }

    /// Stop on loss of active scene state. Returning to the app never restarts serving.
    func leaveActiveScene() {
        stopServing()
        state = .unavailable
    }

    /// No-op if already starting or running. Requires a selected folder; the
    /// underlying `ServerService` is responsible for acquiring its own scoped
    /// access and starting the actual listener.
    func start() {
        switch state {
        case .starting, .running:
            return
        default:
            break
        }
        guard folders.selectedURL != nil else {
            state = .noFolder
            return
        }
        guard !requiresPassword || !password.isEmpty else {
            state = .error("Enter a password before starting, or turn off password protection.")
            return
        }
        state = .starting
        let credentials = requiresPassword ? ServerCredentials(password: password) : nil
        Task {
            do {
                var phpExecutor: (any PHPScriptExecutor)?
                #if canImport(PHPBridge)
                if phpExecutionEnabled {
                    let worker = PHPWorker()
                    try await worker.start(limits: Self.phpWorkerLimits())
                    phpWorker = worker
                    phpExecutor = worker
                }
                #endif
                let port = try await service.start(profile: profile, credentials: credentials, phpExecutor: phpExecutor)
                let host = ipAddressProvider() ?? "localhost"
                state = .running(endpoint: "http://\(host):\(port)/")
                runningPort = port
                bonjourAdvertiser.start(name: deviceNameProvider(), port: Int(port))
            } catch {
                #if canImport(PHPBridge)
                // Started, but service.start(...) failed afterward -- don't
                // leave a running PHP module behind a session that never
                // actually came up.
                if let worker = phpWorker {
                    phpWorker = nil
                    Task { await worker.shutdown() }
                }
                #endif
                state = .error(Self.sanitizedStartFailureMessage(for: error))
            }
        }
    }

    func stop() {
        stopServing()
        state = .unavailable
    }

    private func stopServing() {
        service.stop()
        bonjourAdvertiser.stop()
        runningPort = nil
        #if canImport(PHPBridge)
        if let worker = phpWorker {
            phpWorker = nil
            Task { await worker.shutdown() }
        }
        #endif
    }

    #if canImport(PHPBridge)
    /// Conservative fixed defaults for a first working end-to-end path
    /// (ADR-0009's resource-limits section) — not yet exposed as a setting
    /// anywhere. `sessionSavePath` is under the app's own container cache
    /// directory, never a served folder, so a PHP session can't be listed/
    /// downloaded as if it were served content.
    private static func phpWorkerLimits() -> PHPWorkerLimits {
        let sessionsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iServe-php-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        return PHPWorkerLimits(
            maxExecutionTimeSeconds: 10,
            memoryLimitBytes: 64 * 1024 * 1024,
            sessionSavePath: sessionsDirectory.path
        )
    }
    #endif

    private func folderState() -> State {
        folders.selectedURL == nil ? .noFolder : .ready
    }

    /// Maps a start() failure to a message safe to show a remote-free, local
    /// user: specific enough to say which layer failed, but never the raw
    /// error description, which may originate from FileSystem/Network.framework
    /// and could include a local path or other implementation detail.
    private static func sanitizedStartFailureMessage(for error: Error) -> String {
        switch error {
        case LiveServerService.ServiceError.noFolderSelected:
            return "No folder is selected."
        case LiveServerService.ServiceError.accessDenied:
            return "Could not access the selected folder. Try choosing it again."
        case let serverError as HTTPServer.ServerError:
            switch serverError {
            case .alreadyRunning:
                return "The server is already running."
            case .listenerFailed(let reason):
                return "The network listener failed to start (\(reason)). If iServe just asked for Local Network access, allow it in Settings > iServe and try again."
            }
        #if canImport(PHPBridge)
        case is PHPWorker.WorkerError:
            return "The PHP runtime could not be started."
        #endif
        default:
            return "The server could not be started. Try again."
        }
    }
}
