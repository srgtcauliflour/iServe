# ADR-0006: Per-address connection/request rate limits and rejected-connection telemetry

- Status: Accepted for v0.3
- Date: 2026-09-17

## Context
`docs/SECURITY.md` lists "Slow clients and connection exhaustion" among the threats to test continuously, and `docs/MASTER-SPEC.md` §6 requires "Connection/request limits are configurable and conservative." `HTTPServer.accept(_:)` has only ever enforced one bound so far: a global `HTTPServerLimits.maxConcurrentConnections` ceiling across every client combined. Nothing stops a single remote address — a misbehaving client, a runaway script, or a genuinely hostile one on the same LAN/hotspot — from opening enough connections to consume every slot and starve every other device, which is exactly the "connection exhaustion" scenario named above.

`docs/ROADMAP.md`'s v0.3 deliverable "Rate/connection/request limits and advanced logs" groups connection limits and request limits together. This server's v0.1 design (`ServerCore/HTTPConnection.swift`: no keep-alive/pipelining, at most one response per connection) makes that grouping exact rather than approximate: since one connection serves exactly one request, a limit on connections-per-address-per-window *is* a limit on requests-per-address-per-window. No separate per-request counter is needed.

## Decision
Add two new bounds to `HTTPServerLimits`, both scoped to a single remote address (never in addition to the existing global cap — both apply together):

- `maxConnectionsPerAddress` (default 16): how many connections one address may have open *at the same time*. Independent of `maxConcurrentConnections` (default 32), so even a fully "well-behaved but very busy" client can never claim the whole global budget.
- `maxConnectionsPerAddressPerWindow` (default 120) over `addressRateWindow` (default 10 seconds): how many connections (~= requests) one address may *open* within a rolling window, regardless of how quickly each one finishes — this is what actually stops a rapid open-serve-close flood the concurrent cap alone wouldn't catch, since such a flood can keep concurrent usage low while still hammering the server.

`HTTPServer` (the actor already owning `accept(_:)`) tracks, per address (keyed by `"\(connection.endpoint's host)"`, ignoring port so multiple sockets from the same client collapse to one key): the set of currently-open connection IDs, and the timestamps of connections accepted within the current window (pruned lazily on each check). Both new checks run right after the existing global-cap check, before an `HTTPConnection` is ever constructed. A connection whose remote address can't be determined (only expected for a non-`hostPort` endpoint, which an accepted inbound TCP connection should never be) skips per-address limiting and falls back to the global cap alone, rather than being refused outright for an implementation gap.

**Rejection stays silent — no response, `connection.cancel()`** — exactly like the existing global-cap rejection this decision sits beside. Sending a proper `429`/`503` here would mean writing a response before any `HTTPConnection`/parser exists, a second, parallel response-construction path for one narrow case. Silence is already this server's answer to "too many connections" today; extending the same answer to a per-address cap is consistency, not a new gap.

**Supporting the "advanced logs" half of this deliverable**, `Logging/RequestLog.swift` gains a `rejectedConnectionCount` counter (surfaced on `Snapshot`), incremented once per rejection regardless of which of the three checks (global cap, per-address cap, per-address rate) caused it. A single counter, not a reason-by-reason breakdown: this is meant to answer "is something being turned away right now," a signal worth surfacing on the dashboard, not a diagnostic tool for which limit specifically fired — that's a bigger feature (structured connection-level logging) this ADR doesn't attempt.

## Consequences
### Positive
- Directly answers the "Slow clients and connection exhaustion" threat `docs/SECURITY.md` names, with a bound that degrades gracefully (one client misbehaving costs that client, not everyone else).
- The one-connection-one-request invariant means this is genuinely one mechanism for two roadmap concerns (connection limits and request limits), not two features bolted together.
- Bounded memory: per-address tracking only ever holds entries for addresses with a connection open or a connection within the last `addressRateWindow` — an idle address is pruned away, so a long session doesn't accumulate state for every client that has ever connected.

### Costs
- Both new limits are per-remote-address, which on a NATed/shared connection (a Wi-Fi router doing NAT for several devices, a corporate proxy) could mean several distinct people share one budget. Accepted for a LAN-first, single-owner-operated server; revisit if iServe ever needs to distinguish clients behind shared NAT.
- No response is sent on a per-address/rate rejection, same trade-off the existing global-cap rejection already accepts: a client sees a reset connection, not an informative status code.
- `rejectedConnectionCount` is a single total, not broken down by cause — sufficient to notice something is being limited, not to diagnose which bound without reasoning about traffic patterns separately.

## Revisit triggers
Reconsider per-address scoping if NAT/shared-connection false positives turn out to matter in practice. Reconsider the single rejection counter if a real debugging need shows up for which specific limit fired.
