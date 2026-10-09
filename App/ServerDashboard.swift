import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app's home screen: the standard, default flow only -- choose a
/// folder, start serving (read-only, no password, no PHP, until changed),
/// connect from another device. Everything else (server profile, password,
/// PHP execution/outbound networking, additional mounted folders, on-device
/// diagnostics) lives in `OptionsView`, reached through the toolbar's gear
/// button, so a first-time opener sees a small, focused screen rather than
/// a form full of settings most sessions never touch.
struct ServerDashboard: View {
    /// A single "Preview in App" target — the primary endpoint or one
    /// additional mount's own address — for the in-app browser sheet.
    /// `Identifiable` by its own URL so `.sheet(item:)` can present it.
    private struct PreviewTarget: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @State private var isChoosingFolder = false
    @State private var isShowingOptions = false
    @State private var didRestore = false
    @State private var didCopyEndpoint = false
    @State private var previewTarget: PreviewTarget?
    @State private var requestCount = 0
    @State private var bytesTransferred = 0
    @State private var rejectedConnectionCount = 0
    @State private var recentEntries: [RequestLogEntry] = []
    @State private var phpDiagnosticEntries: [PHPDiagnosticEntry] = []
    // @Bindable, not `let`: the password field (inside OptionsView, which
    // this view hands the same coordinator down to) needs a Binding into
    // coordinator's properties. Plain @Observable property access (as most
    // of this file uses) still tracks changes for re-rendering either way —
    // this only adds the $-projection.
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

    private var endpoint: String? {
        if case .running(let endpoint) = coordinator.state { return endpoint }
        return nil
    }

