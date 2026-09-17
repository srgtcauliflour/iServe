import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ServerDashboard: View {
    /// A single "Preview in App" target — the primary endpoint or one
    /// additional mount's own address — for the in-app browser sheet.
    /// `Identifiable` by its own URL so `.sheet(item:)` can present it.
    private struct PreviewTarget: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @State private var isChoosingFolder = false
    @State private var isChoosingAdditionalFolder = false
    @State private var didRestore = false
    @State private var didCopyEndpoint = false
    @State private var previewTarget: PreviewTarget?
    @State private var requestCount = 0
    @State private var bytesTransferred = 0
    @State private var rejectedConnectionCount = 0
    @State private var recentEntries: [RequestLogEntry] = []
    // @Bindable, not `let`: the profile picker and password field need a
    // Binding into coordinator's properties. Plain @Observable property
    // access (as every other property here already uses) still tracks
    // changes for re-rendering either way - this only adds the $-projection.
    @Bindable var coordinator: ServerCoordinator

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var canStart: Bool {
        switch coordinator.state {
        case .ready, .error, .unavailable: true
        default: false
        }
    }

    private var isBusy: Bool {
        if case .starting = coordinator.state { return true }
        return false
    }

    private var isRunning: Bool {
        if case .running = coordinator.state { return true }
        return false
    }

    private var endpoint: String? {
        if case .running(let endpoint) = coordinator.state { return endpoint }
        return nil
    }

    private var endpointURL: URL? {
        endpoint.flatMap(URL.init(string:))
    }

    private var serverStatusText: String {
        switch coordinator.state {
        case .noFolder: "No folder selected"
        case .ready: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .error(let message): message
        case .unavailable: "Stopped"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                folderSection
                additionalMountsSection
                serverSection
                connectionsSection
                if isRunning {
                    alternateAddressesSection
                    recentRequestsSection
                }
            }
            .navigationTitle("iServe")
            .onChange(of: endpoint) { _, _ in didCopyEndpoint = false }
            .task {
                guard !didRestore else { return }
                didRestore = true
                coordinator.restoreFolder()
                coordinator.folders.restoreMounts()
            }
            .task(id: isRunning) {
                await pollRequestLog()
            }
            .fileImporter(isPresented: $isChoosingFolder,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { coordinator.selectFolder(url) }
                case .failure(let error):
                    coordinator.folders.reportPickerFailure(error)
                }
            }
            .fileImporter(isPresented: $isChoosingAdditionalFolder,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { coordinator.folders.addMount(url) }
                case .failure(let error):
                    coordinator.folders.reportPickerFailure(error)
                }
            }
            .sheet(item: $previewTarget) { target in
                InAppBrowserSheet(url: target.url, password: coordinator.requiresPassword ? coordinator.password : nil)
            }
        }
    }

    private func pollRequestLog() async {
        guard isRunning, let log = coordinator.requestLog else {
            requestCount = 0
            bytesTransferred = 0
            rejectedConnectionCount = 0
            recentEntries = []
            return
        }
        while !Task.isCancelled {
            let snapshot = await log.snapshot()
            requestCount = snapshot.totalRequests
            bytesTransferred = snapshot.totalBytes
            rejectedConnectionCount = snapshot.rejectedConnections
            recentEntries = snapshot.entries
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(coordinator.statusTitle)
                        .font(.headline)
                    Text("Choose a folder, start serving, then connect from another device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        Section {
            Label(coordinator.folders.folderName ?? "No folder selected", systemImage: "folder")
            Button("Choose Folder", systemImage: "folder.badge.plus") {
                isChoosingFolder = true
            }
            .disabled(isBusy || isRunning)
            if coordinator.folders.hasSavedFolder {
                Button("Retry Saved Folder", systemImage: "arrow.clockwise") {
                    coordinator.restoreFolder()
                }
                .disabled(isBusy || isRunning)
                Button("Forget Folder", role: .destructive) {
                    coordinator.forgetFolder()
                }
                .disabled(isBusy || isRunning)
            }
            if let message = coordinator.folders.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Folder error: \(message)")
            }
        } header: {
            Text("Shared folder")
        } footer: {
            Text("The selected folder is remembered on this device. You can change or forget it at any time.")
        }
    }

    /// Additional mounts (v0.3, `docs/adr/0007-multiple-mounted-folders.md`)
    /// are always read/download only, regardless of the chosen profile —
    /// the footer says so plainly, since the "Full Access" warning above
    /// only ever applies to the shared folder.
    @ViewBuilder
    private var additionalMountsSection: some View {
        Section {
            ForEach(coordinator.folders.additionalMounts) { mount in
                Label(mount.name, systemImage: "folder.badge.plus")
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            coordinator.folders.removeMount(named: mount.name)
                        }
                        .disabled(isBusy || isRunning)
                    }
            }
            Button("Add Another Folder", systemImage: "plus") {
                isChoosingAdditionalFolder = true
            }
            .disabled(isBusy || isRunning)
        } header: {
            Text("Additional folders")
        } footer: {
            Text("Each additional folder is served at its own address, browse/download only — never writable, regardless of the server profile above. Adding or removing one only takes effect the next time the server starts.")
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            Picker("Profile", selection: $coordinator.profile) {
                ForEach(ServerProfile.selectable) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .disabled(isBusy || isRunning)
            Text(coordinator.profile.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Require Password", isOn: $coordinator.requiresPassword)
                .disabled(isBusy || isRunning)
            if coordinator.requiresPassword {
                SecureField("Password", text: $coordinator.password)
                    .disabled(isBusy || isRunning)
                    .textContentType(.password)
            }
            LabeledContent("Status", value: serverStatusText)
            if isRunning {
                Button("Stop Server", systemImage: "stop.fill", role: .destructive) {
                    coordinator.stop()
                }
            } else {
                Button("Start Server", systemImage: "play.fill") {
                    coordinator.start()
                }
                .disabled(!canStart)
                .accessibilityHint(
                    canStart
                    ? "Starts serving the selected folder to your local network."
                    : "Choose a folder before starting the server."
                )
            }
        } header: {
            Text("Server")
        } footer: {
            Text(serverSectionFooterText)
        }
    }

    private var serverSectionFooterText: String {
        var lines = [
            coordinator.profile.allowsUploads
            ? "Keep iServe open while sharing. Anyone who can reach this address can add files to the selected folder."
            : "Keep iServe open while sharing. Serving stops when the app is no longer active."
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

    @ViewBuilder
    private var connectionsSection: some View {
        Section("Connections") {
            if let endpoint {
                Label(endpoint, systemImage: "network")
                    .textSelection(.enabled)
                Button(didCopyEndpoint ? "Copied" : "Copy Address", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = endpoint
                    didCopyEndpoint = true
                }
                Button("Preview in App", systemImage: "safari") {
                    guard let endpointURL else { return }
                    previewTarget = PreviewTarget(url: endpointURL)
                }
                if case .published(let name) = coordinator.bonjourState {
                    Label(name, systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Also discoverable on the local network as \(name)")
                }
                DisclosureGroup("Show QR Code") {
                    QRCodeView(string: endpoint)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                }
                Text("Open this address from another device on the same network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Requests", value: "\(requestCount)")
                LabeledContent("Transferred", value: Self.byteFormatter.string(fromByteCount: Int64(bytesTransferred)))
                if rejectedConnectionCount > 0 {
                    Label("\(rejectedConnectionCount) connection(s) turned away by server limits", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .accessibilityLabel("\(rejectedConnectionCount) connections turned away by server limits this session")
                }
                ForEach(coordinator.folders.additionalMounts) { mount in
                    let mountEndpoint = endpoint + "\(mount.name)/"
                    VStack(alignment: .leading, spacing: 4) {
                        Label(mountEndpoint, systemImage: "folder.badge.plus")
                            .textSelection(.enabled)
                            .accessibilityLabel("\(mount.name): \(mountEndpoint)")
                        if let mountURL = URL(string: mountEndpoint) {
                            Button("Preview in App", systemImage: "safari") {
                                previewTarget = PreviewTarget(url: mountURL)
                            }
                            .font(.footnote)
                        }
                    }
                }
            } else {
                Text("No listening endpoint")
                    .foregroundStyle(.secondary)
                Text("Local addresses will appear here when the server is ready. Public connectivity depends on your network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var alternateAddressesSection: some View {
        let entries = coordinator.alternateEndpoints
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    Label(entry.copyValue, systemImage: entry.address.family == .ipv4 ? "wifi" : "wifi.circle")
                        .textSelection(.enabled)
                        .accessibilityLabel("\(entry.address.interfaceName): \(entry.copyValue)")
                }
            } header: {
                Text("Other Addresses")
            } footer: {
                Text("Other network interfaces this device has. Use one of these if the main address above isn't reachable.")
            }
        }
    }

    @ViewBuilder
    private var recentRequestsSection: some View {
        Section("Recent requests") {
            if recentEntries.isEmpty {
                Text("No requests yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentEntries.prefix(10)) { entry in
                    RequestLogEntryRow(entry: entry)
                }
            }
        }
    }
}

private struct RequestLogEntryRow: View {
    let entry: RequestLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(entry.method) \(entry.path)")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(entry.status)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(entry.status < 400 ? Color.secondary : Color.orange)
            }
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ServerDashboard(coordinator: ServerCoordinator())
}
