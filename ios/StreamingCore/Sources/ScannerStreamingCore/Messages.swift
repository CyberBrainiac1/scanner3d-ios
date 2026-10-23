import Foundation

// Hand-written DTOs for contracts/stream v1 (Codex decision 13: DTOs + golden vectors, no codegen).
// Incoming = PC -> phone (decoded strictly, validated in code). Outgoing = phone -> PC bodies as JSONValue so that
// explicit `null` members are always emitted (the schemas require them; synthesized Encodable would omit them).

// MARK: - JSONValue builders

extension JSONValue {
    public static func uuid(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }
    public static func uuid(_ value: UUID?) -> JSONValue { value.map { .uuid($0) } ?? .null }
    public static func int(_ value: Int) -> JSONValue { .integer(Int64(value)) }
    public static func int(_ value: UInt64) -> JSONValue { .integer(Int64(clamping: value)) }
    public static func int(_ value: UInt32) -> JSONValue { .integer(Int64(value)) }
    public static func int(_ value: UInt64?) -> JSONValue { value.map { .int($0) } ?? .null }
    public static func int(_ value: UInt32?) -> JSONValue { value.map { .int($0) } ?? .null }
    public static func num(_ value: Double?) -> JSONValue {
        guard let value, value.isFinite else { return .null }
        return .number(value)
    }
    public static func str(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }
}

// MARK: - Shared enums

public enum TrackingStateWire: String, Sendable, Codable { case normal, limited, notAvailable = "not_available" }
public enum TrackingReasonWire: String, Sendable, Codable {
    case none, initializing, excessiveMotion = "excessive_motion", insufficientFeatures = "insufficient_features"
    case relocalizing, unknown
    /// S3DP header code (section 5 table).
    public var code: UInt8 {
        switch self {
        case .none: return 0
        case .initializing: return 1
        case .excessiveMotion: return 2
        case .insufficientFeatures: return 3
        case .relocalizing: return 4
        case .unknown: return 255
        }
    }
}
extension TrackingStateWire {
    public var code: UInt8 {
        switch self {
        case .notAvailable: return 0
        case .limited: return 1
        case .normal: return 2
        }
    }
}
public enum ThermalStateWire: String, Sendable, Codable, Comparable {
    case nominal, fair, serious, critical
    var rank: Int { [ThermalStateWire.nominal, .fair, .serious, .critical].firstIndex(of: self)! }
    public static func < (a: ThermalStateWire, b: ThermalStateWire) -> Bool { a.rank < b.rank }
}

// MARK: - Incoming envelope

public struct WireError: Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public init(code: String, message: String, retryable: Bool) {
        self.code = code; self.message = message; self.retryable = retryable
    }
}

public struct HelloResponse: Decodable, Sendable, Equatable {
    public struct PCInfo: Decodable, Sendable, Equatable {
        public let pcID: String, displayName: String, appVersion: String, sourceRevision: String
        enum CodingKeys: String, CodingKey {
            case pcID = "pc_id", displayName = "display_name", appVersion = "app_version", sourceRevision = "source_revision"
        }
    }
    public struct Credential: Decodable, Sendable, Equatable {
        public let deviceID: String, secret: String
        enum CodingKeys: String, CodingKey { case deviceID = "device_id", secret }
    }
    public struct Limits: Decodable, Sendable, Equatable {
        public let maxTextBytes: Int, maxBinaryBytes: Int, chunkBytes: Int, windowChunks: Int
        public let previewInflightMax: Int, statusIntervalMs: Int, pingIntervalMs: Int, idleTimeoutMs: Int
        enum CodingKeys: String, CodingKey {
            case maxTextBytes = "max_text_bytes", maxBinaryBytes = "max_binary_bytes", chunkBytes = "chunk_bytes"
            case windowChunks = "window_chunks", previewInflightMax = "preview_inflight_max"
            case statusIntervalMs = "status_interval_ms", pingIntervalMs = "ping_interval_ms"
            case idleTimeoutMs = "idle_timeout_ms"
        }
    }
    public struct PreviewProfile: Decodable, Sendable, Equatable {
        public let rgbCodec: String, rgbWidth: Int, rgbHeight: Int, rgbQuality: Double
        public let depthCodec: String, depthScaleMPerUnit: Double, confidence: Bool, targetHz: Double
        enum CodingKeys: String, CodingKey {
            case rgbCodec = "rgb_codec", rgbWidth = "rgb_width", rgbHeight = "rgb_height", rgbQuality = "rgb_quality"
            case depthCodec = "depth_codec", depthScaleMPerUnit = "depth_scale_m_per_unit", confidence
            case targetHz = "target_hz"
        }
    }
    public let socket: String
    public let protocolVersion: String
    public let previewLayoutVersion: Int
    public let chunkLayoutVersion: Int
    public let connectionID: String
    public let qpcFrequencyHz: Int64
    public let pc: PCInfo
    public let credential: Credential?
    public let limits: Limits
    public let previewProfile: PreviewProfile?
    enum CodingKeys: String, CodingKey {
        case socket, protocolVersion = "protocol_version", previewLayoutVersion = "preview_layout_version"
        case chunkLayoutVersion = "chunk_layout_version", connectionID = "connection_id"
        case qpcFrequencyHz = "qpc_frequency_hz", pc, credential, limits, previewProfile = "preview_profile"
    }

