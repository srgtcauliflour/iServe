import XCTest
@testable import iServe

/// Drives `HTTPServer`/`StaticFileHandler`'s new PHP dispatch path (v0.4,
/// `docs/adr/0009-php-runtime-feasibility.md`) over loopback with a fake
/// `PHPScriptExecutor` — no PHP bridge/runtime involved at all, since
/// `PHPScriptExecutor`/`PHPRequest`/`PHPResponse` live in `ServerCore/`
/// with no dependency on it (see that file's doc comment). This is what
/// actually exercises `StaticFileHandler.routePHPScript`,
/// `MountRouter.routePHPScript`, and `HTTPConnection`'s PHP-first GET/HEAD/POST
/// dispatch on every `ios.yml` run — `PHP/Bridge`'s own integration test
/// (`PHP/Bridge/Tests/iserve_bridge_smoke_test.c`) proves the *bridge*
/// works, this proves the *wiring into the HTTP pipeline* works.
final class PHPScriptExecutionLifecycleTests: XCTestCase {
    func testExecutesPHPFileThroughRealServerAndMapsRequestFields() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<?php echo 'unused, the fake executor never actually reads this';"
            .write(to: root.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(
            statusCode: 201,
            headers: [(name: "X-Fake-PHP", value: "1")],
            body: Data("hello from fake PHP".utf8)
        )))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(
            from: loopbackURL(port: port, path: "/index.php?greeting=hi")
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Fake-PHP"), "1")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello from fake PHP")

        // XCTUnwrap's parameter is a plain (non-async) autoclosure, so the
        // `await` has to happen in a separate statement first -- it can't
        // be evaluated inside XCTUnwrap's own closure.
        let lastRequest = await executor.lastRequest
        let recorded = try XCTUnwrap(lastRequest)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.queryString, "greeting=hi")
        XCTAssertEqual(recorded.scriptFilename, root.appendingPathComponent("index.php").path)
        XCTAssertEqual(recorded.documentRoot, root.path)

        await server.stop()
    }

    /// ADR-0009's capability gating: a `.php` file must round-trip as an
    /// ordinary static file — never executed, same "hide the capability"
    /// convention `allowUploads`/`allowDirectoryListing` already use —
    /// whenever the toggle is off, even with a real executor available.
    func testPHPFileServedAsPlainStaticTextWhenExecutionDisabled() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "<?php echo 'should never run'; ?>"
        try source.write(to: root.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(statusCode: 200, headers: [], body: Data())))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: false,
            phpExecutor: executor
        ))
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/index.php"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), MIMEType.binaryFallback)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), source)
        let recorded = await executor.lastRequest
        XCTAssertNil(recorded, "the executor must never be invoked while the capability is off")

        await server.stop()
    }

    func testPHPExecutorFailureMapsToInternalServerErrorWithoutLeakingDetail() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<?php".write(to: root.appendingPathComponent("broken.php"), atomically: true, encoding: .utf8)

        let executor = FakePHPExecutor(behavior: .failure(.boom))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/broken.php"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 500)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("boom"))

        await server.stop()
    }

    /// Every non-`.php` request must never even reach the executor -- proves
    /// `routePHPScript`'s extension check, not just that ordinary static
    /// serving still works (already covered by `StaticFileServingLifecycleTests`).
    func testNonPHPFileNeverReachesTheExecutor() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "plain text".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(statusCode: 418, headers: [], body: Data())))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/notes.txt"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "plain text")
        let recorded = await executor.lastRequest
        XCTAssertNil(recorded)

        await server.stop()
    }

    func testMissingPHPFileFallsThroughToOrdinary404() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(statusCode: 200, headers: [], body: Data())))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        let (_, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/missing.php"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        let recorded = await executor.lastRequest
        XCTAssertNil(recorded)

        await server.stop()
    }

    /// Proves `HTTPConnection`'s PHP-POST buffering state machine
    /// (`beginPHPPost`/`processPHPPostBytes`/`finishPHPPostBody`) end to
    /// end: the whole body arrives at the executor as one `Data`, exactly
    /// as `php://input` would see it — decided (`isPHPScriptRequest`)
    /// before any body byte is read, same as `beginZipDownload`.
    func testExecutesPHPFileViaPOSTWithBufferedBody() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<?php".write(to: root.appendingPathComponent("submit.php"), atomically: true, encoding: .utf8)

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(
            statusCode: 200,
            headers: [],
            body: Data("ok".utf8)
        )))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/submit.php"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"name":"world"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")

        let lastRequest = await executor.lastRequest
        let recorded = try XCTUnwrap(lastRequest)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.contentType, "application/json")
        XCTAssertEqual(recorded.body, Data(#"{"name":"world"}"#.utf8))

        await server.stop()
    }

    /// An empty PHP POST body is valid (a script may be triggered by a
    /// bare POST with no content) -- unlike an empty ZIP-selection body,
    /// which `beginZipDownload` rejects outright.
    func testPHPPostWithEmptyBodyStillExecutes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<?php".write(to: root.appendingPathComponent("trigger.php"), atomically: true, encoding: .utf8)

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(statusCode: 204, headers: [], body: Data())))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/trigger.php"))
        request.httpMethod = "POST"
        // Explicit empty Data, not nil: ensures a deterministic
        // "Content-Length: 0" over the wire rather than depending on
        // URLSession's own behavior for a POST with no body set at all.
        request.httpBody = Data()
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)

        let lastRequest = await executor.lastRequest
        let recorded = try XCTUnwrap(lastRequest)
        XCTAssertEqual(recorded.body, Data())

        await server.stop()
    }

    /// A POST body over `limits.maxPHPPostBodyBytes` must be rejected
    /// before any of it is buffered, same discipline as every other
    /// bounded POST body this server accepts.
    func testPHPPostBodyOverLimitReturns413() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<?php".write(to: root.appendingPathComponent("submit.php"), atomically: true, encoding: .utf8)

        var limits = HTTPServerLimits.default
        limits.maxPHPPostBodyBytes = 4
        let executor = FakePHPExecutor(behavior: .success(PHPResponse(statusCode: 200, headers: [], body: Data())))
        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowPHPExecution: true, phpExecutor: executor),
            limits: limits
        )
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/submit.php"))
        request.httpMethod = "POST"
        request.httpBody = Data("this is more than four bytes".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
        let recorded = await executor.lastRequest
        XCTAssertNil(recorded)

        await server.stop()
    }

    /// A POST to a non-`.php` path must still reach the ordinary
    /// upload/ZIP-selection handling, never the executor -- proves
    /// `isPHPScriptRequest`'s extension check gates the POST path too, not
    /// just GET/HEAD (already covered by `testNonPHPFileNeverReachesTheExecutor`).
    func testNonPHPPostStillReachesUploadHandling() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = FakePHPExecutor(behavior: .success(PHPResponse(statusCode: 418, headers: [], body: Data())))
        let server = HTTPServer(router: StaticFileHandler(
            resolver: SecurePathResolver(root: root),
            allowUploads: true,
            allowPHPExecution: true,
            phpExecutor: executor
        ))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=x", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("--x--\r\n".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        // Whatever the upload path's own answer is, it must not be the
        // executor's 418 -- that's the thing under test here.
        XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 418)
        let recorded = await executor.lastRequest
        XCTAssertNil(recorded)

        await server.stop()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServePHPLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}

private actor FakePHPExecutor: PHPScriptExecutor {
    enum FakeError: Error, Sendable {
        case boom
    }

    enum Behavior: Sendable {
        case success(PHPResponse)
        case failure(FakeError)
    }

    private(set) var lastRequest: PHPRequest?
    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func execute(_ request: PHPRequest) async throws -> PHPResponse {
        lastRequest = request
        switch behavior {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}
