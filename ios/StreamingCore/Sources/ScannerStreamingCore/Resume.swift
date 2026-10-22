import Foundation

/// One `originals.resume` response page (contract section 6, step 1).
public struct ResumePage: Decodable, Sendable, Equatable {
    public struct PartialFile: Decodable, Sendable, Equatable {
        public let fileID: UInt64, chunkBytes: UInt32, chunksDurable: [IDRange]
        enum CodingKeys: String, CodingKey { case fileID = "file_id", chunkBytes = "chunk_bytes", chunksDurable = "chunks_durable" }
        public init(fileID: UInt64, chunkBytes: UInt32, chunksDurable: [IDRange]) {
            self.fileID = fileID; self.chunkBytes = chunkBytes; self.chunksDurable = chunksDurable
        }
    }
    public let sessionID: UUID
    public let snapshotRev: UInt64
    public let known: Bool
    public let manifestSeqDurable: UInt32?
    public let finalManifestReceived: Bool
    public let filesComplete: [IDRange]
    public let filesPartial: [PartialFile]
    public let allComplete: Bool
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", snapshotRev = "snapshot_rev", known, manifestSeqDurable = "manifest_seq_durable"
        case finalManifestReceived = "final_manifest_received", filesComplete = "files_complete"
        case filesPartial = "files_partial", allComplete = "all_complete", nextCursor = "next_cursor"
    }
    public init(sessionID: UUID, snapshotRev: UInt64, known: Bool, manifestSeqDurable: UInt32?,
                finalManifestReceived: Bool, filesComplete: [IDRange], filesPartial: [PartialFile],
                allComplete: Bool, nextCursor: String?) {
        self.sessionID = sessionID; self.snapshotRev = snapshotRev; self.known = known
        self.manifestSeqDurable = manifestSeqDurable; self.finalManifestReceived = finalManifestReceived
        self.filesComplete = filesComplete; self.filesPartial = filesPartial; self.allComplete = allComplete
        self.nextCursor = nextCursor
    }
}

/// The union of one snapshot's pages (port of `preview_codec.merge_resume_pages`, without expanding ranges).
public struct ResumeSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let snapshotRev: UInt64
    public let known: Bool
    public let manifestSeqDurable: UInt32?
    public let finalManifestReceived: Bool
    /// Normalised, sorted, non-adjacent inclusive file-id runs.
    public let completeFiles: [ClosedRange<UInt64>]
    public let partial: [UInt64: (chunkBytes: UInt32, ranges: [DurableRange])]
    public let allComplete: Bool

    public static func == (a: ResumeSnapshot, b: ResumeSnapshot) -> Bool {
        a.sessionID == b.sessionID && a.snapshotRev == b.snapshotRev && a.completeFiles == b.completeFiles &&
            a.allComplete == b.allComplete && a.manifestSeqDurable == b.manifestSeqDurable &&
            a.partial.keys.sorted() == b.partial.keys.sorted()
    }

    public func isComplete(_ fileID: UInt64) -> Bool {
        // Binary search over sorted runs.
        var low = 0, high = completeFiles.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let run = completeFiles[mid]
            if fileID < run.lowerBound { high = mid - 1 } else if fileID > run.upperBound { low = mid + 1 } else { return true }
        }
        return false
    }

    /// files_complete covers exactly [0, total) (and nothing is partial).
    public func coversAll(total: UInt64) -> Bool {
        guard partial.isEmpty else { return false }
        if total == 0 { return completeFiles.isEmpty }
        return completeFiles.count == 1 && completeFiles[0].lowerBound == 0 && completeFiles[0].upperBound == total - 1
    }

    public var completeCount: UInt64 {
        completeFiles.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound + 1) }
    }
}

