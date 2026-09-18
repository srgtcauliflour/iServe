# iServe Roadmap

## v0.1 — Server Foundation
Goal: prove the secure Files → HTTP vertical slice.

Deliverables:
- iOS/iPadOS SwiftUI application shell.
- Files folder picker.
- Security-scoped root/bookmark manager.
- Secure canonical path resolver.
- Network.framework listener and connection lifecycle.
- Minimal bounded HTTP/1.1 parser.
- GET/HEAD.
- Static file handler + MIME mapping.
- `index.html`/`index.htm` resolution.
- Chunked/bounded file streaming and backpressure.
- Start/stop UI, selected-root display, local endpoint display.
- Basic request log.
- Unit tests for parser/path/MIME/routing plus device integration checklist.

Exit gate: another LAN device loads the selected `index.html`; traversal attempts fail; a large file is streamed without whole-file buffering.

## v0.2 — Shu Parity
Goal: match and modernize Shu's strongest sharing experience.

Deliverables:
- Network interface discovery and IPv4/IPv6 presentation.
- Wi-Fi and Personal Hotspot-friendly UX; Ethernet where available.
- Bonjour/mDNS advertisement.
- QR/copy/share connection helpers.
- Embedded responsive browser file manager.
- Directory browsing.
- Single-file download and streamed browser upload.
- Large-file reliability improvements.
- Transfer/request/client statistics.
- Clear public-address vs reachability state.

Exit gate: a nontechnical user can select a folder and transfer files between iServe and a browser without typing an IP when Bonjour/QR is usable.

## v0.3 — Advanced File Server
Goal: robust high-volume file service.

Deliverables:
- HTTP Range/206 and resumable downloads.
- Multi-selection and streaming ZIP/archive downloads. Shipped: a browser
  client can select several files/subdirectories in a directory listing
  (a plain, no-JavaScript checkbox form) and download them as one `.zip`,
  built in the app's own temporary directory via
  `Transfer/ArchiveManager.swift` and streamed back with
  `Content-Disposition: attachment`, then deleted once the connection
  closes. Bounded independently of upload limits
  (`HTTPServerLimits.maxZipSelectionBytes`/`maxZipEntryCount`/
  `maxZipUncompressedBytes`) and needs no capability opt-in, since
  packaging already-servable files exposes nothing a plain GET of each
  wouldn't. See `ServerCore/README.md`, `Handlers/README.md`.
- Authentication/session layer. Shipped: optional, password-only HTTP
  Basic Authentication (RFC 7617) — off by default, never persisted to
  disk, checked on every request before it reaches the router or a body
  byte is read, with a constant-time comparison and a `401`/
  `WWW-Authenticate` response for a client that already attempted
  Basic Auth. See `docs/adr/0002-http-basic-authentication.md` and
  `ServerCore/README.md`. This is the gate only, not yet the
  capability-based system below. Post-ship addition: a plain browser
  `GET`/`HEAD` with no `Authorization` header at all instead gets a
  password-only cookie login page (`/__iserve/login`) rather than the
  browser's native username+password dialog — a WebDAV/API client that
  already sends `Authorization` is unaffected. See
  `docs/adr/0008-password-only-cookie-login.md`.
- Capability-based server permissions. Shipped: a `ServerProfile` enum
  (`ServerCore/ServerProfile.swift`) bundles directory-listing, upload and
  WebDAV-write capabilities together per profile, chosen once per session
  (before `Start Server`) rather than left to combine freely. Website/Read
  Only additionally disables the generated directory listing for a folder
  with no index (`404` instead), so a "website" session never exposes
  browsing whatever else is in the selected folder. See
  `docs/adr/0003-capability-based-server-profiles.md`. Post-ship fix: index
  auto-serving had been happening in every profile whenever a folder
  happened to contain one, so File Sharing/File Drop/Full Access could
  never actually show their own listing for such a folder; now it's
  Website/Read Only-only, and every other profile always shows the
  listing (an index page is still reachable there by clicking its entry).
  The generated listing also gained a breadcrumb trail
  (`Handlers/DirectoryListingRenderer.swift`) so a browser client can jump
  to any ancestor folder directly instead of relying on the browser's own
  back button.
