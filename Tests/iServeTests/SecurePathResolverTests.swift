import XCTest
@testable import iServe

final class SecurePathResolverTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - Valid paths resolve inside the root

    func testResolvesRootRequest() throws {
        let resolver = SecurePathResolver(root: rootURL)
        let resolved = try resolver.resolve(requestPath: "/")
        XCTAssertEqual(resolved.path, rootURL.resolvingSymlinksInPath().path)
    }

    func testResolvesNestedExistingFile() throws {
        let sub = try makeDirectory("assets")
        let file = try write("style.css", in: sub)
        let resolver = SecurePathResolver(root: rootURL)
        let resolved = try resolver.resolve(requestPath: "/assets/style.css")
        XCTAssertEqual(resolved.path, file.resolvingSymlinksInPath().path)
    }

    func testResolvesMissingFinalComponentForNotFoundHandling() throws {
        let resolver = SecurePathResolver(root: rootURL)
        let resolved = try resolver.resolve(requestPath: "/missing.html")
        XCTAssertEqual(resolved.deletingLastPathComponent().path, rootURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolved.lastPathComponent, "missing.html")
    }

    func testCollapsesRepeatedSlashesWithoutEscaping() throws {
        let sub = try makeDirectory("assets")
        _ = try write("logo.png", in: sub)
        let resolver = SecurePathResolver(root: rootURL)
        let resolved = try resolver.resolve(requestPath: "//assets//logo.png")
        XCTAssertTrue(resolved.path.hasSuffix("assets/logo.png"))
    }

    func testAllowsUnicodeFileName() throws {
        let file = try write("café.txt")
        let resolver = SecurePathResolver(root: rootURL)
        let resolved = try resolver.resolve(requestPath: "/caf%C3%A9.txt")
        XCTAssertEqual(resolved.path, file.resolvingSymlinksInPath().path)
    }

    // MARK: - Hostile traversal corpus

    func testRejectsParentTraversal() {
        assertRejected("/../etc/passwd", as: .forbiddenComponent)
    }

    func testRejectsNestedParentTraversal() {
        assertRejected("/a/../../etc/passwd", as: .forbiddenComponent)
    }

    func testRejectsSingleDotComponent() {
        assertRejected("/./secret", as: .forbiddenComponent)
    }

    func testRejectsEncodedParentTraversal() {
        assertRejected("/%2e%2e/etc/passwd", as: .forbiddenComponent)
    }

    func testRejectsMixedCaseEncodedParentTraversal() {
        assertRejected("/%2E%2E/etc/passwd", as: .forbiddenComponent)
    }

    func testRejectsEncodedSlashSmuggling() {
        assertRejected("/%2Fetc%2Fpasswd", as: .forbiddenComponent)
    }

    func testRejectsFullyEncodedTraversalWithEncodedSeparators() {
        assertRejected("/%2e%2e%2f%2e%2e%2fetc%2fpasswd", as: .forbiddenComponent)
    }

    func testDoubleEncodedTraversalDoesNotEscapeRoot() {
        // Decoding exactly once turns the first segment into the literal,
        // nonexistent directory name "%2e%2e", never into "..". It therefore
        // fails closed as an ordinary missing intermediate component (.notFound)
        // rather than escaping the root or resolving to anything at all.
        assertRejected("/%252e%252e/etc/passwd", as: .notFound)
    }

    func testRejectsMalformedPercentEncodingTruncated() {
        assertRejected("/a%2", as: .malformedEncoding)
    }

    func testRejectsMalformedPercentEncodingNonHex() {
        assertRejected("/a%zz", as: .malformedEncoding)
    }

    func testRejectsMalformedPercentEncodingAtEndOfSegment() {
        assertRejected("/a%", as: .malformedEncoding)
    }

    func testRejectsNullByte() {
        assertRejected("/a%00.txt", as: .invalidCharacter)
    }

    func testRejectsControlCharacter() {
        assertRejected("/a%0a.txt", as: .invalidCharacter)
    }

    func testRejectsBackslashSeparatorAmbiguity() {
        assertRejected("/a%5c..%5cetc", as: .forbiddenComponent)
    }

    func testRejectsRequestPathMissingLeadingSlash() {
        assertRejected("etc/passwd", as: .invalidRequestPath)
    }

    func testRejectsTraversalThroughExistingIntermediateFile() throws {
        _ = try write("file.txt")
        let resolver = SecurePathResolver(root: rootURL)
        XCTAssertThrowsError(try resolver.resolve(requestPath: "/file.txt/more")) { error in
            XCTAssertEqual(error as? SecurePathResolver.ResolutionError, .notFound)
        }
    }

    func testRejectsMissingIntermediateDirectory() {
        assertRejected("/missing-dir/file.txt", as: .notFound)
    }

    // MARK: - Symlink escape behavior

    func testSymlinkedDirectoryInsideRootIsAllowed() throws {
        let real = try makeDirectory("real")
        _ = try write("inside.txt", in: real)
        let link = rootURL.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolver = SecurePathResolver(root: rootURL)
        let resolved = try resolver.resolve(requestPath: "/linked/inside.txt")
        XCTAssertEqual(resolved.path, real.appendingPathComponent("inside.txt").resolvingSymlinksInPath().path)
    }

    func testSymlinkedDirectoryEscapingRootIsRejected() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeResolverOutsideDir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "top secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let link = rootURL.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let resolver = SecurePathResolver(root: rootURL)
        XCTAssertThrowsError(try resolver.resolve(requestPath: "/escape/secret.txt")) { error in
            XCTAssertEqual(error as? SecurePathResolver.ResolutionError, .escapesRoot)
        }
    }

    func testSymlinkedFileEscapingRootIsRejected() throws {
        let outsideFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeResolverOutsideFile-\(UUID().uuidString).txt")
        try "top secret".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let link = rootURL.appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)

        let resolver = SecurePathResolver(root: rootURL)
        XCTAssertThrowsError(try resolver.resolve(requestPath: "/leak.txt")) { error in
            XCTAssertEqual(error as? SecurePathResolver.ResolutionError, .escapesRoot)
        }
    }

    // MARK: - Error safety

    func testErrorsNeverExposeAbsoluteLocalPaths() {
        let resolver = SecurePathResolver(root: rootURL)
        do {
            _ = try resolver.resolve(requestPath: "/../etc/passwd")
            XCTFail("expected traversal to be rejected")
        } catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains(rootURL.path))
            XCTAssertFalse(description.contains("/etc/passwd"))
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, in directory: URL? = nil, contents: String = "ok") throws -> URL {
        let target = (directory ?? rootURL).appendingPathComponent(name)
        try contents.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private func makeDirectory(_ name: String, in directory: URL? = nil) throws -> URL {
        let target = (directory ?? rootURL).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    private func assertRejected(
        _ requestPath: String,
        as expected: SecurePathResolver.ResolutionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolver = SecurePathResolver(root: rootURL)
        XCTAssertThrowsError(try resolver.resolve(requestPath: requestPath), file: file, line: line) { error in
            XCTAssertEqual(error as? SecurePathResolver.ResolutionError, expected, file: file, line: line)
        }
    }
}
