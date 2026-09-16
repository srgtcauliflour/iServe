import Foundation

/// Reads a bounded span of a file in bounded chunks so no arbitrary-size file
/// (or range of one) is ever loaded into a single in-memory `Data` value.
/// `HTTPConnection` drives this one chunk at a time, waiting for each chunk's
/// network send to complete before requesting the next, which is what keeps
/// a slow client from causing an unbounded queue of pending data.
/// Independently testable without any networking involved.
final class FileChunkReader {
    private let handle: FileHandle
    let chunkSize: Int
    private var remaining: Int

    /// Reads exactly `length` bytes starting at `offset` (default 0, the
    /// whole-file case) — never more, even if the file continues past that
    /// point. `offset`/`length` must already match what the response's own
    /// `Content-Length` (and, for a `206`, `Content-Range`) headers
    /// promised — see `ServerCore/HTTPResponse.swift`'s `.partialContent`,
    /// the v0.3 HTTP Range source of a non-zero `offset`. `nil` if the file
    /// can't be opened for reading, or `offset` can't be seeked to.
    init?(url: URL, offset: Int = 0, length: Int, chunkSize: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else {
                try? handle.close()
                return nil
            }
        }
        self.handle = handle
        self.chunkSize = chunkSize
        self.remaining = length
    }

    /// Returns the next chunk (at most `chunkSize` bytes, and never more
    /// than what's left of this read's `length`), or `nil` once exhausted.
    /// Throws only on a genuine read failure.
    func nextChunk() throws -> Data? {
        guard remaining > 0 else { return nil }
        let chunk = try handle.read(upToCount: min(chunkSize, remaining))
        guard let chunk, !chunk.isEmpty else { return nil }
        remaining -= chunk.count
        return chunk
    }

    func close() {
        try? handle.close()
    }
}
