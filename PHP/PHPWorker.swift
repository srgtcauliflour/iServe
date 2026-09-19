import Foundation
import PHPBridge

/// Compiles and links only into the CI-only `iServeWithPHP` target (see
/// `PHP/README.md`) — the ordinary `iServe` target `ios.yml` builds and
/// ships never includes `PHP/` at all, per ADR-0009's isolation guarantee.
///
/// One request at a time, matching ADR-0009's single PHP-worker-actor
/// design: `iserve_php_execute` touches PHP's process-global interpreter
/// state, which is not safe to call from more than one place at once, even
/// from a thread-safe build used this way. Swift's actor isolation is what
/// enforces that serialization here — callers just `await` this actor's
/// `execute(_:)` like any other actor method, and the compiler guarantees
/// no two calls run at once.
public actor PHPWorker: PHPScriptExecutor {
    public enum WorkerError: Error {
        case alreadyStarted
        case notStarted
        /// `diagnostic` is for on-device diagnostics only (ADR-0009's
        /// "remote error behavior": it is never sent to an HTTP client).
        case startupFailed(diagnostic: String? = nil)
    }

    private var isStarted = false

    public init() {}

    /// Must be called exactly once, before any `execute(_:)` call.
    public func start(limits: PHPWorkerLimits) throws {
        guard !isStarted else { throw WorkerError.alreadyStarted }
        let result = limits.sessionSavePath.withCString { sessionSavePath in
            limits.uploadTmpDir.withCString { uploadTmpDir in
                iserve_php_bridge_startup(
                    Int32(limits.maxExecutionTimeSeconds),
                    limits.memoryLimitBytes,
                    sessionSavePath,
                    uploadTmpDir
                )
            }
        }
        guard result == 0 else { throw WorkerError.startupFailed() }
        isStarted = true
    }

    /// Must be called exactly once, after every in-flight `execute(_:)` call
    /// has returned, and never followed by another `start(limits:)` call in
    /// this process — PHP's own module shutdown is not designed to be
    /// re-entered. Intended to run from the app's termination path.
    public func shutdown() {
        guard isStarted else { return }
        iserve_php_bridge_shutdown()
        isStarted = false
    }

    public func execute(_ request: PHPRequest) throws -> PHPResponse {
        guard isStarted else { throw WorkerError.notStarted }

        // The C API only borrows these pointers for the duration of the
        // call (see PHP/Bridge/include/iserve_php_bridge.h) — strdup +
        // defer-free here mirrors that contract directly, rather than
        // nesting many `withCString` closures for what is otherwise a flat
        // list of independent, optional fields.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { for pointer in owned { free(pointer) } }
        func cString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(value)!
            owned.append(pointer)
            return pointer
        }
        func optionalCString(_ value: String?) -> UnsafeMutablePointer<CChar>? {
            guard let value else { return nil }
            return cString(value)
        }

        let bodyBytes = [UInt8](request.body ?? Data())

        // iserve_php_execute() memsets this to zero itself before writing
        // to it; these values just need to be *some* well-typed instance
        // for `&result` below — Clang's C-struct import has no zero-arg
        // initializer, only this full memberwise one.
        var result = iserve_php_result_t(
            status_code: 0,
            headers: nil,
            header_count: 0,
            body: nil,
            body_length: 0,
            startup_diagnostic: nil,
            diagnostic_log: nil
        )
        bodyBytes.withUnsafeBufferPointer { bodyPointer in
            var cRequest = iserve_php_request_t(
                method: UnsafePointer(cString(request.method)),
                uri: UnsafePointer(cString(request.uri)),
                query_string: UnsafePointer(optionalCString(request.queryString)),
                body: bodyPointer.baseAddress,
                body_length: bodyBytes.count,
                content_type: UnsafePointer(optionalCString(request.contentType)),
                remote_addr: UnsafePointer(optionalCString(request.remoteAddr)),
                cookie_header: UnsafePointer(optionalCString(request.cookieHeader)),
                script_filename: UnsafePointer(cString(request.scriptFilename)),
                document_root: UnsafePointer(cString(request.documentRoot))
            )
            iserve_php_execute(&cRequest, &result)
        }
        defer { iserve_php_free_result(&result) }

        if let diagnostic = result.startup_diagnostic {
            throw WorkerError.startupFailed(diagnostic: String(cString: diagnostic))
        }

        var headers: [(name: String, value: String)] = []
        if let items = result.headers {
            for index in 0..<result.header_count {
                let item = items[index]
                headers.append((
                    name: String(cString: item.name),
                    value: String(cString: item.value)
                ))
            }
        }

        let body: Data
        if let bodyPointer = result.body, result.body_length > 0 {
            body = Data(bytes: bodyPointer, count: result.body_length)
        } else {
            body = Data()
        }

        let diagnosticLog = result.diagnostic_log.map { String(cString: $0) }

        return PHPResponse(statusCode: Int(result.status_code), headers: headers, body: body, diagnosticLog: diagnosticLog)
    }
}

public struct PHPWorkerLimits: Sendable {
    public var maxExecutionTimeSeconds: Int
    public var memoryLimitBytes: Int
    /// Absolute path under the app's own container — never under a served
    /// folder, so a PHP session can't be listed/downloaded as if it were
    /// served content (ADR-0009's filesystem-restrictions section).
    public var sessionSavePath: String
    /// Absolute path under the app's own container, same reasoning as
    /// `sessionSavePath` — where a `$_FILES` upload's temporary file is
    /// written before a script `move_uploaded_file()`s it somewhere inside
    /// its own `open_basedir` (ADR-0009's filesystem-restrictions section).
    public var uploadTmpDir: String

    public init(maxExecutionTimeSeconds: Int, memoryLimitBytes: Int, sessionSavePath: String, uploadTmpDir: String) {
        self.maxExecutionTimeSeconds = maxExecutionTimeSeconds
        self.memoryLimitBytes = memoryLimitBytes
        self.sessionSavePath = sessionSavePath
        self.uploadTmpDir = uploadTmpDir
    }
}

// PHPRequest/PHPResponse/PHPScriptExecutor live in ServerCore/PHPScriptExecutor.swift
// — shared by every target, including the ordinary iServe target that
// never compiles this file at all. See that file's doc comment for why.
