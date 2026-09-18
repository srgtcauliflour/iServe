import XCTest
@testable import iServe

/// Drives `HTTPServer`/`StaticFileHandler`'s new PHP dispatch path (v0.4,
/// `docs/adr/0009-php-runtime-feasibility.md`) over loopback with a fake
/// `PHPScriptExecutor` — no PHP bridge/runtime involved at all, since
/// `PHPScriptExecutor`/`PHPRequest`/`PHPResponse` live in `ServerCore/`
/// with no dependency on it (see that file's doc comment). This is what
/// actually exercises `StaticFileHandler.routePHPScript`,
/// `MountRouter.routePHPScript`, and `HTTPConnection`'s PHP-first GET/HEAD
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

        let recorded = try XCTUnwrap(await executor.lastRequest)
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
