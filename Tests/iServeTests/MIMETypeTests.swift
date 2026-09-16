import XCTest
@testable import iServe

final class MIMETypeTests: XCTestCase {
    func testCommonExtensionsMapToExpectedTypes() {
        XCTAssertEqual(MIMEType.forPathExtension("html"), "text/html; charset=utf-8")
        XCTAssertEqual(MIMEType.forPathExtension("css"), "text/css; charset=utf-8")
        XCTAssertEqual(MIMEType.forPathExtension("js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(MIMEType.forPathExtension("json"), "application/json")
        XCTAssertEqual(MIMEType.forPathExtension("svg"), "image/svg+xml")
        XCTAssertEqual(MIMEType.forPathExtension("png"), "image/png")
        XCTAssertEqual(MIMEType.forPathExtension("mp3"), "audio/mpeg")
        XCTAssertEqual(MIMEType.forPathExtension("mp4"), "video/mp4")
        XCTAssertEqual(MIMEType.forPathExtension("pdf"), "application/pdf")
        XCTAssertEqual(MIMEType.forPathExtension("zip"), "application/zip")
        XCTAssertEqual(MIMEType.forPathExtension("woff2"), "font/woff2")
    }

    func testExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(MIMEType.forPathExtension("HTML"), MIMEType.forPathExtension("html"))
        XCTAssertEqual(MIMEType.forPathExtension("PnG"), "image/png")
    }

    func testUnknownExtensionFallsBackToOctetStream() {
        XCTAssertEqual(MIMEType.forPathExtension("madeupextension"), MIMEType.binaryFallback)
        XCTAssertEqual(MIMEType.forPathExtension(""), MIMEType.binaryFallback)
    }
}
