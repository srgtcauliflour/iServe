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

/// A resolved, already-authorized local file. Only `SecurePathResolver`-validated
/// URLs may become one of these; `HTTPConnection` opens and reads it through
/// `Transfer/FileChunkReader.swift` rather than loading it whole.
struct HTTPFileBody: Sendable, Equatable {
    let url: URL
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
    static func file(url: URL, length: Int, contentType: String, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(length))
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: status, reason: reason, headers: headers, body: .file(HTTPFileBody(url: url, length: length)))
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
