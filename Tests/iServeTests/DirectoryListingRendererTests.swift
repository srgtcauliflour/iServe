import XCTest
@testable import iServe

final class DirectoryListingRendererTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeDirectoryListingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func html(requestPath: String = "/") -> String {
        String(decoding: DirectoryListingRenderer.render(directoryURL: root, requestPath: requestPath), as: UTF8.self)
    }

    func testListsDirectoriesBeforeFilesEachAlphabetically() throws {
        try "a".write(to: root.appendingPathComponent("zebra.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: root.appendingPathComponent("apple.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("zdir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("adir"), withIntermediateDirectories: true)

        let page = html()
        let adir = page.range(of: "adir")!
        let zdir = page.range(of: "zdir")!
        let apple = page.range(of: "apple.txt")!
        let zebra = page.range(of: "zebra.txt")!

        XCTAssertTrue(adir.lowerBound < zdir.lowerBound)
        XCTAssertTrue(zdir.lowerBound < apple.lowerBound, "directories must sort before files")
        XCTAssertTrue(apple.lowerBound < zebra.lowerBound)
    }

    func testOmitsHiddenEntries() throws {
        try "secret".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let page = html()
        XCTAssertFalse(page.contains(".hidden"))
        XCTAssertTrue(page.contains("visible.txt"))
    }

    func testEscapesHtmlSignificantCharactersInFileNames() throws {
        let name = "<script>.txt"
        try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let page = html()
        XCTAssertFalse(page.contains("<script>.txt"))
        XCTAssertTrue(page.contains("&lt;script&gt;.txt"))
    }

    func testShowsUpLinkExceptAtRoot() throws {
        XCTAssertFalse(html(requestPath: "/").contains("href=\"../\""))
        XCTAssertTrue(html(requestPath: "/assets/").contains("href=\"../\""))
    }

    func testEmptyDirectoryShowsAMessage() {
        XCTAssertTrue(html().contains("Empty folder"))
    }

    func testDirectoryEntryLinkHasTrailingSlashAndNoSize() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let page = html()
        XCTAssertTrue(page.contains("href=\"sub/\">sub/</a></li>"))
    }

    func testOmitsTheUploadFormByDefault() {
        XCTAssertFalse(html().contains("<form"))
    }

    func testIncludesAMultipartUploadFormWhenAllowUploadsIsTrue() {
        let page = String(
            decoding: DirectoryListingRenderer.render(directoryURL: root, requestPath: "/", allowUploads: true),
            as: UTF8.self
        )
        XCTAssertTrue(page.contains("<form"))
        XCTAssertTrue(page.contains("method=\"POST\""))
        XCTAssertTrue(page.contains("enctype=\"multipart/form-data\""))
        XCTAssertTrue(page.contains("type=\"file\""))
    }
}
