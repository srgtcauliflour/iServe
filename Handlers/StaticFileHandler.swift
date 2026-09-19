import Foundation

/// The v0.1 static site/file router. Every path it serves comes from
/// `SecurePathResolver`; it never constructs or opens a filesystem path itself,
/// including for index-candidate lookups, which are re-resolved through
/// the same resolver rather than appended and opened directly, so an index file
/// that happens to be a symlink is still subject to the root-containment check.
///
/// A directory gets a generated `DirectoryListingRenderer` listing whenever
/// `allowDirectoryListing` is on, even if it contains an index file —
/// auto-serving an index page is reserved for `allowDirectoryListing ==
/// false` (`ServerProfile.websiteReadOnly`), the one mode meant for
/// presenting a site's own pages rather than browsing a folder; see
/// `respondToDirectory(path:directoryURL:request:)`. That resolution order
/// (v0.4, `resolvedIndexURL`) is `index.html`/`index.htm` > `index.php` >
/// the first `.html` file > the first `.php` file — an exact index wins
/// over a same-extension fallback, and HTML wins over PHP at each tier,
/// matching what a person locally testing a mixed HTML/PHP site expects. A
/// resolved `.php` index actually *executes* when PHP execution is on and
/// wired up (`resolvedPHPScriptURL`, checked before `route(_:)` ever runs);
/// this method only ever serves one statically, the same "hide the
/// capability" fallback a `.php` file already gets when reached directly.
/// A directory request whose path doesn't already end in "/" is redirected
/// to the slash-terminated form first — required so the browser's relative
/// links (both the listing's own entries and any served page's own
/// relative asset/href URLs) resolve against the directory rather than its
/// parent.
struct StaticFileHandler: HTTPRouter {
    private static let indexCandidates = ["index.html", "index.htm"]

    let resolver: SecurePathResolver
    /// Off by default: per `docs/SECURITY.md`, writes are an explicit
    /// capability, never implied just by selecting a folder to serve.
    var allowUploads: Bool = false
    /// On by default, matching every pre-v0.3-profiles behavior. Set to
    /// `false` for `ServerProfile.websiteReadOnly`: a directory now serves
    /// its `index.html`/`index.htm` if one exists, or a plain `404`
    /// otherwise, instead of a generated listing — Website mode is for
    /// serving a site's own pages, not for browsing whatever else is in
    /// the selected folder. When this is `true` (every other profile), a
    /// directory always shows the generated listing, even one containing
    /// an index file — that file is only ever reached by name, whether
    /// typed directly or clicked from the listing itself, never
    /// auto-served in place of browsing. Never gates a direct GET of
    /// a file whose name the client already knows, nor ZIP downloads — both
    /// stay bounded by what a client can already resolve, exactly as before.
    var allowDirectoryListing: Bool = true
    /// Off by default. Gates WebDAV `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY`
    /// (v0.3, `docs/adr/0005-webdav-write-operations.md`) — only
    /// `ServerProfile.fullAccess` sets this. Every refusal responds `404`,
    /// the same "hide the capability" convention `allowUploads`/
    /// `allowDirectoryListing` already use.
    var allowWebDAVWrites: Bool = false
    /// Off by default (`docs/adr/0009-php-runtime-feasibility.md`'s
    /// capability gating: PHP execution is an explicit, session-level
    /// toggle, orthogonal to `ServerProfile`, never implied just by a
    /// profile allowing directory listing). `phpExecutor` is `nil` for the
    /// ordinary `iServe` target, which never links the PHP bridge at all —
    /// in that build a `.php` file always round-trips as a plain static
    /// file, exactly like before this existed, regardless of this flag.
    var allowPHPExecution: Bool = false
    var phpExecutor: (any PHPScriptExecutor)? = nil
    /// Where a PHP response's `diagnosticLog` (a runtime warning/notice/
    /// uncaught-exception message `display_errors=0` kept out of the actual
    /// response) is recorded, plus a Swift-level `routePHPScript` failure —
    /// on-device only, never sent to the client. `nil` is a valid, silent
    /// no-op (matches every other optional collaborator on this type).
    var phpDiagnosticsLog: PHPDiagnosticsLog? = nil

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

