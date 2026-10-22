import Foundation
import ARKit
import CoreMotion
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import ScannerStreamingCore

/// The utility capture queue is the sole owner. Follows Stray's ARFrame/video/depth separation while
/// retaining native float depth, per-sample motion timestamps and a durable closed-file catalog.
final class CaptureRecorder {
    let store: OriginalStore
    let configuration: [String: Any]
    let started: Double
    private(set) var segment: UInt32 = 0
    private(set) var nextFrame: UInt64 = 0
    private(set) var savedFrames: UInt64 = 0
    private(set) var depthFrames: UInt64 = 0
    private(set) var stillCount: UInt64 = 0
    private(set) var closed = false
    private var lastSavedFrame: UInt64?
    private var lastTime: Double = -1
    private var recentFrames: [(id: UInt64, time: Double)] = []
    private var segmentStarted: Double
    private var movie: MoviePart?
    private var moviePart = 0
    private let frames: RotatingCSV
    private let accel: RotatingCSV
    private let gyro: RotatingCSV
    private let events: RotatingCSV
    private var segments: [[String]] = []
    private var frameRate = MeasuredRate(), depthRate = MeasuredRate()
    private var accelRate = MeasuredRate(), gyroRate = MeasuredRate()
    private var thermalMax = "nominal"
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(store: OriginalStore, width: Int, height: Int, fps: Int, stills: Bool,
         model: String, os: String, sourceRevision: String, time: Double) throws {
        self.store = store; started = time; segmentStarted = time
        configuration = [
            "video": ["width": width, "height": height, "fps": fps, "codec": "hevc"],
            "depth": ["width": 256, "height": 192, "source": "scene_depth", "every_n_frames": 2],
            "confidence": true,
            "stills": ["enabled": stills, "width": NSNull(), "height": NSNull(), "codec": "jpeg", "quality": 0.95],
            "imu": ["accel_requested_hz": 100, "gyro_requested_hz": 100, "device_motion_requested_hz": NSNull()],
            "intrinsics_scaling": "multiplicative"
        ]
        frames = RotatingCSV(store: store, prefix: "frames", kind: "frames_csv", header: CaptureValues.frameHeader)
        accel = RotatingCSV(store: store, prefix: "motion/accel", kind: "accel_csv", header: ["t_device_s", "ax_g", "ay_g", "az_g"])
        gyro = RotatingCSV(store: store, prefix: "motion/gyro", kind: "gyro_csv", header: ["t_device_s", "wx_rad_s", "wy_rad_s", "wz_rad_s"])
        events = RotatingCSV(store: store, prefix: "events", kind: "events_csv", header: ["t_device_s", "event", "detail"])
        let metadata: [String: Any] = [
            "format": "s3d-session", "format_version": "1.0", "session_id": store.sessionID.uuidString.lowercased(),
            "profile": "tabletop", "started_at": CaptureValues.utc(), "t_device_start_s": time,
            "device": ["model_identifier": model, "os_version": os, "display_name": "Scan iPhone"],
            "app": ["name": "scanner3d-ios", "version": "0.2.0", "build": "1", "source_revision": sourceRevision],
            "capture": configuration, "conventions": CaptureValues.conventions
        ]
        try store.commit(CaptureValues.json(metadata), path: "session.json", kind: "session_meta")
        segments.append(["0", "seg-0", "session_start", "", "0", String(time)])
    }

