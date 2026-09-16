import Foundation

/// Writes bytes to a file in bounded chunks as they arrive, so an upload of
/// any size is written to disk incrementally rather than buffered in memory
/// first. Mirrors `FileChunkReader`'s bounded-chunk design for the opposite
/// direction.
///
/// Creates (and truncates) the file at `init`, so the caller must already
/// have decided the destination is acceptable to create — this type has no
/// opinion on whether overwriting an existing file is allowed; see
/// `Handlers/StaticFileHandler.swift`'s `authorizeUploadedFile(directoryPath:filename:)`,
/// which refuses to hand back a URL that already exists.
final class FileChunkWriter {
    enum WriteError: Error, Equatable {
        /// This upload's bytes so far exceed `maxBytes` — `HTTPConnection`
        /// is expected to delete the partial file and fail the upload, the
        /// same as any other malformed-body failure.
        case exceededMaxBytes
    }

    private let handle: FileHandle
    private let maxBytes: Int
    private(set) var bytesWritten = 0

    init?(url: URL, maxBytes: Int) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        self.maxBytes = maxBytes
    }

    func write(_ chunk: Data) throws {
        guard bytesWritten + chunk.count <= maxBytes else {
            throw WriteError.exceededMaxBytes
        }
        try handle.write(contentsOf: chunk)
        bytesWritten += chunk.count
    }

    func close() {
        try? handle.close()
    }
}
