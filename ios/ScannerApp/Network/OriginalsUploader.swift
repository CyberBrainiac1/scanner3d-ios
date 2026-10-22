import Foundation
import ScannerStreamingCore

/// One session on one pinned originals socket. StreamingCore is authoritative for chunk windows,
/// immutable manifest identities, file retries and fresh all-complete confirmation.
actor OriginalsUploader {
    private let store: OriginalStore
    private let connection: StreamConnection
    private let limits: HelloResponse.Limits
    private let journalURL: URL
    private var planner: OriginalsPlanner
    private var checkedFiles: Set<UInt64> = []
    private var sending: [UInt64: ChunkRequest] = [:]
    private var nextTag: UInt64 = 0
    private var catalogCount: Int
    private var enabled = true
    private var window: Int
    private var bytesPerSecond: Double?
    private var nextSendTime: Double = 0
    private var retryUntil: Double = 0
    private var needsResume = true
    private var lastAck = ProcessInfo.processInfo.systemUptime
    private let onProgress: @Sendable (UUID, UploadProgress, Bool) -> Void

    init(store: OriginalStore, connection: StreamConnection, hello: HelloResponse,
         onProgress: @escaping @Sendable (UUID, UploadProgress, Bool) -> Void) throws {
        self.store = store; self.connection = connection; limits = hello.limits; window = hello.limits.windowChunks
        self.onProgress = onProgress
        // Completion for a different PC cannot authorize removal or suppress this PC's upload.
        guard UUID(uuidString: hello.pc.pcID) != nil else { throw StreamError.invalid("PC identity") }
        journalURL = store.directory.appendingPathComponent("upload-\(hello.pc.pcID).json")
        let saved = FileManager.default.fileExists(atPath: journalURL.path)
            ? try JSONDecoder().decode(UploadJournal.self, from: Data(contentsOf: journalURL))
            : UploadJournal(sessionID: store.sessionID)
        guard saved.sessionID == store.sessionID else { throw StreamError.invalid("Upload journal session") }
        let local = store.snapshot
        planner = OriginalsPlanner(journal: saved, files: local.files)
        catalogCount = local.files.count
        if local.finalized { try planner.setFinal(totalFiles: UInt64(local.files.count)) }
    }

    func run() async throws {
        await connection.binarySource({ [weak self] now in try await self?.next(now: now) },
                                      done: { [weak self] tag, sent in await self?.sent(tag, delivered: sent) })
        defer { Task { await connection.binarySource(nil, done: nil) } }
        while !Task.isCancelled {
            if await connection.isClosed { throw StreamConnection.Failure.disconnected }
            let snapshot = store.snapshot
            let local = snapshot.files
            guard local.count >= catalogCount else { throw StreamError.invalid("Local original catalog shrank") }
            if local.count > catalogCount {
                try planner.addClosedFiles(Array(local.dropFirst(catalogCount))); catalogCount = local.count
            }
            if snapshot.finalized, planner.totalFiles == nil { try planner.setFinal(totalFiles: UInt64(local.count)) }
            let now = ProcessInfo.processInfo.systemUptime
            if needsResume || planner.needsConfirmationResume || (enabled && now - lastAck > 10) {
                // Stop binary scheduling while the PC gives a consistent paginated snapshot.
                needsResume = true
                try await resume()
                needsResume = false; lastAck = now
            }
            if let next = try planner.nextManifestBatch(maximumEntries: min(1000, max(1, (limits.maxTextBytes - 4096) / 600)), flushPartial: true) {
                try persist() // Identity is durable before the first transmission.
                let response = try await connection.request("originals.manifest", next.body)
                guard case .manifestResponse(_, let accepted) = response, accepted.sessionID == store.sessionID else {
                    throw StreamConnection.Failure.wrongReply
                }
                try planner.manifestAccepted(seqDurable: accepted.manifestSeqDurable)
                try persist()
            }
            let offers = planner.filesToOffer(maximum: 64)
            if !offers.isEmpty {
                for id in offers where !checkedFiles.contains(id) {
                    guard let file = planner.files[id] else { throw StreamError.invalid("Missing local file") }
                    _ = try store.verifiedURL(for: file); checkedFiles.insert(id)
                }
                let response = try await connection.request("originals.offer", Wire.offer(sessionID: store.sessionID, fileIDs: offers))
                guard case .offerResponse(_, let offer) = response else { throw StreamConnection.Failure.wrongReply }
                try planner.applyOffer(offer, maximumBinaryBytes: limits.maxBinaryBytes)
                try persist()
            }
            onProgress(store.sessionID, planner.progress, planner.canOfferRemoval)
            if planner.canOfferRemoval { return }
            if planner.progress.filesFailed > 0 { throw StreamError.invalid("Original upload failed; all local files retained") }
            await connection.poke()
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CancellationError()
    }

    func receive(_ value: IncomingMessage) async throws {
        switch value {
        case .originalsAck(let ack):
            guard ack.sessionID == store.sessionID else { throw StreamError.invalid("Wrong session ACK") }
            // Chunk durability is authoritative on the PC and obtained again by resume. ACKs do not
            // change the persisted upload journal; avoid repeatedly rewriting all manifest batches.
            try planner.applyAck(ack); lastAck = ProcessInfo.processInfo.systemUptime
        case .originalsNack(let nack):
            guard nack.sessionID == store.sessionID else { throw StreamError.invalid("Wrong session NACK") }
            switch planner.applyNack(nack) {
            case .resume: needsResume = true
            case .retryLater(let milliseconds): retryUntil = ProcessInfo.processInfo.systemUptime + Double(max(100, milliseconds ?? 1000)) / 1000
            case .fileRestarted: checkedFiles.remove(nack.fileID); needsResume = true
            case .resend, .fileFailed: break
            }
            try persist()
        case .flow(let flow):
            enabled = flow.originals.enabled
            window = min(limits.windowChunks, flow.originals.windowChunks)
            bytesPerSecond = flow.originals.maxBytesPerS.map { Double($0) }
        case .errorEvent(let error):
            if error.fatal { throw StreamConnection.Failure.remote(error.error.message) }
        default: break
        }
        onProgress(store.sessionID, planner.progress, planner.canOfferRemoval)
        await connection.poke()
    }

    private func resume() async throws {
        var accumulator = ResumeAccumulator(sessionID: store.sessionID)
        while true {
            let reply = try await connection.request("originals.resume", Wire.resume(sessionID: store.sessionID, cursor: accumulator.expectedCursor))
            guard case .resumeResponse(_, let page) = reply else { throw StreamConnection.Failure.wrongReply }
            if let snapshot = try accumulator.add(page) {
                try planner.applyResume(snapshot); try persist(); return
            }
        }
    }

    private func next(now: Double) throws -> SocketWriter.BinaryItem? {
        guard enabled, bytesPerSecond != 0, !needsResume, now >= retryUntil, now >= nextSendTime,
              let request = planner.nextChunk(window: window) else { return nil }
        do {
            guard let file = planner.files[request.fileID], checkedFiles.contains(request.fileID) else {
                throw StreamError.invalid("File not verified before sending")
            }
            // Canonical path is taken from the immutable verified catalog, never from the server.
            let handle = try FileHandle(forReadingFrom: store.originals.appendingPathComponent(file.path))
            defer { try? handle.close() }
            try handle.seek(toOffset: request.offset)
            let data = try handle.read(upToCount: request.length) ?? Data()
            guard data.count == request.length else { throw StreamError.invalid("Original truncated after verification") }
            let packet = try PacketEncoder.chunk(sessionID: store.sessionID, fileID: request.fileID, index: request.index,
                chunkBytes: request.chunkBytes, payload: data, last: request.last, maximumBytes: limits.maxBinaryBytes)
            let tag = nextTag; nextTag += 1; sending[tag] = request
            if let rate = bytesPerSecond, rate > 0 { nextSendTime = now + Double(packet.count) / rate }
            return SocketWriter.BinaryItem(data: packet, tag: tag)
        } catch { planner.chunkNotSent(request); throw error }
    }

    private func sent(_ tag: UInt64, delivered: Bool) {
        guard let request = sending.removeValue(forKey: tag) else { return }
        if !delivered { planner.chunkNotSent(request) }
        // Delivery to URLSession is deliberately not a durable ACK.
    }

    private func persist() throws {
        let bytes = try JSONEncoder().encode(planner.journal)
        try bytes.write(to: journalURL, options: [.atomic])
        let file = try FileHandle(forWritingTo: journalURL)
        do { try file.synchronize(); try file.close() } catch { try? file.close(); throw error }
        try OriginalStore.syncDirectory(journalURL.deletingLastPathComponent())
    }
}
