import XCTest
@testable import iServe

/// Drives a real `HTTPServer` over loopback to exercise the password-only
/// cookie login flow end to end (v0.3, `docs/adr/0008-password-only-cookie-login.md`)
/// — complementing `AuthenticationLifecycleTests.swift`, which covers the
/// gate itself (when the login page appears vs. a bare `401`) but not the
/// login flow's own mechanics.
final class LoginLifecycleTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeLoginLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func startServer(root: URL) async throws -> (HTTPServer, UInt16) {
        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root)),
            credentials: ServerCredentials(password: "letmein")
        )
        let port = try await server.start()
        return (server, port)
    }

    private func loginRequest(port: UInt16, password: String, redirect: String = "/") -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__iserve/login")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "password=\(password)&redirect=\(redirect)"
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Cookie-following `URLSession`s auto-redirect, which would hide the
    /// `303`/`Set-Cookie` this test needs to inspect directly.
    private func noRedirectSession() -> (URLSession, NoRedirectDelegate) {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func testCorrectPasswordMintsASessionCookieAndRedirectsToTheOriginalPath() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let (server, port) = try await startServer(root: root)
        let (session, _) = noRedirectSession()

        let (_, response) = try await session.data(for: loginRequest(port: port, password: "letmein", redirect: "/index.html"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 303)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Location"), "/index.html")
        let setCookie = try XCTUnwrap(http.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(setCookie.contains("iserve_session="))
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))

        await server.stop()
    }

    func testWrongPasswordReShowsTheLoginPageWithAnErrorAndSetsNoCookie() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (server, port) = try await startServer(root: root)
        let (session, _) = noRedirectSession()

        let (data, response) = try await session.data(for: loginRequest(port: port, password: "wrong"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNil(http.value(forHTTPHeaderField: "Set-Cookie"))
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("Incorrect password"))

        await server.stop()
    }

    /// A session cookie minted on one connection must be honored on a
    /// later, entirely separate connection — v0.1 has no HTTP keep-alive,
    /// so this is the only way "already logged in" can mean anything.
    func testAMintedSessionCookieIsHonoredOnASeparateLaterConnectionWithoutBasicAuth() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let (server, port) = try await startServer(root: root)
        let (session, _) = noRedirectSession()

        let (_, loginResponse) = try await session.data(for: loginRequest(port: port, password: "letmein"))
        let cookie = try XCTUnwrap((loginResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"))
        let cookiePair = String(cookie.split(separator: ";").first ?? "")

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/index.html")!)
        request.setValue(cookiePair, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "secret")

        await server.stop()
    }

    /// An absolute URL, a protocol-relative `//host/...` one, and a raw
    /// CRLF sequence in `redirect` must all fall back to `/` rather than
    /// ever appearing unsanitized in a `Location` header — an open
    /// redirect and a header-injection primitive respectively.
    func testRedirectPathIsSanitizedAgainstOpenRedirectAndHeaderInjection() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (server, port) = try await startServer(root: root)
        let (session, _) = noRedirectSession()

        let attempts = [
            "https://evil.example/phish",
            "//evil.example/phish",
            "/ok\r\nX-Injected: yes",
        ]
        for redirect in attempts {
            let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirect
            let (_, response) = try await session.data(for: loginRequest(port: port, password: "letmein", redirect: encoded))
            let http = try XCTUnwrap(response as? HTTPURLResponse, "redirect: \(redirect)")
            XCTAssertEqual(http.statusCode, 303, "redirect: \(redirect)")
            XCTAssertEqual(http.value(forHTTPHeaderField: "Location"), "/", "redirect: \(redirect)")
            XCTAssertNil(http.value(forHTTPHeaderField: "X-Injected"), "redirect: \(redirect)")
        }

        await server.stop()
    }

    /// Restarting the server clears every previously minted session token,
    /// same as it already clears every other per-session server-side state.
    func testSessionTokensAreClearedWhenTheServerStopsAndRestarts() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("index.html"))

        let (server, port) = try await startServer(root: root)
        let (session, _) = noRedirectSession()

        let (_, loginResponse) = try await session.data(for: loginRequest(port: port, password: "letmein"))
        let cookie = try XCTUnwrap((loginResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"))
        let cookiePair = String(cookie.split(separator: ";").first ?? "")

        await server.stop()
        let newPort = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(newPort)/index.html")!)
        request.setValue(cookiePair, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("type=\"password\""), "an old cookie must not still authenticate after a restart")

        await server.stop()
    }

    /// The login path is a control-plane endpoint, never a file: it must
    /// never reach `SecurePathResolver`/the router even though it lives
    /// under the same origin as everything the served folder contains.
    func testTheLoginPathNeverReachesTheRouterOrFilesystemEvenWhenAFileWouldMatchIt() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("__iserve", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not the login page".utf8).write(
            to: root.appendingPathComponent("__iserve/login")
        )

        let (server, port) = try await startServer(root: root)

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/__iserve/login")!
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("Password Required"))
        XCTAssertFalse(body.contains("not the login page"))

        await server.stop()
    }
}
