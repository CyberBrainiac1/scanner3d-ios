import Foundation

/// One closed, immutable original (`common.schema.json#/$defs/file_entry`).
public struct LocalFile: Codable, Sendable, Hashable {
    public let fileID: UInt64
    public let path: String
    public let kind: String
    public let bytes: UInt64
    public let sha256: String
    public let segment: UInt32?

    public init(fileID: UInt64, path: String, kind: String, bytes: UInt64, sha256: String, segment: UInt32?) throws {
        guard fileID < 1 << 53, bytes < 1 << 53, LocalFile.isValidSessionPath(path),
              LocalFile.kinds.contains(kind), segment.map({ $0 <= 999_999 }) ?? true else {
            throw StreamError.invalid("file entry")
        }
        _ = try PairingIdentity.fingerprintBytes(sha256)
        self.fileID = fileID; self.path = path; self.kind = kind; self.bytes = bytes; self.sha256 = sha256
        self.segment = segment
    }

    public static let kinds: Set<String> = [
        "session_meta", "session_end", "segments_csv", "frames_csv", "events_csv", "video", "depth_f32",
        "confidence_u8", "still_image", "still_meta", "still_depth_f32", "still_confidence_u8", "accel_csv",
        "gyro_csv", "device_motion_csv", "calibration", "log",
    ]

    public var json: JSONValue {
        .object(["file_id": .int(fileID), "path": .string(path), "kind": .string(kind), "bytes": .int(bytes),
                 "sha256": .string(sha256), "segment": .int(segment)])
    }

    /// `common.schema.json#/$defs/session_path`: forward slashes, [A-Za-z0-9_.-], 1-8 segments of 1-64 chars,
    /// no "." or ".." segment, no leading slash, at most 200 characters.
    public static func isValidSessionPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 200 else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...8).contains(parts.count) else { return false }
        for part in parts {
            guard (1...64).contains(part.utf8.count), part != ".", part != ".." else { return false }
            guard part.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 95 || $0 == 46 || $0 == 45 }) else { return false }
        }
        return true
    }
}

/// A manifest seq is journaled (with its JCS identity) BEFORE it is first sent, so a retransmission after a
/// reconnect or app restart is byte-for-byte the same body (Decision (b)/(i)).
public struct ManifestBatch: Codable, Sendable, Equatable {
    public let seq: UInt32
    public let fileIDs: [UInt64]
    public let final: Bool
    public let totalFiles: UInt64?
    public var identity: String?
}

/// The small per-session state the phone must persist for uploads. Durable chunk state is NOT persisted here:
/// the PC's journal is authoritative and `originals.resume` re-reports it on every connection.
public struct UploadJournal: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public var batches: [ManifestBatch] = []
    /// file_id (decimal) -> immutable chunk size first assigned by the PC.
    public var chunkBytesByFile: [String: UInt32] = [:]
    /// file_id (decimal) -> number of whole-file `resend_file` nacks (limit 2).
    public var fileNackCounts: [String: Int] = [:]
    /// file_id (decimal) -> reason. Failed files are kept on the phone and reported in Scans.
    public var failedFiles: [String: String] = [:]
    /// Set only from a fresh resume: final manifest durable, all_complete, files_complete == [0, total_files).
    public var pcConfirmedComplete = false

    public init(sessionID: UUID) { self.sessionID = sessionID }
}

public struct ChunkKey: Hashable, Sendable { public let fileID: UInt64; public let index: UInt32 }

public struct ChunkRequest: Sendable, Equatable {
    public let fileID: UInt64
    public let index: UInt32
    public let chunkBytes: Int
    public let offset: UInt64
    public let length: Int
    public let last: Bool
    public let path: String
}

public enum NackOutcome: Sendable, Equatable {
    case resend
    case fileRestarted
    case retryLater(milliseconds: Int?)
    case fileFailed(String)
    case resume
}

