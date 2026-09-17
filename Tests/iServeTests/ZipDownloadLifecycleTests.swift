import XCTest
@testable import iServe

/// Drives a real `HTTPServer` over loopback with a form-urlencoded POST, the
/// same shape `Handlers/DirectoryListingRenderer.swift`'s "Download Selected"
/// form actually submits — proving the whole pipeline end to end:
/// `HTTPConnection`'s selection-body buffering -> `StaticFileHandler.resolveZipEntries`
/// -> `Transfer/ArchiveManager.swift` -> the response streamed back as a
/// real `.zip`, with the temporary archive cleaned up afterward.
final class ZipDownloadLifecycleTests: XCTestCase {
    func testDownloadingSelectedFilesReturnsAZipContainingThem() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("A".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("B".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("not selected".utf8).write(to: root.appendingPathComponent("c.txt"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: ["a.txt", "b.txt"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Disposition"), "attachment; filename=\"Download.zip\"")

        let extracted = try extract(data)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("b.txt"), encoding: .utf8), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("c.txt").path))

        await server.stop()
    }

    func testDownloadingASelectedSubdirectoryIncludesItsNestedFiles() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("sunset".utf8).write(to: sub.appendingPathComponent("sunset.txt"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: ["Photos"])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let extracted = try extract(data)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("Photos/sunset.txt"), encoding: .utf8),
            "sunset"
        )

        await server.stop()
    }

    func testDownloadFilenameIsDerivedFromTheDirectory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("q1".utf8).write(to: sub.appendingPathComponent("q1.txt"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/Reports/", names: ["q1.txt"])
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Disposition"), "attachment; filename=\"Reports.zip\"")

        await server.stop()
    }

    func testSelectionWithATraversalNameIsRejectedAndNothingIsBuilt() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("A".utf8).write(to: root.appendingPathComponent("a.txt"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: ["a.txt", "../escape.txt"])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)

        await server.stop()
    }

    func testEmptySelectionIsRejected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("A".utf8).write(to: root.appendingPathComponent("a.txt"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: [])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        await server.stop()
    }

    func testSelectionExceedingTheEntryCountLimitIsRejected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("A".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("B".utf8).write(to: root.appendingPathComponent("b.txt"))

        var limits = HTTPServerLimits.default
        limits.maxZipEntryCount = 1
        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)), limits: limits)
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: ["a.txt", "b.txt"])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)

        await server.stop()
    }

    func testSelectionExceedingTheUncompressedByteLimitIsRejected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "x", count: 100).utf8).write(to: root.appendingPathComponent("big.txt"))

        var limits = HTTPServerLimits.default
        limits.maxZipUncompressedBytes = 10
        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)), limits: limits)
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: ["big.txt"])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)

        await server.stop()
    }

    func testTemporaryArchiveIsDeletedAfterTheResponseCompletes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("A".utf8).write(to: root.appendingPathComponent("a.txt"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = selectionRequest(port: port, path: "/", names: ["a.txt"])
        _ = try await URLSession.shared.data(for: request)

        try await waitUntil {
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
            )) ?? []
            return !leftovers.contains { $0.lastPathComponent.hasPrefix("iserve-download-") }
        }

        await server.stop()
    }

    // MARK: - Helpers

    private func selectionRequest(port: UInt16, path: String, names: [String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = names
            .map { "select=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Writes the response body to a temp file and extracts it with the
    /// already-tested `ArchiveManager.extractArchive(at:to:)`, so this test
    /// suite only has to assert on the extracted contents.
    private func extract(_ zipData: Data) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipDownloadLifecycleTests-\(UUID().uuidString).zip")
        try zipData.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipDownloadLifecycleTests-extracted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ArchiveManager.extractArchive(at: archiveURL, to: destination)
        return destination
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeZipDownloadRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition never became true within \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
