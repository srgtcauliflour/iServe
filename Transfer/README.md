# Transfer

`FileChunkReader` (issue #5) reads a bounded span of a file in bounded
chunks — never a whole file (or range of one) into one `Data` value.
`ServerCore/HTTPConnection.swift` drives it one chunk at a time: it only
asks for the next chunk after the previous one's network send has
completed, so a slow client cannot cause an unbounded queue of pending data
(`HTTPServerLimits.writeChunkSize` bounds each chunk, 64 KB by default). It
has no networking dependency itself, so it's unit tested directly in
`Tests/iServeTests/FileChunkReaderTests.swift` — including that every chunk
except possibly the last is exactly the requested size, and that the
reassembled chunks reproduce the source file (or the requested span of it)
exactly.

`init(url:offset:length:chunkSize:)` (v0.3, HTTP Range support) reads
exactly `length` bytes starting at `offset` — `offset` defaults to `0` for
the whole-file case a plain `200` response uses; a `206 Partial Content`
response sets both to the requested range instead (see
`Transfer/ByteRangeParser.swift` and `ServerCore/HTTPResponse.swift`'s
`.partialContent`), so this reader never touches the rest of the file even
though the file handle it opened could seek anywhere in it.

`ArchiveManager` (v0.3, file manager) creates ZIP archives and extracts ZIP
and 7z archives for the native in-app file manager screen — Apple has no
first-party archive API for either format, and `AGENTS.md`'s "no arbitrary
shell execution" plus the iOS sandbox rule out shelling out to
`zip`/`unzip`/`7z`/`ditto`, so this wraps
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT-licensed,
pure Swift) and [SWCompression](https://github.com/tsolomko/SWCompression)
(Apache-2.0, pure Swift) — this project's first third-party dependencies,
both added via Swift Package Manager. RAR support was deliberately left
out: every available RAR library wraps the non-commercial-licensed `unrar`
code, which these two avoid entirely.

`createArchive(containing:at:maxUncompressedBytes:)` recursively zips
files/directories, preserving structure; `maxUncompressedBytes` (default
unbounded, for the in-app file manager's own deliberate selections) bounds
the *sum* of every file's uncompressed size, checked while walking the
selection so an oversized one aborts (`ArchiveError.selectionTooLarge`)
without finishing. `ServerCore/HTTPConnection.swift`'s HTTP-triggered ZIP
downloads (v0.3) pass a real limit here, since that selection is a remote
client's, not the app's own user. `extractArchive(at:to:)` (ZIP) and
`extractSevenZipArchive(at:to:)` (7z, extraction-only — SWCompression
cannot create `.7z`, and no maintained permissively-licensed Swift library
does either) both defend against "Zip Slip" independently of whatever
protection the underlying library applies, since iServe already accepts
remote uploads and a malicious client could upload a crafted archive for
later local extraction: every entry's destination is walked and
containment-checked one component at a time, the same way
`FileSystem/SecurePathResolver.swift` checks a remote request path, and any
symlink (or, for 7z, any other non-regular-file entry type) is refused
outright rather than materialized. Unlike ZIPFoundation's streaming reader,
SWCompression's `SevenZipContainer` requires the whole compressed archive
and every entry's decompressed bytes in memory at once — there is no
bounded/streaming 7z reader available, a deliberate (if usually small in
practice) departure from this project's bounded-streaming rule, accepted
because no alternative library exists. Tested directly in
`Tests/iServeTests/ArchiveManagerTests.swift` — byte-exact ZIP round trips,
nested/empty directories, multi-item selections, rejection of both a
traversal entry path and a symlink entry without writing anything, and a
7z round trip against a small embedded fixture (SWCompression can't create
one, so `7z`/`p7zip` built it once at authoring time).

`Transfer/ByteRangeParser.swift` (v0.3) parses an HTTP `Range` request
header (RFC 7233 §2.1) against a known file size into a validated,
inclusive byte range — or a signal for the caller to fall back to the full
entity (no header, or a header this parser doesn't implement) or respond
`416` (a single range whose start is at or beyond the file's size). Pure,
no filesystem/networking dependency — unit tested directly in
`Tests/iServeTests/ByteRangeParserTests.swift`. Deliberately doesn't support
multiple ranges (`bytes=0-499,500-999`, which would need a
`multipart/byteranges` response): RFC 7233 §3.1 explicitly permits a server
to ignore a Range header it doesn't implement and serve the full entity
instead, which is exactly what real clients (browsers, download managers,
`curl -C`) fall back to correctly, so this stays a real gap rather than an
error — see `docs/ROADMAP.md` if multi-range ever turns out to matter.

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
