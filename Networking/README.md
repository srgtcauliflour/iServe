# Networking

`LocalNetworkAddress.preferredIPv4Address()` (issue #6) walks active network
interfaces via `getifaddrs` to find a LAN-facing IPv4 address — preferring a
Wi-Fi/Ethernet-family name (`en*`) or Personal Hotspot host mode (`bridge*`)
over cellular or loopback — so `ServerCoordinator` can display an endpoint
another device on the same network can actually reach. It returns `nil` if no
such interface is up; callers must handle that (the coordinator falls back to
`localhost`, which is only useful for on-device testing, not real LAN sharing).

A discovered address is informational, not proof of inbound reachability —
see `docs/SECURITY.md`. Bonjour/mDNS advertisement, QR/copy connection
helpers beyond the dashboard's plain copy button, and distinguishing a
discovered public address from verified external reachability are v0.2/v0.3
(see `docs/ROADMAP.md`), not this module's v0.1 scope.
