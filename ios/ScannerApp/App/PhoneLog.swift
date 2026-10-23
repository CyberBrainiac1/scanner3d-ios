import Foundation

/// The app's own log for remote debugging: a bounded ring for `debug.state`, drained by the PC link into `log` events
/// at most once a second (docs/PHONE-UI-AND-DEBUG.md). Never put secrets, credentials or image data in it.
final class PhoneLog: @unchecked Sendable {
    static let shared = PhoneLog()
    struct Line: Sendable {
        let time: Double
        let level: String
        let text: String
    }
    private let lock = NSLock()
    private var pending: [Line] = []
    private var recent: [Line] = []
    private var dropped = 0

    func add(_ level: String, _ text: String) {
        let clipped = String(text.prefix(500))
        let line = Line(time: ProcessInfo.processInfo.systemUptime,
                        level: ["debug", "info", "warn", "error"].contains(level) ? level : "info", text: clipped.isEmpty ? "-" : clipped)
        lock.lock(); defer { lock.unlock() }
        recent.append(line)
        if recent.count > 300 { recent.removeFirst(recent.count - 300) }
        if pending.count < 500 { pending.append(line) } else { dropped += 1 }
    }
    func info(_ text: String) { add("info", text) }
    func warn(_ text: String) { add("warn", text) }
    func error(_ text: String) { add("error", text) }

    /// Up to 50 waiting lines for one `log` event, and how many were dropped since the last one; nil when idle.
    func drain() -> (lines: [Line], dropped: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let lines = Array(pending.prefix(50))
        pending.removeFirst(lines.count)
        let count = dropped; dropped = 0
        return (lines, count)
    }

    func tail(_ count: Int) -> [Line] {
        lock.lock(); defer { lock.unlock() }
        return Array(recent.suffix(count))
    }
}
