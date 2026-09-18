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

    /// v0.3, password-only cookie login (`docs/adr/0008-password-only-cookie-login.md`):
    /// a plain browser `GET` with no `Authorization` header at all now
    /// gets the password-only login page instead of a bare `401` — see
    /// `LoginLifecycleTests.swift` for the login flow itself. A client
    /// that already attempted (and got rejected for) Basic Auth is a
    /// different case entirely, covered below and unaffected by this.
    func testRequestWithoutCredentialsShowsThePasswordOnlyLoginPageRatherThanWWWAuthenticate() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNil(http.value(forHTTPHeaderField: "WWW-Authenticate"))
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("type=\"password\""))
        XCTAssertFalse(body.contains("type=\"text\""), "the login form must never ask for a username")

        await server.stop()
    }

    /// Unaffected by v0.3's login page (`docs/adr/0008-password-only-cookie-login.md`):
    /// this request already carries an `Authorization` header, just a
    /// wrong one, so it keeps getting the same `401` a WebDAV/API client
    /// retrying Basic Auth already knows how to respond to — only a
    /// request with *no* `Authorization` header at all gets the login
    /// page instead.
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

        // "/index.html" by name: the default handler keeps directory
        // listing on, so "/" itself no longer auto-serves the index file
        // (v0.3 post-ship fix — see StaticFileHandlerTests).
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/index.html")!)
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

    /// Unaffected by v0.3's login page: every header here is an
    /// *attempted* `Authorization` value, just an unusable one, so this
    /// still exercises the same `401` path as a correctly-formed but
    /// wrong Basic credential — never the login page.
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

    /// v0.3: a `HEAD` with no `Authorization` header gets the same
    /// login-page fallback as `GET` does, but with its body suppressed —
    /// HTTP requires a `HEAD` response to have no body regardless of
    /// status. A `HEAD` that already carries a wrong/malformed
    /// `Authorization` header is unaffected and still gets `401`, same
    /// as `GET`'s equivalent case above.
    func testHeadRequestWithoutCredentialsGetsTheLoginPageWithNoBody() async throws {
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
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(data.isEmpty)

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

        // "/index.html" by name: the default handler keeps directory
        // listing on, so "/" itself no longer auto-serves the index file
        // (v0.3 post-ship fix — see StaticFileHandlerTests).
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/index.html")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "open")

        await server.stop()
    }
}
