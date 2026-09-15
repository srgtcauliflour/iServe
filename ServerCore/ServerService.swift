/// The app's lifecycle boundary. Implementations own all listener and connection resources.
/// A future Network.framework implementation must report readiness asynchronously before
/// the dashboard can claim to be serving. No start operation is exposed in this bootstrap.
@MainActor
protocol ServerService: AnyObject {
    /// Must synchronously initiate cancellation of every owned network resource.
    /// Repeated calls must be safe, including before the first start.
    func stop()
}

/// Production bootstrap has no listener and never claims to serve content.
@MainActor
final class UnconfiguredServerService: ServerService {
    func stop() {}
}
