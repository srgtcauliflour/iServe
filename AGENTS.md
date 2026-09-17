# AGENTS.md — iServe AI/Human Contributor Guide

## Mission
Build iServe into a production-quality foreground iOS/iPadOS web and file server. Preserve the simple product loop: **select a folder → start server → connect**.

## Source of truth
Read, in order, before making architectural changes:
1. `README.md`
2. `docs/MASTER-SPEC.md`
3. `docs/SECURITY.md`
4. `docs/ROADMAP.md`
5. Relevant ADRs under `docs/adr/`

If implementation and specification conflict, stop and document the conflict rather than silently redefining architecture.

## Engineering rules
- Swift/SwiftUI for the app and Apple `Network.framework` for the native listener/network layer unless an approved ADR changes this.
- Keep UI, server core, filesystem, transfer, security, networking, WebDAV and PHP concerns separated.
- Never access a requested filesystem path before it passes the central secure path resolver.
- Never load an entire arbitrary-size transfer into memory. Use bounded streaming/backpressure.
- Treat security-scoped resource lifetimes explicitly and balance access calls.
- Do not implement background-server workarounds. The product is foreground-only by design.
- Do not claim a discovered public IP is reachable. Reachability is a separate state.
- PHP/WebDAV must not become dependencies of the v0.1 static server core.
- New protocol/security behavior requires tests and, for significant decisions, an ADR.

## Agent task sizing
Prefer small independently verifiable tasks. Menial work (fixtures, MIME tables, documentation, isolated unit tests, UI previews) may be delegated to lower-cost/subagents. Architecture, security boundaries, HTTP parsing, concurrency, filesystem authorization, PHP embedding and public networking require stronger review.

## Required checks for every change
- Build remains clean for supported targets.
- Unit tests covering changed behavior pass.
- New externally visible behavior has acceptance coverage or a documented manual test.
- No path traversal or symlink-root escape is introduced.
- Memory use remains bounded for file/network payload size.
- Errors are surfaced without leaking sensitive local paths to remote clients.

## Definition of done
A task is not complete because code exists. It is complete when implementation, tests, documentation/ADR impact and acceptance criteria agree.

## Initial module boundaries
- `App/` — lifecycle, state, SwiftUI.
- `ServerCore/` — transport-neutral HTTP request/response/router abstractions plus Network.framework integration.
- `FileSystem/` — folder selection, bookmarks, scoped access, secure resolution.
- `Handlers/` — static/directory/upload/download handlers.
- `Transfer/` — streaming, ranges, ZIP.
- `Networking/` — interfaces, Bonjour, reachability, QR/public-address presentation.
- `Security/` — auth, permissions, sessions/tokens, rate limits.
- WebDAV (v0.3): no separate module — `docs/adr/0004-webdav-read-operations.md`/
  `docs/adr/0005-webdav-write-operations.md` extend `ServerCore/HTTPRouter.swift`/
  `Handlers/StaticFileHandler.swift` directly instead, since it's a thin,
  per-method extension of the same request pipeline already serving
  GET/HEAD/POST, not a distinct subsystem worth its own boundary.
- `PHP/` — optional runtime/bridge module.
- `Logging/` — request/event/statistics pipeline.
- `Tests/` — unit/integration/security tests.

## v0.1 priority
Do not jump ahead to PHP, WebDAV or relay infrastructure. Prove the secure static-server vertical slice first.