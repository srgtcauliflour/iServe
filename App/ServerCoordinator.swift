import Observation

@MainActor
@Observable
final class ServerCoordinator {
    enum State: Equatable {
        case awaitingFolder
        case unavailable
    }

    private(set) var state: State = .awaitingFolder
    private let service: any ServerService

    init(service: any ServerService = UnconfiguredServerService()) {
        self.service = service
    }

    var statusTitle: String {
        switch state {
        case .awaitingFolder: "No folder selected"
        case .unavailable: "Server stopped"
        }
    }

    /// Stop on loss of active scene state. Returning to the app never restarts serving.
    func leaveActiveScene() {
        service.stop()
        state = .unavailable
    }

    func stop() {
        service.stop()
        state = .unavailable
    }
}
