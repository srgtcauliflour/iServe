import XCTest
@testable import iServe

/// Drives a real `HTTPServer` with a real `StaticFileHandler` over loopback
/// for WebDAV `OPTIONS`/`PROPFIND` (v0.3 read operations,
/// `docs/adr/0004-webdav-read-operations.md`) — proving the full pipeline
/// end to end: `HTTPConnection`'s method dispatch ->
/// `StaticFileHandler.routeWebDAVPropfind(path:depth:)` ->
/// `Handlers/WebDAVResponseBuilder.swift` -> a real HTTP client using
/// custom methods and the `Depth` header.
final class WebDAVLifecycleTests: XCTestCase {
    func testOptionsAdvertisesWebDAVSupport() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/"))
        request.httpMethod = "OPTIONS"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "DAV"), "1")
        XCTAssertTrue((http.value(forHTTPHeaderField: "Allow") ?? "").contains("PROPFIND"))

        await server.stop()
    }

    func testPropfindDepthZeroOnAFileDescribesJustThatFile() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (body, response) = try await propfind(port: port, path: "/note.txt", depth: "0")
        XCTAssertEqual(response.statusCode, 207)
        let xml = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(xml.contains("<D:href>/note.txt</D:href>"))
        XCTAssertTrue(xml.contains("<D:getcontentlength>5</D:getcontentlength>"))
        XCTAssertFalse(xml.contains("<D:collection/>"))
        XCTAssertEqual(xml.components(separatedBy: "<D:response>").count - 1, 1)

        await server.stop()
    }

    func testPropfindDepthZeroOnADirectoryDescribesOnlyItself() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (body, response) = try await propfind(port: port, path: "/", depth: "0")
        XCTAssertEqual(response.statusCode, 207)
        let xml = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(xml.contains("<D:collection/>"))
        XCTAssertEqual(xml.components(separatedBy: "<D:response>").count - 1, 1)

        await server.stop()
    }

    func testPropfindDepthOneOnADirectoryListsImmediateChildrenOnly() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let subdirectory = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try "nested".write(to: subdirectory.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (body, response) = try await propfind(port: port, path: "/", depth: "1")
        XCTAssertEqual(response.statusCode, 207)
        let xml = String(decoding: body, as: UTF8.self)
        // Self + "a.txt" + "sub/" - never "sub"'s own nested.txt, and never
        // the dotfile.
        XCTAssertEqual(xml.components(separatedBy: "<D:response>").count - 1, 3)
        XCTAssertTrue(xml.contains("<D:href>/a.txt</D:href>"))
        XCTAssertTrue(xml.contains("<D:href>/sub/</D:href>"))
        XCTAssertFalse(xml.contains("nested.txt"))
        XCTAssertFalse(xml.contains(".hidden"))

        await server.stop()
    }

    func testPropfindWithoutADepthHeaderReturns400() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (_, response) = try await propfind(port: port, path: "/", depth: nil)
        XCTAssertEqual(response.statusCode, 400)

        await server.stop()
    }

    func testPropfindWithDepthInfinityReturns400() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (_, response) = try await propfind(port: port, path: "/", depth: "infinity")
        XCTAssertEqual(response.statusCode, 400)

        await server.stop()
    }

    func testPropfindOnAMissingPathReturns404() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (_, response) = try await propfind(port: port, path: "/missing.txt", depth: "0")
        XCTAssertEqual(response.statusCode, 404)

        await server.stop()
    }

    func testPropfindOnADirectoryReturns404WhenDirectoryListingIsDisabled() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        )
        let port = try await server.start()

        let (_, response) = try await propfind(port: port, path: "/", depth: "1")
        XCTAssertEqual(response.statusCode, 404)

        await server.stop()
    }

    private func propfind(port: UInt16, path: String, depth: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: loopbackURL(port: port, path: path))
        request.httpMethod = "PROPFIND"
        if let depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeWebDAVLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
