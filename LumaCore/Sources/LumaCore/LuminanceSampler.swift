import Foundation

/// Integer pixel bounds, with the origin at the image's top-left corner.
public struct PixelCrop: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Area-averages an opaque, sRGB BGRA frame without copying its pixel storage.
/// The returned row-major grid is in the input's orientation. Alpha is ignored:
/// camera frames are opaque, and this is not an arbitrary-image compositing API.
public enum LuminanceSampler {
    private static let linearChannel: [Double] = (0...255).map {
        let value = Double($0) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Each output cell represents an equal-area rectangle of linear luminance.
    /// Boundary pixels contribute in proportion to coverage, including when the
    /// crop dimensions are not divisible by the grid dimensions. Every visible
    /// pixel contributes; padding and pixels outside the crop do not.
    ///
    /// Invalid bounds, a short buffer, overflow, or a grid finer than the crop
    /// return nil. The caller must keep the input buffer valid for this call.
    public static func grid(
        bgra: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        crop: PixelCrop,
        columns: Int,
        rows: Int
    ) -> [Double]? {
        guard width > 0, height > 0, bytesPerRow > 0,
              columns > 0, rows > 0,
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.x <= width, crop.y <= height,
              crop.width <= width - crop.x, crop.height <= height - crop.y,
              columns <= crop.width, rows <= crop.height,
              bgra.baseAddress != nil else { return nil }

        let rowBytes = width.multipliedReportingOverflow(by: 4)
        let lastRow = (height - 1).multipliedReportingOverflow(by: bytesPerRow)
        let count = columns.multipliedReportingOverflow(by: rows)
        guard !rowBytes.overflow, rowBytes.partialValue <= bytesPerRow,
              !lastRow.overflow, !count.overflow else { return nil }
        let requiredBytes = lastRow.partialValue.addingReportingOverflow(rowBytes.partialValue)
        guard !requiredBytes.overflow, requiredBytes.partialValue <= bgra.count else { return nil }

        // Precompute horizontal coverage once; reuse it across every image row.
        let horizontal = spans(origin: crop.x, length: crop.width, divisions: columns)
        let vertical = spans(origin: crop.y, length: crop.height, divisions: rows)
        let cellArea = Double(crop.width) / Double(columns) * Double(crop.height) / Double(rows)
        var result = [Double](repeating: 0, count: count.partialValue)
        for row in 0..<rows {
            let ySpan = vertical[row]
            for column in 0..<columns {
                let xSpan = horizontal[column]
                var sum = 0.0
                for (yIndex, yWeight) in ySpan.weights.enumerated() {
                    let rowOffset = (ySpan.first + yIndex) * bytesPerRow
                    var horizontalSum = 0.0
                    for (xIndex, xWeight) in xSpan.weights.enumerated() {
                        let offset = rowOffset + (xSpan.first + xIndex) * 4
                        let blue = linearChannel[Int(bgra[offset])]
                        let green = linearChannel[Int(bgra[offset + 1])]
                        let red = linearChannel[Int(bgra[offset + 2])]
                        horizontalSum += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * xWeight
                    }
                    sum += horizontalSum * yWeight
                }
                // Clamp only floating-point rounding at the mathematical limits.
                result[row * columns + column] = min(1, max(0, sum / cellArea))
            }
        }
        return result
    }

    private struct Span {
        let first: Int
        let weights: [Double]
    }

    private static func spans(origin: Int, length: Int, divisions: Int) -> [Span] {
        (0..<divisions).map { index in
            let lower = Double(index) * Double(length) / Double(divisions)
            let upper = Double(index + 1) * Double(length) / Double(divisions)
            let first = Int(lower.rounded(.down))
            let last = min(length, Int(upper.rounded(.up)))
            let weights = (first..<last).map { pixel in
                max(0, min(upper, Double(pixel + 1)) - max(lower, Double(pixel)))
            }
            return Span(first: origin + first, weights: weights)
        }
    }
}
