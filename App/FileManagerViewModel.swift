import Foundation
import Observation
import UniformTypeIdentifiers

/// Backs the native in-app file manager screen (v0.3): browse the app's own
/// on-device storage, preview/edit files, rename/move/copy/delete, and
/// create/extract archives — all separate from the remote HTTP directory
/// listing a browser client sees, and independent of whether the server is
/// running.
///
/// Entirely independent of `ServerCoordinator`/`FolderRootManager` (post-v0.3
/// fix): this used to require a folder already selected in the File Sharing
/// tab, sharing that folder's security-scoped access, which meant the file
/// manager couldn't be used at all before a share was set up and had nothing
/// to do with "your device's files" as a person would expect a file manager
/// to mean. It now always opens the app's own sandboxed Documents directory
/// — real, on-device storage that needs no folder picker or security-scoped
/// bookmark to reach, since the app already owns it outright. `project.yml`
/// sets `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` so this
/// same folder is reachable from the Files app ("On My iPhone/iPad" >
/// iServe) and over USB/Wi-Fi from a Mac, which is how files actually get
/// onto it from outside the app.
@MainActor
@Observable
final class FileManagerViewModel {
    /// Overridable only for tests, which need an isolated temporary
    /// directory rather than the real app container's Documents folder.
    /// Explicitly `@MainActor`, not a plain `() -> URL`: every member of
    /// this class is implicitly `@MainActor`-isolated already (the class
    /// itself is), so `documentsDirectory` below is too — a plain
    /// non-isolated closure type can't hold it without silently dropping
    /// that isolation, which the compiler correctly refuses.
    private let rootProvider: @MainActor () -> URL
    private(set) var rootURL: URL?
    var previewURL: URL?
    var editingTextURL: URL?
    var errorMessage: String?

    init(rootProvider: @escaping @MainActor () -> URL = FileManagerViewModel.documentsDirectory) {
        self.rootProvider = rootProvider
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func start() {
        guard rootURL == nil else { return }
        rootURL = rootProvider()
    }

    func stop() {
        rootURL = nil
    }

    /// Lists a directory's immediate contents, folders first, both groups
    /// alphabetical. Never throws: a listing failure clears to empty and
    /// surfaces through `errorMessage` instead, since a folder view has no
    /// other sensible fallback content.
    func entries(in directory: URL) -> [FileManagerEntry] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            return contents.map(FileManagerEntry.init).sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            errorMessage = "This folder could not be read."
            return []
        }
    }

    // MARK: - Archives

    /// Zips `items` (all expected to live directly in `directory`) into a
    /// new archive alongside them, choosing a name that doesn't collide
    /// with an existing item.
    func createArchive(containing items: [FileManagerEntry], in directory: URL) {
        guard !items.isEmpty else { return }
        let destination = uniqueDestination(for: "Archive.zip", in: directory)
        do {
            try ArchiveManager.createArchive(containing: items.map(\.url), at: destination)
        } catch {
            errorMessage = "The archive could not be created."
        }
    }

    /// Extracts `entry` (expected to be a `.zip` or `.7z` file) into a new
    /// sibling folder named after the archive, choosing a name that doesn't
    /// collide with an existing item. Cleans up the destination folder if
    /// extraction fails partway through, rather than leaving a partial
    /// extraction behind.
    func extractArchive(_ entry: FileManagerEntry, in directory: URL) {
        guard let kind = entry.archiveKind else { return }
        let baseName = (entry.name as NSString).deletingPathExtension
        let destination = uniqueDestination(for: baseName.isEmpty ? "Archive" : baseName, in: directory)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            switch kind {
            case .zip:
                try ArchiveManager.extractArchive(at: entry.url, to: destination)
            case .sevenZip:
                try ArchiveManager.extractSevenZipArchive(at: entry.url, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = "The archive could not be extracted. It may be corrupted or contain unsupported entries."
        }
    }

    // MARK: - Text editing

    func readTextFile(_ url: URL) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = "\"\(url.lastPathComponent)\" could not be opened as text."
            return nil
        }
    }

    @discardableResult
    func writeTextFile(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            errorMessage = "\"\(url.lastPathComponent)\" could not be saved."
            return false
        }
    }

    // MARK: - Rename, delete, move, copy

    /// Renames `entry` within `directory`. Refuses (rather than silently
    /// overwriting, per `docs/SECURITY.md`'s general "never silently
    /// overwrite" stance) when another item already has the requested name.
    func rename(_ entry: FileManagerEntry, to newName: String, in directory: URL) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            errorMessage = "Enter a valid name."
            return
        }
        guard trimmed != entry.name else { return }
        let destination = directory.appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "\"\(trimmed)\" already exists."
            return
        }
        do {
            try FileManager.default.moveItem(at: entry.url, to: destination)
        } catch {
            errorMessage = "\"\(entry.name)\" could not be renamed."
        }
    }

    func delete(_ entries: [FileManagerEntry]) {
        var failures: [String] = []
        for entry in entries {
            do {
                try FileManager.default.removeItem(at: entry.url)
            } catch {
                failures.append(entry.name)
            }
        }
        guard !failures.isEmpty else { return }
        errorMessage = failures.count == 1
            ? "\"\(failures[0])\" could not be deleted."
            : "\(failures.count) items could not be deleted."
    }

    func move(_ entries: [FileManagerEntry], to destinationDirectory: URL) {
        transfer(entries, to: destinationDirectory, verb: "moved") { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func copy(_ entries: [FileManagerEntry], to destinationDirectory: URL) {
        transfer(entries, to: destinationDirectory, verb: "copied") { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func transfer(
        _ entries: [FileManagerEntry],
        to destinationDirectory: URL,
        verb: String,
        operation: (URL, URL) throws -> Void
    ) {
        var failures: [String] = []
        for entry in entries {
            // Never move/copy a folder into itself or one of its own descendants.
            if entry.isDirectory, isContained(destinationDirectory, within: entry.url) {
                failures.append(entry.name)
                continue
            }
            let destination = uniqueDestination(for: entry.name, in: destinationDirectory)
            do {
                try operation(entry.url, destination)
            } catch {
                failures.append(entry.name)
            }
        }
        guard !failures.isEmpty else { return }
        errorMessage = failures.count == 1
            ? "\"\(failures[0])\" could not be \(verb)."
            : "\(failures.count) items could not be \(verb)."
    }

    private func isContained(_ target: URL, within root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if targetPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix)
    }

    private func uniqueDestination(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidateName = name
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidateName).path) {
            candidateName = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        return directory.appendingPathComponent(candidateName)
    }
}

struct FileManagerEntry: Identifiable, Hashable {
    enum ArchiveKind {
        case zip
        case sevenZip
    }

    let url: URL
    let isDirectory: Bool
    let size: Int
    let modificationDate: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var archiveKind: ArchiveKind? {
        guard !isDirectory else { return nil }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "7z": return .sevenZip
        default: return nil
        }
    }

    var isArchive: Bool { archiveKind != nil }

    /// Whether tapping this entry should open the in-place text editor
    /// rather than QuickLook. Only extensions with a registered `UTType`
    /// conforming to `.text` qualify — an extension-less file (`README`,
    /// `Dockerfile`) falls back to QuickLook rather than guessing.
    var isTextEditable: Bool {
        guard !isDirectory, !url.pathExtension.isEmpty else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .text)
    }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        self.isDirectory = values?.isDirectory ?? false
        self.size = values?.fileSize ?? 0
        self.modificationDate = values?.contentModificationDate
    }
}
