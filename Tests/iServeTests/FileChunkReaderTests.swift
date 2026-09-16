import XCTest
@testable import iServe

final class FileChunkReaderTests: XCTestCase {
    private var fileURL: URL?

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func makeFile(byteCount: Int) throws -> (url: URL, contents: Data) {
        var contents = Data(capacity: byteCount)
        for i in 0..<byteCount { contents.append(UInt8(i % 256)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeChunkReaderTests-\(UUID().uuidString).bin")
        try contents.write(to: url)
        fileURL = url
        return (url, contents)
    }

    func testReadsFileInBoundedChunksAndReconstructsExactContent() throws {
        let (url, original) = try makeFile(byteCount: 1000)
        let reader = try XCTUnwrap(FileChunkReader(url: url, chunkSize: 64))
        var collected = Data()
        var chunkCount = 0
        while let chunk = try reader.nextChunk() {
            XCTAssertLessThanOrEqual(chunk.count, 64)
            collected.append(chunk)
            chunkCount += 1
        }
        reader.close()
        XCTAssertEqual(collected, original)
        XCTAssertEqual(chunkCount, 16) // ceil(1000 / 64)
    }

    func testEveryChunkExceptPossiblyTheLastIsExactlyChunkSized() throws {
        let (url, _) = try makeFile(byteCount: 1000)
        let reader = try XCTUnwrap(FileChunkReader(url: url, chunkSize: 64))
        var chunks: [Data] = []
        while let chunk = try reader.nextChunk() { chunks.append(chunk) }
        reader.close()
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.count, 64)
        }
        XCTAssertEqual(chunks.last?.count, 1000 % 64)
    }

    func testEmptyFileYieldsNoChunks() throws {
        let (url, _) = try makeFile(byteCount: 0)
        let reader = try XCTUnwrap(FileChunkReader(url: url, chunkSize: 64))
        XCTAssertNil(try reader.nextChunk())
        reader.close()
    }

    func testInitReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("iServeChunkReaderTests-missing-\(UUID().uuidString)")
        XCTAssertNil(FileChunkReader(url: missing, chunkSize: 64))
    }
}
