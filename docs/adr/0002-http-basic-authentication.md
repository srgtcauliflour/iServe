# ADR-0002: Optional HTTP Basic Authentication as the v0.3 authentication/session layer

- Status: Accepted for v0.3
- Date: 2026-09-17

## Context
`docs/SECURITY.md`'s mandatory request pipeline and `docs/MASTER-SPEC.md`'s core security invariant both name "authenticate/session (if enabled)" as the step between parsing a request and authorizing a capability — but neither has been implemented yet; every request has been unconditionally authorized so far. `docs/ROADMAP.md`'s v0.3 deliverables list "Authentication/session layer" ahead of "Capability-based server permissions" and the profile system (`docs/MASTER-SPEC.md` §4: Website/Read Only, File Sharing, File Drop, Full Access) — this ADR is only the former: a gate on *whether a request is let through at all*, not yet a system of per-capability permissions those profiles will later map onto.

iServe has exactly one class of user: whoever knows the passphrase the device's owner set. There is no accounts/identity system, and none is needed for this step — `docs/SECURITY.md`'s own "Authentication/authorization direction" describes *later* releases separating identity from capabilities, not this one.

iServe also has no TLS/HTTPS, and adding it is a materially larger undertaking (certificate provisioning/trust on arbitrary client devices with no CA) out of scope here.

## Decision
Implement optional HTTP Basic Authentication (RFC 7617), password-only (the username portion of a client's credentials is accepted but ignored, since a single shared passphrase is the only identity this step needs):

- Off by default, an explicit per-session opt-in exactly like `allowUploads` — `docs/SECURITY.md`'s "explicit capability, never implied" posture applies to this too.
- `ServerCoordinator.requiresPassword`/`.password` are plain, **never persisted to disk** — unlike the selected-folder bookmark, a plaintext secret is not something this app should keep at rest. The owner re-enters it each time they want to protect a session.
- Starting the server with `requiresPassword` true and an empty password is refused outright (`ServerCoordinator.start()`), rather than silently accepting any/no password.
- Checked once per connection, in `ServerCore/HTTPConnection.swift`, before any request — GET, HEAD, or POST — reaches the router or a single body byte is read, matching how upload authorization already gates before touching a body. Deliberately kept separate from `HTTPRouter`'s per-capability authorization methods: this answers "is this request allowed to talk to this server at all," a question that has nothing to do with which router is in use.
- The password comparison is constant-time (examines every byte of the longer operand regardless of where a mismatch is found), since an ordinary `==` short-circuits and a sufficiently patient remote attacker could otherwise recover the password one byte at a time from response timing.
- A missing/wrong credential gets `401 Unauthorized` with `WWW-Authenticate: Basic realm="iServe"`, so a browser shows its own native username/password prompt — no custom login page, no JavaScript, consistent with every other form in this app.

Basic Auth sends credentials base64-encoded, not encrypted. Without TLS, anyone who can observe the same network can read them. This is an accepted trade-off, not an oversight: `docs/SECURITY.md` already frames the threat model as "a remote request is untrusted regardless of whether it originated on a LAN, hotspot or public network," and this step is about *authorizing who may ask* rather than protecting transport confidentiality. `ServerDashboard` must say this plainly wherever the toggle lives, so an owner deciding whether to rely on it for a public/hotspot network is making an informed choice, per "public reachability should trigger stronger authentication guidance."

## Consequences
### Positive
- No session/token state at all: v0.1's one-response-per-connection design (no keep-alive) means Basic Auth's "send credentials with every request" is already exactly how this server works — nothing new to invalidate or expire.
- No new UI beyond a toggle and a password field; the login prompt itself is the browser's own, native and already accessible/localized.
- Small, independently testable surface: one gate function plus one response constructor.

### Costs
- No confidentiality for the password in transit without TLS (see above) — acceptable for the stated local-network-first threat model, not for a public deployment.
- A single shared passphrase is not per-user identity; anyone who has it has full access to whatever the active profile already allows. Real multi-user identity, if ever needed, is a different, larger feature.

## Revisit triggers
Reconsider only if the product needs real multi-user identity/roles, session tokens/cookies (which would require deciding what "session" means once persistent connections or a login flow exist), or TLS termination. Any of those requires its own ADR rather than extending this one.
