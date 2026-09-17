import Foundation

/// Either no body, a small in-memory body (status/error pages this core generates
/// itself), or a reference to an already-authorized local file for `HTTPConnection`
/// to stream in bounded chunks. Nothing in this type ever holds a whole file's
/// contents: per `AGENTS.md`, arbitrary-size payloads must stream, never load into
/// a single `Data` value.
enum HTTPResponseBody: Sendable, Equatable {
    case empty
    case data(Data)
    case file(HTTPFileBody)
}

/// A resolved, already-authorized local file, or a byte span of one. Only
/// `SecurePathResolver`-validated URLs may become one of these;
/// `HTTPConnection` opens and reads it through `Transfer/FileChunkReader.swift`
/// rather than loading it whole. `offset` is 0 and `length` is the whole
/// file's size for a normal `200` response; a `206 Partial Content` response
/// (v0.3 HTTP Range support — see `HTTPResponse.partialContent`) sets both
/// to the requested range instead, so `HTTPConnection` streams only that
/// span, never the whole file.
struct HTTPFileBody: Sendable, Equatable {
    let url: URL
    let offset: Int
    let length: Int
}

struct HTTPResponse: Sendable {
    var status: Int
    var reason: String
    var headers: HTTPHeaders
    var body: HTTPResponseBody

