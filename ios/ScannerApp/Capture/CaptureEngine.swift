import Foundation
import UIKit
import ARKit
import AVFoundation
import CoreMotion
import CoreImage
import ImageIO
import Darwin
import ScannerStreamingCore

/// Hardware access is opt-in through start(). Merely opening the app never starts ARKit or motion.
/// Incoming ARFrames are bounded to three; preview callbacks receive owned bytes, never ARFrame.
final class CaptureEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Snapshot: Sendable {
        let sessionID: UUID
        let segment: UInt32
        let elapsed: Double
        let frames: UInt64
        let depthFrames: UInt64
        let stills: UInt64
        let freeBytes: UInt64
        let droppedFrames: UInt64
        let recording: Bool
        let message: String?
    }
    let session = ARSession()
    var onStatus: (@Sendable (Snapshot) -> Void)?
    var onPreview: (@Sendable (UUID, UInt32, UInt64, Data) -> Void)?
    var onSegment: (@Sendable (UUID, UInt32, String, UInt64, Double) -> Void)?
    var onClosed: (@Sendable (OriginalStore) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var onPreviewFailure: (@Sendable (String) -> Void)?
    private let parent: URL
    private let capture = DispatchQueue(label: "scanner3d.capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let incoming = DispatchQueue(label: "scanner3d.arkit", qos: .userInitiated)
    private let frameSlots = DispatchSemaphore(value: 3)
    private let motionSlots = DispatchSemaphore(value: 16)
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    private let gate = NSLock()
    private var running = false
    private var generation: UUID?
    private var dropped: UInt64 = 0
    private var recorder: CaptureRecorder?
    private var lastPreview: Double = -1
    private var previewSequence: UInt64 = 0
    private var lastStill: Double = -1
    private var stillInFlight = false
    private var stillsEnabled = false
    private var previewWidth = 640, previewHeight = 480
    private var previewQuality = 0.75, depthScale = 0.001
    private var previewFloatDepth = false, previewConfidence = true
    private var previewEncodingEnabled = true
    private var previewAllowed = false
    private var lastStatus: Double = -1
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(parent: URL) {
        self.parent = parent
        super.init()
        session.delegate = self; session.delegateQueue = incoming
    }

    var isRunning: Bool { gate.lock(); defer { gate.unlock() }; return running }
    private func setRunning(_ value: Bool) { gate.lock(); running = value; gate.unlock() }
    private func captureID() -> UUID? { gate.lock(); defer { gate.unlock() }; return running ? generation : nil }
    private func noteDrop() { gate.lock(); dropped += 1; gate.unlock() }
    private func droppedCount() -> UInt64 { gate.lock(); defer { gate.unlock() }; return dropped }

    func configurePreview(_ profile: HelloResponse.PreviewProfile) {
        capture.async { [self] in
            previewWidth = profile.rgbWidth; previewHeight = profile.rgbHeight
            previewQuality = profile.rgbQuality; depthScale = profile.depthScaleMPerUnit
            previewFloatDepth = profile.depthCodec == "f32"; previewConfidence = profile.confidence
            previewEncodingEnabled = true
        }
    }
    func allowPreview(_ enabled: Bool) { capture.async { [self] in previewAllowed = enabled } }

    func currentStore() async -> OriginalStore? {
        await withCheckedContinuation { continuation in capture.async { [self] in continuation.resume(returning: recorder?.store) } }
    }

    func start() async throws -> UUID {
        guard !isRunning, ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
              motion.isAccelerometerAvailable, motion.isGyroAvailable else {
            throw OriginalStore.Failure.io("Capture is already running or this device lacks required sensors")
        }
        var permitted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if !permitted { permitted = await AVCaptureDevice.requestAccess(for: .video) }
        guard permitted else { throw OriginalStore.Failure.io("Camera permission is required") }
        let os = await MainActor.run { UIDevice.current.systemVersion }
        return try await withCheckedThrowingContinuation { continuation in
            capture.async { [self] in
                do {
                    guard recorder == nil, !isRunning else { throw OriginalStore.Failure.io("Previous capture has not closed") }
                    let configuration = ARWorldTrackingConfiguration()
                    configuration.frameSemantics = [.sceneDepth]
                    configuration.worldAlignment = .gravity
                    configuration.isAutoFocusEnabled = true
                    stillsEnabled = false
                    if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                        configuration.videoFormat = format; stillsEnabled = true
                    }
                    let format = configuration.videoFormat
                    let id = UUID()
                    let store = try OriginalStore(parent: parent, sessionID: id, create: true)
                    let now = ProcessInfo.processInfo.systemUptime
                    recorder = try CaptureRecorder(store: store, width: Int(format.imageResolution.width),
                        height: Int(format.imageResolution.height), fps: format.framesPerSecond, stills: stillsEnabled,
                        model: Self.modelIdentifier(), os: os,
                        sourceRevision: Bundle.main.object(forInfoDictionaryKey: "ScannerSourceRevision") as? String ?? "unknown", time: now)
                    lastPreview = -1; lastStill = -1; lastStatus = -1; previewSequence = 0; stillInFlight = false; previewEncodingEnabled = true
                    gate.lock(); dropped = 0; generation = id; running = true; gate.unlock()
                    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                    startMotion()
                    onSegment?(id, 0, "session_start", 0, now)
                    continuation.resume(returning: id)
                } catch { setRunning(false); recorder = nil; continuation.resume(throwing: error) }
            }
        }
    }

    func stop(reason: String = "user") async throws {
        setRunning(false)
        session.pause(); motion.stopAccelerometerUpdates(); motion.stopGyroUpdates()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capture.async { [self] in
                guard let recorder else { continuation.resume(); return }
                do {
                    let now = ProcessInfo.processInfo.systemUptime
                    try recorder.finish(reason: reason, interrupted: reason != "user", time: now)
                    publish(recorder, time: now, message: "Saved on iPhone; PC completion still needs confirmation")
                    self.recorder = nil
                    onClosed?(recorder.store)
                    continuation.resume()
                } catch {
                    // Keep incomplete files on disk and do not emit onClosed/final upload eligibility.
                    self.recorder = nil; onFailure?(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let id = captureID() else { return }
        guard frameSlots.wait(timeout: .now()) == .success else { noteDrop(); return }
        capture.async { [self] in
            defer { frameSlots.signal() }
            guard let recorder, recorder.store.sessionID == id, !recorder.closed else { return }
            do {
                let free = freeBytes()
                // Stop conservatively before exhausting filesystem space; no claim that 512 MiB
                // predicts exact remaining recording time. Pending video still needs room to close.
                if free < 512 * 1024 * 1024 { requestStop("storage_low"); return }
                let thermal = Self.thermal()
                if thermal == "critical" { try recorder.thermal(thermal, time: frame.timestamp); requestStop("thermal"); return }
                if let fid = try recorder.append(frame) {
                    if previewAllowed, previewEncodingEnabled, frame.timestamp - lastPreview >= 0.2 {
                        lastPreview = frame.timestamp
                        do {
                            if let bytes = try preview(frame, recorder: recorder, frameID: fid) {
                                onPreview?(recorder.store.sessionID, recorder.segment, previewSequence, bytes); previewSequence += 1
                            }
                        } catch {
                            // A droppable PC preview failure must never stop local original recording.
                            previewEncodingEnabled = false
                            try recorder.event("preview_encode_error", detail: error.localizedDescription, time: frame.timestamp)
                            onPreviewFailure?(error.localizedDescription)
                        }
                    }
                    if stillsEnabled, !stillInFlight, frame.timestamp - lastStill >= 2,
                       CaptureValues.tracking(frame.camera).state == "normal" {
                        requestStill(recorder: recorder, at: frame.timestamp)
                    }
                }
                if frame.timestamp - lastStatus >= 0.5 {
                    lastStatus = frame.timestamp; try recorder.thermal(thermal, time: frame.timestamp)
                    publish(recorder, time: frame.timestamp, message: nil)
                }
            } catch { onFailure?(error.localizedDescription); requestStop("error") }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        capture.async { [self] in
            do { try recorder?.event("interruption", detail: "began", time: ProcessInfo.processInfo.systemUptime) }
            catch { onFailure?(error.localizedDescription); requestStop("error") }
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        capture.async { [self] in
            guard isRunning, let recorder else { return }
            do {
                let now = ProcessInfo.processInfo.systemUptime
                try recorder.boundary(reason: "interruption", time: now)
                onSegment?(recorder.store.sessionID, recorder.segment, "interruption", recorder.nextFrame, now)
            } catch { onFailure?(error.localizedDescription); requestStop("error") }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?(error.localizedDescription); requestStop("error")
    }

    private func startMotion() {
        motion.accelerometerUpdateInterval = 0.01; motion.gyroUpdateInterval = 0.01
        motion.startAccelerometerUpdates(to: motionQueue) { [weak self] sample, error in
            guard let self, let id = self.captureID() else { return }
            if let error { self.onFailure?(error.localizedDescription); self.requestStop("error"); return }
            guard let sample, self.motionSlots.wait(timeout: .now()) == .success else { return }
            self.capture.async {
                defer { self.motionSlots.signal() }
                guard self.recorder?.store.sessionID == id else { return }
                do { try self.recorder?.acceleration(sample) }
                catch { self.onFailure?(error.localizedDescription); self.requestStop("error") }
            }
        }
        motion.startGyroUpdates(to: motionQueue) { [weak self] sample, error in
            guard let self, let id = self.captureID() else { return }
            if let error { self.onFailure?(error.localizedDescription); self.requestStop("error"); return }
            guard let sample, self.motionSlots.wait(timeout: .now()) == .success else { return }
            self.capture.async {
                defer { self.motionSlots.signal() }
                guard self.recorder?.store.sessionID == id else { return }
                do { try self.recorder?.rotation(sample) }
                catch { self.onFailure?(error.localizedDescription); self.requestStop("error") }
            }
        }
    }

    private func requestStop(_ reason: String) {
        guard isRunning else { return }
        setRunning(false)
        Task { try? await stop(reason: reason) }
    }

    private func requestStill(recorder: CaptureRecorder, at time: Double) {
        stillInFlight = true; lastStill = time
        let id = recorder.store.sessionID, seg = recorder.segment
        session.captureHighResolutionFrame { [weak self] frame, error in
            guard let self else { return }
            self.capture.async {
                guard self.isRunning, let current = self.recorder, current.store.sessionID == id else { return }
                self.stillInFlight = false
                do {
                    if let error { try current.event("still_error", detail: error.localizedDescription, time: ProcessInfo.processInfo.systemUptime) }
                    else if let frame { try current.still(frame, requestedSegment: seg) }
                } catch { self.onFailure?(error.localizedDescription); self.requestStop("error") }
            }
        }
    }

    private func preview(_ frame: ARFrame, recorder: CaptureRecorder, frameID: UInt64) throws -> Data? {
        guard onPreview != nil else { return nil }
        let source = frame.capturedImage
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        let sx = Double(previewWidth) / Double(w), sy = Double(previewHeight) / Double(h)
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = imageContext.jpegRepresentation(of: image, colorSpace: space,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): previewQuality]) else {
            throw OriginalStore.Failure.io("Preview JPEG")
        }
        var depthSection: DepthSection?, confidenceBytes: Data?
        if let depth = frame.sceneDepth, let confidence = depth.confidenceMap {
            let dw = CVPixelBufferGetWidth(depth.depthMap), dh = CVPixelBufferGetHeight(depth.depthMap)
            let bytes = try CaptureValues.packed(depth.depthMap, format: kCVPixelFormatType_DepthFloat32, bytesPerPixel: 4)
            // iPhone hardware is little-endian. Decode without assuming Data's alignment.
            let floats: [Float] = stride(from: 0, to: bytes.count, by: 4).map { offset in
                let bits = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
                return Float(bitPattern: bits)
            }
            let previewBytes: Data
            if previewFloatDepth { previewBytes = bytes } else { previewBytes = try DepthSection.quantize(floats, scale: depthScale) }
            depthSection = DepthSection(codec: previewFloatDepth ? .float32 : .uint16,
                bytes: previewBytes,
                intrinsics: CaptureValues.intrinsics(frame, width: dw, height: dh), scaleMetersPerUnit: previewFloatDepth ? 1 : Float(depthScale))
            if previewConfidence { confidenceBytes = try CaptureValues.packed(confidence, format: kCVPixelFormatType_OneComponent8, bytesPerPixel: 1) }
        }
        let tracking = CaptureValues.tracking(frame.camera)
        return try PacketEncoder.preview(PreviewFrame(sessionID: recorder.store.sessionID, segment: recorder.segment,
            frameID: frameID, previewSequence: previewSequence, deviceTime: frame.timestamp,
            sentTime: ProcessInfo.processInfo.systemUptime, cameraToWorld: CaptureValues.pose(frame.camera),
            trackingState: tracking.stateByte, trackingReason: tracking.reasonByte,
            source: CaptureValues.intrinsics(frame, width: w, height: h),
            rgb: RGBSection(jpeg: jpeg, intrinsics: CaptureValues.intrinsics(frame, width: previewWidth, height: previewHeight)),
            depth: depthSection, confidence: confidenceBytes))
    }

    private func publish(_ recorder: CaptureRecorder, time: Double, message: String?) {
        onStatus?(Snapshot(sessionID: recorder.store.sessionID, segment: recorder.segment, elapsed: max(0, time - recorder.started),
            frames: recorder.savedFrames, depthFrames: recorder.depthFrames, stills: recorder.stillCount,
            freeBytes: freeBytes(), droppedFrames: droppedCount(), recording: isRunning, message: message))
    }

    private func freeBytes() -> UInt64 {
        let resource = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, resource?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "serious"
        }
    }

    static func modelIdentifier() -> String {
        var value = utsname(); uname(&value)
        let capacity = MemoryLayout.size(ofValue: value.machine)
        return withUnsafePointer(to: &value.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}
