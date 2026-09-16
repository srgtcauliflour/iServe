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

Replaces `ServerCore/HTTPRouter.swift`'s `NotFoundRouter` bootstrap. File
bodies are handed back as `HTTPResponseBody.file` (a URL + byte length, not
file contents) — `ServerCore/HTTPConnection.swift` is what actually streams
them, via `Transfer/FileChunkReader.swift`.

Covered by `Tests/iServeTests/StaticFileHandlerTests.swift` (router behavior:
index preference, status mapping, MIME types — no networking) and
`Tests/iServeTests/StaticFileServingLifecycleTests.swift` (the same handler
driven by a real `HTTPServer` over loopback).
