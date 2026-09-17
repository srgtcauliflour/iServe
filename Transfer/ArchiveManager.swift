import Foundation
import SWCompression
import ZIPFoundation

/// Creates and extracts ZIP archives, and extracts 7z archives, for the
/// in-app file manager (v0.3).
///
/// ZIPFoundation and SWCompression are the first third-party dependencies
/// this project has taken on — Apple has no first-party API for creating or
/// reading either archive format, and `AGENTS.md`'s "no arbitrary shell
/// execution" plus the iOS sandbox rule out shelling out to
/// `zip`/`unzip`/`7z`/`ditto`. RAR support was deliberately left out: every
/// available RAR library wraps the non-commercial-licensed `unrar` code,
/// which ZIPFoundation/SWCompression's permissive MIT/Apache-2.0 licensing
/// avoids entirely.
///
/// 7z support is extraction-only: SWCompression can read `.7z` containers
/// but cannot create them (no maintained permissively-licensed Swift library
/// does), and unlike ZIPFoundation's streaming reader, `SevenZipContainer`
/// requires the *entire* compressed archive and every extracted entry's
/// bytes in memory at once — there is no bounded/streaming 7z reader
/// available. This is a real (if usually small in practice, given app
/// sandbox storage limits) departure from this project's usual bounded-
/// streaming rule, accepted here because there is no alternative library.
///
/// Both extraction paths defend against "Zip Slip" independently of
/// whatever protection the underlying library applies: iServe already
/// accepts remote uploads, so a malicious client could upload a crafted
/// archive — containing an entry path like `../../Library/evil` or a
/// symlink entry — for a user to extract later via the file manager. Every
/// entry's destination is validated to stay within the extraction root the
/// same way `FileSystem/SecurePathResolver.swift` validates a remote
/// request path, and symlink (or other non-regular-file) entries are
/// refused outright rather than trusted.
enum ArchiveManager {
    /// SWCompression also declares a public `Archive` protocol
    /// (`Sources/Common/Archive.swift`), so ZIPFoundation's `Archive` class
    /// needs disambiguating wherever both modules are imported together.
    private typealias ZipArchive = ZIPFoundation.Archive

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
        /// A 7z entry is neither a regular file nor a directory (a hard link,
        /// device file, socket, FIFO, or an unrecognized type); iServe never
        /// materializes these from an archive.
        case entryTypeUnsupported
        /// The selection's total uncompressed size exceeds the caller's
        /// `maxUncompressedBytes` (v0.3, HTTP-triggered ZIP downloads) —
        /// aborted mid-walk rather than finishing an oversized archive.
        case selectionTooLarge
    }

    /// Creates a ZIP archive at `destination` containing each URL in `items`,
    /// preserving directory structure recursively. `destination` must not
    /// already exist; `items` may mix files and directories from the same
    /// parent folder. `maxUncompressedBytes` bounds the *sum* of every
    /// file's uncompressed size, checked as the selection is walked —
    /// callers packaging a request driven by a remote client (unlike the
    /// in-app file manager's own deliberate selections) should pass a real
    /// limit here.
    static func createArchive(containing items: [URL], at destination: URL, maxUncompressedBytes: Int = .max) throws {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: destination, accessMode: .create)
        } catch {
            throw ArchiveError.cannotCreateArchive
        }
        var totalBytes = 0
        for item in items {
            try addEntryRecursively(
                for: item, relativeTo: item.deletingLastPathComponent(), in: archive,
                totalBytes: &totalBytes, maxUncompressedBytes: maxUncompressedBytes
            )
        }
    }

    /// Extracts every entry of the archive at `source` into `destination`,
    /// which must already exist as a directory. Rejects the entire extraction
    /// — without writing any file — if any entry is a symlink or would
    /// resolve outside `destination`.
    static func extractArchive(at source: URL, to destination: URL) throws {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: source, accessMode: .read)
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

    /// Extracts every entry of the 7z archive at `source` into `destination`,
    /// which must already exist as a directory. Rejects the entire
    /// extraction — without writing any file — if any entry is anything
    /// other than a regular file or a directory, or would resolve outside
    /// `destination`. Loads the whole archive and every entry's decompressed
    /// bytes into memory at once — see this type's documentation.
    static func extractSevenZipArchive(at source: URL, to destination: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ArchiveError.cannotOpenArchive
        }
        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: data)
        } catch {
            throw ArchiveError.cannotOpenArchive
        }

        let root = destination.resolvingSymlinksInPath().standardizedFileURL
        for entry in entries {
            switch entry.info.type {
            case .directory, .regular, .contiguous:
                break
            default:
                throw ArchiveError.entryTypeUnsupported
            }
            // 7z entry names may use "\" as a separator on Windows-authored
            // archives; containedDestination only recognizes "/".
            let normalizedName = entry.info.name.replacingOccurrences(of: "\\", with: "/")
            let entryURL = try containedDestination(for: normalizedName, root: root)
            if entry.info.type == .directory {
                try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: entryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try (entry.data ?? Data()).write(to: entryURL)
            }
        }
    }

    // MARK: - Compression

    private static func addEntryRecursively(
        for url: URL, relativeTo base: URL, in archive: ZipArchive,
        totalBytes: inout Int, maxUncompressedBytes: Int
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ArchiveError.sourceItemMissing
        }
        guard isDirectory.boolValue else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            totalBytes += (attributes?[.size] as? Int) ?? 0
            guard totalBytes <= maxUncompressedBytes else { throw ArchiveError.selectionTooLarge }
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
            try addEntryRecursively(
                for: child, relativeTo: base, in: archive,
                totalBytes: &totalBytes, maxUncompressedBytes: maxUncompressedBytes
            )
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
