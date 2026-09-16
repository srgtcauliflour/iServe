import XCTest
@testable import iServe

final class HTTPRouterTests: XCTestCase {
    func testHeadersLookupIsCaseInsensitiveAndPreservesInsertionOrder() {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        headers.add(name: "X-Custom", value: "one")
        headers.add(name: "x-custom", value: "two")

        XCTAssertEqual(headers["content-type"], "text/plain")
        // Lookup returns the first matching field, matching HTTP's usual convention.
        XCTAssertEqual(headers["X-CUSTOM"], "one")
        XCTAssertEqual(headers.count, 3)
    }

    func testPlainTextResponseSetsExpectedHeaders() {
        let response = HTTPResponse.plainText(status: 404, reason: "Not Found", message: "nope")
        XCTAssertEqual(response.headers["Content-Length"], "4")
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertEqual(response.headers["Connection"], "close")
        XCTAssertEqual(response.body, .data(Data("nope".utf8)))
    }

    func testHeadEncodedProducesAStatusLineHeadersAndBlankLineTerminator() {
        let response = HTTPResponse.notFound()
        let encoded = String(decoding: response.headEncoded(), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(encoded.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(encoded.contains("Content-Length: 9\r\n"))
    }

    func testNotFoundRouterRespondsToAnyRequestWith404() {
        let router = NotFoundRouter()
        let request = HTTPRequest(method: "GET", target: "/anything", httpVersion: "HTTP/1.1", headers: HTTPHeaders())
        let response = router.route(request)
        XCTAssertEqual(response.status, 404)
    }

    func testLengthRequiredAndPayloadTooLargeUseTheExpectedStatusCodes() {
        XCTAssertEqual(HTTPResponse.lengthRequired().status, 411)
        XCTAssertEqual(HTTPResponse.payloadTooLarge().status, 413)
    }

    func testHTTPRouterDefaultImplementationsRefuseEveryUpload() {
        let router = NotFoundRouter()
        XCTAssertFalse(router.authorizeUpload(directoryPath: "/"))
        XCTAssertNil(router.authorizeUploadedFile(directoryPath: "/", filename: "anything.txt"))
    }
}
