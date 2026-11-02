import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

struct FilmSheet: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isoIndex: Binding<Int> {
        Binding(get: {
            ExposureEngine.isoStops.indices.min {
                abs(log2(ExposureEngine.isoStops[$0] / model.setting.iso)) < abs(log2(ExposureEngine.isoStops[$1] / model.setting.iso))
            } ?? 0
        }, set: { index in
            guard ExposureEngine.isoStops.indices.contains(index) else { return }
            model.setISO(ExposureEngine.isoStops[index])
        })
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这次装了哪卷胶片？").font(.headline)
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(spacing: 12))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            ForEach(FilmKind.allCases, id: \.self) { film in filmCard(film) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        let header = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                        header {
                            Text("胶卷 ISO").font(.headline)
                            if !typeSize.isAccessibilitySize { Spacer(minLength: 12) }
                            Text("\(Int(model.setting.iso))")
                                .font(.title2.monospaced().weight(.semibold)).lfNumericText(model.setting.iso)
                                .accessibilityIdentifier("filmISOValue")
                        }
                        StopDial(values: ExposureEngine.isoStops.map { "\(Int($0))" }, selection: isoIndex,
                                 majorEvery: 1, spacing: typeSize.isAccessibilitySize ? 76 : 52, accessibilityLabel: "胶卷 ISO",
                                 identifier: "isoDial", decreaseIdentifier: "decreaseISO", increaseIdentifier: "increaseISO")
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        Text("ISO 跟随胶卷，不随每张照片自动变化。推拉冲请使用你实际采用的曝光指数。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("曝光提醒").font(.headline)
                        Text("胶片类型只调整提醒阈值，不自动增加或减少曝光。").font(.subheadline)
                        Text("测光方式用于取样，不等于局部高光或暗部剪裁检测，也不能预测胶片冲扫后的成片。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }.accessibilityIdentifier("filmScrollView")
                .navigationTitle("胶卷").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.foregroundStyle(.primary) } }
        }.modifier(LFSheetAppearance(appearance: model.appearance))
            .presentationDetents([.medium, .large])
            .presentationBackground(Color(uiColor: .systemBackground))
    }

    private func filmCard(_ film: FilmKind) -> some View {
        let selected = film == model.film
        let color: Color = film == .negative ? Color(red: 0.75, green: 0.38, blue: 0.20)
            : film == .slide ? Color(red: 0.26, green: 0.49, blue: 0.43) : Color(white: 0.35)
        let title = film == .negative ? "彩负" : film == .slide ? "反转" : "黑白"
        return Button { model.film = film } label: {
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 12 : 8) {
                RoundedRectangle(cornerRadius: 8).fill(color).frame(height: typeSize.isAccessibilitySize ? 32 : 36)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.85)).padding(.trailing, 10)
                    }.accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(LF.amber) }
                }
            }.padding(typeSize.isAccessibilitySize ? 12 : 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? LF.amber.opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? LF.amber : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1) }
        }.buttonStyle(.plain)
            .accessibilityLabel(film.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("film_\(film.rawValue)")
    }
}

