import Foundation
import Observation

@MainActor
@Observable
final class ServerCoordinator {
    enum State: Equatable {
        case awaitingFolder
        case unavailable
    }

    private(set) var state: State = .awaitingFolder
    let folders: FolderRootManager
    private let service: any ServerService

    init(service: any ServerService = UnconfiguredServerService(),
         folders: FolderRootManager = FolderRootManager()) {
        self.service = service
        self.folders = folders
    }

    var statusTitle: String {
        switch state {
        case .awaitingFolder: folders.folderName == nil ? "No folder selected" : "Folder ready"
        case .unavailable: "Server stopped"
        }
    }

    func selectFolder(_ url: URL) {
        // Future active transfers must stop before replacing their root authority.
        service.stop()
        folders.select(url)
        state = .awaitingFolder
    }

    func restoreFolder() {
        service.stop()
        folders.restore()
        state = .awaitingFolder
    }

    func forgetFolder() {
        service.stop()
        folders.forget()
        state = .awaitingFolder
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
