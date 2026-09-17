# Handlers

`StaticFileHandler` (issue #5) is the v0.1 `HTTPRouter`: it strips any query
string from `request.target`, resolves the remaining path through
`FileSystem/SecurePathResolver.swift`, and turns the result into an
`HTTPResponse`. It never constructs or opens a filesystem path itself —
including for `index.html`/`index.htm` lookups inside a directory, which are
re-resolved through the same resolver (as `<dir path>/index.html`, etc.)
rather than appended and opened directly, so an index file that happens to be
a symlink is still subject to the root-containment check. A resolver error
maps to a status code (`.escapesRoot` -> 403, other resolver errors -> 400,
missing content -> 404) without ever including the resolver's error detail or
a local path in the response body. An index lookup only ever happens when
`allowDirectoryListing == false` (v0.3 post-ship fix) — see below.

`MIMEType` maps a file extension to a `Content-Type`, falling back to
`application/octet-stream` for anything unrecognized rather than guessing.

`DirectoryListingRenderer` (v0.2, Shu parity) renders a directory as a
minimal HTML file listing, given only a directory URL `StaticFileHandler`
already resolved — it opens nothing itself. Hidden entries (names starting
with `.`) are omitted from the listing per `docs/SECURITY.md`'s "no
hidden/special metadata by default" posture, though an exact request for
one still resolves normally. Every rendered name is HTML-escaped, and the
href for each entry is percent-encoded, since a locally created filename is
not sanitized input. `StaticFileHandler` redirects (`301`) a directory
request whose path doesn't already end in `/` to the slash-terminated form
before rendering or serving an index — required so the browser's relative
links (the listing's own entry links, and any served page's own relative
asset URLs) resolve against the directory rather than its parent.

The listing also renders a breadcrumb trail (v0.3 post-ship addition) above
the entries — "Home / folder / subfolder", each segment a link to that
ancestor — so a person browsing File Share/File Drop/Full Access can jump
back to any ancestor directly rather than relying on the browser's own back
button, which only ever undoes one navigation and not at all after a
reload. See `DirectoryListingRenderer.breadcrumbs(for:)`.

`LoginPageRenderer` (v0.3, `docs/adr/0008-password-only-cookie-login.md`)
renders the password-only HTML login page shown instead of the browser's
native Basic Auth dialog — a plain `POST` back to its own reserved path
(`/__iserve/login`), which `ServerCore/HTTPConnection.swift` intercepts
before it ever reaches this handler/`SecurePathResolver`, so it never
shadows anything the served folder actually contains except that one exact
path. See `ServerCore/README.md` for the login flow itself
(`SessionTokenStore`, the gate in `HTTPConnection.respond(to:leftoverBodyBytes:)`).

Replaces `ServerCore/HTTPRouter.swift`'s `NotFoundRouter` bootstrap. File
bodies are handed back as `HTTPResponseBody.file` (a URL + byte length, not
file contents) — `ServerCore/HTTPConnection.swift` is what actually streams
them, via `Transfer/FileChunkReader.swift`.

`StaticFileHandler.allowUploads` (v0.2, default `false`),
`allowDirectoryListing` (v0.3, default `true`), and `allowWebDAVWrites`
(v0.3, default `false`) are set by `ServerCore/LiveServerService.swift`
from `ServerCoordinator.profile`'s
`allowsUploads`/`allowsDirectoryListing`/`allowsWebDAVWrites` — see
`ServerCore/ServerProfile.swift`.
Per `docs/SECURITY.md`, a write capability is never implied just by
selecting a folder to serve, so this handler refuses every upload unless a
caller opted in explicitly for that session. `allowDirectoryListing: false`
(the `websiteReadOnly` profile) makes a directory serve its
`index.html`/`index.htm` if one exists, or a plain `404` otherwise — Website
mode is for serving a site's own pages, not for browsing whatever else is in
the selected folder. Every other profile (`allowDirectoryListing: true`)
always shows the generated listing, even for a directory that contains an
index file (v0.3 post-ship fix — auto-serving an index used to happen in
every profile, which meant File Sharing/File Drop/Full Access could never
actually show their own listing for a folder that had one); a person still
reaches that page by clicking its entry, which never affects a direct GET
of a file whose name/path the client already knows, since that was never
gated by anything but `SecurePathResolver` in the first place. When uploads
are `true`,
`DirectoryListingRenderer` gets an extra plain-HTML upload form (no
JavaScript) in its listing, and the handler implements `HTTPRouter`'s two
upload-authorization requirements:
- `authorizeUpload(directoryPath:)` — resolves `directoryPath` and confirms
  it's an existing directory.
- `authorizeUploadedFile(directoryPath:filename:)` — treats `filename` as
  one atomic path component (rejecting `/`, `\`, `.`, `..`, and empty
  outright, on top of `SecurePathResolver`'s own protections once the name
  is percent-encoded and resolved against `directoryPath`), and refuses to
  hand back a URL that already exists — "no destructive operations by
  default" (`docs/MASTER-SPEC.md`) means an upload never silently
  overwrites something already there.

Neither method touches the filesystem beyond checking existence/type —
`ServerCore/HTTPConnection.swift` is what actually streams an upload's body
to disk, through `Transfer/MultipartFormDataParser.swift` and
`Transfer/FileChunkWriter.swift`, the same "handler decides, connection
does the I/O" split as a download's `HTTPResponseBody.file`.

`fileResponse(for:request:)` (v0.3, HTTP Range/resumable downloads) checks
`request.headers["Range"]` against `Transfer/ByteRangeParser.swift` before
building a file response: a satisfiable single range becomes
`HTTPResponse.partialContent` (`206`, `Content-Range`, and an
`HTTPFileBody` whose `offset`/`length` cover only that span); an
out-of-bounds one becomes `.rangeNotSatisfiable` (`416`); anything this
parser doesn't understand (no header, or multiple ranges — RFC 7233 §3.1
allows ignoring those) falls back to the ordinary full `.file` response,
which itself now always advertises `Accept-Ranges: bytes` so a client knows
a later Range request will work. Applies uniformly to a direct file
request and a directory's resolved `index.html`/`.htm` — both go through
the same `fileResponse(for:request:)`.

`DirectoryListingRenderer` (v0.3, multi-selection ZIP downloads) also wraps
every non-empty listing in a second, plain `method="POST"` form (default
`enctype`, so a browser sends `application/x-www-form-urlencoded`) with one
checkbox per entry and a "Download Selected (.zip)" button — unconditional,
unlike uploads, since packaging already-servable files as a ZIP exposes
nothing a plain GET of each one wouldn't. `StaticFileHandler` implements the
matching pair of `HTTPRouter` requirements:
- `authorizeZipDownload(directoryPath:)` — resolves `directoryPath` and
  confirms it's an existing directory, same shape as `authorizeUpload`.
- `resolveZipEntries(directoryPath:names:)` — treats every selected name as
  one atomic path component (the same rule as an uploaded filename), and
  refuses the *whole* request (returns `nil`) if even one name fails to
  resolve or no longer exists, rather than silently building an archive
  missing just that entry.

`ServerCore/HTTPConnection.swift` does the actual work once a selection is
authorized and its body fully buffered: it calls `Transfer/ArchiveManager.swift`
to build the ZIP in the app's own temporary directory (never inside the
served root), then responds with `HTTPResponse.attachment(...)` — the same
streamed-`.file` path as any other download, with a
`Content-Disposition: attachment` header so a browser saves rather than
navigates to it — and deletes the temporary archive once the connection
closes, on every exit path (a clean finish, a client disconnect, a timeout).
`HTTPServerLimits.maxZipSelectionBytes`/`maxZipEntryCount`/
`maxZipUncompressedBytes` bound, respectively, the selection body itself
(a small list of names, never file content), how many items one request may
select, and the total uncompressed size the resulting archive may reach —
independent of `docs/SECURITY.md`'s upload-specific `allowUploads` gate,
since this is a read/export operation, not a write.

`StaticFileHandler.routeWebDAVPropfind(path:depth:)` (v0.3 WebDAV read
operations, `docs/adr/0004-webdav-read-operations.md`) is the fourth
`HTTPRouter` requirement that owns a complete response rather than just an
authorization decision — same shape as `route(_:)` itself, since a
`PROPFIND` response is just path resolution plus metadata, nothing a
streaming body needs to gate mid-request. It resolves `path` exactly like
`route(_:)` (the same `SecurePathResolver.ResolutionError` -> status
mapping), requires `allowDirectoryListing` for a directory target
regardless of whether an index file exists there — WebDAV enumeration is
the same "browsing" capability as the HTML listing, just via a different
protocol — and, for `depth: .one` on a directory, lists immediate children
only (never recursing), omitting hidden entries the same way
`DirectoryListingRenderer` does. `ServerCore/HTTPConnection.swift` builds
the `Depth` header into a `WebDAVDepth` (`0`/`1` only — anything else,
including a missing header or `infinity`, is `400` before this method is
ever called) and hands the router's response straight back; `nil` becomes
`501`. See `Handlers/WebDAVResponseBuilder.swift` for the `multistatus` XML
this produces, and the ADR for why request-body parsing and
`Depth: infinity` are both out of scope.

`StaticFileHandler`'s five WebDAV write requirements (v0.3,
`docs/adr/0005-webdav-write-operations.md`) — `routeWebDAVMkcol(path:)`,
`routeWebDAVDelete(path:)`, `routeWebDAVMove(sourcePath:destinationHeader:overwrite:)`,
`routeWebDAVCopy(sourcePath:destinationHeader:overwrite:)`, and
`authorizeWebDAVPut(path:)` — all require `allowWebDAVWrites`, refusing
with `404` when it's off (only `ServerProfile.fullAccess` sets it). The
first four own a complete response, same shape as `routeWebDAVPropfind`;
`authorizeWebDAVPut` instead returns a `WebDAVPutAuthorization?` (a
destination URL, a hidden temporary sibling URL, and whether the
destination already exists) since `PUT`'s body must stream to disk the
same way an upload's does — `ServerCore/HTTPConnection.swift` writes to
the temporary URL via `Transfer/FileChunkWriter.swift` and only replaces
the real destination in one atomic step once every byte has arrived,
so an interrupted `PUT` never corrupts a file that was already there
(unlike `authorizeUploadedFile`, `PUT` is allowed to overwrite — a
deliberate, documented divergence, see the ADR). `MKCOL` refuses
(`405`) a path that already exists and never auto-creates intermediate
directories, matching RFC 4918 §9.3.1 exactly. `DELETE`, and `MOVE`/`COPY`
as either endpoint, refuse (`403`) to touch `resolver.root` itself;
`MOVE`/`COPY` also parse the `Destination` header via
`URLComponents.percentEncodedPath` (never `URL.path`, which would silently
decode it) and refuse (`409`) moving/copying a directory into its own
subtree.

`MountRouter` (v0.3, optional multiple mounted folders,
`docs/adr/0007-multiple-mounted-folders.md`) sits in front of the primary
`StaticFileHandler` and dispatches by a request target's *first path
component*: an unrecognized component (including "/" itself, which has
none) always falls through to `primary` unchanged, so `/` never resolves to
a mount regardless of how many exist. A recognized component's remainder is
routed to that mount's own independent `StaticFileHandler` (its own
`SecurePathResolver`, so one mount's containment check can never be
satisfied by another mount's tree) with the name segment stripped — a bare
mount reference with no trailing slash (`/Name`, not `/Name/`) gets the same
`301` redirect `StaticFileHandler.route(_:)` already gives any directory
request missing its trailing slash, so a mount's own relative links resolve
correctly. With zero additional mounts every `HTTPRouter` requirement is a
provable, unconditional pass-through to `primary` — the exact same
`HTTPRequest`/path forwarded, never reconstructed — so a single-folder
session behaves exactly as it always has; this is exercised by dedicated
zero-mount tests rather than merely asserted. `MountRouter` does no
capability-checking of its own: `ServerCore/LiveServerService.swift`
constructs every additional mount's handler with uploads and WebDAV writes
already forced off (regardless of `ServerProfile`), so this router only
ever dispatches, never special-cases a mount. `MOVE`/`COPY` resolve both the
source and the `Destination` header (via the same
`WebDAVDestinationHeaderParser` `StaticFileHandler` uses) to their owning
mount and refuse with `409` the moment they differ — a write can never
smuggle a file across the boundary between two independently-scoped roots,
primary included. A same-named top-level entry inside the primary is
shadowed by a mount of the same name — a documented trade-off, not a
security concern, since both still resolve to content the operator
explicitly chose to share.

Covered by `Tests/iServeTests/MountRouterTests.swift` (router-only unit
tests against real `StaticFileHandler`s over real temp directories: the
zero-mount pass-through, dispatch to a named mount, `/` always meaning the
primary regardless of mount count, the same-named-entry shadowing rule, the
bare-mount-reference redirect, an unrecognized component falling through to
the primary, `authorize`/`resolve` dispatch rewriting the directory path for
the target mount, PROPFIND answered by the right mount, and every
`MOVE`/`COPY` cross-mount 409 case) and
`Tests/iServeTests/MountLifecycleTests.swift` (the same router driven by a
real `HTTPServer` over loopback: the primary and an additional mount both
reachable at their own addresses, the bare-mount redirect over the wire, and
a mount refusing WebDAV writes even when the primary allows them).

Covered by `Tests/iServeTests/StaticFileHandlerTests.swift` (router behavior:
index preference, status mapping, MIME types, the trailing-slash redirect,
`allowDirectoryListing` gating a no-index directory to `404` while still
serving an index file when disabled, the upload-authorization methods, the
ZIP-download-authorization methods, `routeWebDAVPropfind`'s resolution-error
mapping, every WebDAV write route's authorization/status-mapping edge cases
(disabled writes, an existing `MKCOL` target, deleting root, `MOVE`/`COPY`
overwrite and subtree checks, `PUT`'s temporary-sibling/already-exists
authorization), and Range routing — no networking),
`Tests/iServeTests/DirectoryListingRendererTests.swift`
(sorting, escaping, hidden-entry omission, the upload form's presence/absence,
and the breadcrumb trail's shape at root/nested paths and its percent-decoded
label vs. as-is href — no filesystem-authorization concerns, pure rendering),
`Tests/iServeTests/WebDAVResponseBuilderTests.swift` (pure `multistatus` XML
rendering — collection vs. file properties, escaping, one `<D:response>`
per entry — no filesystem/networking), and
`Tests/iServeTests/StaticFileServingLifecycleTests.swift`/
`Tests/iServeTests/UploadLifecycleTests.swift`/
`Tests/iServeTests/RangeLifecycleTests.swift`/
`Tests/iServeTests/ZipDownloadLifecycleTests.swift`/
`Tests/iServeTests/WebDAVLifecycleTests.swift`/
`Tests/iServeTests/WebDAVWriteLifecycleTests.swift` (the same handler driven
by a real `HTTPServer` over loopback, including following a real redirect to
a real listing, a real multipart upload landing on disk byte-exact, two
Range requests together reconstructing a file exactly, a real selection
POST producing a real ZIP whose extracted contents match, including a
selected subdirectory's nested files, a rejected traversal-name selection,
the temporary archive actually being deleted afterward, a real
`OPTIONS`/`PROPFIND` round trip at both depths, and a real
`MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY` round trip including an overwriting
`PUT` leaving no temporary file behind and every write method refused when
disabled).
