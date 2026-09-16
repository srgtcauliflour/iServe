import Foundation

/// The v0.1 static site/file router. Every path it serves comes from
/// `SecurePathResolver`; it never constructs or opens a filesystem path itself,
/// including for `index.html`/`index.htm` lookups, which are re-resolved through
/// the same resolver rather than appended and opened directly, so an index file
/// that happens to be a symlink is still subject to the root-containment check.
///
/// A directory with no index file gets a generated `DirectoryListingRenderer`
/// listing instead of `404`, matching Shu-parity directory browsing. A
/// directory request whose path doesn't already end in "/" is redirected to
/// the slash-terminated form first — required so the browser's relative links
/// (both the listing's own entries and any served page's own relative
/// asset/href URLs) resolve against the directory rather than its parent.
struct StaticFileHandler: HTTPRouter {
    private static let indexCandidates = ["index.html", "index.htm"]

    let resolver: SecurePathResolver

    func route(_ request: HTTPRequest) -> HTTPResponse {
        guard let path = Self.path(fromTarget: request.target) else { return .badRequest() }

        let resolved: URL
        do {
            resolved = try resolver.resolve(requestPath: path)
        } catch let error as SecurePathResolver.ResolutionError {
            return Self.response(for: error)
        } catch {
            return .internalServerError()
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return .notFound()
        }
        if isDirectory.boolValue {
            guard path.hasSuffix("/") else {
                return .redirect(to: path + "/")
            }
            return respondToDirectory(path: path, directoryURL: resolved)
        }
        return fileResponse(for: resolved)
    }

    /// `path` is guaranteed to end in "/" here: `route(_:)` redirects
    /// otherwise before this is ever called.
    private func respondToDirectory(path: String, directoryURL: URL) -> HTTPResponse {
        for candidate in Self.indexCandidates {
            guard let indexURL = try? resolver.resolve(requestPath: path + candidate) else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: indexURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return fileResponse(for: indexURL)
            }
        }
        return .html(DirectoryListingRenderer.render(directoryURL: directoryURL, requestPath: path))
    }

    private func fileResponse(for url: URL) -> HTTPResponse {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return .internalServerError()
        }
        return .file(url: url, length: size, contentType: MIMEType.forPathExtension(url.pathExtension))
    }

    /// Strips any query string from the raw request-target. Does not decode or
    /// otherwise validate the remaining path; `SecurePathResolver` owns that.
    private static func path(fromTarget target: String) -> String? {
        guard !target.isEmpty else { return nil }
        guard let queryIndex = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<queryIndex])
    }

    private static func response(for error: SecurePathResolver.ResolutionError) -> HTTPResponse {
        switch error {
        case .invalidRequestPath, .malformedEncoding, .invalidCharacter, .forbiddenComponent:
            return .badRequest()
        case .escapesRoot:
            return .forbidden()
        case .notFound:
            return .notFound()
        }
    }
}
