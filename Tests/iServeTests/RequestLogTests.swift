import XCTest
@testable import iServe

final class RequestLogTests: XCTestCase {
    func testRecordsTotalsAndReturnsMostRecentFirst() async {
        let log = RequestLog()
        await log.record(method: "GET", path: "/index.html", status: 200, bytes: 100)
        await log.record(method: "GET", path: "/style.css", status: 200, bytes: 50)
        await log.record(method: "GET", path: "/missing.txt", status: 404, bytes: 9)

        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 3)
        XCTAssertEqual(snapshot.totalBytes, 159)
        XCTAssertEqual(snapshot.entries.map(\.path), ["/missing.txt", "/style.css", "/index.html"])
        XCTAssertEqual(snapshot.entries.first?.status, 404)
    }

    func testBoundsEntriesToCapacityButKeepsCountingTotals() async {
        let log = RequestLog(capacity: 3)
        for i in 0..<10 {
            await log.record(method: "GET", path: "/file\(i)", status: 200, bytes: 1)
        }

        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 10)
        XCTAssertEqual(snapshot.totalBytes, 10)
        XCTAssertEqual(snapshot.entries.count, 3)
        // Most recent first: the last three recorded, newest first.
        XCTAssertEqual(snapshot.entries.map(\.path), ["/file9", "/file8", "/file7"])
    }

    func testEmptyLogSnapshotIsEmptyWithZeroTotals() async {
        let log = RequestLog()
        let snapshot = await log.snapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertEqual(snapshot.totalRequests, 0)
        XCTAssertEqual(snapshot.totalBytes, 0)
    }
}
