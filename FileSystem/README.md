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

This is root selection, not remote filesystem authorization. Issue #3 must supply
central secure path resolution before any handler accesses requested content.
Issue #4/#5 must add a server-session scope lifetime, reacquire access before
serving and retain it until all connections/file operations finish cancellation.
Do not use a remembered URL as proof that scope is currently held.
