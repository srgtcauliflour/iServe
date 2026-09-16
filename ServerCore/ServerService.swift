/// The app's lifecycle boundary. Implementations own all listener and connection
/// resources, plus any security-scoped access they acquire to serve them.
@MainActor
protocol ServerService: AnyObject {
    /// Attempts to start serving and returns the bound local port once the
    /// listener reports ready. Throws (without starting anything) if there is
    /// no folder to serve, scoped access could not be acquired, or the
    /// underlying listener failed to start.
    func start() async throws -> UInt16

    /// Must synchronously initiate cancellation of every owned network
    /// resource and release any security-scoped access this service acquired
    /// to serve them. Repeated calls must be safe, including before the first
    /// start.
    func stop()
}

/// Bootstrap implementation: no listener, always refuses to start, never
/// claims to serve content. `ServerCoordinator`'s default until a caller
/// supplies a real `LiveServerService`.
@MainActor
final class UnconfiguredServerService: ServerService {
    enum ServiceError: Error {
        case unavailable
    }

    func start() async throws -> UInt16 {
        throw ServiceError.unavailable
    }

    func stop() {}
}
