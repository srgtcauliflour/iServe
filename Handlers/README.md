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

Covered by `Tests/iServeTests/StaticFileHandlerTests.swift` (router behavior:
index preference, status mapping, MIME types, the trailing-slash redirect,
and the upload-authorization methods — no networking),
`Tests/iServeTests/DirectoryListingRendererTests.swift`
(sorting, escaping, hidden-entry omission, the upload form's presence/absence
— no filesystem-authorization concerns, pure rendering), and
`Tests/iServeTests/StaticFileServingLifecycleTests.swift`/
`Tests/iServeTests/UploadLifecycleTests.swift` (the same handler driven by a
real `HTTPServer` over loopback, including following a real redirect to a
real listing, and a real multipart upload landing on disk byte-exact).