    /// Shared resolution logic for both `isPHPScriptRequest`/`routePHPScript`:
    /// `nil` whenever this request shouldn't be handled as PHP at all — the
    /// capability is off, no executor is wired up, or resolution failed. A
    /// request that resolves directly to an existing `.php` file is always
    /// eligible; a request that resolves to a *directory* is only eligible
    /// when index resolution (`resolvedIndexURL`) picks a `.php` file for
    /// it — same Website-mode-only, trailing-slash-only rule
    /// `respondToDirectory` itself already follows, since index
    /// auto-serving (v0.4: now including a `.php` candidate) has always been
    /// scoped to that one mode. `route(_:)` deliberately re-resolves its own
    /// path rather than sharing this result: these are separate `HTTPRouter`
    /// requirements (see that protocol's doc comment) called *before*
    /// `route(_:)`, not a branch inside it, so the paths don't share call
    /// state.
    private func resolvedPHPScriptURL(for request: HTTPRequest) -> URL? {
        guard allowPHPExecution, phpExecutor != nil else { return nil }
        guard let path = Self.path(fromTarget: request.target) else { return nil }
        guard let resolved = try? resolver.resolve(requestPath: path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            guard !allowDirectoryListing, path.hasSuffix("/") else { return nil }
            guard let indexURL = resolvedIndexURL(forDirectoryPath: path, directoryURL: resolved),
                  indexURL.pathExtension.lowercased() == "php" else {
                return nil // no index, or an .html one -- route(_:) handles both
            }
            return indexURL
        }
        guard resolved.pathExtension.lowercased() == "php" else { return nil }
        return resolved
    }

    /// Directory-index resolution order (v0.4): an exact `index.html`/
    /// `index.htm`, then `index.php`, then the alphabetically-first `.html`
    /// file in the directory, then the alphabetically-first `.php` file —
    /// what a person locally testing a mixed HTML/PHP site would expect.
    /// `nil` means no index candidate exists at all. Every candidate is
    /// re-resolved through `resolver.resolve(requestPath:)` before being
    /// accepted, even the ones discovered by enumerating `directoryURL`'s
    /// own contents directly: that enumeration only ever produces a bare
    /// filename, never a path this method opens itself, so a symlink
    /// pointing outside the served root is still caught by the resolver's
    /// containment check, same as the fixed `index.html`/`index.htm`
    /// candidates already were before this method existed.
    private func resolvedIndexURL(forDirectoryPath path: String, directoryURL: URL) -> URL? {
        for candidate in Self.indexCandidates {
            if let url = existingFile(atRequestPath: path + candidate) {
                return url
            }
        }
        if let url = existingFile(atRequestPath: path + "index.php") {
            return url
        }
        if let name = Self.firstFilename(in: directoryURL, extension: "html"),
           let url = existingFile(atRequestPath: path + name) {
            return url
        }
        if let name = Self.firstFilename(in: directoryURL, extension: "php"),
           let url = existingFile(atRequestPath: path + name) {
            return url
        }
        return nil
    }

