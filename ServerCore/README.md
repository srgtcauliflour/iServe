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
  together — `allowsDirectoryListing`/`allowsUploads`/`allowsWebDAVWrites`
  — rather than letting a caller pick an arbitrary combination.
  `ServerCoordinator.profile` defaults to `.fileSharing` (browse + download,
  no uploads); `.fileDrop` additionally allows uploads; `.websiteReadOnly`
  additionally turns off the generated directory listing (a `404` instead,
  so Website mode never exposes browsing whatever else is in the folder);
  `.fullAccess` additionally authorizes WebDAV
  `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY` (v0.3,
  `docs/adr/0005-webdav-write-operations.md`) — now in
  `ServerProfile.selectable` alongside the other three, since it finally
  does something a `.fileDrop` session doesn't. `LiveServerService.start(profile:credentials:)`
  passes all three booleans straight through to `StaticFileHandler`.
- `HTTPServer` (an actor) owns the `NWListener` lifecycle: `start()` is
  deterministic and repeatable, and `stop()` cancels the listener, awaits its
  actual `.cancelled` state (not just the `cancel()` call returning — the
  underlying socket tears down asynchronously) and every live connection's
  cancellation, before returning. Awaiting the real teardown, rather than
  firing `cancel()` and moving on, is what makes an immediate subsequent
  `start()` reliable rather than racing the OS still releasing the previous
  listener's socket — a gap that showed up as an intermittent client-side
  connection failure right after a rapid stop-then-start in
  `ConnectionLimitLifecycleTests.testStoppingAndRestartingResetsThePerAddressRateBudget`.
  A connection beyond
  `HTTPServerLimits.maxConcurrentConnections` is cancelled immediately rather
  than queued. `accept(_:)` (v0.3, `docs/adr/0006-connection-and-rate-limits.md`)
  applies two further, per-remote-address bounds after that global one:
  `maxConnectionsPerAddress` (concurrent) and
  `maxConnectionsPerAddressPerWindow` over `addressRateWindow` (a rolling
  window) — tracked per address (host only, ignoring port) and pruned back
  to nothing once an address has no open connection and nothing within the
  window, so a long session doesn't accumulate state for every client ever
  seen. Since v0.1 has no keep-alive, one connection is one request, so the
  rolling-window cap doubles as this server's per-address request-rate
  limit. Every rejection is silent (`connection.cancel()`, no response,
  same as the existing global-cap behavior) but increments
  `RequestLog.rejectedConnectionCount`. `stop()` clears all of this
  tracking, so a restarted session begins with a fresh budget. The
  bookkeeping itself lives in `AddressConnectionTracker` (a plain,
  non-actor struct with an injectable clock), not inline in `HTTPServer` —
  pulled out specifically so the admission *decision* (concurrent cap,
  rate-window cap, slot reuse after removal, timestamp expiry) can be unit
  tested with deterministic sequential calls, never by racing real
  concurrent connections against each other in wall-clock time. An earlier
  version tried to make a real-network concurrent-load test deterministic
  instead, by blocking each connection's `route(_:)` call for a fixed delay
  — `route(_:)` runs synchronously inside `HTTPConnection`'s (an actor)
  dispatched `Task`, so that blocked a Swift concurrency cooperative-pool
  thread for the delay, which under CI's constrained runner starved
  unrelated concurrent work in the same test process (observed as
  multi-second stalls and connection resets in otherwise-unrelated tests).
  `HTTPServer.accept(_:)` now just asks `addressTracker.tryAdmit(id:address:)`
  before ever calling `HTTPConnection.start()`.
- `HTTPConnection` (an actor) owns exactly one accepted `NWConnection`: it
  reads bounded chunks into the parser, dispatches GET/HEAD/POST/OPTIONS/
  PROPFIND/MKCOL/PUT/DELETE/MOVE/COPY through the router (anything else
  gets `501 Not Implemented`; oversized request lines/headers get
  `414`/`431` instead of a generic `400`), writes one
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
  discovery — the same `200`/`Allow: ...`/`DAV: 1` response (naming every
  method this server code understands, not just what the current profile
  authorizes) for every path, never touching the router. `PROPFIND`'s
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

  **WebDAV write operations (v0.3, `docs/adr/0005-webdav-write-operations.md`):**
  `MKCOL`/`DELETE`/`MOVE`/`COPY` all follow `routeWebDAVPropfind`'s shape —
  no body is read, `HTTPConnection` just resolves the path (and, for
  `MOVE`/`COPY`, the `Destination`/`Overwrite` headers) and hands the
  router's complete response straight back. `PUT` is the one write method
  with a body, authorized up front exactly like an upload
  (`router.authorizeWebDAVPut(path:)`, `Content-Length` present and within
  `HTTPServerLimits.maxWebDAVPutBytes`) before a single byte is read. Unlike
  an upload, `PUT` is expected to overwrite an existing file — so instead
  of writing directly to the destination (an upload's approach, safe there
  only because overwrite was never allowed), `HTTPConnection` streams the
  body to a hidden temporary sibling file via `Transfer/FileChunkWriter.swift`
  and only replaces the real destination — `FileManager.replaceItemAt` if
  it already existed, `moveItem` otherwise, both atomic same-volume
  operations — once every declared byte has arrived; any failure along the
  way deletes only the temporary file, leaving a pre-existing destination
  completely untouched. Every write method requires
  `StaticFileHandler.allowWebDAVWrites` (only `ServerProfile.fullAccess`
  sets it) and responds `404` when it's off, the same "hide the capability"
  convention `allowUploads`/`allowDirectoryListing` already use. `DELETE`,
  and `MOVE`/`COPY` as either endpoint, refuse (`403`) to touch
  `resolver.root` itself; `MOVE`/`COPY` also refuse (`409`) moving/copying
  a directory into its own subtree.

