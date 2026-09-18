# ADR-0010: PHP outbound networking (proposed, not yet accepted)

- Status: Proposed — a stub naming the open questions, not a design ready to build. Requires its own explicit accept before any code changes, per `docs/SECURITY.md`'s ADR-gate discipline and ADR-0009's own "Revisit triggers" section, which names this exact scenario: "Reconsider the extension allowlist if a specific, real target application needs `curl`... badly enough to justify the added attack surface and build complexity — each addition should be its own small ADR amendment, not a silent expansion."
- Date: 2026-09-18

## Context
ADR-0009 deliberately excluded `curl`/sockets from v0.4's extension allowlist and forced `allow_url_fopen=0`/`allow_url_include=0` in `PHP/Bridge/iserve_php_bridge.c`'s hardcoded ini: "a PHP script making outbound network requests is a materially different threat than 'serve local files' — the device would originate traffic a person never asked for." That was a deliberate first-cut scope limit, not an oversight.

A real need for it has since been named directly: iServe serves two different audiences — people sharing files, and people locally testing a website they're building — and the second group routinely needs a page to pull from an RSS feed, call a third-party API, or reference a remotely-hosted icon/asset while it's under development.

**Separately, and already resolved without needing this ADR**: whether a *plain HTML page* iServe serves can reference remote resources at all. Confirmed true today, no code change needed — this server sends no `Content-Security-Policy`, CORS, or other response header that restricts what a browser does with a page after receiving it (checked directly: no such header exists anywhere in this codebase). A served page's own `<script>` calling `fetch('https://api.example.com')`, or an `<img src="https://...">` pointing at a remote icon, is a request the *browser rendering that page* makes directly to that remote host — entirely outside iServe's own process, exactly like any other website. Nothing here needs to change for that half of the request; it already works whenever the viewing device has its own internet connectivity alongside its connection to iServe.

This ADR is scoped only to the other half: giving *PHP scripts executing inside iServe's own process* (`PHP/Bridge`'s embed-SAPI worker) that same ability. That is a fundamentally different trust boundary from a browser's own fetch — the outbound request would originate from the device's own PHP interpreter, running server-side, not from client-side code in a browser someone already chose to open the page in.

## Decision
Not yet made. This document exists to capture the open questions a real decision needs to resolve, rather than let this get silently scoped into an implementation with no accepted design. At minimum:

- **Mechanism.** Statically compile `curl` (real HTTP/2, proper certificate validation, wide protocol/auth support, but a meaningfully larger attack surface and build-size cost) vs. re-enabling `allow_url_fopen` for PHP's own `http://`/`https://` stream wrapper only (much smaller surface, HTTP/1.1-only, fewer options — good enough for a simple RSS/JSON-API GET, not for much else) vs. both, gated independently.
- **Scope/consent.** Almost certainly its own capability toggle — off by default, layered on top of (never implied by) `phpExecutionEnabled`. Someone opting into "run PHP" should not automatically also opt into "and let it reach the internet," the same way selecting a folder has never implied upload/write access (`docs/SECURITY.md`'s standing rule, and the exact pattern `ServerCoordinator.phpExecutionEnabled` itself already follows relative to `profile`).
- **SSRF / local-network exposure.** A PHP script with outbound access can reach not just the public internet but the device's own LAN — other services iServe itself might be running, or anything else on whatever network the phone/tablet is joined to. Needs an explicit position: unrestricted, or a host/IP-range denylist (RFC 1918 private ranges, loopback, link-local) applied by default.
- **DNS rebinding.** A hostname that resolves to a public IP when a request is built but a private one by the time the connection is actually made is a known, real SSRF bypass technique — any denylist approach has to validate the *resolved* IP at connect time, not just the hostname up front.
- **Resource bounds.** Request timeout, response size cap, redirect limit, concurrent-outbound-connection cap — the same "bounded, never unbounded" discipline `HTTPServerLimits` already enforces on the server's inbound side, mirrored for this new outbound one.
- **Remote error behavior.** Consistent with ADR-0009's existing "never leak local detail" rule, extended to the outbound direction: a failed or timed-out fetch should surface as an ordinary PHP-visible failure a script can already handle (`curl_exec` returning `false`, `file_get_contents` returning `false`), never a crash or a leaked internal detail.

## Consequences
Anticipated, pending an actual accepted design — recorded now so the tradeoff is visible up front rather than discovered mid-implementation.

### Positive
- Closes a real, already-named gap: a site under active local development that integrates a live RSS feed, a third-party API, or a remote asset becomes testable in place, not just sites that happen to already be fully self-contained.

### Costs
- A materially larger and categorically different security surface than anything ADR-0009 accepted. "Execute arbitrary code against a selected folder" (already accepted, itself non-trivial) plus "...and let that code originate outbound network traffic, potentially reaching the rest of the local network too" is a further, distinct step up — deserving the same "its own dedicated test suite before this is release-ready" treatment ADR-0009 already requires for PHP execution itself, per `docs/ROADMAP.md`'s compatibility/security test suite deliverable.

## Revisit triggers
Come back to this the moment someone is actually ready to scope and build it, so that work starts from this named set of open questions instead of from a blank page. Until then this stays Proposed, and `allow_url_fopen`/`allow_url_include` stay off and no network-capable extension is compiled in, exactly as ADR-0009 already ships.
