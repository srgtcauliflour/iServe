# iServe Security Model

## Trust boundary
The selected Files folder is the maximum filesystem authority of a normal server session. A remote request is untrusted regardless of whether it originated on a LAN, hotspot or public network.

## Mandatory request pipeline
1. Parse with strict size/time limits.
2. Establish authentication/session when configured.
3. Authorize the requested capability.
4. Decode and normalize URL path exactly once according to documented rules.
5. Resolve through the central secure path resolver.
6. Verify the resolved target remains within the authorized root, including symlink considerations.
7. Perform the filesystem operation.
8. Stream a bounded response and record sanitized telemetry.

## Threats to test continuously
- `..` traversal and encoded/double-encoded traversal.
- Absolute paths and separator ambiguity.
- Symlink escape from selected root.
- Null/control characters and malformed UTF-8/percent encoding.
- Oversized request line/headers/body.
- Slow clients and connection exhaustion.
- Range abuse/overflow.
- Upload storage exhaustion and partial-file cleanup.
- ZIP/archive path and resource exhaustion issues.
- Unauthorized destructive WebDAV operations.
- PHP access outside allowed roots and capability boundaries.
- Leakage of absolute device paths, tokens or secrets in remote errors/logs.

## Default posture
- Local/read-only website serving first.
- Writes, WebDAV and PHP are explicit capabilities, not implied by selecting a folder.
- Public reachability should trigger stronger authentication guidance.
- Do not expose hidden/special metadata by default.
- No arbitrary shell execution.

## Authentication/authorization direction
Later releases should separate identity/session authentication from capabilities such as `view`, `download`, `upload`, `rename`, `delete`, `webdav`, and `php`. Server-profile presets map onto these capabilities.

## Public networking
A public/external IP is informational until external reachability is independently established. NAT/CGNAT/firewall limitations must never be represented as an iServe security bypass opportunity.

## PHP
PHP is a high-risk optional subsystem. Before v0.4 implementation, approve an ADR covering runtime origin/build reproducibility, iOS execution constraints, extension allowlist, filesystem restrictions, process/shell-related functions, resource limits and remote error behavior.

## Reporting
Security-sensitive changes require tests. A discovered vulnerability should be fixed on a focused branch/PR without publishing unnecessary exploitation detail before a patch is available.