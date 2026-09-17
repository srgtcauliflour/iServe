# FileSystem

`FolderRootManager` owns one selected root and a local bookmark. The SwiftUI Files
picker delegates selection to it through `ServerCoordinator`. `SystemFolderAccess`
is the iOS provider adapter; protocols allow deterministic denied/stale/failure tests.

Selection and restoration acquire scope, validate directory metadata and create or
refresh the bookmark, then release scope with `defer`, including failure paths.
A failed scope grant fails closed without accessing the URL. A failed replacement
preserves the old root/bookmark; a failed restore clears the usable URL but retains
the saved bookmark for Retry. Forget removes the bookmark without deleting files.
No scope remains held while idle or after the synchronous operation returns.

Bookmarks are local app preferences, never logged or sent over the network. The
privacy manifest declares app-only UserDefaults access. Picker cancellation is a
no-op; other errors are mapped to recoverable messages without local paths.

`FolderRootManager` is root selection, not remote filesystem authorization.
`SecurePathResolver` (issue #3) is the single authority that turns a decoded HTTP
request target into a filesystem URL guaranteed to stay within the selected root.
It decodes percent-escapes exactly once, rejects `.`/`..`/empty/backslash/control
components outright, then walks the path one component at a time, resolving and
containment-checking every existing symlink before the next component is appended
— so an intermediate or final symlink pointing outside the root is rejected the
same way a literal `..` is. No handler may construct its own unchecked path; every
future handler (issues #5+) must call `resolve(requestPath:)` and treat any thrown
`ResolutionError` as a generic 400/403/404 without surfacing the case internals or
any local path to the remote client.

`beginAccess()`/`endAccess(_:)` (issue #6) give any independent access holder
its own scope lifetime, separate from selection/restoration's transient
validation scope: `beginAccess()` acquires scope for the *currently*
selected root and returns that exact URL for the caller to retain and use;
`endAccess(_:)` releases scope for that same URL, not whatever happens to be
selected by the time the caller is done (the selection may have changed
since). `LiveServerService` is one such caller — it must release access only
after its `HTTPServer` has cancelled its listener and every connection, never
before. The underlying security-scoped access is reference-counted, so more
than one independent caller (for example `LiveServerService` serving and
`App/FileManagerScreen.swift` browsing the same root locally) may hold it at
once; each just needs its own matching `beginAccess()`/`endAccess(_:)` pair.
Do not use a remembered `selectedURL` alone as proof that scope is currently
held; only a caller holding a URL returned by `beginAccess()` may treat it as
scoped.

`additionalMounts` (v0.3, `docs/adr/0007-multiple-mounted-folders.md`) are
any number of extra, named, read-only shared folders alongside the one
primary root above — each with its own independent bookmark
(`MountBookmarkStore`, a separate persisted `[MountBookmark]`, never mixed
into the primary's single bookmark) and its own scope lifetime
(`beginAccess(forMountNamed:)`/`endAccess(_:)`, the same pattern as the
primary's). `addMount(_:)` derives a unique path-segment name from the
folder's own last path component, disambiguating collisions with a numeric
suffix; `removeMount(named:)` forgets one for good. `restoreMounts()` is the
multi-mount equivalent of `restore()` — called alongside it at launch — and
drops (without forgetting) any mount whose bookmark no longer resolves or
validates, so one bad mount never blocks the others. Additional mounts are
never validated or authorized for remote access here; that's `MountRouter`
(`Handlers/README.md`) and `LiveServerService`, which construct each mount's
own `StaticFileHandler` with uploads and WebDAV writes forced off
regardless of the session's `ServerProfile`.
