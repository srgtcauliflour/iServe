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
  upload-incapable for free. `routeWebDAVPropfind(path:depth:)` (v0.3,
  see below) follows `route(_:)`'s own shape instead — the router builds
  and owns the *complete* response, `nil` meaning "unsupported" — since a
  WebDAV `PROPFIND` response is decided entirely by path resolution the
  same way a GET's is, with no streaming-body concern an authorization bit
  alone wouldn't cover.
- `ServerProfile` (v0.3, `ServerCore/ServerProfile.swift`) bundles the
  capabilities `docs/MASTER-SPEC.md` section 4's four server profiles grant
  together — `allowsDirectoryListing`/`allowsUploads` — rather than letting
  a caller pick an arbitrary combination. `ServerCoordinator.profile`
  defaults to `.fileSharing` (browse + download, no uploads); `.fileDrop`
  additionally allows uploads; `.websiteReadOnly` additionally turns off
  the generated directory listing (a `404` instead, so Website mode never
  exposes browsing whatever else is in the folder); `.fullAccess` exists
  for a later authorized-write capability (WebDAV) and is deliberately kept
  out of `ServerProfile.selectable` — the picker `App/ServerDashboard.swift`
  offers — until that lands, since it's otherwise indistinguishable from
  `.fileDrop`. `LiveServerService.start(profile:credentials:)` passes the
  two booleans straight through to `StaticFileHandler`.
- `HTTPServer` (an actor) owns the `NWListener` lifecycle: `start()` is
  deterministic and repeatable, and `stop()` cancels the listener and awaits
  every live connection's cancellation before returning. A connection beyond
  `HTTPServerLimits.maxConcurrentConnections` is cancelled immediately rather
  than queued.
- `HTTPConnection` (an actor) owns exactly one accepted `NWConnection`: it
  reads bounded chunks into the parser, dispatches GET/HEAD/POST/OPTIONS/
  PROPFIND through the router (anything else gets `501 Not Implemented`;
  oversized request lines/headers get `414`/`431` instead of a generic
  `400`), writes one
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

  **Authentication (v0.3, `ServerCore/ServerCredentials.swift`):** if the
  session was started with credentials, every request — GET, HEAD, or
  POST alike — is checked against them before anything else: before
  `router.route(_:)`, before `beginUpload`, before `beginZipDownload`, so
  an unauthenticated request never reaches a router or has a single body
  byte read. `ServerCredentials` is password-only (a client's Basic
  username is decoded and ignored), and the comparison is constant-time
  (`HTTPConnection.constantTimeEquals`) rather than a plain `==`, which
  would let a remote attacker recover the password one byte at a time
  from response timing. Missing/wrong credentials get `401` with
  `WWW-Authenticate: Basic realm="iServe"`, so a browser's own native
  login prompt handles it — no custom page, no JavaScript. `nil`
  credentials (the default) mean no check at all — every test predating
  this still exercises that path. See
  `docs/adr/0002-http-basic-authentication.md` for why Basic Auth
  specifically, and the plain-HTTP trade-off it accepts.

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

  **WebDAV read operations (v0.3, `Handlers/WebDAVResponseBuilder.swift`,
  `docs/adr/0004-webdav-read-operations.md`):** `OPTIONS` is pure capability
  discovery — the same `200`/`Allow: GET, HEAD, POST, OPTIONS, PROPFIND`/
  `DAV: 1` response for every path, never touching the router. `PROPFIND`'s
  own request body is never read (this server doesn't parse WebDAV request
  XML at all — see the ADR), so unlike an upload or ZIP selection it
  responds synchronously from headers alone: the `Depth` header must be
  exactly `0` or `1` (anything else, including a missing header or `Depth:
  infinity`, is `400` before the request ever reaches `router
  .routeWebDAVPropfind(path:depth:)`), and the router's response — `207
  Multi-Status` with a fixed property set (`resourcetype`,
  `getcontentlength`/`getcontenttype` for files, `getlastmodified`,
  `displayname`) per entry — is sent back exactly as returned, `nil`
  becoming `501 Not Implemented`. `StaticFileHandler`'s implementation
  requires `allowDirectoryListing` for a directory target (independent of
  whether an index file exists there, unlike the HTML listing path) and
  omits hidden entries from a `Depth: 1` directory's children, same as
  `DirectoryListingRenderer`.

- `LiveServerService` (issue #6, `@MainActor`) is the real `ServerService`:
  `start(profile:credentials:)` acquires scoped access to the
  currently selected folder via `FolderRootManager.beginAccess()` — for
  the entire server session, not just validation — builds an
  `HTTPServer` rooted there with a real `StaticFileHandler`/
  `SecurePathResolver` (passing `profile.allowsUploads`/
  `.allowsDirectoryListing` straight through to the handler, and
  `credentials` straight through to the `HTTPServer`) and a
  fresh `RequestLog`, and starts it. `profile`/`credentials` reflect
  `ServerCoordinator.profile`/`.requiresPassword`+`.password` at
  the moment `start()` was called — `profile` defaults to `.fileSharing`
  (browse + download, no uploads) and `credentials` is `nil` unless
  password protection is on, and per `docs/SECURITY.md` neither write
  access nor a write-capable profile is ever implied just by having a
  folder selected — so a service must never default `profile` to
  `.fileDrop`/`.fullAccess` on its own; see `App/ServerCoordinator.swift`
  and `ServerCore/ServerProfile.swift`.
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
`AuthenticationLifecycleTests.swift` (a real `HTTPServer` with credentials
set — no credentials rejected with `WWW-Authenticate`, the wrong password
rejected, the right one accepted, the username ignored, a malformed
`Authorization` header rejected rather than crashing, `HEAD` and an
upload `POST` gated the same way as `GET` — including that the upload
never touches the filesystem when rejected — and that omitting
credentials entirely still serves every request unchecked),
`WebDAVLifecycleTests.swift` (a real `OPTIONS`/`PROPFIND` round trip over
loopback — capability discovery, `Depth: 0` on a file and on a directory,
`Depth: 1` listing immediate children only and omitting hidden entries, a
missing/`infinity` `Depth` header rejected with `400`, a missing path
`404`, and `allowDirectoryListing: false` refusing a directory the same
way the HTML listing already does) and `WebDAVResponseBuilderTests.swift`
(pure XML rendering — collection vs. file properties, escaping, one
`<D:response>` per entry), and
`LiveServerServiceTests.swift` (a real folder served through the full
scoped-access + `HTTPServer` session lifecycle, including the session's
`requestLog` going from `nil` to populated to `nil` again across
start/request/stop, a real credentials-protected session rejecting an
unauthenticated request before accepting an authenticated one, and
`.websiteReadOnly` returning `404` for a real no-index directory over
loopback). `StaticFileHandlerTests.swift` also covers `allowDirectoryListing`
directly: a no-index directory `404`s when it's `false`, while an index file
in the same directory is still served.