/// Accumulates pages of ONE answer: same session and snapshot_rev, following next_cursor, until next_cursor null.
/// `all_complete` is meaningful only on the returned snapshot (the next_cursor-null page). On `cursor_invalid`
/// the caller discards the accumulator and restarts with cursor null.
public struct ResumeAccumulator: Sendable {
    public let sessionID: UUID
    public private(set) var expectedCursor: String?
    private var snapshotRev: UInt64?
    private var first: ResumePage?
    private var complete: [ClosedRange<UInt64>] = []
    private var partial: [UInt64: (chunkBytes: UInt32, ranges: [DurableRange])] = [:]
    public private(set) var pages = 0
    public static let maximumPages = 100_000

    public init(sessionID: UUID) { self.sessionID = sessionID }

    /// Returns the merged snapshot after the last page; nil means "request the next page with `expectedCursor`".
    public mutating func add(_ page: ResumePage) throws -> ResumeSnapshot? {
        guard page.sessionID == sessionID else { throw StreamError.invalid("resume page for another session") }
        if let snapshotRev, snapshotRev != page.snapshotRev { throw StreamError.invalid("resume pages from different snapshots") }
        if let first {
            guard first.manifestSeqDurable == page.manifestSeqDurable, first.allComplete == page.allComplete,
                  first.finalManifestReceived == page.finalManifestReceived, first.known == page.known else {
                throw StreamError.invalid("resume pages disagree")
            }
        }
        pages += 1
        guard pages <= ResumeAccumulator.maximumPages else { throw StreamError.sizeLimit }
        snapshotRev = page.snapshotRev
        if first == nil { first = page }
        for run in page.filesComplete {
            guard let last = run.lastChecked else { throw StreamError.invalid("files_complete range") }
            complete.append(run.first...last)
        }
        for file in page.filesPartial {
            guard file.fileID < 1 << 53, !file.chunksDurable.isEmpty else { throw StreamError.invalid("files_partial") }
            guard file.chunkBytes >= 65536, file.chunkBytes % 65536 == 0,
                  Int(file.chunkBytes) <= PacketEncoder.schemaMaximumChunkBytes else {
                throw StreamError.invalid("files_partial chunk_bytes")
            }
            var entry: (chunkBytes: UInt32, ranges: [DurableRange]) = partial[file.fileID] ?? (chunkBytes: file.chunkBytes, ranges: [])
            guard entry.chunkBytes == file.chunkBytes else { throw StreamError.invalid("chunk_bytes changed between pages") }
            for run in file.chunksDurable {
                guard let last = run.lastChecked, last <= UInt64(UInt32.max) else { throw StreamError.invalid("chunk range") }
                let range = DurableRange(first: UInt32(run.first), last: UInt32(last))
                if entry.ranges.contains(where: { $0.first <= range.last && range.first <= $0.last }) {
                    throw StreamError.invalid("overlapping durable ranges")
                }
                entry.ranges.append(range)
            }
            partial[file.fileID] = entry
        }
        expectedCursor = page.nextCursor
        guard page.nextCursor == nil else { return nil }

        // Normalise complete runs.
        var merged: [ClosedRange<UInt64>] = []
        for run in complete.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, run.lowerBound <= last.upperBound &+ 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, run.upperBound)
            } else { merged.append(run) }
        }
        var sortedPartial: [UInt64: (chunkBytes: UInt32, ranges: [DurableRange])] = [:]
        for (fileID, entry) in partial {
            sortedPartial[fileID] = (chunkBytes: entry.chunkBytes,
                                     ranges: entry.ranges.sorted(by: { a, b in a.first < b.first }))
        }
        let snapshot = ResumeSnapshot(sessionID: sessionID, snapshotRev: page.snapshotRev, known: page.known,
                                      manifestSeqDurable: page.manifestSeqDurable,
                                      finalManifestReceived: page.finalManifestReceived, completeFiles: merged,
                                      partial: sortedPartial,
                                      allComplete: page.allComplete)
        for fileID in partial.keys where snapshot.isComplete(fileID) {
            throw StreamError.invalid("a file is both complete and partial")
        }
        return snapshot
    }
}
