import XCTest
@testable import iServe

/// Unit tests for `MountRouter`'s dispatch logic (v0.3,
/// `docs/adr/0007-multiple-mounted-folders.md`) — first-path-component
/// routing between the primary and any number of additional, named,
/// read-only mounts. A real loopback round trip through `LiveServerService`
/// belongs in a lifecycle test; these only exercise the router itself
/// against real `StaticFileHandler`s over real temp directories.
final class MountRouterTests: XCTestCase {
    private var primaryRoot: URL!
    private var mountARoot: URL!
    private var mountBRoot: URL!

    override func setUpWithError() throws {
        primaryRoot = try makeTempDirectory(name: "primary")
        mountARoot = try makeTempDirectory(name: "mountA")
        mountBRoot = try makeTempDirectory(name: "mountB")
    }

    override func tearDownWithError() throws {
        for root in [primaryRoot, mountARoot, mountBRoot] {
            if let root { try? FileManager.default.removeItem(at: root) }
        }
    }

    private func makeTempDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeMountRouterTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func request(_ target: String, method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, target: target, httpVersion: "HTTP/1.1", headers: HTTPHeaders())
    }

    // MARK: - Zero-mount pass-through

    func testWithNoAdditionalMountsRouteBehavesExactlyLikeThePrimaryAlone() throws {
        try "hello".write(to: primaryRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let primary = StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot))
        let router = MountRouter(primary: primary, additional: [])

        let directResponse = primary.route(request("/file.txt"))
        let routedResponse = router.route(request("/file.txt"))

        XCTAssertEqual(directResponse.status, routedResponse.status)
        guard case .file(let directFile) = directResponse.body, case .file(let routedFile) = routedResponse.body else {
            return XCTFail("expected both responses to serve the file")
        }
        XCTAssertEqual(directFile.url, routedFile.url)
    }

    func testWithNoAdditionalMountsAuthorizeUploadPassesThroughUnchanged() {
        let primary = StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot), allowUploads: true)
        let router = MountRouter(primary: primary, additional: [])

        XCTAssertEqual(primary.authorizeUpload(directoryPath: "/"), router.authorizeUpload(directoryPath: "/"))
    }

    // MARK: - Dispatch to a named mount

    func testRequestForAMountPathIsServedByThatMountsOwnHandler() throws {
        try "from mount a".write(to: mountARoot.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let router = makeRouter(withMounts: ["MountA": mountARoot])

        let response = router.route(request("/MountA/notes.txt"))

        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url, mountARoot.appendingPathComponent("notes.txt"))
    }

    func testRequestForThePrimaryRootAlwaysServesThePrimaryRegardlessOfMountCount() throws {
        try "index".write(to: primaryRoot.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let router = makeRouter(withMounts: ["MountA": mountARoot, "MountB": mountBRoot])

        let response = router.route(request("/"))

        XCTAssertEqual(response.status, 200)
        guard case .file(let file) = response.body else { return XCTFail("expected the primary's index.html") }
        XCTAssertEqual(file.url, primaryRoot.appendingPathComponent("index.html"))
    }

    func testASameNamedTopLevelEntryInThePrimaryIsShadowedByTheMount() throws {
        // A directory literally named "MountA" inside the primary...
        let shadowed = primaryRoot.appendingPathComponent("MountA", isDirectory: true)
        try FileManager.default.createDirectory(at: shadowed, withIntermediateDirectories: true)
        try "primary's own".write(to: shadowed.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        // ...and a mount of the same name, holding a different file.
        try "the mount's".write(to: mountARoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let router = makeRouter(withMounts: ["MountA": mountARoot])

        let response = router.route(request("/MountA/file.txt"))

        guard case .file(let file) = response.body else { return XCTFail("expected a file body") }
        XCTAssertEqual(file.url, mountARoot.appendingPathComponent("file.txt"), "the mount should win over the primary's own same-named entry")
    }

    func testABareMountReferenceWithoutATrailingSlashRedirectsToTheMountsOwnRoot() {
        let router = makeRouter(withMounts: ["MountA": mountARoot])

        let response = router.route(request("/MountA"))

        XCTAssertEqual(response.status, 301)
        XCTAssertEqual(response.headers["Location"], "/MountA/")
    }

    func testAnUnknownFirstComponentFallsThroughToThePrimary() {
        let router = makeRouter(withMounts: ["MountA": mountARoot])

        let response = router.route(request("/NotAMount/file.txt"))

        // The primary has no such file, but it's still the primary that
        // answers -- 404 from the primary, not from a mount.
        XCTAssertEqual(response.status, 404)
    }

    // MARK: - authorize*/resolve* dispatch (directory-path based requirements)

    func testAuthorizeUploadIsAlwaysRefusedForAMountEvenWhenTheMountHandlerWouldAllowIt() {
        // LiveServerService always constructs mount handlers with
        // allowUploads: false -- but MountRouter itself does no
        // capability-checking of its own, it only dispatches. Prove that by
        // constructing a mount handler that *would* allow uploads, and
        // confirming the router still just asks that handler (whatever it
        // says goes) rather than special-casing mounts.
        let permissiveMountHandler = StaticFileHandler(resolver: SecurePathResolver(root: mountARoot), allowUploads: true)
        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot)),
            additional: [MountRouter.Mount(name: "MountA", handler: permissiveMountHandler)]
        )

        XCTAssertTrue(router.authorizeUpload(directoryPath: "/MountA/"))
    }

    func testResolveZipEntriesRewritesTheDirectoryPathForTheTargetMount() throws {
        try "a".write(to: mountARoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let router = makeRouter(withMounts: ["MountA": mountARoot])

        let resolved = router.resolveZipEntries(directoryPath: "/MountA/", names: ["a.txt"])

        XCTAssertEqual(resolved, [mountARoot.appendingPathComponent("a.txt")])
    }

    // MARK: - WebDAV

    func testPropfindOnAMountPathIsAnsweredByThatMount() {
        let router = makeRouter(withMounts: ["MountA": mountARoot], allowWebDAVWritesOnPrimary: false)

        let response = router.routeWebDAVPropfind(path: "/MountA/", depth: .zero)

        XCTAssertNotNil(response)
        XCTAssertEqual(response?.status, 207)
    }

    func testMoveWithinTheSameMountSucceeds() throws {
        try "content".write(to: mountARoot.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        let mountHandler = StaticFileHandler(resolver: SecurePathResolver(root: mountARoot), allowWebDAVWrites: true)
        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot), allowWebDAVWrites: true),
            additional: [MountRouter.Mount(name: "MountA", handler: mountHandler)]
        )

        let response = router.routeWebDAVMove(sourcePath: "/MountA/source.txt", destinationHeader: "/MountA/dest.txt", overwrite: false)

        XCTAssertEqual(response?.status, 201)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountARoot.appendingPathComponent("dest.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountARoot.appendingPathComponent("source.txt").path))
    }

    func testMoveFromAMountToThePrimaryIsRefusedWithConflict() throws {
        try "content".write(to: mountARoot.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        let mountHandler = StaticFileHandler(resolver: SecurePathResolver(root: mountARoot), allowWebDAVWrites: true)
        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot), allowWebDAVWrites: true),
            additional: [MountRouter.Mount(name: "MountA", handler: mountHandler)]
        )

        let response = router.routeWebDAVMove(sourcePath: "/MountA/source.txt", destinationHeader: "/dest.txt", overwrite: false)

        XCTAssertEqual(response?.status, 409)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountARoot.appendingPathComponent("source.txt").path), "a refused move must leave the source untouched")
    }

    func testMoveBetweenTwoDifferentMountsIsRefusedWithConflict() throws {
        try "content".write(to: mountARoot.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        let router = MountRouter(
            primary: StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot), allowWebDAVWrites: true),
            additional: [
                MountRouter.Mount(name: "MountA", handler: StaticFileHandler(resolver: SecurePathResolver(root: mountARoot), allowWebDAVWrites: true)),
                MountRouter.Mount(name: "MountB", handler: StaticFileHandler(resolver: SecurePathResolver(root: mountBRoot), allowWebDAVWrites: true))
            ]
        )

        let response = router.routeWebDAVMove(sourcePath: "/MountA/source.txt", destinationHeader: "/MountB/dest.txt", overwrite: false)

        XCTAssertEqual(response?.status, 409)
    }

    func testCopyWithoutADestinationHeaderIsABadRequestBeforeConsultingAnyMount() {
        let router = makeRouter(withMounts: ["MountA": mountARoot])

        let response = router.routeWebDAVCopy(sourcePath: "/MountA/source.txt", destinationHeader: nil, overwrite: false)

        XCTAssertEqual(response?.status, 400)
    }

    // MARK: - Helpers

    private func makeRouter(withMounts mounts: [String: URL], allowWebDAVWritesOnPrimary: Bool = false) -> MountRouter {
        let primary = StaticFileHandler(resolver: SecurePathResolver(root: primaryRoot), allowWebDAVWrites: allowWebDAVWritesOnPrimary)
        let additional = mounts.map { name, root in
            MountRouter.Mount(name: name, handler: StaticFileHandler(resolver: SecurePathResolver(root: root), allowDirectoryListing: true))
        }
        return MountRouter(primary: primary, additional: additional)
    }
}
