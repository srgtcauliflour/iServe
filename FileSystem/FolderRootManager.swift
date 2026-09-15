import Foundation
import Observation

/// Owns the one user-approved root. Selecting/restoring validates only the root;
/// it does not enumerate content or authorize any remote request path.
@MainActor
@Observable
final class FolderRootManager {
    private(set) var selectedURL: URL?
    private(set) var errorMessage: String?
    private let access: any FolderAccess
    private var store: any FolderBookmarkStore

    init(access: any FolderAccess = SystemFolderAccess(),
         store: any FolderBookmarkStore = UserDefaultsFolderBookmarkStore()) {
        self.access = access
        self.store = store
    }

    var folderName: String? { selectedURL?.lastPathComponent }
    var hasSavedFolder: Bool { store.bookmark != nil }

    /// A failed replacement leaves the previously selected folder and bookmark intact.
    func select(_ url: URL) {
        do {
            let bookmark = try withScopedAccess(to: url) {
                try access.validateDirectory(url)
                return try access.makeBookmark(url)
            }
            store.bookmark = bookmark
            selectedURL = url
            errorMessage = nil
        } catch {
            errorMessage = "This folder could not be opened or saved. Choose it again in Files."
        }
    }

    /// Resolve again on retry; a provider can become available without discarding the bookmark.
    func restore() {
        guard let data = store.bookmark else { return }
        selectedURL = nil
        do {
            let resolved = try access.resolveBookmark(data)
            let refreshed: Data? = try withScopedAccess(to: resolved.url) {
                try access.validateDirectory(resolved.url)
                return resolved.stale ? try access.makeBookmark(resolved.url) : nil
            }
            if let refreshed { store.bookmark = refreshed }
            selectedURL = resolved.url
            errorMessage = nil
        } catch {
            errorMessage = "The saved folder is unavailable. Retry or choose the folder again in Files."
        }
    }

    func forget() {
        selectedURL = nil
        store.bookmark = nil
        errorMessage = nil
    }

    func reportPickerFailure(_ error: Error) {
        let cocoaError = error as NSError
        guard !(cocoaError.domain == NSCocoaErrorDomain &&
                cocoaError.code == CocoaError.Code.userCancelled.rawValue) else { return }
        errorMessage = "Files could not open the folder picker. Please try again."
    }

    private func withScopedAccess<T>(to url: URL, operation: () throws -> T) throws -> T {
        // Fail closed for externally selected roots. No filesystem operation is attempted
        // if the system cannot grant scope. Only a successful start requires a stop.
        guard url.isFileURL, access.startAccessing(url) else { throw FolderAccessError.accessDenied }
        defer { access.stopAccessing(url) }
        return try operation()
    }
}
