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

    /// Acquires scoped access for the *currently* selected root and returns
    /// that exact URL, or `nil` if there is no selected root or access could
    /// not be granted. The caller — a server session — must retain this URL
    /// and pass it back to `endServingAccess(_:)` when done; a remembered URL
    /// alone is never proof that scope is currently held, and this call does
    /// not itself track whether access remains outstanding.
    func beginServingAccess() -> URL? {
        guard let selectedURL, access.startAccessing(selectedURL) else { return nil }
        return selectedURL
    }

    /// Releases scope previously granted by `beginServingAccess()` for `url`.
    /// Takes the exact URL that was scoped, not `selectedURL`, since the
    /// selection may have changed since access was acquired.
    func endServingAccess(_ url: URL) {
        access.stopAccessing(url)
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
