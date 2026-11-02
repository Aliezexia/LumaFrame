import Foundation

public enum ExposureMode: String, CaseIterable, Codable, Sendable {
    case manual = "M"
    case aperturePriority = "A"
    case shutterPriority = "S"

    public var title: String {
        switch self {
        case .manual: return "手动"
        case .aperturePriority: return "光圈优先"
        case .shutterPriority: return "快门优先"
        }
    }
}

public enum FilmKind: String, CaseIterable, Codable, Sendable {
    case negative
    case slide
    case blackAndWhite

    public var title: String {
        switch self {
        case .negative: return "彩色负片"
        case .slide: return "反转片"
        case .blackAndWhite: return "黑白负片"
        }
    }
}

public struct ExposureSetting: Equatable, Codable, Sendable {
    public var iso: Double
    public var aperture: Double
    public var shutterSeconds: Double

    public init(iso: Double = 400, aperture: Double = 5.6, shutterSeconds: Double = 1.0 / 125) {
        self.iso = iso
        self.aperture = aperture
        self.shutterSeconds = shutterSeconds
    }
}

public struct ExposureSolution: Equatable, Sendable {
    public let setting: ExposureSetting
    /// Actual exposure offset minus requested compensation. Positive means brighter than the target.
    public let residualEV: Double
    /// True when an automatic parameter would exceed its supported range, or input is invalid.
    public let isLimited: Bool

    public init(setting: ExposureSetting, residualEV: Double, isLimited: Bool) {
        self.setting = setting
        self.residualEV = residualEV
        self.isLimited = isLimited
    }
}

public enum ExposureRisk: String, Codable, Sendable {
    case balanced
    case brighter
    case darker
    case highlights
    case shadows

    public var title: String {
        switch self {
        case .balanced: return "接近测光基准"
        case .brighter: return "画面更亮"
        case .darker: return "画面更暗"
        case .highlights: return "高光风险"
        case .shadows: return "暗部风险"
        }
    }

    public var isSevere: Bool {
        self == .highlights || self == .shadows
    }
}

