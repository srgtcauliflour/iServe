import XCTest
@testable import iServe

/// Drives a real `HTTPServer` (with uploads enabled) over loopback with a
/// hand-built multipart/form-data POST, the same shape a browser's
/// `<input type="file">` form actually sends - proving the whole pipeline
/// end to end: `HTTPConnection`'s body-streaming -> `MultipartFormDataParser`
/// -> `FileChunkWriter` -> `SecurePathResolver`-authorized destination.
/// Parser-only edge cases live in `MultipartFormDataParserTests`; this is
/// only the cases that need an actual client/server round trip.
final class UploadLifecycleTests: XCTestCase {
    private let boundary = "iServeTestBoundary123"

    func testUploadingAFileWritesItToDiskAndRedirectsBackToTheDirectory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true))
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("note.txt", "Hello from a test")])
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200) // URLSession follows the 303 automatically
        XCTAssertEqual(http.url?.path, "/")

        let uploaded = root.appendingPathComponent("note.txt")
        XCTAssertEqual(try String(contentsOf: uploaded, encoding: .utf8), "Hello from a test")

        await server.stop()
    }

    func testUploadingMultipleFilesInOneRequestWritesEachOne() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true))
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("a.txt", "AAA"), ("b.txt", "BBB")])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "AAA")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "BBB")

        await server.stop()
    }

    func testLargerThanOneReadChunkUploadArrivesByteExact() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Comfortably larger than the 8KB default read chunk, so this only
        // succeeds if HTTPConnection's body-streaming loop actually keeps
        // feeding the parser across many reads rather than assuming one.
        var large = Data(capacity: 200_000)
        for i in 0..<200_000 { large.append(UInt8(truncatingIfNeeded: i)) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true))
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("large.bin", large)])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let writtenData = try Data(contentsOf: root.appendingPathComponent("large.bin"))
        XCTAssertEqual(writtenData, large)

        await server.stop()
    }

    func testUploadIsRefusedWhenUploadsAreNotEnabled() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("note.txt", "should not land")])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("note.txt").path))

        await server.stop()
    }

    func testUploadWithATraversalFilenameIsRejectedAndNothingEscapesRoot() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeUploadTraversalOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true))
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("../escape.txt", "malicious")])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))

        await server.stop()
    }

    func testUploadingToAnExistingFileNameIsRefusedWithoutOverwritingIt() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "original".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true))
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("note.txt", "overwritten?")])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8), "original")

        await server.stop()
    }

    func testUploadExceedingTheServersMaxUploadSizeIsRejected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var limits = HTTPServerLimits.default
        limits.maxUploadBytes = 10
        let server = HTTPServer(
            router: StaticFileHandler(resolver: SecurePathResolver(root: root), allowUploads: true),
            limits: limits
        )
        let port = try await server.start()

        let request = multipartRequest(port: port, path: "/", files: [("note.txt", "this is way more than 10 bytes")])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("note.txt").path))

        await server.stop()
    }

    // MARK: - Helpers

    private func multipartRequest(port: UInt16, path: String, files: [(name: String, content: String)]) -> URLRequest {
        multipartRequest(port: port, path: path, files: files.map { ($0.name, Data($0.content.utf8)) })
    }

    private func multipartRequest(port: UInt16, path: String, files: [(name: String, content: Data)]) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for file in files {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(file.name)\"\r\n".utf8
            ))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(file.content)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeUploadLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
