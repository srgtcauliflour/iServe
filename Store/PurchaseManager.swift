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
    /// doc comment on why this matters), never from a cached local flag.
    /// `revocationDate == nil` is a belt-and-braces check alongside
    /// `currentEntitlements` already excluding refunded/revoked
    /// transactions on its own.
    private func refreshEntitlement() async {
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
