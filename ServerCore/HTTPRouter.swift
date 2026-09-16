import Foundation

/// Dispatches a parsed, method-supported request (GET/HEAD; `HTTPConnection`
/// rejects everything else with 501 before a router ever sees it) to a response.
///
/// Issue #5 supplies the real implementation: strip any query string from
/// `request.target`, resolve the remaining path through `SecurePathResolver`,
/// and serve the result. No router may construct or open a filesystem path
/// itself; that stays the resolver's sole authority.
protocol HTTPRouter: Sendable {
    func route(_ request: HTTPRequest) -> HTTPResponse
}

/// The v0.1 bootstrap router: no static handler exists yet, so every request
/// receives a plain 404. `HTTPServer` is otherwise fully functional without it.
struct NotFoundRouter: HTTPRouter {
    func route(_ request: HTTPRequest) -> HTTPResponse {
        .notFound()
    }
}