    private func existingFile(atRequestPath requestPath: String) -> URL? {
        guard let url = try? resolver.resolve(requestPath: requestPath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// The alphabetically-first (Finder-style, e.g. "2" before "10")
    /// filename directly inside `directoryURL` matching `extension`,
    /// skipping subdirectories and hidden files. A bare filename only —
    /// the caller re-resolves it through `existingFile(atRequestPath:)`
    /// before opening anything.
    private static func firstFilename(in directoryURL: URL, extension ext: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension.lowercased() == ext && !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
    }

    /// Checked by `HTTPConnection` before reading a POST body byte — see
    /// `HTTPRouter`'s doc comment for why. Side-effect-free.
    func isPHPScriptRequest(_ request: HTTPRequest) -> Bool {
        resolvedPHPScriptURL(for: request) != nil
    }

    /// `body` is the already-fully-read POST body (buffered by
    /// `HTTPConnection`'s own PHP-POST state machine, mirroring how it
    /// already buffers a ZIP-selection POST body — see that state machine's
    /// doc comment for why a PHP body is buffered rather than streamed to
    /// disk like an upload), or `nil` for GET/HEAD, which carries none.
    func routePHPScript(_ request: HTTPRequest, body: Data?) async -> HTTPResponse? {
        guard let resolved = resolvedPHPScriptURL(for: request), let phpExecutor else { return nil }
        let phpRequest = PHPRequest(
            method: request.method,
            uri: request.target,
            queryString: Self.queryString(fromTarget: request.target),
            body: body,
            contentType: request.headers["Content-Type"],
            cookieHeader: request.headers["Cookie"],
            scriptFilename: resolved.path,
            documentRoot: resolver.root.path
        )
        do {
            let response = try await phpExecutor.execute(phpRequest)
            if let diagnosticLog = response.diagnosticLog, !diagnosticLog.isEmpty {
                await phpDiagnosticsLog?.record(scriptPath: phpRequest.scriptFilename, message: diagnosticLog)
            }
            return Self.httpResponse(fromPHP: response)
        } catch {
            // The real failure reason is for on-device diagnostics only
            // (ADR-0009's "remote error behavior": display_errors is
            // always off) — never surfaced to the client beyond a generic 500.
            await phpDiagnosticsLog?.record(scriptPath: phpRequest.scriptFilename, message: "PHP executor failed: \(error)")
            return .internalServerError()
        }
    }

    /// `path` is guaranteed to end in "/" here: `route(_:)` redirects
    /// otherwise before this is ever called.
    ///
    /// An index file is only auto-served when directory listing is off
    /// (`ServerProfile.websiteReadOnly`) — that's the one mode meant for
    /// presenting a site's own pages rather than browsing a folder. Every
    /// other profile (File Sharing, File Drop, Full Access) always shows
    /// the generated listing here, even when the directory happens to
    /// contain an index candidate; a person browsing those modes still
    /// reaches that page the ordinary way, by clicking its entry in the
    /// listing, which resolves it as a plain file through `route(_:)`
    /// exactly like any other file.
    ///
    /// This only ever serves the resolved index *statically* — reached
    /// when PHP execution is off, no executor is wired up, or resolution
    /// picked an `.html` candidate. `resolvedPHPScriptURL` (called first,
    /// from `isPHPScriptRequest`/`routePHPScript`, before `route(_:)` ever
    /// runs) is what actually executes a resolved `.php` index instead of
    /// serving its source as text — see that method's doc comment.
    private func respondToDirectory(path: String, directoryURL: URL, request: HTTPRequest) -> HTTPResponse {
        guard allowDirectoryListing else {
            guard let indexURL = resolvedIndexURL(forDirectoryPath: path, directoryURL: directoryURL) else {
                return .notFound()
            }
            return fileResponse(for: indexURL, request: request)
        }
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

    // MARK: - WebDAV (v0.3 write operations)

    func routeWebDAVMkcol(path: String) -> HTTPResponse? {
        guard allowWebDAVWrites else { return .notFound() }
        let resolved: URL
        do {
            resolved = try resolver.resolve(requestPath: path)
        } catch let error as SecurePathResolver.ResolutionError {
            return Self.response(for: error)
        } catch {
            return .internalServerError()
        }
        // RFC 4918 §9.3.1: MKCOL only succeeds on an unmapped URL.
        guard !FileManager.default.fileExists(atPath: resolved.path) else {
            return .methodNotAllowed()
        }
        do {
            // Never auto-create intermediate collections — RFC 4918
            // forbids MKCOL from creating more than the one requested
            // collection; a missing parent already failed resolution above.
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: false)
        } catch {
            return .internalServerError()
        }
        return .created()
    }

    func routeWebDAVDelete(path: String) -> HTTPResponse? {
        guard allowWebDAVWrites else { return .notFound() }
        let resolved: URL
        do {
            resolved = try resolver.resolve(requestPath: path)
        } catch let error as SecurePathResolver.ResolutionError {
            return Self.response(for: error)
        } catch {
            return .internalServerError()
        }
        // Never delete the served root itself: that's the whole selected
        // folder disappearing out from under this session's scoped access.
        guard resolved != resolver.root else { return .forbidden() }
        guard FileManager.default.fileExists(atPath: resolved.path) else { return .notFound() }
        do {
            try FileManager.default.removeItem(at: resolved)
        } catch {
            return .internalServerError()
        }
        return .noContent()
    }

    func routeWebDAVMove(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse? {
        webDAVCopyOrMove(sourcePath: sourcePath, destinationHeader: destinationHeader, overwrite: overwrite, isMove: true)
    }

    func routeWebDAVCopy(sourcePath: String, destinationHeader: String?, overwrite: Bool) -> HTTPResponse? {
        webDAVCopyOrMove(sourcePath: sourcePath, destinationHeader: destinationHeader, overwrite: overwrite, isMove: false)
    }

    private func webDAVCopyOrMove(sourcePath: String, destinationHeader: String?, overwrite: Bool, isMove: Bool) -> HTTPResponse? {
        guard allowWebDAVWrites else { return .notFound() }
        guard let destinationPath = WebDAVDestinationHeaderParser.path(from: destinationHeader) else {
            return .badRequest("Destination header is required")
        }

        let sourceURL: URL
        do {
            sourceURL = try resolver.resolve(requestPath: sourcePath)
        } catch let error as SecurePathResolver.ResolutionError {
            return Self.response(for: error)
        } catch {
            return .internalServerError()
        }
        guard sourceURL != resolver.root else { return .forbidden() }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return .notFound() }

        let destinationURL: URL
        do {
            destinationURL = try resolver.resolve(requestPath: destinationPath)
        } catch let error as SecurePathResolver.ResolutionError {
            return Self.response(for: error)
        } catch {
            return .internalServerError()
        }
        guard destinationURL != resolver.root else { return .forbidden() }

        // Never move/copy a directory into its own subtree -- no sound
        // filesystem meaning (infinite nesting or a broken half-move/copy).
        var sourceIsDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory)
        if sourceIsDirectory.boolValue {
            let sourcePrefix = sourceURL.path.hasSuffix("/") ? sourceURL.path : sourceURL.path + "/"
            guard !(destinationURL.path + "/").hasPrefix(sourcePrefix) else { return .conflict() }
        }

        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
        guard !destinationExists || overwrite else { return .preconditionFailed() }

        // Same "no implicit intermediate creation" rule as MKCOL: the
        // destination's own parent must already exist as a directory.
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationURL.deletingLastPathComponent().path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            return .conflict()
        }

        do {
            if destinationExists {
                try FileManager.default.removeItem(at: destinationURL)
            }
            if isMove {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            return .internalServerError()
        }
        return destinationExists ? .noContent() : .created()
    }

    /// Authorizes a WebDAV `PUT` up front, exactly like `authorizeUpload`:
    /// writes must be enabled, the path must resolve, it must not already
    /// be an existing *directory* (a file may already exist -- unlike an
    /// upload, `PUT` is expected to overwrite), and the parent must already
    /// exist. `temporaryURL` is a hidden sibling of the real destination so
    /// `HTTPConnection` can stream the body there and only replace the real
    /// file with one atomic rename/replace once every byte has arrived --
    /// see `docs/adr/0005-webdav-write-operations.md`.
    func authorizeWebDAVPut(path: String) -> WebDAVPutAuthorization? {
        guard allowWebDAVWrites else { return nil }
        guard let destination = try? resolver.resolve(requestPath: path), destination != resolver.root else {
            return nil
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        guard !exists || !isDirectory.boolValue else { return nil }
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            return nil
        }
        let temporaryURL = parent.appendingPathComponent(".iserve-put-\(UUID().uuidString).tmp")
        return WebDAVPutAuthorization(destinationURL: destination, temporaryURL: temporaryURL, alreadyExists: exists)
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

    /// The raw text after "?" in `target`, undecoded (PHP's own `$_GET`
    /// parsing expects raw, url-encoded `QUERY_STRING`, same as any other
    /// SAPI) — `nil` when there's no "?" at all, "" for a bare trailing "?".
    private static func queryString(fromTarget target: String) -> String? {
        guard let queryIndex = target.firstIndex(of: "?") else { return nil }
        let afterQuestionMark = target.index(after: queryIndex)
        return afterQuestionMark < target.endIndex ? String(target[afterQuestionMark...]) : ""
    }

    /// Maps a PHP script's own status/headers/body onto this server's
    /// response type. Fills in `Content-Type`/`Content-Length` only if the
    /// script didn't already send its own — mirroring every other response
    /// factory in `HTTPResponse.swift`, PHP output is always a `Connection:
    /// close` response, matching this server's one-response-per-connection
    /// design (see `HTTPConnection`'s own doc comment).
    private static func httpResponse(fromPHP response: PHPResponse) -> HTTPResponse {
        var headers = HTTPHeaders()
        var sawContentType = false
        var sawContentLength = false
        for header in response.headers {
            headers.add(name: header.name, value: header.value)
            if header.name.caseInsensitiveCompare("Content-Type") == .orderedSame { sawContentType = true }
            if header.name.caseInsensitiveCompare("Content-Length") == .orderedSame { sawContentLength = true }
        }
        if !sawContentType {
            headers.add(name: "Content-Type", value: "text/html; charset=UTF-8")
        }
        if !sawContentLength {
            headers.add(name: "Content-Length", value: String(response.body.count))
        }
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(
            status: response.statusCode,
            reason: reasonPhrase(for: response.statusCode),
            headers: headers,
            body: .data(response.body)
        )
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default:
            switch status {
            case ..<300: "OK"
            case ..<400: "Redirect"
            case ..<500: "Client Error"
            default: "Server Error"
            }
        }
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
