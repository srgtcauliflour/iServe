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

The product identifier (`PurchaseManager.unlockProductID`,
`com.srgtcauliflour.iServe.unlockOptions`) must exactly match a
Non-Consumable product created in App Store Connect (Monetization >
In-App Purchases) before this can be tested against the real App Store —
that product record itself is account/business configuration this
repository can't create on its own. For local Xcode testing without a
live App Store Connect record, use a `.storekit` configuration file (Xcode
> File > New > StoreKit Configuration File) with a matching product ID,
wired into the run scheme's Options > StoreKit Configuration.
