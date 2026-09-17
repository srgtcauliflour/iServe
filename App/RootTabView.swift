import SwiftUI

/// Root bottom tab bar (v0.3): the app opens straight to the File Manager
/// tab so a person can browse the selected folder immediately, and moves
/// to the File Sharing tab (folder selection, server profile, and the web
/// server itself — `ServerDashboard`) with a standard Apple-style tab bar.
/// Replaces the old "Open File Manager" sheet, which buried file
/// management behind the server screen instead of giving it its own
/// first-class destination.
///
/// `fileManagerModel` is created once, here, rather than inline in `body`
/// (which SwiftUI re-invokes far more often than once) — `ServerDashboard`
/// and `FileManagerViewModel` independently hold their own scoped access to
/// `coordinator.folders`' selected root, exactly as before this tab bar
/// existed; the two are unaffected by each other.
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
        _fileManagerModel = State(initialValue: FileManagerViewModel(folders: coordinator.folders))
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
