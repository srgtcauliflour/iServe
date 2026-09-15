import SwiftUI

struct ServerDashboard: View {
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
                    Label("No folder selected", systemImage: "folder")
                    Button("Choose Folder", systemImage: "folder.badge.plus") {}
                        .disabled(true)
                        .accessibilityHint("Folder selection is not available in this development build.")
                } header: {
                    Text("Shared folder")
                } footer: {
                    Text("Files folder access is the next development milestone.")
                }

                Section {
                    LabeledContent("Profile", value: "Website / Read Only")
                    LabeledContent("Status", value: "Stopped")
                    Button("Start Server", systemImage: "play.fill") {}
                        .disabled(true)
                        .accessibilityHint("Requires folder access and the HTTP listener, coming in later milestones.")
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
                    Text("This build establishes the app foundation. It does not yet read or serve files.")
                        .font(.footnote)
                }
            }
            .navigationTitle("iServe")
        }
    }
}

#Preview {
    ServerDashboard(coordinator: ServerCoordinator())
}