    /// Validator rules the schema cannot express (contract section 4) plus the schema ranges.
    public func validate(socket expected: String, sentPairingToken: Bool) throws {
        let l = limits
        guard socket == expected,
              protocolVersion.split(separator: ".").first == "1", previewLayoutVersion == 1, chunkLayoutVersion == 1,
              qpcFrequencyHz >= 1,
              (65536...1_048_576).contains(l.maxTextBytes), (65536...PacketEncoder.schemaMaximumBinaryBytes).contains(l.maxBinaryBytes),
              (65536...PacketEncoder.schemaMaximumChunkBytes).contains(l.chunkBytes), l.chunkBytes % 65536 == 0,
              l.chunkBytes + 96 <= l.maxBinaryBytes,
              (1...64).contains(l.windowChunks), (1...4).contains(l.previewInflightMax),
              (500...10000).contains(l.statusIntervalMs), (250...10000).contains(l.pingIntervalMs),
              (2000...60000).contains(l.idleTimeoutMs) else {
            throw StreamError.invalid("hello response limits/versions")
        }
        if credential != nil && !sentPairingToken { throw StreamError.invalid("credential without pairing") }
        if sentPairingToken {
            guard let credential, credential.deviceID.count == 36,
                  credential.secret.utf8.count == 43,
                  credential.secret.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 })
            else { throw StreamError.invalid("pairing hello without a valid credential") }
        }
        if socket == "originals" {
            guard previewProfile == nil else { throw StreamError.invalid("preview_profile on originals socket") }
        }
        if let p = previewProfile {
            guard p.rgbCodec == "jpeg", (16...4096).contains(p.rgbWidth), (16...4096).contains(p.rgbHeight),
                  p.rgbQuality >= 0, p.rgbQuality <= 1, ["f32", "u16"].contains(p.depthCodec),
                  p.depthScaleMPerUnit > 0, p.depthScaleMPerUnit <= 1,
                  p.depthCodec != "f32" || p.depthScaleMPerUnit == 1,
                  p.targetHz > 0, p.targetHz <= 30 else { throw StreamError.invalid("preview_profile") }
        }
    }
}

public struct FlowEvent: Decodable, Sendable, Equatable {
    public struct Preview: Decodable, Sendable, Equatable {
        public let enabled: Bool, targetHz: Double, inflightMax: Int, reason: String?
        enum CodingKeys: String, CodingKey { case enabled, targetHz = "target_hz", inflightMax = "inflight_max", reason }
    }
    public struct Originals: Decodable, Sendable, Equatable {
        public let enabled: Bool, maxBytesPerS: Int64?, windowChunks: Int, reason: String?
        enum CodingKeys: String, CodingKey {
            case enabled, maxBytesPerS = "max_bytes_per_s", windowChunks = "window_chunks", reason
        }
    }
    public let preview: Preview
    public let originals: Originals
    public func validate() throws {
        guard preview.targetHz.isFinite, (0...30).contains(preview.targetHz), (1...4).contains(preview.inflightMax),
              (1...64).contains(originals.windowChunks),
              originals.maxBytesPerS.map({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }) ?? true else {
            throw StreamError.invalid("flow limits")
        }
    }
}

