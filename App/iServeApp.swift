import SwiftUI

@main
struct iServeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: ServerCoordinator

    init() {
        let folders = FolderRootManager()
        let service = LiveServerService(folders: folders)
        _coordinator = State(initialValue: ServerCoordinator(service: service, folders: folders))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(coordinator: coordinator)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                coordinator.leaveActiveScene()
            }
        }
    }
}
