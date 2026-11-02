import Foundation

public enum MeteringMode: String, Codable, CaseIterable, Sendable {
    case matrix
    case centerWeighted
    case spot

    public var title: String {
        switch self {
        case .matrix: return "矩阵测光"
        case .centerWeighted: return "中央重点"
        case .spot: return "点测光"
        }
    }

    public var shortTitle: String {
        switch self {
        case .matrix: return "矩阵"
        case .centerWeighted: return "中央"
        case .spot: return "点测"
        }
    }

    public var systemImage: String {
        switch self {
        case .matrix: return "square.grid.3x3"
        case .centerWeighted: return "circle.dotted.circle"
        case .spot: return "scope"
        }
    }
}

/// A point in the displayed, cropped frame, with the origin at its top-left corner.
/// Coordinates are clamped to 0...1; a nonfinite component becomes 0.5.
public struct MeteringPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0.5
        self.y = y.isFinite ? min(1, max(0, y)) : 0.5
    }

    public static let center = MeteringPoint(x: 0.5, y: 0.5)

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try values.decode(Double.self, forKey: .x),
                  y: try values.decode(Double.self, forKey: .y))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(x, forKey: .x)
        try values.encode(y, forKey: .y)
    }
}

/// Spatial weighting of an equal-area grid of linear luminance values.
/// This is an exposure correction, not an absolute light or camera calibration.
public enum SpatialMetering {
    /// Diameter of the spot circle as a fraction of the displayed frame's shorter side.
    public static let spotDiameterFraction = 0.16

    private static let minimumLinearLuminance = 0.000001

    /// Keeps the entire spot circle inside the displayed frame.
    /// Invalid or numerically unrepresentable aspect ratios return the center.
    public static func clampedPoint(_ point: MeteringPoint, aspectRatio: Double) -> MeteringPoint {
        guard validAspectRatio(aspectRatio) else { return .center }
        let radii = spotRadii(aspectRatio: aspectRatio)
        return MeteringPoint(x: min(1 - radii.x, max(radii.x, point.x)),
                             y: min(1 - radii.y, max(radii.y, point.y)))
    }

    /// Returns log2(weighted linear luminance / 0.18), in EV.
    ///
    /// `luminances` is a row-major grid in display orientation, after the same crop
    /// used by the viewfinder. Each cell represents the average of an equal-area
    /// region, with values in 0...1. `aspectRatio` is displayed width / height.
    /// Matrix uses all cells equally; center-weighted uses a smooth, radial Gaussian
    /// emphasis over a uniform base. Spot averages a circle by equal-area disk
    /// quadrature over the grid's piecewise-constant cells, so coarse grids remain
    /// defined even when the circle contains no cell center.
    ///
    /// Invalid dimensions, count, luminance or aspect ratio return nil. Values below
    /// 1e-6 are floored before taking the logarithm; completely dark input therefore
    /// remains finite, but is not evidence of a reliable physical measurement.
    public static func correction(
        luminances: [Double],
        columns: Int,
        rows: Int,
        mode: MeteringMode,
        point: MeteringPoint = .center,
        aspectRatio: Double
    ) -> Double? {
        guard columns > 0, rows > 0, validAspectRatio(aspectRatio) else { return nil }
        let count = columns.multipliedReportingOverflow(by: rows)
        guard !count.overflow, count.partialValue == luminances.count,
              luminances.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }

        let mean: Double
        switch mode {
        case .matrix:
            mean = luminances.reduce(0, +) / Double(luminances.count)
        case .centerWeighted:
            // Physical distances are expressed in units of the shorter frame side.
            let width = max(1, aspectRatio)
            let height = max(1, 1 / aspectRatio)
            let sigma = 0.25
            var weightedSum = 0.0
            var totalWeight = 0.0
            for row in 0..<rows {
                let y = (Double(row) + 0.5) / Double(rows)
                for column in 0..<columns {
                    let x = (Double(column) + 0.5) / Double(columns)
                    let distance = hypot((x - 0.5) * width, (y - 0.5) * height)
                    let weight = 1 + 4 * exp(-0.5 * pow(distance / sigma, 2))
                    weightedSum += luminances[row * columns + column] * weight
                    totalWeight += weight
                }
            }
            mean = weightedSum / totalWeight
        case .spot:
            let center = clampedPoint(point, aspectRatio: aspectRatio)
            let radii = spotRadii(aspectRatio: aspectRatio)
            // Eight equal-area annuli, each sampled at 32 equally spaced angles.
            // Half-angle offsets preserve symmetry about both axes.
            let rings = 8
            let angles = 32
            var sum = 0.0
            for ring in 0..<rings {
                let radius = sqrt((Double(ring) + 0.5) / Double(rings))
                for angle in 0..<angles {
                    let theta = (Double(angle) + 0.5) * 2 * Double.pi / Double(angles)
                    let x = center.x + radii.x * radius * cos(theta)
                    let y = center.y + radii.y * radius * sin(theta)
                    let column = min(columns - 1, max(0, Int(x * Double(columns))))
                    let row = min(rows - 1, max(0, Int(y * Double(rows))))
                    sum += luminances[row * columns + column]
                }
            }
            mean = sum / Double(rings * angles)
        }

        guard mean.isFinite else { return nil }
        return log2(max(minimumLinearLuminance, mean) / 0.18)
    }

    private static func validAspectRatio(_ aspectRatio: Double) -> Bool {
        aspectRatio.isFinite && aspectRatio > 0 && (1 / aspectRatio).isFinite
    }

    private static func spotRadii(aspectRatio: Double) -> (x: Double, y: Double) {
        let radius = spotDiameterFraction / 2
        return (radius / max(1, aspectRatio), radius / max(1, 1 / aspectRatio))
    }
}