/// `guidance` event (PC -> phone, preview socket): the PC's current live-coverage tip for the guidance card.
public struct GuidanceEvent: Decodable, Sendable, Equatable {
    public struct Tip: Decodable, Sendable, Equatable {
        public let id: String, severity: String, text: String, conditionKey: String
        enum CodingKeys: String, CodingKey { case id, severity, text, conditionKey = "condition_key" }
    }
    public let sessionID: UUID, coverageScore: Double?, tip: Tip?
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", coverageScore = "coverage_score", tip }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        coverageScore = try c.decodeIfPresent(Double.self, forKey: .coverageScore)
        tip = try c.decodeIfPresent(Tip.self, forKey: .tip)
    }
    public func validate() throws {
        guard coverageScore.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw StreamError.invalid("coverage score") }
        if let tip {
            guard ["warning", "adjust", "next"].contains(tip.severity), (1...200).contains(tip.text.count),
                  (1...128).contains(tip.conditionKey.count), (1...64).contains(tip.id.count) else { throw StreamError.invalid("guidance tip") }
        }
    }
}

public struct PreviewAck: Decodable, Sendable, Equatable {
    public let sessionID: UUID, frameID: UInt64, previewSeq: UInt64, receivedQpcTicks: QPCTicks, result: String
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", frameID = "frame_id", previewSeq = "preview_seq"
        case receivedQpcTicks = "received_qpc_ticks", result
    }
}

public struct SessionStartResponse: Decodable, Sendable, Equatable {
    public let sessionID: UUID, resumed: Bool, diskFreeBytes: UInt64, livePreview: String
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", resumed, diskFreeBytes = "disk_free_bytes", livePreview = "live_preview"
    }
}

public struct SessionStopResponse: Decodable, Sendable, Equatable {
    public let sessionID: UUID, originalsComplete: Bool
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", originalsComplete = "originals_complete" }
}

/// `capture.stop` request (Decision S9). TODO-RELEASE: bound to the 2026-10-21 M2-C2 draft schemas
/// (contracts/stream/schemas/capture.stop.*.schema.json); reconcile with the RELEASED hash list.
public struct CaptureStopRequestBody: Decodable, Sendable, Equatable {
    public let sessionID: UUID, reason: String, detail: String?
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", reason, detail }
}

public struct ManifestResponse: Decodable, Sendable, Equatable {
    public let sessionID: UUID, manifestSeqDurable: UInt32
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", manifestSeqDurable = "manifest_seq_durable" }
}

public struct OfferResponse: Decodable, Sendable, Equatable {
    public struct File: Decodable, Sendable, Equatable {
        public let fileID: UInt64, state: String, chunkBytes: UInt32, chunksTotal: UInt32, chunksDurableCount: UInt32
        enum CodingKeys: String, CodingKey {
            case fileID = "file_id", state, chunkBytes = "chunk_bytes", chunksTotal = "chunks_total"
            case chunksDurableCount = "chunks_durable_count"
        }
    }
    public let sessionID: UUID, files: [File]
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", files }
}

public struct OriginalsAck: Decodable, Sendable, Equatable {
    public struct FileAck: Decodable, Sendable, Equatable {
        public let fileID: UInt64, chunks: [IDRange], fileComplete: Bool
        enum CodingKeys: String, CodingKey { case fileID = "file_id", chunks, fileComplete = "file_complete" }
    }
    public let sessionID: UUID, acks: [FileAck]
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", acks }
}

public struct OriginalsNack: Decodable, Sendable, Equatable {
    public let sessionID: UUID, fileID: UInt64, chunkIndex: UInt32?, reason: String, action: String, retryAfterMs: Int?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", fileID = "file_id", chunkIndex = "chunk_index", reason, action
        case retryAfterMs = "retry_after_ms"
    }
}

