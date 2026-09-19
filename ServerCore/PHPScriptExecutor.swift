import Foundation

/// PHP script execution (v0.4, `docs/adr/0009-php-runtime-feasibility.md`).
/// Declared here in `ServerCore/` — compiled into every build target,
/// including the ordinary `iServe` target that never links PHP at all —
/// rather than in `PHP/`, so `Handlers/StaticFileHandler.swift` can hold an
/// optional `(any PHPScriptExecutor)?` without ever needing to reference the
/// PHP bridge itself. `PHP/PHPWorker.swift` (only compiled into the CI-only
/// `iServeWithPHP` target — see `PHP/README.md`) is this protocol's one real
/// conformer; the ordinary `iServe` target simply never has anything to hand
/// `StaticFileHandler` here, so a `.php` file keeps round-tripping as a
/// plain static file exactly like before this existed.
public protocol PHPScriptExecutor: Sendable {
    /// Runs exactly one request to completion and maps its result back to
    /// an HTTP-shaped response. An implementation that serializes execution
    /// (ADR-0009's single PHP-worker-actor design) does so internally —
    /// callers just await this like any other async call, one at a time or
    /// concurrently, without needing to know that detail.
    func execute(_ request: PHPRequest) async throws -> PHPResponse
}

public struct PHPRequest: Sendable {
    public var method: String
    public var uri: String
    public var queryString: String?
    public var body: Data?
    public var contentType: String?
    public var remoteAddr: String?
    public var cookieHeader: String?
    /// Absolute path to the `.php` file to run.
    public var scriptFilename: String
    /// Absolute path this request's `open_basedir` is narrowed to — the
    /// same resolved root `SecurePathResolver` already computed for this
    /// session/mount (ADR-0009's filesystem-restrictions section).
    public var documentRoot: String

    public init(
        method: String,
        uri: String,
        queryString: String? = nil,
        body: Data? = nil,
        contentType: String? = nil,
        remoteAddr: String? = nil,
        cookieHeader: String? = nil,
        scriptFilename: String,
        documentRoot: String
    ) {
        self.method = method
        self.uri = uri
        self.queryString = queryString
        self.body = body
        self.contentType = contentType
        self.remoteAddr = remoteAddr
        self.cookieHeader = cookieHeader
        self.scriptFilename = scriptFilename
        self.documentRoot = documentRoot
    }
}

public struct PHPResponse: Sendable {
    public var statusCode: Int
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// Runtime warnings/notices/uncaught-exception messages this request
    /// logged (ADR-0009's `display_errors` is always off, so none of this
    /// ever reaches `body`) — `nil` when nothing was logged. On-device
    /// diagnostics only (`docs/ROADMAP.md`'s "PHP diagnostics console"
    /// deliverable, `Logging/PHPDiagnosticsLog.swift`); never forwarded to
    /// the HTTP client.
    public var diagnosticLog: String?

    public init(statusCode: Int, headers: [(name: String, value: String)], body: Data, diagnosticLog: String? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.diagnosticLog = diagnosticLog
    }
}
