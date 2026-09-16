# Logging

`RequestLog` (issue #6, an actor) is bounded, sanitized request telemetry for
one server session: total request count, total response bytes, and a
capacity-bounded (default 50) most-recent-first list of `RequestLogEntry`
(method, request target, status, byte count, timestamp). It only ever records
what a remote client's own request already exposed — never a local
filesystem path or other implementation detail.

`LiveServerService` owns one `RequestLog` per session, created fresh in
`start()` and discarded in `stop()` (so a restart never shows stale entries
from a previous run), and passes it down through `HTTPServer` to every
`HTTPConnection`, which records one entry per dispatched response right
before sending it. `bytes` is the response's declared/intended length (its
`Content-Length`), not bytes confirmed delivered over the wire — a
connection that drops mid-stream is still counted at its full intended size.
This is a deliberate v0.1 simplification for a dashboard counter, not a
security-relevant accounting guarantee.

`ServerCoordinator.requestLog` forwards `ServerService.requestLog`, and
`ServerDashboard` polls it once a second (via `.task(id: isRunning)`, which
SwiftUI cancels automatically when the server stops) to show live request
counts, transferred bytes, and the most recent requests.

Covered by `Tests/iServeTests/RequestLogTests.swift` (bounding, totals,
ordering — no networking) and the request-log cases in
`StaticFileServingLifecycleTests.swift`/`LiveServerServiceTests.swift` (a
real request recorded through the full `HTTPServer`/`HTTPConnection`
pipeline, and through a full `LiveServerService` session respectively).
