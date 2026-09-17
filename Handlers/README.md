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
a local path in the response body.

`MIMEType` maps a file extension to a `Content-Type`, falling back to
`application/octet-stream` for anything unrecognized rather than guessing.

`DirectoryListingRenderer` (v0.2, Shu parity) renders a directory that has no
`index.html`/`index.htm` as a minimal HTML file listing instead of `404`,
given only a directory URL `StaticFileHandler` already resolved — it opens
nothing itself. Hidden entries (names starting with `.`) are omitted from the
listing per `docs/SECURITY.md`'s "no hidden/special metadata by default"
posture, though an exact request for one still resolves normally. Every
rendered name is HTML-escaped, and the href for each entry is
percent-encoded, since a locally created filename is not sanitized input.
`StaticFileHandler` redirects (`301`) a directory request whose path doesn't
already end in `/` to the slash-terminated form before rendering or serving
an index — required so the browser's relative links (the listing's own entry
links, and any served page's own relative asset URLs) resolve against the
directory rather than its parent.

Replaces `ServerCore/HTTPRouter.swift`'s `NotFoundRouter` bootstrap. File
bodies are handed back as `HTTPResponseBody.file` (a URL + byte length, not
file contents) — `ServerCore/HTTPConnection.swift` is what actually streams
them, via `Transfer/FileChunkReader.swift`.

`StaticFileHandler.allowUploads` (v0.2, default `false`) is set by
`ServerCore/LiveServerService.swift` from `ServerCoordinator.uploadsEnabled`
— per `docs/SECURITY.md`, a write capability is never implied just by
selecting a folder to serve, so this handler refuses every upload unless a
caller opted in explicitly for that session. When `true`,
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

Covered by `Tests/iServeTests/StaticFileHandlerTests.swift` (router behavior:
index preference, status mapping, MIME types, the trailing-slash redirect,
the upload-authorization methods, the ZIP-download-authorization methods,
and Range routing — no networking),
`Tests/iServeTests/DirectoryListingRendererTests.swift`
(sorting, escaping, hidden-entry omission, the upload form's presence/absence
— no filesystem-authorization concerns, pure rendering), and
`Tests/iServeTests/StaticFileServingLifecycleTests.swift`/
`Tests/iServeTests/UploadLifecycleTests.swift`/
`Tests/iServeTests/RangeLifecycleTests.swift`/
`Tests/iServeTests/ZipDownloadLifecycleTests.swift` (the same handler driven
by a real `HTTPServer` over loopback, including following a real redirect to
a real listing, a real multipart upload landing on disk byte-exact, two
Range requests together reconstructing a file exactly, and a real selection
POST producing a real ZIP whose extracted contents match, including a
selected subdirectory's nested files, a rejected traversal-name selection,
and the temporary archive actually being deleted afterward).
