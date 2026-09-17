import Foundation

/// Server-session-scoped tokens for the password-only cookie login flow
/// (v0.3, `docs/adr/0008-password-only-cookie-login.md`). Deliberately
/// never persisted anywhere and cleared entirely on `HTTPServer.stop()` —
/// matching `ServerCredentials`'s own "never persisted, re-enter each
/// time" rule for the password itself. An actor, not a plain type behind
/// a lock, since `HTTPServer` hands the same instance to every
/// `HTTPConnection` it accepts and those run concurrently.
actor SessionTokenStore {
    private var tokens: Set<String> = []

    /// Mints a new token, remembers it as valid, and returns it for the
    /// caller to send back as a cookie.
    func mint() -> String {
        let token = Self.randomToken()
        tokens.insert(token)
        return token
    }

    func isValid(_ token: String) -> Bool {
        tokens.contains(token)
    }

    func removeAll() {
        tokens.removeAll()
    }

    /// 32 random bytes (256 bits) of `SystemRandomNumberGenerator` output
    /// (cryptographically secure on Apple platforms), hex-encoded — long
    /// and unpredictable enough that guessing a valid session token is
    /// never a viable alternative to actually knowing the password.
    private static func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
