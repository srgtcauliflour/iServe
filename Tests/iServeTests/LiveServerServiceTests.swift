import XCTest
@testable import iServe

final class LiveServerServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeLiveServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testStartServesTheSelectedFolderAndStopReleasesScope() async throws {
        try "<html>ok</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        folders.select(root)
        access.events = []

        let service = LiveServerService(folders: folders)
        XCTAssertNil(service.requestLog)

        let port = try await service.start(allowUploads: false, credentials: nil)
        XCTAssertEqual(access.events, ["start"])
        XCTAssertNotNil(service.requestLog)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<html>ok</html>")

        let log = try XCTUnwrap(service.requestLog)
        let snapshot = try await waitForSnapshot(log, expectingAtLeast: 1)
        XCTAssertEqual(snapshot.totalRequests, 1)
        XCTAssertEqual(snapshot.entries.first?.path, "/")
        XCTAssertEqual(snapshot.entries.first?.status, 200)

        service.stop()
        try await waitUntil { access.events.contains("stop") }
        XCTAssertEqual(access.events, ["start", "stop"])
        XCTAssertNil(service.requestLog)
    }

    @MainActor
    func testStartWithoutASelectedFolderThrows() async {
        let folders = FolderRootManager(access: StubFolderAccess(), store: MemoryBookmarkStore())
        let service = LiveServerService(folders: folders)
        do {
            _ = try await service.start(allowUploads: false, credentials: nil)
            XCTFail("expected start() to throw with no folder selected")
        } catch {
            XCTAssertEqual(error as? LiveServerService.ServiceError, .noFolderSelected)
        }
    }

    @MainActor
    func testStartWithCredentialsRequiresAMatchingPasswordOverLoopback() async throws {
        try "<html>secret</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        folders.select(root)

        let service = LiveServerService(folders: folders)
        let port = try await service.start(allowUploads: false, credentials: ServerCredentials(password: "letmein"))

        let (_, unauthorizedResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)

        var authorizedRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        let encodedCredentials = Data(":letmein".utf8).base64EncodedString()
        authorizedRequest.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        let (data, authorizedResponse) = try await URLSession.shared.data(for: authorizedRequest)
        XCTAssertEqual((authorizedResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<html>secret</html>")

        service.stop()
    }

    @MainActor
    func testStartWhenAccessIsDeniedThrowsAndDoesNotLeaveScopeHeld() async {
        let access = StubFolderAccess()
        let folders = FolderRootManager(access: access, store: MemoryBookmarkStore())
        folders.select(root)
        XCTAssertNotNil(folders.selectedURL)

        access.grantsScope = false
        access.events = []

        let service = LiveServerService(folders: folders)
        do {
            _ = try await service.start(allowUploads: false, credentials: nil)
            XCTFail("expected start() to throw when scope cannot be acquired")
        } catch {
            XCTAssertEqual(error as? LiveServerService.ServiceError, .accessDenied)
        }
        XCTAssertEqual(access.events, ["start"])
    }

    @MainActor
    private func waitForSnapshot(
        _ log: RequestLog,
        expectingAtLeast count: Int,
        timeout: TimeInterval = 2
    ) async throws -> RequestLog.Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let snapshot = await log.snapshot()
            if snapshot.totalRequests >= count || Date() > deadline {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
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
