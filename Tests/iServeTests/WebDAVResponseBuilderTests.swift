import XCTest
@testable import iServe

/// Pure rendering tests for `Handlers/WebDAVResponseBuilder.swift` — no
/// filesystem, no networking. `StaticFileHandler`'s own entry-construction
/// (hidden-entry omission, depth handling, capability gating) is covered by
/// `WebDAVLifecycleTests.swift`'s real loopback round trips instead.
final class WebDAVResponseBuilderTests: XCTestCase {
    func testCollectionEntryRendersResourcetypeCollection() {
        let entry = WebDAVResponseBuilder.Entry(
            href: "/photos/", isCollection: true, length: nil, lastModified: nil,
            contentType: nil, displayName: "photos"
        )
        let xml = String(decoding: WebDAVResponseBuilder.multiStatus(entries: [entry]), as: UTF8.self)
        XCTAssertTrue(xml.contains("<D:resourcetype><D:collection/></D:resourcetype>"))
        XCTAssertTrue(xml.contains("<D:href>/photos/</D:href>"))
        XCTAssertFalse(xml.contains("<D:getcontentlength>"))
    }

    func testFileEntryRendersEmptyResourcetypeAndContentProperties() {
        let entry = WebDAVResponseBuilder.Entry(
            href: "/a.txt", isCollection: false, length: 42, lastModified: nil,
            contentType: "text/plain", displayName: "a.txt"
        )
        let xml = String(decoding: WebDAVResponseBuilder.multiStatus(entries: [entry]), as: UTF8.self)
        XCTAssertTrue(xml.contains("<D:resourcetype/>"))
        XCTAssertTrue(xml.contains("<D:getcontentlength>42</D:getcontentlength>"))
        XCTAssertTrue(xml.contains("<D:getcontenttype>text/plain</D:getcontenttype>"))
    }

    func testDisplayNameAndHrefAreEscaped() {
        let entry = WebDAVResponseBuilder.Entry(
            href: "/a&b.txt", isCollection: false, length: 1, lastModified: nil,
            contentType: "text/plain", displayName: "a&b<c>.txt"
        )
        let xml = String(decoding: WebDAVResponseBuilder.multiStatus(entries: [entry]), as: UTF8.self)
        XCTAssertTrue(xml.contains("<D:href>/a&amp;b.txt</D:href>"))
        XCTAssertTrue(xml.contains("<D:displayname>a&amp;b&lt;c&gt;.txt</D:displayname>"))
    }

    func testMultipleEntriesEachGetTheirOwnResponseElement() {
        let entries = [
            WebDAVResponseBuilder.Entry(href: "/", isCollection: true, length: nil, lastModified: nil, contentType: nil, displayName: "root"),
            WebDAVResponseBuilder.Entry(href: "/a.txt", isCollection: false, length: 1, lastModified: nil, contentType: "text/plain", displayName: "a.txt"),
        ]
        let xml = String(decoding: WebDAVResponseBuilder.multiStatus(entries: entries), as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<D:response>").count - 1, 2)
    }

    func testEveryResponseReportsStatus200OK() {
        let entry = WebDAVResponseBuilder.Entry(
            href: "/a.txt", isCollection: false, length: 1, lastModified: nil,
            contentType: "text/plain", displayName: "a.txt"
        )
        let xml = String(decoding: WebDAVResponseBuilder.multiStatus(entries: [entry]), as: UTF8.self)
        XCTAssertTrue(xml.contains("<D:status>HTTP/1.1 200 OK</D:status>"))
    }
}
