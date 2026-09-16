import Foundation

/// An in-memory HTTP/1.1 response. Every v0.1 response body originates from this
/// server core itself (status/error pages, `Connection: close` acknowledgements),
/// so a single bounded `Data` body is sufficient here.
///
/// Issue #5's static file handler must NOT reuse this type to hold arbitrary-size
/// file contents: per `AGENTS.md`, file bodies must stream in bounded chunks rather
/// than load a whole file into one `Data` value. That issue introduces its own
/// chunked body path through `HTTPConnection` rather than widening this struct.
struct HTTPResponse: Sendable {
    var status: Int
    var reason: String
    var headers: HTTPHeaders
    var body: Data

    static func plainText(status: Int, reason: String, message: String) -> HTTPResponse {
        let data = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(data.count))
        headers.add(name: "Connection", value: "close")
        return HTTPResponse(status: status, reason: reason, headers: headers, body: data)
    }

    static func notImplemented(method: String) -> HTTPResponse {
        .plainText(status: 501, reason: "Not Implemented", message: "Unsupported method: \(method)")
    }

    static func badRequest(_ message: String = "Bad Request") -> HTTPResponse {
        .plainText(status: 400, reason: "Bad Request", message: message)
    }

    static func notFound() -> HTTPResponse {
        .plainText(status: 404, reason: "Not Found", message: "Not Found")
    }

    /// Renders the status line and header block, ending with the blank line that
    /// separates headers from the body. `HEAD` responses omit the body entirely at
    /// the connection layer; this method never encodes the body itself.
    func headEncoded() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for field in headers.fields {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }
}
