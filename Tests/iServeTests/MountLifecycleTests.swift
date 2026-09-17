import XCTest
@testable import iServe

/// Drives a real `HTTPServer` with a real `MountRouter` over loopback (v0.3,
/// `docs/adr/0007-multiple-mounted-folders.md`) — the full pipeline a
/// two-folder session actually uses, complementing `MountRouterTests.swift`'s
/// router-only unit tests with an end-to-end round trip.
final class MountLifecycleTests: XCTestCase {
    func testPrimaryAndAnAdditionalMountAreBothReachableAtTheirOwnAddresses() async throws {
        let primaryRoot = try makeTempDirectory(name: "primary")
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        let mountRoot = try makeTempDirectory(name: "mount")
        defer { try? FileManager.default.removeItem(at: mountRoot) }

        try "primary page".write(to: primaryRoot.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "mounted file".write(to: mountRoot.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)

        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot)),
            additional: [MountRouter.Mount(name: "Extra", handler: StaticFileHandler(resolver: SecurePathResolver(root: mountRoot)))]
        )
        let server = HTTPServer(router: router)
        let port = try await server.start()

        // "/index.html" by name: the primary's default handler keeps
        // directory listing on, so "/" itself no longer auto-serves the
        // index file (v0.3 post-ship fix — see StaticFileHandlerTests).
        let (primaryData, primaryResponse) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/index.html"))
        XCTAssertEqual((primaryResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: primaryData, as: UTF8.self), "primary page")

        let (mountData, mountResponse) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/Extra/shared.txt"))
        XCTAssertEqual((mountResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: mountData, as: UTF8.self), "mounted file")

        await server.stop()
    }

    func testABareMountAddressRedirectsToItsOwnRootOverTheWire() async throws {
        let primaryRoot = try makeTempDirectory(name: "primary")
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        let mountRoot = try makeTempDirectory(name: "mount")
        defer { try? FileManager.default.removeItem(at: mountRoot) }

        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot)),
            additional: [MountRouter.Mount(name: "Extra", handler: StaticFileHandler(resolver: SecurePathResolver(root: mountRoot)))]
        )
        let server = HTTPServer(router: router)
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/Extra"))
        request.httpMethod = "GET"
        // Follow no redirects, so we can inspect the 301 itself.
        let noRedirectSession = URLSession(configuration: .ephemeral, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
        let (_, response) = try await noRedirectSession.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 301)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), "/Extra/")

        await server.stop()
    }

    func testAnAdditionalMountRefusesWebDAVWritesEvenWhenThePrimaryAllowsThem() async throws {
        let primaryRoot = try makeTempDirectory(name: "primary")
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        let mountRoot = try makeTempDirectory(name: "mount")
        defer { try? FileManager.default.removeItem(at: mountRoot) }

        // Mirrors LiveServerService: the primary's own writes capability
        // never leaks to an additional mount's handler.
        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot), allowWebDAVWrites: true),
            additional: [MountRouter.Mount(name: "Extra", handler: StaticFileHandler(resolver: SecurePathResolver(root: mountRoot), allowWebDAVWrites: false))]
        )
        let server = HTTPServer(router: router)
        let port = try await server.start()

        var putRequest = URLRequest(url: loopbackURL(port: port, path: "/Extra/new.txt"))
        putRequest.httpMethod = "PUT"
        putRequest.httpBody = Data("hello".utf8)
        let (_, putResponse) = try await URLSession.shared.data(for: putRequest)
        XCTAssertEqual((putResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountRoot.appendingPathComponent("new.txt").path))

        await server.stop()
    }

    private func makeTempDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeMountLifecycleTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Prevents `URLSession` from transparently following the 301, so the test
/// can assert on the redirect response itself.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
