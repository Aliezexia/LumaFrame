import AVFoundation
import Combine
import CoreImage
import ImageIO
import UIKit

enum CameraStatus: Equatable {
    case idle, requesting, ready, denied, unavailable
    case failed(String)
}

struct CameraLens: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let zoom: Double

    static let demoOptions = [
        CameraLens(id: "demo-wide", title: "1×", detail: "演示广角", zoom: 1),
        CameraLens(id: "demo-tele", title: "2×", detail: "演示数码裁切", zoom: 2)
    ]
}

struct CapturedReading {
    let ev100: Double
    let image: UIImage
    let capturedAt: Date
    let zoom: Double
    let lensTitle: String
    let meteringMode: MeteringMode
    let meteringPoint: MeteringPoint

    init(ev100: Double, image: UIImage, capturedAt: Date, zoom: Double,
         lensTitle: String = "广角", meteringMode: MeteringMode = .matrix,
         meteringPoint: MeteringPoint = .center) {
        self.ev100 = ev100; self.image = image; self.capturedAt = capturedAt; self.zoom = zoom
        self.lensTitle = lensTitle; self.meteringMode = meteringMode; self.meteringPoint = meteringPoint
    }
}

enum CameraFailure: LocalizedError {
    case noCamera, configuration, unstable, interrupted, invalidCalibration, rendering, sceneChanged
    case lensUnavailable, lensSwitch, meteringUnavailable

    var errorDescription: String? {
        switch self {
        case .noCamera: return "这台设备没有可用的后置相机。可使用演示模式体验交互。"
        case .configuration: return "相机暂时无法启动，请稍后重试。"
        case .unstable: return "光线还不稳定，请保持手机不动后重新测光。"
        case .interrupted: return "相机被其他应用或系统暂时占用，请返回取景后重试。"
        case .invalidCalibration: return "校准值无效，请在设置中重新输入。"
        case .rendering: return "未能生成取景参考图，请重新测光。"
        case .sceneChanged: return "取景状态已改变，请重新测光。"
        case .lensUnavailable: return "当前设备没有这个可用镜头。"
        case .lensSwitch: return "未能切换镜头，已保留原镜头，请重试。"
        case .meteringUnavailable: return "当前画面无法生成分区读数，请调整取景后重试。"
        }
    }
}

/// UI state lives on the main actor; all capture mutations run on the pipeline queue.
@MainActor
final class CameraService: ObservableObject {
    @Published private(set) var status: CameraStatus = .idle
    @Published private(set) var liveEV100: Double?
    @Published private(set) var isStable = false
    @Published private(set) var zoom: Double = 1
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var selectedLensID = ""
    @Published private(set) var isSwitchingLens = false

    let session: AVCaptureSession
    private let pipeline: CameraPipeline
    private var desiredRunning = false
    private var starting = false
    private var lifecycleRevision = 0

    init() {
        let pipeline = CameraPipeline()
        self.pipeline = pipeline
        session = pipeline.session
        pipeline.onSample = { [weak self] generation, ev, stable, zoom in
            Task { @MainActor [weak self] in
                guard let self, self.desiredRunning, generation == self.lifecycleRevision,
                      self.status == .ready else { return }
                self.liveEV100 = ev
                self.isStable = stable
                self.zoom = zoom
            }
        }
        pipeline.onStatus = { [weak self] generation, status in
            Task { @MainActor [weak self] in
                guard let self, self.desiredRunning, generation == self.lifecycleRevision else { return }
                self.status = status
                if status != .ready {
                    self.isStable = false
                    self.liveEV100 = nil
                }
            }
        }
    }

    func start() async {
        desiredRunning = true
        guard status != .ready, !starting else { return }
        starting = true
        defer { starting = false }

        // One startup owns the loop. A start received while it is awaiting permission
        // or the capture queue updates the intent instead of being lost.
        while desiredRunning {
            let revision = lifecycleRevision
            status = .requesting
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined:
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            // A permission sheet may outlive the scene that requested it. Only an
            // explicit later start can restore desiredRunning after stop().
            guard desiredRunning else { return }
            guard revision == lifecycleRevision else { continue }
            guard authorized else { status = .denied; return }

            do {
                let snapshot = try await pipeline.start(generation: revision)
                guard desiredRunning, revision == lifecycleRevision else {
                    pipeline.stop(generation: lifecycleRevision)
                    continue
                }
                apply(snapshot)
                status = .ready
                return
            } catch {
                guard desiredRunning else { return }
                guard revision == lifecycleRevision else { continue }
                switch error {
                case CameraFailure.noCamera: status = .unavailable
                default: status = .failed(error.localizedDescription)
                }
                return
            }
        }
    }

