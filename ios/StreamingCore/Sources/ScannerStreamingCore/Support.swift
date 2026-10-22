import Foundation

/// Reconnect backoff (contract section 10): 0.5, 1, 2, 4, then 8 s maximum, ±20 % jitter.
public struct ReconnectBackoff: Sendable, Equatable {
    public static let steps: [Double] = [0.5, 1, 2, 4, 8]
    public private(set) var attempt = 0
    public init() {}

    /// `unit` is a uniform random number in [0, 1) supplied by the caller (testable).
    public mutating func nextDelay(unit: Double) -> Double {
        let base = ReconnectBackoff.steps[min(attempt, ReconnectBackoff.steps.count - 1)]
        attempt += 1
        let jitter = 0.8 + 0.4 * min(max(unit, 0), 1)
        return base * jitter
    }

    public mutating func reset() { attempt = 0 }
}

/// Measures sample rates over 2 s windows (status `rates_hz`, session.end `measured_rates_hz`).
public struct RateMeter: Sendable, Equatable {
    public let window: Double
    private var windowStart: Double?
    private var count = 0
    public private(set) var lastRate: Double?
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?
    private var sumRates = 0.0
    private var windows = 0

    public init(window: Double = 2) { self.window = window }

    public mutating func tick(at time: Double) {
        guard time.isFinite else { return }
        if let start = windowStart {
            if time - start >= window {
                let rate = Double(count) / (time - start)
                lastRate = rate
                minimum = min(minimum ?? rate, rate); maximum = max(maximum ?? rate, rate)
                sumRates += rate; windows += 1
                windowStart = time; count = 0
            }
        } else {
            windowStart = time
        }
        count += 1
    }

    /// Rate over the last full window, nil if the source stopped for more than two windows.
    public func current(now: Double) -> Double? {
        guard let start = windowStart, now - start < 2 * window else { return nil }
        return lastRate
    }

    public var mean: Double? { windows == 0 ? nil : sumRates / Double(windows) }

    public var statsJSON: JSONValue {
        guard let mean, let minimum, let maximum else { return .null }
        return .object(["mean": .number(mean), "min": .number(minimum), "max": .number(maximum)])
    }
}

/// Originals file names (contract section 9).
public enum SessionLayout {
    public static func id6(_ value: UInt64) -> String { String(format: "%06llu", value) }
    public static func depth(frameID: UInt64) -> String { "depth/\(id6(frameID)).f32" }
    public static func confidence(frameID: UInt64) -> String { "confidence/\(id6(frameID)).u8" }
    public static func still(_ stillID: UInt64, ext: String) -> String { "stills/\(id6(stillID)).\(ext)" }
    public static func stillMeta(_ stillID: UInt64) -> String { "stills/\(id6(stillID)).json" }
    public static func stillDepth(_ stillID: UInt64) -> String { "stills/\(id6(stillID)).depth.f32" }
    public static func stillConfidence(_ stillID: UInt64) -> String { "stills/\(id6(stillID)).conf.u8" }
    public static func video(segment: UInt32, part: Int) -> String {
        "video/seg\(id6(UInt64(segment)))-part\(String(format: "%03d", part)).mov"
    }
    public static func framesPart(_ part: Int) -> String { "frames/part-\(id6(UInt64(part))).csv" }
    public static func accelPart(_ part: Int) -> String { "motion/accel/part-\(id6(UInt64(part))).csv" }
    public static func gyroPart(_ part: Int) -> String { "motion/gyro/part-\(id6(UInt64(part))).csv" }
    public static func eventsPart(_ part: Int) -> String { "events/part-\(id6(UInt64(part))).csv" }
    public static let sessionMeta = "session.json"
    public static let sessionEnd = "session_end.json"
    public static let segments = "segments.csv"
    public static let calibration = "calibration/arkit_camera.json"
}

/// CSV cells: '.' decimal separator, shortest round-trip decimal, empty cell for null / non-finite.
public enum CSV {
    public static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return "\(value)"
    }
    public static func number(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "" }
        return "\(value)"
    }
    public static func text(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
