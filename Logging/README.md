# Logging

`RequestLog` (issue #6, an actor) is bounded, sanitized request telemetry for
one server session: total request count, total response bytes, a
capacity-bounded (default 50) most-recent-first list of `RequestLogEntry`
(method, request target, status, byte count, timestamp), and (v0.3,
`docs/adr/0006-connection-and-rate-limits.md`) a `rejectedConnectionCount`
— one connection `HTTPServer.accept(_:)` turned away, for any of its three
limits, before an `HTTPConnection` (and so a `RequestLogEntry`) ever
existed for it. A single total, not broken down by which limit fired: it
answers "is something being turned away right now," not which one. It only
ever records what a remote client's own request already exposed — never a
local filesystem path or other implementation detail.

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
counts, transferred bytes, the most recent requests, and — only once it's
non-zero — how many connections have been turned away by server limits
this session.

Covered by `Tests/iServeTests/RequestLogTests.swift` (bounding, totals,
ordering, and `recordRejectedConnection()` incrementing its own counter
without touching request totals — no networking),
`Tests/iServeTests/ConnectionLimitLifecycleTests.swift` (a real
`HTTPServer` over loopback: a low per-address rate-window budget rejecting
requests deterministically once exhausted, a low per-address concurrent
cap rejecting some of many simultaneous connections, rejections landing in
`RequestLog.snapshot().rejectedConnections`, and `stop()`/`start()`
resetting that budget for a fresh session), and the request-log cases in
`StaticFileServingLifecycleTests.swift`/`LiveServerServiceTests.swift` (a
real request recorded through the full `HTTPServer`/`HTTPConnection`
pipeline, and through a full `LiveServerService` session respectively).
