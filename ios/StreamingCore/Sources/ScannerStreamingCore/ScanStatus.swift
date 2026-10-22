import Foundation

/// Maps capture/link state to the approved Scan-screen copy (ui/README.md section 4, screens 3-4).
///
/// APPROVED strings (ui/iphone/index.html): "Scanning · all good", "Weak Wi-Fi · recording is safe",
/// guidance "Move slower" / "Point back at the part.".
/// EXTRAPOLATED strings (not on an approved board; follow the same calm rules; listed in ios/ScannerApp/README.md
/// for the UI session's v0.4 review): every other pill text and guidance card below.
public enum LinkHealth: Sendable, Equatable {
    case notPaired
    case connecting
    case connected
    case previewPaused   // no preview.ack for 2 s, or PC paused preview for weak_link
    case disconnected
}

public struct ScanConditions: Sendable, Equatable {
    public var recording: Bool
    public var elapsedSeconds: Double
    public var tracking: TrackingStateWire
    public var reason: TrackingReasonWire
    public var link: LinkHealth
    public var thermal: ThermalStateWire
    public var storageWarning: Bool

    public init(recording: Bool, elapsedSeconds: Double = 0, tracking: TrackingStateWire = .normal,
                reason: TrackingReasonWire = .none, link: LinkHealth = .connected, thermal: ThermalStateWire = .nominal,
                storageWarning: Bool = false) {
        self.recording = recording; self.elapsedSeconds = elapsedSeconds; self.tracking = tracking
        self.reason = reason; self.link = link; self.thermal = thermal; self.storageWarning = storageWarning
    }
}

public struct ScanGuidance: Sendable, Equatable {
    public let title: String
    public let body: String
}

public struct ScanPresentation: Sendable, Equatable {
    public let pillText: String?
    public let pillIsWarning: Bool
    public let timerText: String?
    public let guidance: ScanGuidance?
    /// VoiceOver label for the pill: words only, timer spelled out.
    public let pillAccessibilityLabel: String?
}

public enum ScanStatusText {
    public static let allGood = "Scanning · all good"
    public static let weakWiFi = "Weak Wi-Fi · recording is safe"
    public static let pcNotConnected = "PC not connected · recording is safe"          // extrapolated
    public static let savedOnPhone = "Scanning · saved on this phone"                  // extrapolated
    public static let phoneWarm = "Phone is warm · recording is safe"                 // extrapolated
    public static let storageLow = "Phone storage almost full · recording is safe"    // extrapolated
    public static let idleNotConnected = "PC not connected · scans stay on this phone" // extrapolated

    public static func timer(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total / 60) % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }

    static func spokenTimer(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60, secs = total % 60
        return "\(minutes) minute\(minutes == 1 ? "" : "s") \(secs) second\(secs == 1 ? "" : "s")"
    }

    public static func guidance(tracking: TrackingStateWire, reason: TrackingReasonWire) -> ScanGuidance? {
        switch (tracking, reason) {
        case (.normal, _): return nil
        case (.limited, .excessiveMotion): return ScanGuidance(title: "Move slower", body: "Point back at the part.")
        case (.limited, .insufficientFeatures):
            return ScanGuidance(title: "Point back at the part", body: "Keep it in view, with good light.")
        case (.limited, .initializing): return ScanGuidance(title: "Hold steady", body: "Move the phone slowly to start.")
        case (.limited, .relocalizing):
            return ScanGuidance(title: "Point back at the part", body: "Return to where you started.")
        default: return ScanGuidance(title: "Point back at the part", body: "Move the phone slowly.")
        }
    }

    public static func present(_ c: ScanConditions) -> ScanPresentation {
        guard c.recording else {
            let text: String? = (c.link == .disconnected) ? idleNotConnected : nil
            return ScanPresentation(pillText: text, pillIsWarning: text != nil, timerText: nil, guidance: nil,
                                    pillAccessibilityLabel: text)
        }
        let card = ScanStatusText.guidance(tracking: c.tracking, reason: c.reason)
        var text = allGood
        var warn = false
        if c.storageWarning { text = storageLow; warn = true }
        else if c.thermal >= .serious { text = phoneWarm; warn = true }
        else if c.link == .previewPaused { text = weakWiFi; warn = true }
        else if c.link == .disconnected || c.link == .connecting { text = pcNotConnected; warn = true }
        else if c.link == .notPaired { text = savedOnPhone }
        let clock: String? = warn ? nil : ScanStatusText.timer(c.elapsedSeconds)
        let spoken = warn ? text : "\(text), recording for \(spokenTimer(c.elapsedSeconds))"
        return ScanPresentation(pillText: text, pillIsWarning: warn, timerText: clock, guidance: card,
                                pillAccessibilityLabel: spoken.replacingOccurrences(of: " · ", with: ", "))
    }
}

/// Scans list rows (ui/README.md screen 5). APPROVED strings: "Sending to PC · 64%", "Saved on PC",
/// "Remove from phone", "12 files not on the PC yet. They’ll send when connected.", the footer.
public enum ScanRowStatus: Sendable, Equatable {
    case recording
    case sending(percent: Int)
    case waiting(filesNotOnPC: Int)
    case savedOnPC
    case failed(files: Int)

    public var text: String {
        switch self {
        case .recording: return "Recording"                                     // extrapolated
        case .sending(let percent): return "Sending to PC · \(percent)%"
        case .waiting(let files):
            return "\(files) file\(files == 1 ? "" : "s") not on the PC yet. They’ll send when connected."
        case .savedOnPC: return "Saved on PC"
        case .failed(let files):                                                 // extrapolated
            return "\(files) file\(files == 1 ? "" : "s") couldn’t be sent. They stay on this phone."
        }
    }

    public var isWarning: Bool {
        switch self {
        case .waiting, .failed: return true
        default: return false
        }
    }

    public var offersRemoval: Bool { self == .savedOnPC }

    public static let footer = "Scans stay on this phone until you remove them. You can only remove a scan after the PC has saved all of it."

    /// `pcConfirmed` comes only from `UploadJournal.pcConfirmedComplete` (fresh-resume gate).
    public static func derive(recording: Bool, pcConfirmed: Bool, connected: Bool, progress: UploadProgress) -> ScanRowStatus {
        if recording { return .recording }
        if pcConfirmed { return .savedOnPC }
        if progress.filesFailed > 0 { return .failed(files: progress.filesFailed) }
        let notOnPC = max(0, progress.filesKnown - progress.filesCompleteOnPC)
        if !connected { return .waiting(filesNotOnPC: max(1, notOnPC)) }
        let percent = min(99, Int((progress.fraction * 100).rounded(.down)))
        return .sending(percent: percent)
    }
}
