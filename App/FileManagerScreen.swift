import SwiftUI

/// Native in-app file manager (v0.3): browse the selected root, preview
/// files with QuickLook, and zip/unzip — independent of the remote HTTP
/// directory listing a browser client sees, and of whether the server is
/// running. Scoped access to the root is acquired for the screen's whole
/// lifetime (`.task`/`.onDisappear`), separate from any server session.
struct FileManagerScreen: View {
    @Bindable var model: FileManagerViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let rootURL = model.rootURL {
                    FileManagerFolderView(model: model, directory: rootURL)
                        .navigationTitle(rootURL.lastPathComponent)
                } else {
                    ContentUnavailableView(
                        "Folder Unavailable",
                        systemImage: "folder.badge.questionmark",
                        description: Text(model.errorMessage ?? "Select a folder from the main screen first.")
                    )
                }
            }
            .navigationDestination(for: URL.self) { directory in
                FileManagerFolderView(model: model, directory: directory)
                    .navigationTitle(directory.lastPathComponent)
            }
        }
        .quickLookPreview($model.previewURL)
        .alert("Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in if !isPresented { model.errorMessage = nil } }
        )
    }
}

/// One directory level. Recursion happens through `NavigationLink(value:)` +
/// the parent `NavigationStack`'s single `navigationDestination(for: URL.self)`,
/// so every nested folder reuses this same view rather than a bespoke one
/// per depth.
struct FileManagerFolderView: View {
    @Bindable var model: FileManagerViewModel
    let directory: URL

    @State private var entries: [FileManagerEntry] = []
    @State private var isSelecting = false
    @State private var selection = Set<FileManagerEntry.ID>()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        List(selection: $selection) {
            if entries.isEmpty {
                Text("This folder is empty.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                row(for: entry)
            }
        }
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button("Compress") {
                        model.createArchive(containing: entries.filter { selection.contains($0.id) }, in: directory)
                        endSelecting()
                    }
                    .disabled(selection.isEmpty)
                    Button("Done") { endSelecting() }
                } else {
                    Button("Select") { isSelecting = true }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func row(for entry: FileManagerEntry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: entry.url) {
                label(for: entry)
            }
        } else {
            Button {
                guard !isSelecting else { return }
                model.previewURL = entry.url
            } label: {
                label(for: entry)
            }
            .foregroundStyle(.primary)
            .swipeActions {
                if entry.isZipArchive {
                    Button("Extract", systemImage: "archivebox") {
                        model.extractArchive(entry, in: directory)
                        refresh()
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private func label(for entry: FileManagerEntry) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(entry.name)
                if !entry.isDirectory {
                    Text(Self.byteFormatter.string(fromByteCount: Int64(entry.size)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: entry.isDirectory ? "folder" : (entry.isZipArchive ? "doc.zipper" : "doc"))
        }
    }

    private func refresh() {
        entries = model.entries(in: directory)
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
        refresh()
    }
}