public struct ErrorEvent: Decodable, Sendable, Equatable {
    public let error: WireError, fatal: Bool, sessionID: UUID?
    enum CodingKeys: String, CodingKey { case error, fatal, sessionID = "session_id" }
}

public enum IncomingMessage: Sendable, Equatable {
    case helloResponse(replyTo: String, HelloResponse)
    case errorResponse(type: String, replyTo: String, WireError)
    case ping(id: String, QPCTicks)
    case flow(FlowEvent)
    case guidance(GuidanceEvent)
    case previewAck(PreviewAck)
    case sessionStartResponse(replyTo: String, SessionStartResponse)
    case sessionStopResponse(replyTo: String, SessionStopResponse)
    case captureStop(id: String, CaptureStopRequestBody)
    case resumeResponse(replyTo: String, ResumePage)
    case manifestResponse(replyTo: String, ManifestResponse)
    case offerResponse(replyTo: String, OfferResponse)
    case originalsAck(OriginalsAck)
    case originalsNack(OriginalsNack)
    case errorEvent(ErrorEvent)
    case unknownRequest(type: String, id: String)
    case unknownResponse(type: String, replyTo: String)
    case unknownEvent(type: String)

    private struct Head: Decodable {
        let v: Int, type: String, kind: String, id: String
        let replyTo: String?, ok: Bool?
        enum CodingKeys: String, CodingKey { case v, type, kind, id, replyTo = "reply_to", ok }
    }
    private struct Body<B: Decodable>: Decodable { let body: B }
    private struct ErrorBody: Decodable { let error: WireError }
    private struct PingBody: Decodable {
        let ticks: QPCTicks
        enum CodingKeys: String, CodingKey { case ticks = "t_pc_tx_qpc_ticks" }
    }

    /// Decodes one PC text frame. Size is checked BEFORE parsing (`max_text_bytes`, 1 MiB before hello).
    public static func decode(_ data: Data, maximumBytes: Int = 1_048_576) throws -> IncomingMessage {
        guard data.count <= maximumBytes else { throw StreamError.sizeLimit }
        let decoder = JSONDecoder()
        let head = try decoder.decode(Head.self, from: data)
        guard head.v == 1, isValidPCMessageID(head.id), ["request", "response", "event"].contains(head.kind) else {
            throw StreamError.invalid("envelope")
        }
        func body<B: Decodable>(_ type: B.Type) throws -> B { try decoder.decode(Body<B>.self, from: data).body }
        switch head.kind {
        case "response":
            guard let replyTo = head.replyTo, replyTo.hasPrefix("ph-"), let ok = head.ok else {
                throw StreamError.invalid("response envelope")
            }
            if !ok { return .errorResponse(type: head.type, replyTo: replyTo, try decoder.decode(ErrorBody.self, from: data).error) }
            switch head.type {
            case "hello": return .helloResponse(replyTo: replyTo, try body(HelloResponse.self))
            case "session.start": return .sessionStartResponse(replyTo: replyTo, try body(SessionStartResponse.self))
            case "session.stop": return .sessionStopResponse(replyTo: replyTo, try body(SessionStopResponse.self))
            case "originals.resume": return .resumeResponse(replyTo: replyTo, try body(ResumePage.self))
            case "originals.manifest": return .manifestResponse(replyTo: replyTo, try body(ManifestResponse.self))
            case "originals.offer": return .offerResponse(replyTo: replyTo, try body(OfferResponse.self))
            default: return .unknownResponse(type: head.type, replyTo: replyTo)
            }
        case "request":
            switch head.type {
            case "ping":
                return .ping(id: head.id, try body(PingBody.self).ticks)
            case CaptureStopFlow.messageType:
                return .captureStop(id: head.id, try body(CaptureStopRequestBody.self))
            default: return .unknownRequest(type: head.type, id: head.id)
            }
        default:
            switch head.type {
            case "flow":
                let flow = try body(FlowEvent.self); try flow.validate(); return .flow(flow)
            case "guidance":
                let guidance = try body(GuidanceEvent.self); try guidance.validate(); return .guidance(guidance)
            case "preview.ack": return .previewAck(try body(PreviewAck.self))
            case "originals.ack": return .originalsAck(try body(OriginalsAck.self))
            case "originals.nack": return .originalsNack(try body(OriginalsNack.self))
            case "error": return .errorEvent(try body(ErrorEvent.self))
            default: return .unknownEvent(type: head.type)
            }
        }
    }
}

