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
}
