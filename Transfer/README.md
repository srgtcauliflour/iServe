# Transfer

`FileChunkReader` (issue #5) reads a file in bounded chunks — never a whole
file into one `Data` value. `ServerCore/HTTPConnection.swift` drives it one
chunk at a time: it only asks for the next chunk after the previous one's
network send has completed, so a slow client cannot cause an unbounded queue
of pending data (`HTTPServerLimits.writeChunkSize` bounds each chunk, 64 KB by
default). It has no networking dependency itself, so it's unit tested
directly in `Tests/iServeTests/FileChunkReaderTests.swift` — including that
every chunk except possibly the last is exactly the requested size, and that
the reassembled chunks reproduce the source file exactly.

HTTP Range/resume and streaming ZIP generation are v0.3 (see `docs/ROADMAP.md`)
and build on this reader rather than replacing it.

`FileChunkWriter` (v0.2) is the opposite direction, for uploads: creates
(truncating) the destination file and writes bytes to it in bounded chunks
as they arrive, enforcing a `maxBytes` ceiling itself so one upload can't
grow its destination without limit even if a lying `Content-Length` let it
start. It has no opinion on whether overwriting an existing file is
allowed — that's `Handlers/StaticFileHandler.swift`'s
`authorizeUploadedFile(directoryPath:filename:)`, which refuses to hand
back a URL this type would ever see already existing. Tested directly in
`Tests/iServeTests/FileChunkWriterTests.swift`.

`MultipartFormDataParser` (v0.2) is a bounded, incremental
`multipart/form-data` parser (RFC 7578) — mirrors
`ServerCore/HTTPRequestParser.swift`'s feed-bytes-as-they-arrive design, for
the same reason: an upload's body can be any size, so nothing here ever
buffers a whole part. Each `feed(_:)` call returns `.partBodyChunk` events
for whatever's immediately available, holding back only the handful of
bytes that might be the start of a boundary line split across two network
reads (RFC 2046 §5.1's `CRLF--boundary` delimiter). `ServerCore/HTTPConnection.swift`
drives it directly, writing each event's chunk through `FileChunkWriter` as
it arrives — the parser itself never touches a filesystem path. Covered
extensively in `Tests/iServeTests/MultipartFormDataParserTests.swift`,
including a one-byte-at-a-time feed test (mirroring
`HTTPRequestParserTests.testParsesRequestFedOneByteAtATime`) and a case
with binary content containing a byte sequence that coincidentally matches
part of the boundary, to prove that doesn't cause an incorrect early part
end.
