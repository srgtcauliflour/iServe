import XCTest
@testable import iServe

final class StaticFileHandlerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeStaticHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHandler() -> StaticFileHandler {
        StaticFileHandler(resolver: SecurePathResolver(root: root))
    }

    private func request(_ target: String, method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, target: target, httpVersion: "HTTP/1.1", headers: HTTPHeaders())
    }

    func testPrefersIndexHtmlOverIndexHtmWhenBothExist() throws {
        try "html".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "htm".write(to: root.appendingPathComponent("index.htm"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/"))
        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url.lastPathComponent, "index.html")
    }

    func testFallsBackToIndexHtmWhenIndexHtmlIsAbsent() throws {
        try "htm".write(to: root.appendingPathComponent("index.htm"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/"))
        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url.lastPathComponent, "index.htm")
    }

    func testDirectoryWithoutIndexReturnsAGeneratedListing() throws {
        let dir = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "body".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let response = makeHandler().route(request("/empty/"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
        guard case .data(let data) = response.body else { return XCTFail("expected an in-memory HTML body") }
        let page = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(page.contains("notes.txt"))
    }

    func testDirectoryRequestWithoutTrailingSlashRedirects() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"), withIntermediateDirectories: true
        )
        let response = makeHandler().route(request("/assets"))
        XCTAssertEqual(response.status, 301)
        XCTAssertEqual(response.headers["Location"], "/assets/")
        XCTAssertEqual(response.body, .empty)
    }

    func testRootDirectoryDoesNotRedirect() throws {
        let response = makeHandler().route(request("/"))
        // Root has no index either in this test, so it should list rather
        // than redirect (it's already slash-terminated) or 404.
        XCTAssertEqual(response.status, 200)
        XCTAssertNil(response.headers["Location"])
    }

    func testMissingFileReturns404() {
        let response = makeHandler().route(request("/missing.txt"))
        XCTAssertEqual(response.status, 404)
    }

    func testQueryStringIsStrippedBeforeResolving() throws {
        try "body".write(to: root.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/page.html?tracking=1&x=2"))
        XCTAssertEqual(response.status, 200)
    }

    func testContentTypeMatchesFileExtension() throws {
        try "{}".write(to: root.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/data.json"))
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
    }

    func testUnknownExtensionFallsBackToOctetStream() throws {
        try "???".write(to: root.appendingPathComponent("weird.xyzabc"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/weird.xyzabc"))
        XCTAssertEqual(response.headers["Content-Type"], "application/octet-stream")
    }

    func testTraversalAttemptReturns400() {
        let response = makeHandler().route(request("/../etc/passwd"))
        XCTAssertEqual(response.status, 400)
    }

    func testSymlinkEscapeReturns403() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeStaticHandlerOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )

        let response = makeHandler().route(request("/escape/secret.txt"))
        XCTAssertEqual(response.status, 403)
    }

    func testNestedAssetResolvesWithCorrectContentLength() throws {
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "body { color: red; }".write(to: assets.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        let response = makeHandler().route(request("/assets/style.css"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/css; charset=utf-8")
        XCTAssertEqual(response.headers["Content-Length"], "20")
    }

    // MARK: - Uploads

    func testDirectoryListingOmitsTheUploadFormWhenUploadsAreDisabled() throws {
        let response = makeHandler().route(request("/"))
        guard case .data(let data) = response.body else { return XCTFail("expected an in-memory HTML body") }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("enctype=\"multipart/form-data\""))
    }

    func testDirectoryListingIncludesTheUploadFormWhenUploadsAreEnabled() throws {
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        let response = handler.route(request("/"))
        guard case .data(let data) = response.body else { return XCTFail("expected an in-memory HTML body") }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("enctype=\"multipart/form-data\""))
    }

    func testAuthorizeUploadRefusesWhenUploadsAreDisabledEvenForARealDirectory() {
        XCTAssertFalse(makeHandler().authorizeUpload(directoryPath: "/"))
    }

    func testAuthorizeUploadAcceptsAnExistingDirectoryWhenEnabled() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("uploads"), withIntermediateDirectories: true)
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertTrue(handler.authorizeUpload(directoryPath: "/uploads/"))
    }

    func testAuthorizeUploadRefusesAPathThatIsNotADirectory() throws {
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertFalse(handler.authorizeUpload(directoryPath: "/file.txt/"))
    }

    func testAuthorizeUploadRefusesAMissingDirectory() {
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertFalse(handler.authorizeUpload(directoryPath: "/missing/"))
    }

    func testAuthorizeUploadedFileResolvesAPlainFilenameInsideTheDirectory() {
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        let url = handler.authorizeUploadedFile(directoryPath: "/", filename: "photo.jpg")
        XCTAssertEqual(url?.lastPathComponent, "photo.jpg")
    }

    func testAuthorizeUploadedFileRefusesWhenUploadsAreDisabled() {
        XCTAssertNil(makeHandler().authorizeUploadedFile(directoryPath: "/", filename: "photo.jpg"))
    }

    func testAuthorizeUploadedFileRefusesToOverwriteAnExistingFile() throws {
        try "existing".write(to: root.appendingPathComponent("photo.jpg"), atomically: true, encoding: .utf8)
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertNil(handler.authorizeUploadedFile(directoryPath: "/", filename: "photo.jpg"))
    }

    func testAuthorizeUploadedFileRejectsATraversalFilename() {
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertNil(handler.authorizeUploadedFile(directoryPath: "/", filename: "../escape.txt"))
    }

    func testAuthorizeUploadedFileRejectsAFilenameContainingASlash() {
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertNil(handler.authorizeUploadedFile(directoryPath: "/", filename: "a/b.txt"))
    }

    func testAuthorizeUploadedFileRejectsAnEmptyFilename() {
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true)
        XCTAssertNil(handler.authorizeUploadedFile(directoryPath: "/", filename: ""))
    }
}
