import Foundation

/// Dispatches by the request target's *first path component* between the
/// primary mount and any number of additional, named mounts (v0.3,
/// `docs/adr/0007-multiple-mounted-folders.md`) — the "secure namespace"
/// `docs/ROADMAP.md` names as a precondition for supporting more than one
/// shared folder. Each mount is a fully independent `StaticFileHandler`,
/// resolving through its own `SecurePathResolver`, so one mount's
/// containment check can never be satisfied by another mount's tree.
///
/// With zero additional mounts, every requirement below is a pure,
/// unconditional pass-through to `primary` — the exact same `HTTPRequest`/
/// path/etc. the caller supplied, never reconstructed — so a single-folder
/// session behaves exactly as it always has. `/` never resolves to a
/// mount: an empty first component always means "ask the primary."
struct MountRouter: HTTPRouter {
    struct Mount: Sendable {
        let name: String
        let handler: StaticFileHandler
    }

    let primary: StaticFileHandler
    let additional: [Mount]

    func route(_ request: HTTPRequest) -> HTTPResponse {
        guard let path = Self.path(fromTarget: request.target) else { return .badRequest() }
        guard let (name, rest) = Self.firstComponent(of: path), additional.contains(where: { $0.name == name }) else {
            return primary.route(request)
        }
        // A bare mount reference ("/name", no trailing slash) gets the same
        // redirect StaticFileHandler.route(_:) already gives any directory
        // request that doesn't end in "/", so the mount's own relative
        // links resolve correctly once the browser is actually at "/name/".
        guard !rest.isEmpty else {
            return .redirect(to: "/\(name)/")
        }
        return handler(named: name).route(Self.rewritten(request, subPath: rest))
    }

    func authorizeUpload(directoryPath: String) -> Bool {
        let (name, rewritten) = resolve(directoryPath)
        return handler(named: name).authorizeUpload(directoryPath: rewritten)
    }

    func authorizeUploadedFile(directoryPath: String, filename: String) -> URL? {
        let (name, rewritten) = resolve(directoryPath)
        return handler(named: name).authorizeUploadedFile(directoryPath: rewritten, filename: filename)
    }

    func authorizeZipDownload(directoryPath: String) -> Bool {
        let (name, rewritten) = resolve(directoryPath)
        return handler(named: name).authorizeZipDownload(directoryPath: rewritten)
    }

    func resolveZipEntries(directoryPath: String, names: [String]) -> [URL]? {
        let (name, rewritten) = resolve(directoryPath)
        return handler(named: name).resolveZipEntries(directoryPath: rewritten, names: names)
    }

    func routeWebDAVPropfind(path: String, depth: WebDAVDepth) -> HTTPResponse? {
        let (name, rewritten) = resolve(path)
        return handler(named: name).routeWebDAVPropfind(path: rewritten, depth: depth)
    }

    func routeWebDAVMkcol(path: String) -> HTTPResponse? {
        let (name, rewritten) = resolve(path)
        return handler(named: name).routeWebDAVMkcol(path: rewritten)
    }

    func routeWebDAVDelete(path: String) -> HTTPResponse? {
        let (name, rewritten) = resolve(path)
        return handler(named: name).routeWebDAVDelete(path: rewritten)
    }

