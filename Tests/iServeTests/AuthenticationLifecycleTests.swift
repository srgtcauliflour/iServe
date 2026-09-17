import XCTest
@testable import iServe

/// Drives a real `HTTPServer` over loopback with `ServerCredentials` set,
/// proving `HTTPConnection`'s optional HTTP Basic Auth gate
/// (`docs/adr/0002-http-basic-authentication.md`) runs before *any* request
/// — GET, HEAD, or POST — reaches the router or a body byte is read.
final class AuthenticationLifecycleTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeAuthLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func basicHeader(user: String = "", password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    func testRequestWithoutCredentialsIsRejectedWithWWWAuthenticate() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertEqual(http.value(forHTTPHeaderField: "WWW-Authenticate"), "Basic realm=\"iServe\", charset=\"UTF-8\"")

        await server.stop()
    }

    func testRequestWithTheWrongPasswordIsRejected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.setValue(basicHeader(password: "wrong"), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)

        await server.stop()
    }

    func testRequestWithTheCorrectPasswordSucceeds() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.setValue(basicHeader(password: "letmein"), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "secret")

        await server.stop()
    }

    func testUsernameIsAcceptedButIgnored() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.setValue(basicHeader(user: "whoever", password: "letmein"), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        await server.stop()
    }

    func testMalformedAuthorizationHeaderIsRejectedRatherThanCrashing() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        for header in ["Bearer sometoken", "Basic not-valid-base64!!!", "Basic"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
            request.setValue(header, forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, "header: \(header)")
        }

        await server.stop()
    }

    func testHeadRequestIsGatedTheSameWayAsGet() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)

        await server.stop()
    }

    /// A POST is gated before `beginUpload`/`beginZipDownload` ever run, so
    /// an unauthenticated upload attempt must never reach the filesystem.
    func testUploadPostIsRejectedWithoutCredentialsAndNothingIsWritten() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        let boundary = "AuthTestBoundary"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n".utf8))
        body.append(Data("Content-Type: text/plain\r\n\r\n".utf8))
        body.append(Data("hello".utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("note.txt").path))

        await server.stop()
    }

    func testNoCredentialsConfiguredMeansNoAuthorizationHeaderIsNeeded() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("open".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "open")

        await server.stop()
    }
}
