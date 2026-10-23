import Foundation
import ARKit
import CoreVideo
import ScannerStreamingCore
import simd

enum CaptureValues {
    static let conventions: [String: String] = [
        "length_unit": "m", "accel_unit": "g", "gyro_unit": "rad/s", "time": "device_uptime_s",
        "world": "arkit_right_handed_y_up", "camera_axes": "arkit_x_right_y_up_z_back",
        "pose": "camera_to_world", "matrix_layout": "row_major_column_vectors",
        "image_orientation": "sensor_native_landscape", "imu_axes": "coremotion_device", "depth": "z_depth_f32_m"
    ]
    static let frameHeader = ["frame_id", "segment", "t_device_s", "tracking_state", "tracking_reason"] +
        (0..<4).flatMap { row in (0..<4).map { col in "m\(row)\(col)" } } +
        ["rgb_width", "rgb_height", "fx", "fy", "cx", "cy", "video_file", "video_frame_index", "has_depth",
         "depth_width", "depth_height", "dfx", "dfy", "dcx", "dcy", "exposure_duration_s", "exposure_offset_ev"]

    static func utc(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    /// SIMD stores columns; wire/storage contracts explicitly require row-major column-vector matrices.
    static func pose(_ camera: ARCamera) -> [Float] {
        rowMajor(camera.transform)
    }
    static func rowMajor(_ matrix: simd_float4x4) -> [Float] {
        (0..<4).flatMap { row in (0..<4).map { col in matrix[col][row] } }
    }

    static func intrinsics(_ frame: ARFrame, width: Int, height: Int) -> Intrinsics {
        let k = frame.camera.intrinsics
        let source = frame.camera.imageResolution
        let sx = Float(width) / Float(source.width), sy = Float(height) / Float(source.height)
        return Intrinsics(width: width, height: height, fx: k[0][0] * sx, fy: k[1][1] * sy,
                          cx: k[2][0] * sx, cy: k[2][1] * sy)
    }

    static func intrinsicObject(_ k: Intrinsics) -> [String: Any] {
        ["width": k.width, "height": k.height, "fx": k.fx, "fy": k.fy, "cx": k.cx, "cy": k.cy]
    }

    static func tracking(_ camera: ARCamera) -> (state: String, reason: String, stateByte: UInt8, reasonByte: UInt8) {
        switch camera.trackingState {
        case .normal: return ("normal", "none", 2, 0)
        case .notAvailable: return ("not_available", "none", 0, 0)
        case .limited(let reason):
            switch reason {
            case .initializing: return ("limited", "initializing", 1, 1)
            case .excessiveMotion: return ("limited", "excessive_motion", 1, 2)
            case .insufficientFeatures: return ("limited", "insufficient_features", 1, 3)
            case .relocalizing: return ("limited", "relocalizing", 1, 4)
            @unknown default: return ("limited", "unknown", 1, 255)
            }
        }
    }

    /// Copy active bytes only, excluding CoreVideo row padding. No depth scale/axis/value conversion.
    static func packed(_ buffer: CVPixelBuffer, format: OSType, bytesPerPixel: Int) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(buffer) == format,
              !CVPixelBufferIsPlanar(buffer), CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw OriginalStore.Failure.io("Unexpected or inaccessible depth/confidence buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), active = width * bytesPerPixel
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= active else {
            throw OriginalStore.Failure.io("Invalid pixel row")
        }
        var output = Data(capacity: active * height)
        for y in 0..<height { output.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: active) }
        return output
    }
}

/// Actual sample counts over two-second windows, not requested rates. Finish includes the last partial
/// window; min/max describe windows, mean describes total samples divided by actual elapsed time.
struct MeasuredRate {
    private var first: Double?
    private var last: Double?
    private var window: Double?
    private var windowCount = 0
    private var intervals: [Double] = []
    private var count = 0

    mutating func add(_ time: Double) {
        guard time.isFinite, time >= 0, last.map({ time > $0 }) ?? true else { return }
        if first == nil { first = time; window = time }
        if let start = window, time - start >= 2 {
            intervals.append(Double(windowCount) / (time - start)); window = time; windowCount = 0
        }
        last = time; count += 1; windowCount += 1
    }

