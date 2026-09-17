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
    /// Off by default: per `docs/SECURITY.md`, writes are an explicit
    /// capability, never implied just by selecting a folder to serve.
    var allowUploads: Bool = false
    /// On by default, matching every pre-v0.3-profiles behavior. Set to
    /// `false` for `ServerProfile.websiteReadOnly`: a directory with no
    /// index file gets a plain `404` instead of a generated listing, since
    /// Website mode is for serving a site's own pages, not for browsing
    /// whatever else is in the selected folder. Never gates a direct GET of
    /// a file whose name the client already knows, nor ZIP downloads — both
    /// stay bounded by what a client can already resolve, exactly as before.
    var allowDirectoryListing: Bool = true

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
            return respondToDirectory(path: path, directoryURL: resolved, request: request)
        }
        return fileResponse(for: resolved, request: request)
    }

    /// `path` is guaranteed to end in "/" here: `route(_:)` redirects
    /// otherwise before this is ever called.
    private func respondToDirectory(path: String, directoryURL: URL, request: HTTPRequest) -> HTTPResponse {
        for candidate in Self.indexCandidates {
            guard let indexURL = try? resolver.resolve(requestPath: path + candidate) else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: indexURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return fileResponse(for: indexURL, request: request)
            }
        }
        guard allowDirectoryListing else { return .notFound() }
        return .html(DirectoryListingRenderer.render(directoryURL: directoryURL, requestPath: path, allowUploads: allowUploads))
    }

    // MARK: - WebDAV (v0.3 read operations)

    /// `path` is already query-stripped and need not end in "/" — unlike
    /// `route(_:)`, a WebDAV client `PROPFIND`s a path to *discover* whether
    /// it's a collection, so there's no trailing-slash redirect here; the
    /// response's own `href` supplies the canonical, slash-terminated form
    /// for a directory. See `docs/adr/0004-webdav-read-operations.md`.
    func routeWebDAVPropfind(path: String, depth: WebDAVDepth) -> HTTPResponse? {
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
            // Same "no browsing" rule as the HTML listing (ADR-0003):
            // PROPFIND on a directory is fundamentally an enumeration
            // operation, so it's refused the same way regardless of
            // whether an index file happens to live there.
            guard allowDirectoryListing else { return .notFound() }
            let href = path.hasSuffix("/") ? path : path + "/"
            var entries = [Self.webDAVCollectionEntry(at: resolved, href: href)]
            if depth == .one {
                entries += Self.webDAVChildEntries(of: resolved, parentHref: href)
            }
            return .webDAVMultiStatus(WebDAVResponseBuilder.multiStatus(entries: entries))
        }
        return .webDAVMultiStatus(WebDAVResponseBuilder.multiStatus(entries: [Self.webDAVFileEntry(at: resolved, href: path)]))
    }

    private static func webDAVCollectionEntry(at url: URL, href: String) -> WebDAVResponseBuilder.Entry {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return WebDAVResponseBuilder.Entry(
            href: href,
            isCollection: true,
            length: nil,
            lastModified: attributes?[.modificationDate] as? Date,
            contentType: nil,
            displayName: url.lastPathComponent
        )
    }

    private static func webDAVFileEntry(at url: URL, href: String) -> WebDAVResponseBuilder.Entry {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return WebDAVResponseBuilder.Entry(
            href: href,
            isCollection: false,
            length: attributes?[.size] as? Int,
            lastModified: attributes?[.modificationDate] as? Date,
            contentType: MIMEType.forPathExtension(url.pathExtension),
            displayName: url.lastPathComponent
        )
    }

    /// Depth-1 children only — never recurses into a child directory's own
    /// contents. Hidden entries (names starting with ".") are omitted, same
    /// as `DirectoryListingRenderer` and for the same reason
    /// (`docs/SECURITY.md`'s "no hidden/special metadata by default").
    private static func webDAVChildEntries(of directoryURL: URL, parentHref: String) -> [WebDAVResponseBuilder.Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { url -> WebDAVResponseBuilder.Entry? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            return WebDAVResponseBuilder.Entry(
                href: parentHref + encodedName + (isDirectory ? "/" : ""),
                isCollection: isDirectory,
                length: isDirectory ? nil : values?.fileSize,
                lastModified: values?.contentModificationDate,
                contentType: isDirectory ? nil : MIMEType.forPathExtension(url.pathExtension),
                displayName: name
            )
        }
    }

    // MARK: - ZIP downloads

    func authorizeZipDownload(directoryPath: String) -> Bool {
        guard let resolved = try? resolver.resolve(requestPath: directoryPath) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    func resolveZipEntries(directoryPath: String, names: [String]) -> [URL]? {
        var urls: [URL] = []
        var seen = Set<String>()
        for name in names {
            // Same "one atomic path component" rule as an uploaded filename:
            // this came from a checkbox value in our own rendered form, not
            // a browsable path, so it must never introduce path structure.
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\") else {
                return nil
            }
            guard seen.insert(name).inserted else { continue }
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let resolved = try? resolver.resolve(requestPath: directoryPath + encoded),
                  FileManager.default.fileExists(atPath: resolved.path) else {
                return nil
            }
            urls.append(resolved)
        }
        return urls.isEmpty ? nil : urls
    }

    // MARK: - Uploads

    func authorizeUpload(directoryPath: String) -> Bool {
        guard allowUploads else { return false }
        guard let resolved = try? resolver.resolve(requestPath: directoryPath) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    func authorizeUploadedFile(directoryPath: String, filename: String) -> URL? {
        guard allowUploads else { return nil }
        // Reject explicitly rather than rely solely on the resolver's own
        // traversal protection: a filename is meant to be one atomic path
        // component (what the browser showed the person picking a file),
        // never something that introduces extra path structure.
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else {
            return nil
        }
        guard let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        guard let resolved = try? resolver.resolve(requestPath: directoryPath + encodedFilename) else {
            return nil
        }
        // No destructive operations by default (docs/SECURITY.md): never
        // silently overwrite something already there.
        guard !FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// Honors a single-range `Range` request (v0.3, RFC 7233) via
    /// `Transfer/ByteRangeParser.swift`: `206` for a satisfiable range,
    /// `416` for one that's out of bounds, or the ordinary full `200`
    /// response for no `Range` header (or one this parser doesn't
    /// implement, e.g. multiple ranges — RFC 7233 §3.1 explicitly permits
    /// ignoring those rather than erroring).
    private func fileResponse(for url: URL, request: HTTPRequest) -> HTTPResponse {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return .internalServerError()
        }
        let contentType = MIMEType.forPathExtension(url.pathExtension)
        switch ByteRangeParser.parse(request.headers["Range"], fileSize: size) {
        case .notRequested:
            return .file(url: url, length: size, contentType: contentType)
        case .satisfiable(let range):
            return .partialContent(url: url, fileSize: size, range: range, contentType: contentType)
        case .unsatisfiable:
            return .rangeNotSatisfiable(fileSize: size)
        }
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
