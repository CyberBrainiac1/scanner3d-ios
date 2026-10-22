import Foundation
import ScannerStreamingCore

/// App-level orchestration. Capture and its originals survive link errors. No method deletes a scan.
actor PhoneLink {
    struct State: Sendable {
        let connected: Bool
        let name: String?
        let message: String
        var revision: UInt64 = 0
        var previewAllowed = false
    }
    private let app = AppInfo(version: "0.2.0", build: "1", sourceRevision: "unknown")
    private let device: DeviceInfo
    private var paired: PairedPC?
    private var preview: StreamConnection?
    private var previewHello: HelloResponse?
    private var originals: StreamConnection?
    private var uploader: OriginalsUploader?
    private var uploadTask: Task<Void, Never>?
    private var previewWindow = PreviewWindow(now: ProcessInfo.processInfo.systemUptime)
    private var recording: OriginalStore?
    private var uploadStore: OriginalStore?
    private var sessionReady = false
    private var segmentBodies: [UUID: JSONValue] = [:]
    private var currentSegment: UInt32 = 0
    private var lastPreviewOffered: Double = -1
    private var targetHz: Double = 5
    private var previewEnabled = true
    private var inflightMax = 2
    private var lastStatusTime: Double = -1
    private var completeThisConnection: Set<UUID> = []
    private var connectionEpoch = UUID()
    private var uploadEpoch: UUID?
    private var captureStop = CaptureStopFlow()
    private var pcStopSession: UUID?
    private var stateRevision: UInt64 = 0
    private let state: @Sendable (State) -> Void
    private let progress: @Sendable (UUID, UploadProgress, Bool) -> Void
    private let remoteStop: @Sendable (UUID, String) -> Void
    private let configurePreview: @Sendable (HelloResponse.PreviewProfile) -> Void

    init(device: DeviceInfo, state: @escaping @Sendable (State) -> Void,
         progress: @escaping @Sendable (UUID, UploadProgress, Bool) -> Void,
         remoteStop: @escaping @Sendable (UUID, String) -> Void,
         configurePreview: @escaping @Sendable (HelloResponse.PreviewProfile) -> Void) {
        self.device = device; self.state = state; self.progress = progress; self.remoteStop = remoteStop
        self.configurePreview = configurePreview
    }

    func connectConfirmed(_ payload: PairingPayload) async throws {
        guard payload.expires > Date() else { throw StreamError.invalid("PC code expired; open Connect phone again") }
        let existing = try PairedPCStore.load()
        let reuse = existing?.pcID == payload.pcID && existing?.fingerprint == payload.fingerprint
        let auth: HelloAuth = reuse ? existing!.auth : .pairingToken(payload.token)
        try await connect(addresses: payload.addresses, pin: payload.fingerprint, auth: auth,
                          expectedPC: payload.pcID, expectedName: payload.pcName)
    }

    func reconnect() async throws {
        if let preview, !(await preview.isClosed) { try await ensureUpload(); return }
        guard let saved = try PairedPCStore.load() else { return }
        let addresses = try saved.addresses.map { try PairingAddress.parse($0) }
        try await connect(addresses: addresses, pin: saved.fingerprint, auth: saved.auth,
                          expectedPC: saved.pcID, expectedName: saved.name)
    }

    func connectTyped(address: PairingAddress, fingerprint: String, token: String) async throws {
        let old = try PairedPCStore.load()
        let auth: HelloAuth = old?.fingerprint == fingerprint ? old!.auth : .pairingToken(token)
        try await connect(addresses: [address], pin: fingerprint, auth: auth,
                          expectedPC: old?.fingerprint == fingerprint ? old?.pcID : nil, expectedName: address.displayHost)
    }

    private func connect(addresses: [PairingAddress], pin: String, auth: HelloAuth,
                         expectedPC: String?, expectedName: String) async throws {
        let epoch = UUID(); connectionEpoch = epoch
        await closeConnections()
        guard connectionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
        emit(State(connected: false, name: expectedName, message: "Connecting…"))
        var failure: Error = StreamConnection.Failure.disconnected
        for address in addresses {
            guard connectionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
            let connection = try StreamConnection(address: address, fingerprint: pin, channel: "preview",
                onEvent: { [weak self] message in try await self?.receivePreview(message, epoch: epoch) })
            do {
                let hello = try await connection.hello(auth: auth, app: app, device: device)
                guard connectionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
                guard expectedPC == nil || hello.pc.pcID == expectedPC, let profile = hello.previewProfile else {
                    throw StreamError.invalid("PC identity or preview profile does not match this phone implementation")
                }
                let saved: PairedPC
                if let credential = hello.credential {
                    saved = PairedPC(pcID: hello.pc.pcID, name: hello.pc.displayName,
                        addresses: [address.description] + addresses.filter { $0 != address }.map(\.description),
                        fingerprint: pin, deviceID: credential.deviceID, secret: credential.secret)
                    try PairedPCStore.save(saved)
                } else {
                    guard let old = try PairedPCStore.load(), old.pcID == hello.pc.pcID, old.fingerprint == pin else {
                        throw StreamError.invalid("Missing saved credential")
                    }
                    saved = old
                }
                paired = saved; preview = connection; previewHello = hello
                configurePreview(profile)
                targetHz = min(5, profile.targetHz)
                inflightMax = hello.limits.previewInflightMax
                try await freshPreviewWindow(connection)
                emit(State(connected: true, name: saved.name, message: "Connected"))
                if let recording { try await announce(recording, resumed: true) }
                try await ensureUpload()
                return
            } catch {
                failure = error; await connection.close(error: error)
                guard connectionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
                // A consumed pairing token must never be replayed on another address after receiving a
                // credential. The Keychain now carries that successful pairing for the next reconnect.
                if case .pairingToken = auth, let saved = try PairedPCStore.load(), saved.fingerprint == pin { break }
            }
        }
        emit(State(connected: false, name: expectedName, message: "PC unavailable; recording stays on iPhone"))
        throw failure
    }

    func disconnect() async {
        connectionEpoch = UUID()
        await closeConnections()
    }

    private func closeConnections() async {
        sessionReady = false
        uploadTask?.cancel(); uploadTask = nil; uploader = nil; uploadEpoch = nil
        let previousOriginals = originals, previousPreview = preview
        originals = nil; preview = nil; previewHello = nil
        completeThisConnection = []
        emit(State(connected: false, name: paired?.name, message: "Disconnected; local scans are kept"))
        if let previousOriginals { await previousOriginals.close() }
        if let previousPreview { await previousPreview.close() }
    }

    func startRecording(_ store: OriginalStore) async throws {
        recording = store; currentSegment = 0; sessionReady = false; lastPreviewOffered = -1
        if let preview, !(await preview.isClosed) {
            try await freshPreviewWindow(preview)
            try await announce(store, resumed: false)
        }
        try await switchUpload(to: store)
    }

    func segment(sessionID: UUID, segment: UInt32, reason: String, firstFrame: UInt64, time: Double) async throws {
        let body = Wire.segmentStart(sessionID: sessionID, segment: segment, reason: reason,
            previousSegment: segment == 0 ? nil : segment - 1, firstFrameID: firstFrame, tDevice: time)
        segmentBodies[sessionID] = body
        guard recording?.sessionID == sessionID else { return }
        currentSegment = segment
        if sessionReady {
            try await previewWindow.configure(inflightMax: inflightMax, enabled: false)
            try await previewWindow.resetConnection(now: ProcessInfo.processInfo.systemUptime)
            try await preview?.event("segment.start", body)
            try await previewWindow.configure(inflightMax: inflightMax, enabled: previewEnabled)
        }
    }

    private func announce(_ store: OriginalStore, resumed: Bool) async throws {
        guard let preview else { return }
        let epoch = connectionEpoch
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.originals.appendingPathComponent("session.json")))
        guard let capture = metadata["capture"], let start = metadata["t_device_start_s"] else {
            throw StreamError.invalid("Local session metadata")
        }
        let body: JSONValue = .object(["session_id": .uuid(store.sessionID), "resumed": .bool(resumed),
            "profile": .string("tabletop"), "t_device_s": start, "capture": capture,
            "storage_free_bytes": .int(0), "estimated_originals_bytes_per_s": .int(0)])
        let reply = try await preview.request("session.start", body)
        guard connectionEpoch == epoch, recording?.sessionID == store.sessionID else { return }
        guard case .sessionStartResponse(_, let response) = reply, response.sessionID == store.sessionID else {
            throw StreamConnection.Failure.wrongReply
        }
        let first: JSONValue = segmentBodies[store.sessionID] ?? .object([
            "session_id": .uuid(store.sessionID), "segment": .int(0), "coord_frame": .string("seg-0"),
            "reason": .string("session_start"), "previous_segment": .null, "first_frame_id": .int(0), "t_device_s": start])
        try await preview.event("segment.start", first)
        sessionReady = true
    }

    func offerPreview(sessionID: UUID, segment: UInt32, sequence: UInt64, bytes: Data) async throws {
        guard sessionReady, recording?.sessionID == sessionID, currentSegment == segment,
              let preview, let hello = previewHello, bytes.count <= hello.limits.maxBinaryBytes else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard targetHz > 0 else { return }
        guard now - lastPreviewOffered >= 1 / targetHz else { return }
        lastPreviewOffered = now
        try await previewWindow.offer(PreviewWindow.Packet(sequence: sequence, bytes: bytes)); await preview.poke()
    }

    func status(_ snapshot: CaptureEngine.Snapshot) async throws {
        guard sessionReady, recording?.sessionID == snapshot.sessionID, let preview else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStatusTime >= 2 else { return }
        lastStatusTime = now
        let backlog = recording?.files.reduce(UInt64(0)) { $0 + $1.bytes } ?? 0
        let message = StatusSnapshot(sessionID: snapshot.sessionID, recording: snapshot.recording,
            segment: snapshot.segment, tDevice: now, thermal: ThermalStateWire(rawValue: CaptureEngine.thermal()) ?? .serious,
            storageFreeBytes: snapshot.freeBytes, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            framesCaptured: snapshot.frames, stillsCaptured: snapshot.stills, filesClosed: UInt64(recording?.files.count ?? 0),
            bytesPending: backlog)
        try await preview.event("status", message.json)
    }

    func stopped(_ store: OriginalStore, wireReason: String? = nil) async throws {
        guard recording?.sessionID == store.sessionID else {
            if recording == nil { uploadStore = store; try await ensureUpload() }
            return
        }
        recording = nil; sessionReady = false
        let actualWireReason = wireReason ?? (pcStopSession == store.sessionID ? "pc_request" : nil)
        pcStopSession = nil; _ = captureStop.captureEnded()
        if let preview, !(await preview.isClosed) {
            let end = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.originals.appendingPathComponent("session_end.json")))
            let body: JSONValue = .object(["session_id": .uuid(store.sessionID), "t_device_s": end["t_device_stop_s"] ?? .num(ProcessInfo.processInfo.systemUptime),
                "reason": actualWireReason.map { .string($0) } ?? end["reason"] ?? .string("user"), "last_frame_id": end["last_frame_id"] ?? .null,
                "frames_captured": end["frames_captured"] ?? .int(0), "stills_captured": end["stills_captured"] ?? .int(0), "segments": end["segments"] ?? .int(1)])
            _ = try await preview.request("session.stop", body)
        }
        uploadStore = store; try await ensureUpload()
    }

    func upload(_ store: OriginalStore) async throws {
        guard recording == nil || recording?.sessionID == store.sessionID else { throw StreamError.invalid("Finish the active scan before sending another") }
        try await switchUpload(to: store)
    }

    func confirmRemoteStop() -> UUID? {
        if case .stopCapture(let sessionID, _) = captureStop.userConfirmed(), recording?.sessionID == sessionID {
            pcStopSession = sessionID; return sessionID
        }
        return nil
    }
    func declineRemoteStop() { _ = captureStop.userDeclined() }

    private func switchUpload(to store: OriginalStore) async throws {
        if uploadStore?.sessionID != store.sessionID {
            uploadStore = store
            uploadTask?.cancel(); uploadTask = nil; uploader = nil; uploadEpoch = nil
            let previous = originals; originals = nil
            if let previous { await previous.close() }
        }
        uploadStore = store; try await ensureUpload()
    }

    private func ensureUpload() async throws {
        guard uploadTask == nil, uploadEpoch == nil, let store = uploadStore, !completeThisConnection.contains(store.sessionID),
              let paired, let firstAddress = paired.addresses.first, let address = try? PairingAddress.parse(firstAddress),
              let preview, !(await preview.isClosed) else { return }
        let epoch = UUID(), parentEpoch = connectionEpoch
        let connection = try StreamConnection(address: address, fingerprint: paired.fingerprint, channel: "originals",
            onEvent: { [weak self] message in try await self?.receiveOriginals(message, epoch: epoch) })
        uploadEpoch = epoch
        do {
            let hello = try await connection.hello(auth: paired.auth, app: app, device: device)
            guard uploadEpoch == epoch, connectionEpoch == parentEpoch, uploadStore?.sessionID == store.sessionID,
                  !Task.isCancelled else { throw CancellationError() }
            guard hello.pc.pcID == paired.pcID else { throw StreamError.invalid("PC identity changed") }
            let worker = try OriginalsUploader(store: store, connection: connection, hello: hello, onProgress: progress)
            originals = connection; uploader = worker
            uploadTask = Task { [weak self] in
                do { try await worker.run(); await self?.uploadEnded(sessionID: store.sessionID, epoch: epoch, success: true) }
                catch { await self?.uploadEnded(sessionID: store.sessionID, epoch: epoch, success: false) }
            }
        } catch {
            if uploadEpoch == epoch { uploadEpoch = nil }
            await connection.close(error: error); throw error
        }
    }

    private func uploadEnded(sessionID: UUID, epoch: UUID, success: Bool) async {
        guard uploadStore?.sessionID == sessionID, uploadEpoch == epoch else { return }
        uploadTask = nil; uploader = nil; uploadEpoch = nil
        if success { completeThisConnection.insert(sessionID) }
        let previous = originals; originals = nil
        if previous != nil && !success { emit(State(connected: preview != nil, name: paired?.name, message: "Upload paused; all originals remain on iPhone")) }
        if let previous { await previous.close() }
    }

    private func receiveOriginals(_ value: IncomingMessage, epoch: UUID) async throws {
        guard uploadEpoch == epoch else { return }
        try await uploader?.receive(value)
    }

    private func receivePreview(_ value: IncomingMessage, epoch: UUID) async throws {
        guard connectionEpoch == epoch else { return }
        switch value {
        case .previewAck(let ack):
            guard ack.sessionID == recording?.sessionID else { return }
            _ = try await previewWindow.acknowledge(sequence: ack.previewSeq, now: ProcessInfo.processInfo.systemUptime)
        case .flow(let flow):
            targetHz = min(5, max(0, flow.preview.targetHz))
            previewEnabled = flow.preview.enabled; inflightMax = flow.preview.inflightMax
            try await previewWindow.configure(inflightMax: inflightMax, enabled: previewEnabled)
            emit(State(connected: preview != nil, name: paired?.name,
                       message: previewEnabled ? "Connected" : "PC preview paused; original recording stays on iPhone"))
        case .captureStop(let id, let body):
            let (reply, effect) = captureStop.receive(requestID: id, body: body, recordingSession: recording?.sessionID)
            switch reply {
            case .response(let replyTo, let content): try await preview?.respond("capture.stop", replyTo: replyTo, body: content)
            case .errorResponse(let replyTo, let code, let text): try await preview?.respondError("capture.stop", replyTo: replyTo, code: code, message: text)
            }
            if case .showConfirmation(let request) = effect {
                remoteStop(request.sessionID, request.detail ?? "The PC asked to stop this scan.")
            }
        case .errorEvent(let error):
            if error.fatal { throw StreamConnection.Failure.remote(error.error.message) }
        default: break
        }
    }

    private func freshPreviewWindow(_ connection: StreamConnection) async throws {
        try await previewWindow.configure(inflightMax: inflightMax, enabled: false)
        let window = PreviewWindow(now: ProcessInfo.processInfo.systemUptime, inflightMax: inflightMax)
        try await window.configure(inflightMax: inflightMax, enabled: previewEnabled)
        previewWindow = window
        await connection.binarySource({ now in
            guard let packet = try await window.take(now: now) else { return nil }
            return SocketWriter.BinaryItem(data: try PacketEncoder.stampingSendTime(packet.bytes, now: now), tag: packet.sequence)
        }, done: { sequence, delivered in
            if delivered { try? await window.sendCompleted(sequence: sequence) }
            else { await window.sendFailed(sequence: sequence) }
        })
    }

    private func emit(_ input: State) {
        var value = input
        stateRevision += 1; value.revision = stateRevision
        value.previewAllowed = value.connected && previewEnabled && targetHz > 0
        state(value)
    }
}
