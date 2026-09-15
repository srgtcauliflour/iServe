import Foundation
import XCTest
@testable import iServe

final class FolderRootManagerTests: XCTestCase {
    @MainActor
    func testSelectionSavesBookmarkAndBalancesScope() {
        let access = StubFolderAccess()
        let store = MemoryBookmarkStore()
        let manager = FolderRootManager(access: access, store: store)
        manager.select(access.url)
        XCTAssertEqual(manager.selectedURL, access.url)
        XCTAssertEqual(manager.folderName, "Website")
        XCTAssertEqual(store.bookmark, access.newBookmark)
        XCTAssertEqual(access.events, ["start", "validate", "bookmark", "stop"])
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testDeniedScopeDoesNotReadDirectoryOrStopUnacquiredScope() {
        let access = StubFolderAccess()
        access.grantsScope = false
        let store = MemoryBookmarkStore()
        let manager = FolderRootManager(access: access, store: store)
        manager.select(access.url)
        XCTAssertNil(manager.selectedURL)
        XCTAssertNil(store.bookmark)
        XCTAssertEqual(access.events, ["start"])
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testValidationFailureAlwaysReleasesScope() {
        let access = StubFolderAccess()
        access.validationFails = true
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        XCTAssertEqual(access.events, ["start", "validate", "stop"])
        XCTAssertNil(manager.selectedURL)
    }

    @MainActor
    func testBookmarkFailureKeepsPreviousRootAndSavedBookmark() {
        let access = StubFolderAccess()
        let store = MemoryBookmarkStore()
        let manager = FolderRootManager(access: access, store: store)
        manager.select(access.url)
        access.bookmarkFails = true
        access.events = []
        manager.select(URL(fileURLWithPath: "/private/Other"))
        XCTAssertEqual(manager.selectedURL, access.url)
        XCTAssertEqual(store.bookmark, access.newBookmark)
        XCTAssertEqual(access.events, ["start", "validate", "bookmark", "stop"])
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.errorMessage!.contains("/private/"))
    }

    @MainActor
    func testFreshManagerRestoresSavedRootWithoutRewritingValidBookmark() {
        let access = StubFolderAccess()
        let original = Data([1])
        let store = MemoryBookmarkStore(bookmark: original)
        let manager = FolderRootManager(access: access, store: store)
        manager.restore()
        XCTAssertEqual(manager.selectedURL, access.url)
        XCTAssertEqual(store.bookmark, original)
        XCTAssertEqual(access.events, ["resolve", "start", "validate", "stop"])
    }

    @MainActor
    func testStaleBookmarkIsRefreshedWithinScope() {
        let access = StubFolderAccess()
        access.stale = true
        let store = MemoryBookmarkStore(bookmark: Data([1]))
        let manager = FolderRootManager(access: access, store: store)
        manager.restore()
        XCTAssertEqual(manager.selectedURL, access.url)
        XCTAssertEqual(store.bookmark, access.newBookmark)
        XCTAssertEqual(access.events, ["resolve", "start", "validate", "bookmark", "stop"])
    }

    @MainActor
    func testStaleRefreshFailurePreservesBookmarkForRetryAndReleasesScope() {
        let access = StubFolderAccess()
        access.stale = true
        access.bookmarkFails = true
        let original = Data([1])
        let store = MemoryBookmarkStore(bookmark: original)
        let manager = FolderRootManager(access: access, store: store)
        manager.restore()
        XCTAssertNil(manager.selectedURL)
        XCTAssertEqual(store.bookmark, original)
        XCTAssertEqual(access.events.last, "stop")
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testUnavailableProviderCanBeRetriedWithoutLosingSavedBookmark() {
        let access = StubFolderAccess()
        access.resolveFails = true
        let store = MemoryBookmarkStore(bookmark: Data([1]))
        let manager = FolderRootManager(access: access, store: store)
        manager.restore()
        XCTAssertNil(manager.selectedURL)
        XCTAssertTrue(manager.hasSavedFolder)
        XCTAssertEqual(access.events, ["resolve"])
        XCTAssertNotNil(manager.errorMessage)
        access.resolveFails = false
        manager.restore()
        XCTAssertEqual(manager.selectedURL, access.url)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testRestoreDeniedScopeClearsPreviouslyValidatedRoot() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        access.events = []
        access.grantsScope = false
        manager.restore()
        XCTAssertNil(manager.selectedURL)
        XCTAssertEqual(access.events, ["resolve", "start"])
        XCTAssertTrue(manager.hasSavedFolder)
    }

    @MainActor
    func testForgetRemovesBookmarkAndStateWithoutExtraScopeOperations() {
        let access = StubFolderAccess()
        let store = MemoryBookmarkStore()
        let manager = FolderRootManager(access: access, store: store)
        manager.select(access.url)
        access.events = []
        manager.forget()
        manager.forget()
        XCTAssertNil(store.bookmark)
        XCTAssertNil(manager.selectedURL)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(access.events.isEmpty)
        manager.restore()
        XCTAssertTrue(access.events.isEmpty)
    }

    @MainActor
    func testNonFileURLIsRejectedBeforeProviderOperations() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(URL(string: "https://example.com")!)
        XCTAssertTrue(access.events.isEmpty)
        XCTAssertNil(manager.selectedURL)
    }

    @MainActor
    func testPickerCancellationKeepsSelectionAndNoError() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        manager.reportPickerFailure(CocoaError(.userCancelled))
        XCTAssertEqual(manager.selectedURL, access.url)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testUserDefaultsBookmarkSurvivesStoreRecreationAndForget() {
        let name = "iServe.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UserDefaultsFolderBookmarkStore(defaults: defaults)
        first.bookmark = Data([4, 5, 6])
        let second = UserDefaultsFolderBookmarkStore(defaults: defaults)
        XCTAssertEqual(second.bookmark, Data([4, 5, 6]))
        second.bookmark = nil
        XCTAssertNil(first.bookmark)
    }
}

@MainActor
final class MemoryBookmarkStore: FolderBookmarkStore {
    var bookmark: Data?
    init(bookmark: Data? = nil) { self.bookmark = bookmark }
}

@MainActor
final class StubFolderAccess: FolderAccess {
    let url = URL(fileURLWithPath: "/private/Website")
    let newBookmark = Data([2, 3])
    var grantsScope = true
    var validationFails = false
    var bookmarkFails = false
    var resolveFails = false
    var stale = false
    var events: [String] = []
    var onStart: (() -> Void)?

    func startAccessing(_ url: URL) -> Bool {
        onStart?()
        events.append("start")
        return grantsScope
    }
    func stopAccessing(_ url: URL) { events.append("stop") }
    func validateDirectory(_ url: URL) throws {
        events.append("validate")
        if validationFails { throw FolderAccessError.notDirectory }
    }
    func makeBookmark(_ url: URL) throws -> Data {
        events.append("bookmark")
        if bookmarkFails { throw CocoaError(.fileReadNoPermission) }
        return newBookmark
    }
    func resolveBookmark(_ data: Data) throws -> (url: URL, stale: Bool) {
        events.append("resolve")
        if resolveFails { throw CocoaError(.fileReadNoSuchFile) }
        return (url, stale)
    }
}
