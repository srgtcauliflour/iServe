# iServe Master Engineering Specification

## 1. Purpose

iServe is a foreground-only iOS/iPadOS application that exposes user-selected Files content through an embedded network server. It combines modern static website hosting and file transfer with the strongest usability ideas demonstrated by older tools such as Shu / Magic File Viewer: browser-based sharing, LAN/hotspot use, QR-style connection, large-file transfer and WebDAV-style access.

## 2. Primary user journey
1. Launch iServe.
2. Choose a folder using the system Files folder picker.
3. iServe acquires scoped access and records a persistent bookmark where permitted.
4. Choose a server profile (initially Website/Read Only).
5. Tap Start Server.
6. iServe starts an HTTP listener and displays usable local endpoints plus connection helpers.
7. A second device opens the endpoint and receives the selected site's index file or directory/file experience.
8. Tap Stop Server or leave the supported active-serving lifecycle; iServe tears down listeners/connections and scoped access.

## 3. Functional domains

### 3.1 Files
- Folder selection through system UI.
- Security-scoped access with explicit lifecycle management.
- Persistent bookmarks/recent roots where supported.
- Central canonical path resolver.
- Optional multiple mounts after v0.2/v0.3; one root is sufficient for v0.1.

### 3.2 HTTP server
- Network.framework listener/connection ownership.
- HTTP/1.1 first; no HTTP/2 requirement for initial releases.
- GET and HEAD in v0.1; POST/PUT/DELETE/OPTIONS added when required by uploads/WebDAV.
- Request/header size limits and timeouts.
- Correct status lines, headers, MIME types and connection closure semantics.
- Bounded streaming and backpressure.

### 3.3 Static hosting
- Resolve `/` to configured index candidates, initially `index.html`, `index.htm` and later `index.php` when PHP is enabled.
- Serve common web/media/document/archive/font MIME types.
- Reject root escape, malformed paths and unauthorized hidden/special content.
- Optional generated directory UI when no index exists.

### 3.4 File transfer
- Direct single-file downloads.
- Large-file streaming.
- HTTP Range/206 and resume in v0.3.
- Browser uploads with bounded streaming.
- Multi-select and streaming archive generation.

### 3.5 Shu-parity networking/UX
- LAN-oriented browser sharing.
- Personal Hotspot-compatible serving where iOS/network topology exposes an appropriate path.
- Ethernet support through the same interface-agnostic listener design.
- IPv4/IPv6 awareness.
- Bonjour/mDNS discovery.
- QR code and copy/share actions for usable endpoints.
- Live request/transfer statistics.
- Never equate external-address discovery with proven inbound reachability.

### 3.6 WebDAV
Optional module after static/file-server foundations. Provide standards-compatible browse/read operations first, then controlled writes (upload/create/rename/move/copy/delete) according to server permissions.

### 3.7 PHP
Optional v0.4 module. Embed an iOS-compatible PHP runtime/bridge rather than expecting a system PHP executable. Translate HTTP requests into PHP request state and capture response status/headers/body. Target common self-contained applications, particularly SQLite-backed sites. Runtime packaging and distribution constraints require an explicit feasibility/architecture review before implementation is considered release-ready.

### 3.8 Public connectivity
Direct inbound access is opportunistic, not guaranteed. NAT, CGNAT, carrier policy, IPv6 firewalling and router configuration can prevent it. The UI must distinguish local address, discovered external address and externally verified reachability. Optional relay/tunnel infrastructure is post-v1 unless separately approved.

## 4. Server profiles
- **Website / Read Only:** static/PHP content where enabled; no remote writes.
- **File Sharing:** browse + download.
- **File Drop:** browse/download/upload with no destructive operations by default.
- **Full Access:** explicit advanced profile enabling authorized WebDAV/file-management writes.

## 5. Core security invariant
For every filesystem-bound request:

`parse request → authenticate/session (if enabled) → authorize capability → normalize/decode path → canonical secure-root resolution → filesystem operation`

No handler may bypass this pipeline.

## 6. Performance invariants
- Payload memory usage must not scale linearly with arbitrary file size.
- File serving/uploads/archive generation use chunks and backpressure.
- Slow clients must not force unbounded queued data.
- Connection/request limits are configurable and conservative.

## 7. App lifecycle
Serving is foreground-only by product decision. The app does not attempt background audio/location tricks or other mechanisms to keep a server alive. Lifecycle transitions must make server state unambiguous and clean up network/scoped filesystem resources safely.

## 8. Observability
On-device dashboard should eventually expose server state, endpoints, connected/recent clients, request count, transferred bytes, uptime, recent requests and filtered HTTP/PHP/WebDAV errors. Remote errors must avoid leaking absolute local filesystem paths.

## 9. Architecture

```text
SwiftUI App
   |
Server Coordinator
   |---------------- Filesystem Root / Scoped Access
   |---------------- Network Interface/Discovery
   |
HTTP Listener -> Connection -> Parser -> Router
                                  |
          +-----------------------+----------------------+
          |                       |                      |
       Static                  Transfer               Optional
       Handler                 Handlers          PHP / WebDAV
          |                       |                      |
          +---------------- Secure Path Resolver -------+
                                  |
                              Files Provider
```

## 10. Non-goals for initial releases
- Background daemon behavior.
- General-purpose shell hosting.
- Arbitrary server-side executable support.
- Guaranteed public-IP reachability.
- Cloud account requirement.
- Relay infrastructure in the core v1 path.

## 11. v0.1 acceptance gate
A real iPhone/iPad build can select a folder containing `index.html`, start the listener, display a LAN-relevant endpoint, and a second device on the applicable local network can request `/` and receive the file correctly. The same implementation must reject traversal outside the selected root and stream a large test file without whole-file buffering.
