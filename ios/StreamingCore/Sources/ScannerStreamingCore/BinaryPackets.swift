import Foundation
import CryptoKit

public enum StreamError: Error, Equatable, LocalizedError {
    case invalid(String)
    case sizeLimit
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Invalid scanner data: \(detail)"
        case .sizeLimit: return "The scanner message exceeds the negotiated size limit."
        }
    }
}

public struct Intrinsics: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fx: Float
    public let fy: Float
    public let cx: Float
    public let cy: Float

    public init(width: Int, height: Int, fx: Float, fy: Float, cx: Float, cy: Float) {
        self.width = width; self.height = height
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }

    func validate(maximum: Int) throws {
        guard (1...maximum).contains(width), (1...maximum).contains(height),
              [fx, fy, cx, cy].allSatisfy({ $0.isFinite }), fx > 0, fy > 0 else {
            throw StreamError.invalid("intrinsics")
        }
    }
}

public struct RGBSection: Sendable {
    public let jpeg: Data
    public let intrinsics: Intrinsics
    public init(jpeg: Data, intrinsics: Intrinsics) { self.jpeg = jpeg; self.intrinsics = intrinsics }
}

public struct DepthSection: Sendable {
    public enum Codec: UInt8, Sendable { case float32 = 1, uint16 = 2 }
    public let codec: Codec
    /// Packed little-endian values, exactly width * height * bytesPerPixel, no row padding.
    public let bytes: Data
    public let intrinsics: Intrinsics
    public let scaleMetersPerUnit: Float

    public init(codec: Codec, bytes: Data, intrinsics: Intrinsics, scaleMetersPerUnit: Float) {
        self.codec = codec; self.bytes = bytes; self.intrinsics = intrinsics
        self.scaleMetersPerUnit = scaleMetersPerUnit
    }

    /// Preview quantization only. Keep original Float32 depth separately and unchanged.
    /// Use Double(0.001) for the v1 default, not a widened Float(0.001), to match reference rounding.
    public static func quantize(_ depths: [Float], scale: Double = 0.001) throws -> Data {
        guard scale.isFinite, scale > 0, scale <= 1 else { throw StreamError.invalid("depth scale") }
        var result = Data(); result.reserveCapacity(depths.count * 2)
        for depth in depths {
            let q = (Double(depth) / scale + 0.5).rounded(.down)
            let value: UInt16 = q.isFinite && depth > 0 && q > 0 && q <= 65535 ? UInt16(q) : 0
            result.appendLE(value)
        }
        return result
    }
}

public struct PreviewFrame: Sendable {
    public let sessionID: UUID
    public let segment: UInt32
    public let frameID: UInt64
    public let previewSequence: UInt64
    public let deviceTime: Double
    public let sentTime: Double
    /// ARKit camera_to_world. Row-major storage, column-vector multiplication; meters.
    public let cameraToWorld: [Float]
    public let trackingState: UInt8
    public let trackingReason: UInt8
    public let source: Intrinsics
    public let scaling: UInt8
    public let rgb: RGBSection?
    public let depth: DepthSection?
    public let confidence: Data?
    public let flags: UInt32

    public init(sessionID: UUID, segment: UInt32, frameID: UInt64, previewSequence: UInt64,
                deviceTime: Double, sentTime: Double, cameraToWorld: [Float],
                trackingState: UInt8, trackingReason: UInt8, source: Intrinsics,
                scaling: UInt8 = 0, rgb: RGBSection? = nil, depth: DepthSection? = nil,
                confidence: Data? = nil, flags: UInt32 = 0) {
        self.sessionID = sessionID; self.segment = segment; self.frameID = frameID
        self.previewSequence = previewSequence; self.deviceTime = deviceTime; self.sentTime = sentTime
        self.cameraToWorld = cameraToWorld; self.trackingState = trackingState
        self.trackingReason = trackingReason; self.source = source; self.scaling = scaling
        self.rgb = rgb; self.depth = depth; self.confidence = confidence; self.flags = flags
    }
}

public enum PacketEncoder {
    /// Default `hello.limits.max_binary_bytes` (4 MiB). The negotiated value may be larger.
    public static let maximumPacketBytes = 4 * 1024 * 1024
    /// Schema ceiling for `hello.limits.max_binary_bytes` (16 MiB). Encoders accept any negotiated value up to this.
    public static let schemaMaximumBinaryBytes = 16 * 1024 * 1024
    /// Schema ceiling for a file's `chunk_bytes` (8 MiB, a multiple of 64 KiB).
    public static let schemaMaximumChunkBytes = 8 * 1024 * 1024
    private static let uint53: UInt64 = (1 << 53) - 1