// MARK: - Outgoing bodies

public struct AppInfo: Sendable, Equatable {
    public let name: String, version: String, build: String, sourceRevision: String
    public init(name: String = "scanner3d-ios", version: String, build: String, sourceRevision: String) {
        self.name = name; self.version = version; self.build = build
        // Schema: ^([0-9a-f]{7,40}(\+dirty)?|unknown)$
        let core = sourceRevision.hasSuffix("+dirty") ? String(sourceRevision.dropLast(6)) : sourceRevision
        let ok = (7...40).contains(core.count) && core.allSatisfy { "0123456789abcdef".contains($0) }
        self.sourceRevision = ok ? sourceRevision : "unknown"
    }
    public var json: JSONValue {
        .object(["name": .string(name), "version": .string(version), "build": .string(build),
                 "source_revision": .string(sourceRevision)])
    }
}

public struct DeviceInfo: Sendable, Equatable {
    public let modelIdentifier: String, osVersion: String, displayName: String
    public init(modelIdentifier: String, osVersion: String, displayName: String) {
        self.modelIdentifier = modelIdentifier; self.osVersion = osVersion
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(64))
    }
    public var json: JSONValue {
        .object(["model_identifier": .string(modelIdentifier), "os_version": .string(osVersion),
                 "display_name": .string(displayName)])
    }
}

public enum HelloAuth: Sendable, Equatable {
    case pairingToken(String)
    case deviceSecret(deviceID: String, secret: String)
    var json: JSONValue {
        switch self {
        case .pairingToken(let token):
            return .object(["method": .string("pairing_token"), "token": .string(token), "sas_confirmed": .bool(true)])
        case .deviceSecret(let deviceID, let secret):
            return .object(["method": .string("device_secret"), "device_id": .string(deviceID.lowercased()),
                            "secret": .string(secret)])
        }
    }
}

public struct CaptureConfig: Sendable, Equatable {
    public var videoWidth: Int, videoHeight: Int, videoFPS: Int, videoCodec: String
    public var depthWidth: Int, depthHeight: Int, depthSource: String, depthEveryNFrames: Int
    public var confidence: Bool
    public var stillsEnabled: Bool, stillWidth: Int?, stillHeight: Int?, stillCodec: String, stillQuality: Double
    public var accelHz: Double, gyroHz: Double, deviceMotionHz: Double?
    public var intrinsicsScaling: String

    public init(videoWidth: Int, videoHeight: Int, videoFPS: Int, videoCodec: String = "hevc",
                depthWidth: Int, depthHeight: Int, depthSource: String = "scene_depth", depthEveryNFrames: Int,
                confidence: Bool = true, stillsEnabled: Bool, stillWidth: Int?, stillHeight: Int?,
                stillCodec: String = "heic", stillQuality: Double, accelHz: Double = 100, gyroHz: Double = 100,
                deviceMotionHz: Double? = nil, intrinsicsScaling: String = "multiplicative") {
        self.videoWidth = videoWidth; self.videoHeight = videoHeight; self.videoFPS = videoFPS; self.videoCodec = videoCodec
        self.depthWidth = depthWidth; self.depthHeight = depthHeight; self.depthSource = depthSource
        self.depthEveryNFrames = depthEveryNFrames; self.confidence = confidence
        self.stillsEnabled = stillsEnabled; self.stillWidth = stillWidth; self.stillHeight = stillHeight
        self.stillCodec = stillCodec; self.stillQuality = stillQuality
        self.accelHz = accelHz; self.gyroHz = gyroHz; self.deviceMotionHz = deviceMotionHz
        self.intrinsicsScaling = intrinsicsScaling
    }

