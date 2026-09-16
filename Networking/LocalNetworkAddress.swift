import Darwin
import Foundation

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

    private static func ipv4String(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var sinAddr = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
