import SwiftUI

/// A native, snapping stop scale. Binding writes come only from deliberate input;
/// initial layout and programmatic repositioning never change the selected stop.
struct StopDial: View {
    let values: [String]
    @Binding var selection: Int
    let majorEvery: Int
    let spacing: CGFloat
    let enabled: Bool
    let accessibilityLabel: String
    let identifier: String
    let decreaseIdentifier: String
    let increaseIdentifier: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || LF.testReduceMotion }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 15
    @State private var position: Int?
    @State private var acceptingScroll = false
    @State private var dragging = false
    @State private var settleTask: Task<Void, Never>?
    @State private var feedback = 0

    init(values: [String], selection: Binding<Int>, majorEvery: Int = 3,
         spacing: CGFloat = 14, enabled: Bool = true, accessibilityLabel: String,
         identifier: String = "stopDial", decreaseIdentifier: String = "decreaseParameter",
         increaseIdentifier: String = "increaseParameter") {
        self.values = values
        self._selection = selection
        self.majorEvery = max(1, majorEvery)
        self.spacing = spacing.isFinite ? max(8, spacing) : 14
        self.enabled = enabled
        self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier
        self.decreaseIdentifier = decreaseIdentifier
        self.increaseIdentifier = increaseIdentifier
        self._position = State(initialValue: values.isEmpty ? nil : min(values.count - 1, max(0, selection.wrappedValue)))
    }

    private var currentIndex: Int? {
        values.isEmpty ? nil : min(values.count - 1, max(0, selection))
    }
    private var currentValue: String { currentIndex.map { values[$0] } ?? "—" }
    private var dialHeight: CGFloat { max(62, 43 + labelHeight) }
    private var tickSpacing: CGFloat { dynamicTypeSize.isAccessibilitySize ? max(spacing, 20) : spacing }
    private var secondaryInk: Color { colorScheme == .dark ? LF.inkSecondary : .secondary }

    var body: some View {
        ScrollViewReader { scrollProxy in
        HStack(spacing: 0) {
            stepButton(delta: -1, symbol: "chevron.left", identifier: decreaseIdentifier, proxy: scrollProxy)
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    ScrollView(.horizontal) {
                        // Only a few dozen stops: laying them all out makes every
                        // target's geometry available for the very first scrollTo.
                        HStack(spacing: 0) {
                            ForEach(values.indices, id: \.self) { index in
                                tick(index)
                                    .frame(width: tickSpacing, height: dialHeight, alignment: .top)
                                    .id(index)
                            }
                        }
                        .scrollTargetLayout()
                        .background {
                            GeometryReader { contentGeometry in
                                Color.clear.preference(key: StopDialContentWidth.self,
                                                       value: contentGeometry.size.width)
                            }
                        }
                    }
                    .contentMargins(.horizontal, max(0, (geometry.size.width - tickSpacing) / 2), for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: scrollPosition, anchor: .center)
                    .scrollDisabled(!enabled || values.count < 2)
                    .modifier(StopDialScrollActivity(action: scrollActivityChanged))
                    .onPreferenceChange(StopDialContentWidth.self) { width in
                        guard width > 0 else { return }
                        synchronizePosition(using: scrollProxy)
                    }
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                        }
                    }
                    .opacity(enabled ? 1 : 0.35)
                    .simultaneousGesture(DragGesture(minimumDistance: 3)
                        .onChanged { _ in
                            if #available(iOS 18.0, *) { return }
                            guard enabled else { return }
                            settleTask?.cancel()
                            acceptingScroll = true
                            dragging = true
                        }
                        .onEnded { _ in
                            if #available(iOS 18.0, *) { return }
                            dragging = false
                            finishScrollingWhenSettled()
                        })

                    Capsule()
                        .fill(LF.amber)
                        .frame(width: 2, height: 25)
                        .opacity(enabled ? 1 : 0.35)
                        .allowsHitTesting(false)

                    if !enabled {
                        Text("自动计算")
                            .font(.caption)
                            .foregroundStyle(secondaryInk)
                            .padding(.top, 31)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(enabled ? currentValue : "\(currentValue)，自动计算")
                .accessibilityHint(enabled ? "上下轻扫调节一档" : "此参数由当前曝光模式自动计算")
                .accessibilityIdentifier(identifier)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(by: 1, proxy: scrollProxy)
                    case .decrement: step(by: -1, proxy: scrollProxy)
                    @unknown default: break
                    }
                }
                .onAppear { synchronizePosition(using: scrollProxy) }
                .onChange(of: geometry.size.width) { _, _ in synchronizePosition(using: scrollProxy) }
            }
            stepButton(delta: 1, symbol: "chevron.right", identifier: increaseIdentifier, proxy: scrollProxy)
        }
        .frame(height: dialHeight)
        .sensoryFeedback(.selection, trigger: feedback)
        .onChange(of: selection) { _, _ in
            // Scroll-originated writes already set position; only outside changes
            // need to stop the current scroll transaction and move the dial.
            if position != currentIndex { synchronizePosition(using: scrollProxy) }
        }
        .onChange(of: values) { _, _ in synchronizePosition(using: scrollProxy) }
        .onChange(of: enabled) { _, _ in synchronizePosition(using: scrollProxy) }
        .onChange(of: dynamicTypeSize) { _, _ in synchronizePosition(using: scrollProxy) }
        .onDisappear { settleTask?.cancel() }
        }
    }

    private func tick(_ index: Int) -> some View {
        let major = index.isMultiple(of: majorEvery)
        return Rectangle()
            .fill(major ? secondaryInk : secondaryInk.opacity(0.5))
            .frame(width: 1, height: major ? 22 : 12)
            .frame(height: 25, alignment: .top)
            .overlay(alignment: .top) {
                if major && enabled {
                    Text(values[index])
                        .font(.caption2.monospacedDigit())
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: max(tickSpacing, tickSpacing * CGFloat(majorEvery) - 4), height: labelHeight)
                        .offset(y: 31)
                }
            }
            .accessibilityHidden(true)
    }

    private func stepButton(delta: Int, symbol: String, identifier: String, proxy: ScrollViewProxy) -> some View {
        let available = currentIndex.map { values.indices.contains($0 + delta) } ?? false
        return Button { step(by: delta, proxy: proxy) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled && available ? secondaryInk : secondaryInk.opacity(0.25))
                .frame(width: 44, height: max(44, dialHeight))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !available)
        .accessibilityLabel(delta < 0 ? "上一档\(accessibilityLabel)" : "下一档\(accessibilityLabel)")
        .accessibilityIdentifier(identifier)
    }

    private var scrollPosition: Binding<Int?> {
        Binding(get: { position }, set: { next in
            guard enabled, acceptingScroll, let next, values.indices.contains(next) else { return }
            position = next
            if selection != next {
                selection = next
                feedback += 1
            }
            if !dragging { finishScrollingWhenSettled() }
        })
    }

    private func step(by delta: Int, proxy: ScrollViewProxy) {
        guard enabled, let currentIndex else { return }
        let next = min(values.count - 1, max(0, currentIndex + delta))
        guard next != currentIndex else { return }
        selection = next
        feedback += 1
        synchronizePosition(using: proxy, animated: true)
    }

    private func synchronizePosition(using proxy: ScrollViewProxy, animated: Bool = false) {
        settleTask?.cancel()
        acceptingScroll = false
        dragging = false
        guard let target = currentIndex else { position = nil; return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.16)) {
                position = target
                proxy.scrollTo(target, anchor: .center)
            }
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = target
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private func finishScrollingWhenSettled() {
        // iOS 18+ reports the actual end of deceleration, so no timer is needed.
        if #available(iOS 18.0, *) { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            acceptingScroll = false
        }
    }

    private func scrollActivityChanged(userDriven: Bool, idle: Bool) {
        settleTask?.cancel()
        if idle {
            // Allow the final position write from this SwiftUI update to settle.
            settleTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                acceptingScroll = false
            }
        } else {
            acceptingScroll = enabled && userDriven
        }
    }
}

private struct StopDialContentWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct StopDialScrollActivity: ViewModifier {
    let action: (_ userDriven: Bool, _ idle: Bool) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: action(true, false)
                case .animating: action(false, false)
                case .idle: action(false, true)
                @unknown default: action(false, false)
                }
            }
        } else {
            content
        }
    }
}
