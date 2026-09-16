import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ServerDashboard: View {
    @State private var isChoosingFolder = false
    @State private var didRestore = false
    @State private var didCopyEndpoint = false
    @State private var requestCount = 0
    @State private var bytesTransferred = 0
    @State private var recentEntries: [RequestLogEntry] = []
    let coordinator: ServerCoordinator

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

                Section {
                    LabeledContent("Profile", value: "Website / Read Only")
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
                    Text("Keep iServe open while sharing. Serving stops when the app is no longer active.")
                }

                Section("Connections") {
                    if let endpoint {
                        Label(endpoint, systemImage: "network")
                            .textSelection(.enabled)
                        Button(didCopyEndpoint ? "Copied" : "Copy Address", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = endpoint
                            didCopyEndpoint = true
                        }
                        Text("Open this address from another device on the same network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LabeledContent("Requests", value: "\(requestCount)")
                        LabeledContent("Transferred", value: Self.byteFormatter.string(fromByteCount: Int64(bytesTransferred)))
                    } else {
                        Text("No listening endpoint")
                            .foregroundStyle(.secondary)
                        Text("Local addresses will appear here when the server is ready. Public connectivity depends on your network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if isRunning {
                    Section("Recent requests") {
                        if recentEntries.isEmpty {
                            Text("No requests yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(recentEntries.prefix(10)) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(entry.method) \(entry.path)")
                                            .font(.callout)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text("\(entry.status)")
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(entry.status < 400 ? .secondary : .orange)
                                    }
                                    Text(entry.date, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("iServe")
            .onChange(of: endpoint) { _, _ in didCopyEndpoint = false }
            .task {
                guard !didRestore else { return }
                didRestore = true
                coordinator.restoreFolder()
            }
            .task(id: isRunning) {
                guard isRunning, let log = coordinator.requestLog else {
                    requestCount = 0
                    bytesTransferred = 0
                    recentEntries = []
                    return
                }
                while !Task.isCancelled {
                    let snapshot = await log.snapshot()
                    requestCount = snapshot.totalRequests
                    bytesTransferred = snapshot.totalBytes
                    recentEntries = snapshot.entries
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
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
        }
    }
}

#Preview {
    ServerDashboard(coordinator: ServerCoordinator())
}
