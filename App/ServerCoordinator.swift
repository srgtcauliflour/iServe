import Foundation
import Observation

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

    private(set) var state: State
    let folders: FolderRootManager
    private let service: any ServerService
    private let ipAddressProvider: @Sendable () -> String?

    init(
        service: any ServerService = UnconfiguredServerService(),
        folders: FolderRootManager = FolderRootManager(),
        ipAddressProvider: @escaping @Sendable () -> String? = LocalNetworkAddress.preferredIPv4Address
    ) {
        self.service = service
        self.folders = folders
        self.ipAddressProvider = ipAddressProvider
        self.state = folders.selectedURL == nil ? .noFolder : .ready
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
        service.stop()
        folders.select(url)
        state = folderState()
    }

    func restoreFolder() {
        service.stop()
        folders.restore()
        state = folderState()
    }

    func forgetFolder() {
        service.stop()
        folders.forget()
        state = folderState()
    }

    /// Stop on loss of active scene state. Returning to the app never restarts serving.
    func leaveActiveScene() {
        service.stop()
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
            } catch {
                state = .error(Self.sanitizedStartFailureMessage(for: error))
            }
        }
    }

    func stop() {
        service.stop()
        state = .unavailable
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
