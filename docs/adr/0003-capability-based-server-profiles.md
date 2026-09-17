# ADR-0003: Capability-based server profiles (Website/Read Only, File Sharing, File Drop, Full Access)

- Status: Accepted for v0.3 (Website/Read Only, File Sharing, File Drop); Full Access reserved, not yet exposed
- Date: 2026-09-17

## Context
`docs/MASTER-SPEC.md` §2 step 4 and §4 name four server profiles — Website/Read Only, File Sharing, File Drop, Full Access — as something the user chooses before starting the server, and §5's core security invariant places "authorize capability" right after authentication/session (ADR-0002) in the mandatory pipeline. Until now the only capability that existed was the single `ServerCoordinator.uploadsEnabled` boolean threaded into `StaticFileHandler.allowUploads`; there was no notion of a "profile" at all, and no way to restrict directory browsing independent of uploads.

`docs/ROADMAP.md` lists this immediately after the authentication/session layer, explicitly as the system that gate is meant to sit in front of. Authentication answers "is this request allowed to talk to the server at all"; this ADR answers "what is this session allowed to do," which is a different, per-capability question that must be decided once per session (at `start()`), not per request.

## Decision
Introduce `ServerCore/ServerProfile.swift`, an enum with one case per `docs/MASTER-SPEC.md` §4 profile, each bundling capabilities together rather than letting them vary independently:

| Profile | Directory listing | Uploads |
|---|---|---|
| `.websiteReadOnly` | off (`404` for a no-index directory) | off |
| `.fileSharing` (default) | on | off |
| `.fileDrop` | on | on |
| `.fullAccess` | on | on (reserved — see below) |

- `ServerCoordinator.profile: ServerProfile` replaces the old `uploadsEnabled: Bool`, defaulting to `.fileSharing` — the exact capability set the old `uploadsEnabled = false` default already provided, so no existing session's behavior changes silently. Per `docs/SECURITY.md`, a service must never default to a write-capable profile on its own.
- `ServerService.start(profile:credentials:)` replaces `start(allowUploads:credentials:)`; `LiveServerService` passes `profile.allowsUploads`/`.allowsDirectoryListing` straight through to a new `StaticFileHandler.allowDirectoryListing` property (alongside the existing `allowUploads`).
- `allowDirectoryListing: false` only changes what happens when a directory has no index file: instead of a generated `DirectoryListingRenderer` listing, it's a plain `404`. It never gates a direct GET of a file or an already-known path — that was never a capability check, only `SecurePathResolver`'s containment check, and this ADR doesn't change that. This keeps Website/Read Only meaningfully distinct from File Sharing: a site is served, but the folder isn't browsable.
- ZIP downloads (`authorizeZipDownload`/`resolveZipEntries`) stay ungated by profile, per the reasoning already in `Handlers/README.md`/ADR-adjacent commentary: packaging files a client can already GET individually exposes nothing new, regardless of profile.
- `.fullAccess` is defined now (so a later capability doesn't need another `ServerService.start` signature change) but is deliberately **not** offered in `App/ServerDashboard.swift`'s picker — `ServerProfile.selectable` excludes it. Until an authorized write capability (WebDAV write operations, `docs/ROADMAP.md`'s next-listed v0.3 item) actually exists, `.fullAccess` is indistinguishable from `.fileDrop`; presenting it as a separate, selectable option today would misrepresent what it does. It becomes meaningful, and gets added to `selectable`, only once WebDAV writes land behind their own feasibility/security review.

## Consequences
### Positive
- One property (`profile`) instead of a growing set of independent booleans — adding a future capability (e.g., WebDAV writes) means adding one more `allowsX` computed property and updating the profile→capability table, not another `ServerService.start` parameter.
- Preserves every existing test/behavior by construction: `.fileSharing`'s capabilities are bit-for-bit what `uploadsEnabled = false` already meant.
- Keeps the "explicit capability, never implied" posture from ADR-0002/`docs/SECURITY.md` at the profile level too: starting still requires an explicit choice, defaulting to the least-privileged non-restrictive option.

### Costs
- `.fullAccess` exists in the type system but is inert (identical to `.fileDrop`) until WebDAV writes ship — a deliberate placeholder, not a shipped feature; anyone reading the enum without this ADR could reasonably wonder why it's unreachable from the UI.
- Website/Read Only's directory-listing restriction is new, occasionally-surprising behavior for anyone who previously relied on browsing a folder with uploads off — no prior profile combination could produce "listing off, uploads off" before this change.

## Revisit triggers
Reconsider when WebDAV write operations are implemented (`.fullAccess` needs real, distinguishing capabilities and should join `ServerProfile.selectable`), or if a profile ever needs a capability that isn't a simple boolean (e.g., a per-directory scope, or a capability that isn't "on for the whole session") — either extends this ADR rather than replacing it, unless the shape of `ServerProfile` itself needs to change.
