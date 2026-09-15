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
