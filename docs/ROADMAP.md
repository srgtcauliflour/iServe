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
  `WWW-Authenticate` response that triggers the browser's own native login
  prompt. See `docs/adr/0002-http-basic-authentication.md` and
  `ServerCore/README.md`. This is the gate only, not yet the
  capability-based system below.
- Capability-based server permissions. Shipped: a `ServerProfile` enum
  (`ServerCore/ServerProfile.swift`) bundles directory-listing and upload
  capabilities together per profile, chosen once per session (before
  `Start Server`) rather than left to combine freely. Website/Read Only
  additionally disables the generated directory listing for a folder with
  no index (`404` instead), so a "website" session never exposes browsing
  whatever else is in the selected folder — File Sharing and File Drop
  differ only in whether uploads are allowed. See
  `docs/adr/0003-capability-based-server-profiles.md`.
- File Sharing, File Drop and Full Access profiles. File Sharing and File
  Drop shipped as above; Full Access is defined in `ServerProfile` but
  deliberately kept out of the picker until WebDAV write operations (next)
  give it something that actually distinguishes it from File Drop.
- WebDAV read operations, then authorized write operations. Read operations
  shipped: `OPTIONS` (capability discovery — `DAV: 1`, `Allow` naming every
  supported method) and `PROPFIND` (`Depth: 0`/`1` only; a missing header or
  `Depth: infinity` is refused with `400`, and the response always describes
  a fixed property set rather than parsing the client's request body — see
  `docs/adr/0004-webdav-read-operations.md` for why both are deliberate,
  documented simplifications rather than full RFC 4918 conformance). Gated
  by the same directory-listing capability as the HTML listing
  (`docs/adr/0003-capability-based-server-profiles.md`) for a directory
  target; a known file path is never gated, same as a plain GET. Authorized
  write operations (`MKCOL`, `PUT`/`DELETE`/`MOVE`/`COPY` via WebDAV,
  `LOCK`/`UNLOCK`) remain the next, separate increment, once
  `ServerProfile.fullAccess` has something real to do.
- Optional multiple mounted folders after secure namespace design.
- Rate/connection/request limits and advanced logs.
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

Exit gate: large transfers resume correctly, archives remain bounded-memory, and WebDAV operations cannot escape authorized roots/capabilities.

## v0.4 — Web Application Server
Goal: serve useful self-contained PHP applications.

Precondition: approve PHP feasibility ADR covering runtime integration, extensions, code-signing/distribution and sandbox implications.

Deliverables:
- Embedded PHP runtime/bridge.
- Request mapping for GET/POST/cookies/server state/file uploads.
- Response status/header/body capture.
- Sessions.
- SQLite/PDO.
- Selected extensions (subject to feasibility).
- `index.php` routing.
- PHP diagnostics console.
- Compatibility/security test suite.

Exit gate: representative self-contained PHP+SQLite applications execute reliably without compromising iServe's root/permission boundaries.

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
