import Foundation
import Observation

/// Advertises this server session over Bonjour/mDNS (`_http._tcp.`) so a
/// nearby device can discover it by name instead of needing the IP-based
/// endpoint the dashboard already shows. Wraps `NetService` rather than
/// setting `NWListener.service` on `ServerCore/HTTPServer.swift`'s own
/// listener: this only publishes a name+port record on the network, it
/// never touches the socket that actually serves requests, so a failure
/// here can never affect serving itself — only discoverability.
///
/// Requires `NSBonjourServices` (`_http._tcp.`) and
/// `NSLocalNetworkUsageDescription` in Info.plist; see `project.yml`.
@MainActor
@Observable
final class BonjourAdvertiser: NSObject {
    enum State: Equatable {
        case idle
        case publishing
        case published(name: String)
        case failed(String)
    }

    private static let serviceType = "_http._tcp."

    private(set) var state: State = .idle
    private var service: NetService?

    /// Starts (or restarts) advertising `name` on `port`. Any previous
    /// advertisement is stopped first — one advertisement per server
    /// session, matching `LiveServerService`'s one-listener-per-session
    /// lifecycle. `name` may be renamed by the system for uniqueness on the
    /// local network; the actual published name arrives via `.published`.
    func start(name: String, port: Int) {
        stop()
        let netService = NetService(domain: "local.", type: Self.serviceType, name: name, port: Int32(port))
        netService.delegate = self
        service = netService
        state = .publishing
        netService.publish()
    }

    /// Safe to call repeatedly, including before the first `start()`.
    func stop() {
        service?.delegate = nil
        service?.stop()
        service = nil
        if state != .idle { state = .idle }
    }
}

extension BonjourAdvertiser: NetServiceDelegate {
    // `NetService`/`[String: NSNumber]` aren't `Sendable`, so nothing derived
    // from `sender`/`errorDict` can be captured directly into the `Task`
    // below (a `@Sendable` closure) - each value needed is read out into a
    // plain `Sendable` local first. `ObjectIdentifier` stands in for
    // `sender` itself, so the hop can still recognize (and ignore) a
    // callback from an advertisement `start()`/`stop()` already replaced.
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        let identifier = ObjectIdentifier(sender)
        let name = sender.name
        Task { @MainActor [weak self] in
            guard let self, self.service.map(ObjectIdentifier.init) == identifier else { return }
            self.state = .published(name: name)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let identifier = ObjectIdentifier(sender)
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        Task { @MainActor [weak self] in
            guard let self, self.service.map(ObjectIdentifier.init) == identifier else { return }
            self.state = .failed("Bonjour advertisement failed (error \(code))")
        }
    }
}
