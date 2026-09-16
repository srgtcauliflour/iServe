import XCTest
@testable import iServe

/// Drives a real `HTTPServer` with a real `StaticFileHandler` over loopback
/// for HTTP Range requests (v0.3) - proving the full pipeline end to end:
/// `Transfer/ByteRangeParser.swift` -> `HTTPResponse.partialContent`/
/// `.rangeNotSatisfiable` -> `HTTPConnection`'s offset-aware
/// `Transfer/FileChunkReader.swift` streaming -> a real HTTP client.
/// Parser-only edge cases live in `ByteRangeParserTests`; router-only status
/// mapping lives in `StaticFileHandlerTests`; these are only the cases that
/// need an actual client/server round trip.
final class RangeLifecycleTests: XCTestCase {
    func testRangeRequestReturnsExactlyTheRequestedBytes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var large = Data(capacity: 100_000)
        for i in 0..<100_000 { large.append(UInt8(truncatingIfNeeded: i)) }
        try large.write(to: root.appendingPathComponent("large.bin"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/large.bin"))
        request.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 1000-1999/100000")
        XCTAssertEqual(data.count, 1000)
        XCTAssertEqual(data, large[1000..<2000])

        await server.stop()
    }

    func testTwoRangeRequestsCoveringTheWholeFileReconstructItExactly() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var large = Data(capacity: 50_000)
        for i in 0..<50_000 { large.append(UInt8(truncatingIfNeeded: i * 7)) }
        try large.write(to: root.appendingPathComponent("large.bin"))

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        // Simulates a resumed download: two separate Range requests, each
        // for half the file, that a real client would issue as "give me
        // what I'm still missing" after an interrupted first attempt.
        var firstHalf = URLRequest(url: loopbackURL(port: port, path: "/large.bin"))
        firstHalf.setValue("bytes=0-24999", forHTTPHeaderField: "Range")
        firstHalf.cachePolicy = .reloadIgnoringLocalCacheData
        let (firstData, firstResponse) = try await URLSession.shared.data(for: firstHalf)
        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 206)

        var secondHalf = URLRequest(url: loopbackURL(port: port, path: "/large.bin"))
        secondHalf.cachePolicy = .reloadIgnoringLocalCacheData
        secondHalf.setValue("bytes=25000-", forHTTPHeaderField: "Range")
        let (secondData, secondResponse) = try await URLSession.shared.data(for: secondHalf)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 206)

        XCTAssertEqual(firstData + secondData, large)

        await server.stop()
    }

    func testUnsatisfiableRangeReturns416OverTheWire() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "0123456789".write(to: root.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        var request = URLRequest(url: loopbackURL(port: port, path: "/data.txt"))
        request.setValue("bytes=1000-2000", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 416)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes */10")

        await server.stop()
    }

    func testPlainRequestWithoutARangeStillReturnsTheWholeFileAndAdvertisesSupport() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "0123456789".write(to: root.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let server = HTTPServer(router: StaticFileHandler(resolver: SecurePathResolver(root: root)))
        let port = try await server.start()

        let (data, response) = try await URLSession.shared.data(from: loopbackURL(port: port, path: "/data.txt"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "0123456789")

        await server.stop()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeRangeLifecycleRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func loopbackURL(port: UInt16, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
}