    /// Returns a saved frame ID, or nil on video encoder backpressure. No metadata refers to a missing
    /// video sample. Frame IDs can have gaps; video_frame_index is the actual successful append index.
    func append(_ frame: ARFrame) throws -> UInt64? {
        guard !closed, frame.timestamp >= segmentStarted, frame.timestamp > lastTime else { return nil }
        lastTime = frame.timestamp
        let fid = nextFrame; nextFrame += 1
        let buffer = frame.capturedImage
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        if let movie, frame.timestamp - movie.openedAt >= 60 { try closeMovie() }
        if movie == nil { movie = try MoviePart(store: store, segment: segment, part: moviePart,
                                               width: w, height: h, time: frame.timestamp) }
        guard let movie, let videoIndex = try movie.append(buffer, time: frame.timestamp) else {
            try event("video_backpressure", detail: "frame_id=\(fid)", time: frame.timestamp)
            return nil
        }
        let tracking = CaptureValues.tracking(frame.camera)
        let rgbK = CaptureValues.intrinsics(frame, width: w, height: h)
        var depthK: Intrinsics?
        if fid % 2 == 0, let depth = frame.sceneDepth, let confidence = depth.confidenceMap {
            let dw = CVPixelBufferGetWidth(depth.depthMap), dh = CVPixelBufferGetHeight(depth.depthMap)
            guard dw == 256, dh == 192, CVPixelBufferGetWidth(confidence) == dw,
                  CVPixelBufferGetHeight(confidence) == dh else { throw OriginalStore.Failure.io("Unsupported depth dimensions") }
            let bytes = try CaptureValues.packed(depth.depthMap, format: kCVPixelFormatType_DepthFloat32, bytesPerPixel: 4)
            let conf = try CaptureValues.packed(confidence, format: kCVPixelFormatType_OneComponent8, bytesPerPixel: 1)
            guard conf.allSatisfy({ $0 <= 2 }) else { throw OriginalStore.Failure.io("Invalid confidence") }
            try store.commit(bytes, path: String(format: "depth/%06llu.f32", fid), kind: "depth_f32", segment: segment)
            try store.commit(conf, path: String(format: "confidence/%06llu.u8", fid), kind: "confidence_u8", segment: segment)
            depthK = CaptureValues.intrinsics(frame, width: dw, height: dh)
        }
        var row = [String(fid), String(segment), String(frame.timestamp), tracking.state, tracking.reason]
        row += CaptureValues.pose(frame.camera).map { String($0) }
        row += [String(w), String(h), String(rgbK.fx), String(rgbK.fy), String(rgbK.cx), String(rgbK.cy), movie.path,
                String(videoIndex), depthK == nil ? "0" : "1"]
        row += depthK.map { [String($0.width), String($0.height), String($0.fx), String($0.fy), String($0.cx), String($0.cy)] }
            ?? ["0", "0", "0", "0", "0", "0"]
        row += [String(frame.camera.exposureDuration), String(frame.camera.exposureOffset)]
        try frames.append(row, time: frame.timestamp, segment: segment)
        savedFrames += 1; lastSavedFrame = fid; frameRate.add(frame.timestamp)
        recentFrames.append((fid, frame.timestamp))
        if recentFrames.count > 512 { recentFrames.removeFirst(recentFrames.count - 512) }
        if depthK != nil { depthFrames += 1; depthRate.add(frame.timestamp) }
        return fid
    }

    func acceleration(_ sample: CMAccelerometerData) throws {
        guard !closed, sample.timestamp >= started else { return }
        let a = sample.acceleration
        guard [sample.timestamp, a.x, a.y, a.z].allSatisfy(\.isFinite) else { throw OriginalStore.Failure.io("Nonfinite acceleration") }
        try accel.append([String(sample.timestamp), String(a.x), String(a.y), String(a.z)], time: sample.timestamp)
        accelRate.add(sample.timestamp)
    }

    func rotation(_ sample: CMGyroData) throws {
        guard !closed, sample.timestamp >= started else { return }
        let r = sample.rotationRate
        guard [sample.timestamp, r.x, r.y, r.z].allSatisfy(\.isFinite) else { throw OriginalStore.Failure.io("Nonfinite gyro") }
        try gyro.append([String(sample.timestamp), String(r.x), String(r.y), String(r.z)], time: sample.timestamp)
        gyroRate.add(sample.timestamp)
    }

    func boundary(reason: String, time: Double) throws {
        guard !closed, segment < 999_999, ["tracking_reset", "interruption", "relocalization_failed"].contains(reason) else {
            throw OriginalStore.Failure.io("Segment boundary")
        }
        try closeMovie(); try frames.close(); try events.close()
        let previous = segment; segment += 1; moviePart = 0
        segmentStarted = time
        recentFrames = []
        segments.append([String(segment), "seg-\(segment)", reason, String(previous), String(nextFrame), String(time)])
        try event("segment_start", detail: reason, time: time)
    }

    func event(_ name: String, detail: String, time: Double) throws {
        guard !closed else { return }
        try events.append([String(time), name, detail], time: time, segment: segment)
    }

    func thermal(_ value: String, time: Double) throws {
        let order = ["nominal", "fair", "serious", "critical"]
        guard let rank = order.firstIndex(of: value) else { return }
        if rank > (order.firstIndex(of: thermalMax) ?? 0) { thermalMax = value }
        try event("thermal", detail: value, time: time)
    }

