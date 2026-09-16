import Foundation
import ZIPFoundation

/// Creates and extracts ZIP archives for the in-app file manager (v0.3).
///
/// ZIPFoundation is the first third-party dependency this project has taken on —
/// Apple has no first-party API for creating or reading ZIP archives, and
/// `AGENTS.md`'s "no arbitrary shell execution" plus the iOS sandbox rule out
/// shelling out to `zip`/`unzip`/`ditto`.
///
/// Extraction defends against "Zip Slip" independently of whatever protection
/// ZIPFoundation itself applies: iServe already accepts remote uploads, so a
/// malicious client could upload a crafted `.zip` — containing an entry path
/// like `../../Library/evil` or a symlink entry — for a user to extract later
/// via the file manager. Every entry's destination is validated to stay within
/// the extraction root the same way `FileSystem/SecurePathResolver.swift`
/// validates a remote request path, and symlink entries are refused outright
/// rather than trusted.
enum ArchiveManager {
    enum ArchiveError: Error, Equatable {
        /// The archive could not be opened for reading.
        case cannotOpenArchive
        /// The destination archive could not be created for writing.
        case cannotCreateArchive
        /// An item to compress no longer exists at the given URL.
        case sourceItemMissing
        /// An entry's path was empty, or a "."/".." component.
        case entryNameInvalid
        /// An entry's resolved destination would land outside the extraction root.
        case entryEscapesDestination
        /// An entry is a symlink; iServe never materializes archive symlinks on extract.
        case entrySymlinkRefused
    }

    /// Creates a ZIP archive at `destination` containing each URL in `items`,
    /// preserving directory structure recursively. `destination` must not
    /// already exist; `items` may mix files and directories from the same
    /// parent folder.
    static func createArchive(containing items: [URL], at destination: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: destination, accessMode: .create)
        } catch {
            throw ArchiveError.cannotCreateArchive
        }
        for item in items {
            try addEntryRecursively(for: item, relativeTo: item.deletingLastPathComponent(), in: archive)
        }
    }

    /// Extracts every entry of the archive at `source` into `destination`,
    /// which must already exist as a directory. Rejects the entire extraction
    /// — without writing any file — if any entry is a symlink or would
    /// resolve outside `destination`.
    static func extractArchive(at source: URL, to destination: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw ArchiveError.cannotOpenArchive
        }
        let root = destination.resolvingSymlinksInPath().standardizedFileURL
        for entry in archive {
            guard entry.type != .symlink else { throw ArchiveError.entrySymlinkRefused }
            let entryURL = try containedDestination(for: entry.path, root: root)
            _ = try archive.extract(entry, to: entryURL)
        }
    }

    // MARK: - Compression

    private static func addEntryRecursively(for url: URL, relativeTo base: URL, in archive: Archive) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ArchiveError.sourceItemMissing
        }
        guard isDirectory.boolValue else {
            try archive.addEntry(
                with: relativePath(of: url, relativeTo: base),
                relativeTo: base,
                compressionMethod: .deflate
            )
            return
        }
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard !children.isEmpty else {
            let path = relativePath(of: url, relativeTo: base) + "/"
            try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0), provider: { _, _ in Data() })
            return
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try addEntryRecursively(for: child, relativeTo: base, in: archive)
        }
    }

    private static func relativePath(of url: URL, relativeTo base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard fullPath.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(fullPath.dropFirst(prefix.count))
    }

    // MARK: - Extraction containment

    /// Walks `entryPath` one component at a time the same way
    /// `SecurePathResolver.resolve(requestPath:)` walks a decoded HTTP request
    /// target: any "."/".." component is rejected outright, and any component
    /// that already exists on disk (for example a directory created by an
    /// earlier entry in this same archive) is resolved through symlinks and
    /// re-checked before the next component is appended, so an intermediate
    /// symlink cannot smuggle a later entry outside `root`.
    private static func containedDestination(for entryPath: String, root: URL) throws -> URL {
        let components = entryPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw ArchiveError.entryNameInvalid }

        var current = root
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else {
                throw ArchiveError.entryEscapesDestination
            }
            current = current.appendingPathComponent(String(component))

            let isLast = index == components.count - 1
            if !isLast, FileManager.default.fileExists(atPath: current.path) {
                current = current.resolvingSymlinksInPath()
                guard isContained(current, within: root) else {
                    throw ArchiveError.entryEscapesDestination
                }
            }
        }

        let resolved = current.standardizedFileURL
        guard isContained(resolved, within: root) else {
            throw ArchiveError.entryEscapesDestination
        }
        return resolved
    }

    private static func isContained(_ target: URL, within root: URL) -> Bool {
        let rootPath = root.path
        let targetPath = target.path
        if targetPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix)
    }
}
