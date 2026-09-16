import XCTest
@testable import iServe

final class FileChunkWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeFileChunkWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWritesChunksInOrderAndProducesByteExactFile() throws {
        let url = root.appendingPathComponent("out.bin")
        let writer = try XCTUnwrap(FileChunkWriter(url: url, maxBytes: 1_000))
        try writer.write(Data("Hello, ".utf8))
        try writer.write(Data("world!".utf8))
        writer.close()

        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, Data("Hello, world!".utf8))
    }

    func testTracksBytesWritten() throws {
        let url = root.appendingPathComponent("out.bin")
        let writer = try XCTUnwrap(FileChunkWriter(url: url, maxBytes: 1_000))
        try writer.write(Data(repeating: 0, count: 10))
        try writer.write(Data(repeating: 0, count: 5))
        XCTAssertEqual(writer.bytesWritten, 15)
        writer.close()
    }

    func testThrowsAndStopsWritingOnceMaxBytesWouldBeExceeded() throws {
        let url = root.appendingPathComponent("out.bin")
        let writer = try XCTUnwrap(FileChunkWriter(url: url, maxBytes: 10))
        try writer.write(Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try writer.write(Data(repeating: 0, count: 8))) { error in
            XCTAssertEqual(error as? FileChunkWriter.WriteError, .exceededMaxBytes)
        }
        // The over-limit chunk must not have been partially written.
        XCTAssertEqual(writer.bytesWritten, 8)
        writer.close()
    }

    func testTruncatesAnExistingFileAtTheDestination() throws {
        let url = root.appendingPathComponent("existing.txt")
        try "old content, much longer than the new content".write(to: url, atomically: true, encoding: .utf8)

        let writer = try XCTUnwrap(FileChunkWriter(url: url, maxBytes: 1_000))
        try writer.write(Data("new".utf8))
        writer.close()

        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
    }
}