    static func plainText(status: Int, reason: String, message: String) -> HTTPResponse {
        let data = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(data.count))
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: status, reason: reason, headers: headers, body: .data(data))
    }

    /// `url`/`length` must already come from a successful `SecurePathResolver`
    /// resolution; this initializer does not itself validate or open the file.
    /// Always advertises `Accept-Ranges: bytes` — even this full-file response
    /// is what tells a client a later `Range` request (a resume, a video
    /// seek) will work; see `.partialContent`.
    static func file(url: URL, length: Int, contentType: String, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(length))
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(
            status: status, reason: reason, headers: headers,
            body: .file(HTTPFileBody(url: url, offset: 0, length: length))
        )
    }

    /// A single-range `206 Partial Content` response (v0.3 HTTP Range
    /// support, RFC 7233) for `range` — already validated by
    /// `Transfer/ByteRangeParser.swift` against the file's actual size,
    /// `fileSize`. `HTTPConnection` streams only `range`'s span of the file,
    /// via `HTTPFileBody.offset`/`.length`, never the whole thing.
    static func partialContent(url: URL, fileSize: Int, range: ByteRangeParser.Range, contentType: String) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(range.length))
        headers.add(name: "Content-Range", value: "bytes \(range.start)-\(range.end)/\(fileSize)")
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(
            status: 206, reason: "Partial Content", headers: headers,
            body: .file(HTTPFileBody(url: url, offset: range.start, length: range.length))
        )
    }

    /// A `416 Range Not Satisfiable` response naming the resource's actual
    /// `fileSize` (RFC 7233 §4.4), so a well-behaved client can retry
    /// without it rather than repeat the same unsatisfiable range.
    static func rangeNotSatisfiable(fileSize: Int) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Range", value: "bytes */\(fileSize)")
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: 416, reason: "Range Not Satisfiable", headers: headers, body: .empty)
    }

    /// A file offered as a download (`Content-Disposition: attachment`)
    /// rather than served for inline display/navigation — used for the
    /// generated ZIP a directory listing's "Download Selected" form
    /// produces (v0.3). `url`/`length` must already be a file this
    /// connection is authorized to stream, exactly like `.file(...)`.
    static func attachment(url: URL, length: Int, filename: String, contentType: String = "application/zip") -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(length))
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(Self.sanitizedFilename(filename))\"")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(
            status: 200, reason: "OK", headers: headers,
            body: .file(HTTPFileBody(url: url, offset: 0, length: length))
        )
    }

    /// Strips characters that would break out of the quoted
    /// `Content-Disposition` filename parameter or inject a header line.
    /// `filename` is server-derived (a directory name), never raw remote
    /// input, but this costs nothing and removes any doubt.
    private static func sanitizedFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// A `401 Unauthorized` response with `WWW-Authenticate: Basic`, so a
    /// browser shows its own native username/password prompt rather than
    /// the request just silently failing (v0.3, optional password
    /// protection — `ServerCore/ServerCredentials.swift`).
    static func unauthorized() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "WWW-Authenticate", value: "Basic realm=\"iServe\", charset=\"UTF-8\"")
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: 401, reason: "Unauthorized", headers: headers, body: .empty)
    }

    static func notImplemented(method: String) -> HTTPResponse {
        .plainText(status: 501, reason: "Not Implemented", message: "Unsupported method: \(method)")
    }

    static func badRequest(_ message: String = "Bad Request") -> HTTPResponse {
        .plainText(status: 400, reason: "Bad Request", message: message)
    }

    static func forbidden() -> HTTPResponse {
        .plainText(status: 403, reason: "Forbidden", message: "Forbidden")
    }

    static func notFound() -> HTTPResponse {
        .plainText(status: 404, reason: "Not Found", message: "Not Found")
    }

    static func uriTooLong() -> HTTPResponse {
        .plainText(status: 414, reason: "URI Too Long", message: "URI Too Long")
    }

    static func requestHeaderFieldsTooLarge() -> HTTPResponse {
        .plainText(status: 431, reason: "Request Header Fields Too Large", message: "Request Header Fields Too Large")
    }

    static func lengthRequired() -> HTTPResponse {
        .plainText(status: 411, reason: "Length Required", message: "Length Required")
    }

    static func payloadTooLarge() -> HTTPResponse {
        .plainText(status: 413, reason: "Payload Too Large", message: "Payload Too Large")
    }

    static func internalServerError() -> HTTPResponse {
        .plainText(status: 500, reason: "Internal Server Error", message: "Internal Server Error")
    }

    /// `location` must be a path relative to the server root (e.g. one this
    /// core generated itself, such as a directory request with an appended
    /// trailing slash) — never a value derived from unvalidated remote input.
    static func redirect(to location: String, status: Int = 301, reason: String = "Moved Permanently") -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: location)
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: status, reason: reason, headers: headers, body: .empty)
    }

    static func html(_ body: Data, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: status, reason: reason, headers: headers, body: .data(body))
    }

    /// A `207 Multi-Status` response for a successful WebDAV `PROPFIND`
    /// (v0.3, RFC 4918 §9.1 — see `Handlers/WebDAVResponseBuilder.swift` and
    /// `docs/adr/0004-webdav-read-operations.md`).
    static func webDAVMultiStatus(_ body: Data) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/xml; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: 207, reason: "Multi-Status", headers: headers, body: .data(body))
    }

    /// `OPTIONS` capability discovery (v0.3, WebDAV) — the same response for
    /// every path, since it never resolves or authorizes anything; a client
    /// uses this only to learn the server understands WebDAV before it
    /// tries `PROPFIND`. `Allow` names every method this server code
    /// understands regardless of whether the current session's profile
    /// actually authorizes it — same as any other server's `Allow` header
    /// describing what a resource/protocol supports rather than the
    /// caller's own permissions; a disallowed attempt still gets refused
    /// (`404`, per `docs/adr/0005-webdav-write-operations.md`'s "hide the
    /// capability" convention) when it's actually made.
    static func webDAVOptions() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Allow", value: "GET, HEAD, POST, OPTIONS, PROPFIND, MKCOL, PUT, DELETE, MOVE, COPY")
        headers.add(name: "DAV", value: "1")
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: 200, reason: "OK", headers: headers, body: .empty)
    }

    /// A bare `201 Created` — WebDAV `MKCOL`, or a `PUT`/`COPY`/`MOVE` whose
    /// destination didn't already exist (v0.3, `docs/adr/0005-webdav-write-operations.md`).
    static func created() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: 201, reason: "Created", headers: headers, body: .empty)
    }

    /// A bare `204 No Content` — WebDAV `DELETE`, or a `PUT`/`COPY`/`MOVE`
    /// whose destination already existed and was replaced (v0.3).
    static func noContent() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: 204, reason: "No Content", headers: headers, body: .empty)
    }

    /// `409 Conflict` — WebDAV `MKCOL`/`MOVE`/`COPY` refusing an operation
    /// that has no sound filesystem meaning right now (a missing
    /// intermediate parent, or moving/copying a directory into its own
    /// subtree; v0.3).
    static func conflict() -> HTTPResponse {
        .plainText(status: 409, reason: "Conflict", message: "Conflict")
    }

    /// `405 Method Not Allowed` — WebDAV `MKCOL` targeting a path that
    /// already exists; RFC 4918 §9.3.1 reserves `MKCOL` for an unmapped URL
    /// (v0.3).
    static func methodNotAllowed() -> HTTPResponse {
        .plainText(status: 405, reason: "Method Not Allowed", message: "Method Not Allowed")
    }

    /// `412 Precondition Failed` — a WebDAV `MOVE`/`COPY` with
    /// `Overwrite: F` whose destination already exists (v0.3).
    static func preconditionFailed() -> HTTPResponse {
        .plainText(status: 412, reason: "Precondition Failed", message: "Precondition Failed")
    }

    /// Renders the status line and header block, ending with the blank line that
    /// separates headers from the body. `HEAD` responses and the body's own bytes
    /// are handled by `HTTPConnection`; this method never encodes the body itself.
    func headEncoded() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for field in headers.fields {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }
}
