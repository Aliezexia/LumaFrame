import SwiftUI

/// Shared visual language for the dark meter and the system-themed sheets.
enum LF {
    static let canvas = Color.black
    static let surface = Color(white: 0.11)
    static let ink = Color.white
    static let inkSecondary = Color.white.opacity(0.62)
    static let inkTertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.12)
    static let amber = Color(red: 1.00, green: 0.76, blue: 0.24)
    static let warning = Color.orange
    static let critical = Color.red

    static func hero(_ size: CGFloat = 42) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static let label = Font.caption.weight(.medium)
    static let chip = Font.footnote.weight(.semibold)
    static let mono = Font.caption.monospaced()

    static let gutter: CGFloat = 16
    static let chipHeight: CGFloat = 34
    static let shutter: CGFloat = 68

    // Deterministic screenshot fixtures never change production accessibility settings.
    static var testReduceMotion: Bool { testFlag("-ui-testing-reduce-motion") }
    static var testReduceTransparency: Bool { testFlag("-ui-testing-reduce-transparency") }
    private static func testFlag(_ flag: String) -> Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing") && arguments.contains(flag)
        #else
        return false
        #endif
    }
}

private struct LFNumericText<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || LF.testReduceMotion }

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
    }
}

extension View {
    /// Animate a changing number while preserving equal digit widths.
    func lfNumericText<Value: Equatable>(_ value: Value) -> some View {
        modifier(LFNumericText(value: value))
    }
}
