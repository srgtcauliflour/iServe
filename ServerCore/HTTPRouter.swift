import Foundation

/// The two `Depth` header values this server accepts for a WebDAV `PROPFIND`
/// request (v0.3, RFC 4918 §9.1, `docs/adr/0004-webdav-read-operations.md`).
/// `HTTPConnection` maps a missing/malformed header, or the RFC's own
/// "infinity" value, to `400` before a router ever sees the request: an
/// unbounded recursive tree walk has no place in this server's
/// bounded-operations design, and every `PROPFIND` client this server
/// targets already sends an explicit `Depth: 0`/`Depth: 1` to list one
/// directory at a time.
enum WebDAVDepth: Sendable, Equatable {
    /// Describe only the resource at the request path.
    case zero
    /// Describe the resource at the request path plus, if it's a directory,
    /// its immediate (non-hidden) children — never their own children.
    case one
}

/// What `HTTPConnection` needs to stream a WebDAV `PUT`'s body to disk
/// without ever risking an existing file (`docs/adr/0005-webdav-write-operations.md`):
/// bytes are written to `temporaryURL` (a hidden sibling of `destinationURL`,
/// so the final step is an atomic same-volume rename/replace) and only
/// replace `destinationURL` once every declared body byte has arrived
/// intact. `alreadyExists` decides the success status (`201`/`204`).
struct WebDAVPutAuthorization: Sendable {
    let destinationURL: URL
    let temporaryURL: URL
    let alreadyExists: Bool
}

/// Dispatches a parsed, method-supported request (GET/HEAD/POST/OPTIONS/
/// PROPFIND/MKCOL/PUT/DELETE/MOVE/COPY; `HTTPConnection` rejects everything
/// else with 501 before a router ever sees it) to a response.
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

    /// Whether `directoryPath` (always slash-terminated) can be packaged as
    /// a ZIP right now — essentially just that it resolves to an existing
    /// directory; unlike uploads this isn't a separate opt-in capability,
    /// since it exposes nothing a plain GET of the same files wouldn't
    /// already. Checked before any selection-body bytes are read.
    func authorizeZipDownload(directoryPath: String) -> Bool

    /// Resolves every selected name (as submitted by a directory listing's
    /// "Download Selected" form) against `directoryPath` into a filesystem
    /// URL, or `nil` to refuse the *whole* request if even one name fails
    /// to resolve — a traversal attempt, a name that no longer exists —
    /// rather than silently building an archive missing just that entry.
    func resolveZipEntries(directoryPath: String, names: [String]) -> [URL]?

    /// WebDAV `PROPFIND` (v0.3 read support, RFC 4918 §9.1,
    /// `docs/adr/0004-webdav-read-operations.md`). Unlike every other
    /// requirement here, the router builds and owns the *complete*
    /// response itself — status/error mapping included — exactly like
    /// `route(_:)`; `nil` means this router doesn't support WebDAV at all,
    /// which `HTTPConnection` maps to `501 Not Implemented`.
    func routeWebDAVPropfind(path: String, depth: WebDAVDepth) -> HTTPResponse?

    /// WebDAV `MKCOL` (v0.3 write support, `docs/adr/0005-webdav-write-operations.md`)
    /// — builds and owns the complete response itself, same shape as
    /// `routeWebDAVPropfind`.
    func routeWebDAVMkcol(path: String) -> HTTPResponse?

    /// WebDAV `DELETE`. Refuses (with whatever status the implementation
    /// chooses — this server uses `403`) to remove the served root itself.
    func routeWebDAVDelete(path: String) -> HTTPResponse?

    /// WebDAV `MOVE`. `destinationHeader` is the raw `Destination` header
    /// value (absolute URL or bare path); `overwrite` reflects the
    /// `Overwrite` header (`true` unless it was exactly `F`, per RFC 4918).
    func routeWebDAVMove(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse?

    /// WebDAV `COPY`. Same parameters as `routeWebDAVMove`.
    func routeWebDAVCopy(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse?

    /// Authorizes a WebDAV `PUT` before any body byte is read — same
    /// "decide everything up front" discipline as `authorizeUpload`, but
    /// `nil` here collapses every refusal reason (writes disabled, a
    /// resolver rejection, the target already being a directory, a missing
    /// parent) into one outcome, exactly like `authorizeUpload`/
    /// `authorizeUploadedFile` already do for uploads — `HTTPConnection`
    /// always responds `404` to any of them.
    func authorizeWebDAVPut(path: String) -> WebDAVPutAuthorization?

    /// Whether `request`'s target currently resolves to a `.php` file this
    /// session would execute right now — i.e. whether `routePHPScript(_:body:)`
    /// would actually run something rather than declining (`nil`). Checked
    /// by `HTTPConnection` before reading a single POST body byte, same
    /// "decide everything up front" discipline as `authorizeUpload`: a POST
    /// headed for PHP execution must never fall into the upload/ZIP-selection
    /// body reader by mistake. Cheap and side-effect-free — never executes
    /// anything itself, just answers the question.
    func isPHPScriptRequest(_ request: HTTPRequest) -> Bool

    /// PHP script execution (v0.4, `docs/adr/0009-php-runtime-feasibility.md`).
    /// `body` is the already-fully-read POST body, or `nil` for GET/HEAD,
    /// which carries none. `nil` return means this request isn't handled as
    /// PHP at all — the feature is off, no executor is wired up, or the
    /// resolved path isn't a `.php` file — in which case `HTTPConnection`
    /// falls back to `route(_:)`'s ordinary static-file handling (GET/HEAD)
    /// or the upload/ZIP-selection path (POST) exactly as if this method
    /// didn't exist. Unlike every other requirement here, this one is
    /// `async`: it may run an entire PHP script to completion before
    /// returning. The default implementation always returns `nil`, so
    /// `NotFoundRouter` and any router that doesn't override it stay
    /// PHP-incapable with no extra code — same convention `authorizeUpload`'s
    /// doc comment above describes for uploads.
    func routePHPScript(_ request: HTTPRequest, body: Data?) async -> HTTPResponse?
}

extension HTTPRouter {
    func authorizeUpload(directoryPath: String) -> Bool { false }
    func authorizeUploadedFile(directoryPath: String, filename: String) -> URL? { nil }
    func authorizeZipDownload(directoryPath: String) -> Bool { false }
    func resolveZipEntries(directoryPath: String, names: [String]) -> [URL]? { nil }
    func routeWebDAVPropfind(path: String, depth: WebDAVDepth) -> HTTPResponse? { nil }
    func routeWebDAVMkcol(path: String) -> HTTPResponse? { nil }
    func routeWebDAVDelete(path: String) -> HTTPResponse? { nil }
    func routeWebDAVMove(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse? { nil }
    func routeWebDAVCopy(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse? { nil }
    func authorizeWebDAVPut(path: String) -> WebDAVPutAuthorization? { nil }
    func isPHPScriptRequest(_ request: HTTPRequest) -> Bool { false }
    func routePHPScript(_ request: HTTPRequest, body: Data?) async -> HTTPResponse? { nil }
}

/// The v0.1 bootstrap router: no static handler exists yet, so every request
/// receives a plain 404. `HTTPServer` is otherwise fully functional without it.
struct NotFoundRouter: HTTPRouter {
    func route(_ request: HTTPRequest) -> HTTPResponse {
        .notFound()
    }
}
