import XCTest
@testable import iServe

/// Exercises the real `NWListener`/`NWConnection` lifecycle over loopback rather
/// than stubbing the transport, since start/stop determinism and concurrent
/// connection handling are only meaningful against the real stack. These are the
/// slowest tests in the suite; keep new cases here narrowly scoped to lifecycle
/// and transport behavior; parsing/router behavior belongs in the other suites.
final class ServerLifecycleTests: XCTestCase {
    func testStartReturnsABoundPortAndServesARequest() async throws {
        let server = HTTPServer()
        let port = try await server.start()

        let (_, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)

        await server.stop()
    }

    func testHeadSuppressesBodyButKeepsContentLength() async throws {
        let server = HTTPServer()
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/missing"))
        request.httpMethod = "HEAD"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
        XCTAssertTrue(data.isEmpty)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Length"))

        await server.stop()
    }

    func testUnsupportedMethodReturnsNotImplemented() async throws {
        let server = HTTPServer()
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/"))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 501)

        await server.stop()
    }

    func testConcurrentRequestsAreAllServedWithoutHanging() async throws {
        let server = HTTPServer()
        let port = try await server.start()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let (_, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/"))
                    return (response as? HTTPURLResponse)?.statusCode ?? -1
                }
            }
            for try await status in group {
                XCTAssertEqual(status, 404)
            }
        }

        await server.stop()
    }

    func testStartStopIsDeterministicAndRepeatable() async throws {
        let server = HTTPServer()
        for _ in 0..<3 {
            let port = try await server.start()
            let (_, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            await server.stop()
            let stateAfterStop = await server.state
            XCTAssertEqual(stateAfterStop, .idle)
        }
    }

    func testStopBeforeStartIsSafe() async {
        let server = HTTPServer()
        await server.stop()
        let state = await server.state
        XCTAssertEqual(state, .idle)
    }

    func testStartingTwiceWithoutStoppingThrows() async throws {
        let server = HTTPServer()
        _ = try await server.start()
        do {
            _ = try await server.start()
            XCTFail("expected a second start() without an intervening stop() to throw")
        } catch {
            XCTAssertEqual(error as? HTTPServer.ServerError, .alreadyRunning)
        }
        await server.stop()
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