struct ExposureAdjustmentSheet: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    private var isNeutral: Bool { abs(model.compensation) < 0.0001 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $model.compensation, in: -3...3, step: 1.0/3.0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("曝光补偿")
                            Text(String(format: "%+.1f EV", isNeutral ? 0 : model.compensation))
                                .lfNumericText(model.compensation).foregroundStyle(.secondary)
                                .accessibilityIdentifier("compensationValue")
                        }
                    }.accessibilityIdentifier("compensationStepper")
                    Button("归零") { model.compensation = 0 }
                        .foregroundStyle(.primary)
                        .disabled(isNeutral).accessibilityIdentifier("resetCompensation")
                } header: { Text("目标曝光补偿") } footer: {
                    Text(model.mode == .manual
                         ? "每次调节 1/3 档。M 模式保留你的参数，只有点击「采用建议」才应用补偿。"
                         : "每次调节 1/3 档。正值增加推荐曝光，负值减少推荐曝光。")
                }
                Section("读数说明") {
                    LabeledContent("场景 EV100") {
                        Text("测得的场景亮度").foregroundStyle(.secondary)
                    }
                    LabeledContent("当前曝光偏移") {
                        Text("当前参数相对测光基准的差值").foregroundStyle(.secondary)
                    }
                    LabeledContent("曝光补偿") {
                        Text("你希望推荐值偏移多少").foregroundStyle(.secondary)
                    }
                    Text("曝光提醒基于整体读数，不判断局部高光或暗部剪裁。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("曝光").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }.foregroundStyle(.primary).accessibilityIdentifier("exposureDone")
                    }
                }
        }.modifier(LFSheetAppearance(appearance: model.appearance))
            .presentationDetents([.medium, .large])
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("弹层主题", selection: $model.appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.accessibilityIdentifier("appearancePicker")
                } header: { Text("弹层外观") } footer: { Text("仅影响胶卷、曝光、记录与设置弹层；测光主界面始终使用深色。") }
                Section {
                    Toggle("九宫格", isOn: $model.showGrid)
                } header: { Text("取景") }
                Section {
                    Stepper(value: $model.calibration, in: -3...3, step: 0.1) {
                        LabeledContent("测光校准") {
                            Text(String(format: "%+.1f EV", model.calibration))
                                .lfNumericText(model.calibration)
                        }
                    }
                    Text("仅在与可靠参考测光表、均匀灰卡比较后调整。正值提高 EV100，推荐的曝光量会减少。修改后必须重新测光。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("设备校准") }
                Section {
                    Stepper(value: $model.frameNumber, in: 1...9999) {
                        Text("下一张帧号 · \(model.frameNumber)").lfNumericText(model.frameNumber)
                    }
                    Button("从第 1 张开始") { showResetConfirmation = true }.foregroundStyle(.primary)
                    Text("保存到相册成功后帧号才增加；分享不会自动增加。记录卡包含测光时的参考画面，不包含趋势滤镜。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("拍摄记录") }
                Section {
                    Toggle("演示模式", isOn: Binding(get: { model.isDemo }, set: { value in Task { await model.setDemo(value) } }))
                        .disabled(model.isBusy)
                    if model.isDemo {
                        Picker("演示光线", selection: Binding(get: { model.demoEV }, set: { model.demoEV = $0; model.invalidateReading() })) {
                            Text("日照 · EV100 15").tag(15.0)
                            Text("阴天 · EV100 12").tag(12.0)
                            Text("室内 · EV100 8").tag(8.0)
                        }
                    }
                    Text("演示采用插画和固定光线数据，不能用于实际拍摄。退出演示后可启用后置相机。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("体验与帮助") }
                Section {
                    Label("离线工作，无账号，不上传照片", systemImage: "lock.shield")
                    Text("仅在启用相机或保存相册时请求所需权限。不请求麦克风、位置或相册读取权限。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("打开系统权限设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.foregroundStyle(.primary)
                } header: { Text("隐私") }
                Section {
                    LabeledContent("LumaFrame 光格", value: "0.1 · 开发预览")
                    Text("适用于反射式测光参考。曝光趋势不是胶片成片模拟；测光精度与稳定性仍需在你的 iPhone 上完成灰卡验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("关于") }
            }.accessibilityIdentifier("settingsForm")
                .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.foregroundStyle(.primary) } }
                .confirmationDialog("开始新胶卷？", isPresented: $showResetConfirmation) {
                    Button("帧号重置为 1") { model.frameNumber = 1 }
                    Button("取消", role: .cancel) {}
                } message: { Text("已有相册记录不会改变。") }
        }.modifier(LFSheetAppearance(appearance: model.appearance))
            .presentationDetents([.large])
    }
}

struct RecordParameter: Identifiable {
    let id: String
    let label: String
    let value: String

    @MainActor static func capture(from model: MeterModel) -> [RecordParameter] {
        guard let reading = model.reading else { return [] }
        let setting = model.setting
        var result = [
            RecordParameter(id: "film", label: "胶片", value: model.film.title),
            RecordParameter(id: "iso", label: "ISO", value: "\(Int(setting.iso))"),
            RecordParameter(id: "mode", label: "曝光模式", value: "\(model.mode.rawValue) · \(model.mode.title)"),
            RecordParameter(id: "aperture", label: "光圈", value: "f/\(setting.aperture.formatted(.number.precision(.fractionLength(0...1))))"),
            RecordParameter(id: "shutter", label: "快门", value: ExposureEngine.shutterLabel(setting.shutterSeconds)),
            RecordParameter(id: "delta", label: "曝光偏移", value: String(format: "%+.1f EV", ExposureEngine.deltaEV(ev100: reading.ev100, setting: setting))),
            RecordParameter(id: "metering", label: "测光方式", value: reading.meteringMode.title),
            RecordParameter(id: "lens", label: "镜头", value: reading.lensTitle),
            RecordParameter(id: "ev", label: "场景 EV100", value: String(format: "%.1f", reading.ev100)),
            RecordParameter(id: "date", label: "测光时间", value: reading.capturedAt.formatted(date: .abbreviated, time: .shortened))
        ]
        if reading.meteringMode == .spot {
            result.append(RecordParameter(id: "point", label: "取样位置", value: String(format: "横向 %.0f%%\n纵向 %.0f%%", reading.meteringPoint.x * 100, reading.meteringPoint.y * 100)))
        }
        return result
    }
}

// The draft owns an immutable UIImage; sharing encodes that exact raster as PNG.
// No exposure rendering or model state is consulted by this transfer representation.
private struct RecordPNG: Transferable, @unchecked Sendable {
    let image: UIImage
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { record in
            guard let data = record.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }
}

struct RecordSheet: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var draft: RecordDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var acknowledged = false
    @State private var saving = false
    @State private var saveFailure: PhotoSaveFailure?
    @State private var riskReviewRequest = 0
    @State private var parameters: [RecordParameter]
    private var canExport: Bool { draft.risk?.isSevere != true || acknowledged }

    init(model: MeterModel, draft: RecordDraft, parameters: [RecordParameter] = []) {
        self.model = model
        self.draft = draft
        _parameters = State(initialValue: parameters)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("第 \(draft.frame) 张").font(.headline).lfNumericText(draft.frame)
                        Image(uiImage: draft.image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel("第 \(draft.frame) 张记录参考图")
                            .accessibilityIdentifier("recordPreview")
                            .accessibilityHidden(typeSize.isAccessibilitySize)
                        if parameters.isEmpty {
                            Text(draft.parameterSummary).font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("recordParameterSummary")
                        } else {
                            Group {
                            if typeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 20) {
                                    ForEach(parameters) { parameter in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(parameter.label).font(.subheadline).foregroundStyle(.secondary)
                                            Text(parameter.value).font(.body.monospaced()).lfNumericText(parameter.value)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(parameter.label)，\(parameter.value)")
                                        .accessibilityIdentifier("recordParameter_\(parameter.id)")
                                    }
                                }
                            } else {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                                ForEach(parameters) { parameter in
                                    let isNumeric = ["iso", "aperture", "shutter", "delta", "ev"].contains(parameter.id)
                                    GridRow(alignment: .firstTextBaseline) {
                                        Text(parameter.label).font(.subheadline).foregroundStyle(.secondary)
                                            .gridColumnAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(parameter.value).font(.body.monospaced()).lfNumericText(parameter.value)
                                            .lineLimit(isNumeric ? 1 : nil)
                                            .minimumScaleFactor(isNumeric ? 0.6 : 1)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(parameter.label)，\(parameter.value)")
                                    .accessibilityIdentifier("recordParameter_\(parameter.id)")
                                }
                            }
                            }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("recordParameterSummary")
                        }
                        Text("未加曝光趋势的取景参考图")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if draft.isDemo {
                            Label("演示记录已带有标记，不是实际测光结果。", systemImage: "info.circle").font(.footnote)
                        }
                        if draft.risk?.isSevere == true {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(draft.risk?.title ?? "", systemImage: "exclamationmark.triangle").font(.headline)
                                Text("当前设置相对测光基准偏移较大。这是经验提醒，不是画面剪裁检测。")
                                    .font(.subheadline)
                                Toggle("我理解提醒，保留这些参数", isOn: $acknowledged)
                                    .font(.subheadline).accessibilityIdentifier("riskAcknowledgement")
                            }.padding(16).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                                .id("riskDetails")
                        }
                        if let saveFailure {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(saveFailure.localizedDescription).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("saveError")
                                if saveFailure == .denied {
                                    Button("前往系统设置") {
                                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                    }.foregroundStyle(.primary).frame(minHeight: 44).accessibilityIdentifier("photoSettingsButton")
                                }
                            }.id("saveFailureDetails")
                        }
                    }.padding(20)
                }.accessibilityIdentifier("recordScrollView")
                .onChange(of: saveFailure) { _, failure in
                    if failure != nil { proxy.scrollTo("saveFailureDetails", anchor: .bottom) }
                }
                .onChange(of: riskReviewRequest) { _, _ in
                    proxy.scrollTo("riskDetails", anchor: .bottom)
                }
            }
                .safeAreaInset(edge: .bottom, spacing: 0) { recordActions }
                .navigationTitle("拍摄记录").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.foregroundStyle(.primary).disabled(saving) }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: RecordPNG(image: draft.image), preview: SharePreview("第 \(draft.frame) 张记录", image: Image(uiImage: draft.image))) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .disabled(!canExport || saving)
                        .opacity(canExport && !saving ? 1 : 0.35)
                        .accessibilityLabel("分享记录图")
                        .accessibilityIdentifier("shareRecord")
                    }
                }
                .interactiveDismissDisabled(saving)
        }.modifier(LFSheetAppearance(appearance: model.appearance))
            .presentationDetents([.large])
    }

    private var recordActions: some View {
        return VStack(spacing: 10) {
            if !canExport {
                Button { riskReviewRequest += 1 } label: {
                    Label("查看曝光提醒", systemImage: "exclamationmark.triangle")
                        .font(.footnote).frame(minHeight: 44)
                }.foregroundStyle(.primary).accessibilityIdentifier("reviewExposureRisk")
            }
            if draft.saved {
                Label("已保存到系统相册", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saveSuccess")
            }
            primaryAction
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var primaryAction: some View {
        if draft.saved {
            Button { dismiss() } label: {
                Text("继续取景").fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LF.amber).foregroundStyle(.black)
                .accessibilityIdentifier("continueMetering")
        } else {
            Button {
                guard !saving, !draft.saved, canExport else { return }
                saving = true
                saveFailure = nil
                Task {
                    do {
                        try await RecordExporter.save(draft.image)
                        model.recordSaved(draft)
                    } catch { saveFailure = (error as? PhotoSaveFailure) ?? .failed }
                    saving = false
                }
            } label: {
                HStack {
                    if saving { ProgressView().tint(.black) }
                    Text(saving ? "正在保存…" : (saveFailure == nil ? "保存到相册" : "重试保存")).fontWeight(.semibold)
                }.frame(maxWidth: .infinity, minHeight: 36)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LF.amber).foregroundStyle(.black)
                .disabled(!canExport || saving).accessibilityIdentifier("saveRecord")
        }
    }
}

private struct LFSheetAppearance: ViewModifier {
    let appearance: String
    @State private var systemScheme: ColorScheme?
    private var resolvedScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemScheme
        }
    }

    func body(content: Content) -> some View {
        content
            .tint(LF.amber)
            .background {
                LFSystemAppearanceObserver { scheme in
                    if systemScheme != scheme { systemScheme = scheme }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .preferredColorScheme(resolvedScheme)
            .presentationDragIndicator(.visible)
    }
}

/// Reads the upstream scene, never a view/window trait overridden by the dark meter.
private struct LFSystemAppearanceObserver: UIViewRepresentable {
    let onChange: (ColorScheme) -> Void

    func makeUIView(context: Context) -> LFSceneAppearanceView {
        let view = LFSceneAppearanceView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: LFSceneAppearanceView, context: Context) {
        view.onChange = onChange
        view.observeCurrentScene()
    }

    static func dismantleUIView(_ view: LFSceneAppearanceView, coordinator: ()) {
        view.stopObserving()
    }
}

private final class LFSceneAppearanceView: UIView {
    var onChange: ((ColorScheme) -> Void)?
    private weak var observedScene: UIWindowScene?
    private var registration: (any UITraitChangeRegistration)?
    private var lastStyle: UIUserInterfaceStyle?
    private var revision = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observeCurrentScene()
    }

    func observeCurrentScene() {
        let scene = window?.windowScene
        if observedScene !== scene {
            stopObserving()
            guard let scene else { return }
            observedScene = scene
            registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (scene: UIWindowScene, _: UITraitCollection) in
                self?.publishStyle(from: scene)
            }
        }
        if let scene { publishStyle(from: scene) }
    }

    func stopObserving() {
        revision += 1
        if let registration, let observedScene {
            observedScene.unregisterForTraitChanges(registration)
        }
        registration = nil
        observedScene = nil
        lastStyle = nil
    }

    private func publishStyle(from scene: UIWindowScene) {
        let style = scene.traitCollection.userInterfaceStyle
        guard style == .light || style == .dark, style != lastStyle else { return }
        lastStyle = style
        let expectedRevision = revision
        // UIKit may attach this view during SwiftUI's update. Publish on the next
        // main turn and discard callbacks for a detached scene or superseded style.
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let self, let scene, self.revision == expectedRevision,
                  self.observedScene === scene, scene.traitCollection.userInterfaceStyle == style else { return }
            self.onChange?(style == .dark ? .dark : .light)
        }
    }
}
