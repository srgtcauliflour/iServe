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

    func testHTTPRouterDefaultImplementationDoesNotSupportWebDAV() {
        let router = NotFoundRouter()
        XCTAssertNil(router.routeWebDAVPropfind(path: "/", depth: .zero))
    }

    func testHTTPRouterDefaultImplementationsDoNotSupportWebDAVWrites() {
        let router = NotFoundRouter()
        XCTAssertNil(router.routeWebDAVMkcol(path: "/"))
        XCTAssertNil(router.routeWebDAVDelete(path: "/a.txt"))
        XCTAssertNil(router.routeWebDAVMove(sourcePath: "/a.txt", destinationHeader: "/b.txt", overwrite: true))
        XCTAssertNil(router.routeWebDAVCopy(sourcePath: "/a.txt", destinationHeader: "/b.txt", overwrite: true))
        XCTAssertNil(router.authorizeWebDAVPut(path: "/a.txt"))
    }

    func testWebDAVOptionsAdvertisesEveryMethodAndDAVLevel1() {
        let response = HTTPResponse.webDAVOptions()
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["DAV"], "1")
        XCTAssertEqual(response.headers["Allow"], "GET, HEAD, POST, OPTIONS, PROPFIND, MKCOL, PUT, DELETE, MOVE, COPY")
    }

    func testWebDAVMultiStatusSetsExpectedHeaders() {
        let body = Data("<D:multistatus/>".utf8)
        let response = HTTPResponse.webDAVMultiStatus(body)
        XCTAssertEqual(response.status, 207)
        XCTAssertEqual(response.headers["Content-Type"], "application/xml; charset=utf-8")
        XCTAssertEqual(response.headers["Content-Length"], String(body.count))
        XCTAssertEqual(response.body, .data(body))
    }

    func testWebDAVWriteStatusHelpersUseTheExpectedCodes() {
        XCTAssertEqual(HTTPResponse.created().status, 201)
        XCTAssertEqual(HTTPResponse.noContent().status, 204)
        XCTAssertEqual(HTTPResponse.conflict().status, 409)
        XCTAssertEqual(HTTPResponse.methodNotAllowed().status, 405)
        XCTAssertEqual(HTTPResponse.preconditionFailed().status, 412)
    }

    func testCreatedAndNoContentHaveEmptyBodies() {
        XCTAssertEqual(HTTPResponse.created().body, .empty)
        XCTAssertEqual(HTTPResponse.noContent().body, .empty)
    }
}
