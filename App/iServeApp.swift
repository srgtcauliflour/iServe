import SwiftUI

@main
struct iServeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = ServerCoordinator()

    var body: some Scene {
        WindowGroup {
            ServerDashboard(coordinator: coordinator)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                coordinator.leaveActiveScene()
            }
        }
    }
}
