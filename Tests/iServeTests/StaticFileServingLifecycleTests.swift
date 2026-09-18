import XCTest
@testable import iServe

/// Drives `HTTPServer` with a real `StaticFileHandler` over loopback, proving the
/// full pipeline end to end: `SecurePathResolver` -> `StaticFileHandler` ->
/// `HTTPConnection`'s chunked file streaming -> a real HTTP client. Router-only
/// behavior (index preference, status mapping) lives in `StaticFileHandlerTests`;
/// these cases are only the ones that need an actual client/server round trip.
final class StaticFileServingLifecycleTests: XCTestCase {
    /// Index auto-serving only happens with directory listing off
    /// (`ServerProfile.websiteReadOnly`) — see `docs/adr` and
    /// `StaticFileHandlerTests` for the router-level rule; this exercises
    /// the same thing over a real client/server round trip.
    func testServesIndexHtmlAtRootWithCorrectContentType() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<html>hi</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        )
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<html>hi</html>")

        await server.stop()
    }

    func testServesNestedAssetAndLargePayloadIntact() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "body { color: red; }".write(to: assets.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        // Large enough to require many multiples of the 64KB write chunk size,
        // so a successful, byte-exact download demonstrates real chunked
        // streaming rather than a single in-memory send.
        var large = Data(capacity: 600_000)
        for i in 0..<600_000 { large.append(UInt8(truncatingIfNeeded: i)) }
        try large.write(to: root.appendingPathComponent("large.bin"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (cssData, cssResponse) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/assets/style.css"))
        XCTAssertEqual((cssResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/css; charset=utf-8")
        XCTAssertEqual(String(decoding: cssData, as: UTF8.self), "body { color: red; }")

        let (binData, binResponse) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/large.bin"))
        let binHttp = try XCTUnwrap(binResponse as? HTTPURLResponse)
        XCTAssertEqual(binHttp.statusCode, 200)
        XCTAssertEqual(binHttp.value(forHTTPHeaderField: "Content-Type"), MIMEType.binaryFallback)
        XCTAssertEqual(binData.count, large.count)
        XCTAssertEqual(binData, large)

        await server.stop()
    }

    func testSymlinkEscapeIsRejectedOverTheWire() async throws {
        // `..` traversal is deliberately not exercised here: URLSession/CFNetwork
        // normalizes dot-segments out of a URL's path client-side (RFC 3986
        // 5.2.4) before anything reaches the socket, so a raw ".." never
        // actually goes over the wire this way. That defense is proven directly
        // against the router in StaticFileHandlerTests and exhaustively against
        // the resolver in SecurePathResolverTests instead. A plain path
        // component like "escape" below is not touched by that normalization,
        // so it does prove the real server (not just the router in isolation)
        // rejects a symlink escape.
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeStaticLifecycleOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (_, escapeResponse) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/escape/secret.txt"))
        XCTAssertEqual((escapeResponse as? HTTPURLResponse)?.statusCode, 403)

        await server.stop()
    }

    func testDirectoryListingIsReachableAfterTrailingSlashRedirect() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "body".write(to: assets.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        // No trailing slash in the request: URLSession follows the 301
        // automatically, proving the whole redirect round trip works, not
        // just that the router computes the right Location header.
        let (data, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/assets"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        // Not asserting http.url?.path here: URLSession's reported redirect
        // target is a Foundation-version-dependent cosmetic detail (it has
        // been observed dropping the trailing slash even though the request
        // that actually produced this response - proven below by getting the
        // listing itself, not a 301 - did go to "/assets/"). The redirect
        // and listing pipeline is what this test is proving, not URL parsing.
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("notes.txt"))

        await server.stop()
    }

    func testRequestLogRecordsRealRequestsThroughTheFullPipeline() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<html>hi</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let log = RequestLog()
        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)), requestLog: log)
        let port = try await server.start()

        _ = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/"))
        _ = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/missing.txt"))

        let snapshot = try await waitForSnapshot(log, expectingAtLeast: 2)
        XCTAssertEqual(snapshot.totalRequests, 2)
        XCTAssertTrue(snapshot.entries.contains { $0.path == "/" && $0.status == 200 })
        XCTAssertTrue(snapshot.entries.contains { $0.path == "/missing.txt" && $0.status == 404 })
        XCTAssertGreaterThan(snapshot.totalBytes, 0)

        await server.stop()
    }

    private func waitForSnapshot(
        _ log: RequestLog,
        expectingAtLeast count: Int,
        timeout: TimeInterval = 2
    ) async throws -> RequestLog.Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let snapshot = await log.snapshot()
            if snapshot.totalRequests >= count || Date() > deadline {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeStaticLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
