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
            // Server-only product scope (docs/adr/0011-remove-native-file-manager.md):
            // ServerDashboard is the whole app now, so it's the window's root
            // view directly -- no tab bar, since there's nothing else to switch to.
            ServerDashboard(coordinator: coordinator)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                coordinator.leaveActiveScene()
            }
        }
    }
}
