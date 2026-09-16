import XCTest
@testable import iServe

/// Only covers `WebViewLoadState`'s own state machine, driven directly -
/// not a real `WKWebView` load. Loading a real page (even the app's own
/// local server) inside a `WKWebView` during a unit test would need a
/// running HTTPServer and WebKit's full rendering engine, which isn't
/// reliable to exercise in CI - see `Tests/iServeTests/BonjourAdvertiserTests.swift`
/// for the same reasoning applied to real mDNS publish.
final class WebViewLoadStateTests: XCTestCase {
    @MainActor
    func testStartsLoading() {
        let state = WebViewLoadState()
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testFinishedLoadingClearsLoadingWithoutTouchingError() {
        let state = WebViewLoadState()
        state.finishedLoading()
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testFailedSetsErrorAndClearsLoading() {
        let state = WebViewLoadState()
        state.failed("offline")
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.errorMessage, "offline")
    }

    @MainActor
    func testResetReturnsToTheInitialLoadingState() {
        let state = WebViewLoadState()
        state.failed("offline")
        state.reset()
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }
}