    public var json: JSONValue {
        .object([
            "video": .object(["width": .int(videoWidth), "height": .int(videoHeight), "fps": .int(videoFPS),
                              "codec": .string(videoCodec)]),
            "depth": .object(["width": .int(depthWidth), "height": .int(depthHeight), "source": .string(depthSource),
                              "every_n_frames": .int(depthEveryNFrames)]),
            "confidence": .bool(confidence),
            "stills": .object(["enabled": .bool(stillsEnabled), "width": stillWidth.map { JSONValue.int($0) } ?? .null,
                               "height": stillHeight.map { JSONValue.int($0) } ?? .null, "codec": .string(stillCodec),
                               "quality": .number(stillQuality)]),
            "imu": .object(["accel_requested_hz": .number(accelHz), "gyro_requested_hz": .number(gyroHz),
                            "device_motion_requested_hz": .num(deviceMotionHz)]),
            "intrinsics_scaling": .string(intrinsicsScaling),
        ])
    }
}

public struct StatusSnapshot: Sendable, Equatable {
    public var sessionID: UUID?
    public var recording: Bool
    public var segment: UInt32?
    public var tDevice: Double
    public var thermal: ThermalStateWire
    public var storageFreeBytes: UInt64
    public var batteryLevel: Double?
    public var batteryState: String
    public var lowPowerMode: Bool
    public var trackingState: TrackingStateWire
    public var trackingReason: TrackingReasonWire
    public var rateARFrame: Double?, rateDepth: Double?, rateAccel: Double?, rateGyro: Double?, ratePreviewSent: Double?
    public var framesCaptured: UInt64, stillsCaptured: UInt64, previewSent: UInt64, previewDroppedQueue: UInt64
    public var filesClosed: UInt64, filesCompleteOnPC: UInt64, bytesPending: UInt64

    public init(sessionID: UUID? = nil, recording: Bool = false, segment: UInt32? = nil, tDevice: Double,
                thermal: ThermalStateWire = .nominal, storageFreeBytes: UInt64 = 0, batteryLevel: Double? = nil,
                batteryState: String = "unknown", lowPowerMode: Bool = false,
                trackingState: TrackingStateWire = .notAvailable, trackingReason: TrackingReasonWire = .none,
                rateARFrame: Double? = nil, rateDepth: Double? = nil, rateAccel: Double? = nil,
                rateGyro: Double? = nil, ratePreviewSent: Double? = nil, framesCaptured: UInt64 = 0,
                stillsCaptured: UInt64 = 0, previewSent: UInt64 = 0, previewDroppedQueue: UInt64 = 0,
                filesClosed: UInt64 = 0, filesCompleteOnPC: UInt64 = 0, bytesPending: UInt64 = 0) {
        self.sessionID = sessionID; self.recording = recording; self.segment = segment; self.tDevice = tDevice
        self.thermal = thermal; self.storageFreeBytes = storageFreeBytes; self.batteryLevel = batteryLevel
        self.batteryState = batteryState; self.lowPowerMode = lowPowerMode; self.trackingState = trackingState
        self.trackingReason = trackingReason; self.rateARFrame = rateARFrame; self.rateDepth = rateDepth
        self.rateAccel = rateAccel; self.rateGyro = rateGyro; self.ratePreviewSent = ratePreviewSent
        self.framesCaptured = framesCaptured; self.stillsCaptured = stillsCaptured; self.previewSent = previewSent
        self.previewDroppedQueue = previewDroppedQueue; self.filesClosed = filesClosed
        self.filesCompleteOnPC = filesCompleteOnPC; self.bytesPending = bytesPending
    }

