import SwiftUI
import UniformTypeIdentifiers

/// Everything beyond the standard "choose a folder, start serving" flow --
/// server profile/password, PHP execution/outbound networking, additional
/// mounted folders, and on-device diagnostics -- tucked away from
/// `ServerDashboard`'s own home screen so that default, read-only HTML
/// serving is what a first-time opener actually sees, not a form full of
/// settings most sessions never touch.
///
/// Kept as an ordinary `List` (not another glass-card layout): every control
/// here already existed, already works, and is standard List/Form chrome
/// (`Picker`, `Toggle`, `SecureField`, `DisclosureGroup`, swipe-to-delete) --
/// reusing it keeps this screen reliable without re-deriving list-row
/// interaction behavior by hand. `.scrollContentBackground(.hidden)` plus
/// the same background this app's home screen uses keeps it visually part
/// of the same design language rather than looking like a bolted-on
/// settings screen.
struct OptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: ServerCoordinator
    @Bindable var purchaseManager: PurchaseManager
    let recentEntries: [RequestLogEntry]
    let phpDiagnosticEntries: [PHPDiagnosticEntry]

    @AppStorage("iServe.appTheme") private var themeRawValue = AppTheme.system.rawValue
    private var theme: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: themeRawValue) ?? .system },
            set: { themeRawValue = $0.rawValue }
        )
    }

    @State private var isAddingMount = false

    var body: some View {
        NavigationStack {
            Group {
                if purchaseManager.isUnlocked {
                    optionsList
                } else {
                    PaywallView(purchaseManager: purchaseManager)
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $isAddingMount,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    coordinator.folders.addMount(url)
                case .failure(let error):
                    coordinator.folders.reportPickerFailure(error)
                }
            }
        }
    }

    /// Everything that was free before the IAP gate -- unchanged in
    /// content, only reachable once `purchaseManager.isUnlocked` is true.
    private var optionsList: some View {
        List {
            appearanceSection
            profileSection
            #if canImport(PHPBridge)
            phpSection
            #endif
            additionalMountsSection
            diagnosticsSection
        }
        .scrollContentBackground(.hidden)
        .background(OptionsBackground())
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: theme) {
                ForEach(AppTheme.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Appearance")
        }
    }

    private var profileSection: some View {
        Section {
            Picker("Profile", selection: $coordinator.profile) {
                ForEach(ServerProfile.selectable) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .disabled(coordinator.isBusy || coordinator.isRunning)
            Text(coordinator.profile.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Require Password", isOn: $coordinator.requiresPassword)
                .disabled(coordinator.isBusy || coordinator.isRunning)
            if coordinator.requiresPassword {
                SecureField("Password", text: $coordinator.password)
                    .disabled(coordinator.isBusy || coordinator.isRunning)
                    .textContentType(.password)
            }
        } header: {
            Text("Server Profile")
        } footer: {
            Text(profileFooterText)
        }
    }

    private var profileFooterText: String {
        var lines = [
            coordinator.profile.allowsUploads
            ? "Anyone who can reach this address can add files to the selected folder."
            : "Visitors can browse and download, never upload or change anything."
        ]
        if coordinator.profile.allowsWebDAVWrites {
            lines.append(
                "Full Access also lets a connected WebDAV client overwrite, move, or delete files and folders in the selected folder — including replacing existing files without a prompt."
            )
        }
        if coordinator.requiresPassword {
            lines.append(
                "A password prompt will appear before anyone can connect. iServe has no encryption, so only rely on this on networks you trust — not open/public Wi-Fi."
            )
        }
        return lines.joined(separator: " ")
    }

    #if canImport(PHPBridge)
    private var phpSection: some View {
        Section {
            Toggle("Run PHP Scripts", isOn: $coordinator.phpExecutionEnabled)
                .disabled(coordinator.isBusy || coordinator.isRunning)
            if coordinator.phpExecutionEnabled {
                Toggle("Allow Network Access", isOn: $coordinator.outboundNetworkingEnabled)
                    .disabled(coordinator.isBusy || coordinator.isRunning)
            }
        } header: {
            Text("PHP")
        } footer: {
            Text(phpFooterText)
        }
    }

    private var phpFooterText: String {
        guard coordinator.phpExecutionEnabled else {
            return "PHP files (including index.php) download as plain text, same as any other file."
        }
        var lines = [
            "PHP files (including index.php) will run instead of downloading as plain text. Scripts can only read and write inside the selected folder, can't run other programs, and are stopped if they run too long."
        ]
        if coordinator.outboundNetworkingEnabled {
            lines.append(
                "Scripts can also make their own web requests (for a remote API, RSS feed, or asset) — never to this device, your home network, or other devices on it, only to the open internet."
            )
        } else {
            lines.append("Scripts can't reach the network.")
        }
        return lines.joined(separator: " ")
    }
    #endif

    /// Additional mounts (v0.3, `docs/adr/0007-multiple-mounted-folders.md`)
    /// are always read/download only, regardless of the chosen profile —
    /// the footer says so plainly, since the "Full Access" warning above
    /// only ever applies to the shared folder.
    private var additionalMountsSection: some View {
        Section {
            ForEach(coordinator.folders.additionalMounts) { mount in
                Label(mount.name, systemImage: "folder.badge.plus")
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            coordinator.folders.removeMount(named: mount.name)
                        }
                        .disabled(coordinator.isBusy || coordinator.isRunning)
                    }
            }
            Button("Add Another Folder", systemImage: "plus") {
                isAddingMount = true
            }
            .disabled(coordinator.isBusy || coordinator.isRunning)
        } header: {
            Text("Additional Folders")
        } footer: {
            Text("Each additional folder is served at its own address, browse/download only — never writable, regardless of the server profile above. Adding or removing one only takes effect the next time the server starts.")
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            let entries = coordinator.alternateEndpoints
            if entries.isEmpty {
                Text("No other addresses")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    Label(entry.copyValue, systemImage: entry.address.family == .ipv4 ? "wifi" : "wifi.circle")
                        .textSelection(.enabled)
                        .accessibilityLabel("\(entry.address.interfaceName): \(entry.copyValue)")
                }
            }
        } header: {
            Text("Other Addresses")
        } footer: {
            Text("Other network interfaces this device has. Use one of these if the main address on the home screen isn't reachable.")
        }

        Section("Recent Requests") {
            if recentEntries.isEmpty {
                Text("No requests yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentEntries.prefix(10)) { entry in
                    RequestLogEntryRow(entry: entry)
                }
            }
        }

        #if canImport(PHPBridge)
        if coordinator.phpExecutionEnabled {
            Section {
                if phpDiagnosticEntries.isEmpty {
                    Text("No PHP diagnostics yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(phpDiagnosticEntries.prefix(10)) { entry in
                        PHPDiagnosticEntryRow(entry: entry)
                    }
                }
            } header: {
                Text("PHP Diagnostics")
            } footer: {
                Text("Warnings and errors from your PHP scripts, kept on this device only. Never shown to anyone connecting to the server.")
            }
        }
        #endif
    }
}

/// A quieter version of `ServerDashboard`'s own background gradient --
/// present so this sheet doesn't look like a flat, unrelated settings
/// screen bolted onto a glass home screen, but less prominent than the
/// home screen's own, since this one is a form full of text, not a few
/// hero cards.
private struct OptionsBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.06), Color(.systemGroupedBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

#Preview {
    OptionsView(coordinator: ServerCoordinator(), purchaseManager: PurchaseManager(), recentEntries: [], phpDiagnosticEntries: [])
}
