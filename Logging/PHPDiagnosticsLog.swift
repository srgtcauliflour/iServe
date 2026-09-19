import Foundation

/// One PHP script's logged runtime diagnostic (a warning, notice, or
/// uncaught-exception fatal — `display_errors` is always off per
/// `docs/adr/0009-php-runtime-feasibility.md`, so none of this ever reaches
/// a remote client). Unlike `RequestLogEntry`, `message` is deliberately
/// NOT sanitized: this is an on-device-only surface for whoever is running
/// the server to debug their own script, so the real PHP error text
/// (which may include a local file path) is exactly what's useful here.
struct PHPDiagnosticEntry: Sendable, Identifiable, Equatable {
    let id: UUID
    let scriptPath: String
    let message: String
    let date: Date

    init(scriptPath: String, message: String, date: Date = Date()) {
        self.id = UUID()
        self.scriptPath = scriptPath
        self.message = message
        self.date = date
    }
}

/// Bounded, on-device-only log of PHP runtime diagnostics for one server
/// session — the ROADMAP's "PHP diagnostics console" deliverable's data
/// source. Mirrors `RequestLog`'s shape (bounded capacity, most-recent-first
/// snapshot) but holds unsanitized text, never surfaced to a remote client;
/// see `PHPDiagnosticEntry`'s own doc comment for why that's fine here.
actor PHPDiagnosticsLog {
    private var entries: [PHPDiagnosticEntry] = []
    private let capacity: Int

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    func record(scriptPath: String, message: String) {
        entries.append(PHPDiagnosticEntry(scriptPath: scriptPath, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Most-recent-first, for display.
    func snapshot() -> [PHPDiagnosticEntry] {
        Array(entries.reversed())
    }
}