    func routeWebDAVMove(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse? {
        webDAVCopyOrMove(sourcePath: sourcePath, destinationHeader: destinationHeader, overwrite: overwrite, isMove: true)
    }

    func routeWebDAVCopy(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse? {
        webDAVCopyOrMove(sourcePath: sourcePath, destinationHeader: destinationHeader, overwrite: overwrite, isMove: false)
    }

    func authorizeWebDAVPut(path: String) -> WebDAVPutAuthorization? {
        let (name, rewritten) = resolve(path)
        return handler(named: name).authorizeWebDAVPut(path: rewritten)
    }

    func routePHPScript(_ request: HTTPRequest) async -> HTTPResponse? {
        guard let path = Self.path(fromTarget: request.target) else { return nil }
        guard let (name, rest) = Self.firstComponent(of: path), additional.contains(where: { $0.name == name }) else {
            return await primary.routePHPScript(request)
        }
        // A bare mount reference has no PHP file to run -- route(_:) is
        // what issues the same redirect this gets for a plain static
        // request, so just decline here and let that path handle it.
        guard !rest.isEmpty else { return nil }
        return await handler(named: name).routePHPScript(Self.rewritten(request, subPath: rest))
    }

    /// `MOVE`/`COPY` never cross mounts: the `Destination` header is
    /// resolved to a mount the same way the source path is, and anything
    /// other than "both the same mount" (primary included) is `409`
    /// before either mount's own handler is asked to do anything.
    private func webDAVCopyOrMove(sourcePath: String, destinationHeader: String?, overwrite: Bool, isMove: Bool) -> HTTPResponse? {
        guard let destinationPath = WebDAVDestinationHeaderParser.path(from: destinationHeader) else {
            return .badRequest("Destination header is required")
        }
        let (sourceName, sourceRewritten) = resolve(sourcePath)
        let (destinationName, destinationRewritten) = resolve(destinationPath)
        guard sourceName == destinationName else {
            return .conflict()
        }
        let target = handler(named: sourceName)
        return isMove
            ? target.routeWebDAVMove(sourcePath: sourceRewritten, destinationHeader: destinationRewritten, overwrite: overwrite)
            : target.routeWebDAVCopy(sourcePath: sourceRewritten, destinationHeader: destinationRewritten, overwrite: overwrite)
    }

    /// `nil` name means the path belongs to the primary mount — either its
    /// first component didn't match any additional mount's name, or the
    /// path was "/" with no component at all. `rewrittenPath` is always
    /// what that mount's own handler should see: unchanged for the
    /// primary, with the name segment stripped (and defaulted to "/" for
    /// the mount's own root) for an additional mount.
    private func resolve(_ path: String) -> (name: String?, rewrittenPath: String) {
        guard let (name, rest) = Self.firstComponent(of: path), additional.contains(where: { $0.name == name }) else {
            return (nil, path)
        }
        return (name, rest.isEmpty ? "/" : rest)
    }

    private func handler(named name: String?) -> StaticFileHandler {
        guard let name, let mount = additional.first(where: { $0.name == name }) else { return primary }
        return mount.handler
    }

    /// Splits a leading "/name" off `path`. `rest` is the empty string
    /// when nothing follows the name at all (a bare "/name", no trailing
    /// slash) — every caller decides for itself what that means (`route(_:)`
    /// redirects; every other requirement here treats it as that mount's
    /// own root, "/"). `nil` for "/" itself (no component to match) or any
    /// path not starting with "/".
    private static func firstComponent(of path: String) -> (name: String, rest: String)? {
        guard path.hasPrefix("/") else { return nil }
        let trimmed = path.dropFirst()
        guard !trimmed.isEmpty else { return nil }
        guard let slashIndex = trimmed.firstIndex(of: "/") else {
            return (String(trimmed), "")
        }
        return (String(trimmed[..<slashIndex]), String(trimmed[slashIndex...]))
    }

    /// Strips any query string from the raw request-target, same as
    /// `StaticFileHandler`'s own helper (duplicated rather than shared:
    /// this one only ever needs to look at the first path component, never
    /// resolve anything).
    private static func path(fromTarget target: String) -> String? {
        guard !target.isEmpty else { return nil }
        guard let queryIndex = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<queryIndex])
    }

    /// Rebuilds the request with `subPath` (already mount-relative) as its
    /// target, preserving the original query string, if any.
    private static func rewritten(_ request: HTTPRequest, subPath: String) -> HTTPRequest {
        let query: String
        if let queryIndex = request.target.firstIndex(of: "?") {
            query = String(request.target[queryIndex...])
        } else {
            query = ""
        }
        return HTTPRequest(method: request.method, target: subPath + query, httpVersion: request.httpVersion, headers: request.headers)
    }
}
