import Foundation

/// Optional HTTP Basic Authentication (RFC 7617) gating every request a
/// server session accepts, checked by `ServerCore/HTTPConnection.swift`
/// before any request reaches the router. Deliberately separate from
/// `HTTPRouter`'s per-capability authorization methods (`authorizeUpload`,
/// etc.) — this answers a different question ("does this request carry
/// the right passphrase at all?") that has nothing to do with which
/// router is in use, matching `docs/SECURITY.md`'s mandatory pipeline
/// ("authenticate/session" before "authorize capability").
///
/// Password-only: the username portion of a client's Basic credentials is
/// accepted but never checked, since a single shared passphrase is the
/// only identity this step needs — see `docs/adr/0002-http-basic-authentication.md`.
///
/// `nil` (passed everywhere until a caller opts in) means the server
/// requires no credentials — the behavior every test predating this
/// expects.
///
/// HTTP Basic Auth sends credentials base64-encoded, not encrypted, and
/// this server only ever speaks plain HTTP, so anyone who can observe the
/// same network can read them. That's an accepted trade-off for a
/// local-network tool (see the ADR above), not an oversight.
struct ServerCredentials: Sendable, Equatable {
    let password: String
}
