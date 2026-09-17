import Foundation

/// The real `ServerService`: acquires scoped access to the selected folder
/// (and, v0.3, every currently-resolvable additional mount —
/// `docs/adr/0007-multiple-mounted-folders.md`) for the entire server
/// session, starts an `HTTPServer` rooted there, and — on `stop()` —
/// cancels the listener/connections before releasing all of that access.
/// `ServerCoordinator` owns exactly one of these; nothing else should
/// construct an `HTTPServer` directly for the app's own serving session.
@MainActor
final class LiveServerService: ServerService {
    enum ServiceError: Error, Equatable {
        case noFolderSelected
        case accessDenied
    }

    private let folders: FolderRootManager
    private let limits: HTTPServerLimits
    private var httpServer: HTTPServer?
    private var scopedURL: URL?
    /// Additional mounts' scoped URLs, keyed by mount name, for the
    /// current session only — a mount added/removed after `start()` has no
    /// effect until the next restart, same as `profile`/`credentials`.
    private var scopedMountURLs: [String: URL] = [:]
    private(set) var requestLog: RequestLog?

    init(folders: FolderRootManager, limits: HTTPServerLimits = .default) {
        self.folders = folders
        self.limits = limits
    }

    func start(profile: ServerProfile, credentials: ServerCredentials?) async throws -> UInt16 {
        guard httpServer == nil else {
            throw ServiceError.accessDenied
        }
        guard let scopedURL = folders.beginAccess() else {
            throw folders.selectedURL == nil ? ServiceError.noFolderSelected : ServiceError.accessDenied
        }

        // A mount whose scope can't be acquired right now is silently
        // skipped for this session, per the ADR, rather than failing the
        // whole server start over one bad mount.
        var scopedMountURLs: [String: URL] = [:]
        var mounts: [MountRouter.Mount] = []
        for mount in folders.additionalMounts {
            guard let mountURL = folders.beginAccess(forMountNamed: mount.name) else { continue }
            scopedMountURLs[mount.name] = mountURL
            // Additional mounts are read/download only regardless of
            // profile -- only allowDirectoryListing (browsing) follows it,
            // same as the primary. See the ADR for why.
            let mountHandler = StaticFileHandler(
                resolver: SecurePathResolver(root: mountURL),
                allowUploads: false,
                allowDirectoryListing: profile.allowsDirectoryListing,
                allowWebDAVWrites: false
            )
            mounts.append(MountRouter.Mount(name: mount.name, handler: mountHandler))
        }

        let resolver = SecurePathResolver(root: scopedURL)
        let log = RequestLog()
        let primaryHandler = StaticFileHandler(
            resolver: resolver,
            allowUploads: profile.allowsUploads,
            allowDirectoryListing: profile.allowsDirectoryListing,
            allowWebDAVWrites: profile.allowsWebDAVWrites
        )
        // Always MountRouter, even with zero additional mounts: it's a
        // provably exact pass-through to the primary handler in that case
        // (see Handlers/MountRouter.swift), so every session -- not just
        // ones that opt into multiple mounts -- exercises the same code
        // path this promise depends on.
        let router = MountRouter(primary: primaryHandler, additional: mounts)
        let server = HTTPServer(router: router, limits: limits, requestLog: log, credentials: credentials)
        do {
            let port = try await server.start()
            self.httpServer = server
            self.scopedURL = scopedURL
            self.scopedMountURLs = scopedMountURLs
            self.requestLog = log
            return port
        } catch {
            folders.endAccess(scopedURL)
            for (_, mountURL) in scopedMountURLs {
                folders.endAccess(mountURL)
            }
            throw error
        }
    }

    func stop() {
        guard let server = httpServer else { return }
        httpServer = nil
        requestLog = nil
        let urlToRelease = scopedURL
        scopedURL = nil
        let mountURLsToRelease = scopedMountURLs
        scopedMountURLs = [:]
        Task { @MainActor in
            await server.stop()
            if let urlToRelease {
                self.folders.endAccess(urlToRelease)
            }
            for (_, mountURL) in mountURLsToRelease {
                self.folders.endAccess(mountURL)
            }
        }
    }
}
