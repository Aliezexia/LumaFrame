import SwiftUI
import AVFoundation

@MainActor
final class MeterModel: ObservableObject {
    @Published var setting = ExposureSetting() { didSet { persist() } }
    @Published var mode: ExposureMode = .aperturePriority { didSet { solveAutomatic(); persist() } }
    @Published var film: FilmKind = .negative { didSet { persist() } }
    @Published var compensation: Double = 0 { didSet { solveAutomatic(); updateTrend(); persist() } }
    @Published var calibration: Double = 0 { didSet { invalidateReading(); persist() } }
    @Published var showGrid = true { didSet { persist() } }
    @Published var appearance = "system" { didSet { persist() } }
    @Published var frameNumber = 1 { didSet { persist() } }
    @Published var reading: CapturedReading?
    @Published var trendImage: UIImage?
    @Published var isMeasuring = false
    @Published var message: String?
    @Published var selectedParameter: Parameter = .aperture
    @Published var demoEV = 12.0
    @Published var isDemo: Bool
    @Published var record: RecordDraft?
    @Published var zoom = 1.0
    @Published private(set) var meteringMode: MeteringMode = .matrix
    @Published private(set) var meteringPoint = MeteringPoint.center
    @Published private(set) var selectedLensID = CameraLens.demoOptions[0].id
    @Published private(set) var isChangingLens = false
    @Published private(set) var demoPreview = DemoScene.preview(zoom: 1, aspect: 0.9)
    let camera = CameraService()
    var viewfinderAspect: CGFloat = 0.9
    private let defaults: UserDefaults
    private var restoring = true
    private var measurementRevision = 0
    private var trendRevision = 0
    private var trendTask: Task<Void, Never>?
    private var pendingTrend: (image: UIImage, exposure: Double, revision: Int)?
    private var measurementAttempts = 0