- File Sharing, File Drop and Full Access profiles. All three shipped and
  are selectable: File Sharing (browse + download), File Drop (adds
  uploads), and Full Access (adds WebDAV `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY`
  — `docs/adr/0005-webdav-write-operations.md`).
- WebDAV read operations, then authorized write operations. Both shipped.
  Read: `OPTIONS` (capability discovery — `DAV: 1`, `Allow` naming every
  supported method) and `PROPFIND` (`Depth: 0`/`1` only; a missing header or
  `Depth: infinity` is refused with `400`, and the response always describes
  a fixed property set rather than parsing the client's request body — see
  `docs/adr/0004-webdav-read-operations.md` for why both are deliberate,
  documented simplifications rather than full RFC 4918 conformance). Gated
  by the same directory-listing capability as the HTML listing
  (`docs/adr/0003-capability-based-server-profiles.md`) for a directory
  target; a known file path is never gated, same as a plain GET. Write:
  `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY`, gated by
  `ServerProfile.fullAccess`'s `allowsWebDAVWrites` and refused with `404`
  when off. `PUT` (unlike a browser upload) is allowed to overwrite an
  existing file, streaming to a hidden temporary sibling file first and
  only replacing the real destination in one atomic step once the whole
  body has arrived, so an interrupted `PUT` can never corrupt a
  pre-existing file. `DELETE`/`MOVE`/`COPY` refuse to touch the served
  root itself; `MOVE`/`COPY` refuse moving/copying a directory into its
  own subtree. `LOCK`/`UNLOCK` are a deliberate, documented non-goal for
  now — see `docs/adr/0005-webdav-write-operations.md`.
- Optional multiple mounted folders after secure namespace design. Shipped:
  any number of additional, named, read/download-only folders alongside the
  one primary root, each dispatched by the request target's first path
  component (`MountRouter`) to its own independent `StaticFileHandler`/
  `SecurePathResolver` — one mount's containment check can never be
  satisfied by another mount's tree, primary included. `/` always means the
  primary, unconditionally, regardless of how many mounts exist; there is no
  generated mounts-index page, since mount discovery happens in the app's
  own UI (`ServerDashboard`), not server-rendered HTML. With zero additional
  mounts, `MountRouter` is a provable, unconditional pass-through to the
  primary — the same `HTTPRequest` forwarded unchanged — so every
  single-folder session behaves exactly as it always has. Additional mounts
  are always read/download-only regardless of the session's `ServerProfile`
  (uploads and WebDAV writes forced off when each mount's handler is
  constructed); `MOVE`/`COPY` refuse (`409`) the moment source and
  destination resolve to different mounts. Each mount has its own
  independent security-scoped bookmark (`FileSystem/FolderAccess.swift`'s
  `MountBookmarkStore`), added/removed from `ServerDashboard` and taking
  effect on the next server start. See
  `docs/adr/0007-multiple-mounted-folders.md`. Post-ship addition: each
  mount now has its own "Preview in App" button next to its address in
  `ServerDashboard`, not just the primary shared folder.
- Rate/connection/request limits and advanced logs. Shipped:
  `HTTPServer.accept(_:)` now enforces two further, per-remote-address
  bounds beyond the existing global `maxConcurrentConnections` —
  `maxConnectionsPerAddress` (concurrent) and
  `maxConnectionsPerAddressPerWindow` over a rolling `addressRateWindow`.
  Since v0.1 has no keep-alive (one connection is one request), the
  rolling-window cap is both the connection limit and the request-rate
  limit this bullet asks for, rather than two separate mechanisms. Every
  rejection is silent (matching the existing global-cap behavior) but now
  increments a new `RequestLog.rejectedConnectionCount`, surfaced on
  `ServerDashboard` once it's non-zero — the "advanced logs" half of this
  deliverable. See `docs/adr/0006-connection-and-rate-limits.md`.
