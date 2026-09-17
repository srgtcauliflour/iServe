import XCTest
@testable import iServe

/// Unit tests for `AddressConnectionTracker` — the per-address admission
/// bookkeeping behind `docs/adr/0006-connection-and-rate-limits.md`'s two
/// additional limits, pulled out of `HTTPServer` specifically so this logic
/// could be tested deterministically: plain sequential calls with an
/// injected clock, rather than needing real concurrent network connections
/// to race against each other in wall-clock time (see
/// `ConnectionLimitLifecycleTests.swift` for why that approach was
/// abandoned — it was either flaky or, when made artificially "deterministic"
/// with a blocking per-connection delay, risked starving Swift concurrency's
/// cooperative thread pool for unrelated work in the same process).
final class AddressConnectionTrackerTests: XCTestCase {
    func testAdmitsUpToTheConcurrentCapThenRejectsFurtherConnectionsFromTheSameAddress() {
        var tracker = AddressConnectionTracker(maxConnectionsPerAddress: 2, maxConnectionsPerAddressPerWindow: 1000, addressRateWindow: 60)

        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertFalse(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
    }

    func testDifferentAddressesHaveIndependentConcurrentBudgets() {
        var tracker = AddressConnectionTracker(maxConnectionsPerAddress: 1, maxConnectionsPerAddressPerWindow: 1000, addressRateWindow: 60)

        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertFalse(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "5.6.7.8"), "a different address must have its own budget")
    }

    func testRemovingAConnectionFreesAConcurrentSlotForANewOne() {
        var tracker = AddressConnectionTracker(maxConnectionsPerAddress: 1, maxConnectionsPerAddressPerWindow: 1000, addressRateWindow: 60)
        let first = UUID()

        XCTAssertTrue(tracker.tryAdmit(id: first, address: "1.2.3.4"))
        XCTAssertFalse(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))

        tracker.remove(first)

        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"), "removing the first connection should free its slot")
    }

    func testRemoveIsANoOpForAnIDThatWasNeverAdmitted() {
        var tracker = AddressConnectionTracker(maxConnectionsPerAddress: 1, maxConnectionsPerAddressPerWindow: 1000, addressRateWindow: 60)
        let admitted = UUID()
        XCTAssertTrue(tracker.tryAdmit(id: admitted, address: "1.2.3.4"))

        tracker.remove(UUID()) // never admitted

        XCTAssertFalse(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"), "the real connection's slot must still be occupied")
    }

    func testRateWindowCapRejectsBeyondBudgetWithinTheWindowEvenWithConnectionsRemoved() {
        // A high concurrent cap isolates this to just the rate-window
        // budget: removing a connection frees a *concurrent* slot but must
        // never refund a spent rate-window timestamp.
        var tracker = AddressConnectionTracker(maxConnectionsPerAddress: 1000, maxConnectionsPerAddressPerWindow: 2, addressRateWindow: 60)
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(tracker.tryAdmit(id: first, address: "1.2.3.4"))
        XCTAssertTrue(tracker.tryAdmit(id: second, address: "1.2.3.4"))
        tracker.remove(first)
        tracker.remove(second)

        XCTAssertFalse(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"), "the window budget stays spent regardless of concurrent-slot removals")
    }

    func testExpiredTimestampsAreExcludedFromTheRateWindowBudget() {
        let clock = MutableClock()
        var tracker = AddressConnectionTracker(
            maxConnectionsPerAddress: 1000,
            maxConnectionsPerAddressPerWindow: 1,
            addressRateWindow: 10,
            now: { clock.date }
        )

        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertFalse(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"), "still within the window")

        clock.date.addTimeInterval(10.001)

        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"), "the first timestamp has aged out of the window")
    }

    func testRemoveAllClearsEveryAddresssBookkeeping() {
        var tracker = AddressConnectionTracker(maxConnectionsPerAddress: 1, maxConnectionsPerAddressPerWindow: 1, addressRateWindow: 60)
        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "5.6.7.8"))

        tracker.removeAll()

        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "1.2.3.4"))
        XCTAssertTrue(tracker.tryAdmit(id: UUID(), address: "5.6.7.8"))
    }
}

private final class MutableClock {
    var date = Date()
}