- `LiveServerService` (issue #6, `@MainActor`) is the real `ServerService`:
  `start(profile:credentials:)` acquires scoped access to the
  currently selected folder via `FolderRootManager.beginAccess()` — for
  the entire server session, not just validation — builds an
  `HTTPServer` rooted there with a real `StaticFileHandler`/
  `SecurePathResolver` (passing `profile.allowsUploads`/
  `.allowsDirectoryListing`/`.allowsWebDAVWrites` straight through to the
  handler, and `credentials` straight through to the `HTTPServer`) and a
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

  `start(profile:credentials:)` also acquires scoped access for every
  currently-resolvable additional mount (v0.3, optional multiple mounted
  folders, `docs/adr/0007-multiple-mounted-folders.md`) via
  `FolderRootManager.beginAccess(forMountNamed:)` — a mount whose scope
  can't be acquired right now is silently skipped for this session rather
  than failing the whole server start over one bad mount. Each resolvable
  mount gets its own `StaticFileHandler`/`SecurePathResolver`, constructed
  with uploads and WebDAV writes forced off regardless of `profile` (only
  `allowDirectoryListing` follows it, same as the primary) — additional
  mounts are always read/download-only. The primary and every mount handler
  are wrapped in a `MountRouter` (`Handlers/README.md`) unconditionally,
  even with zero additional mounts, so every session exercises the same
  dispatch path the "provable pass-through" guarantee depends on. `stop()`
  releases every mount's scoped access alongside the primary's, in the same
  order guarantee (after the listener/connections are cancelled, never
  before) — and a start failure releases everything already acquired,
  mounts included, before rethrowing.

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
way the HTML listing already does), `WebDAVResponseBuilderTests.swift`
(pure XML rendering — collection vs. file properties, escaping, one
`<D:response>` per entry), `WebDAVWriteLifecycleTests.swift` (a real
`MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY` round trip over loopback — creating a
directory, creating and overwriting a file, a `PUT` over
`maxWebDAVPutBytes` writing nothing, deleting a file, renaming and copying
via the `Destination` header including an absolute-URL form,
`Overwrite: F` refusing an existing destination, and every write method
refused with `404` when `allowWebDAVWrites` is off),
`ConnectionLimitLifecycleTests.swift` (a real `HTTPServer` over loopback —
a low per-address rate-window budget rejecting requests deterministically
once exhausted; a low per-address concurrent cap rejecting a third raw
connection while two idle ones opened earlier still occupy both slots, then
admitting a new one once those two are cancelled — deterministic without
racing real concurrent requests against each other, since a connection is
counted the moment it's accepted, before any request is even sent;
rejections landing in `RequestLog.snapshot().rejectedConnections`; and
`stop()`/`start()` resetting that budget for a fresh session),
`AddressConnectionTrackerTests.swift`
(the admission decision itself, deterministically: the concurrent cap
admitting up to and rejecting beyond its limit, independent budgets per
address, a removed connection freeing its slot immediately, the
rate-window budget staying spent regardless of concurrent-slot removals,
an expired timestamp aging out of the window via an injected clock, and
`removeAll()` clearing every address), and
`LiveServerServiceTests.swift` (a real folder served through the full
scoped-access + `HTTPServer` session lifecycle, including the session's
`requestLog` going from `nil` to populated to `nil` again across
start/request/stop, a real credentials-protected session rejecting an
unauthenticated request before accepting an authenticated one, and
`.websiteReadOnly` returning `404` for a real no-index directory over
loopback). `StaticFileHandlerTests.swift` also covers `allowDirectoryListing`
directly: a no-index directory `404`s when it's `false`, while an index file
in the same directory is still served.
