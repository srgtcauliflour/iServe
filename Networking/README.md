# Networking

`LocalNetworkAddress.preferredIPv4Address()` (issue #6) walks active network
interfaces via `getifaddrs` to find a LAN-facing IPv4 address — preferring a
Wi-Fi/Ethernet-family name (`en*`) or Personal Hotspot host mode (`bridge*`)
over cellular or loopback — so `ServerCoordinator` can display an endpoint
another device on the same network can actually reach. It returns `nil` if no
such interface is up; callers must handle that (the coordinator falls back to
`localhost`, which is only useful for on-device testing, not real LAN sharing).

A discovered address is informational, not proof of inbound reachability —
see `docs/SECURITY.md`. Distinguishing a discovered public address from
verified external reachability is v0.3 (see `docs/ROADMAP.md`), not this
module's scope yet.

`BonjourAdvertiser` (v0.2, Shu parity) publishes this session's endpoint over
Bonjour/mDNS as `_http._tcp.` via `NetService`, so a nearby device can find
it by name instead of typing the IP address `LocalNetworkAddress` found.
It's deliberately independent of `ServerCore/HTTPServer.swift`'s own
`NWListener` — it only publishes a name+port record, never touches the
socket that actually serves requests — so a Bonjour failure can only ever
degrade discoverability, never serving itself; `App/ServerCoordinator.swift`
starts it once `service.start()` returns a port and stops it everywhere it
stops the underlying `ServerService`. Requires `NSBonjourServices`
(`_http._tcp.`) alongside the existing `NSLocalNetworkUsageDescription` in
`project.yml`'s synthesized Info.plist — unverified by CI (no device runs
the app under test), so a real-device check is what actually confirms
advertisement/discovery works; if it doesn't, `project.yml`'s
`INFOPLIST_KEY_NSBonjourServices` single-value setting may need to become an
explicit array via xcodegen's `info:`/`properties:` block instead (see
`docs/DEVELOPMENT.md`'s v0.2 progress notes).

Its `state` only covers the deterministic `start()`/`stop()` transitions in
CI (`Tests/iServeTests/BonjourAdvertiserTests.swift`); whether a real
`.published`/`.failed` transition happens depends on actual mDNS behavior,
which isn't reliable to assert on a CI runner.
