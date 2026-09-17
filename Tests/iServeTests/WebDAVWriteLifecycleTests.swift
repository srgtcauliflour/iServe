import XCTest
@testable import iServe

/// Drives a real `HTTPServer` with a real `StaticFileHandler` over loopback
/// for WebDAV `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY` (v0.3 write operations,
/// `docs/adr/0005-webdav-write-operations.md`) — proving the full pipeline
/// end to end, including the atomic temp-file-then-replace `PUT` strategy
/// and that every write method is refused (`404`) when
/// `allowWebDAVWrites` is off. Router-only authorization/status-mapping
/// edge cases live in `StaticFileHandlerTests.swift`; these are only the
/// cases that need an actual client/server round trip.
final class WebDAVWriteLifecycleTests: XCTestCase {
    func testMkcolCreatesADirectoryOverTheWire() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/newdir"))
        request.httpMethod = "MKCOL"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("newdir").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        await server.stop()
    }

    func testPutCreatesAFileOverTheWireAndReturns201() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/new.txt"))
        request.httpMethod = "PUT"
        request.httpBody = Data("hello world".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "hello world")

        // No leftover temporary file after a completed PUT.
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".iserve-put-") })

        await server.stop()
    }

    func testPutOverwritesAnExistingFileAndReturns204() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "original".write(to: root.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/existing.txt"))
        request.httpMethod = "PUT"
        request.httpBody = Data("replaced".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("existing.txt"), encoding: .utf8), "replaced")

        await server.stop()
    }

    func testPutExceedingTheSizeLimitReturns413AndWritesNothing() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = HTTPServerLimits.default
        limits.maxWebDAVPutBytes = 4

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true), limits: limits
        )
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/big.txt"))
        request.httpMethod = "PUT"
        request.httpBody = Data("this is more than four bytes".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("big.txt").path))

        await server.stop()
    }

    func testDeleteRemovesAFileOverTheWire() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/a.txt"))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

        await server.stop()
    }

    func testMoveRenamesAFileOverTheWireUsingTheDestinationHeader() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/a.txt"))
        request.httpMethod = "MOVE"
        request.setValue(loopbackURL(port: port, path: "/b.txt").absoluteString, forHTTPHeaderField: "Destination")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "a")

        await server.stop()
    }

    func testCopyDuplicatesAFileOverTheWireLeavingTheSourceInPlace() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/a.txt"))
        request.httpMethod = "COPY"
        request.setValue("/b.txt", forHTTPHeaderField: "Destination")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "a")

        await server.stop()
    }

    func testMoveWithOverwriteFalseRefusesAnExistingDestination() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/a.txt"))
        request.httpMethod = "MOVE"
        request.setValue("/b.txt", forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 412)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

        await server.stop()
    }

    func testEveryWriteMethodIsRefusedWhenWebDAVWritesAreDisabled() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        for method in ["MKCOL", "PUT", "DELETE", "MOVE", "COPY"] {
            var request = URLRequest(url: loopbackURL(port: port, path: "/a.txt"))
            request.httpMethod = method
            if method == "PUT" {
                request.httpBody = Data("x".utf8)
            }
            if method == "MOVE" || method == "COPY" {
                request.setValue("/b.txt", forHTTPHeaderField: "Destination")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404, "method: \(method)")
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "a")

        await server.stop()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeWebDAVWriteLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
