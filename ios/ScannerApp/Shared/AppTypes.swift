import Foundation
import ScannerStreamingCore

struct ClosedOriginal: Codable, Hashable, Sendable {
    let fileID: UInt64
    let path: String
    let kind: String
    let bytes: UInt64
    let sha256: String
    let segment: UInt32?
}

struct LocalScan: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var isRecording: Bool
    var originalCount: Int
    var uploadedCount: Int
    var pcConfirmedComplete: Bool
    var displayName: String
    var canRemoveFromPhone: Bool { !isRecording && pcConfirmedComplete && uploadedCount == originalCount }
}

struct CaptureStatus: Sendable {
    var recording = false
    var elapsedSeconds: Double = 0
    var segment: UInt32 = 0
    var guidance: String?
    var thermalState = "nominal"
    var storageFreeBytes: UInt64 = 0
    var framesSaved: UInt64 = 0
    var previewRateHz: Double = 0
    var failure: String?
}

struct PairingProposal: Identifiable, Sendable {
    let id: UUID
    let pcID: UUID?
    let pcName: String
    let addresses: [String]
    let fingerprint: String
    let token: String
    let shortCode: String
}

struct RemoteStopRequest: Identifiable, Sendable {
    let id: String
    let sessionID: UUID
    let reason: String
}

enum LinkEvent: Sendable {
    case connecting
    case connected(pcName: String)
    case disconnected(reason: String?)
    case uploadProgress(sessionID: UUID, saved: Int, total: Int)
    case remoteStop(RemoteStopRequest)
    case previewPaused(reason: String)
    case failure(String)
}

enum AppVersion {
    /// The native shell. A UI bundle declares the oldest shell it runs on (`min_native`, docs/PHONE-UI-AND-DEBUG.md).
    static let native = "0.3.0"
}

/// The answer to one PC debug request: its response body, or an error response.
enum DebugReply: Sendable {
    case ok(JSONValue)
    case error(code: String, message: String)
}
