import XCTest
@testable import iServe

/// Only covers the deterministic, synchronous parts of `BonjourAdvertiser`'s
/// state machine — `start()`/`stop()` set `.publishing`/`.idle` immediately,
/// before any real network round trip. Whether `NetService.publish()` itself
/// actually succeeds (`.published`) or fails (`.failed`) depends on real
/// mDNS/system Bonjour behavior, which isn't reliable to assert on in CI —
/// see `Networking/README.md`.
final class BonjourAdvertiserTests: XCTestCase {
    @MainActor
    func testStartsIdle() {
        let advertiser = BonjourAdvertiser()
        XCTAssertEqual(advertiser.state, .idle)
    }

    @MainActor
    func testStartMovesToPublishingImmediately() {
        let advertiser = BonjourAdvertiser()
        advertiser.start(name: "Test Device", port: 8080)
        XCTAssertEqual(advertiser.state, .publishing)
    }

    @MainActor
    func testStopReturnsToIdle() {
        let advertiser = BonjourAdvertiser()
        advertiser.start(name: "Test Device", port: 8080)
        advertiser.stop()
        XCTAssertEqual(advertiser.state, .idle)
    }

    @MainActor
    func testStopBeforeStartIsSafe() {
        let advertiser = BonjourAdvertiser()
        advertiser.stop()
        XCTAssertEqual(advertiser.state, .idle)
    }

    @MainActor
    func testStartingAgainReplacesThePreviousAdvertisementWithoutCrashing() {
        let advertiser = BonjourAdvertiser()
        advertiser.start(name: "First", port: 8080)
        advertiser.start(name: "Second", port: 8081)
        XCTAssertEqual(advertiser.state, .publishing)
    }
}