    enum Parameter { case aperture, shutter }
    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        defaults = testing ? UserDefaults(suiteName: "LumaFrame.UITests")! : .standard
        if testing && !ProcessInfo.processInfo.arguments.contains("-ui-testing-preserve") {
            defaults.removePersistentDomain(forName: "LumaFrame.UITests")
        }
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        isDemo = true
        #else
        isDemo = testing
        #endif
        if testing && ProcessInfo.processInfo.arguments.contains("-ui-testing-camera-placeholder") { isDemo = false }
        if let data = defaults.data(forKey: "exposure"), let saved = try? JSONDecoder().decode(ExposureSetting.self, from: data),
           saved.iso.isFinite, saved.iso > 0, saved.aperture.isFinite, saved.aperture > 0, saved.shutterSeconds.isFinite, saved.shutterSeconds > 0 {
            setting = saved
        }
        if let raw = defaults.string(forKey: "mode"), let value = ExposureMode(rawValue: raw) { mode = value }
        selectedParameter = mode == .shutterPriority ? .shutter : .aperture
        if let raw = defaults.string(forKey: "film"), let value = FilmKind(rawValue: raw) { film = value }
        if let raw = defaults.string(forKey: "meteringMode"), let value = MeteringMode(rawValue: raw) { meteringMode = value }
        compensation = min(3, max(-3, defaults.double(forKey: "compensation")))
        calibration = min(3, max(-3, defaults.double(forKey: "calibration")))
        frameNumber = max(1, defaults.integer(forKey: "frameNumber"))
        showGrid = defaults.object(forKey: "grid") as? Bool ?? true
        if let saved = defaults.string(forKey: "appearance"), ["system", "light", "dark"].contains(saved) { appearance = saved }
        restoring = false
    }
    var delta: Double? { reading.map { ExposureEngine.deltaEV(ev100: $0.ev100, setting: setting) } }
    var lensOptions: [CameraLens] { isDemo ? CameraLens.demoOptions : camera.lenses }
    var currentLensID: String { isDemo ? selectedLensID : camera.selectedLensID }
    var lensTitle: String { lensOptions.first(where: { $0.id == currentLensID })?.title ?? "1×" }
    var lensDetail: String { lensOptions.first(where: { $0.id == currentLensID })?.detail ?? "广角" }
    var isBusy: Bool { isMeasuring || isChangingLens || camera.isSwitchingLens }
    var risk: ExposureRisk? { delta.map { ExposureEngine.risk(deltaEV: $0, film: film) } }
    var solution: ExposureSolution? {
        reading.map { ExposureEngine.solve(mode: mode == .manual ? .aperturePriority : mode, setting: setting, ev100: $0.ev100, compensationEV: compensation) }
    }
    var isLimited: Bool { mode != .manual && solution?.isLimited == true }
    var isAutomaticSelection: Bool { (mode == .aperturePriority && selectedParameter == .shutter) || (mode == .shutterPriority && selectedParameter == .aperture) }
    var stops: [Double] { selectedParameter == .aperture ? ExposureEngine.apertureStops : ExposureEngine.shutterStops }
    var currentIndex: Double {
        let value = selectedParameter == .aperture ? setting.aperture : setting.shutterSeconds
        return Double(stops.indices.min(by: { abs(log2(stops[$0] / value)) < abs(log2(stops[$1] / value)) }) ?? 0)
    }
    func changeIndex(_ index: Double) {
        guard !isAutomaticSelection else { return }
        let i = min(stops.count - 1, max(0, Int(index.rounded())))
        if selectedParameter == .aperture { setting.aperture = stops[i] }
        else { setting.shutterSeconds = stops[i] }
        solveAutomatic()
        updateTrend()
    }
    func setISO(_ iso: Double) {
        setting.iso = iso
        solveAutomatic()
        updateTrend()
    }
    func selectMode(_ next: ExposureMode) {
        mode = next
        if next == .aperturePriority { selectedParameter = .aperture }
        if next == .shutterPriority { selectedParameter = .shutter }
        updateTrend()
    }
    func measure() async {
        guard !isBusy else { return }
        invalidateReading()
        isMeasuring = true
        message = nil
        measurementAttempts += 1
        let revision = measurementRevision
        defer { isMeasuring = false }
        do {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ui-testing"), arguments.contains("-ui-testing-fail-remeasure"), measurementAttempts == 2 {
                throw CameraFailure.unstable
            }
            let captured: CapturedReading
            if isDemo {
                let offset = DemoScene.meteringOffset(image: demoPreview, mode: meteringMode, point: meteringPoint)
                captured = CapturedReading(ev100: demoEV + offset + calibration, image: demoPreview, capturedAt: Date(), zoom: zoom,
                                          lensTitle: lensTitle, meteringMode: meteringMode, meteringPoint: meteringPoint)
            } else {
                captured = try await camera.captureReading(calibrationEV: calibration, mode: meteringMode,
                                                           point: meteringPoint, aspectRatio: Double(viewfinderAspect))
            }
            guard revision == measurementRevision, captured.ev100.isFinite else { return }
            reading = CapturedReading(ev100: captured.ev100, image: DemoScene.crop(captured.image, aspect: viewfinderAspect),
                                      capturedAt: captured.capturedAt, zoom: captured.zoom, lensTitle: captured.lensTitle,
                                      meteringMode: captured.meteringMode, meteringPoint: captured.meteringPoint)
            trendImage = reading?.image
            solveAutomatic()
            updateTrend()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch { if revision == measurementRevision { message = error.localizedDescription } }
    }
    func useSuggestion() {
        guard let solution else { return }
        setting = solution.setting
        updateTrend()
    }
    func invalidateReading() {
        measurementRevision += 1
        trendRevision += 1
        pendingTrend = nil
        reading = nil
        trendImage = nil
    }
    func selectMeteringMode(_ value: MeteringMode) {
        guard value != meteringMode, !isBusy else { return }
        meteringMode = value
        invalidateReading()
        persist()
    }
    func setMeteringPoint(_ point: MeteringPoint) {
        guard meteringMode == .spot, !isBusy else { return }
        meteringPoint = SpatialMetering.clampedPoint(point, aspectRatio: Double(viewfinderAspect))
        invalidateReading()
    }
    func updateViewfinderAspect(_ aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0, abs(viewfinderAspect - aspect) > 0.001 else { return }
        viewfinderAspect = aspect
        meteringPoint = SpatialMetering.clampedPoint(meteringPoint, aspectRatio: Double(aspect))
        invalidateReading()
        if isDemo { demoPreview = DemoScene.preview(zoom: zoom, aspect: aspect) }
    }
    func selectLens(_ lens: CameraLens) async {
        guard !isBusy, lens.id != currentLensID else { return }
        isChangingLens = true
        invalidateReading()
        defer { isChangingLens = false }
        do {
            if isDemo {
                selectedLensID = lens.id
                zoom = lens.zoom
                demoPreview = DemoScene.preview(zoom: zoom, aspect: viewfinderAspect)
            } else {
                try await camera.selectLens(lens.id)
                zoom = camera.zoom
            }
            meteringPoint = .center
            UISelectionFeedbackGenerator().selectionChanged()
        } catch { message = error.localizedDescription }
    }
    func setDemo(_ enabled: Bool) async {
        guard !isBusy else { return }
        isDemo = enabled
        invalidateReading()
        meteringPoint = .center
        if enabled {
            camera.stop()
            selectedLensID = CameraLens.demoOptions[0].id
            zoom = CameraLens.demoOptions[0].zoom
            demoPreview = DemoScene.preview(zoom: zoom, aspect: viewfinderAspect)
        } else { await camera.start() }
    }
    func resume() async {
        guard !isDemo else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { await camera.start() }
    }
    func background() {
        camera.stop()
        if !isDemo { invalidateReading() }
    }
    func prepareRecord() {
        guard let reading else { return }
        let date = reading.capturedAt.formatted(date: .abbreviated, time: .shortened)
        let amount = delta ?? 0
        let lines = [
            "\(film.title) · ISO \(Int(setting.iso)) · \(mode.rawValue)模式",
            "f/\(setting.aperture.formatted(.number.precision(.fractionLength(0...1))))   \(ExposureEngine.shutterLabel(setting.shutterSeconds))   \(String(format: "%+.1f EV", amount))",
            "\(reading.meteringMode.title) · \(reading.lensTitle) · EV100 \(String(format: "%.1f", reading.ev100))",
            "\(date)\(reading.meteringMode == .spot ? String(format: " · 取样位置 %.0f%% / %.0f%%", reading.meteringPoint.x * 100, reading.meteringPoint.y * 100) : "")",
            isDemo ? "演示数据 · 不可用于实际测光" : "取景参考图 · 非胶片成片模拟"
        ]
        let spotSummary = reading.meteringMode == .spot ? String(format: "取样位置：横向 %.0f%%，纵向 %.0f%%。", reading.meteringPoint.x * 100, reading.meteringPoint.y * 100) : ""
        let summary = "\(film.title)，ISO \(Int(setting.iso))，\(mode.title)。光圈 f/\(setting.aperture.formatted(.number.precision(.fractionLength(0...1))))，快门 \(ExposureEngine.shutterLabel(setting.shutterSeconds))，曝光偏移 \(String(format: "%+.1f", amount)) EV。\(reading.meteringMode.title)，\(reading.lensTitle)取景。\(spotSummary)场景 EV100 \(String(format: "%.1f", reading.ev100))，\(date)。"
        record = RecordDraft(image: RecordExporter.compose(image: reading.image, lines: lines, title: String(format: "LUMAFRAME  /  #%03d", frameNumber), parameters: RecordParameter.capture(from: self)), frame: frameNumber, risk: risk, isDemo: isDemo, parameterSummary: summary)
    }
    func recordSaved(_ draft: RecordDraft) {
        guard !draft.saved else { return }
        draft.saved = true
        frameNumber = max(frameNumber, draft.frame + 1)
        invalidateReading()
    }
    private func solveAutomatic() {
        guard !restoring, let reading, mode != .manual else { return }
        let result = ExposureEngine.solve(mode: mode, setting: setting, ev100: reading.ev100, compensationEV: compensation)
        if result.setting != setting { setting = result.setting }
    }
    private func updateTrend() {
        guard let reading else { return }
        trendRevision += 1
        pendingTrend = (reading.image, delta ?? 0, trendRevision)
        guard trendTask == nil else { return }
        trendTask = Task { [weak self] in
            // One render in flight; slider updates replace one pending request.
            // An invalidated render may finish, but cannot publish or overlap another render.
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard let self else { return }
                guard let request = self.pendingTrend else { self.trendTask = nil; return }
                self.pendingTrend = nil
                let rendered = await Task.detached(priority: .userInitiated) {
                    TrendRenderer.image(request.image, deltaEV: request.exposure)
                }.value
                if self.trendRevision == request.revision { self.trendImage = rendered }
                if self.pendingTrend == nil { self.trendTask = nil; return }
            }
        }
    }
    private func persist() {
        guard !restoring else { return }
        defaults.set(try? JSONEncoder().encode(setting), forKey: "exposure")
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(film.rawValue, forKey: "film")
        defaults.set(meteringMode.rawValue, forKey: "meteringMode")
        defaults.set(compensation, forKey: "compensation")
        defaults.set(calibration, forKey: "calibration")
        defaults.set(frameNumber, forKey: "frameNumber")
        defaults.set(showGrid, forKey: "grid")
        defaults.set(appearance, forKey: "appearance")
    }
}

@MainActor
final class RecordDraft: ObservableObject, Identifiable {
    let id = UUID()
    let image: UIImage
    let frame: Int
    let risk: ExposureRisk?
    let isDemo: Bool
    let parameterSummary: String
    @Published var saved = false
    init(image: UIImage, frame: Int, risk: ExposureRisk?, isDemo: Bool, parameterSummary: String) {
        self.image = image; self.frame = frame; self.risk = risk; self.isDemo = isDemo
        self.parameterSummary = parameterSummary
    }
}

