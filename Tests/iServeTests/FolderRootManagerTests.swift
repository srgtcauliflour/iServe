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
    func testBeginAccessReturnsSelectedURLAndAcquiresScope() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        access.events = []

        let scoped = manager.beginAccess()
        XCTAssertEqual(scoped, access.url)
        XCTAssertEqual(access.events, ["start"])
    }

    @MainActor
    func testBeginAccessReturnsNilWithoutASelectedFolder() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        XCTAssertNil(manager.beginAccess())
        XCTAssertTrue(access.events.isEmpty)
    }

    @MainActor
    func testBeginAccessReturnsNilWhenScopeIsDenied() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        access.events = []
        access.grantsScope = false

        XCTAssertNil(manager.beginAccess())
        XCTAssertEqual(access.events, ["start"])
    }

    @MainActor
    func testEndAccessStopsScopeForTheGivenURL() {
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        access.events = []

        let scoped = manager.beginAccess()!
        manager.endAccess(scoped)
        XCTAssertEqual(access.events, ["start", "stop"])
    }

    @MainActor
    func testBeginAccessIsReentrantForConcurrentIndependentCallers() {
        // A server session and the file manager screen can both hold
        // access to the same root at once; each must be released
        // independently by its own matching endAccess(_:) call.
        let access = StubFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore())
        manager.select(access.url)
        access.events = []

        let first = manager.beginAccess()
        let second = manager.beginAccess()
        XCTAssertEqual(first, access.url)
        XCTAssertEqual(second, access.url)
        XCTAssertEqual(access.events, ["start", "start"])

        manager.endAccess(first!)
        manager.endAccess(second!)
        XCTAssertEqual(access.events, ["start", "start", "stop", "stop"])
    }

    // MARK: - Additional mounts (v0.3, docs/adr/0007-multiple-mounted-folders.md)

    @MainActor
    func testAddMountPersistsBookmarkAndAppendsToAdditionalMounts() {
        let access = MultiMountFolderAccess()
        let mountStore = MemoryMountBookmarkStore()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: mountStore)
        let url = URL(fileURLWithPath: "/private/Photos")

        manager.addMount(url)

        XCTAssertEqual(manager.additionalMounts.map(\.name), ["Photos"])
        XCTAssertEqual(manager.additionalMounts.first?.url, url)
        XCTAssertEqual(mountStore.mounts.map(\.name), ["Photos"])
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testAddMountDerivesUniqueNameFromFolderNameAndDisambiguatesCollisions() {
        let access = MultiMountFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: MemoryMountBookmarkStore())

        manager.addMount(URL(fileURLWithPath: "/private/Photos"))
        manager.addMount(URL(fileURLWithPath: "/private/other/Photos"))
        manager.addMount(URL(fileURLWithPath: "/private/third/Photos"))

        XCTAssertEqual(manager.additionalMounts.map(\.name), ["Photos", "Photos-2", "Photos-3"])
    }

    @MainActor
    func testAddMountFailureSetsErrorMessageAndDoesNotAppend() {
        let access = MultiMountFolderAccess()
        access.validationFails = true
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: MemoryMountBookmarkStore())

        manager.addMount(URL(fileURLWithPath: "/private/Photos"))

        XCTAssertTrue(manager.additionalMounts.isEmpty)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testRemoveMountDropsFromListAndPersistedStore() {
        let access = MultiMountFolderAccess()
        let mountStore = MemoryMountBookmarkStore()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: mountStore)
        manager.addMount(URL(fileURLWithPath: "/private/Photos"))
        manager.addMount(URL(fileURLWithPath: "/private/Music"))

        manager.removeMount(named: "Photos")

        XCTAssertEqual(manager.additionalMounts.map(\.name), ["Music"])
        XCTAssertEqual(mountStore.mounts.map(\.name), ["Music"])
    }

    @MainActor
    func testRestoreMountsResolvesAllPersistedBookmarks() {
        let access = MultiMountFolderAccess()
        let firstManager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: MemoryMountBookmarkStore())
        firstManager.addMount(URL(fileURLWithPath: "/private/Photos"))
        firstManager.addMount(URL(fileURLWithPath: "/private/Music"))
        let mountStore = MemoryMountBookmarkStore(mounts: firstManager.additionalMounts.map {
            MountBookmark(name: $0.name, bookmark: $0.url.absoluteString.data(using: .utf8)!)
        })

        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: mountStore)
        manager.restoreMounts()

        XCTAssertEqual(Set(manager.additionalMounts.map(\.name)), Set(["Photos", "Music"]))
    }

    @MainActor
    func testRestoreMountsSkipsUnresolvableBookmarkWithoutAffectingOthers() {
        let access = MultiMountFolderAccess()
        let goodURL = URL(fileURLWithPath: "/private/Photos")
        let mountStore = MemoryMountBookmarkStore(mounts: [
            MountBookmark(name: "Broken", bookmark: Data([0xFF])),
            MountBookmark(name: "Photos", bookmark: goodURL.absoluteString.data(using: .utf8)!)
        ])
        access.unresolvableBookmarks = [Data([0xFF])]

        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: mountStore)
        manager.restoreMounts()

        XCTAssertEqual(manager.additionalMounts.map(\.name), ["Photos"])
        // The unresolvable mount's bookmark stays persisted for a future retry.
        XCTAssertEqual(mountStore.mounts.map(\.name), ["Broken", "Photos"])
    }

    @MainActor
    func testRestoreMountsRefreshesStaleBookmarkForThatMountOnly() {
        let access = MultiMountFolderAccess()
        let staleURL = URL(fileURLWithPath: "/private/Photos")
        access.staleURLs = [staleURL]
        let mountStore = MemoryMountBookmarkStore(mounts: [
            MountBookmark(name: "Photos", bookmark: staleURL.absoluteString.data(using: .utf8)!)
        ])

        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: mountStore)
        manager.restoreMounts()

        XCTAssertEqual(manager.additionalMounts.map(\.name), ["Photos"])
        XCTAssertEqual(access.events.filter { $0.hasPrefix("bookmark:") }, ["bookmark:Photos"])
    }

    @MainActor
    func testBeginAccessForMountNamedReturnsURLAndAcquiresScope() {
        let access = MultiMountFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: MemoryMountBookmarkStore())
        manager.addMount(URL(fileURLWithPath: "/private/Photos"))
        access.events = []

        let scoped = manager.beginAccess(forMountNamed: "Photos")

        XCTAssertEqual(scoped, URL(fileURLWithPath: "/private/Photos"))
        XCTAssertEqual(access.events, ["start:Photos"])
    }

    @MainActor
    func testBeginAccessForMountNamedReturnsNilForUnknownName() {
        let access = MultiMountFolderAccess()
        let manager = FolderRootManager(access: access, store: MemoryBookmarkStore(), mountStore: MemoryMountBookmarkStore())

        XCTAssertNil(manager.beginAccess(forMountNamed: "DoesNotExist"))
        XCTAssertTrue(access.events.isEmpty)
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

@MainActor
final class MemoryMountBookmarkStore: MountBookmarkStore {
    var mounts: [MountBookmark]
    init(mounts: [MountBookmark] = []) { self.mounts = mounts }
}

/// Unlike `StubFolderAccess` (one fixed URL for every call), this stub
/// round-trips each mount's own URL through its bookmark data (the URL's
/// `absoluteString`, UTF-8 encoded) so tests can exercise more than one
/// mount at once and assert on each by name.
@MainActor
final class MultiMountFolderAccess: FolderAccess {
    var grantsScope = true
    var validationFails = false
    var bookmarkFails = false
    var staleURLs: Set<URL> = []
    var unresolvableBookmarks: Set<Data> = []
    var events: [String] = []

    func startAccessing(_ url: URL) -> Bool {
        events.append("start:\(url.lastPathComponent)")
        return grantsScope
    }
    func stopAccessing(_ url: URL) { events.append("stop:\(url.lastPathComponent)") }
    func validateDirectory(_ url: URL) throws {
        events.append("validate:\(url.lastPathComponent)")
        if validationFails { throw FolderAccessError.notDirectory }
    }
    func makeBookmark(_ url: URL) throws -> Data {
        events.append("bookmark:\(url.lastPathComponent)")
        if bookmarkFails { throw CocoaError(.fileReadNoPermission) }
        return url.absoluteString.data(using: .utf8)!
    }
    func resolveBookmark(_ data: Data) throws -> (url: URL, stale: Bool) {
        if unresolvableBookmarks.contains(data) { throw CocoaError(.fileReadNoSuchFile) }
        guard let urlString = String(data: data, encoding: .utf8), let url = URL(string: urlString) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        events.append("resolve:\(url.lastPathComponent)")
        return (url, staleURLs.contains(url))
    }
}
