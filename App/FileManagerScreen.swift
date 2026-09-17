@preconcurrency import QuickLook
import SwiftUI

/// Native in-app file manager (v0.3): browse the selected root, preview or
/// edit files, rename/move/copy/delete, and zip/unzip — independent of the
/// remote HTTP directory listing a browser client sees, and of whether the
/// server is running. Scoped access to the root is acquired for the
/// screen's whole lifetime (`.task`/`.onDisappear`), separate from any
/// server session.
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
        .sheet(isPresented: previewPresented) {
            if let previewURL = model.previewURL {
                QuickLookPreview(url: previewURL)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: editingPresented) {
            if let editingTextURL = model.editingTextURL {
                TextEditorSheet(model: model, url: editingTextURL)
            }
        }
        .alert("Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var previewPresented: Binding<Bool> {
        Binding(
            get: { model.previewURL != nil },
            set: { isPresented in if !isPresented { model.previewURL = nil } }
        )
    }

    private var editingPresented: Binding<Bool> {
        Binding(
            get: { model.editingTextURL != nil },
            set: { isPresented in if !isPresented { model.editingTextURL = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in if !isPresented { model.errorMessage = nil } }
        )
    }
}

/// Wraps `QLPreviewController` (UIKit) rather than SwiftUI's own
/// `quickLookPreview(_:)` view modifier, which — despite being documented —
/// isn't resolvable as a member on an arbitrary view hierarchy in this
/// project's toolchain; `QLPreviewController` is the well-established,
/// reliable path and needs no such assumption.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// A plain in-place text editor for files `FileManagerEntry.isTextEditable`
/// selects instead of QuickLook. Saves overwrite the file directly (no undo
/// beyond dismissing without saving); there's no autosave or draft
/// recovery, matching the scope of a first text-editing increment.
private struct TextEditorSheet: View {
    let model: FileManagerViewModel
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoaded {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .padding(4)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.writeTextFile(text, to: url) {
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            text = model.readTextFile(url) ?? ""
            isLoaded = true
        }
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
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selection = Set<FileManagerEntry.ID>()
    @State private var renamingEntry: FileManagerEntry?
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var isShowingMovePicker = false
    @State private var isShowingCopyPicker = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var filteredEntries: [FileManagerEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        listView
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            .toolbar { toolbarContent }
            .confirmationDialog(deleteConfirmationTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                deleteConfirmationActions
            }
            .sheet(isPresented: $isShowingMovePicker) { movePickerSheet }
            .sheet(isPresented: $isShowingCopyPicker) { copyPickerSheet }
            .alert("Rename", isPresented: renamingPresented, presenting: renamingEntry) { entry in
                renameAlertActions(for: entry)
            } message: { entry in
                Text("Enter a new name for \"\(entry.name)\".")
            }
            .onAppear(perform: refresh)
    }

    private var listView: some View {
        List(selection: $selection) {
            if entries.isEmpty {
                Text("This folder is empty.")
                    .foregroundStyle(.secondary)
            } else if filteredEntries.isEmpty {
                Text("No matching items.")
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredEntries) { entry in
                row(for: entry)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                Menu {
                    Button("Compress", systemImage: "doc.zipper") { compressSelection() }
                    Button("Move…", systemImage: "folder") { isShowingMovePicker = true }
                    Button("Copy…", systemImage: "doc.on.doc") { isShowingCopyPicker = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(selection.isEmpty)
                Button("Done") { endSelecting() }
            } else {
                Button("Select") { isSelecting = true }
                    .disabled(entries.isEmpty)
            }
        }
    }

    private var deleteConfirmationTitle: String {
        "Delete \(selection.count) item\(selection.count == 1 ? "" : "s")?"
    }

    @ViewBuilder
    private var deleteConfirmationActions: some View {
        Button("Delete", role: .destructive) {
            model.delete(selectedEntries())
            endSelecting()
        }
        Button("Cancel", role: .cancel) {}
    }

    private var movePickerSheet: some View {
        FolderPickerSheet(rootURL: model.rootURL ?? directory, actionTitle: "Move") { destination in
            model.move(selectedEntries(), to: destination)
            endSelecting()
        }
    }

    private var copyPickerSheet: some View {
        FolderPickerSheet(rootURL: model.rootURL ?? directory, actionTitle: "Copy") { destination in
            model.copy(selectedEntries(), to: destination)
            endSelecting()
        }
    }

    @ViewBuilder
    private func renameAlertActions(for entry: FileManagerEntry) -> some View {
        TextField("Name", text: $renameText)
        Button("Cancel", role: .cancel) {}
        Button("Rename") {
            model.rename(entry, to: renameText, in: directory)
            refresh()
        }
    }

    @ViewBuilder
    private func row(for entry: FileManagerEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink(value: entry.url) {
                    label(for: entry)
                }
            } else {
                Button {
                    guard !isSelecting else { return }
                    if entry.isTextEditable {
                        model.editingTextURL = entry.url
                    } else {
                        model.previewURL = entry.url
                    }
                } label: {
                    label(for: entry)
                }
                .foregroundStyle(.primary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.delete([entry])
                refresh()
            }
            if entry.isArchive {
                Button("Extract", systemImage: "archivebox") {
                    model.extractArchive(entry, in: directory)
                    refresh()
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading) {
            Button("Rename", systemImage: "pencil") {
                renamingEntry = entry
                renameText = entry.name
            }
            .tint(.orange)
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
            Image(systemName: entry.isDirectory ? "folder" : (entry.isArchive ? "doc.zipper" : "doc"))
        }
    }

    private func selectedEntries() -> [FileManagerEntry] {
        entries.filter { selection.contains($0.id) }
    }

    private func compressSelection() {
        model.createArchive(containing: selectedEntries(), in: directory)
        endSelecting()
    }

    private func refresh() {
        entries = model.entries(in: directory)
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
        refresh()
    }

    private var renamingPresented: Binding<Bool> {
        Binding(
            get: { renamingEntry != nil },
            set: { isPresented in if !isPresented { renamingEntry = nil } }
        )
    }
}

/// A read-only folder browser for picking a "Move"/"Copy" destination.
/// Reuses `FileManagerEntry` for listing but only ever shows directories —
/// files can't be a move/copy destination. Its own `NavigationStack` and
/// `navigationDestination(for: URL.self)` are independent of
/// `FileManagerScreen`'s, since this is a separate modal sheet.
private struct FolderPickerSheet: View {
    let rootURL: URL
    let actionTitle: String
    let onSelect: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolderPickerLevel(directory: rootURL, actionTitle: actionTitle, onSelect: select)
                .navigationDestination(for: URL.self) { directory in
                    FolderPickerLevel(directory: directory, actionTitle: actionTitle, onSelect: select)
                }
        }
    }

    private func select(_ destination: URL) {
        onSelect(destination)
        dismiss()
    }
}

private struct FolderPickerLevel: View {
    let directory: URL
    let actionTitle: String
    let onSelect: (URL) -> Void

    @State private var subfolders: [FileManagerEntry] = []

    var body: some View {
        List {
            ForEach(subfolders) { entry in
                NavigationLink(value: entry.url) {
                    Label(entry.name, systemImage: "folder")
                }
            }
            if subfolders.isEmpty {
                Text("No subfolders")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("\(actionTitle) Here") { onSelect(directory) }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        subfolders = contents.map(FileManagerEntry.init)
            .filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
