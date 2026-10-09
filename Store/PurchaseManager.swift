import Foundation
import StoreKit
import Observation

/// Gates `OptionsView`'s content behind a single, non-consumable, lifetime
/// unlock In-App Purchase ($2.99, one-time -- explicitly not a subscription,
/// so this is a `Product.ProductType.nonConsumable`, never auto-renewable).
/// Built on StoreKit 2 (`Product`/`Transaction`'s async/await API), available
/// unconditionally from this project's iOS 17 deployment target -- no
/// `SKPaymentQueue` observer pattern needed.
///
/// Security posture, stated plainly rather than oversold: every check here
/// verifies Apple's own cryptographically-signed transaction (StoreKit 2's
/// `VerificationResult`, checked against Apple's own certificate chain)
/// rather than trusting a cached local flag alone -- `isUnlocked` is always
/// re-derived from `Transaction.currentEntitlements`, StoreKit's own live
/// query, not read from `UserDefaults` or similar. That closes the
/// trivial "flip a saved boolean" bypass. It does not, and cannot, make
/// this literally uncrackable: any on-device check can ultimately be
/// defeated on a jailbroken device or a patched binary, since the whole
/// app runs under the attacker's own control. Closing that remaining gap
/// needs server-side receipt validation (the App Store Server API), which
/// means standing up backend infrastructure this project doesn't otherwise
/// have -- it is a fully local, no-backend app by design (AGENTS.md). This
/// is the strongest protection practical without that, not a guarantee
/// beyond it.
@MainActor
@Observable
final class PurchaseManager {
    /// Must exactly match the non-consumable product created in App Store
    /// Connect (Monetization > In-App Purchases): $2.99, type
    /// Non-Consumable. Never change this string once the product is live --
    /// App Store Connect product identifiers are permanent.
    static let unlockProductID = "com.srgtcauliflour.iServe.unlockOptions"

    /// True when this binary's receipt is Apple's own TestFlight sandbox
    /// receipt (`appStoreReceiptURL`'s last path component is
    /// `"sandboxReceipt"` for a TestFlight install, `"receipt"` for a real
    /// App Store release, and the URL itself is nil for a plain Xcode
    /// Debug run with no receipt at all) -- the standard, widely-used way
    /// apps distinguish a TestFlight build from a production one, since
    /// Apple exposes no public `isTestFlight` API.
    static var isRunningInTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Whether a TestFlight install should unlock automatically, with no
    /// purchase needed -- on by default, so ordinary beta testers never hit
    /// the paywall. A real `@Observable`-tracked stored property (not a
    /// computed one reading `UserDefaults` directly), so its own `Toggle`
    /// in `OptionsView`/`PaywallView` updates instantly rather than waiting
    /// on `refreshEntitlement()`'s async round trip; `didSet` is what
    /// actually persists it. Exposed as its own toggle in both
    /// `OptionsView` and `PaywallView` (visible only while
    /// `isRunningInTestFlight`, never in a production build) so Apple's own
    /// App Review team -- who also install via TestFlight -- can switch it
    /// off and verify the real purchase/restore flow still works, same as
    /// Guideline 3.1.1 expects them to be able to test. Without this escape
    /// hatch, a blanket "TestFlight always unlocked" would leave reviewers
    /// unable to test the IAP at all.
    var isTestFlightAutoUnlockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTestFlightAutoUnlockEnabled, forKey: Self.testFlightAutoUnlockKey)
            Task { await refreshEntitlement() }
        }
    }
    private static let testFlightAutoUnlockKey = "iServe.testFlightAutoUnlockEnabled"

    private(set) var product: Product?
    private(set) var isUnlocked = false
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    /// `nonisolated(unsafe)`, not plain `private var`: a `@MainActor`
    /// class's `deinit` runs in a nonisolated context in Swift 6 (it isn't
    /// guaranteed to run on the main actor), so `deinit` below can't touch
    /// an actor-isolated stored property directly -- confirmed by a real
    /// CI compile failure ("main actor-isolated property
    /// 'updateListenerTask' can not be referenced from a nonisolated
    /// context"). Safe to opt out of isolation checking for specifically
    /// this property: `Task.cancel()` is documented thread-safe to call
    /// from any context, and nothing else ever reads this property's value
    /// (only assigns it once in `init()`, then cancels it in `deinit`).
    private nonisolated(unsafe) var updateListenerTask: Task<Void, Never>?

    init() {
        isTestFlightAutoUnlockEnabled = UserDefaults.standard.object(forKey: Self.testFlightAutoUnlockKey) as? Bool ?? true
        updateListenerTask = Self.listenForTransactionUpdates { [weak self] in
            await self?.refreshEntitlement()
        }
        Task {
            await loadProduct()
            await refreshEntitlement()
            isLoading = false
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.unlockProductID])
            product = products.first
        } catch {
            errorMessage = "Could not reach the App Store. Check your connection and try again."
        }
    }

    func purchase() async {
        guard let product else { return }
        errorMessage = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    errorMessage = "Apple couldn't verify this purchase. Please try again or contact support."
                    return
                }
                await transaction.finish()
                await refreshEntitlement()
            case .userCancelled:
                break
            case .pending:
                errorMessage = "Purchase is pending approval (for example, Ask to Buy)."
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed. Please try again."
        }
    }

    /// Re-downloads this Apple ID's past transactions from the App Store
    /// (a prior purchase on another device, or after a reinstall) --
    /// required by App Review Guideline 3.1.1 for any non-consumable IAP.
    func restore() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isUnlocked {
                errorMessage = "No previous purchase found for this Apple ID."
            }
        } catch {
            errorMessage = "Could not restore purchases. Check your connection and try again."
        }
    }

    /// The one place that decides `isUnlocked` -- always re-derived from
    /// StoreKit's own live, signed entitlement list (see the type's own
    /// doc comment on why this matters), never from a cached local flag,
    /// *except* the deliberate TestFlight auto-unlock above, which exists
    /// specifically to skip this check for beta testers. `revocationDate
    /// == nil` is a belt-and-braces check alongside `currentEntitlements`
    /// already excluding refunded/revoked transactions on its own.
    private func refreshEntitlement() async {
        if Self.isRunningInTestFlight && isTestFlightAutoUnlockEnabled {
            isUnlocked = true
            return
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.unlockProductID,
                  transaction.revocationDate == nil else { continue }
            isUnlocked = true
            return
        }
        isUnlocked = false
    }

    /// A long-running background listener for transactions that complete
    /// outside the immediate `purchase()` call -- Ask to Buy approval,
    /// a purchase restored via Family Sharing, or one completing after
    /// the app was relaunched. `Task.detached`, matching Apple's own
    /// StoreKit 2 sample pattern, so it runs independently of whatever
    /// triggered `PurchaseManager`'s own `init()`. `[weak self]` (via the
    /// `onUpdate` closure captured by value here, not `self` directly)
    /// avoids `self` retaining a Task that in turn retains `self` for as
    /// long as the app runs, which would otherwise leak `PurchaseManager`
    /// forever.
    private static func listenForTransactionUpdates(onUpdate: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await onUpdate()
            }
        }
    }
}
