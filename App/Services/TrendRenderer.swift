import CoreImage
import UIKit

enum TrendRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A bounded brightness illustration on a frozen frame, never a film simulation.
    static func image(_ image: UIImage, deltaEV: Double) -> UIImage {
        guard deltaEV.isFinite, let input = CIImage(image: image) else { return image }
        let compensation = min(3, max(-3, deltaEV))
        let output = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: compensation])
        guard let cgImage = context.createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