/// Exposure math only. Camera metering quality, scene contrast and film latitude
/// cannot be inferred from these values.
public enum ExposureEngine {
    /// Conventional nominal 1/3-stop values; slight rounding differences are intentional.
    public static let isoStops: [Double] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320,
        400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200
    ]

    public static let apertureStops: [Double] = [
        1, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8,
        3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10,
        11, 13, 14, 16, 18, 20, 22
    ]

    public static let shutterStops: [Double] = [
        1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000,
        1.0 / 3200, 1.0 / 2500, 1.0 / 2000, 1.0 / 1600,
        1.0 / 1250, 1.0 / 1000, 1.0 / 800, 1.0 / 640,
        1.0 / 500, 1.0 / 400, 1.0 / 320, 1.0 / 250,
        1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 100,
        1.0 / 80, 1.0 / 60, 1.0 / 50, 1.0 / 40,
        1.0 / 30, 1.0 / 25, 1.0 / 20, 1.0 / 15,
        1.0 / 13, 1.0 / 10, 1.0 / 8, 1.0 / 6,
        1.0 / 5, 1.0 / 4, 0.3, 0.4, 0.5, 0.6,
        0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4
    ]

    /// EV100 = log2(N²/t) − log2(ISO/100) + calibration.
    /// Log-domain arithmetic avoids overflowing N² or ISO/100.
    public static func ev100(
        aperture: Double,
        shutterSeconds: Double,
        iso: Double,
        calibrationEV: Double = 0
    ) -> Double? {
        guard positiveFinite(aperture), positiveFinite(shutterSeconds),
              positiveFinite(iso), calibrationEV.isFinite else { return nil }
        let value = 2 * log2(aperture) - log2(shutterSeconds)
            - (log2(iso) - log2(100.0)) + calibrationEV
        return value.isFinite ? value : nil
    }

    /// Positive compensation requests more exposure and therefore lowers the target EV.
    /// Invalid inputs return NaN; callers must keep an invalid reading out of the UI.
    public static func targetEV(
        ev100: Double,
        iso: Double,
        compensationEV: Double = 0
    ) -> Double {
        guard ev100.isFinite, positiveFinite(iso), compensationEV.isFinite else { return .nan }
        return ev100 + (log2(iso) - log2(100.0)) - compensationEV
    }

    /// Positive delta means the current setting gives more exposure than the measured baseline.
    /// The baseline must already include calibration. No film-specific exposure bias is applied.
    public static func deltaEV(ev100: Double, setting: ExposureSetting) -> Double {
        guard let settingEV100 = self.ev100(
            aperture: setting.aperture,
            shutterSeconds: setting.shutterSeconds,
            iso: setting.iso
        ), ev100.isFinite else { return .nan }
        return ev100 - settingEV100
    }

    /// M preserves all parameters. A changes only time. S changes only aperture.
    /// Automatic values use the nearest nominal stop in log space, then clamp to the supported range.
    public static func solve(
        mode: ExposureMode,
        setting: ExposureSetting,
        ev100: Double,
        compensationEV: Double = 0
    ) -> ExposureSolution {
        guard positiveFinite(setting.iso), positiveFinite(setting.aperture),
              positiveFinite(setting.shutterSeconds), ev100.isFinite,
              compensationEV.isFinite else {
            return ExposureSolution(setting: setting, residualEV: .nan, isLimited: true)
        }
        let target = targetEV(ev100: ev100, iso: setting.iso, compensationEV: compensationEV)
        guard target.isFinite else {
            return ExposureSolution(setting: setting, residualEV: .nan, isLimited: true)
        }

        var result = setting
        var limited = false
        switch mode {
        case .manual:
            break
        case .aperturePriority:
            let desiredLogTime = 2 * log2(setting.aperture) - target
            let selected = nearestStop(logValue: desiredLogTime, stops: shutterStops)
            result.shutterSeconds = selected.value
            limited = selected.limited
        case .shutterPriority:
            let desiredLogAperture = (log2(setting.shutterSeconds) + target) / 2
            let selected = nearestStop(logValue: desiredLogAperture, stops: apertureStops)
            result.aperture = selected.value
            limited = selected.limited
        }
        return ExposureSolution(
            setting: result,
            residualEV: deltaEV(ev100: ev100, setting: result) - compensationEV,
            isLimited: limited
        )
    }

    /// Heuristic warnings relative to a measured baseline, not measured film latitude.
    /// Use only with a valid finite delta. NaN falls back to balanced because this fixed
    /// presentation enum has no invalid-reading case; the caller must show its meter error state.
    public static func risk(deltaEV: Double, film: FilmKind) -> ExposureRisk {
        let shadowThreshold = film == .slide ? -1.0 : -2.0
        let highlightThreshold = film == .slide ? 1.0 : 3.0
        if deltaEV <= shadowThreshold { return .shadows }
        if deltaEV >= highlightThreshold { return .highlights }
        if abs(deltaEV) < 0.34 { return .balanced }
        return deltaEV > 0 ? .brighter : (deltaEV < 0 ? .darker : .balanced)
    }

    public static func shutterLabel(_ seconds: Double) -> String {
        guard positiveFinite(seconds) else { return "—" }
        if seconds >= 0.3 {
            if seconds.rounded() == seconds {
                return String(format: "%.0f s", seconds)
            }
            return String(format: "%.1f s", seconds)
        }
        let denominator = (1 / seconds).rounded()
        guard denominator.isFinite else { return "—" }
        return String(format: "1/%.0f", denominator)
    }

    private static func positiveFinite(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    private static func nearestStop(logValue: Double, stops: [Double]) -> (value: Double, limited: Bool) {
        // The tables are nonempty and strictly increasing.
        let selected = stops.min {
            abs(log2($0) - logValue) < abs(log2($1) - logValue)
        }!
        let lower = log2(stops[0])
        let upper = log2(stops[stops.count - 1])
        return (selected, logValue < lower - 1e-10 || logValue > upper + 1e-10)
    }
}
