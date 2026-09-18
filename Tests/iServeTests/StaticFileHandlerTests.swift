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

    private func makeWritableHandler() -> StaticFileHandler {
        StaticFileHandler(resolver: SecurePathResolver(root: root), allowWebDAVWrites: true)
    }

    private func request(_ target: String, method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, target: target, httpVersion: "HTTP/1.1", headers: HTTPHeaders())
    }

    private func request(_ target: String, range: String) -> HTTPRequest {
        var headers = HTTPHeaders()
        headers.add(name: "Range", value: range)
        return HTTPRequest(method: "GET", target: target, httpVersion: "HTTP/1.1", headers: headers)
    }

    /// Index auto-serving is a `ServerProfile.websiteReadOnly`-only
    /// behavior (`allowDirectoryListing == false`) — see
    /// `testDirectoryListingModeAlwaysShowsTheListingEvenWithAnIndexFilePresent`
    /// below for the other three profiles, which always show the listing.
    func testPrefersIndexHtmlOverIndexHtmWhenBothExist() throws {
        try "html".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "htm".write(to: root.appendingPathComponent("index.htm"), atomically: true, encoding: .utf8)
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        let response = handler.route(request("/"))
        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url.lastPathComponent, "index.html")
    }

    func testFallsBackToIndexHtmWhenIndexHtmlIsAbsent() throws {
        try "htm".write(to: root.appendingPathComponent("index.htm"), atomically: true, encoding: .utf8)
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        let response = handler.route(request("/"))
        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url.lastPathComponent, "index.htm")
    }

    /// File Sharing (the default profile `makeHandler()` represents), File
    /// Drop, and Full Access all keep `allowDirectoryListing == true` and
    /// must always show the listing, never auto-serve an index page out
    /// from under it — a person still reaches that page by clicking its
    /// entry in the listing (a plain file GET, unaffected by this).
    func testDirectoryListingModeAlwaysShowsTheListingEvenWithAnIndexFilePresent() throws {
        try "<html>hi</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let response = makeHandler().route(request("/"))
        XCTAssertEqual(response.status, 200)
        guard case .data(let data) = response.body else { return XCTFail("expected a generated listing body") }
        let page = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(page.contains("notes.txt"))
        XCTAssertTrue(page.contains("index.html"))

        // Clicking the index file's own entry still serves it as a plain file.
        let fileResponse = makeHandler().route(request("/index.html"))
        XCTAssertEqual(fileResponse.status, 200)
        guard case .file(let file) = fileResponse.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url.lastPathComponent, "index.html")
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

    // MARK: - Directory listing (ServerProfile, v0.3)

    func testDirectoryWithNoIndexReturns404WhenDirectoryListingIsDisabled() throws {
        let dir = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "body".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        let response = handler.route(request("/empty/"))
        XCTAssertEqual(response.status, 404)
    }

    func testIndexFileIsStillServedWhenDirectoryListingIsDisabled() throws {
        try "html".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        let response = handler.route(request("/"))
        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url.lastPathComponent, "index.html")
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

    // MARK: - ZIP downloads (v0.3)

    func testDirectoryListingIncludesTheDownloadSelectedFormWhenNonEmpty() throws {
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/"))
        guard case .data(let data) = response.body else { return XCTFail("expected an in-memory HTML body") }
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("name=\"select\""))
        XCTAssertTrue(html.contains("Download Selected"))
    }

    func testDirectoryListingOmitsTheDownloadSelectedFormWhenEmpty() throws {
        let response = makeHandler().route(request("/"))
        guard case .data(let data) = response.body else { return XCTFail("expected an in-memory HTML body") }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("name=\"select\""))
    }

    func testAuthorizeZipDownloadAcceptsAnExistingDirectoryWithNoOptInRequired() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("photos"), withIntermediateDirectories: true)
        // Unlike uploads, this needs no `allowUploads`/opt-in flag at all.
        XCTAssertTrue(makeHandler().authorizeZipDownload(directoryPath: "/photos/"))
    }

    func testAuthorizeZipDownloadRefusesAMissingDirectory() {
        XCTAssertFalse(makeHandler().authorizeZipDownload(directoryPath: "/missing/"))
    }

    func testResolveZipEntriesResolvesEachPlainNameInsideTheDirectory() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let urls = makeHandler().resolveZipEntries(directoryPath: "/", names: ["a.txt", "b.txt"])
        XCTAssertEqual(Set(urls?.map(\.lastPathComponent) ?? []), ["a.txt", "b.txt"])
    }

    func testResolveZipEntriesRefusesTheWholeRequestIfOneNameIsMissing() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertNil(makeHandler().resolveZipEntries(directoryPath: "/", names: ["a.txt", "missing.txt"]))
    }

    func testResolveZipEntriesRejectsATraversalName() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertNil(makeHandler().resolveZipEntries(directoryPath: "/", names: ["a.txt", "../escape.txt"]))
    }

    func testResolveZipEntriesRejectsAnEmptySelection() {
        XCTAssertNil(makeHandler().resolveZipEntries(directoryPath: "/", names: []))
    }

    // MARK: - WebDAV (v0.3 read operations)

    func testRouteWebDAVPropfindOnATraversalPathReturnsBadRequest() {
        let response = makeHandler().routeWebDAVPropfind(path: "/../etc/passwd", depth: .zero)
        XCTAssertEqual(response?.status, 400)
    }

    func testRouteWebDAVPropfindOnASymlinkEscapeReturnsForbidden() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeStaticHandlerWebDAVOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )

        let response = makeHandler().routeWebDAVPropfind(path: "/escape/secret.txt", depth: .zero)
        XCTAssertEqual(response?.status, 403)
    }

    func testRouteWebDAVPropfindOnAMissingPathReturnsNotFound() {
        let response = makeHandler().routeWebDAVPropfind(path: "/missing.txt", depth: .zero)
        XCTAssertEqual(response?.status, 404)
    }

    // MARK: - WebDAV (v0.3 write operations)

    func testRouteWebDAVMkcolRefusesWhenWritesAreDisabled() {
        XCTAssertEqual(makeHandler().routeWebDAVMkcol(path: "/newdir")?.status, 404)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("newdir").path))
    }

    func testRouteWebDAVMkcolCreatesADirectoryWhenWritesAreEnabled() {
        let response = makeWritableHandler().routeWebDAVMkcol(path: "/newdir")
        XCTAssertEqual(response?.status, 201)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("newdir").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRouteWebDAVMkcolReturnsMethodNotAllowedWhenTargetAlreadyExists() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("existing"), withIntermediateDirectories: true)
        let response = makeWritableHandler().routeWebDAVMkcol(path: "/existing")
        XCTAssertEqual(response?.status, 405)
    }

    func testRouteWebDAVMkcolReturnsNotFoundWhenParentIsMissing() {
        let response = makeWritableHandler().routeWebDAVMkcol(path: "/missing/newdir")
        XCTAssertEqual(response?.status, 404)
    }

    func testRouteWebDAVDeleteRemovesAFile() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVDelete(path: "/a.txt")
        XCTAssertEqual(response?.status, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testRouteWebDAVDeleteRemovesADirectoryRecursively() throws {
        let dir = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "nested".write(to: dir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVDelete(path: "/dir")
        XCTAssertEqual(response?.status, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRouteWebDAVDeleteRefusesToDeleteTheRoot() {
        let response = makeWritableHandler().routeWebDAVDelete(path: "/")
        XCTAssertEqual(response?.status, 403)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRouteWebDAVDeleteReturnsNotFoundForAMissingPath() {
        XCTAssertEqual(makeWritableHandler().routeWebDAVDelete(path: "/missing.txt")?.status, 404)
    }

    func testRouteWebDAVDeleteRefusesWhenWritesAreDisabled() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(makeHandler().routeWebDAVDelete(path: "/a.txt")?.status, 404)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testRouteWebDAVMoveRenamesAFile() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVMove(sourcePath: "/a.txt", destinationHeader: "/b.txt", overwrite: true)
        XCTAssertEqual(response?.status, 201)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

    func testRouteWebDAVMoveAcceptsAnAbsoluteURLDestination() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVMove(
            sourcePath: "/a.txt", destinationHeader: "http://192.0.2.1:8080/b.txt", overwrite: true
        )
        XCTAssertEqual(response?.status, 201)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

    func testRouteWebDAVMoveReturns204WhenReplacingAnExistingDestination() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVMove(sourcePath: "/a.txt", destinationHeader: "/b.txt", overwrite: true)
        XCTAssertEqual(response?.status, 204)
    }

    func testRouteWebDAVMoveRefusesOverwriteWhenOverwriteIsFalseAndDestinationExists() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVMove(sourcePath: "/a.txt", destinationHeader: "/b.txt", overwrite: false)
        XCTAssertEqual(response?.status, 412)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "b")
    }

    func testRouteWebDAVMoveRefusesMovingADirectoryIntoItsOwnSubtree() throws {
        let dir = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let response = makeWritableHandler().routeWebDAVMove(sourcePath: "/dir", destinationHeader: "/dir/nested", overwrite: true)
        XCTAssertEqual(response?.status, 409)
    }

    func testRouteWebDAVMoveRequiresADestinationHeader() {
        let response = makeWritableHandler().routeWebDAVMove(sourcePath: "/a.txt", destinationHeader: nil, overwrite: true)
        XCTAssertEqual(response?.status, 400)
    }

    func testRouteWebDAVCopyDuplicatesAFileLeavingTheSourceInPlace() throws {
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let response = makeWritableHandler().routeWebDAVCopy(sourcePath: "/a.txt", destinationHeader: "/b.txt", overwrite: true)
        XCTAssertEqual(response?.status, 201)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "a")
    }

    func testAuthorizeWebDAVPutRefusesWhenWritesAreDisabled() {
        XCTAssertNil(makeHandler().authorizeWebDAVPut(path: "/new.txt"))
    }

    func testAuthorizeWebDAVPutProvidesATemporarySiblingAndReflectsExistingState() throws {
        let authorization = try XCTUnwrap(makeWritableHandler().authorizeWebDAVPut(path: "/new.txt"))
        XCTAssertFalse(authorization.alreadyExists)
        XCTAssertEqual(authorization.destinationURL.lastPathComponent, "new.txt")
        XCTAssertNotEqual(authorization.temporaryURL, authorization.destinationURL)
        XCTAssertEqual(authorization.temporaryURL.deletingLastPathComponent(), authorization.destinationURL.deletingLastPathComponent())

        try "existing".write(to: root.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        let existingAuthorization = try XCTUnwrap(makeWritableHandler().authorizeWebDAVPut(path: "/existing.txt"))
        XCTAssertTrue(existingAuthorization.alreadyExists)
    }

    func testAuthorizeWebDAVPutRefusesAnExistingDirectoryTarget() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        XCTAssertNil(makeWritableHandler().authorizeWebDAVPut(path: "/dir"))
    }

    func testAuthorizeWebDAVPutRefusesTheRootItself() {
        XCTAssertNil(makeWritableHandler().authorizeWebDAVPut(path: "/"))
    }

    func testAuthorizeWebDAVPutRefusesAMissingParentDirectory() {
        XCTAssertNil(makeWritableHandler().authorizeWebDAVPut(path: "/missing/new.txt"))
    }

    // MARK: - HTTP Range (v0.3)

    func testPlainRequestAdvertisesAcceptRanges() throws {
        try "0123456789".write(to: root.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/data.txt"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Accept-Ranges"], "bytes")
    }

    func testSatisfiableRangeReturns206WithContentRangeAndOnlyThatSpan() throws {
        try "0123456789".write(to: root.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/data.txt", range: "bytes=2-5"))
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 2-5/10")
        XCTAssertEqual(response.headers["Content-Length"], "4")
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.offset, 2)
        XCTAssertEqual(file.length, 4)
    }

    func testUnsatisfiableRangeReturns416WithContentRangeNamingTheFullSize() throws {
        try "0123456789".write(to: root.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let response = makeHandler().route(request("/data.txt", range: "bytes=1000-2000"))
        XCTAssertEqual(response.status, 416)
        XCTAssertEqual(response.headers["Content-Range"], "bytes */10")
    }

    func testUnrecognizedRangeSyntaxFallsBackToTheFullFile() throws {
        try "0123456789".write(to: root.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        // Multiple ranges aren't supported; RFC 7233 permits ignoring them.
        let response = makeHandler().route(request("/data.txt", range: "bytes=0-1,2-3"))
        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.offset, 0)
        XCTAssertEqual(file.length, 10)
    }

    func testRangeAppliesToAResolvedIndexFileToo() throws {
        try "0123456789".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let handler = StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: false)
        let response = handler.route(request("/", range: "bytes=0-3"))
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 0-3/10")
    }
}
