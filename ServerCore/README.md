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
  itself), or `.file(HTTPFileBody)` — a URL + byte length from an already
  successful `SecurePathResolver` resolution, never file contents. Only
  `HTTPConnection` opens and reads a `.file` body, through
  `Transfer/FileChunkReader.swift`, in bounded chunks — `AGENTS.md` requires
  bounded streaming, never a whole-file `Data` load.
- `HTTPRouter` dispatches a method-supported request to a response.
  `NotFoundRouter` is the original v0.1 bootstrap implementation;
  `Handlers/StaticFileHandler.swift` (issue #5) is the real one, resolving
  `request.target` (query string stripped) through
  `FileSystem/SecurePathResolver.swift`.
- `HTTPServer` (an actor) owns the `NWListener` lifecycle: `start()` is
  deterministic and repeatable, and `stop()` cancels the listener and awaits
  every live connection's cancellation before returning. A connection beyond
  `HTTPServerLimits.maxConcurrentConnections` is cancelled immediately rather
  than queued.
- `HTTPConnection` (an actor) owns exactly one accepted `NWConnection`: it
  reads bounded chunks into the parser, dispatches GET/HEAD through the
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

- `LiveServerService` (issue #6, `@MainActor`) is the real `ServerService`:
  `start()` acquires scoped access to the currently selected folder via
  `FolderRootManager.beginServingAccess()` — for the entire server session,
  not just validation — builds an `HTTPServer` rooted there with a real
  `StaticFileHandler`/`SecurePathResolver` and a fresh `RequestLog`, and
  starts it. `stop()` cancels the listener/connections (`await`ed inside a
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
independent of any listener), `HTTPRouterTests.swift` (headers/response
encoding), `ServerLifecycleTests.swift` (real loopback start/stop determinism,
GET/HEAD/unsupported-method behavior, concurrent connections),
`StaticFileServingLifecycleTests.swift` (a real `StaticFileHandler` served
end to end, including a large payload streamed byte-exact and a real request
recorded into an injected `RequestLog`), and `LiveServerServiceTests.swift`
(a real folder served through the full scoped-access + `HTTPServer` session
lifecycle, including the session's `requestLog` going from `nil` to
populated to `nil` again across start/request/stop).
