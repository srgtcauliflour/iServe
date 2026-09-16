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

`beginServingAccess()`/`endServingAccess(_:)` (issue #6) give a server session
its own scope lifetime, separate from selection/restoration's transient
validation scope: `beginServingAccess()` acquires scope for the *currently*
selected root and returns that exact URL for the caller (`LiveServerService`)
to retain and serve through; `endServingAccess(_:)` releases scope for that
same URL, not whatever happens to be selected by the time serving stops (the
selection may have changed since). `LiveServerService` must release access
only after its `HTTPServer` has cancelled its listener and every connection —
never before. Do not use a remembered `selectedURL` alone as proof that scope
is currently held; only a session holding a URL returned by
`beginServingAccess()` may treat it as scoped.