    private var endpointURL: URL? {
        endpoint.flatMap(URL.init(string:))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: GlassMetrics.cardSpacing) {
                    heroCard
                    folderCard
                    startStopControl
                    if coordinator.isRunning {
                        connectionCard
                    }
                }
                .padding(GlassMetrics.cardPadding)
            }
            .background(DashboardBackground(tint: statusTint))
            .navigationTitle("iServe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingOptions = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Options")
                }
            }
            .onChange(of: endpoint) { _, _ in didCopyEndpoint = false }
            .task {
                guard !didRestore else { return }
                didRestore = true
                coordinator.restoreFolder()
                coordinator.folders.restoreMounts()
            }
            .task(id: coordinator.isRunning) {
                await pollRequestLog()
            }
            .fileImporter(isPresented: $isChoosingFolder,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    coordinator.selectFolder(url)
                case .failure(let error):
                    coordinator.folders.reportPickerFailure(error)
                }
            }
            .sheet(isPresented: $isShowingOptions) {
                OptionsView(
                    coordinator: coordinator,
                    recentEntries: recentEntries,
                    phpDiagnosticEntries: phpDiagnosticEntries
                )
            }
            .sheet(item: $previewTarget) { target in
                InAppBrowserSheet(url: target.url, password: coordinator.requiresPassword ? coordinator.password : nil)
            }
        }
    }

    private func pollRequestLog() async {
        guard coordinator.isRunning, let log = coordinator.requestLog else {
            requestCount = 0
            bytesTransferred = 0
            rejectedConnectionCount = 0
            recentEntries = []
            phpDiagnosticEntries = []
            return
        }
        let diagnosticsLog = coordinator.phpDiagnosticsLog
        while !Task.isCancelled {
            let snapshot = await log.snapshot()
            requestCount = snapshot.totalRequests
            bytesTransferred = snapshot.totalBytes
            rejectedConnectionCount = snapshot.rejectedConnections
            recentEntries = snapshot.entries
            phpDiagnosticEntries = await diagnosticsLog?.snapshot() ?? []
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Status

    private var statusTint: Color {
        switch coordinator.state {
        case .running: .green
        case .starting: .yellow
        case .error, .unavailable: .orange
        case .noFolder, .ready: .accentColor
        }
    }

    private var statusIcon: String {
        switch coordinator.state {
        case .running: "dot.radiowaves.left.and.right"
        case .starting: "hourglass"
        case .error, .unavailable: "exclamationmark.triangle.fill"
        case .noFolder, .ready: "externaldrive.badge.wifi"
        }
    }

    private var heroSubtitle: String {
        switch coordinator.state {
        case .noFolder:
            "Choose a folder, start serving, then connect from another device."
        case .ready:
            "Ready to start serving \(coordinator.folders.folderName ?? "your folder")."
        case .starting:
            "Starting…"
        case .running:
            coordinator.requiresPassword
            ? "\(coordinator.profile.displayName) · Password protected"
            : coordinator.profile.displayName
        case .error(let message):
            message
        case .unavailable:
            "Serving stopped because iServe left the foreground."
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var heroCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: statusIcon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.statusTitle)
                    .font(.title3.bold())
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(GlassMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: statusTint)
    }

    @ViewBuilder
    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(coordinator.folders.folderName ?? "No folder selected")
                    .font(.headline)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
            }
            HStack(spacing: 10) {
                Button("Choose Folder", systemImage: "folder.badge.plus") {
                    isChoosingFolder = true
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isBusy || coordinator.isRunning)

                if coordinator.folders.hasSavedFolder {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        coordinator.restoreFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.isBusy || coordinator.isRunning)

                    Button("Forget", systemImage: "trash", role: .destructive) {
                        coordinator.forgetFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.isBusy || coordinator.isRunning)
                }
            }
            if let message = coordinator.folders.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Folder error: \(message)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GlassMetrics.cardPadding)
        .glassCard()
    }

    @ViewBuilder
    private var startStopControl: some View {
        if coordinator.isBusy {
            Button {
                // No-op: disabled while starting, shown only as feedback.
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Starting…")
                }
            }
            .buttonStyle(.appGlassProminent(tint: .yellow))
            .disabled(true)
        } else if coordinator.isRunning {
            Button("Stop Server", systemImage: "stop.fill") {
                coordinator.stop()
            }
            .buttonStyle(.appGlassProminent(tint: .red))
        } else {
            Button("Start Server", systemImage: "play.fill") {
                coordinator.start()
            }
            .buttonStyle(.appGlassProminent(tint: .green))
            .disabled(!canStart)
            .accessibilityHint(
                canStart
                ? "Starts serving the selected folder to your local network."
                : "Choose a folder before starting the server."
            )
        }
    }

    @ViewBuilder
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            if let endpoint {
                Text(endpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button(didCopyEndpoint ? "Copied" : "Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = endpoint
                        didCopyEndpoint = true
                    }
                    .buttonStyle(.bordered)
                    Button("Preview", systemImage: "safari") {
                        guard let endpointURL else { return }
                        previewTarget = PreviewTarget(url: endpointURL)
                    }
                    .buttonStyle(.bordered)
                }

                if case .published(let name) = coordinator.bonjourState {
                    Label(name, systemImage: "dot.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Also discoverable on the local network as \(name)")
                }

                DisclosureGroup("Show QR Code") {
                    QRCodeView(string: endpoint)
                        .frame(maxWidth: 200)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .font(.subheadline)

                Divider()

                HStack(spacing: 24) {
                    statPill(title: "Requests", value: "\(requestCount)")
                    statPill(title: "Transferred", value: Self.byteFormatter.string(fromByteCount: Int64(bytesTransferred)))
                }

                if rejectedConnectionCount > 0 {
                    Label("\(rejectedConnectionCount) connection(s) turned away by server limits", systemImage: "exclamationmark.shield")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(rejectedConnectionCount) connections turned away by server limits this session")
                }

                ForEach(coordinator.folders.additionalMounts) { mount in
                    let mountEndpoint = endpoint + "\(mount.name)/"
                    VStack(alignment: .leading, spacing: 4) {
                        Label(mountEndpoint, systemImage: "folder.badge.plus")
                            .font(.footnote)
                            .textSelection(.enabled)
                            .accessibilityLabel("\(mount.name): \(mountEndpoint)")
                        if let mountURL = URL(string: mountEndpoint) {
                            Button("Preview", systemImage: "safari") {
                                previewTarget = PreviewTarget(url: mountURL)
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GlassMetrics.cardPadding)
        .glassCard(tint: .green)
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The home screen's soft background gradient -- present so the glass
/// cards above it have something with color/depth to actually show
/// translucency against, rather than a flat system background. Tints
/// toward the current status color (green while running, etc.) at very
/// low opacity, subtle rather than loud.
private struct DashboardBackground: View {
    var tint: Color

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0.16), Color(.systemGroupedBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: tint)
    }
}

struct RequestLogEntryRow: View {
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

struct PHPDiagnosticEntryRow: View {
    let entry: PHPDiagnosticEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((entry.scriptPath as NSString).lastPathComponent)
                .font(.callout)
                .lineLimit(1)
            Text(entry.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ServerDashboard(coordinator: ServerCoordinator())
}
