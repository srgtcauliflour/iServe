import Foundation
import Observation

/// Backs the native in-app file manager screen (v0.3): browse the selected
/// root on-device, preview files, and create/extract ZIP archives — all
/// separate from the remote HTTP directory listing a browser client sees,
/// and independent of whether the server is running.
///
/// Holds its own scoped access to the selected root for the screen's
/// lifetime via `FolderRootManager.beginAccess()`/`endAccess(_:)`. This is
/// safe to hold at the same time `LiveServerService` holds its own access
/// for an active serving session — the underlying security-scoped access
/// is reference-counted, so the two are independent counts released by
/// their own matching calls.
@MainActor
@Observable
final class FileManagerViewModel {
    private let folders: FolderRootManager
    private(set) var rootURL: URL?
    private var scopedURL: URL?
    var previewURL: URL?
    var errorMessage: String?

    init(folders: FolderRootManager) {
        self.folders = folders
    }

    func start() {
        guard scopedURL == nil else { return }
        guard let url = folders.beginAccess() else {
            errorMessage = "Could not access the selected folder."
            return
        }
        scopedURL = url
        rootURL = url
    }

    func stop() {
        guard let scopedURL else { return }
        self.scopedURL = nil
        rootURL = nil
        folders.endAccess(scopedURL)
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

    /// Extracts `entry` (expected to be a `.zip` file) into a new sibling
    /// folder named after the archive, choosing a name that doesn't
    /// collide with an existing item. Cleans up the destination folder if
    /// extraction fails partway through, rather than leaving a partial
    /// extraction behind.
    func extractArchive(_ entry: FileManagerEntry, in directory: URL) {
        let baseName = (entry.name as NSString).deletingPathExtension
        let destination = uniqueDestination(for: baseName.isEmpty ? "Archive" : baseName, in: directory)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try ArchiveManager.extractArchive(at: entry.url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = "The archive could not be extracted. It may be corrupted or contain unsupported entries."
        }
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
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modificationDate: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isZipArchive: Bool { !isDirectory && url.pathExtension.lowercased() == "zip" }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        self.isDirectory = values?.isDirectory ?? false
        self.size = values?.fileSize ?? 0
        self.modificationDate = values?.contentModificationDate
    }
}
