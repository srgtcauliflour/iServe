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