    public var json: JSONValue {
        let level: JSONValue = batteryLevel.map { JSONValue.number(min(1, max(0, $0))) } ?? .null
        return .object([
            "session_id": .uuid(sessionID), "recording": .bool(recording), "segment": .int(segment),
            "t_device_s": .number(max(0, tDevice)), "thermal_state": .string(thermal.rawValue),
            "storage_free_bytes": .int(storageFreeBytes), "battery_level": level,
            "battery_state": .string(batteryState), "low_power_mode": .bool(lowPowerMode),
            "tracking_state": .string(trackingState.rawValue), "tracking_reason": .string(trackingReason.rawValue),
            "rates_hz": .object(["arframe": .num(rateARFrame), "depth": .num(rateDepth), "accel": .num(rateAccel),
                                 "gyro": .num(rateGyro), "preview_sent": .num(ratePreviewSent)]),
            "counters": .object(["frames_captured": .int(framesCaptured), "stills_captured": .int(stillsCaptured),
                                 "preview_sent": .int(previewSent), "preview_dropped_queue": .int(previewDroppedQueue)]),
            "originals": .object(["files_closed": .int(filesClosed), "files_complete_on_pc": .int(filesCompleteOnPC),
                                  "bytes_pending": .int(bytesPending)]),
        ])
    }
}

public enum Wire {
    public static func hello(socket: String, auth: HelloAuth, app: AppInfo, device: DeviceInfo,
                             depthCodecs: [String] = ["f32", "u16"], maxPreviewHz: Double = 10) -> JSONValue {
        .object([
            "socket": .string(socket), "protocol_versions": .array([.string("1.0")]),
            "preview_layout_versions": .array([.integer(1)]), "chunk_layout_versions": .array([.integer(1)]),
            "app": app.json, "device": device.json, "auth": auth.json,
            "capabilities": .object(["rgb_codecs": .array([.string("jpeg")]),
                                     "depth_codecs": .array(depthCodecs.map { JSONValue.string($0) }),
                                     "max_preview_hz": .number(maxPreviewHz)]),
        ])
    }

    public static func sessionStart(sessionID: UUID, resumed: Bool, tDevice: Double, capture: CaptureConfig,
                                    storageFreeBytes: UInt64, estimatedBytesPerSecond: UInt64) -> JSONValue {
        .object(["session_id": .uuid(sessionID), "resumed": .bool(resumed), "profile": .string("tabletop"),
                 "t_device_s": .number(tDevice), "capture": capture.json,
                 "storage_free_bytes": .int(storageFreeBytes),
                 "estimated_originals_bytes_per_s": .int(estimatedBytesPerSecond)])
    }

    /// `reason`: user, thermal, storage_low, app_backgrounded, error, pc_request (TODO-RELEASE: pc_request is from
    /// the 2026-10-21 draft, Decision S9).
    public static func sessionStop(sessionID: UUID, tDevice: Double, reason: String, lastFrameID: UInt64?,
                                   framesCaptured: UInt64, stillsCaptured: UInt64, segments: Int) -> JSONValue {
        .object(["session_id": .uuid(sessionID), "t_device_s": .number(tDevice), "reason": .string(reason),
                 "last_frame_id": .int(lastFrameID), "frames_captured": .int(framesCaptured),
                 "stills_captured": .int(stillsCaptured), "segments": .int(max(1, segments))])
    }

    public static func segmentStart(sessionID: UUID, segment: UInt32, reason: String, previousSegment: UInt32?,
                                    firstFrameID: UInt64, tDevice: Double) -> JSONValue {
        .object(["session_id": .uuid(sessionID), "segment": .int(segment), "coord_frame": .string("seg-\(segment)"),
                 "reason": .string(reason), "previous_segment": .int(previousSegment),
                 "first_frame_id": .int(firstFrameID), "t_device_s": .number(tDevice)])
    }

    public static func resume(sessionID: UUID, cursor: String?) -> JSONValue {
        .object(["session_id": .uuid(sessionID), "cursor": .str(cursor)])
    }

    public static func manifest(sessionID: UUID, seq: UInt32, final: Bool, totalFiles: UInt64?,
                                files: [LocalFile]) -> JSONValue {
        .object(["session_id": .uuid(sessionID), "manifest_seq": .int(seq), "final": .bool(final),
                 "total_files": final ? .int(totalFiles) : .null, "files": .array(files.map { (file: LocalFile) -> JSONValue in file.json })])
    }

    public static func offer(sessionID: UUID, fileIDs: [UInt64]) -> JSONValue {
        .object(["session_id": .uuid(sessionID), "file_ids": .array(fileIDs.map { JSONValue.int($0) })])
    }
}
