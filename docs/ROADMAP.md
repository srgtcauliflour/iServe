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
- Multi-selection and streaming ZIP/archive downloads.
- Authentication/session layer.
- Capability-based server permissions.
- File Sharing, File Drop and Full Access profiles.
- WebDAV read operations, then authorized write operations.
- Optional multiple mounted folders after secure namespace design.
- Rate/connection/request limits and advanced logs.
- Feature-rich in-app sandboxed file manager: open/preview files in place
  (text, images, video, PDF), edit text-based files, and archive support
  beyond zip/unzip — 7z, RAR and other common compression formats — plus
  whatever else a proper on-device file manager benefits from (rename,
  move, copy, delete within capability limits, multi-select actions,
  search), all still bounded to the selected root the same way serving
  already is. Materially bigger than "download/upload a file" — needs its
  own scoping pass and likely its own ADR once v0.3's transport/auth layer
  lands, especially for in-place editing and third-party archive-format
  libraries (RAR support in particular has licensing considerations to
  check before picking a library).

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
