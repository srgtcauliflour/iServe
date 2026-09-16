import XCTest
@testable import iServe

final class LocalNetworkAddressTests: XCTestCase {
    func testPreferredIPv4AddressDoesNotCrashAndIfPresentLooksLikeAnIPv4Address() {
        let address = LocalNetworkAddress.preferredIPv4Address()
        // No active non-loopback interface is a legitimate outcome in some
        // sandboxed CI environments; only validate the shape when present.
        guard let address else { return }
        let components = address.split(separator: ".")
        XCTAssertEqual(components.count, 4)
        for component in components {
            XCTAssertNotNil(UInt8(component), "\(component) is not a valid IPv4 octet")
        }
    }

    func testAllAddressesDoesNotCrashAndNeverIncludesLoopback() {
        let addresses = LocalNetworkAddress.allAddresses()
        // Same CI-sandbox caveat as above: an empty result is legitimate.
        for entry in addresses {
            XCTAssertFalse(entry.interfaceName.isEmpty)
            XCTAssertNotEqual(entry.address, "127.0.0.1")
            XCTAssertNotEqual(entry.address, "::1")
            switch entry.family {
            case .ipv4:
                XCTAssertEqual(entry.address.split(separator: ".").count, 4)
            case .ipv6:
                XCTAssertTrue(entry.address.contains(":"))
            }
        }
    }

    func testAllAddressesIncludesPreferredIPv4AddressWhenOneExists() {
        // Both walk the same live interface list, so whatever
        // preferredIPv4Address() picked must also appear in the full list -
        // proves allAddresses() isn't silently dropping the interface the
        // rest of the app already relies on for the primary endpoint.
        guard let preferred = LocalNetworkAddress.preferredIPv4Address() else { return }
        let addresses = LocalNetworkAddress.allAddresses()
        XCTAssertTrue(addresses.contains { $0.family == .ipv4 && $0.address == preferred })
    }
}