public struct UploadProgress: Sendable, Equatable {
    public var filesKnown: Int
    public var filesCompleteOnPC: Int
    public var filesFailed: Int
    public var bytesTotal: UInt64
    public var bytesDurable: UInt64
    public var bytesPending: UInt64 { bytesTotal > bytesDurable ? bytesTotal - bytesDurable : 0 }
    public var fraction: Double { bytesTotal == 0 ? (filesKnown == 0 ? 0 : 1) : Double(bytesDurable) / Double(bytesTotal) }
}

/// Pure upload state machine for ONE session on one originals connection (contract section 6). The socket adapter
/// feeds it verified PC messages and asks it what to send next. It never deletes or alters files.
public struct OriginalsPlanner: Sendable {
    public static let chunkChecksumFailureLimit = 3
    public static let fileFailureLimit = 2
    public static let maximumOfferFiles = 256

    public let sessionID: UUID
    public private(set) var journal: UploadJournal
    public private(set) var files: [UInt64: LocalFile] = [:]
    public private(set) var totalFiles: UInt64?
    public private(set) var manifestSeqDurable: UInt32?
    public private(set) var haveResume = false
    private var completeOnPC: Set<UInt64> = []
    private var transfers: [UInt64: OriginalTransfer] = [:]
    private var offerOrder: [UInt64] = []
    private var inFlight: Set<ChunkKey> = []
    private var chunkFailures: [ChunkKey: Int] = [:]
    private var resumePartial: [UInt64: (chunkBytes: UInt32, ranges: [DurableRange])] = [:]

    public init(journal: UploadJournal, files: [LocalFile] = [], totalFiles: UInt64? = nil) {
        self.sessionID = journal.sessionID
        self.journal = journal
        // A saved deletion gate is historical. Each new connection requires a fresh PC snapshot.
        self.journal.pcConfirmedComplete = false
        for file in files { self.files[file.fileID] = file }
        self.totalFiles = totalFiles
    }

    // MARK: Local catalog

    public mutating func addClosedFiles(_ new: [LocalFile]) throws {
        for file in new {
            if let existing = files[file.fileID], existing != file { throw StreamError.invalid("file_id redefined locally") }
            files[file.fileID] = file
        }
    }

    /// After session_end.json is closed: the catalog is exactly [0, total).
    public mutating func setFinal(totalFiles total: UInt64) throws {
        guard UInt64(files.count) == total, (0..<total).allSatisfy({ files[$0] != nil }) else {
            throw StreamError.invalid("catalog is not exactly [0, total_files)")
        }
        totalFiles = total
    }

    // MARK: Manifest

    private var finalBatch: ManifestBatch? { journal.batches.last(where: { $0.final }) }

    public func manifestBody(_ batch: ManifestBatch) throws -> JSONValue {
        let entries = try batch.fileIDs.map { id -> LocalFile in
            guard let file = files[id] else { throw StreamError.invalid("manifest entry missing locally") }
            return file
        }
        return Wire.manifest(sessionID: sessionID, seq: batch.seq, final: batch.final, totalFiles: batch.totalFiles,
                             files: entries)
    }

    /// The next manifest seq to send: an already journaled seq the PC has not made durable (resent with an
    /// identical body), else a newly journaled batch. `flushPartial` lets the caller decide when a non-final
    /// batch is worth sending during capture. The caller MUST persist `journal` before sending a new batch.
    public mutating func nextManifestBatch(maximumEntries: Int, flushPartial: Bool) throws -> (batch: ManifestBatch, body: JSONValue)? {
        let nextSeq: UInt32 = manifestSeqDurable.map { $0 + 1 } ?? 0
        if Int(nextSeq) < journal.batches.count {
            let batch = journal.batches[Int(nextSeq)]
            guard batch.seq == nextSeq else { throw StreamError.invalid("journal seq order") }
            let body = try manifestBody(batch)
            if let identity = batch.identity, identity != (try JCS.identity(body)) {
                throw StreamError.invalid("manifest seq \(batch.seq) changed since first sent")
            }
            return (batch, body)
        }
        guard Int(nextSeq) == journal.batches.count, finalBatch == nil else { return nil }
        let batched = Set(journal.batches.flatMap { $0.fileIDs })
        let pending = files.keys.filter { !batched.contains($0) }.sorted()
        let limit = max(1, min(1000, maximumEntries))
        let batch: ManifestBatch
        if let total = totalFiles, pending.count <= limit {
            batch = ManifestBatch(seq: nextSeq, fileIDs: pending, final: true, totalFiles: total, identity: nil)
        } else if !pending.isEmpty && (flushPartial || pending.count >= limit || totalFiles != nil) {
            batch = ManifestBatch(seq: nextSeq, fileIDs: Array(pending.prefix(limit)), final: false, totalFiles: nil,
                                  identity: nil)
        } else {
            return nil
        }
        var journaled = batch
        let body = try manifestBody(batch)
        journaled.identity = try JCS.identity(body)
        journal.batches.append(journaled)
        return (journaled, body)
    }

