import Foundation

/// Parses an HTTP `Range` request header (RFC 7233 §2.1) for a single byte
/// range against a known resource size, so `Handlers/StaticFileHandler.swift`
/// can serve `206 Partial Content` — the basis for HTTP resumable downloads
/// (v0.3). Pure and independently testable, no filesystem/networking
/// involved.
///
/// Multi-range requests (`bytes=0-499,1000-1499`) are deliberately not
/// supported: RFC 7233 §3.1 explicitly permits a server to ignore any Range
/// header it doesn't implement and serve the full entity instead, which is
/// exactly what `.notRequested` tells the caller to do — a real error
/// response is reserved for a range this parser does understand but that's
/// genuinely out of bounds.
enum ByteRangeParser {
    /// An inclusive byte range already validated against a known file size.
    struct Range: Equatable {
        let start: Int
        /// Inclusive.
        let end: Int
        var length: Int { end - start + 1 }
    }

    enum Result: Equatable {
        /// No `Range` header, or one this parser doesn't understand (e.g.
        /// multiple ranges, malformed syntax) — serve the full entity.
        case notRequested
        case satisfiable(Range)
        /// A single-range request whose start is at or beyond the
        /// resource's size — respond `416 Range Not Satisfiable`.
        case unsatisfiable
    }

    static func parse(_ header: String?, fileSize: Int) -> Result {
        guard let header, header.hasPrefix("bytes=") else { return .notRequested }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return .notRequested }

        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .notRequested }
        let startText = parts[0]
        let endText = parts[1]

        guard fileSize > 0 else { return .unsatisfiable }

        if startText.isEmpty {
            // Suffix range: the last N bytes ("bytes=-500").
            guard let suffixLength = Int(endText), suffixLength > 0 else { return .notRequested }
            let start = max(0, fileSize - suffixLength)
            return .satisfiable(Range(start: start, end: fileSize - 1))
        }

        guard let start = Int(startText), start >= 0 else { return .notRequested }
        guard start < fileSize else { return .unsatisfiable }

        if endText.isEmpty {
            return .satisfiable(Range(start: start, end: fileSize - 1))
        }
        guard let end = Int(endText), end >= start else { return .notRequested }
        return .satisfiable(Range(start: start, end: min(end, fileSize - 1)))
    }
}
