import SwiftUI

@main
struct iServeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: ServerCoordinator
    /// One shared instance for the app's lifetime, same as `coordinator` --
    /// `PurchaseManager`'s own `init()` kicks off loading the product and
    /// checking the current entitlement immediately, so constructing it
    /// here (not lazily inside `OptionsView`) means that check is already
    /// underway well before anyone taps the gear button.
    @State private var purchaseManager = PurchaseManager()
    /// The Options screen's "Appearance" picker writes this same key
    /// (`AppTheme`, `App/Theme.swift`) — both read the identical
    /// `UserDefaults`-backed storage, so a change there is reflected here
    /// without any direct view-to-view wiring.
    @AppStorage("iServe.appTheme") private var themeRawValue = AppTheme.system.rawValue

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
            ServerDashboard(coordinator: coordinator, purchaseManager: purchaseManager)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            // Only `.background` is "truly left the foreground" (ADR-0001:
            // foreground-only by design, stop serving once backgrounded).
            // `.inactive` is a brief, transitional state many unrelated
            // system interactions pass through without ever backgrounding
            // the app -- Control Center, an incoming call banner, the
            // app-switcher preview, and critically, presenting ANY system
            // modal UI from this app itself, including the `.fileImporter`
            // folder picker. Reacting to `.inactive` here was tearing down
            // `state`/stopping the server mid-presentation of that picker,
            // which on real devices (not the Simulator) was breaking its
            // dismiss-and-callback handshake entirely: the Files picker's
            // "Open" button would do nothing and the sheet would never
            // close, confirmed as specific to this app (other apps'
            // folder pickers on the same device worked fine).
            if phase == .background {
                coordinator.leaveActiveScene()
            }
        }
    }
}
