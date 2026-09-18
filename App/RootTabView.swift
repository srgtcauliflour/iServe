import SwiftUI

/// Root bottom tab bar (v0.3): the app opens straight to the File Manager
/// tab so a person can browse their device's files immediately, and moves
/// to the File Sharing tab (folder selection, server profile, and the web
/// server itself — `ServerDashboard`) with a standard Apple-style tab bar.
/// Replaces the old "Open File Manager" sheet, which buried file
/// management behind the server screen instead of giving it its own
/// first-class destination.
///
/// `fileManagerModel` is created once, here, rather than inline in `body`
/// (which SwiftUI re-invokes far more often than once). It is entirely
/// independent of `coordinator` (post-v0.3 fix) — it browses the app's own
/// Documents directory unconditionally, not whatever folder is or isn't
/// selected for sharing — so the two tabs share no state at all.
struct RootTabView: View {
    enum Tab: Hashable {
        case files
        case server
    }

    @Bindable var coordinator: ServerCoordinator
    @State private var selection: Tab = .files
    @State private var fileManagerModel: FileManagerViewModel

    init(coordinator: ServerCoordinator) {
        self.coordinator = coordinator
        _fileManagerModel = State(initialValue: FileManagerViewModel())
    }

    var body: some View {
        TabView(selection: $selection) {
            FileManagerScreen(model: fileManagerModel)
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(Tab.files)
            ServerDashboard(coordinator: coordinator)
                .tabItem { Label("File Sharing", systemImage: "externaldrive.badge.wifi") }
                .tag(Tab.server)
        }
    }
}

#Preview {
    RootTabView(coordinator: ServerCoordinator())
}
