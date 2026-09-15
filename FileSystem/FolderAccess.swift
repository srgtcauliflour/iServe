import Foundation

/// All provider operations run while the caller holds scoped access.
@MainActor
protocol FolderAccess {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func validateDirectory(_ url: URL) throws
    func makeBookmark(_ url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, stale: Bool)
}

@MainActor
struct SystemFolderAccess: FolderAccess {
    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }

    func validateDirectory(_ url: URL) throws {
        guard url.isFileURL,
              try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw FolderAccessError.notDirectory
        }
    }

    func makeBookmark(_ url: URL) throws -> Data {
        // iOS document-picker bookmarks do not use macOS-only .withSecurityScope.
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

enum FolderAccessError: Error {
    case accessDenied
    case notDirectory
}

@MainActor
protocol FolderBookmarkStore {
    var bookmark: Data? { get set }
}

@MainActor
final class UserDefaultsFolderBookmarkStore: FolderBookmarkStore {
    private let defaults: UserDefaults
    private let key = "iServe.selectedFolderBookmark"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var bookmark: Data? {
        get { defaults.data(forKey: key) }
        set {
            if let newValue { defaults.set(newValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}
