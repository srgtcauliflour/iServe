import UIKit
import XCTest
@testable import iServe

final class QRCodeViewTests: XCTestCase {
    func testGeneratesAnImageForATypicalEndpointURL() {
        let image = QRCodeView.image(for: "http://192.168.1.10:8080/")
        XCTAssertNotNil(image)
    }

    func testGeneratesAnImageForAnEmptyStringWithoutCrashing() {
        // CoreImage can encode an empty payload; this just proves it
        // doesn't crash or hang, not that the result is meaningful.
        _ = QRCodeView.image(for: "")
    }

    func testDifferentEndpointsProduceDifferentImageData() {
        let first = QRCodeView.image(for: "http://192.168.1.10:8080/")
        let second = QRCodeView.image(for: "http://192.168.1.11:9090/")
        XCTAssertNotEqual(first?.pngData(), second?.pngData())
    }
}
