# ADR-0004: WebDAV read operations (PROPFIND/OPTIONS), depth-bounded and property-fixed

- Status: Accepted for v0.3 (read only — authorized write operations are a separate, later increment)
- Date: 2026-09-17

## Context
`docs/MASTER-SPEC.md` §3.6 and `docs/ROADMAP.md`'s v0.3 deliverables list "WebDAV read operations, then authorized write operations" right after capability-based server profiles (`docs/adr/0003-capability-based-server-profiles.md`). Until now this server only understands GET/HEAD/POST; WebDAV clients (Finder "Connect to Server", Windows' WebDAV mini-redirector, Cyberduck, various iOS/iPadOS file-manager apps) instead rely on `OPTIONS` for capability discovery and `PROPFIND` for both metadata and directory enumeration.

A conformant `PROPFIND` implementation (RFC 4918 §9.1) parses the request body's XML to determine which specific properties the client asked for (`<allprop/>`, `<propname/>`, or a named `<prop>` list), and supports `Depth: 0`, `Depth: 1`, and `Depth: infinity` (a full recursive tree walk). Both of those are meaningfully larger undertakings than this ADR's scope: an XML parser is a new dependency this project has otherwise avoided taking on for a request body (`Transfer/MultipartFormDataParser.swift` and the ZIP-selection form are both parsed by hand precisely because they're simple enough not to need one), and an unbounded `Depth: infinity` walk conflicts with `docs/MASTER-SPEC.md` §6's "bounded" performance invariant the same way an unbounded ZIP selection would.

## Decision
Implement read-only WebDAV support with two deliberate simplifications, both documented here rather than left as silent gaps:

1. **Fixed property set, no request-body parsing.** `PROPFIND`'s body is never read or parsed. Every response describes the same fixed properties regardless of what the client asked for: `resourcetype`, `getcontentlength`/`getcontenttype` (files only), `getlastmodified`, and `displayname`. This covers what every WebDAV client actually needs to render a file browser (is this a folder, how big is it, what kind is it, when was it changed, what's it called) — the common case for every read-oriented client this server is meant to support. A client that specifically requested a narrower `<prop>` list will see extra properties in the response; in practice this is harmless (RFC 4918 clients are built to skip properties they didn't ask for), so it's an accepted, documented deviation from strict `<prop>`-list conformance rather than a functional break.
2. **`Depth: 0` or `Depth: 1` only — nothing else.** The `Depth` header must be present and exactly `0` or `1`; a missing header, `Depth: infinity`, or anything else this parser doesn't recognize is rejected with `400 Bad Request` before any resolution happens. This mirrors `Transfer/ByteRangeParser.swift`'s "ignore what this parser doesn't implement" precedent (RFC 7233 permits ignoring multi-range requests) and keeps every WebDAV response bounded to at most one directory's immediate contents — the same scope `Handlers/DirectoryListingRenderer.swift`'s HTML listing already has, never a recursive tree.

Beyond those two simplifications, the read path follows the server's existing conventions exactly:

- `ServerCore/HTTPRouter.swift` gains `routeWebDAVPropfind(path:depth:) -> HTTPResponse?`, matching `route(_:)`'s own shape: the router builds and owns the *complete* response (status/error mapping included), not just an authorization bit. `nil` means "this router doesn't support WebDAV at all," which `HTTPConnection` maps to `501 Not Implemented`; the default `HTTPRouter` extension returns `nil`, so `NotFoundRouter` stays WebDAV-incapable for free, same as it's upload-incapable today.
- `StaticFileHandler` resolves `path` through `SecurePathResolver` exactly like `route(_:)` does, and maps the same `SecurePathResolver.ResolutionError` cases to the same status codes.
- A directory target requires `allowDirectoryListing` (`docs/adr/0003-capability-based-server-profiles.md`), independent of whether an index file happens to exist there: PROPFIND is fundamentally a browsing/enumeration operation, and Website/Read Only's entire point is that the folder isn't browsable — that holds whether the client asks via the generated HTML listing or via WebDAV. Refused the same way an unbrowsable directory already is: `404`, not `403` — this server never distinguishes "exists but you can't browse it" from "doesn't exist" for a directory, on either path.
- A file target is never gated by `allowDirectoryListing` — like a direct GET, describing a path the client already knows is no different a capability question than fetching it.
- Hidden entries (dotfiles) are omitted from a directory's `Depth: 1` children, same as `DirectoryListingRenderer` and for the same reason (`docs/SECURITY.md`'s "no hidden/special metadata by default").
- `PROPFIND`'s body, if the client sends one, is never read: like rejecting an unauthorized upload before touching its body, this server's no-keep-alive design (v0.1) means there's no need to drain bytes the client is still sending before responding and closing.
- `OPTIONS` is capability discovery only — `200` with `Allow: GET, HEAD, POST, OPTIONS, PROPFIND` and `DAV: 1`, identical for every path, authenticated exactly like every other method (no special exemption).

## Consequences
### Positive
- No new dependency, no new request-body state machine in `HTTPConnection` (unlike uploads/ZIP selections, `PROPFIND` never needs one) — the whole feature is a router-owned, synchronous `HTTPResponse` builder, the simplest shape this codebase has for a request.
- Bounded by construction: `Depth: 1` can only ever describe one directory's immediate contents, the same ceiling the HTML listing already has.
- Reuses every existing security decision (path resolution, hidden-file omission, the profile-based browsing gate) rather than inventing parallel rules for the WebDAV path.

### Costs
- Not a fully RFC 4918-conformant `PROPFIND`: a client's specific `<prop>` request is ignored, and `Depth: infinity` is refused rather than served. A WebDAV client that requires a full recursive listing in one request (rather than one `PROPFIND` per directory as it navigates) won't work against this server.
- No write operations yet (`MKCOL`, `PUT` via WebDAV, `DELETE`, `MOVE`, `COPY`, `LOCK`/`UNLOCK`) — those are `docs/ROADMAP.md`'s explicitly separate next item, and will need their own authorization story once `ServerProfile.fullAccess` has something real to do (`docs/adr/0003-capability-based-server-profiles.md`).

## Revisit triggers
Reconsider the fixed-property-set simplification only if a real client turns out to depend on a narrower `<prop>` response (would need an XML parser). Reconsider the `Depth: infinity` refusal only if a specific, justified use case needs a bounded-but-larger recursive walk (a depth limit greater than 1, still finite, rather than true `infinity`). Authorized write operations need their own ADR regardless, once undertaken.
