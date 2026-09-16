import Foundation

/// A bounded, incremental `multipart/form-data` parser (RFC 7578). Feed it
/// body bytes as they arrive from a connection, in any chunking — mirrors
/// `ServerCore/HTTPRequestParser.swift`'s incremental design and, like it,
/// has no dependency on networking.
///
/// Never buffers a whole part's body: each `feed(_:)` call returns
/// `.partBodyChunk` events for whatever is immediately available, holding
/// back only the small tail that might be the start of a boundary line
/// split across two reads. The caller (`ServerCore/HTTPConnection.swift`)
/// is what actually writes those chunks to disk as they arrive.
struct MultipartFormDataParser {
    enum Event: Equatable {
        /// A new part started. `filename` is `nil` for an ordinary form
        /// field (no `filename` parameter on `Content-Disposition`) —
        /// v0.1 uploads only care about file parts, so a caller should
        /// treat a `nil` filename the same as an authorization refusal:
        /// discard the part's body chunks rather than write them anywhere.
        case partBegan(fieldName: String, filename: String?)
        case partBodyChunk(Data)
        case partEnded
        /// The closing boundary (`--boundary--`) was seen. Any bytes fed
        /// afterward (a multipart "epilogue", or a client simply sending
        /// more than it declared) are ignored, not reported as an error.
        case finished
    }

    enum ParseError: Error, Equatable {
        /// The body didn't start with the expected `--boundary`, or a part
        /// delimiter wasn't followed by CRLF or `--` as required.
        case malformedDelimiter
        /// A part's header block wasn't valid UTF-8, or had no
        /// `Content-Disposition` naming a field.
        case malformedPartHeaders
    }

    private enum State: Equatable {
        case awaitingFirstBoundary
        case readingPartHeaders
        case readingPartBody
        /// A delimiter's `--boundary` token was just consumed; still need
        /// to see whether it's followed by `--` (final) or CRLF (into the
        /// next part's headers) before more of `feed`'s state machine can
        /// run — a separate state from `.readingPartBody` because by this
        /// point the delimiter itself is already gone from `buffer`, so
        /// re-searching for it again would be wrong.
        case awaitingDelimiterTerminator
        case finished
    }

    private static let crlf = Data([0x0D, 0x0A])
    private static let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private static let finalMarker = Data([0x2D, 0x2D]) // "--"

    /// The delimiter as it appears before the very first part: `--boundary`
    /// with nothing preceding it.
    private let openingDelimiter: Data
    /// The delimiter as it appears before every subsequent part, and at the
    /// end of a part's body: `CRLF--boundary`. The CRLF belongs to the
    /// delimiter, not the preceding part's content — RFC 2046 §5.1.
    private let delimiter: Data

    private var buffer = Data()
    private var state: State = .awaitingFirstBoundary

    init(boundary: String) {
        openingDelimiter = Data(("--" + boundary).utf8)
        delimiter = Self.crlf + openingDelimiter
    }

    /// Feeds newly received body bytes and returns the events they produce,
    /// in order. May return zero, one, or several events per call.
    mutating func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []

        parsing: while true {
            switch state {
            case .finished:
                break parsing

            case .awaitingFirstBoundary:
                guard let isFinal = try consumeOpeningDelimiter() else { break parsing }
                if isFinal {
                    state = .finished
                    events.append(.finished)
                    buffer.removeAll()
                } else {
                    state = .readingPartHeaders
                }

            case .readingPartHeaders:
                guard let headerRange = buffer.firstRange(of: Self.doubleCRLF) else { break parsing }
                let headerBytes = buffer[buffer.startIndex..<headerRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                let (fieldName, filename) = try Self.parsePartHeaders(headerBytes)
                events.append(.partBegan(fieldName: fieldName, filename: filename))
                state = .readingPartBody

            case .readingPartBody:
                if let range = buffer.firstRange(of: delimiter) {
                    let bodyChunk = buffer[buffer.startIndex..<range.lowerBound]
                    if !bodyChunk.isEmpty { events.append(.partBodyChunk(Data(bodyChunk))) }
                    events.append(.partEnded)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    state = .awaitingDelimiterTerminator
                } else {
                    // Emit everything except a tail that could be the start
                    // of a boundary split across this read and the next.
                    let safeCount = max(0, buffer.count - (delimiter.count - 1))
                    guard safeCount > 0 else { break parsing }
                    let chunk = buffer.prefix(safeCount)
                    events.append(.partBodyChunk(Data(chunk)))
                    buffer.removeFirst(safeCount)
                    break parsing
                }

            case .awaitingDelimiterTerminator:
                guard let isFinal = try consumeDelimiterTerminator() else { break parsing }
                if isFinal {
                    state = .finished
                    events.append(.finished)
                    buffer.removeAll()
                } else {
                    state = .readingPartHeaders
                }
            }
        }

        return events
    }

    // MARK: - Delimiter matching

    /// `buffer` is positioned at the very start of the body. Consumes
    /// `--boundary` plus whatever follows it (`--` or CRLF) once enough
    /// bytes are available; returns `nil` (consuming nothing) if not.
    private mutating func consumeOpeningDelimiter() throws -> Bool? {
        guard buffer.count >= openingDelimiter.count + 2 else { return nil }
        guard buffer.starts(with: openingDelimiter) else {
            throw ParseError.malformedDelimiter
        }
        buffer.removeFirst(openingDelimiter.count)
        return try consumeDelimiterTerminator()
    }

    /// `buffer` is positioned right after a delimiter's `--boundary` token.
    /// Consumes `--` (final) or CRLF (into the next part's headers) once
    /// enough bytes are available; returns `nil` (consuming nothing) if not.
    private mutating func consumeDelimiterTerminator() throws -> Bool? {
        guard buffer.count >= 2 else { return nil }
        if buffer.starts(with: Self.finalMarker) {
            buffer.removeFirst(2)
            return true
        }
        guard buffer.starts(with: Self.crlf) else {
            throw ParseError.malformedDelimiter
        }
        buffer.removeFirst(2)
        return false
    }

    // MARK: - Part header parsing

    private static func parsePartHeaders(_ data: some Sequence<UInt8>) throws -> (fieldName: String, filename: String?) {
        guard let text = String(bytes: Data(data), encoding: .utf8) else {
            throw ParseError.malformedPartHeaders
        }
        var fieldName: String?
        var filename: String?
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Content-Disposition") == .orderedSame else { continue }
            let value = String(line[line.index(after: colon)...])
            let parameters = Self.parseParameters(value)
            fieldName = parameters["name"]
            filename = parameters["filename"]
        }
        guard let fieldName else { throw ParseError.malformedPartHeaders }
        return (fieldName, filename)
    }

    /// Parses `key="value"; key2=value2`-style parameters from a
    /// `Content-Disposition` value. Unquoted values are accepted too, since
    /// not every client quotes them.
    private static func parseParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawParameter in value.split(separator: ";") {
            let parameter = rawParameter.trimmingCharacters(in: .whitespaces)
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[parameter.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var rawValue = String(parameter[parameter.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
                rawValue = String(rawValue.dropFirst().dropLast())
            }
            result[key] = rawValue
        }
        return result
    }
}
