@preconcurrency import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Native in-app file manager (v0.3): browse this app's own on-device
/// storage (or, via `locationMenu`, any other folder a person picks),
/// preview or edit files, rename/move/copy/delete, and zip/unzip —
/// independent of the remote HTTP directory listing a browser client sees,
/// of whether the server is running, and (post-v0.3 fix) of whatever
/// folder is or isn't selected in the File Sharing tab. `model.start()`
/// always resolves to *some* root (the app's Documents directory, or a
/// remembered external location), so this screen has nothing to wait on
/// and no "no folder selected" state of its own.
struct FileManagerScreen: View {
    @Bindable var model: FileManagerViewModel
    @State private var isChoosingLocation = false

    var body: some View {
        NavigationStack {
            Group {
                if let rootURL = model.rootURL {
                    FileManagerFolderView(model: model, directory: rootURL)
                        .navigationTitle("Files")
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                locationMenu
                            }
                        }
                        .safeAreaInset(edge: .top) {
                            locationBanner(for: rootURL)
                        }
                } else {
                    ContentUnavailableView(
                        "Files Unavailable",
                        systemImage: "folder.badge.questionmark",
                        description: Text(model.errorMessage ?? "Your on-device files could not be loaded.")
                    )
                }
            }
            .navigationDestination(for: URL.self) { directory in
                FileManagerFolderView(model: model, directory: directory)
                    .navigationTitle(directory.lastPathComponent)
            }
        }
        .fileImporter(
            isPresented: $isChoosingLocation,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.chooseLocation(url) }
            case .failure(let error):
                model.reportPickerFailure(error)
            }
        }
        .sheet(isPresented: previewPresented) {
            if let previewURL = model.previewURL {
                // `QLPreviewController` normally supplies its own "Done"
                // button when *presented* by UIKit, but embedded directly
                // via `UIViewControllerRepresentable` here it has no
                // navigation bar of its own — without this wrapper there
                // was no visible way to exit an image/file preview besides
                // an undiscoverable swipe-down gesture.
                NavigationStack {
                    QuickLookPreview(url: previewURL)
                        .ignoresSafeArea()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { model.previewURL = nil }
                            }
                        }
                }
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

    /// "Browse Other Location…" opens the system folder picker — the same
    /// one `ServerDashboard`'s "Choose Folder" uses — for anywhere iOS's
    /// sandboxing doesn't already grant this app: On My iPhone/iPad,
    /// Downloads, iCloud Drive, another app's shared documents. There's no
    /// way to reach any of that without a person picking it at least once;
    /// this screen just remembers the choice afterward
    /// (`FileManagerViewModel.chooseLocation(_:)`) so it feels automatic on
    /// every later launch. The reset action only appears once there's
    /// somewhere to reset *to* — i.e. only while actually browsing an
    /// external location rather than the app's own Documents directory.
    private var locationMenu: some View {
        Menu {
            Button("Browse Other Location…", systemImage: "folder.badge.plus") {
                isChoosingLocation = true
            }
            if model.isBrowsingExternalLocation {
                Button("Use This App's Storage", systemImage: "arrow.uturn.backward") {
                    model.resetToAppStorage()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Change browse location")
    }

    /// A persistent, unmissable readout of exactly what `model.rootURL`
    /// currently is — added specifically so "which folder is the file
    /// manager actually showing right now" is never a guess from a
    /// screenshot or a bug report. Always visible at the top of the root
    /// screen (not nested subfolders), regardless of scroll position,
    /// via `.safeAreaInset` rather than a plain list row. Also surfaces
    /// `model.lastListingDiagnostic` — a temporary debugging aid for an
    /// on-device report that an externally-chosen folder listed empty.
    /// Pull-to-refresh on the list below (`FileManagerFolderView`) re-runs
    /// the listing and updates this line, to tell a timing issue apart
    /// from a permanent one without leaving this screen.
    private func locationBanner(for rootURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: model.isBrowsingExternalLocation ? "externaldrive" : "shippingbox")
                Text(model.isBrowsingExternalLocation ? "Browsing: \(rootURL.path)" : "Browsing: This app's own storage")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let diagnostic = model.lastListingDiagnostic {
                Text(diagnostic)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
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
    @State private var infoEntry: FileManagerEntry?
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
            .toolbar { toolbarContent }
            .confirmationDialog(deleteConfirmationTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                deleteConfirmationActions
            }
            .sheet(isPresented: $isShowingMovePicker) { movePickerSheet }
            .sheet(isPresented: $isShowingCopyPicker) { copyPickerSheet }
            .sheet(item: $infoEntry) { entry in FileInfoSheet(entry: entry) }
            .alert("Rename", isPresented: renamingPresented, presenting: renamingEntry) { entry in
                renameAlertActions(for: entry)
            } message: { entry in
                Text("Enter a new name for \"\(entry.name)\".")
            }
            // `.task(id: directory)`, not `.onAppear`: `onAppear` only fires
            // the first time this view mounts. When the file manager's
            // root screen stays mounted and `chooseLocation(_:)`/
            // `resetToAppStorage()` just hands it a *new* `directory` value
            // (the common case — switching location without ever leaving
            // the Files tab), SwiftUI updates this same view's `directory`
            // property in place without remounting it, so `onAppear` never
            // fires again and `entries` silently keeps showing whatever
            // was loaded for the *previous* directory. `.task(id:)` re-runs
            // its body every time the id (here, `directory`) actually
            // changes, in addition to on first appearance, which is the
            // real fix — this was the actual cause of a folder chosen via
            // "Browse Other Location" appearing empty until something
            // unrelated (leaving and returning to the tab) happened to
            // remount this view from scratch.
            .task(id: directory) { refresh() }
            .refreshable { refresh() }
    }

    /// A plain, non-selection `List`: earlier this used `List(selection:)`
    /// for multi-select, but a `List` with a `Set`-backed selection binding
    /// intercepts row taps for its own selection handling even when a row's
    /// content is itself an interactive `NavigationLink`/`Button` — which
    /// silently broke opening folders, previewing files, and building up a
    /// selection to compress/move/copy at all. Selection is now handled
    /// entirely by hand in `row(for:)` instead, so ordinary taps always
    /// reach the folder's `NavigationLink`/the file's preview `Button`.
    private var listView: some View {
        List {
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

    /// While `isSelecting` is on, every row (folder or file alike) becomes a
    /// plain tap-to-toggle checkbox row instead of its normal
    /// `NavigationLink`/preview `Button` — folders are selectable too now
    /// (they weren't before: the old code let a folder row navigate even
    /// during selection, so a folder could never actually be selected for
    /// compress/move/copy/delete).
    @ViewBuilder
    private func row(for entry: FileManagerEntry) -> some View {
        Group {
            if isSelecting {
                Button {
                    toggleSelection(entry)
                } label: {
                    HStack {
                        Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(entry.id) ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        label(for: entry)
                    }
                }
                .foregroundStyle(.primary)
            } else if entry.isDirectory {
                NavigationLink(value: entry.url) {
                    label(for: entry)
                }
            } else {
                Button {
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
            Button("Info", systemImage: "info.circle") {
                infoEntry = entry
            }
            .tint(.gray)
        }
    }

    private func toggleSelection(_ entry: FileManagerEntry) {
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
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

/// A read-only summary of one entry's name, kind, size, modification date,
/// and containing folder — reached via a leading swipe action's "Info"
/// button on any row.
private struct FileInfoSheet: View {
    let entry: FileManagerEntry

    @Environment(\.dismiss) private var dismiss

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Name", value: entry.name)
                    .textSelection(.enabled)
                LabeledContent("Kind", value: kindText)
                if !entry.isDirectory {
                    LabeledContent("Size", value: Self.byteFormatter.string(fromByteCount: Int64(entry.size)))
                }
                if let modificationDate = entry.modificationDate {
                    LabeledContent("Modified", value: Self.dateFormatter.string(from: modificationDate))
                }
                LabeledContent("Location", value: entry.url.deletingLastPathComponent().path)
                    .textSelection(.enabled)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var kindText: String {
        if entry.isDirectory { return "Folder" }
        switch entry.archiveKind {
        case .zip: return "ZIP Archive"
        case .sevenZip: return "7z Archive"
        case nil: return entry.url.pathExtension.isEmpty ? "File" : entry.url.pathExtension.uppercased() + " File"
        }
    }
}
