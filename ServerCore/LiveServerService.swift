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
    private(set) var requestLog: RequestLog?

    init(folders: FolderRootManager, limits: HTTPServerLimits = .default) {
        self.folders = folders
        self.limits = limits
    }

    func start(allowUploads: Bool, credentials: ServerCredentials?) async throws -> UInt16 {
        guard httpServer == nil else {
            throw ServiceError.accessDenied
        }
        guard let scopedURL = folders.beginAccess() else {
            throw folders.selectedURL == nil ? ServiceError.noFolderSelected : ServiceError.accessDenied
        }

        let resolver = SecurePathResolver(root: scopedURL)
        let log = RequestLog()
        let router = StaticFileHandler(resolver: resolver, allowUploads: allowUploads)
        let server = HTTPServer(router: router, limits: limits, requestLog: log, credentials: credentials)
        do {
            let port = try await server.start()
            self.httpServer = server
            self.scopedURL = scopedURL
            self.requestLog = log
            return port
        } catch {
            folders.endAccess(scopedURL)
            throw error
        }
    }

    func stop() {
        guard let server = httpServer else { return }
        httpServer = nil
        requestLog = nil
        let urlToRelease = scopedURL
        scopedURL = nil
        Task { @MainActor in
            await server.stop()
            if let urlToRelease {
                self.folders.endAccess(urlToRelease)
            }
        }
    }
}
