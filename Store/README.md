# Store

`PurchaseManager` gates `OptionsView`'s content behind a single, one-time,
non-consumable In-App Purchase ($2.99 — explicitly not a subscription,
`Product.productType == .nonConsumable`): server profiles, password
protection, PHP execution/outbound networking, additional mounted folders,
appearance, and diagnostics. The standard "choose a folder, start serving"
flow on the home screen stays free regardless — this gate exists only on
`OptionsView` (`App/OptionsView.swift`, `App/PaywallView.swift`).

Built on StoreKit 2 (`Product`/`Transaction`'s async/await API, not the
older `SKPaymentQueue` observer pattern), available unconditionally from
this project's iOS 17 deployment target. `isUnlocked` is always re-derived
from `Transaction.currentEntitlements` — StoreKit's own live, cryptographically-
signed entitlement list — never read from a cached local flag (a
`UserDefaults` bool would be a trivial jailbreak-tool bypass). A background
`Transaction.updates` listener catches purchases completing outside the
immediate purchase flow (Ask to Buy approval, Family Sharing, restoring
on a new device).

This is the strongest *practical* protection for a fully local, no-backend
app — not a claim of being uncrackable. Closing that remaining gap needs
server-side receipt validation (the App Store Server API), which means
standing up backend infrastructure this project doesn't otherwise have
or need, and would be a real architectural departure from its fully local,
foreground-only design (`AGENTS.md`).

On a TestFlight install (`PurchaseManager.isRunningInTestFlight`, detected
via `Bundle.main.appStoreReceiptURL`'s `"sandboxReceipt"` filename — the
standard technique, since Apple exposes no public `isTestFlight` API),
`isUnlocked` defaults to true automatically, with no purchase needed —
beta testers should never hit the paywall. This auto-unlock has its own
toggle (`isTestFlightAutoUnlockEnabled`, surfaced in both `OptionsView`'s
"TestFlight Testing" section and directly on `PaywallView` so it's always
reachable either way), because App Review's own team *also* installs via
TestFlight to test a submission — without a way to turn it back off,
reviewers could never verify the real $2.99 purchase/restore flow
actually works (Guideline 3.1.1 expects it to be testable). Both the
section and the toggle are compiled out of nothing at the API level, but
only ever show themselves while `isRunningInTestFlight` — a real App
Store release build never displays this at all.

The product identifier (`PurchaseManager.unlockProductID`,
`com.srgtcauliflour.iServe.unlockOptions`) must exactly match a
Non-Consumable product created in App Store Connect (Monetization >
In-App Purchases) before this can be tested against the real App Store —
that product record itself is account/business configuration this
repository can't create on its own. For local Xcode testing without a
live App Store Connect record, use a `.storekit` configuration file (Xcode
> File > New > StoreKit Configuration File) with a matching product ID,
wired into the run scheme's Options > StoreKit Configuration.
