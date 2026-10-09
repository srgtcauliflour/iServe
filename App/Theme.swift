import SwiftUI

/// The in-app appearance override (Options screen) -- independent of and
/// layered on top of the system's own Light/Dark setting, same pattern as
/// `ServerCoordinator.profile`/`requiresPassword`: an explicit, persisted
/// choice, defaulting to following the system rather than forcing one way.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Visual design tokens shared by every "glass card" surface in the app, so
/// corner radius/spacing stay consistent without repeating magic numbers.
enum GlassMetrics {
    static let cardCornerRadius: CGFloat = 24
    static let controlCornerRadius: CGFloat = 16
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 18
}

/// Apple's real Liquid Glass material (`glassEffect(_:in:)`/
/// `GlassEffectContainer`, iOS 26) is the target look this app is designed
/// around -- but this project's deployment target stays at iOS 17 (not
/// every install is on 26 yet), so every glass surface branches: the real
/// material on 26+, a `.ultraThinMaterial`-backed approximation
/// (translucent, blurred, a soft light border to read as "glass" rather
/// than a flat card) below that. Both branches share the same shape/corner
/// radius so layout never shifts between them.
///
/// `#if compiler(>=6.2)` wraps the real-glass branch *in addition to* the
/// runtime `if #available(iOS 26.0, *)` check -- `#available` only decides
/// at runtime whether to take a code path; it does nothing to stop the
/// compiler from needing `Glass`/`glassEffect` to actually be declared in
/// the SDK it's building against. A real CI run on Xcode 16.4 (iPhoneOS
/// 18.5 SDK, no iOS 26 SDK at all) proved this the hard way: "cannot find
/// 'Glass' in scope" even inside an `#available(iOS 26.0, *)` branch,
/// since that SDK doesn't declare the symbol under any condition. Xcode 26
/// bundles Swift 6.2 (confirmed against Apple's own Xcode 26 release
/// notes); Xcode 16.x bundles Swift 6.0/6.1 -- `compiler(>=6.2)` is
/// evaluated before typechecking, so the real-glass branch is skipped
/// entirely (never even looked up) on any toolchain that can't declare it,
/// while `#available` still separately decides, at runtime, whether a
/// *device* on iOS 17-25 gets the real material even when the app was
/// built with an Xcode 26+ toolchain capable of both branches.
private struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return AnyView(
                content
                    .glassEffect(tint.map { Glass.regular.tint($0) } ?? Glass.regular, in: shape)
            )
        }
        #endif
        return AnyView(
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .background(
                    tint.map { color in
                        shape.fill(color.opacity(0.12))
                    }
                )
        )
    }
}

extension View {
    /// The standard translucent "glass card" surface used throughout the
    /// app -- a status card, the folder card, the connection card.
    func glassCard(cornerRadius: CGFloat = GlassMetrics.cardCornerRadius, tint: Color? = nil) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius, tint: tint))
    }
}

/// The large, full-width Start/Stop control's own style -- a glass-tinted
/// capsule on iOS 26+ (real `Glass.regular.tint(_:).interactive()`), a
/// material-backed capsule with a colored tint below that. Kept as its own
/// `ButtonStyle` (rather than another `glassCard` use) since a button also
/// needs a pressed-state visual response, which `glassCard` alone doesn't
/// provide.
///
/// Named `AppGlassProminentButtonStyle`, not `GlassProminentButtonStyle` --
/// iOS 26 itself declares a real SwiftUI type with that exact name
/// (`PrimitiveButtonStyle`'s `.glassProminent` static member), and reusing
/// it here would collide with that framework symbol once the iOS 26 SDK is
/// in scope, not just read confusingly similar.
///
/// Same `#if compiler(>=6.2)` guard as `GlassCardBackground` above, for the
/// identical reason: `Glass`/`glassEffect` must be excluded from
/// compilation entirely on a toolchain whose SDK doesn't declare them at
/// all (Xcode 16.x), not just skipped at runtime via `#available` -- a real
/// CI run on Xcode 16.4 proved `#available` alone insufficient here too.
struct AppGlassProminentButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let capsule = Capsule(style: .continuous)
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                configuration.label
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .glassEffect(Glass.regular.tint(tint).interactive(), in: capsule)
            } else {
                configuration.label
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(tint.gradient, in: capsule)
                    .overlay(
                        capsule.strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
            }
            #else
            configuration.label
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(tint.gradient, in: capsule)
                .overlay(
                    capsule.strokeBorder(.white.opacity(0.25), lineWidth: 1)
                )
            #endif
        }
        .opacity(configuration.isPressed ? 0.75 : 1)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AppGlassProminentButtonStyle {
    /// Named `appGlassProminent`, not `glassProminent` -- iOS 26 itself
    /// adds a real `ButtonStyle == .glassProminent` static property, and
    /// this stays clearly distinct from it rather than risk confusing the
    /// two (this one needs a `tint:`, so it can look like a primary/
    /// destructive action; Apple's own doesn't take one).
    static func appGlassProminent(tint: Color) -> AppGlassProminentButtonStyle {
        AppGlassProminentButtonStyle(tint: tint)
    }
}