    /// Call immediately before handing a locally encoded preview to URLSession.send, after queueing.
    /// This is a send timestamp, not an ACK or a durable-save signal.
    public static func stampingSendTime(_ packet: Data, now: Double) throws -> Data {
        guard packet.startIndex == 0, packet.count >= 256, packet.count <= schemaMaximumBinaryBytes,
              packet.prefix(8) == Data([83, 51, 68, 80, 1, 0, 0, 1]), now.isFinite else {
            throw StreamError.invalid("preview send stamp")
        }
        func bits(at offset: Int, bytes: Int) -> UInt64 {
            (0..<bytes).reduce(UInt64(0)) { $0 | (UInt64(packet[offset + $1]) << ($1 * 8)) }
        }
        let captured = Double(bitPattern: bits(at: 48, bytes: 8))
        let previous = Double(bitPattern: bits(at: 56, bytes: 8))
        guard bits(at: 240, bytes: 4) == UInt64(packet.count), captured.isFinite, previous.isFinite,
              captured >= 0, now >= max(captured, previous) else { throw StreamError.invalid("preview send clock") }
        var stamped = packet; stamped.putLE(now.bitPattern, at: 56); return stamped
    }

    public static func preview(_ frame: PreviewFrame, maximumBytes: Int = maximumPacketBytes) throws -> Data {
        guard maximumBytes >= 256, maximumBytes <= schemaMaximumBinaryBytes else { throw StreamError.sizeLimit }
        guard frame.segment <= 999999, frame.frameID <= uint53, frame.previewSequence <= uint53,
              !frame.sessionID.isZero, frame.flags & ~UInt32(7) == 0,
              frame.deviceTime.isFinite, frame.sentTime.isFinite,
              frame.deviceTime >= 0, frame.sentTime >= frame.deviceTime,
              frame.trackingState <= 2, [UInt8(0), 1, 2, 3, 4, 255].contains(frame.trackingReason),
              (frame.trackingState == 1) == (frame.trackingReason != 0), frame.scaling <= 1 else {
            throw StreamError.invalid("frame metadata")
        }
        try validatePose(frame.cameraToWorld)
        try frame.source.validate(maximum: 16384)
        if let rgb = frame.rgb {
            try rgb.intrinsics.validate(maximum: 4096)
            guard rgb.jpeg.count >= 4, rgb.jpeg.prefix(2) == Data([0xff, 0xd8]),
                  rgb.jpeg.suffix(2) == Data([0xff, 0xd9]) else { throw StreamError.invalid("JPEG markers") }
            // A platform JPEG decoder must separately verify the actual dimensions before capture integration.
        }
        if let depth = frame.depth {
            try depth.intrinsics.validate(maximum: 1024)
            let pixelBytes = depth.codec == .float32 ? 4 : 2
            guard depth.bytes.count == depth.intrinsics.width * depth.intrinsics.height * pixelBytes,
                  depth.scaleMetersPerUnit.isFinite, depth.scaleMetersPerUnit > 0,
                  depth.scaleMetersPerUnit <= 1,
                  depth.codec != .float32 || depth.scaleMetersPerUnit == 1 else {
                throw StreamError.invalid("depth payload/scale")
            }
        }
        if let confidence = frame.confidence {
            guard let depth = frame.depth,
                  confidence.count == depth.intrinsics.width * depth.intrinsics.height,
                  confidence.allSatisfy({ $0 <= 2 }) else { throw StreamError.invalid("confidence") }
        }
        let sections = [frame.rgb?.jpeg, frame.depth?.bytes, frame.confidence]
        var position = 256
        var offsets = [Int](repeating: 0, count: 3)
        for index in sections.indices {
            guard let section = sections[index] else { continue }
            position = (position + 15) & ~15
            offsets[index] = position
            let (next, overflow) = position.addingReportingOverflow(section.count)
            guard !overflow, next <= maximumBytes, next <= Int(UInt32.max) else { throw StreamError.sizeLimit }
            position = next
        }
        guard position <= maximumBytes else { throw StreamError.sizeLimit }
        var packet = Data(repeating: 0, count: position)
        packet.put(Data("S3DP".utf8), at: 0)
        packet.putLE(UInt16(1), at: 4); packet.putLE(UInt16(256), at: 6)
        packet.putLE(frame.flags, at: 8); packet.putLE(frame.segment, at: 12)
        packet.put(frame.sessionID.wireBytes, at: 16)
        packet.putLE(frame.frameID, at: 32); packet.putLE(frame.previewSequence, at: 40)
        packet.putLE(frame.deviceTime.bitPattern, at: 48); packet.putLE(frame.sentTime.bitPattern, at: 56)
        for (index, value) in frame.cameraToWorld.enumerated() { packet.putLE(value.bitPattern, at: 64 + 4 * index) }
        packet[128] = frame.trackingState; packet[129] = frame.trackingReason
        packet[130] = frame.rgb == nil ? 0 : 1; packet[131] = frame.depth?.codec.rawValue ?? 0
        packet[132] = frame.confidence == nil ? 0 : 1; packet[133] = frame.scaling
        packet.putLE((frame.depth?.scaleMetersPerUnit ?? 0).bitPattern, at: 136)
        packet.putIntrinsics(frame.rgb?.intrinsics, at: 144)
        packet.putIntrinsics(frame.depth?.intrinsics, at: 168)
        packet.putIntrinsics(frame.source, at: 192)
        for index in sections.indices {
            guard let section = sections[index] else { continue }
            packet.putLE(UInt32(offsets[index]), at: 216 + index * 8)
            packet.putLE(UInt32(section.count), at: 220 + index * 8)
            packet.put(section, at: offsets[index])
        }
        packet.putLE(UInt32(position), at: 240)
        return packet
    }