    func stop() {
        desiredRunning = false
        lifecycleRevision += 1
        pipeline.stop(generation: lifecycleRevision)
        status = .idle
        liveEV100 = nil
        isStable = false
    }

    func setZoom(_ factor: Double) {
        guard factor.isFinite else { return }
        // Compatibility for the original 1×/2× control. New UI selects explicit routes.
        guard let lens = lenses.first(where: { abs($0.zoom - factor) < 0.05 }) else { return }
        Task { try? await selectLens(lens.id) }
    }

    func selectLens(_ id: String) async throws {
        guard desiredRunning, status == .ready, !isSwitchingLens else { throw CameraFailure.interrupted }
        guard lenses.contains(where: { $0.id == id }) else { throw CameraFailure.lensUnavailable }
        guard id != selectedLensID else { return }
        lifecycleRevision += 1
        let revision = lifecycleRevision
        isSwitchingLens = true
        isStable = false
        liveEV100 = nil
        defer { isSwitchingLens = false }
        do {
            let snapshot = try await pipeline.selectLens(id, generation: revision)
            guard desiredRunning, revision == lifecycleRevision else { throw CameraFailure.sceneChanged }
            apply(snapshot)
        } catch {
            guard desiredRunning, revision == lifecycleRevision else { throw CameraFailure.sceneChanged }
            // Recoverable switching failures leave the original input and selection intact.
            if case CameraFailure.configuration = error { status = .failed(error.localizedDescription) }
            throw error
        }
    }

    private func apply(_ snapshot: CameraLensSnapshot) {
        lenses = snapshot.lenses
        selectedLensID = snapshot.selectedID
        zoom = snapshot.zoom
    }

    func captureReading(calibrationEV: Double, mode: MeteringMode = .matrix,
                        point: MeteringPoint = .center, aspectRatio: Double = 0.75) async throws -> CapturedReading {
        guard calibrationEV.isFinite else { throw CameraFailure.invalidCalibration }
        guard aspectRatio.isFinite, aspectRatio > 0 else { throw CameraFailure.meteringUnavailable }
        guard status == .ready, !isSwitchingLens else { throw CameraFailure.interrupted }
        let revision = lifecycleRevision
        // The bounded wait allows AE to settle without freezing the UI.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            try Task.checkCancellation()
            guard status == .ready, !isSwitchingLens else { throw CameraFailure.interrupted }
            guard revision == lifecycleRevision else { throw CameraFailure.sceneChanged }
            if let reading = try await pipeline.captureIfStable(calibrationEV: calibrationEV, mode: mode,
                                                               point: point, aspectRatio: aspectRatio) {
                guard status == .ready, revision == lifecycleRevision else { throw CameraFailure.sceneChanged }
                return reading
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CameraFailure.unstable
    }
}

private struct CameraLensSnapshot: Sendable {
    let lenses: [CameraLens]
    let selectedID: String
    let zoom: Double
}

// Mutable capture state is confined to `queue`. Callbacks are installed before first
// start and subsequently only read on that queue; the capture session is shared solely
// with AVFoundation's preview layer, which is designed for this use.
private final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onSample: ((Int, Double?, Bool, Double) -> Void)?
    var onStatus: ((Int, CameraStatus) -> Void)?

