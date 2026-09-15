import XCTest
@testable import iServe

final class ServerCoordinatorTests: XCTestCase {
    @MainActor
    func testInitialStateDoesNotStartOrStopAnyService() {
        let service = RecordingServerService()
        let coordinator = ServerCoordinator(service: service)
        XCTAssertEqual(coordinator.state, .awaitingFolder)
        XCTAssertEqual(service.stopCount, 0)
    }

    @MainActor
    func testLeavingActiveSceneAlwaysStopsService() {
        let service = RecordingServerService()
        let coordinator = ServerCoordinator(service: service)
        coordinator.leaveActiveScene()
        XCTAssertEqual(service.stopCount, 1)
        XCTAssertEqual(coordinator.state, .unavailable)
    }

    @MainActor
    func testRepeatedInactiveAndBackgroundNotificationsAreSafe() {
        let service = RecordingServerService()
        let coordinator = ServerCoordinator(service: service)
        coordinator.leaveActiveScene()
        coordinator.leaveActiveScene()
        coordinator.stop()
        XCTAssertEqual(service.stopCount, 3)
        XCTAssertEqual(coordinator.state, .unavailable)
    }

    @MainActor
    func testFolderReplacementStopsServiceBeforeAcquiringNewRoot() {
        let service = RecordingServerService()
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(service: service, folders: folders)
        access.onStart = { XCTAssertEqual(service.stopCount, 1) }
        coordinator.selectFolder(access.url)
        XCTAssertEqual(folders.selectedURL, access.url)
        coordinator.forgetFolder()
        XCTAssertEqual(service.stopCount, 2)
        XCTAssertNil(folders.selectedURL)
    }

    @MainActor
    func testSceneExitRetainsBookmarkWithoutHoldingAnyScope() {
        let service = RecordingServerService()
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(service: service, folders: folders)
        coordinator.selectFolder(access.url)
        coordinator.leaveActiveScene()
        XCTAssertTrue(folders.hasSavedFolder)
        XCTAssertEqual(access.events.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(access.events.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(service.stopCount, 2)
    }

    @MainActor
    func testProductionBootstrapCanStopBeforeStart() {
        let coordinator = ServerCoordinator()
        coordinator.stop()
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .unavailable)
    }
}

@MainActor
private final class RecordingServerService: ServerService {
    var stopCount = 0
    func stop() { stopCount += 1 }
}
