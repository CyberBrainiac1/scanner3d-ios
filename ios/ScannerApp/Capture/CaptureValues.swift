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
}
