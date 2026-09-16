import XCTest
@testable import iServe

final class ServerCoordinatorTests: XCTestCase {
    @MainActor
    func testInitialStateDoesNotStartOrStopAnyService() {
        let service = RecordingServerService()
        let coordinator = ServerCoordinator(service: service)
        XCTAssertEqual(coordinator.state, .noFolder)
        XCTAssertEqual(service.stopCount, 0)
        XCTAssertEqual(service.startCallCount, 0)
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

    @MainActor
    func testStartWithoutAFolderStaysInNoFolderStateAndNeverCallsTheService() {
        let service = RecordingServerService()
        let coordinator = ServerCoordinator(service: service)
        coordinator.start()
        XCTAssertEqual(coordinator.state, .noFolder)
        XCTAssertEqual(service.startCallCount, 0)
    }

    @MainActor
    func testStartSucceedsAndReportsRunningEndpoint() async throws {
        let service = RecordingServerService()
        service.startResult = .success(4321)
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(
            service: service, folders: folders, ipAddressProvider: { "192.0.2.1" }
        )
        coordinator.selectFolder(access.url)

        coordinator.start()
        XCTAssertEqual(coordinator.state, .starting)

        try await waitUntil { coordinator.state != .starting }
        XCTAssertEqual(coordinator.state, .running(endpoint: "http://192.0.2.1:4321/"))
        XCTAssertEqual(service.startCallCount, 1)
    }

    @MainActor
    func testCallingStartAgainWhileRunningDoesNotRestartTheService() async throws {
        let service = RecordingServerService()
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(
            service: service, folders: folders, ipAddressProvider: { "192.0.2.1" }
        )
        coordinator.selectFolder(access.url)
        coordinator.start()
        try await waitUntil { coordinator.state != .starting }

        coordinator.start()
        XCTAssertEqual(service.startCallCount, 1)
    }

    @MainActor
    func testStartFailureSetsErrorStateWithoutLeakingUnderlyingDetail() async throws {
        struct UnderlyingError: Error { let detail = "/private/var/mobile/sensitive" }
        let service = RecordingServerService()
        service.startResult = .failure(UnderlyingError())
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(service: service, folders: folders)
        coordinator.selectFolder(access.url)

        coordinator.start()
        try await waitUntil { coordinator.state != .starting }

        guard case .error(let message) = coordinator.state else {
            return XCTFail("expected an error state, got \(coordinator.state)")
        }
        XCTAssertFalse(message.contains("/private"))
        XCTAssertFalse(message.contains("mobile"))
    }

    @MainActor
    func testListenerFailureNamesTheFailureWithoutLeakingItsRawDescription() async throws {
        let service = RecordingServerService()
        service.startResult = .failure(HTTPServer.ServerError.listenerFailed("POSIXErrorCode(48): Address already in use"))
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(service: service, folders: folders)
        coordinator.selectFolder(access.url)

        coordinator.start()
        try await waitUntil { coordinator.state != .starting }

        guard case .error(let message) = coordinator.state else {
            return XCTFail("expected an error state, got \(coordinator.state)")
        }
        XCTAssertTrue(message.contains("Local Network"))
    }

    @MainActor
    func testAccessDeniedFailureNamesFolderAccessRatherThanAGenericMessage() async throws {
        let service = RecordingServerService()
        service.startResult = .failure(LiveServerService.ServiceError.accessDenied)
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(service: service, folders: folders)
        coordinator.selectFolder(access.url)

        coordinator.start()
        try await waitUntil { coordinator.state != .starting }

        guard case .error(let message) = coordinator.state else {
            return XCTFail("expected an error state, got \(coordinator.state)")
        }
        XCTAssertTrue(message.contains("access the selected folder"))
    }

    @MainActor
    func testStoppingAfterRunningStopsTheServiceAndReturnsToUnavailable() async throws {
        let service = RecordingServerService()
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        let coordinator = ServerCoordinator(
            service: service, folders: folders, ipAddressProvider: { "192.0.2.1" }
        )
        coordinator.selectFolder(access.url)
        coordinator.start()
        try await waitUntil { coordinator.state != .starting }

        coordinator.stop()
        XCTAssertEqual(coordinator.state, .unavailable)
        XCTAssertEqual(service.stopCount, 2) // once from selectFolder, once from stop()
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition never became true within \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
private final class RecordingServerService: ServerService {
    var stopCount = 0
    var startCallCount = 0
    var startResult: Result<UInt16, Error> = .success(8080)
    var requestLog: RequestLog?

    func start() async throws -> UInt16 {
        startCallCount += 1
        return try startResult.get()
    }

    func stop() { stopCount += 1 }
}