    public mutating func manifestAccepted(seqDurable: UInt32) throws {
        guard Int(seqDurable) < journal.batches.count else { throw StreamError.invalid("PC made an unsent seq durable") }
        manifestSeqDurable = max(manifestSeqDurable ?? 0, seqDurable)
    }

    private func isManifested(_ fileID: UInt64) -> Bool {
        guard let durable = manifestSeqDurable else { return false }
        return journal.batches.prefix(Int(durable) + 1).contains { $0.fileIDs.contains(fileID) }
    }

    // MARK: Resume

    public mutating func applyResume(_ snapshot: ResumeSnapshot) throws {
        guard snapshot.sessionID == sessionID else { throw StreamError.invalid("resume for another session") }
        guard snapshot.known || (snapshot.manifestSeqDurable == nil && !snapshot.finalManifestReceived &&
                                  !snapshot.allComplete && snapshot.completeFiles.isEmpty && snapshot.partial.isEmpty),
              !snapshot.allComplete || snapshot.finalManifestReceived,
              !snapshot.finalManifestReceived || snapshot.manifestSeqDurable != nil else {
            throw StreamError.invalid("inconsistent resume state")
        }
        if let durable = snapshot.manifestSeqDurable, Int(durable) >= journal.batches.count {
            throw StreamError.invalid("PC holds manifest seqs this phone never sent")
        }
        manifestSeqDurable = snapshot.manifestSeqDurable
        // Reconcile rather than union: the PC may have restored an earlier backup or lost its data.
        completeOnPC = Set(files.keys.filter { snapshot.isComplete($0) })
        journal.pcConfirmedComplete = false
        resumePartial = [:]
        transfers = [:]; offerOrder = []; inFlight = []
        for (fileID, entry) in snapshot.partial where files[fileID] != nil {
            if let recorded = journal.chunkBytesByFile[String(fileID)], recorded != entry.chunkBytes {
                throw StreamError.invalid("chunk_bytes changed for file \(fileID)")
            }
            journal.chunkBytesByFile[String(fileID)] = entry.chunkBytes
            resumePartial[fileID] = entry
        }
        haveResume = true
        if let total = totalFiles, let final = finalBatch, let durable = manifestSeqDurable, durable >= final.seq,
           snapshot.known, snapshot.allComplete, snapshot.finalManifestReceived, snapshot.coversAll(total: total) {
            journal.pcConfirmedComplete = true
        }
    }

    /// True when every local file is complete on the PC and the final manifest is durable, but the deletion gate
    /// still needs a FRESH resume (requested now) to confirm it.
    public var needsConfirmationResume: Bool {
        guard !journal.pcConfirmedComplete, let total = totalFiles, let final = finalBatch,
              let durable = manifestSeqDurable, durable >= final.seq else { return false }
        return UInt64(completeOnPC.count) == total
    }

    /// "Remove from phone" may be OFFERED (the user still taps and confirms).
    public var canOfferRemoval: Bool { journal.pcConfirmedComplete }

    // MARK: Offer

