import Foundation

/// Inclusive chunk-index range kept in memory as {first, last}. The wire form is `IDRange` {first, count}.
public struct DurableRange: Codable, Equatable, Sendable {
    public let first: UInt32
    public let last: UInt32
    public init(first: UInt32, last: UInt32) { self.first = first; self.last = last }
}

/// Wire `common.schema.json#/$defs/id_range`: {first, count >= 1}, uint53 bounded. Used for file-id runs
/// (`files_complete`) and chunk-index runs (`chunks`, `chunks_durable`).
public struct IDRange: Codable, Equatable, Hashable, Sendable {
    public let first: UInt64
    public let count: UInt64
    public init(first: UInt64, count: UInt64) { self.first = first; self.count = count }

    static let uint53: UInt64 = (1 << 53) - 1

    /// Checked: count >= 1, first + count - 1 <= 2^53 - 1.
    public var lastChecked: UInt64? {
        guard count >= 1, first <= IDRange.uint53, count <= IDRange.uint53 else { return nil }
        let (end, overflow) = first.addingReportingOverflow(count - 1)
        guard !overflow, end <= IDRange.uint53 else { return nil }
        return end
    }

    /// Converts a chunk-index run into a DurableRange that must lie inside [0, total).
    public func toDurable(total: UInt64) throws -> DurableRange {
        guard let last = lastChecked, last < total, last <= UInt64(UInt32.max) else {
            throw StreamError.invalid("chunk range outside the file")
        }
        return DurableRange(first: UInt32(first), last: UInt32(last))
    }

    public static func from(_ range: DurableRange) -> IDRange {
        IDRange(first: UInt64(range.first), count: UInt64(range.last) - UInt64(range.first) + 1)
    }
}

/// One immutable closed original file. The caller persists only what it must (chunk size) and supplies verified
/// PC ACKs. Socket-send completion NEVER calls acknowledge. This model never removes or alters original file bytes.
public struct OriginalTransfer: Codable, Sendable {
    public let sessionID: UUID
    public let fileID: UInt64
    public let fileBytes: UInt64
    public let fileSHA256: String
    public private(set) var chunkBytes: UInt32?
    public private(set) var ranges: [DurableRange] = []
    public private(set) var fileComplete = false

    public init(sessionID: UUID, fileID: UInt64, fileBytes: UInt64, fileSHA256: String) throws {
        guard !sessionID.isZero, fileID < 1 << 53, fileBytes < 1 << 53 else { throw StreamError.invalid("original identity") }
        _ = try PairingIdentity.fingerprintBytes(fileSHA256)
        self.sessionID = sessionID; self.fileID = fileID; self.fileBytes = fileBytes; self.fileSHA256 = fileSHA256
    }

    /// `maximumBinaryBytes` is the negotiated `hello.limits.max_binary_bytes`; the contract requires chunk + 96 <= it.
    public mutating func acceptOffer(chunkBytes value: UInt32,
                                     maximumBinaryBytes: Int = PacketEncoder.schemaMaximumBinaryBytes) throws {
        guard value >= 65536, value % 65536 == 0, Int(value) <= PacketEncoder.schemaMaximumChunkBytes,
              maximumBinaryBytes <= PacketEncoder.schemaMaximumBinaryBytes,
              Int(value) + 96 <= maximumBinaryBytes else {
            throw StreamError.invalid("immutable chunk size")
        }
        if let previous = chunkBytes, previous != value { throw StreamError.invalid("chunk size changed across reconnect") }
        let total = max(UInt64(1), (fileBytes + UInt64(value) - 1) / UInt64(value))
        guard total <= UInt64(UInt32.max) else { throw StreamError.sizeLimit }
        chunkBytes = value
    }

    public var chunksTotal: UInt64? {
        guard let chunkBytes else { return nil }
        return max(1, (fileBytes + UInt64(chunkBytes) - 1) / UInt64(chunkBytes))
    }

    /// Merge PC-verified durable ranges. `complete: true` (a PC `file_complete`, a resume `files_complete` entry or
    /// an offer `state: complete`) is AUTHORITATIVE: the PC has hashed and durably renamed the whole file, so every
    /// chunk is durable even if earlier ACKs were lost. Listed ranges are still bounds-checked.
    public mutating func acknowledge(_ incoming: [DurableRange], complete: Bool = false) throws {
        guard let total = chunksTotal else { throw StreamError.invalid("ACK before offer") }
        for range in incoming {
            guard range.first <= range.last, UInt64(range.last) < total else { throw StreamError.invalid("ACK range") }
        }
        if complete {
            ranges = [DurableRange(first: 0, last: UInt32(total - 1))]
            fileComplete = true
            return
        }
        // Normalise first, then bound the normalised size (an update that merges fragments must not be rejected).
        var merged: [DurableRange] = []
        merged.reserveCapacity(ranges.count + incoming.count)
        for range in (ranges + incoming).sorted(by: { $0.first < $1.first }) {
            if let previous = merged.last, UInt64(range.first) <= UInt64(previous.last) + 1 {
                merged[merged.count - 1] = DurableRange(first: previous.first, last: max(previous.last, range.last))
            } else { merged.append(range) }
        }
        guard merged.count <= 65536 else { throw StreamError.sizeLimit }
        ranges = merged
    }

    public func isDurable(_ index: UInt32) -> Bool {
        if fileComplete { return true }
        return ranges.contains { $0.first <= index && index <= $0.last }
    }

    public var durableCount: UInt64 {
        ranges.reduce(UInt64(0)) { $0 + UInt64($1.last) - UInt64($1.first) + 1 }
    }

    public func nextMissingIndex(from start: UInt64 = 0) throws -> UInt32? {
        guard let total = chunksTotal else { throw StreamError.invalid("missing chunk size") }
        if fileComplete { return nil }
        var index = start
        for range in ranges {
            if index < UInt64(range.first) { break }
            if index <= UInt64(range.last) { index = UInt64(range.last) + 1 }
        }
        return index < total ? UInt32(index) : nil
    }

    /// Apply the server's verified resend_file action without touching immutable source bytes.
    /// The assigned chunk size must not change. Retry limits live in `OriginalsPlanner`.
    public mutating func restartAfterFileNack() {
        ranges.removeAll(); fileComplete = false
    }

    /// Restored data is untrusted: decoding Codable alone does not establish invariants.
    public static func restore(_ data: Data) throws -> OriginalTransfer {
        guard data.count <= 8 * 1024 * 1024 else { throw StreamError.sizeLimit }
        let decoded = try JSONDecoder().decode(OriginalTransfer.self, from: data)
        var validated = try OriginalTransfer(sessionID: decoded.sessionID, fileID: decoded.fileID,
                                             fileBytes: decoded.fileBytes, fileSHA256: decoded.fileSHA256)
        if let size = decoded.chunkBytes { try validated.acceptOffer(chunkBytes: size) }
        guard decoded.chunkBytes != nil || (decoded.ranges.isEmpty && !decoded.fileComplete) else {
            throw StreamError.invalid("restored ACK without offer")
        }
        if decoded.chunkBytes != nil { try validated.acknowledge(decoded.ranges, complete: decoded.fileComplete) }
        return validated
    }
}
