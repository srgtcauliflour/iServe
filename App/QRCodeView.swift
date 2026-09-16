import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Renders `string` as a scannable QR code, generated on-device via
/// CoreImage — no network access or third-party dependency. Meant for the
/// dashboard's connection endpoint, so another device can scan instead of
/// typing the address by hand.
struct QRCodeView: View {
    let string: String

    var body: some View {
        if let image = Self.image(for: string) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .accessibilityLabel("QR code for \(string)")
        } else {
            ContentUnavailableView("QR Code Unavailable", systemImage: "qrcode")
        }
    }

    /// `nil` only if CoreImage's generator itself fails (in practice, only
    /// for input too long to encode as a QR symbol). Not private so
    /// `QRCodeViewTests` can exercise the encoding itself, not just that
    /// the view builds.
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        // Generated at ~1pt per module; scale up so it renders crisply
        // instead of blurring a tiny bitmap up to view size.
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
