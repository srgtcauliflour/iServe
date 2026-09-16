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
        let port = try await service.start()
        XCTAssertEqual(access.events, ["start"])

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<html>ok</html>")

        service.stop()
        try await waitUntil { access.events.contains("stop") }
        XCTAssertEqual(access.events, ["start", "stop"])
    }

    @MainActor
    func testStartWithoutASelectedFolderThrows() async {
        let folders = FolderRootManager(access: StubFolderAccess(), store: MemoryBookmarkStore())
        let service = LiveServerService(folders: folders)
        do {
            _ = try await service.start()
            XCTFail("expected start() to throw with no folder selected")
        } catch {
            XCTAssertEqual(error as? LiveServerService.ServiceError, .noFolderSelected)
        }
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
            _ = try await service.start()
            XCTFail("expected start() to throw when scope cannot be acquired")
        } catch {
            XCTAssertEqual(error as? LiveServerService.ServiceError, .accessDenied)
        }
        XCTAssertEqual(access.events, ["start"])
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
