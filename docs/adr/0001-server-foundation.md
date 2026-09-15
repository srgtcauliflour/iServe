# ADR-0001: Native foreground server foundation

- Status: Accepted for v0.1
- Date: 2026-09-15

## Context
iServe needs an embedded HTTP server that operates only while the app is active, serves a user-selected security-scoped Files root, scales to large transfers, and can later support discovery, WebDAV and PHP without coupling those features into the initial core.

## Decision
Use Swift and Apple's Network.framework as the native listener/connection foundation. Implement a small bounded HTTP/1.1 layer with explicit parser limits, router abstractions and streaming response bodies. Keep filesystem authorization/resolution separate from transport and handlers.

The app is foreground-only by design. We will not build background execution workarounds.

## Consequences
### Positive
- Direct control over lifecycle, backpressure and interface behavior.
- No early dependency on a large third-party server framework.
- Core can be fuzz/unit tested independently.
- Later PHP/WebDAV modules plug into routing rather than defining architecture.

### Costs
- HTTP parsing/connection correctness becomes our responsibility.
- Requires a strong hostile-input test corpus before release.

## Revisit triggers
Reconsider only if measured implementation complexity/security risk shows a mature iOS-compatible server library provides materially safer behavior without undermining architecture, distribution or streaming requirements. Such a change requires a new ADR.