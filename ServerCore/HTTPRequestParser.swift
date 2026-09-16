import Foundation

/// A bounded, incremental HTTP/1.1 request-line-and-headers parser.
///
/// Feed it bytes as they arrive from a connection, in any chunking. It has no
/// dependency on networking and does not read a request body (v0.1 only supports
/// GET/HEAD, which carry none), so it can be exercised directly by unit tests
/// without a live listener, per issue #4's acceptance criteria.
///
/// Every limit in `Limits` bounds the parser's own buffering: a client that never
/// sends a line terminator, sends an oversized line, or sends too many headers is
/// rejected with a typed error rather than being allowed to grow memory without end.
struct HTTPRequestParser {
    struct Limits: Sendable {
        var maxRequestLineLength: Int
        var maxHeaderLineLength: Int
        var maxHeaderCount: Int
        var maxTotalHeaderBytes: Int

        static let `default` = Limits(
            maxRequestLineLength: 8 * 1024,
            maxHeaderLineLength: 8 * 1024,
            maxHeaderCount: 100,
            maxTotalHeaderBytes: 32 * 1024
        )
    }

    enum ParseError: Error, Equatable {
        case requestLineTooLong
        case headerLineTooLong
        case tooManyHeaders
        case headerSectionTooLarge
        case malformedRequestLine
        case malformedHeaderLine
        case unsupportedVersion
    }

    private static let crlf = Data([0x0D, 0x0A])

    private let limits: Limits
    private var buffer = Data()
    private var requestLine: (method: String, target: String, version: String)?
    private var headers = HTTPHeaders()
    private var totalHeaderBytes = 0

    init(limits: Limits = .default) {
        self.limits = limits
    }

    /// Removes and returns whatever is left in the internal buffer once
    /// `feed(_:)` has returned a completed request. A client's write of
    /// "headers immediately followed by body" (routine for a POST) can
    /// land in the very same network read as the header-terminating blank
    /// line, so those leading body bytes are already sitting here — the
    /// caller must recover them before reading any more from the
    /// connection, or silently lose the start of the body. Only meaningful
    /// immediately after `feed(_:)` returns non-`nil`; the parser isn't
    /// reused afterward regardless.
    mutating func drainRemainder() -> Data {
        defer { buffer.removeAll() }
        return buffer
    }

    /// Appends newly received bytes and parses as many complete lines as are
    /// available. Returns the completed request once the blank line terminating
    /// the header section has been seen, or `nil` if more data is required.
    /// Throws immediately once any limit is exceeded or a line is malformed;
    /// the parser must not be reused after throwing.
    mutating func feed(_ data: Data) throws -> HTTPRequest? {
        buffer.append(data)

        while let range = buffer.firstRange(of: Self.crlf) {
            let line = buffer[buffer.startIndex..<range.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)

            if requestLine == nil {
                guard line.count <= limits.maxRequestLineLength else {
                    throw ParseError.requestLineTooLong
                }
                guard let text = String(bytes: line, encoding: .utf8) else {
                    throw ParseError.malformedRequestLine
                }
                requestLine = try Self.parseRequestLine(text)
                continue
            }

            if line.isEmpty {
                guard let requestLine else { throw ParseError.malformedRequestLine }
                return HTTPRequest(
                    method: requestLine.method,
                    target: requestLine.target,
                    httpVersion: requestLine.version,
                    headers: headers
                )
            }

            guard line.count <= limits.maxHeaderLineLength else {
                throw ParseError.headerLineTooLong
            }
            totalHeaderBytes += line.count
            guard totalHeaderBytes <= limits.maxTotalHeaderBytes else {
                throw ParseError.headerSectionTooLarge
            }
            try appendHeaderLine(line)
            guard headers.count <= limits.maxHeaderCount else {
                throw ParseError.tooManyHeaders
            }
        }

        // No terminator yet in the current line: still enforce its bound so a
        // client that withholds CRLF forever cannot grow the buffer unbounded.
        let ceiling = requestLine == nil ? limits.maxRequestLineLength : limits.maxHeaderLineLength
        guard buffer.count <= ceiling else {
            throw requestLine == nil ? ParseError.requestLineTooLong : ParseError.headerLineTooLong
        }
        return nil
    }

    private mutating func appendHeaderLine(_ line: Data) throws {
        guard let text = String(bytes: line, encoding: .utf8) else {
            throw ParseError.malformedHeaderLine
        }
        // Deliberately rejects obsolete line folding (a continuation line has no
        // colon): RFC 7230 requires senders not to use it, and a minimal bounded
        // parser rejecting it outright is simpler and safer than unfolding it.
        guard let separator = text.firstIndex(of: ":") else {
            throw ParseError.malformedHeaderLine
        }
        let name = String(text[text.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ParseError.malformedHeaderLine }
        headers.add(name: name, value: value)
    }

    private static func parseRequestLine(_ line: String) throws -> (method: String, target: String, version: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { throw ParseError.malformedRequestLine }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard !method.isEmpty, !target.isEmpty else { throw ParseError.malformedRequestLine }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw ParseError.unsupportedVersion
        }
        return (method, target, version)
    }
}
