import Foundation
import Observation

/// One additional, read-only shared folder (v0.3,
/// `docs/adr/0007-multiple-mounted-folders.md`) — `name` is the unique,
/// validated path segment it's served under (`/<name>/...`).
struct AdditionalMount: Identifiable, Equatable, Sendable {
    let name: String
    let url: URL
    var id: String { name }
}

/// Owns the one primary user-approved root, plus (v0.3) any number of
/// additional, read-only mounted folders. Selecting/restoring validates
/// only the root; it does not enumerate content or authorize any remote
/// request path.
@MainActor
@Observable
final class FolderRootManager {
    private(set) var selectedURL: URL?
    private(set) var errorMessage: String?
    private(set) var additionalMounts: [AdditionalMount] = []
    private let access: any FolderAccess
    private var store: any FolderBookmarkStore
    private var mountStore: any MountBookmarkStore

    init(access: any FolderAccess = SystemFolderAccess(),
         store: any FolderBookmarkStore = UserDefaultsFolderBookmarkStore(),
         mountStore: any MountBookmarkStore = UserDefaultsMountBookmarkStore()) {
        self.access = access
        self.store = store
        self.mountStore = mountStore
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

    /// Adds `url` as a new additional mount (v0.3,
    /// `docs/adr/0007-multiple-mounted-folders.md`) — validated exactly
    /// like `select(_:)` validates the primary folder, with its own
    /// bookmark persisted entirely separately. Derives a unique name from
    /// the folder's own last path component (sanitized, and disambiguated
    /// with a `-2`/`-3`/... suffix against every existing mount name) —
    /// never against the primary folder's own name, since the primary
    /// serves at the bare root and has no name segment to collide with.
    func addMount(_ url: URL) {
        do {
            let bookmark = try withScopedAccess(to: url) {
                try access.validateDirectory(url)
                return try access.makeBookmark(url)
            }
            let name = Self.uniqueMountName(basedOn: url.lastPathComponent, avoiding: Set(additionalMounts.map(\.name)))
            var persisted = mountStore.mounts
            persisted.append(MountBookmark(name: name, bookmark: bookmark))
            mountStore.mounts = persisted
            additionalMounts.append(AdditionalMount(name: name, url: url))
            errorMessage = nil
        } catch {
            errorMessage = "This folder could not be opened or saved. Choose it again in Files."
        }
    }

    /// Forgets one additional mount for good — its persisted bookmark is
    /// deleted, unlike a mount `restoreMounts()` merely couldn't resolve
    /// this launch (which stays persisted for a future retry).
    func removeMount(named name: String) {
        additionalMounts.removeAll { $0.name == name }
        var persisted = mountStore.mounts
        persisted.removeAll { $0.name == name }
        mountStore.mounts = persisted
    }

    /// Re-resolves every persisted additional mount's bookmark — the
    /// multi-mount equivalent of `restore()`, meant to be called alongside
    /// it (e.g. `ServerDashboard`'s launch-time `.task`). A mount whose
    /// bookmark fails to resolve or no longer validates as a directory is
    /// silently dropped from `additionalMounts` for this launch rather than
    /// surfaced per-mount (`docs/adr/0007-multiple-mounted-folders.md`:
    /// "one bad mount shouldn't block everything else") — its persisted
    /// bookmark is left alone, so a later launch (the provider becoming
    /// available again) can still pick it back up; only
    /// `removeMount(named:)` forgets a mount for good.
    func restoreMounts() {
        var persisted = mountStore.mounts
        var resolved: [AdditionalMount] = []
        var didRefreshAny = false
        for index in persisted.indices {
            guard let outcome = resolvedMount(from: persisted[index]) else { continue }
            if let refreshedBookmark = outcome.refreshedBookmark {
                persisted[index] = MountBookmark(name: persisted[index].name, bookmark: refreshedBookmark)
                didRefreshAny = true
            }
            resolved.append(AdditionalMount(name: persisted[index].name, url: outcome.url))
        }
        if didRefreshAny { mountStore.mounts = persisted }
        additionalMounts = resolved
    }

    /// `nil` if the bookmark no longer resolves or no longer validates as a
    /// directory. `refreshedBookmark` is non-`nil` only when the resolved
    /// bookmark was stale and needed replacing — same "resolve, validate,
    /// refresh only if stale" shape as `restore()` uses for the primary.
    private func resolvedMount(from entry: MountBookmark) -> (url: URL, refreshedBookmark: Data?)? {
        guard let resolved = try? access.resolveBookmark(entry.bookmark) else { return nil }
        // A real `do`/`catch`, not `try?`: `withScopedAccess` here legitimately
        // returns `Data?` on success (`nil` meaning "not stale, no refresh
        // needed"), and `try?`'s flattening (SE-0230) would make that
        // indistinguishable from the call having thrown.
        do {
            let refreshed: Data? = try withScopedAccess(to: resolved.url) {
                try access.validateDirectory(resolved.url)
                return resolved.stale ? try access.makeBookmark(resolved.url) : nil
            }
            return (resolved.url, refreshed)
        } catch {
            return nil
        }
    }

    /// Acquires scoped access for the additional mount named `name` — same
    /// contract as `beginAccess()`, just for one additional mount instead
    /// of the primary. Release with `endAccess(_:)`, same as the primary.
    func beginAccess(forMountNamed name: String) -> URL? {
        guard let mount = additionalMounts.first(where: { $0.name == name }), access.startAccessing(mount.url) else {
            return nil
        }
        return mount.url
    }

    /// Same component-validity rules `SecurePathResolver` enforces for any
    /// path segment (non-empty, not "."/"..", no "/"/"\\", no control
    /// characters) — replaced with "_" rather than rejected outright,
    /// since a folder's own on-disk name isn't remote input to refuse.
    /// Disambiguated against `reserved` with a numeric suffix.
    private static func uniqueMountName(basedOn candidate: String, avoiding reserved: Set<String>) -> String {
        var sanitized = String(candidate.unicodeScalars.map { scalar -> Character in
            (scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\") ? "_" : Character(scalar)
        })
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = "Folder"
        }
        guard reserved.contains(sanitized) else { return sanitized }
        var suffix = 2
        while reserved.contains("\(sanitized)-\(suffix)") { suffix += 1 }
        return "\(sanitized)-\(suffix)"
    }

    /// Acquires scoped access for the *currently* selected root and returns
    /// that exact URL, or `nil` if there is no selected root or access could
    /// not be granted. The caller — a server session, `App/FileManagerScreen.swift`
    /// browsing the folder locally, or any other independent access holder —
    /// must retain this URL and pass it back to `endAccess(_:)` when done; a
    /// remembered URL alone is never proof that scope is currently held, and
    /// this call does not itself track whether access remains outstanding.
    /// Reentrant-safe to call from more than one caller at once: the
    /// underlying security-scoped access is itself reference-counted, so a
    /// server session and the file manager screen holding access
    /// simultaneously just means two independent counts, each released by
    /// its own matching `endAccess(_:)` call.
    func beginAccess() -> URL? {
        guard let selectedURL, access.startAccessing(selectedURL) else { return nil }
        return selectedURL
    }

    /// Releases scope previously granted by `beginAccess()` for `url`.
    /// Takes the exact URL that was scoped, not `selectedURL`, since the
    /// selection may have changed since access was acquired.
    func endAccess(_ url: URL) {
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
