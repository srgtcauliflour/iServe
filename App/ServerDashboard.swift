import SwiftUI
import UniformTypeIdentifiers

struct ServerDashboard: View {
    @State private var isChoosingFolder = false
    @State private var didRestore = false
    let coordinator: ServerCoordinator

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
                    if coordinator.folders.hasSavedFolder {
                        Button("Retry Saved Folder", systemImage: "arrow.clockwise") {
                            coordinator.restoreFolder()
                        }
                        Button("Forget Folder", role: .destructive) {
                            coordinator.forgetFolder()
                        }
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
                    LabeledContent("Status", value: "Stopped")
                    Button("Start Server", systemImage: "play.fill") {}
                        .disabled(true)
                        .accessibilityHint("The HTTP listener is not available in this development build.")
                } header: {
                    Text("Server")
                } footer: {
                    Text("Keep iServe open while sharing. Serving stops when the app is no longer active.")
                }

                Section("Connections") {
                    Text("No listening endpoint")
                        .foregroundStyle(.secondary)
                    Text("Local addresses will appear here when the server is ready. Public connectivity depends on your network.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Development preview") {
                    Text("Folder selection is available. HTTP serving is still in development.")
                        .font(.footnote)
                }
            }
            .navigationTitle("iServe")
            .task {
                guard !didRestore else { return }
                didRestore = true
                coordinator.restoreFolder()
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
