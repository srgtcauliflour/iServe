import XCTest
@testable import iServe

final class PHPDiagnosticsLogTests: XCTestCase {
    func testRecordsEntriesAndReturnsMostRecentFirst() async {
        let log = PHPDiagnosticsLog()
        await log.record(scriptPath: "/root/index.php", message: "Notice: Undefined variable $x")
        await log.record(scriptPath: "/root/submit.php", message: "Warning: division by zero")

        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.map(\.message), [
            "Warning: division by zero",
            "Notice: Undefined variable $x",
        ])
        XCTAssertEqual(snapshot.first?.scriptPath, "/root/submit.php")
    }

    func testBoundsEntriesToCapacity() async {
        let log = PHPDiagnosticsLog(capacity: 3)
        for i in 0..<10 {
            await log.record(scriptPath: "/root/script\(i).php", message: "error \(i)")
        }

        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        // Most recent first: the last three recorded, newest first.
        XCTAssertEqual(snapshot.map(\.message), ["error 9", "error 8", "error 7"])
    }

    func testEmptyLogSnapshotIsEmpty() async {
        let log = PHPDiagnosticsLog()
        let snapshot = await log.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }
}
