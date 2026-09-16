import Darwin
import Foundation

/// One address `LocalNetworkAddress.allAddresses()` found on an active,
/// non-loopback interface — everything `preferredIPv4Address()` doesn't
/// surface: other Wi-Fi/Ethernet-family interfaces, IPv6, and interfaces
/// `preferredIPv4Address()` didn't prefer. Purely presentational, like the
/// rest of this module — see `docs/SECURITY.md`'s local/public distinction.
struct NetworkInterfaceAddress: Equatable, Identifiable, Sendable {
    enum Family: Equatable, Sendable {
        case ipv4
        case ipv6
    }

    let interfaceName: String
    let family: Family
    /// For a link-local IPv6 address (`fe80::/10`), this already includes
    /// the `%<interface>` zone id a client needs to actually route to it —
    /// see `ipv6String(from:interfaceName:)`.
    let address: String

    var id: String { "\(interfaceName)-\(family)-\(address)" }
}

/// Discovers this device's LAN-facing IPv4 address by walking active network
/// interfaces, so the dashboard can display an endpoint another device on the
/// same network can actually reach. A discovered address is informational, not
/// proof of reachability — see `docs/SECURITY.md`'s local/public distinction.
enum LocalNetworkAddress {
    /// Interface name prefixes considered LAN-reachable: Wi-Fi ("en0" on
    /// virtually every iPhone/iPad), other Ethernet-family adapters ("en1",
    /// "en2", ... — USB/Lightning Ethernet adapters enumerate this way), and
    /// Personal Hotspot host mode ("bridge100"). Cellular ("pdp_ip0") and
    /// loopback are deliberately not preferred: neither is a LAN another
    /// device on the same Wi-Fi/hotspot reaches the same way.
    private static let preferredPrefixes = ["en", "bridge"]

    /// Returns the first plausible LAN IPv4 address, preferring a known
    /// Wi-Fi/Ethernet/hotspot interface name, or `nil` if no active,
    /// non-loopback IPv4 interface is found at all.
    static func preferredIPv4Address() -> String? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddress = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var fallbackAddress: String?
        var preferredAddress: String?

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = pointer {
            pointer = current.pointee.ifa_next

            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let address = Self.ipv4String(from: addr) else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            if fallbackAddress == nil { fallbackAddress = address }
            if preferredAddress == nil, Self.preferredPrefixes.contains(where: { name.hasPrefix($0) }) {
                preferredAddress = address
            }
        }

        return preferredAddress ?? fallbackAddress
    }

    /// Every active, non-loopback address this device has — IPv4 and IPv6,
    /// across every interface, not just the one `preferredIPv4Address()`
    /// picks. `HTTPServer` binds to `.any` (every interface), so any of
    /// these reaches it on the same port the dashboard already shows.
    /// Sorted with `preferredIPv4Address()`'s same preferred-interface
    /// ordering first, so the list reads with the "main" addresses up top.
    static func allAddresses() -> [NetworkInterfaceAddress] {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddress = ifaddrPointer else { return [] }
        defer { freeifaddrs(ifaddrPointer) }

        var results: [NetworkInterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = pointer {
            pointer = current.pointee.ifa_next

            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)

            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                if let address = Self.ipv4String(from: addr) {
                    results.append(NetworkInterfaceAddress(interfaceName: name, family: .ipv4, address: address))
                }
            case AF_INET6:
                if let address = Self.ipv6String(from: addr, interfaceName: name) {
                    results.append(NetworkInterfaceAddress(interfaceName: name, family: .ipv6, address: address))
                }
            default:
                break
            }
        }

        return results.sorted { lhs, rhs in
            let lhsPreferred = Self.preferredPrefixes.contains { lhs.interfaceName.hasPrefix($0) }
            let rhsPreferred = Self.preferredPrefixes.contains { rhs.interfaceName.hasPrefix($0) }
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            if lhs.interfaceName != rhs.interfaceName { return lhs.interfaceName < rhs.interfaceName }
            if lhs.family != rhs.family { return lhs.family == .ipv4 }
            return lhs.address < rhs.address
        }
    }

    private static func ipv4String(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var sinAddr = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// A link-local IPv6 address (`fe80::/10` — what every interface has,
    /// with or without a router) is ambiguous without its zone: the same
    /// address can exist on several interfaces at once, so a client needs
    /// `%<interface>` appended to know which one to actually use.
    private static func ipv6String(from addr: UnsafeMutablePointer<sockaddr>, interfaceName: String) -> String? {
        var sin6Addr = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &sin6Addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        let address = String(cString: buffer)
        return address.hasPrefix("fe80") ? "\(address)%\(interfaceName)" : address
    }
}
