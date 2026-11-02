import SwiftUI
import UIKit

@main
struct LumaFrameApp: App {
    @StateObject private var model = MeterModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MeterView(model: model, camera: model.camera)
                .task { await model.resume() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.resume() } }
                    else if phase == .background { model.background() }
                }
        }
    }
}

struct MeterView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var camera: CameraService
    @State private var showFilm = false
    @State private var showSettings = false
    @State private var showExposure = false
    @State private var showRisk = false
    @State private var sheetPresentationActive = false
    @State private var editingCompensation = false
    @State private var lensToast: String?
    @State private var lensToastTask: Task<Void, Never>?
    @State private var recordParameters: [RecordParameter] = []
    @State private var autoTap = 0
    @State private var pointFeedback = 0
    @State private var measureSuccess = 0
    @State private var measureFailure = 0
    @State private var failureOffset: CGFloat = 0
    @Namespace private var glassNamespace
    @Namespace private var lensNamespace
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || LF.testReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            let available = geometry.size.height + top
            let compact = geometry.size.width < 390 || available < 740
            let height = typeSize.isAccessibilitySize ? 260 : min(geometry.size.width * 4 / 3, max(260, available - (compact ? 328 : 344)))
            VStack(spacing: 0) {
                viewfinder(height: height, topInset: top)
                statusRow.padding(.horizontal, LF.gutter).padding(.top, 4)
                ScrollView(.vertical) {
                    instrumentPanel(compact: compact)
                        .padding(.horizontal, LF.gutter).padding(.bottom, 16)
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("meterScrollView")
                actions(compact: compact)
            }
            .frame(width: geometry.size.width, height: available)
            .offset(y: -top)
            .environment(\.colorScheme, .dark)
        }
        .background(LF.canvas.ignoresSafeArea())
        .foregroundStyle(LF.ink).tint(LF.amber)
        .preferredColorScheme(hasSheet ? sheetColorScheme : .dark)
        .sheet(isPresented: $showFilm, onDismiss: sheetDidDismiss) { FilmSheet(model: model) }
        .sheet(isPresented: $showSettings, onDismiss: sheetDidDismiss) { SettingsSheet(model: model) }
        .sheet(isPresented: $showExposure, onDismiss: sheetDidDismiss) { ExposureAdjustmentSheet(model: model) }
        .sheet(item: $model.record, onDismiss: sheetDidDismiss) { draft in
            RecordSheet(model: model, draft: draft, parameters: recordParameters)
        }
        .onChange(of: hasSheet) { _, presented in
            if presented { sheetPresentationActive = true }
        }
        .onChange(of: camera.status) { _, status in
            guard !model.isDemo else { return }
            switch status {
            case .denied, .unavailable, .failed: model.invalidateReading()
            default: break
            }
        }
        .onChange(of: camera.zoom) { _, zoom in if !model.isDemo { model.zoom = zoom } }
        .onChange(of: model.mode) { _, _ in editingCompensation = false }
        .onChange(of: model.reading != nil) { _, locked in if locked { measureSuccess += 1 } }
        .onChange(of: model.message) { _, message in
            guard message != nil else { return }
            measureFailure += 1
            guard !reduceMotion else { return }
            Task { @MainActor in
                for offset: CGFloat in [-5, 5, -3, 0] {
                    withAnimation(.easeInOut(duration: 0.07)) { failureOffset = offset }
                    try? await Task.sleep(for: .milliseconds(70))
                }
            }
        }
        .sensoryFeedback(.success, trigger: measureSuccess)
        .sensoryFeedback(.warning, trigger: measureFailure)
        .sensoryFeedback(.impact(weight: .light), trigger: autoTap)
        .sensoryFeedback(.selection, trigger: pointFeedback)
        .sensoryFeedback(.selection, trigger: model.meteringMode)
        .sensoryFeedback(.selection, trigger: model.currentLensID)
        .onDisappear { lensToastTask?.cancel() }
        .alert("暂时无法测光", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private func viewfinder(height: CGFloat, topInset: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack {
                if hasFrame {
                    // Keep the gesture host stable when moving a point clears the frozen image.
                    ZStack { cameraImage }
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { event in movePoint(event.location, in: proxy.size) }
                            .onEnded { event in
                                guard model.meteringMode == .spot, !model.isBusy else { return }
                                movePoint(event.location, in: proxy.size)
                                pointFeedback += 1
                            })
                    if model.showGrid {
                        GridOverlay().stroke(.white.opacity(0.18), lineWidth: 0.6)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    meteringReticle(size: proxy.size)
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                           .init(color: .clear, location: 0.3),
                                           .init(color: .clear, location: 0.65),
                                           .init(color: .black.opacity(0.45), location: 1)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    if model.reading != nil {
                        Rectangle().strokeBorder(LF.amber, lineWidth: 2).allowsHitTesting(false)
                            .padding(.top, topInset + 2).padding(.horizontal, 2)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                } else {
                    LF.surface
                    ScrollView {
                        cameraPlaceholder.padding(.bottom, 12)
                    }.padding(.top, topInset + 60).accessibilityIdentifier("cameraHelpScrollView")
                }
                VStack(spacing: 0) {
                    topControls.padding(.top, topInset + 8)
                    Spacer(minLength: 8)
                    if hasFrame { lowerViewfinderControls.dynamicTypeSize(...DynamicTypeSize.large) }
                }.padding(.horizontal, LF.gutter).padding(.bottom, 10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.reading != nil)
            .accessibilityElement(children: .contain).accessibilityIdentifier("viewfinder")
            .onAppear { model.updateViewfinderAspect(proxy.size.width / max(1, proxy.size.height)) }
            .onChange(of: proxy.size) { _, size in model.updateViewfinderAspect(size.width / max(1, size.height)) }
        }
        .frame(height: height)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private var cameraImage: some View {
        if let image = model.trendImage { Image(uiImage: image).resizable().scaledToFill() }
        else if model.isDemo { Image(uiImage: model.demoPreview).resizable().scaledToFill() }
        else { CameraPreview(session: camera.session) }
    }

    @ViewBuilder private func meteringReticle(size: CGSize) -> some View {
        if model.meteringMode == .spot {
            let diameter = min(size.width, size.height) * SpatialMetering.spotDiameterFraction
            Circle().stroke(LF.amber, lineWidth: 1.5)
                .background(Circle().fill(.black.opacity(0.06)))
                .overlay { Circle().fill(LF.amber).frame(width: 4, height: 4) }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: size.width * model.meteringPoint.x, y: size.height * model.meteringPoint.y)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                .allowsHitTesting(false).accessibilityHidden(true)
        } else if model.meteringMode == .centerWeighted {
            Circle().stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .frame(width: min(size.width, size.height) * 0.55)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func movePoint(_ location: CGPoint, in size: CGSize) {
        guard model.meteringMode == .spot, !model.isBusy else { return }
        model.setMeteringPoint(MeteringPoint(x: location.x / max(1, size.width), y: location.y / max(1, size.height)))
    }

    private var topControls: some View {
        LFGlassGroup {
            HStack {
                Button { showFilm = true } label: {
                    Label("\(filmLabel) · \(Int(model.setting.iso))", systemImage: "film")
                        .font(LF.chip).lfNumericText(model.setting.iso).padding(.horizontal, 12).lfGlassControl()
                }.buttonStyle(.plain)
                    .accessibilityLabel("胶卷设置，\(model.film.title)，ISO \(Int(model.setting.iso))")
                    .accessibilityIdentifier("filmButton")
                Spacer(minLength: 8)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 34)
                        .lfGlassControl(radius: 17).frame(width: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("设置").accessibilityIdentifier("settingsButton")
            }
        }
    }

    private var lowerViewfinderControls: some View {
        VStack(spacing: 6) {
            LFGlassGroup {
                HStack(spacing: 8) {
                    meteringMenu
                    Spacer(minLength: 0)
                    if model.isDemo {
                        Text("DEMO").font(.system(size: 9, weight: .bold)).tracking(0.8)
                            .padding(.horizontal, 7).frame(height: 22)
                            .meterGlassSurface(radius: 11)
                            .overlay(Capsule().stroke(LF.amber.opacity(0.7), lineWidth: 0.7))
                            .accessibilityLabel("演示场景，非实测").accessibilityIdentifier("demoBadge")
                    }
                    if model.reading != nil {
                        Label("AE-L", systemImage: "lock.fill").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 7).frame(height: 22).foregroundStyle(LF.amber)
                            .background(.black.opacity(0.16), in: Capsule())
                            .overlay(Capsule().stroke(LF.amber.opacity(0.7), lineWidth: 0.7))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("AE-L，读数已锁定")
                            .accessibilityIdentifier("aeLockStatus")
                    }
                }
            }
            lensPicker
        }
    }

    private var meteringMenu: some View {
        Menu {
            Picker("测光方式", selection: Binding(get: { model.meteringMode }, set: { value in
                withAnimation(reduceMotion ? nil : .spring(duration: 0.22)) { model.selectMeteringMode(value) }
            })) {
                ForEach(MeteringMode.allCases, id: \.self) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                        .accessibilityIdentifier("metering_\(item.rawValue)")
                }
            }
            if model.meteringMode == .spot { Section("测光点位置") { spotPositionOptions } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.meteringMode.systemImage)
                Text(model.meteringMode.shortTitle)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(LF.chip).padding(.horizontal, 10).lfGlassControl()
        }.disabled(model.isBusy)
            .accessibilityLabel("测光方式，\(model.meteringMode.title)")
            .accessibilityHint("矩阵、中央重点或点测光；独立于曝光模式")
            .accessibilityIdentifier("meteringMenu")
    }

    private var lensPicker: some View {
        HStack(spacing: 2) {
            ForEach(model.lensOptions) { lens in
                Button {
                    Task {
                        await model.selectLens(lens)
                        guard model.currentLensID == lens.id else { return }
                        lensToastTask?.cancel()
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { lensToast = lens.detail }
                        lensToastTask = Task { @MainActor in
                            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { lensToast = nil }
                        }
                    }
                } label: {
                    Text(lens.title).font(LF.chip).monospacedDigit().frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        .foregroundStyle(model.currentLensID == lens.id ? LF.amber : LF.ink)
                        .background {
                            if model.currentLensID == lens.id {
                                Circle().fill(.white.opacity(0.13)).frame(width: 28, height: 28)
                                    .matchedGeometryEffect(id: "selectedLens", in: lensNamespace)
                            }
                        }
                }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityLabel("\(lens.title)，\(lens.detail)")
                    .accessibilityAddTraits(model.currentLensID == lens.id ? .isSelected : [])
                    .accessibilityIdentifier("lens_\(lens.id)")
            }
        }.padding(.horizontal, 3)
            .background { Color.clear.frame(height: LF.chipHeight).meterGlassSurface(radius: 18).allowsHitTesting(false) }
            .animation(reduceMotion ? nil : .spring(duration: 0.22), value: model.currentLensID)
            .overlay(alignment: .top) {
                if let lensToast {
                    Text(lensToast).font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.8), in: Capsule()).fixedSize()
                        .offset(y: -35).allowsHitTesting(false).accessibilityIdentifier("lensDetail")
                }
            }
    }

    private func instrumentPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 2 : 4) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                parameterHero(.aperture, compact: compact)
                parameterHero(.shutter, compact: compact)
            }
            dial(compact: compact).padding(.top, 6)
            secondaryControls
        }.padding(.bottom, 2)
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            if let reading = model.reading {
                Text(String(format: "EV %.1f", reading.ev100)).font(LF.mono).foregroundStyle(LF.inkSecondary)
                    .lfNumericText(reading.ev100).accessibilityIdentifier("viewfinderReading")
                ExposureOffsetScale(delta: model.delta ?? 0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("曝光偏移")
                    .accessibilityValue(String(format: "%+.1f EV", model.delta ?? 0))
                    .accessibilityIdentifier("deltaValue")
                if model.isLimited || model.risk?.isSevere == true {
                    Button { showRisk = true } label: {
                        HStack(spacing: 4) {
                            Circle().fill(model.isLimited ? LF.warning : LF.critical).frame(width: 5, height: 5)
                            Text(model.isLimited ? "档位边界" : (model.risk == .highlights ? "高光风险" : "暗部风险"))
                                .font(.caption2)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("exposureRisk")
                        .popover(isPresented: $showRisk) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(model.isLimited ? "已到档位边界" : (model.risk?.title ?? "曝光提醒")).font(.headline)
                                Text(model.isLimited ? "当前参数已超出可用档位，请调整光圈、快门或 ISO 后查看曝光偏移。" : "当前参数与测光基准偏离较大。提醒基于胶片类型与整体曝光偏移，不代表局部高光或暗部检测。")
                                Button("知道了") { showRisk = false }.frame(minHeight: 44).contentShape(Rectangle())
                            }.padding(20).frame(idealWidth: 300).presentationCompactAdaptation(.popover)
                        }
                }
            } else {
                Text("对准主体，按下测光").font(LF.mono).foregroundStyle(LF.inkSecondary)
                    .accessibilityIdentifier("viewfinderReading")
                Spacer(minLength: 0)
            }
        }.frame(minHeight: 28).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func parameterHero(_ parameter: MeterModel.Parameter, compact: Bool) -> some View {
        let isAperture = parameter == .aperture
        let automatic = isAperture ? model.mode == .shutterPriority : model.mode == .aperturePriority
        let selected = !editingCompensation && !automatic && model.selectedParameter == parameter
        let label = isAperture ? "光圈" : "快门"
        let value = automatic && model.reading == nil ? "—" : (isAperture ? "f/\(apertureLabel)" : ExposureEngine.shutterLabel(model.setting.shutterSeconds))
        return Button {
            if automatic { autoTap += 1 }
            else { editingCompensation = false; model.selectedParameter = parameter }
        } label: {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 3))
            layout {
                if typeSize.isAccessibilitySize {
                    Text(automatic ? "\(label) · 自动" : label).font(.body).foregroundStyle(LF.inkSecondary)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    Spacer(minLength: 0)
                }
                Text(value).font(LF.hero(typeSize.isAccessibilitySize ? 42 : (compact ? 36 : 42)))
                    .lfNumericText(value).lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(selected ? LF.amber : (automatic && !typeSize.isAccessibilitySize ? LF.inkSecondary : LF.ink))
                if !typeSize.isAccessibilitySize {
                    Text(automatic ? "\(label) · 自动" : label).font(LF.label).foregroundStyle(LF.inkSecondary)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(selected ? LF.amber : .clear).frame(width: 18, height: 2).offset(y: 5)
                        }
                }
            }.frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 60 : (compact ? 64 : 70))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(label)，\(value)，\(automatic ? "自动计算" : "点击调整")")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(automatic ? (isAperture ? "automaticAperture" : "automaticShutter") : (isAperture ? "apertureParameter" : "shutterParameter"))
    }

    private func dial(compact: Bool) -> some View {
        let values = editingCompensation ? (0...18).map { String(format: "%+.1f", Double($0 - 9) / 3) }
            : model.stops.map { model.selectedParameter == .aperture ? $0.formatted(.number.precision(.fractionLength(0...1))) : ExposureEngine.shutterLabel($0) }
        let selection = Binding<Int>(get: {
            editingCompensation ? Int((model.compensation * 3).rounded()) + 9 : Int(model.currentIndex)
        }, set: { index in
            if editingCompensation { model.compensation = Double(index - 9) / 3 }
            else { model.changeIndex(Double(index)) }
        })
        return StopDial(values: values, selection: selection, spacing: compact ? 12 : 14,
                        enabled: editingCompensation || !model.isAutomaticSelection,
                        accessibilityLabel: editingCompensation ? "曝光补偿" : (model.selectedParameter == .aperture ? "光圈调节" : "快门调节"),
                        identifier: "parameterDial")
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .id(editingCompensation ? "compensation" : (model.selectedParameter == .aperture ? "aperture" : "shutter"))
    }

    private var secondaryControls: some View {
        LFGlassGroup {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Menu {
                        ForEach(ExposureMode.allCases, id: \.self) { mode in
                            Button("\(mode.rawValue) \(mode.title)") { model.selectMode(mode) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.mode == .manual && model.reading != nil ? "M" : "\(model.mode.rawValue) \(model.mode.title)")
                            Image(systemName: "chevron.down").font(.caption2)
                        }.font(LF.chip).padding(.horizontal, 12).lfGlassControl()
                    }
                        .accessibilityLabel("曝光模式，\(model.mode.rawValue) \(model.mode.title)").accessibilityIdentifier("modePicker")
                    Button { editingCompensation = true } label: {
                        Text("\(compensationLabel) EV").font(LF.chip).lfNumericText(model.compensation)
                            .foregroundStyle(editingCompensation || abs(model.compensation) > 0.001 ? LF.amber : LF.inkSecondary)
                            .padding(.horizontal, 12).frame(minHeight: LF.chipHeight)
                            .meterGlassSurface(radius: 18, interactive: true)
                            .overlay(Capsule().stroke(abs(model.compensation) > 0.001 || editingCompensation ? LF.amber.opacity(0.8) : .clear, lineWidth: 1))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .contextMenu {
                            Button("归零") { model.compensation = 0 }
                            Button("补偿说明") { showExposure = true }
                        }
                        .accessibilityLabel("目标曝光补偿 \(compensationLabel) EV，点击调整")
                        .accessibilityHint("长按可归零或查看补偿说明")
                        .accessibilityAddTraits(editingCompensation ? .isSelected : [])
                        .accessibilityIdentifier("compensationButton")
                if model.mode == .manual, model.reading != nil, let suggested = model.solution {
                    Button { model.useSuggestion() } label: {
                        Text("采用 f/\(suggested.setting.aperture.formatted(.number.precision(.fractionLength(0...1))))·\(ExposureEngine.shutterLabel(suggested.setting.shutterSeconds))")
                            .font(LF.chip).lineLimit(1).minimumScaleFactor(0.85)
                            .padding(.horizontal, 10).lfGlassControl()
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("useSuggestion")
                }
            }
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func actions(compact: Bool) -> some View {
        HStack {
            Button {
                recordParameters = RecordParameter.capture(from: model)
                model.prepareRecord()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).stroke(LF.inkTertiary, lineWidth: 1)
                    if let image = model.reading?.image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(LF.inkTertiary)
                    }
                }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(model.reading == nil || model.isBusy)
                .accessibilityLabel("记录").accessibilityIdentifier("recordButton")
            Spacer()
            Button { Task { await model.measure() } } label: {
                ShutterControl(measuring: model.isMeasuring, locked: model.reading != nil, size: compact ? 64 : LF.shutter)
            }.buttonStyle(.plain).offset(x: failureOffset)
                .disabled(sheetPresentationActive || model.isBusy || (!model.isDemo && camera.status != .ready))
                .accessibilityLabel(model.isMeasuring ? "正在测光" : (model.reading == nil ? "测光" : "重新测光"))
                .accessibilityIdentifier("measureButton")
            Spacer()
            Group {
                if model.reading != nil {
                    Button { model.invalidateReading() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .medium)).frame(width: 34)
                            .lfGlassControl(radius: 17).frame(width: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("返回实时取景").accessibilityIdentifier("liveButton")
                } else if model.meteringMode == .spot { spotPositionMenu }
                else { Color.clear.frame(width: 44, height: 44).accessibilityHidden(true) }
            }.frame(width: 44)
        }.padding(.horizontal, 32).padding(.vertical, 6).background(LF.canvas)
    }

    private var spotPositionMenu: some View {
        Menu { spotPositionOptions } label: {
            Image(systemName: "scope").font(.system(size: 16, weight: .medium)).frame(width: 34)
                .lfGlassControl(radius: 17).frame(width: 44).contentShape(Rectangle())
        }.disabled(model.isBusy)
            .accessibilityLabel("测光点位置")
            .accessibilityValue(String(format: "横向 %.0f%%，纵向 %.0f%%", model.meteringPoint.x * 100, model.meteringPoint.y * 100))
            .accessibilityHint("选择预设位置，也可在取景画面点按或拖动")
            .accessibilityIdentifier("spotPositionMenu")
    }

    @ViewBuilder private var spotPositionOptions: some View {
        Button("中心") { model.setMeteringPoint(.center) }
        Button("上方") { model.setMeteringPoint(MeteringPoint(x: 0.5, y: 0.25)) }
        Button("下方") { model.setMeteringPoint(MeteringPoint(x: 0.5, y: 0.75)) }
        Button("左侧") { model.setMeteringPoint(MeteringPoint(x: 0.25, y: 0.5)) }
        Button("右侧") { model.setMeteringPoint(MeteringPoint(x: 0.75, y: 0.5)) }
    }

    private func sheetDidDismiss() {
        if !hasSheet { sheetPresentationActive = false }
    }
    private var hasSheet: Bool { showFilm || showSettings || showExposure || model.record != nil }
    private var sheetColorScheme: ColorScheme? {
        model.appearance == "light" ? .light : (model.appearance == "dark" ? .dark : nil)
    }
    private var hasFrame: Bool { model.isDemo || camera.status == .ready || model.reading != nil }
    private var apertureLabel: String { model.setting.aperture.formatted(.number.precision(.fractionLength(0...1))) }
    private var filmLabel: String {
        switch model.film { case .negative: return "负片"; case .slide: return "反转片"; case .blackAndWhite: return "黑白" }
    }
    private var compensationLabel: String { abs(model.compensation) < 0.001 ? "±0.0" : String(format: "%+.1f", model.compensation) }
    private var cameraPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.system(size: 32)).foregroundStyle(LF.amber).accessibilityHidden(true)
            Text(cameraTitle).font(.headline).multilineTextAlignment(.center)
            if camera.status == .denied {
                Button("前往系统设置") { openSettings() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .frame(minHeight: 44).accessibilityIdentifier("cameraSettingsButton")
            } else {
                Button(camera.status == .requesting ? "正在准备…" : "启用相机") { Task { await camera.start() } }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black).frame(minHeight: 44).contentShape(Rectangle())
                    .disabled(camera.status == .requesting).accessibilityIdentifier("enableCamera")
            }
            Button("先体验演示") { Task { await model.setDemo(true) } }.frame(minHeight: 44).contentShape(Rectangle())
                .font(.subheadline).accessibilityIdentifier("demoModeButton")
        }.padding(.horizontal, 20).frame(maxWidth: .infinity)
    }
    private var cameraTitle: String {
        switch camera.status {
        case .denied: return "需要相机访问权限"
        case .unavailable: return "当前设备没有可用相机"
        case .failed(let detail): return detail
        default: return "让光格看见眼前的光"
        }
    }
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ExposureOffsetScale: View {
    let delta: Double
    var body: some View {
        HStack(spacing: 5) {
            Text("−3")
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0...18, id: \.self) { index in
                            Rectangle().fill(index == 9 ? LF.inkSecondary : LF.inkTertiary)
                                .frame(width: 1, height: index == 9 ? 13 : (index.isMultiple(of: 3) ? 9 : 5))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7))
                        .foregroundStyle(LF.amber)
                        .position(x: (min(3, max(-3, delta)) + 3) / 6 * (geometry.size.width - geometry.size.width / 19) + geometry.size.width / 38, y: 3)
                }
            }.frame(height: 21)
            Text("+3")
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(LF.inkSecondary)
    }
}

private struct ShutterControl: View {
    let measuring: Bool
    let locked: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || LF.testReduceMotion }
    @State private var spinning = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(measuring ? LF.amber.opacity(0.3) : LF.ink, lineWidth: 3)
            if measuring {
                Circle().trim(from: 0, to: 0.7).stroke(LF.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(2).rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = !reduceMotion }.onDisappear { spinning = false }
            }
            Circle().fill(LF.ink).padding(8)
            Image(systemName: locked ? "arrow.clockwise" : "viewfinder").font(.system(size: 20, weight: .medium)).foregroundStyle(.black)
        }.frame(width: size, height: size).contentShape(Circle()).accessibilityHidden(true)
    }
}

struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0/3, 2.0/3] {
            path.move(to: CGPoint(x: rect.width * fraction, y: 0))
            path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
        }
        return path
    }
}
