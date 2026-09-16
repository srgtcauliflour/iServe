import XCTest
@testable import iServe

final class ByteRangeParserTests: XCTestCase {
    func testNoHeaderIsNotRequested() {
        XCTAssertEqual(ByteRangeParser.parse(nil, fileSize: 1000), .notRequested)
    }

    func testStartAndEndIsSatisfiable() {
        let result = ByteRangeParser.parse("bytes=0-499", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 0, end: 499)))
    }

    func testMidRangeIsSatisfiable() {
        let result = ByteRangeParser.parse("bytes=200-299", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 200, end: 299)))
    }

    func testStartOnlyRangesToEndOfFile() {
        let result = ByteRangeParser.parse("bytes=900-", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 900, end: 999)))
    }

    func testSuffixRangeIsTheLastNBytes() {
        let result = ByteRangeParser.parse("bytes=-500", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 500, end: 999)))
    }

    func testSuffixRangeLongerThanFileClampsToTheWholeFile() {
        let result = ByteRangeParser.parse("bytes=-5000", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 0, end: 999)))
    }

    func testEndBeyondFileSizeClampsToTheLastByte() {
        let result = ByteRangeParser.parse("bytes=0-999999", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 0, end: 999)))
    }

    func testSingleByteRange() {
        let result = ByteRangeParser.parse("bytes=5-5", fileSize: 1000)
        XCTAssertEqual(result, .satisfiable(.init(start: 5, end: 5)))
        if case .satisfiable(let range) = result {
            XCTAssertEqual(range.length, 1)
        } else {
            XCTFail("expected a satisfiable range")
        }
    }

    func testStartAtOrBeyondFileSizeIsUnsatisfiable() {
        XCTAssertEqual(ByteRangeParser.parse("bytes=1000-1999", fileSize: 1000), .unsatisfiable)
        XCTAssertEqual(ByteRangeParser.parse("bytes=1000-", fileSize: 1000), .unsatisfiable)
    }

    func testEmptyFileIsAlwaysUnsatisfiable() {
        XCTAssertEqual(ByteRangeParser.parse("bytes=0-0", fileSize: 0), .unsatisfiable)
    }

    func testMultipleRangesAreNotSupportedAndFallBackToTheFullEntity() {
        XCTAssertEqual(ByteRangeParser.parse("bytes=0-499,500-999", fileSize: 1000), .notRequested)
    }

    func testMissingBytesPrefixIsNotRequested() {
        XCTAssertEqual(ByteRangeParser.parse("0-499", fileSize: 1000), .notRequested)
    }

    func testNonNumericBoundsAreNotRequested() {
        XCTAssertEqual(ByteRangeParser.parse("bytes=abc-def", fileSize: 1000), .notRequested)
    }

    func testEndBeforeStartIsNotRequested() {
        XCTAssertEqual(ByteRangeParser.parse("bytes=500-100", fileSize: 1000), .notRequested)
    }

    func testMalformedSyntaxIsNotRequested() {
        XCTAssertEqual(ByteRangeParser.parse("bytes=0-100-200", fileSize: 1000), .notRequested)
        XCTAssertEqual(ByteRangeParser.parse("bytes=", fileSize: 1000), .notRequested)
        XCTAssertEqual(ByteRangeParser.parse("bytes=-", fileSize: 1000), .notRequested)
    }
}
