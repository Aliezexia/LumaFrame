import SwiftUI

/// Native Liquid Glass for controls; keep reading surfaces opaque and legible.
private struct MeterGlassSurface: ViewModifier {
    var radius: CGFloat
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || LF.testReduceTransparency }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(LF.surface, in: RoundedRectangle(cornerRadius: radius))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
        }
    }
}

private struct MeterGlassButton: ViewModifier {
    var prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || LF.testReduceTransparency }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

/// Adjacent native glass surfaces share one rendering and morphing container.
struct LFGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || LF.testReduceTransparency }

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

private struct MeterGlassIdentity: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || LF.testReduceTransparency }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || LF.testReduceMotion }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, !reduceMotion {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Use inside a Button/Menu label: compact glass, with a separate 44pt touch area.
    func lfGlassControl(radius: CGFloat = 18, interactive: Bool = true) -> some View {
        frame(minHeight: LF.chipHeight)
            .meterGlassSurface(radius: radius, interactive: interactive)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    func meterGlassSurface(radius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(MeterGlassSurface(radius: radius, interactive: interactive))
    }
    func meterGlassButton(prominent: Bool = false) -> some View { modifier(MeterGlassButton(prominent: prominent)) }
    func meterGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(MeterGlassIdentity(id: id, namespace: namespace))
    }
}
