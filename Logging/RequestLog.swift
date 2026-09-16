import Foundation

/// A single sanitized, bounded record of one completed request. Only ever
/// carries what the remote client's own request already exposed — method,
/// request target, response status, response byte count — never a local
/// filesystem path or other implementation detail.
struct RequestLogEntry: Sendable, Identifiable, Equatable {
    let id: UUID
    let method: String
    let path: String
    let status: Int
    let bytes: Int
    let date: Date

    init(method: String, path: String, status: Int, bytes: Int, date: Date = Date()) {
        self.id = UUID()
        self.method = method
        self.path = path
        self.status = status
        self.bytes = bytes
        self.date = date
    }
}

/// Bounded, sanitized request telemetry for one server session. Bounded to
/// `capacity` most-recent entries so a long-running session's memory use for
/// the log itself stays constant regardless of how many requests arrive;
/// `totalRequestCount`/`totalBytesTransferred` still count every request.
///
/// `bytes` reflects each response's declared/intended length (its
/// `Content-Length`), recorded when the response is dispatched — not bytes
/// actually confirmed delivered over the wire. A connection that drops
/// mid-stream is still counted at its full intended size; this is a known
/// v0.1 simplification for a dashboard counter, not a security-relevant
/// accounting guarantee.
actor RequestLog {
    struct Snapshot: Sendable {
        let entries: [RequestLogEntry]
        let totalRequests: Int
        let totalBytes: Int
    }

    private(set) var totalRequestCount = 0
    private(set) var totalBytesTransferred = 0
    private var entries: [RequestLogEntry] = []
    private let capacity: Int

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    func record(method: String, path: String, status: Int, bytes: Int) {
        totalRequestCount += 1
        totalBytesTransferred += bytes
        entries.append(RequestLogEntry(method: method, path: path, status: status, bytes: bytes))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Most-recent-first, for display.
    func snapshot() -> Snapshot {
        Snapshot(entries: Array(entries.reversed()), totalRequests: totalRequestCount, totalBytes: totalBytesTransferred)
    }
}
