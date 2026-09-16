import Foundation

/// The real `ServerService`: acquires scoped access to the selected folder for
/// the entire server session, starts an `HTTPServer` rooted there, and — on
/// `stop()` — cancels the listener/connections before releasing that access.
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

    init(folders: FolderRootManager, limits: HTTPServerLimits = .default) {
        self.folders = folders
        self.limits = limits
    }

    func start() async throws -> UInt16 {
        guard httpServer == nil else {
            throw ServiceError.accessDenied
        }
        guard let scopedURL = folders.beginServingAccess() else {
            throw folders.selectedURL == nil ? ServiceError.noFolderSelected : ServiceError.accessDenied
        }

        let resolver = SecurePathResolver(root: scopedURL)
        let server = HTTPServer(router: StaticFileHandler(resolver: resolver), limits: limits)
        do {
            let port = try await server.start()
            self.httpServer = server
            self.scopedURL = scopedURL
            return port
        } catch {
            folders.endServingAccess(scopedURL)
            throw error
        }
    }

    func stop() {
        guard let server = httpServer else { return }
        httpServer = nil
        let urlToRelease = scopedURL
        scopedURL = nil
        Task { @MainActor in
            await server.stop()
            if let urlToRelease {
                self.folders.endServingAccess(urlToRelease)
            }
        }
    }
}