    func stats(until end: Double) -> [String: Double] {
        guard let first, let window, end > first else { return ["mean": 0, "min": 0, "max": 0] }
        var windows = intervals
        if end > window { windows.append(Double(windowCount) / (end - window)) }
        return ["mean": Double(count) / (end - first), "min": windows.min() ?? 0, "max": windows.max() ?? 0]
    }

    /// Median depth (m) of the centre third of the depth map, where the part usually is: medium/high confidence,
    /// finite and positive values only, sampled every 4th pixel. nil if too few samples.
    static func centerDepth(_ depth: CVPixelBuffer, confidence: CVPixelBuffer?) -> Double? {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        var conf: UnsafeMutableRawPointer?, confStride = 0
        if let confidence, CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidence) == CVPixelBufferGetWidth(depth), CVPixelBufferGetHeight(confidence) == CVPixelBufferGetHeight(depth),
           CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess {
            conf = CVPixelBufferGetBaseAddress(confidence); confStride = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if conf != nil, let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth), stride = CVPixelBufferGetBytesPerRow(depth)
        var values: [Float] = []
        values.reserveCapacity((w / 12 + 1) * (h / 12 + 1))
        for y in Swift.stride(from: h / 3, to: 2 * h / 3, by: 4) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            let crow = conf?.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: w / 3, to: 2 * w / 3, by: 4) {
                let z = row[x]
                if z.isFinite, z > 0, (crow.map { $0[x] >= 1 } ?? true) { values.append(z) }
            }
        }
        guard values.count >= 8 else { return nil }
        values.sort()
        return Double(values[values.count / 2])
    }

    static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        return bytes.allSatisfy { (32...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
}

/// On-phone scan guidance from ARKit alone (ui/README.md, iPhone screens 3-4): a few short instructions mapped from the
/// tracking state, light, distance to the part, speed and heat. A condition shows only after it has held for
/// `showAfter` and clears only after it has been gone for `clearAfter`, so the card never flickers. The PC's coverage
/// tips ("scan the back-right underside") come separately over the link and rank below these.
struct GuidanceTracker: Sendable {
    enum Level: String, Sendable { case info, warn }
    struct Tip: Equatable, Sendable {
        let key: String
        let text: String
        let level: Level
    }
    struct Input {
        var time: Double
        var trackingState: String
        var trackingReason: String
        var ambientIntensity: Double?          // ARLightEstimate lumens; about 1000 is a well-lit room
        var centerDepthM: Double?
        var position: SIMD3<Float>
        var thermal: String
        var autoLight = false                  // torch is under auto control: the dark tip waits for it to reach max
        var torchAtMax = false
    }
    static let showAfter = 0.6, clearAfter = 1.0
    static let darkLumens = 250.0, tooCloseM = 0.20, tooFarM = 0.50, fastMPerS = 0.35

    private(set) var shown: Tip?
    private var pending: (key: String?, since: Double)?
    private var last: (position: SIMD3<Float>, time: Double)?
    private(set) var speed = 0.0                // smoothed camera speed, m/s
    private(set) var light: Double?             // smoothed ambient intensity

    /// The tip for this instant, before smoothing over time. Highest priority first.
    /// With auto light on, the torch answers darkness first; only a scene still dark at full torch asks for a lamp.
    static func condition(state: String, reason: String, light: Double?, depth: Double?, speed: Double, thermal: String,
                          autoLight: Bool = false, torchAtMax: Bool = false) -> Tip? {
        if state == "not_available" { return Tip(key: "tracking_lost", text: "Point the phone back at the part", level: .warn) }
        if reason == "relocalizing" { return Tip(key: "relocalizing", text: "Point back at where you started", level: .warn) }
        if reason == "excessive_motion" || speed > fastMPerS { return Tip(key: "too_fast", text: "Move slower", level: .warn) }
        if reason == "insufficient_features" {
            return Tip(key: "featureless", text: "Point back at the part · more light or texture helps", level: .warn)
        }
        if let light, light < darkLumens {
            if !autoLight { return Tip(key: "dark", text: "More light needed · turn on a lamp", level: .warn) }
            if torchAtMax { return Tip(key: "dark", text: "Still too dark · add a lamp", level: .warn) }
        }
        if let depth, depth < tooCloseM { return Tip(key: "too_close", text: "Move back a little · about 30 cm away", level: .warn) }
        if let depth, depth > tooFarM { return Tip(key: "too_far", text: "Move closer · about 30 cm away", level: .warn) }
        if thermal == "serious" { return Tip(key: "warm", text: "iPhone is getting warm · pause soon", level: .warn) }
        if reason == "initializing" { return Tip(key: "initializing", text: "Hold steady for a moment", level: .info) }
        return nil
    }

    mutating func update(_ input: Input) -> Tip? {
        if let last, input.time > last.time {
            let dt = min(input.time - last.time, 0.5)
            let v = Double(simd_distance(input.position, last.position)) / max(input.time - last.time, 1e-3)
            speed += (v - speed) * dt / (0.3 + dt)
            if let value = input.ambientIntensity { light = light.map { $0 + (value - $0) * dt / (1.0 + dt) } ?? value }
        } else if last == nil {
            light = input.ambientIntensity
        }
        last = (input.position, input.time)
        let raw = Self.condition(state: input.trackingState, reason: input.trackingReason, light: light,
                                 depth: input.centerDepthM, speed: speed, thermal: input.thermal,
                                 autoLight: input.autoLight, torchAtMax: input.torchAtMax)
        if raw?.key == shown?.key { shown = raw; pending = nil; return shown }
        let since: Double
        if let p = pending, p.key == raw?.key { since = p.since } else { since = input.time; pending = (raw?.key, input.time) }
        if input.time - since >= (raw == nil ? Self.clearAfter : Self.showAfter) { shown = raw; pending = nil }
        return shown
    }
}

/// Auto light: a closed-loop torch level for dark scenes. The torch's own light raises the measured intensity, so the
/// level is not mapped from intensity but stepped: every `stepEvery` it goes up `step` while the smoothed light is below
/// `lowLumens`, down while above `highLumens`, and holds in the band between. Heat or auto light off force it to 0 (off).
/// It holds while tracking is unavailable, when the light estimate means little.
struct TorchController: Sendable {
    struct Input {
        var time: Double
        var ambientIntensity: Double?          // ARLightEstimate lumens, torch light included
        var thermal: String
        var trackingState: String
        var enabled = true
    }
    static let lowLumens = 400.0, highLumens = 900.0, stepEvery = 0.5
    static let step: Float = 0.15, maxLevel: Float = 1.0

    private(set) var level: Float = 0           // 0 is off
    private(set) var changed = false            // level changed in the last update: only then touch the hardware
    private(set) var forcedOff = false          // held off by heat or by auto light being off
    private(set) var light: Double?             // smoothed ambient intensity, about 1 s time constant
    private var lastTime: Double?
    private var lastStep = -Double.infinity

    var atMax: Bool { level >= Self.maxLevel }

    /// Returns whether the level changed.
    @discardableResult
    mutating func update(_ input: Input) -> Bool {
        let before = level
        if let lastTime, input.time > lastTime {
            let dt = min(input.time - lastTime, 0.5)
            if let value = input.ambientIntensity { light = light.map { $0 + (value - $0) * dt / (1.0 + dt) } ?? value }
            self.lastTime = input.time
        } else if lastTime == nil {
            light = input.ambientIntensity; lastTime = input.time
        }
        forcedOff = !input.enabled || input.thermal == "serious" || input.thermal == "critical"
        if forcedOff {
            level = 0
        } else if input.time - lastStep >= Self.stepEvery, input.trackingState != "not_available", let light {
            lastStep = input.time
            if light < Self.lowLumens { level = min(Self.maxLevel, level + Self.step) }
            else if light > Self.highLumens { level = max(0, level - Self.step) }
            if level < 0.01 { level = 0 }
        }
        changed = level != before
        return changed
    }
}
