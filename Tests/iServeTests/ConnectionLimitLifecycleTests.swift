import XCTest
@testable import iServe

/// Drives a real `HTTPServer` over loopback for the per-address connection
/// and rate limits (v0.3, `docs/adr/0006-connection-and-rate-limits.md`).
/// Every request in this file originates from the same address (loopback),
/// which is exactly what makes these limits testable without simulating
/// multiple distinct clients.
final class ConnectionLimitLifecycleTests: XCTestCase {
    /// Sequential requests fully complete (and their connection closes)
    /// before the next one starts, so only the rolling-window rate limit —
    /// never the concurrent-connection cap — can be what rejects any of
    /// them. Deterministic, unlike a concurrency-based test.
    func testPerAddressRateLimitRejectsRequestsBeyondTheWindowBudget() async throws {
        var limits = HTTPServerLimits.default
        limits.maxConnectionsPerAddressPerWindow = 3
        limits.addressRateWindow = 60 // long enough it can't expire mid-test

        let server = HTTPServer(limits: limits)
        let port = try await server.start()

        var results: [Bool] = []
        for _ in 0..<5 {
            results.append(await attemptRequest(port: port))
        }
        XCTAssertEqual(results.filter { $0 }.count, 3)
        XCTAssertEqual(results.filter { !$0 }.count, 2)

        await server.stop()
    }

    /// Ten simultaneous connection attempts against a concurrent cap of 2
    /// for the one address they all share. Asserts only that *some* were
    /// rejected (not an exact count), since real wall-clock timing among
    /// truly concurrent connections isn't perfectly deterministic — but a
    /// cap this far below the attempt count is a comfortable enough margin
    /// to be reliable in practice.
    func testPerAddressConnectionLimitRejectsSomeConnectionsUnderConcurrentLoad() async throws {
        var limits = HTTPServerLimits.default
        limits.maxConnectionsPerAddress = 2
        limits.maxConnectionsPerAddressPerWindow = 1000 // large enough not to interfere

        let server = HTTPServer(limits: limits)
        let port = try await server.start()

        let successCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<10 {
                group.addTask { await attemptRequest(port: port) }
            }
            var count = 0
            for await succeeded in group where succeeded {
                count += 1
            }
            return count
        }
        XCTAssertLessThan(successCount, 10, "expected at least one connection to be rejected under the per-address concurrent cap")

        await server.stop()
    }

    func testRejectedConnectionsAreCountedInTheRequestLog() async throws {
        var limits = HTTPServerLimits.default
        limits.maxConnectionsPerAddressPerWindow = 1
        limits.addressRateWindow = 60

        let log = RequestLog()
        let server = HTTPServer(limits: limits, requestLog: log)
        let port = try await server.start()

        XCTAssertTrue(await attemptRequest(port: port))
        XCTAssertFalse(await attemptRequest(port: port))

        let snapshot = await log.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.rejectedConnections, 1)

        await server.stop()
    }

    /// `stop()` clears every per-address tracking structure, so a fresh
    /// `start()` begins with a clean rate-limit budget rather than
    /// inheriting the previous session's.
    func testStoppingAndRestartingResetsThePerAddressRateBudget() async throws {
        var limits = HTTPServerLimits.default
        limits.maxConnectionsPerAddressPerWindow = 1
        limits.addressRateWindow = 60

        let server = HTTPServer(limits: limits)

        let firstPort = try await server.start()
        XCTAssertTrue(await attemptRequest(port: firstPort))
        XCTAssertFalse(await attemptRequest(port: firstPort))
        await server.stop()

        let secondPort = try await server.start()
        XCTAssertTrue(await attemptRequest(port: secondPort))
        await server.stop()
    }
}

/// `true` if the request completed with the expected `404` (the bootstrap
/// `NotFoundRouter`'s only possible response); `false` for any error,
/// including the connection reset a rejected connection produces.
private func attemptRequest(port: UInt16) async -> Bool {
    do {
        let (_, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/"))
        return (response as? HTTPURLResponse)?.statusCode == 404
    } catch {
        return false
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
