# ADR-0008: Password-only cookie login for browser navigation, alongside HTTP Basic Auth

- Status: Accepted for v0.3
- Date: 2026-09-17

## Context
`docs/adr/0002-http-basic-authentication.md` implemented optional authentication as HTTP Basic Auth (RFC 7617), deliberately relying on the browser's own native credential prompt rather than a custom login page — "no custom login page, no JavaScript, consistent with every other form in this app." That native prompt, however, is not password-only: every browser renders Basic Auth's challenge as a username *and* password dialog, even though iServe's own credential model has never had a username (`ServerCredentials` accepts one but never checks it). A person actually using this — connecting from a phone or laptop's browser to browse or download files — sees a login box asking for something that doesn't exist and does nothing, which is confusing regardless of how clearly the app itself is labeled "password only."

ADR-0002's own Revisit triggers anticipated this: "Reconsider only if the product needs ... session tokens/cookies (which would require deciding what 'session' means once persistent connections or a login flow exist) ... Any of those requires its own ADR rather than extending this one." This is that ADR.

The constraint that keeps this from being a simple swap: WebDAV clients (Finder's "Connect to Server," Cyberduck, and similar) authenticate over the WebDAV protocol itself, using HTTP Basic/Digest Auth baked into the client — they have no concept of following a redirect to an HTML form, filling it out, and holding a cookie the way a browser does. Removing Basic Auth entirely to fix the browser experience would silently break `ServerProfile.fullAccess` (WebDAV writes) for every password-protected session used with a real WebDAV client.

## Decision
Keep HTTP Basic Auth working exactly as ADR-0002 defined it, and add a second, independent path specifically for ordinary browser navigation:

- **A plain, password-only HTML login page** (no JavaScript, matching every other form in this project — `Handlers/LoginPageRenderer.swift`) is shown instead of a bare `401` when an unauthenticated `GET`/`HEAD` — the two methods an actual browser navigation actually uses — arrives with neither a valid session cookie nor valid Basic credentials. It `POST`s to one reserved path (`/__iserve/login`), intercepted by `ServerCore/HTTPConnection.swift` before it ever reaches `SecurePathResolver` or the router — it is a control-plane endpoint, not a file, and shares no namespace with anything the served folder(s) contain.
- **Every other method** (`POST` uploads, `PROPFIND`, `MKCOL`, `PUT`, `DELETE`, `MOVE`, `COPY`) keeps today's exact behavior: a missing/wrong credential is `401` with `WWW-Authenticate: Basic realm="iServe"`, unconditionally, regardless of whether the request happens to carry a session cookie's absence — this is what WebDAV/API-style clients already know how to respond to, and changing it for them would be the exact regression this ADR exists to avoid.
- **A correct password on the login form mints a session token** (`ServerCore/SessionTokenStore.swift`, an actor shared by every connection this server session accepts — v0.1 has no keep-alive, so a session cookie is the only way one browser's later requests are recognized as already authenticated) and responds `303 See Other` back to wherever the client was actually trying to go (a hidden `redirect` field, captured from the original request's path when the login page was first shown), with `Set-Cookie: iserve_session=<token>; Path=/; HttpOnly; SameSite=Strict`. No `Secure` flag — this server only ever speaks plain HTTP, the same accepted trade-off ADR-0002 already made for the password itself.
- **A wrong password re-shows the same login page with an error** rather than a generic `401` — the whole point of this flow is that a browser never sees Basic Auth's native prompt at all.
- **A valid session cookie is checked first**, before either Basic Auth or the login-path check, and — if present and valid — is sufficient on its own to reach the router; a browser that has already logged in never re-sends Basic credentials and never sees the login page again on a later request.
- **Session tokens are never persisted to disk** and are cleared entirely on `HTTPServer.stop()`, matching `ServerCredentials`'s own "never persisted, re-enter each time" rule for the password itself — restarting the server invalidates every previously-logged-in browser, same as it already invalidates every other per-session server-side state (`AddressConnectionTracker`, `RequestLog`).
- **The `redirect` value is validated before ever appearing in a response header or HTML attribute**: only a same-origin, root-relative path (starts with `/`, not `//`, containing neither `\r` nor `\n`) is honored, falling back to `/` otherwise — this value round-trips through a client-controlled form field (unlike `request.target`, which can never contain a raw CR/LF, since the request line it appears in has already ended by the time a target is parsed), so without this check a crafted `redirect` could mount an open redirect or inject additional response header lines.

## Consequences
### Positive
- The confusing username field is gone for the case that actually matters day to day — a person opening the server's address in a normal browser.
- WebDAV/Full-Access clients need no changes and keep working exactly as before; this ADR adds a path, it does not remove one.
- No new UI beyond the login page itself and the toggle/password field ADR-0002 already added — the login page is server-rendered, plain HTML, same posture as every other form in this project.
- `SessionTokenStore`'s cross-connection sharing is the only structural addition to `HTTPServer`/`HTTPConnection`; everything else is a new, self-contained branch in the existing single-gate check `docs/SECURITY.md` already mandates.

### Costs
- Two authentication mechanisms now coexist for one password, rather than one — a real increase in surface a security reviewer must read, even though each individual mechanism is small.
- A session cookie is a second, longer-lived secret alongside the password itself (though scoped to `HttpOnly`/`SameSite=Strict` and cleared on restart) — a browser that stays open and never closes the tab remains "logged in" until the server restarts, with no explicit logout in this increment. Revisit if that turns out to matter in practice.
- The reserved login path (`/__iserve/login`) is global, shadowing that exact path in the primary folder or any additional mount, the same class of trade-off ADR-0007 already accepted for a same-named mount shadowing a primary-folder entry — for a path this unlikely to collide with real content, accepted without a dedicated escape hatch.

## Revisit triggers
Reconsider if a real need for explicit logout, multiple concurrent distinct passwords, or session expiry (beyond "cleared on server restart") emerges — any of those is a large enough change in what "session" means here to warrant its own ADR rather than extending this one.