- Feature-rich in-app sandboxed file manager. Shipped: a native browse
  screen (`App/FileManagerScreen.swift`), file preview via
  `QLPreviewController` (text, images, video, PDF — whatever QuickLook
  itself supports), in-place editing of text-based files (gated on the
  file extension's `UTType` conforming to `.text`), rename/delete (swipe
  actions and multi-select), move/copy via a folder-picker sheet, in-list
  search, and zip/unzip/7z-extract via `Transfer/ArchiveManager.swift`
  wrapping [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) and
  [SWCompression](https://github.com/tsolomko/SWCompression) (this
  project's first third-party dependencies), with its own Zip-Slip
  containment check independent of either library's own protections.
  RAR support was deliberately left out: every available RAR library
  wraps the non-commercial-licensed `unrar` code, which ZIPFoundation/
  SWCompression's permissive MIT/Apache-2.0 licensing avoids entirely — no
  ADR reversed this, the licensing question was resolved by not taking on
  RAR at all. 7z support is extraction-only (no maintained
  permissively-licensed Swift library can create `.7z`) and, unlike
  ZIPFoundation's streaming reader, requires the whole archive and every
  entry's decompressed bytes in memory at once — a deliberate, documented
  departure from this project's bounded-streaming rule where no
  alternative library exists. Still remaining: archive formats beyond
  zip/7z if one ever turns out to matter, and whole-tree search (current
  search only filters the current directory's listing) — all still
  bounded to the selected root the same way serving already is.

  Post-ship fixes/additions: the file manager's multi-select `List` used
  `List(selection:)`, whose `Set`-backed selection binding intercepted a
  row's own tap even when the row was itself an interactive
  `NavigationLink`/`Button` — silently breaking opening a folder,
  previewing a file, and building a selection to compress/move/copy at
  all (delete alone kept working, since it only used a per-row swipe
  action). Replaced with hand-rolled tap-to-toggle selection so ordinary
  taps always reach the folder link/preview button. Also added: a "Done"
  exit button on the image/file preview sheet (`QLPreviewController`
  supplies one only when UIKit presents it directly, not when embedded via
  `UIViewControllerRepresentable`), and a "File Info" sheet (kind, size,
  modified date, containing folder) via each row's leading swipe actions.
  The file manager also moved to its own bottom-tab-bar destination
  (`App/RootTabView.swift`) — the app now opens directly to it, with a
  second tab for folder selection/server profile/the web server itself —
  replacing the old "Open File Manager" sheet from `ServerDashboard`. It
  was then decoupled from that second tab entirely: rather than sharing
  `ServerCoordinator.folders`' selected root (unusable until a folder was
  chosen for sharing, which has nothing to do with what a file manager is
  for), it defaults to the app's own sandboxed Documents directory, made
  reachable from outside the app via the Files app and Finder/Explorer
  (`UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` in
  `project.yml`). That default is genuinely empty on a fresh install,
  though, and iOS has no such thing as an automatic, unscoped "home
  directory" a third-party app can browse — so a "Browse Other Location…"
  action (the same system folder picker `ServerDashboard` already uses for
  the shared folder) lets a person point the file manager at On My
  iPhone/iPad, Downloads, iCloud Drive, or any other folder instead, with
  its own independent bookmark remembered for next launch so the one-time
  picker grant is the only manual step.

Exit gate: large transfers resume correctly, archives remain bounded-memory, and WebDAV operations cannot escape authorized roots/capabilities.

## v0.4 — Web Application Server
Goal: serve useful self-contained PHP applications.

Precondition: approve PHP feasibility ADR covering runtime integration, extensions, code-signing/distribution and sandbox implications. **Done** — see `docs/adr/0009-php-runtime-feasibility.md`.

Done: `.github/workflows/php-embed.yml` (a new, dedicated workflow, kept
independent of `ios.yml` — every job in it runs `continue-on-error: true`)
cross-compiles PHP 8.4.2's embed SAPI as `libphp.a` for the iOS device and
Simulator targets, in four incremental, CI-observed steps: device
cross-compile, a native-macOS embed-SAPI smoke test, a Simulator-target
smoke test (actually executed in CI via `xcrun simctl spawn`), and a
device-target link smoke test (build-only — a device binary can't execute
on a CI runner). All four green.

Done: `PHP/Bridge/iserve_php_bridge.c` is a real Swift/C bridge onto the
embed SAPI — not the stock `php_embed_init`/`php_embed_shutdown`
convenience macros (those are a one-shot, single-request-per-process design),
but a hand-built module-startup/per-request/module-shutdown split so one
process can serve many requests without re-running PHP's own module
initialization each time. It maps GET/POST/cookies/server variables in,
captures response status/headers/body out, and narrows `open_basedir` to
each request's own resolved root — all verified for real in CI via
`native-smoke-test`'s bridge integration test
(`PHP/Bridge/Tests/iserve_bridge_smoke_test.c`), which runs two requests
back-to-back in one process and checks request/response mapping,
`open_basedir` enforcement, and `disable_functions` enforcement.
`PHPWorker.swift` wraps it in a single-worker actor per ADR-0009.

Both are now wired into a real app target — but deliberately not the
`iServe` target `ios.yml` builds and ships. `project.yml` defines a second,
CI-only target/scheme, `iServeWithPHP` (same sources plus `PHP/`, linked
against `libphp.a`), built only by two new `php-embed.yml` jobs
(`build-app-with-php-device`/`-simulator`) against headers + `libphp.a`
packaged by that same workflow's own cross-compile jobs, downloaded from
the same run — never a cross-workflow artifact fetch. This keeps
ADR-0009's isolation guarantee intact: `ios.yml` and the `iServe` scheme it
builds are untouched, so PHP's fragile cross-compiled dependency still
can't break the real app's build/release pipeline, while `iServeWithPHP`
proves the bridge genuinely compiles and links as part of the full app
(SwiftUI, ServerCore, Handlers — everything), not just a standalone clang
invocation.

Done: `.php` requests now actually reach `PHPWorker` through the real HTTP
pipeline, GET/HEAD only for now. `ServerCore/PHPScriptExecutor.swift`
declares the `PHPScriptExecutor` protocol (plus `PHPRequest`/`PHPResponse`)
with no dependency on the PHP bridge itself, so `Handlers/StaticFileHandler.swift`
can hold an optional executor and stay part of the ordinary `iServe` target.
`HTTPRouter` gained a `routePHPScript(_:)` requirement (default `nil`,
mirroring how each WebDAV method already gets its own requirement rather
than being folded into `route(_:)`); `HTTPConnection` tries it first for
GET/HEAD, falling back to the ordinary static path when it declines — off,
no executor, or not a `.php` file. `ServerCoordinator.phpExecutionEnabled`
(off by default, orthogonal to `profile` per the ADR) constructs and starts
a `PHPWorker` under `#if canImport(PHPBridge)` and hands it down through
`ServerService.start`/`LiveServerService`, gated additionally on
`profile.allowsDirectoryListing` per the ADR's own framing. Verified for
real by `Tests/iServeTests/PHPScriptExecutionLifecycleTests.swift` — a fake
`PHPScriptExecutor` driven through a real `HTTPServer` over loopback, no PHP
runtime involved, so it runs on every `ios.yml` test pass, not just the
occasional `iServeWithPHP` build check.

Still open: POST bodies (`HTTPRequest` carries none today — v0.1 never
needed one; wiring `php://input` needs the same kind of streaming state
machine `HTTPConnection`'s upload/WebDAV-PUT handling already uses, not a
body field), sessions, SQLite/PDO wiring, `index.php` routing, file uploads
through the bridge, a UI toggle for `phpExecutionEnabled`, the PHP
diagnostics console, and the compatibility/security test suite below.

**Remote content in a served page, clarified (no code change needed):** a
plain HTML/CSS/JS page iServe serves has always been able to reference a
remote RSS feed, API, or icon/asset — `fetch()`/`<img src="https://...">`/
etc. are requests the *browser rendering the page* makes directly to that
remote host, entirely outside iServe's own process. This server sends no
`Content-Security-Policy`, CORS, or other response header that would
restrict that (checked directly — none exists anywhere in this codebase),
so it already works today whenever the viewing device has its own internet
connectivity. **PHP scripts reaching the internet is a different, deferred
question** — see v0.5 below.

Deliverables:
- Embedded PHP runtime/bridge.
- Request mapping for GET/POST/cookies/server state/file uploads. GET
  done; POST still open (see above).
- Response status/header/body capture. Done.
- Sessions.
- SQLite/PDO.
- Selected extensions (subject to feasibility).
- `index.php` routing.
- PHP diagnostics console.
- Compatibility/security test suite.

Exit gate: representative self-contained PHP+SQLite applications execute reliably without compromising iServe's root/permission boundaries.

## v0.5 — PHP Outbound Networking
Goal: let a PHP script served by iServe pull from a real internet source —
an RSS feed, a third-party API, a remotely-hosted icon/asset — for sites
under active local development that aren't fully self-contained.

Deliberately its own version, not folded into v0.4: ADR-0009 explicitly
scoped outbound networking (`curl`, `allow_url_fopen`/`allow_url_include`)
out of v0.4 as a first-cut security boundary, naming it as a future
amendment rather than baseline scope — see that ADR's "Revisit triggers".
v0.4's own exit gate ("without compromising iServe's root/permission
boundaries") was written against a PHP runtime that categorically cannot
originate network traffic; widening that is a distinct, additional
capability with its own threat model (SSRF against the device's own LAN,
DNS rebinding, unbounded outbound requests), not a tweak to land alongside
v0.4's already-large scope.

Precondition: accept `docs/adr/0010-php-outbound-networking.md` — currently
a stub naming the open questions (curl vs. stream-wrapper-only, a capability
toggle layered on top of `phpExecutionEnabled` rather than implied by it,
an SSRF/local-network denylist and DNS-rebinding defense, resource bounds,
sanitized remote-fetch error behavior) rather than an accepted design.

Deliverables (pending that ADR's actual decisions):
- Outbound HTTP(S) capability, off by default, gated separately from `phpExecutionEnabled`.
- SSRF/local-network-exposure defense (host/IP-range denylist, validated at connect time against DNS-rebinding).
- Resource bounds on outbound requests (timeout, response size, redirect limit, concurrency).
- Sanitized failure behavior matching ADR-0009's existing "never leak local detail" rule.

Exit gate: a locally-tested site can call a real external API/RSS feed/asset from PHP, with the same "explicit capability, never implied" and "bounded, never unbounded" discipline this project applies everywhere else, verified by its own test suite before this is considered release-ready.

## v1.0 — Gold Release
Goal: production-quality user and developer experience.

Deliverables:
- Full security review and hostile-input test corpus.
- Concurrency, memory and long-transfer stress testing.
- iPhone/iPad adaptive UI and accessibility.
- Onboarding/connection wizard.
- Refined public-connectivity diagnostics.
- Privacy/security documentation.
- Migration/backward-compatibility policy.
- Release build and distribution-readiness review.

## Post-v1 candidates
- Optional encrypted relay/tunnel for NAT/CGNAT cases.
- TLS certificate workflow improvements.
- Additional server-side runtimes only through separate feasibility/security ADRs.
- Share-sheet/Shortcuts integrations where they preserve the foreground-only product model.
- Background operation, plus a Home Screen/Lock Screen widget to start and
  stop the server without opening the app. This directly conflicts with
  the current foreground-only design decision (`AGENTS.md`: "Do not
  implement background-server workarounds") and with iOS's own
  background-execution limits on a long-running network listener, so it
  is a candidate to revisit, not a queued feature: it needs its own
  feasibility ADR first, covering which background mode/entitlement (if
  any) could apply, what "running" can actually mean while backgrounded
  under those constraints, and an App Intent for the widget's start/stop
  action. Do not implement any part of this without that ADR being
  approved first.
