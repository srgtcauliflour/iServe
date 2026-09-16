import Foundation

/// Dispatches a parsed, method-supported request (GET/HEAD/POST;
/// `HTTPConnection` rejects everything else with 501 before a router ever
/// sees it) to a response.
///
/// Issue #5 supplies the real implementation: strip any query string from
/// `request.target`, resolve the remaining path through `SecurePathResolver`,
/// and serve the result. No router may construct or open a filesystem path
/// itself; that stays the resolver's sole authority.
///
/// `authorizeUpload`/`authorizeUploadedFile` (v0.2) exist because a POST
/// upload's body can be arbitrarily large and must stream straight to disk —
/// unlike `route(_:)`, `HTTPConnection` can't just call one synchronous
/// method and get a complete `HTTPResponse` back. It calls these instead,
/// before and during that streaming, to keep the same "no router constructs
/// or opens a path itself" rule for uploads too. The default implementations
/// refuse every upload, so `NotFoundRouter` and any future router that
/// doesn't override them stay upload-incapable with no extra code.
protocol HTTPRouter: Sendable {
    func route(_ request: HTTPRequest) -> HTTPResponse

    /// Whether `directoryPath` (always slash-terminated) accepts uploads
    /// right now — both that it resolves to an existing directory and that
    /// uploads are enabled for this session. Checked once, before any
    /// request body bytes are read.
    func authorizeUpload(directoryPath: String) -> Bool

    /// Resolves one multipart part's declared `filename` against
    /// `directoryPath` into the file URL to write it to, or `nil` to refuse
    /// just this part — a traversal attempt, an existing file this upload
    /// would silently overwrite, or any other resolver rejection — without
    /// failing the rest of the request.
    func authorizeUploadedFile(directoryPath: String, filename: String) -> URL?
}

extension HTTPRouter {
    func authorizeUpload(directoryPath: String) -> Bool { false }
    func authorizeUploadedFile(directoryPath: String, filename: String) -> URL? { nil }
}

/// The v0.1 bootstrap router: no static handler exists yet, so every request
/// receives a plain 404. `HTTPServer` is otherwise fully functional without it.
struct NotFoundRouter: HTTPRouter {
    func route(_ request: HTTPRequest) -> HTTPResponse {
        .notFound()
    }
}
