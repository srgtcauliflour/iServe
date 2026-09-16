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
    let folders: FolderRootManager
    private let service: any ServerService
    private let ipAddressProvider: @Sendable () -> String?
    private let networkAddressProvider: @Sendable () -> [NetworkInterfaceAddress]
    private let deviceNameProvider: @MainActor @Sendable () -> String
    private let bonjourAdvertiser: BonjourAdvertiser
    private(set) var runningPort: UInt16?

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
        state = .starting
        Task {
            do {
                let port = try await service.start()
                let host = ipAddressProvider() ?? "localhost"
                state = .running(endpoint: "http://\(host):\(port)/")
                runningPort = port
                bonjourAdvertiser.start(name: deviceNameProvider(), port: Int(port))
            } catch {
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
    }

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
        default:
            return "The server could not be started. Try again."
        }
    }
}