    private let queue = DispatchQueue(label: "com.lumaframe.camera", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var device: AVCaptureDevice?
    private var activeInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var discoveredDevices: [AVCaptureDevice] = []
    private var routes: [LensRoute] = []
    private var selectedLensID = "wide"
    private var configured = false
    private var wantsRunning = false
    private var generation = 0
    private var interrupted = false
    private var sample: FrameSample?
    private var stableCount = 0
    private var previousEV: Double?
    private var lastPublish = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var minimumFrameTime = CMTime.invalid

    private struct LensRoute {
        let lens: CameraLens
        let device: AVCaptureDevice
        let deviceZoom: Double
    }

    private struct FrameSample {
        let buffer: CVPixelBuffer
        let ev100: Double
        let capturedAt: Date
        let zoom: Double
        let stable: Bool
        let lensTitle: String
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.wantsRunning else { return }
                self.interrupted = true
                self.clearSample()
                self.onStatus?(self.generation, .failed(CameraFailure.interrupted.localizedDescription))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.interrupted = self.session.isInterrupted
                self.clearSample()
                if self.wantsRunning {
                    self.recoverRunningSession()
                }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                             object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.queue.async {
                guard self.wantsRunning else { return }
                self.clearSample()
                self.interrupted = self.session.isInterrupted
                if error?.code == .mediaServicesWereReset && self.wantsRunning {
                    self.recoverRunningSession()
                } else {
                    let failure: CameraFailure = self.interrupted ? .interrupted : .configuration
                    self.onStatus?(self.generation, .failed(failure.localizedDescription))
                }
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start(generation: Int) async throws -> CameraLensSnapshot {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CameraLensSnapshot, Error>) in
            queue.async {
                self.generation = generation
                do {
                    try self.configureIfNeeded()
                    self.wantsRunning = true
                    self.clearSample()
                    try self.startRunningIfAvailable()
                    self.refreshRoutes()
                    continuation.resume(returning: self.lensSnapshot())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// isRunning does not mean the camera hardware is available during an interruption.
    /// Keep the running intent so interruptionEnded can complete the same request.
    private func startRunningIfAvailable() throws {
        interrupted = session.isInterrupted
        guard !interrupted else { throw CameraFailure.interrupted }
        guard configured else { throw CameraFailure.configuration }
        if !session.isRunning { session.startRunning() }
        interrupted = session.isInterrupted
        guard !interrupted else { throw CameraFailure.interrupted }
        guard session.isRunning else { throw CameraFailure.configuration }
    }

    private func recoverRunningSession() {
        do {
            try startRunningIfAvailable()
            onStatus?(generation, .ready)
        } catch {
            onStatus?(generation, .failed(error.localizedDescription))
        }
    }

    func stop(generation: Int) {
        queue.async {
            self.generation = generation
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            self.clearSample()
        }
    }

    func selectLens(_ id: String, generation: Int) async throws -> CameraLensSnapshot {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CameraLensSnapshot, Error>) in
            queue.async {
                self.generation = generation
                self.clearSample()
                guard self.wantsRunning, self.session.isRunning, !self.interrupted, !self.session.isInterrupted else {
                    continuation.resume(throwing: CameraFailure.interrupted)
                    return
                }
                guard let route = self.routes.first(where: { $0.lens.id == id }) else {
                    continuation.resume(throwing: CameraFailure.lensUnavailable)
                    return
                }
                do {
                    try self.switchInput(to: route)
                    self.refreshRoutes()
                    self.clearSample()
                    continuation.resume(returning: self.lensSnapshot())
                } catch {
                    self.clearSample()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func captureIfStable(calibrationEV: Double, mode: MeteringMode,
                         point: MeteringPoint, aspectRatio: Double) async throws -> CapturedReading? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.interrupted, !self.session.isInterrupted else {
                    continuation.resume(throwing: CameraFailure.interrupted)
                    return
                }
                guard self.wantsRunning, self.session.isRunning,
                      let sample = self.sample, sample.stable,
                      Date().timeIntervalSince(sample.capturedAt) < 0.5 else {
                    continuation.resume(returning: nil)
                    return
                }
                let ciImage = CIImage(cvPixelBuffer: sample.buffer)
                let crop = self.visibleRect(width: CVPixelBufferGetWidth(sample.buffer),
                                            height: CVPixelBufferGetHeight(sample.buffer), aspectRatio: aspectRatio)
                let measuredPoint = SpatialMetering.clampedPoint(point, aspectRatio: aspectRatio)
                guard let luminances = self.luminanceGrid(sample.buffer, crop: crop),
                      let correction = SpatialMetering.correction(luminances: luminances, columns: 48, rows: 64,
                          mode: mode, point: measuredPoint, aspectRatio: aspectRatio) else {
                    continuation.resume(throwing: CameraFailure.meteringUnavailable)
                    return
                }
                // Center crop is symmetric in the buffer's top-left coordinates and CI's
                // bottom-left coordinates. The returned reference uses exactly this crop.
                guard let cgImage = self.context.createCGImage(ciImage, from: crop) else {
                    continuation.resume(throwing: CameraFailure.rendering)
                    return
                }
                continuation.resume(returning: CapturedReading(
                    ev100: sample.ev100 + correction + calibrationEV,
                    image: UIImage(cgImage: cgImage),
                    capturedAt: sample.capturedAt,
                    zoom: sample.zoom,
                    lensTitle: sample.lensTitle,
                    meteringMode: mode,
                    meteringPoint: measuredPoint
                ))
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        discoveredDevices = AVCaptureDevice.DiscoverySession(deviceTypes:
            [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back).devices
        guard let device = discoveredDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else {
            throw CameraFailure.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { throw CameraFailure.configuration }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraFailure.configuration
        }
        session.addOutput(output)
        do {
            try configureDevice(device, zoom: 1)
        } catch {
            session.removeOutput(output)
            session.removeInput(input)
            throw error
        }
        self.device = device
        activeInput = input
        videoOutput = output
        selectedLensID = "wide"
        orientOutput()
        configured = true
    }

    private func configureDevice(_ device: AVCaptureDevice, zoom: Double) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let lower = device.minAvailableVideoZoomFactor
        let upper = device.maxAvailableVideoZoomFactor
        guard zoom.isFinite, CGFloat(zoom) >= lower, CGFloat(zoom) <= upper else {
            throw CameraFailure.lensUnavailable
        }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        // Sensor AE remains an exposure baseline. Spatial metering is computed separately
        // from the same frozen BGRA frame, not simulated by an AE point of interest.
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if device.activeFormat.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
        device.videoZoomFactor = CGFloat(zoom)
    }

    private func orientOutput() {
        if let connection = videoOutput?.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func switchInput(to route: LensRoute) throws {
        guard let oldInput = activeInput, let oldDevice = device else { throw CameraFailure.configuration }
        if oldDevice.uniqueID == route.device.uniqueID {
            do { try configureDevice(oldDevice, zoom: route.deviceZoom) }
            catch { throw CameraFailure.lensSwitch }
            selectedLensID = route.lens.id
            return
        }
        let nextInput: AVCaptureDeviceInput
        do { nextInput = try AVCaptureDeviceInput(device: route.device) }
        catch { throw CameraFailure.lensSwitch }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.removeInput(oldInput)
        do {
            guard session.canAddInput(nextInput) else { throw CameraFailure.lensSwitch }
            session.addInput(nextInput)
            try configureDevice(route.device, zoom: route.deviceZoom)
            device = route.device
            activeInput = nextInput
            selectedLensID = route.lens.id
            orientOutput()
        } catch {
            if session.inputs.contains(where: { $0 === nextInput }) { session.removeInput(nextInput) }
            guard session.canAddInput(oldInput) else {
                // Leave a clean, retryable configuration if the OS cannot restore the input.
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                device = nil; activeInput = nil; videoOutput = nil; configured = false
                throw CameraFailure.configuration
            }
            session.addInput(oldInput)
            orientOutput()
            throw CameraFailure.lensSwitch
        }
    }

    private func refreshRoutes() {
        guard let wide = discoveredDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return }
        var next: [LensRoute] = []
        var counts: [String: Int] = [:]
        for camera in discoveredDevices {
            let baseID = camera.deviceType == .builtInWideAngleCamera ? "wide" :
                (camera.deviceType == .builtInUltraWideCamera ? "ultra" : "tele")
            let kind = baseID == "wide" ? "广角" : (baseID == "ultra" ? "超广角" : "长焦")
            counts[baseID, default: 0] += 1
            let id = counts[baseID] == 1 ? baseID : "\(baseID)\(counts[baseID]!)"
            let focal = nominalFocalLength(camera)
            let wideFocal = nominalFocalLength(wide)
            let field = Double(camera.activeFormat.videoFieldOfView)
            let wideField = Double(wide.activeFormat.videoFieldOfView)
            let ratio: Double
            var approximate = false
            if camera.uniqueID == wide.uniqueID { ratio = 1 }
            else if let focal, let wideFocal { ratio = focal / wideFocal }
            else if field > 0, field < 180, wideField > 0, wideField < 180 {
                ratio = tan(wideField * .pi / 360) / tan(field * .pi / 360)
                approximate = true
            } else {
                // No guessed focal lengths or fabricated relative zoom for unknown formats.
                continue
            }
            guard ratio.isFinite, ratio > 0 else { continue }
            let label = ratio.formatted(.number.precision(.fractionLength(0...1))) + "×"
            let focalText = focal.map { " · \(Int($0.rounded()))mm（设备标称）" } ?? ""
            let descriptor = CameraLens(id: id, title: (approximate ? "约" : "") + label,
                detail: "\(kind) · 硬件镜头\(focalText)", zoom: ratio)
            next.append(LensRoute(lens: descriptor, device: camera, deviceZoom: 1))
        }
        if wide.maxAvailableVideoZoomFactor >= 2,
           selectedLensID == "crop2x" || !next.contains(where: { $0.lens.id != "wide" && abs($0.lens.zoom - 2) < 0.15 }) {
            next.append(LensRoute(lens: CameraLens(id: "crop2x", title: "2×裁切", detail: "广角数码裁切", zoom: 2),
                                  device: wide, deviceZoom: 2))
        }
        routes = next.sorted { $0.lens.zoom < $1.lens.zoom }
    }

    private func nominalFocalLength(_ device: AVCaptureDevice) -> Double? {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let value = Double(device.nominalFocalLengthIn35mmFilm)
            if value.isFinite, value > 0 { return value }
        }
        #endif
        return nil
    }

    private func lensSnapshot() -> CameraLensSnapshot {
        CameraLensSnapshot(lenses: routes.map(\.lens), selectedID: selectedLensID, zoom: relativeZoom)
    }

    private var relativeZoom: Double {
        guard let route = routes.first(where: { $0.lens.id == selectedLensID }), let device else { return 1 }
        return route.lens.zoom * Double(device.videoZoomFactor) / route.deviceZoom
    }

    private var lensTitle: String {
        guard let route = routes.first(where: { $0.lens.id == selectedLensID }) else { return "广角" }
        return "\(route.lens.title) · \(route.lens.detail)"
    }

    private func visibleRect(width: Int, height: Int, aspectRatio: Double) -> CGRect {
        let w = min(Double(width), Double(height) * aspectRatio)
        let h = min(Double(height), Double(width) / aspectRatio)
        // Whole-pixel, symmetric bounds keep the sampler and exported reference aligned
        // in both the buffer's top-left and Core Image's bottom-left coordinates.
        let insetX = Int(((Double(width) - w) / 2).rounded(.down))
        let insetY = Int(((Double(height) - h) / 2).rounded(.down))
        return CGRect(x: insetX, y: insetY, width: width - 2 * insetX, height: height - 2 * insetY)
    }

    private func luminanceGrid(_ buffer: CVPixelBuffer, crop: CGRect) -> [Double]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                         count: CVPixelBufferGetDataSize(buffer))
        return LuminanceSampler.grid(bgra: pixels, width: width, height: height, bytesPerRow: stride,
            crop: PixelCrop(x: Int(crop.minX), y: Int(crop.minY), width: Int(crop.width), height: Int(crop.height)),
            columns: 48, rows: 64)
    }

    private func clearSample() {
        sample = nil
        stableCount = 0
        previousEV = nil
        lastPublish = .distantPast
        minimumFrameTime = CMClockGetTime(CMClockGetHostTimeClock())
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard wantsRunning, !interrupted, !session.isInterrupted, let device,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Check sensor presentation time, not merely callback arrival time. This rejects
        // an old queued frame after a long configuration or rendering operation.
        let hostClock = CMClockGetHostTimeClock()
        let sourceClock = session.synchronizationClock ?? hostClock
        let presentationTime = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                                 from: sourceClock, to: hostClock)
        let frameAge = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(hostClock), presentationTime))
        guard frameAge.isFinite, frameAge >= -0.1, frameAge < 0.5 else { clearSample(); return }
        guard !minimumFrameTime.isValid || CMTimeCompare(presentationTime, minimumFrameTime) >= 0 else { return }

        // Prefer per-frame metadata when supplied by the hardware. Some devices omit it;
        // in that case the AE-stability gate bounds the device-value / frame-time mismatch.
        let metadata = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                         target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any]
        let exif = metadata?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let aperture = (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? Double(device.lensAperture)
        let shutter = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? CMTimeGetSeconds(device.exposureDuration)
        let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        let iso = isoValues?.first?.doubleValue ?? Double(device.iso)
        guard aperture.isFinite, shutter.isFinite, iso.isFinite,
              aperture > 0, shutter > 0, iso > 0 else { clearSample(); return }
        let ev = log2(aperture * aperture / shutter) - log2(iso / 100)
        let offset = Double(device.exposureTargetOffset)
        let exposureStable = !device.isAdjustingExposure && offset.isFinite && abs(offset) < 0.3
        let similar = previousEV.map { abs($0 - ev) < 0.15 } ?? false
        stableCount = exposureStable && similar ? stableCount + 1 : 0
        previousEV = ev
        let stable = stableCount >= 4
        let now = Date()
        sample = FrameSample(buffer: buffer, ev100: ev, capturedAt: now.addingTimeInterval(-max(0, frameAge)),
                             zoom: relativeZoom, stable: stable, lensTitle: lensTitle)
        if now.timeIntervalSince(lastPublish) >= 0.2 {
            lastPublish = now
            onSample?(generation, ev, stable, relativeZoom)
        }
    }
}