    /// The returned high-resolution ARFrame owns this still's timestamp, pose and intrinsics. Reject
    /// stale callbacks from before a segment boundary; never borrow the latest live frame's calibration.
    func still(_ frame: ARFrame, requestedSegment: UInt32) throws {
        guard !closed, segment == requestedSegment, frame.timestamp >= segmentStarted,
              let nearest = recentFrames.min(by: { abs($0.time - frame.timestamp) < abs($1.time - frame.timestamp) })?.id,
              CaptureValues.tracking(frame.camera).state == "normal" else { return }
        let id = stillCount
        let path = String(format: "stills/%06llu.jpg", id)
        let pixels = frame.capturedImage
        let image = CIImage(cvPixelBuffer: pixels)
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let bytes = imageContext.jpegRepresentation(of: image, colorSpace: color,
                                                         options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]) else {
            throw OriginalStore.Failure.io("Still JPEG encoding")
        }
        let k = CaptureValues.intrinsics(frame, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let tracking = CaptureValues.tracking(frame.camera)
        var ownDepth: Any = NSNull()
        if let depth = frame.sceneDepth {
            let dw = CVPixelBufferGetWidth(depth.depthMap), dh = CVPixelBufferGetHeight(depth.depthMap)
            let depthPath = String(format: "stills/%06llu.depth.f32", id)
            try store.commit(CaptureValues.packed(depth.depthMap, format: kCVPixelFormatType_DepthFloat32, bytesPerPixel: 4),
                             path: depthPath, kind: "still_depth_f32", segment: segment)
            var confidencePath: Any = NSNull()
            if let confidence = depth.confidenceMap {
                guard CVPixelBufferGetWidth(confidence) == dw, CVPixelBufferGetHeight(confidence) == dh else {
                    throw OriginalStore.Failure.io("Still confidence dimensions")
                }
                let path = String(format: "stills/%06llu.conf.u8", id)
                let conf = try CaptureValues.packed(confidence, format: kCVPixelFormatType_OneComponent8, bytesPerPixel: 1)
                guard conf.allSatisfy({ $0 <= 2 }) else { throw OriginalStore.Failure.io("Still confidence values") }
                try store.commit(conf, path: path, kind: "still_confidence_u8", segment: segment)
                confidencePath = path
            }
            ownDepth = ["path": depthPath, "confidence_path": confidencePath,
                        "intrinsics": CaptureValues.intrinsicObject(CaptureValues.intrinsics(frame, width: dw, height: dh))] as [String: Any]
        }
        let metadata: [String: Any] = [
            "format": "s3d-still", "session_id": store.sessionID.uuidString.lowercased(), "still_id": id,
            "segment": segment, "coord_frame": "seg-\(segment)", "t_device_s": frame.timestamp,
            "nearest_frame_id": nearest, "camera_to_world": CaptureValues.pose(frame.camera),
            "tracking_state": tracking.state, "tracking_reason": tracking.reason,
            "image": ["path": path, "codec": "jpeg", "intrinsics": CaptureValues.intrinsicObject(k)],
            "depth": ownDepth, "exposure": ["duration_s": frame.camera.exposureDuration > 0 ? frame.camera.exposureDuration as Any : NSNull(), "iso": NSNull()]
        ]
        try store.commit(bytes, path: path, kind: "still_image", segment: segment)
        try store.commit(CaptureValues.json(metadata), path: String(format: "stills/%06llu.json", id), kind: "still_meta", segment: segment)
        stillCount += 1
    }

    func finish(reason: String, interrupted: Bool, time: Double) throws {
        guard !closed else { return }
        guard ["user", "thermal", "storage_low", "app_backgrounded", "error", "crash_recovered"].contains(reason) else {
            throw OriginalStore.Failure.io("Unknown stop reason")
        }
        try event("stop", detail: reason, time: time)
        try closeMovie(); try frames.close(); try accel.close(); try gyro.close(); try events.close()
        var segmentData = RotatingCSV.line(["segment", "coord_frame", "reason", "previous_segment", "first_frame_id", "t_device_s"])
        for row in segments { segmentData.append(RotatingCSV.line(row)) }
        try store.commit(segmentData, path: "segments.csv", kind: "segments_csv")
        let end: [String: Any] = [
            "format": "s3d-session-end", "session_id": store.sessionID.uuidString.lowercased(),
            "stopped_at": CaptureValues.utc(), "t_device_stop_s": time, "reason": reason, "interrupted": interrupted,
            "last_frame_id": lastSavedFrame.map { $0 as Any } ?? NSNull(), "frames_captured": savedFrames,
            "frames_with_depth": depthFrames, "stills_captured": stillCount, "segments": Int(segment) + 1,
            "measured_rates_hz": ["arframe": frameRate.stats(until: time), "depth": depthRate.stats(until: time),
                                  "accel": accelRate.stats(until: time), "gyro": gyroRate.stats(until: time), "device_motion": NSNull()],
            "thermal_max": thermalMax, "files_total": store.files.count + 1
        ]
        try store.commit(CaptureValues.json(end), path: "session_end.json", kind: "session_end")
        closed = true
    }

    private func closeMovie() throws {
        if let movie { try movie.close(); self.movie = nil; moviePart += 1 }
    }
}
