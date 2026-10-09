import SwiftUI
import StoreKit

/// Shown in place of `OptionsView`'s real content whenever
/// `PurchaseManager.isUnlocked` is false -- server profiles, password
/// protection, PHP execution/networking, additional folders, appearance,
/// and diagnostics are all behind this single, one-time purchase (the
/// standard "choose a folder, start serving" flow on the home screen stays
/// free regardless).
struct PaywallView: View {
    @Bindable var purchaseManager: PurchaseManager
    @State private var isPurchasing = false
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Unlock Options")
                    .font(.title2.bold())
                Text("Server profiles, password protection, PHP execution, additional folders, appearance, and diagnostics — unlocked once, for this device and every device signed into your Apple ID.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            purchaseButton

            Button {
                Task {
                    isRestoring = true
                    await purchaseManager.restore()
                    isRestoring = false
                }
            } label: {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("Restore Purchases")
                }
            }
            .font(.footnote)
            .disabled(isRestoring || isPurchasing)

            if let errorMessage = purchaseManager.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if PurchaseManager.isRunningInTestFlight {
                testFlightToggle
            }

            Spacer(minLength: 0)

            Text("One-time purchase for lifetime access. Not a subscription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard()
        .padding()
    }

    /// Only ever shown on a TestFlight install (never in a production
    /// build) -- seeing this screen at all during TestFlight already means
    /// someone (a tester or an App Review reviewer) just turned auto-unlock
    /// off to get here; this is the visible way back.
    private var testFlightToggle: some View {
        Toggle("Auto-Unlock for TestFlight", isOn: Binding(
            get: { purchaseManager.isTestFlightAutoUnlockEnabled },
            set: { purchaseManager.isTestFlightAutoUnlockEnabled = $0 }
        ))
        .font(.footnote)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var purchaseButton: some View {
        if purchaseManager.isLoading {
            ProgressView()
        } else if let product = purchaseManager.product {
            Button {
                Task {
                    isPurchasing = true
                    await purchaseManager.purchase()
                    isPurchasing = false
                }
            } label: {
                if isPurchasing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Unlock for \(product.displayPrice)")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.appGlassProminent(tint: .accentColor))
            .disabled(isPurchasing || isRestoring)
            .padding(.horizontal)
        } else {
            Text("The unlock price couldn't be loaded. Check your connection and reopen Options.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

#Preview {
    PaywallView(purchaseManager: PurchaseManager())
}