    public func filesToOffer(maximum: Int = OriginalsPlanner.maximumOfferFiles) -> [UInt64] {
        guard haveResume else { return [] }
        let offered = Set(offerOrder)
        return files.keys.filter {
            !completeOnPC.contains($0) && !offered.contains($0) && journal.failedFiles[String($0)] == nil && isManifested($0)
        }.sorted().prefix(max(1, min(OriginalsPlanner.maximumOfferFiles, maximum))).map { $0 }
    }

    /// Returns file ids that failed validation (marked failed, kept on the phone).
    @discardableResult
    public mutating func applyOffer(_ response: OfferResponse, maximumBinaryBytes: Int) throws -> [UInt64] {
        guard response.sessionID == sessionID else { throw StreamError.invalid("offer for another session") }
        var failed: [UInt64] = []
        for entry in response.files {
            guard let file = files[entry.fileID] else { continue }
            if entry.state == "complete" {
                completeOnPC.insert(entry.fileID); transfers[entry.fileID] = nil
                continue
            }
            guard entry.state == "need" || entry.state == "partial" else { throw StreamError.invalid("offer state") }
            if let recorded = journal.chunkBytesByFile[String(entry.fileID)], recorded != entry.chunkBytes {
                markFailed(entry.fileID, reason: "chunk_size_changed"); failed.append(entry.fileID); continue
            }
            var transfer = try transfers[entry.fileID] ?? OriginalTransfer(sessionID: sessionID, fileID: file.fileID,
                                                                           fileBytes: file.bytes, fileSHA256: file.sha256)
            do {
                try transfer.acceptOffer(chunkBytes: entry.chunkBytes, maximumBinaryBytes: maximumBinaryBytes)
                guard transfer.chunksTotal == UInt64(entry.chunksTotal) else { throw StreamError.invalid("chunks_total") }
                if entry.state == "partial", let partial = resumePartial[entry.fileID] {
                    try transfer.acknowledge(partial.ranges)
                }
            } catch {
                markFailed(entry.fileID, reason: "offer_invalid"); failed.append(entry.fileID); continue
            }
            journal.chunkBytesByFile[String(entry.fileID)] = entry.chunkBytes
            transfers[entry.fileID] = transfer
            if !offerOrder.contains(entry.fileID) { offerOrder.append(entry.fileID) }
        }
        return failed
    }

    // MARK: Chunks

    public var inFlightCount: Int { inFlight.count }

    public mutating func nextChunk(window: Int) -> ChunkRequest? {
        guard inFlight.count < max(1, window) else { return nil }
        for fileID in offerOrder {
            guard !completeOnPC.contains(fileID), journal.failedFiles[String(fileID)] == nil,
                  let transfer = transfers[fileID], let chunkBytes = transfer.chunkBytes,
                  let total = transfer.chunksTotal, let file = files[fileID] else { continue }
            var start: UInt64 = 0
            while let index = try? transfer.nextMissingIndex(from: start) {
                let key = ChunkKey(fileID: fileID, index: index)
                if inFlight.contains(key) { start = UInt64(index) + 1; continue }
                let offset = UInt64(index) * UInt64(chunkBytes)
                let length = Int(min(UInt64(chunkBytes), file.bytes > offset ? file.bytes - offset : 0))
                inFlight.insert(key)
                return ChunkRequest(fileID: fileID, index: index, chunkBytes: Int(chunkBytes), offset: offset,
                                    length: length, last: UInt64(index) == total - 1, path: file.path)
            }
        }
        return nil
    }

    /// A chunk whose send failed locally (socket error) was never received; make it eligible again.
    public mutating func chunkNotSent(_ request: ChunkRequest) {
        inFlight.remove(ChunkKey(fileID: request.fileID, index: request.index))
    }

