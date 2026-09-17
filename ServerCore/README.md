# ServerCore

The v0.1 HTTP core (issue #4): a bounded, transport-independent parser plus a
Network.framework transport built on top of it, plus (issue #6)
`LiveServerService`, the real `ServerService` `App/ServerCoordinator.swift`
now uses in place of `UnconfiguredServerService`.

- `HTTPRequestParser` parses only the request line and header section of an
  HTTP/1.1 request (GET/HEAD carry no body). It is a plain value type with no
  networking dependency, fed via `feed(_:) throws -> HTTPRequest?`, so it is
  fully unit tested (`Tests/iServeTests/HTTPRequestParserTests.swift`) without a
  live listener. Every limit in `HTTPRequestParser.Limits` bounds the parser's
  own buffering — a client that withholds a line terminator, sends an oversized
  line, or sends too many headers is rejected rather than allowed to grow
  memory without bound.
- `HTTPRequest`/`HTTPResponse`/`HTTPHeaders` are the transport-neutral request
  and response model. `HTTPResponse.body` (an `HTTPResponseBody`) is `.empty`,
  a small in-memory `.data` (every status/error page this core generates
  itself), or `.file(HTTPFileBody)` — a URL + a byte span (`offset`/`length`)
  from an already successful `SecurePathResolver` resolution, never file
  contents. Only `HTTPConnection` opens and reads a `.file` body, through
  `Transfer/FileChunkReader.swift`, in bounded chunks — `AGENTS.md` requires
  bounded streaming, never a whole-file `Data` load. `.file(url:length:contentType:...)`
  is the whole-file case (`offset` 0), and always sets `Accept-Ranges: bytes`;
  `.partialContent(url:fileSize:range:contentType:)` (v0.3, HTTP Range) is a
  `206` for one already-validated `Transfer/ByteRangeParser.swift` range,
  setting `offset`/`length` to just that span so `HTTPConnection` streams
  only it; `.rangeNotSatisfiable(fileSize:)` is the matching `416`.
- `HTTPRouter` dispatches a method-supported request to a response.
  `NotFoundRouter` is the original v0.1 bootstrap implementation;
  `Handlers/StaticFileHandler.swift` (issue #5) is the real one, resolving
  `request.target` (query string stripped) through
  `FileSystem/SecurePathResolver.swift`. Its two upload-authorization
  requirements (v0.2, `authorizeUpload(directoryPath:)`/
  `authorizeUploadedFile(directoryPath:filename:)`) exist because a POST
  body can be arbitrarily large and must stream straight to disk — unlike
  `route(_:)`, `HTTPConnection` can't get one synchronous `HTTPResponse`
  back for an upload. Default implementations refuse every upload, so
  `NotFoundRouter` and any future router that doesn't override them stay
  upload-incapable for free.
- `HTTPServer` (an actor) owns the `NWListener` lifecycle: `start()` is
  deterministic and repeatable, and `stop()` cancels the listener and awaits
  every live connection's cancellation before returning. A connection beyond
  `HTTPServerLimits.maxConcurrentConnections` is cancelled immediately rather
  than queued.
- `HTTPConnection` (an actor) owns exactly one accepted `NWConnection`: it
  reads bounded chunks into the parser, dispatches GET/HEAD/POST through the
  router (anything else gets `501 Not Implemented`; oversized request
  lines/headers get `414`/`431` instead of a generic `400`), writes one
  response — streaming a `.file` body one `FileChunkReader` chunk at a time,
  only requesting the next chunk once the previous one's network send has
  completed — and closes. v0.1 does not support keep-alive/pipelining —
  every connection serves at most one response — which keeps this first
  transport implementation's lifecycle simple and bounded; a later issue can
  add persistent connections behind an ADR if the product needs them. An
  idle-read timeout guards the request-reading phase (and is cancelled once a
  response begins, so a slow-but-progressing file transfer isn't cut short by
  a timer meant for a stalled request); a hard maximum connection lifetime
  bounds a connection that never makes any progress at all. If constructed
  with a `Logging/RequestLog.swift` instance, it records one sanitized entry
  (method, target, status, declared byte count) per dispatched response —
  never for a request that failed to parse at all, since there is no clean
  target to show for one.

  **POST uploads (v0.2):** once headers are parsed for a POST,
  `HTTPConnection` authorizes the *whole* request — target is a directory,
  `Content-Type` names a `multipart/form-data` boundary, `Content-Length` is
  present and within `HTTPServerLimits.maxUploadBytes`, and
  `router.authorizeUpload(directoryPath:)` accepts it — before reading a
  single body byte; anything short of that responds immediately without
  touching the body at all (v0.1's no-keep-alive design means there's never
  a need to drain and discard bytes a rejected client is still sending). A
  request that passes all of that feeds every subsequent received chunk
  into a `Transfer/MultipartFormDataParser.swift`, writing each file part
  through a `Transfer/FileChunkWriter.swift` opened via
  `router.authorizeUploadedFile(directoryPath:filename:)` — bounded the same
  way a download is, one chunk at a time, never a whole upload buffered in
  memory. A malformed/truncated body, a write past `maxUploadBytes`, or the
  connection closing mid-upload all delete whatever partial file was in
  progress (`docs/SECURITY.md`'s "partial-file cleanup") and, for the first
  two, respond `400`; already-completed parts from earlier in the same
  request are left in place rather than retroactively undone. On success,
  responds `303 See Other` back to the directory so a browser's page
  refresh after the redirect doesn't resubmit the upload.

  **POST ZIP downloads (v0.3):** a POST whose `Content-Type` is
  `application/x-www-form-urlencoded` instead — a directory listing's
  "Download Selected" form — takes a separate path: `HTTPConnection`
  authorizes it the same way (directory target, `Content-Length` present
  and within `HTTPServerLimits.maxZipSelectionBytes`, and
  `router.authorizeZipDownload(directoryPath:)` accepts it), buffers the
  small selection body in memory (never streamed to a parser — it's just a
  list of names), parses out every `select=<name>` pair, and hands the
  names to `router.resolveZipEntries(directoryPath:names:)`. Given a
  resolved list, it builds a ZIP via `Transfer/ArchiveManager.swift` in the
  app's own temporary directory (bounded by `maxZipEntryCount`/
  `maxZipUncompressedBytes`), then responds with `HTTPResponse.attachment(...)`
  — the same streamed-`.file` path as any other download — and deletes the
  temporary archive in `close()`, the one place every termination path (a
  clean finish, a client disconnect mid-stream, a timeout) already funnels
  through, so cleanup happens exactly once regardless of how the
  connection ends.

- `LiveServerService` (issue #6, `@MainActor`) is the real `ServerService`:
  `start(allowUploads:)` acquires scoped access to the currently selected
  folder via `FolderRootManager.beginAccess()` — for the entire
  server session, not just validation — builds an `HTTPServer` rooted there
  with a real `StaticFileHandler`/`SecurePathResolver` (passing
  `allowUploads` straight through to the handler) and a fresh `RequestLog`,
  and starts it. `allowUploads` is `ServerCoordinator.uploadsEnabled` at the
  moment `start()` was called — off by default, and per `docs/SECURITY.md`
  never implied just by having a folder selected — so a service must never
  default it to `true` on its own; see `App/ServerCoordinator.swift`.
  `stop()` cancels the listener/connections (`await`ed inside a
  detached `Task`, since the `ServerService` protocol's `stop()` itself must
  stay synchronous) before releasing that same scoped access — never before,
  per `FileSystem/README.md`'s ordering requirement — and drops the session's
  `requestLog` reference so a subsequent restart starts from an empty log
  rather than carrying over stale entries. `ServerCoordinator` owns exactly
  one of these; nothing else should construct an `HTTPServer` for the app's
  own serving session.

  **`App/iServeApp.swift` is the only place that should construct a real
  `LiveServerService`.** It was missed entirely for one release cycle — the
  shipped app kept using the `UnconfiguredServerService` bootstrap by
  default, so `Start Server` always failed even though every piece below it
  worked and was fully tested. No test caught it because the test suite
  injects its dependencies directly and nothing exercises `iServeApp`'s own
  `init()`; only a real device tap-through surfaced it. If you add a new
  `ServerService`-consuming entry point, make sure it actually constructs
  `LiveServerService` rather than relying on `ServerCoordinator`'s default
  parameter.

Covered by `Tests/iServeTests/HTTPRequestParserTests.swift` (bounded parsing,
independent of any listener, including that a POST's leading body bytes
already sitting in the same network read as the header-terminating blank
line survive via `drainRemainder()`), `HTTPRouterTests.swift`
(headers/response encoding), `ServerLifecycleTests.swift` (real loopback
start/stop determinism, GET/HEAD/unsupported-method behavior, concurrent
connections), `StaticFileServingLifecycleTests.swift` (a real
`StaticFileHandler` served end to end, including a large payload streamed
byte-exact and a real request recorded into an injected `RequestLog`),
`UploadLifecycleTests.swift` (a real multipart POST over loopback —
success, multiple files in one request, a payload larger than one read
chunk arriving byte-exact, uploads disabled, a traversal filename, an
overwrite attempt, and exceeding `maxUploadBytes` — each checking both the
HTTP response and the actual filesystem effect or lack of one),
`RangeLifecycleTests.swift` (a real Range GET over loopback — an exact byte
span, `416` for an out-of-bounds range, and two Range requests together
reconstructing a whole file exactly, the resumed-download case Range
support exists for), `ZipDownloadLifecycleTests.swift` (a real selection
POST over loopback — a real ZIP whose extracted contents match, a selected
subdirectory's nested files, the download filename derived from the
directory, a rejected traversal-name selection, an empty selection, both
size limits, and the temporary archive actually being deleted afterward),
and `LiveServerServiceTests.swift` (a real folder served through the full
scoped-access + `HTTPServer` session lifecycle, including the session's
`requestLog` going from `nil` to populated to `nil` again across
start/request/stop).
