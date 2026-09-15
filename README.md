# iServe

iServe turns an iPhone or iPad into an on-demand web and file server while the app is open. Select a folder from Files, tap Start Server, and expose approved content over local networking and, where the network permits it, direct public connectivity.

The product is inspired by the best sharing capabilities of the historical **Shu / Magic File Viewer** experience and extends that model with modern iOS APIs, static website hosting, PHP support, WebDAV, large-file streaming, multi-file downloads, QR/Bonjour discovery, explicit permissions, and stronger security.

## Product principles

1. **Select → Start → Connect.** Basic sharing must take seconds.
2. **Foreground by design.** Serving is intentionally limited to the active app session.
3. **Files-first.** A selected security-scoped folder becomes the server root; avoid unnecessary imports/copies.
4. **Network everywhere.** Treat Wi-Fi, Personal Hotspot, Ethernet, IPv4 and IPv6 as available server paths rather than designing a Wi-Fi-only server.
5. **Stream, don't buffer.** Large files, uploads and generated archives use bounded memory.
6. **Secure by construction.** Every filesystem request passes authorization and canonical path validation before file access.
7. **Modular core.** HTTP, transfer, WebDAV and PHP remain independent modules.

## Release roadmap

- **v0.1 — Server Foundation:** folder picker, security-scoped access, HTTP/1.1 core, static sites, streaming, LAN endpoint, start/stop and request logs.
- **v0.2 — Shu Parity:** Wi-Fi/hotspot-oriented sharing, interface discovery, Bonjour, QR connection, browser file manager, uploads/downloads, large-file handling and transfer statistics.
- **v0.3 — Advanced File Server:** Range/resume, streaming ZIP, permissions/authentication, WebDAV, advanced logging and optional multiple mounts.
- **v0.4 — Web Application Server:** embedded PHP bridge/runtime, forms, cookies, sessions, uploads, SQLite/PDO, selected extensions and PHP diagnostics.
- **v1.0 — Gold Release:** security hardening, stress/compatibility testing, polished iPhone/iPad UX, accessibility, public-reachability guidance and release documentation.

See [`docs/MASTER-SPEC.md`](docs/MASTER-SPEC.md), [`docs/ROADMAP.md`](docs/ROADMAP.md), [`docs/SECURITY.md`](docs/SECURITY.md), and [`AGENTS.md`](AGENTS.md).

## Current development target

**v0.1 acceptance path:**

`Choose Files folder → Start Server → another LAN device opens the displayed URL → index.html is served correctly.`

PHP and WebDAV deliberately come after the HTTP/filesystem/streaming foundations are proven.