    public static func chunk(sessionID: UUID, fileID: UInt64, index: UInt32, chunkBytes: Int,
                             payload: Data, last: Bool, maximumBytes: Int = maximumPacketBytes) throws -> Data {
        // Validate bounds before any arithmetic so hostile values throw instead of trapping.
        guard maximumBytes >= 96, maximumBytes <= schemaMaximumBinaryBytes,
              chunkBytes >= 65536, chunkBytes <= schemaMaximumChunkBytes,
              chunkBytes + 96 <= maximumBytes else { throw StreamError.sizeLimit }
        guard !sessionID.isZero, fileID <= uint53,
              chunkBytes % 65536 == 0, payload.count <= chunkBytes,
              last || payload.count == chunkBytes,
              !payload.isEmpty || (last && index == 0) else { throw StreamError.invalid("chunk metadata") }
        let (offset, overflow) = UInt64(index).multipliedReportingOverflow(by: UInt64(chunkBytes))
        guard !overflow, offset <= uint53, payload.count <= maximumBytes - 96 else { throw StreamError.sizeLimit }
        var packet = Data(repeating: 0, count: 96)
        packet.put(Data("S3DC".utf8), at: 0)
        packet.putLE(UInt16(1), at: 4); packet.putLE(UInt16(96), at: 6)
        packet.putLE(UInt32(last ? 1 : 0), at: 8); packet.putLE(index, at: 12)
        packet.put(sessionID.wireBytes, at: 16); packet.putLE(fileID, at: 32)
        packet.putLE(offset, at: 40); packet.putLE(UInt32(payload.count), at: 48)
        packet.put(Data(SHA256.hash(data: payload)), at: 56)
        packet.append(payload)
        return packet
    }

    private static func validatePose(_ matrix: [Float]) throws {
        guard matrix.count == 16, matrix.allSatisfy({ $0.isFinite }),
              Array(matrix[12...15]) == [0, 0, 0, 1] else { throw StreamError.invalid("pose layout") }
        for colA in 0..<3 {
            for colB in 0..<3 {
                let dot = (0..<3).reduce(0.0) { $0 + Double(matrix[$1 * 4 + colA]) * Double(matrix[$1 * 4 + colB]) }
                guard abs(dot - (colA == colB ? 1 : 0)) <= 1e-3 else { throw StreamError.invalid("pose orthogonality") }
            }
        }
        let m = matrix.map(Double.init)
        let determinant = m[0] * (m[5] * m[10] - m[6] * m[9])
                        - m[1] * (m[4] * m[10] - m[6] * m[8])
                        + m[2] * (m[4] * m[9] - m[5] * m[8])
        guard determinant > 0 else { throw StreamError.invalid("pose handedness") }
    }
}

extension UUID {
    var wireBytes: Data { Swift.withUnsafeBytes(of: uuid) { Data($0) } }
    var isZero: Bool { wireBytes.allSatisfy({ $0 == 0 }) }
}

extension Data {
    mutating func put(_ bytes: Data, at offset: Int) { replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    mutating func putLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { put(Data($0), at: offset) }
    }
    mutating func putIntrinsics(_ intrinsic: Intrinsics?, at offset: Int) {
        guard let intrinsic else { return }
        putLE(UInt32(intrinsic.width), at: offset); putLE(UInt32(intrinsic.height), at: offset + 4)
        for (index, value) in [intrinsic.fx, intrinsic.fy, intrinsic.cx, intrinsic.cy].enumerated() {
            putLE(value.bitPattern, at: offset + 8 + 4 * index)
        }
    }
}