    public mutating func applyAck(_ ack: OriginalsAck) throws {
        guard ack.sessionID == sessionID else { throw StreamError.invalid("ack for another session") }
        for fileAck in ack.acks {
            if fileAck.fileComplete {
                guard files[fileAck.fileID] != nil else { continue }
                completeOnPC.insert(fileAck.fileID)
                if var transfer = transfers[fileAck.fileID] {
                    try transfer.acknowledge([], complete: true)
                    transfers[fileAck.fileID] = nil
                }
                inFlight = inFlight.filter { $0.fileID != fileAck.fileID }
                offerOrder.removeAll { $0 == fileAck.fileID }
                continue
            }
            guard var transfer = transfers[fileAck.fileID], let total = transfer.chunksTotal else { continue }
            let ranges = try fileAck.chunks.map { try $0.toDurable(total: total) }
            try transfer.acknowledge(ranges)
            transfers[fileAck.fileID] = transfer
            inFlight = inFlight.filter { key in
                key.fileID != fileAck.fileID || !ranges.contains { $0.first <= key.index && key.index <= $0.last }
            }
        }
    }

    public mutating func applyNack(_ nack: OriginalsNack) -> NackOutcome {
        guard nack.sessionID == sessionID, files[nack.fileID] != nil else { return .resume }
        if let index = nack.chunkIndex { inFlight.remove(ChunkKey(fileID: nack.fileID, index: index)) }
        if nack.reason == "file_conflict" || nack.action == "give_up" {
            markFailed(nack.fileID, reason: nack.reason)
            return .fileFailed(nack.reason)
        }
        switch nack.action {
        case "resend_chunk":
            guard let index = nack.chunkIndex else { return .resume }
            let key = ChunkKey(fileID: nack.fileID, index: index)
            let failures = (chunkFailures[key] ?? 0) + 1
            chunkFailures[key] = failures
            if failures >= OriginalsPlanner.chunkChecksumFailureLimit {
                markFailed(nack.fileID, reason: nack.reason)
                return .fileFailed(nack.reason)
            }
            return .resend
        case "resend_file":
            let key = String(nack.fileID)
            let failures = (journal.fileNackCounts[key] ?? 0) + 1
            journal.fileNackCounts[key] = failures
            if failures >= OriginalsPlanner.fileFailureLimit {
                markFailed(nack.fileID, reason: nack.reason)
                return .fileFailed(nack.reason)
            }
            transfers[nack.fileID]?.restartAfterFileNack()
            inFlight = inFlight.filter { $0.fileID != nack.fileID }
            return .fileRestarted
        case "retry_later":
            return .retryLater(milliseconds: nack.retryAfterMs)
        default:
            return .resume
        }
    }

    private mutating func markFailed(_ fileID: UInt64, reason: String) {
        journal.failedFiles[String(fileID)] = reason
        transfers[fileID] = nil
        inFlight = inFlight.filter { $0.fileID != fileID }
        offerOrder.removeAll { $0 == fileID }
    }

    /// Disconnect: in-flight chunks and offers are forgotten; resume will re-establish durable state.
    public mutating func connectionReset() {
        inFlight = []; offerOrder = []; transfers = [:]; resumePartial = [:]; haveResume = false
        manifestSeqDurable = nil; chunkFailures = [:]
    }

    // MARK: Progress

    public var progress: UploadProgress {
        var total: UInt64 = 0, durable: UInt64 = 0
        for file in files.values {
            total += file.bytes
            if completeOnPC.contains(file.fileID) { durable += file.bytes; continue }
            if let transfer = transfers[file.fileID], let chunk = transfer.chunkBytes {
                durable += min(file.bytes, transfer.durableCount * UInt64(chunk))
            }
        }
        return UploadProgress(filesKnown: files.count, filesCompleteOnPC: completeOnPC.count,
                              filesFailed: journal.failedFiles.count, bytesTotal: total, bytesDurable: durable)
    }

    public var hasPendingWork: Bool {
        if journal.pcConfirmedComplete { return false }
        let remaining = files.keys.contains { !completeOnPC.contains($0) && journal.failedFiles[String($0)] == nil }
        return remaining || finalBatch == nil || needsConfirmationResume
    }
}
