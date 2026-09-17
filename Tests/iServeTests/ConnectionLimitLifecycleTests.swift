import Network
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

    /// A connection is counted by `accept(_:)` the moment the TCP handshake
    /// completes — before any request bytes are read, let alone routed —
    /// so two raw connections that are opened and then simply left idle
    /// (no request ever sent) occupy the concurrent cap's two slots exactly
    /// as long as they stay open, with no timing race and nothing on the
    /// server side ever blocked waiting on a client. A third connection
    /// from the same address must then be rejected deterministically; once
    /// the first two are cancelled and their slots freed, a fourth must
    /// succeed. (An earlier version of this test tried to force overlap
    /// among real *concurrent* requests instead, first with a loose "some
    /// were rejected" assertion that could flake if none happened to
    /// overlap, then with an artificial per-connection response delay that
    /// blocked a Swift concurrency cooperative-pool thread and starved
    /// unrelated work in the same process under CI. `AddressConnectionTrackerTests.swift`
    /// separately covers the exact admission-decision logic with plain,
    /// deterministic unit tests.)
    func testPerAddressConnectionLimitRejectsConnectionsBeyondTheConcurrentCap() async throws {
        var limits = HTTPServerLimits.default
        limits.maxConnectionsPerAddress = 2
        limits.maxConnectionsPerAddressPerWindow = 1000 // large enough not to interfere

        let server = HTTPServer(limits: limits)
        let port = try await server.start()

        let first = try await openIdleConnection(port: port)
        let second = try await openIdleConnection(port: port)
        // Lets the server actor's accept() bookkeeping for both connections
        // finish running before the third attempt -- accept() itself does
        // no I/O and completes almost instantly once scheduled, this is
        // just a safety margin against scheduling latency, not a race the
        // assertion below depends on to pass.
        try await Task.sleep(nanoseconds: 100_000_000)

        let thirdSucceeded = await attemptRequest(port: port)
        XCTAssertFalse(thirdSucceeded, "a third connection from the same address should be rejected while both slots are occupied")

        first.cancel()
        second.cancel()

        // A retry here only ever masks how long it takes the server to
        // notice the cancellations and free the slots, never a real
        // regression: if a slot genuinely weren't freed, every attempt
        // would be rejected identically, not intermittently.
        let fourthSucceeded = await attemptRequestWithRetry(port: port)
        XCTAssertTrue(fourthSucceeded, "cancelling both connections should free their slots for a new one")

        await server.stop()
    }

    func testRejectedConnectionsAreCountedInTheRequestLog() async throws {
        var limits = HTTPServerLimits.default
        limits.maxConnectionsPerAddressPerWindow = 1
        limits.addressRateWindow = 60

        let log = RequestLog()
        let server = HTTPServer(limits: limits, requestLog: log)
        let port = try await server.start()

        let firstSucceeded = await attemptRequest(port: port)
        let secondSucceeded = await attemptRequest(port: port)
        XCTAssertTrue(firstSucceeded)
        XCTAssertFalse(secondSucceeded)

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
        let firstSucceeded = await attemptRequest(port: firstPort)
        let secondSucceeded = await attemptRequest(port: firstPort)
        XCTAssertTrue(firstSucceeded)
        XCTAssertFalse(secondSucceeded)
        await server.stop()

        let secondPort = try await server.start()
        // A retry here only ever masks a transient post-restart network
        // hiccup, never a real regression: if the budget genuinely hadn't
        // reset, every attempt would be rejected identically (the
        // connection is refused deterministically, not intermittently).
        let thirdSucceeded = await attemptRequestWithRetry(port: secondPort)
        XCTAssertTrue(thirdSucceeded)
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

/// Opens a raw TCP connection to loopback:`port` and waits for it to reach
/// `.ready`, without ever sending a byte. The server's own `accept(_:)`
/// counts a connection as soon as the handshake completes, so a connection
/// returned by this function occupies a per-address concurrent-cap slot
/// for as long as the caller keeps it open — the caller cancels it via the
/// returned `NWConnection` when done.
private func openIdleConnection(port: UInt16) async throws -> NWConnection {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                continuation.resume()
            case .failed(let error):
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    return connection
}

/// A handful of quick retries for a request expected to succeed, to
/// absorb a transient connection hiccup (observed right after a fresh
/// `start()` following a `stop()`) rather than mistake it for an actual
/// rejection.
private func attemptRequestWithRetry(port: UInt16, attempts: Int = 3) async -> Bool {
    for attempt in 1...attempts {
        if await attemptRequest(port: port) { return true }
        if attempt < attempts {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    return false
}
