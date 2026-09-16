import Foundation

/// Reads a file in bounded chunks so no arbitrary-size file is ever loaded into a
/// single in-memory `Data` value. `HTTPConnection` drives this one chunk at a time,
/// waiting for each chunk's network send to complete before requesting the next,
/// which is what keeps a slow client from causing an unbounded queue of pending
/// data. Independently testable without any networking involved.
final class FileChunkReader {
    private let handle: FileHandle
    let chunkSize: Int

    init?(url: URL, chunkSize: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        self.chunkSize = chunkSize
    }

    /// Returns the next chunk (at most `chunkSize` bytes), or `nil` once the file
    /// is exhausted. Throws only on a genuine read failure.
    func nextChunk() throws -> Data? {
        let chunk = try handle.read(upToCount: chunkSize)
        guard let chunk, !chunk.isEmpty else { return nil }
        return chunk
    }

    func close() {
        try? handle.close()
    }
}
