import Foundation

/// A fully parsed HTTP/1.1 request line and header section. Bodies are not modeled:
/// v0.1 only supports GET/HEAD, neither of which carries a request body.
///
/// `target` is the raw request-target token exactly as sent (e.g. `/a/b.html?x=1`).
/// It is not decoded, normalized, or validated here — only `SecurePathResolver`
/// (see `FileSystem/SecurePathResolver.swift`) is authorized to turn it into a
/// filesystem path, after a handler strips any query component.
struct HTTPRequest: Sendable, Equatable {
    let method: String
    let target: String
    let httpVersion: String
    let headers: HTTPHeaders
}
