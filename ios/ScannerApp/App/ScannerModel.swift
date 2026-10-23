import Foundation
import Observation
import UIKit
import ARKit
import ScannerStreamingCore

@MainActor @Observable
final class ScannerModel {
    struct ScanRow: Identifiable, Sendable {
        let id: UUID
        let title: String
        let originals: Int
        let finalized: Bool
        var completeOnPC = false
        var progress = "Saved on iPhone"
        var catalogReadable = true
        var createdAt = Date.distantPast
    }
    enum Sheet: String, Identifiable { case pairing; var id: String { rawValue } }
    var sheet: Sheet?
    var busy = false
    var recording = false
    var elapsed: Double = 0
    var message = "Ready to scan"
    var linkMessage = "Connect your Windows PC for a live preview"
    var connected = false
    var pcName: String?
    var error: String?
    var inventoryError: String?
    var frames: UInt64 = 0
    var stills: UInt64 = 0
    var dropped: UInt64 = 0
    var freeBytes: UInt64 = 0
    var scans: [ScanRow] = []
    var remoteStop: RemoteStopRequest?
    /// One guidance card on the camera (ui/README.md iPhone screen 4). ARKit's own warnings (tracking, speed, light,
    /// distance) rank first, then the PC's live-coverage tip (dismissable per condition), then ARKit's calm hints.
    struct ScanCard: Equatable {
        let key: String
        let text: String
        let warn: Bool
        let dismissable: Bool
    }
    var localTip: GuidanceTracker.Tip?
    var pcTip: GuidanceEvent.Tip?
    var coverage: Double?
    private var dismissedPCTips: Set<String> = []
    var card: ScanCard? {
        guard recording else { return nil }
        if let tip = localTip, tip.level == .warn { return ScanCard(key: tip.key, text: tip.text, warn: true, dismissable: false) }
        if let tip = pcTip, !dismissedPCTips.contains(tip.conditionKey) {
            return ScanCard(key: tip.conditionKey, text: tip.text, warn: tip.severity == "warning", dismissable: true)
        }
        if let tip = localTip { return ScanCard(key: tip.key, text: tip.text, warn: false, dismissable: false) }
        return nil
    }
    /// The status pill: grey when all is well, amber only for a problem the user should know about.
    var pillWarn: Bool { recording && !(connected && linkMessage == "Connected") }
    var pillText: String {
        if !connected { return "PC not connected · recording is safe" }
        if linkMessage != "Connected" { return "PC preview paused · recording is safe" }
        return "Scanning · all good"
    }
    /// Auto flashlight in dark scenes (on by default, remembered). The engine applies it on its capture queue.
    var autoLight: Bool = UserDefaults.standard.object(forKey: "autoLight") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLight, forKey: "autoLight"); engine.setAutoLight(autoLight) }
    }
    func dismissCard() { if let card, card.dismissable { dismissedPCTips.insert(card.key) } }
    private(set) var currentSessionID: UUID?
    private var lifetimeEpoch = UUID()
    private var lastLinkRevision: UInt64 = 0
    private var inventoryEpoch = UUID()
    @ObservationIgnored let engine: CaptureEngine
    @ObservationIgnored private let parent: URL
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    // ---- hot-updatable web UI and PC debugging (docs/PHONE-UI-AND-DEBUG.md); the bridge is in ScannerModel+Bridge.swift
    enum UIMode: String { case native, web }
    var uiMode: UIMode = .native
    var bundleVersion: String?
    var uiNotice: String?
    var sensors: CaptureEngine.Sensors?
    var torchState: CaptureEngine.TorchState?
    var pcViewing = false
    /// Show the PC's screens (web UI) when a bundle is installed; off after "Use the built-in screens".
    var preferWebUI: Bool = UserDefaults.standard.object(forKey: "preferWebUI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferWebUI, forKey: "preferWebUI") }
    }
    /// "Allow this PC to view and control the app" (on by default, as the user asked).
    var allowPCDebug: Bool = UserDefaults.standard.object(forKey: "allowPCDebug") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowPCDebug, forKey: "allowPCDebug"); PhoneLog.shared.info("PC debugging \(allowPCDebug ? "allowed" : "off")") }
    }
    @ObservationIgnored let bundles = UIBundleStore.standard
    @ObservationIgnored lazy var webUI: WebUIController = makeWebUI()
    @ObservationIgnored weak var cameraView: ARSCNView?
    @ObservationIgnored var statePushTask: Task<Void, Never>?
    @ObservationIgnored var lastPushedState = ""
    @ObservationIgnored var viewingResetTask: Task<Void, Never>?

    @ObservationIgnored lazy var link: PhoneLink = PhoneLink(
        device: DeviceInfo(modelIdentifier: CaptureEngine.modelIdentifier(), osVersion: UIDevice.current.systemVersion, displayName: "Scan iPhone"),
        state: { [weak self] value in Task { @MainActor in
            guard let self, value.revision > self.lastLinkRevision else { return }
            self.lastLinkRevision = value.revision
            self.connected = value.connected; self.pcName = value.name; self.linkMessage = value.message
            self.engine.allowPreview(value.previewAllowed)
        } },
        progress: { [weak self] id, value, complete in Task { @MainActor in
            guard let self, let index = self.scans.firstIndex(where: { $0.id == id }) else { return }
            self.scans[index].completeOnPC = complete
            self.scans[index].progress = complete ? "Saved on PC" : "\(value.filesCompleteOnPC) of \(value.filesKnown) files confirmed on PC"
        } },
        remoteStop: { [weak self] id, detail in Task { @MainActor in
            self?.remoteStop = RemoteStopRequest(id: UUID().uuidString, sessionID: id, reason: detail)
        } }, configurePreview: { [weak self] profile in Task { @MainActor in self?.engine.configurePreview(profile) } },
        guidance: { [weak self] event in Task { @MainActor in
            guard let self, self.recording, event.sessionID == self.currentSessionID else { return }
            self.pcTip = event.tip; self.coverage = event.coverageScore
        } },
        bundle: { [weak self] request in
            guard let self else { return .object(["version": .string(""), "installed": .bool(false), "active": .bool(false), "detail": .string("app closing")]) }
            return await self.installBundle(request)
        },
        debug: { [weak self] type, body in
            guard let self else { return .error(code: "internal", message: "app closing") }
            return await self.handleDebug(type: type, body: body)
        })

    init() {
        parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        engine = CaptureEngine(parent: parent)
        engine.setAutoLight(autoLight)
        startWebUIIfInstalled()
        engine.onStatus = { [weak self] snapshot in Task { @MainActor in
            guard let self else { return }
            guard self.currentSessionID == snapshot.sessionID else { return }
            self.recording = snapshot.recording; self.elapsed = snapshot.elapsed
            self.frames = snapshot.frames; self.stills = snapshot.stills; self.dropped = snapshot.droppedFrames
            self.freeBytes = snapshot.freeBytes
            if let text = snapshot.message { self.message = text }
            self.localTip = snapshot.guidance
            self.sensors = snapshot.sensors; self.torchState = snapshot.torch
            do { try await self.link.status(snapshot) } catch { self.linkMessage = "Preview disconnected; recording is safe" }
        } }
        engine.onPreview = { [weak self] id, segment, sequence, bytes in Task { @MainActor in
            do { try await self?.link.offerPreview(sessionID: id, segment: segment, sequence: sequence, bytes: bytes) }
            catch { self?.linkMessage = "Preview paused; recording is safe" }
        } }
        engine.onSegment = { [weak self] id, segment, reason, first, time in Task { @MainActor in
            do { try await self?.link.segment(sessionID: id, segment: segment, reason: reason, firstFrame: first, time: time) }
            catch { self?.linkMessage = "Preview paused; recording is safe" }
        } }
        engine.onFailure = { [weak self] text in Task { @MainActor in
            guard let self else { return }
            self.error = text; self.recording = false; self.currentSessionID = nil; self.lifetimeEpoch = UUID()
            UIApplication.shared.isIdleTimerDisabled = false
            await self.refreshScans()
        } }
        engine.onPreviewFailure = { [weak self] _ in Task { @MainActor in
            self?.linkMessage = "PC preview unavailable; original recording continues on iPhone"
        } }
        engine.onClosed = { [weak self] store in Task { @MainActor in
            guard let self else { return }
            guard self.currentSessionID == nil || self.currentSessionID == store.sessionID else { await self.refreshScans(); return }
            self.currentSessionID = nil
            self.recording = false; self.remoteStop = nil; UIApplication.shared.isIdleTimerDisabled = false
            await self.refreshScans()
            do { try await self.link.stopped(store) } catch { self.linkMessage = "Scan is safe on iPhone; reconnect to send it" }
        } }
    }

    func foreground() async { await refreshScans(); resumeLink() }

    func resumeLink() {
        guard reconnectTask == nil else { return }
        lifetimeEpoch = UUID()
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.link.reconnect() }
                catch { self.connected = false; self.linkMessage = "PC unavailable; local recordings are safe" }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }

    func toggleRecording() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        if recording {
            do { try await engine.stop(); recording = false; message = "Saved on iPhone" }
            catch { self.error = "Could not finalize this scan: \(error.localizedDescription). Its files are retained." }
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            do {
                let epoch = lifetimeEpoch
                currentSessionID = try await engine.start()
                guard epoch == lifetimeEpoch, UIApplication.shared.applicationState == .active else {
                    try await engine.stop(reason: "app_backgrounded"); currentSessionID = nil; recording = false
                    await refreshScans(); return
                }
                recording = true; elapsed = 0; message = "Scanning · recording on iPhone"
                localTip = nil; pcTip = nil; coverage = nil; dismissedPCTips = []
                UIApplication.shared.isIdleTimerDisabled = true
                await refreshScans()
                if let store = await engine.currentStore() {
                    do { try await link.startRecording(store) }
                    catch { linkMessage = "PC preview unavailable; recording continues on iPhone" }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func confirmRemoteStop() async {
        remoteStop = nil
        let approved = await link.confirmRemoteStop()
        let current = await engine.currentStore()
        if let id = approved, recording, current?.sessionID == id {
            await toggleRecording()
        }
    }
    func declineRemoteStop() async { remoteStop = nil; await link.declineRemoteStop() }

    func connectConfirmed(_ payload: PairingPayload) async throws {
        reconnectTask?.cancel(); reconnectTask = nil
        defer { resumeLink() }
        try await link.connectConfirmed(payload)
    }

    func connectTyped(address: PairingAddress, fingerprint: String, token: String) async throws {
        reconnectTask?.cancel(); reconnectTask = nil
        defer { resumeLink() }
        try await link.connectTyped(address: address, fingerprint: fingerprint, token: token)
    }

    func send(_ row: ScanRow) async {
        guard !recording else { return }
        error = nil
        do {
            let directory = parent
            let store = try await Task.detached(priority: .utility) {
                try OriginalStore(parent: directory, sessionID: row.id, create: false)
            }.value
            guard store.finalized else { throw OriginalStore.Failure.io("Recording is incomplete; files are retained for recovery") }
            try await link.upload(store)
            try await link.reconnect()
        } catch { self.error = error.localizedDescription }
    }

    func inspect(_ row: ScanRow) async throws -> RecordingInspection {
        guard !recording, !busy else { throw OriginalStore.Failure.io("Stop and save before checking recordings.") }
        let root = parent
        let id = row.id
        let worker = Task.detached(priority: .utility) { try RecordingInspection.inspect(parent: root, sessionID: id) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    func refreshScans() async {
        let epoch = UUID()
        inventoryEpoch = epoch
        let root = parent
        let inventory: [RecordingInventory]
        do { inventory = try await Task.detached(priority: .utility) { try RecordingInventory.list(parent: root) }.value }
        catch {
            guard inventoryEpoch == epoch else { return }
            inventoryError = "Could not list saved recordings. Files are retained: \(error.localizedDescription)"; return
        }
        guard inventoryEpoch == epoch else { return }
        inventoryError = nil
        let rows = inventory.map { item in
            ScanRow(id: item.id, title: item.createdAt.formatted(date: .abbreviated, time: .shortened),
                originals: item.fileCount ?? 0, finalized: item.finalized,
                progress: item.fileCount == nil ? "File list needs inspection · all files retained"
                    : item.finalized ? "Saved on iPhone" : "Incomplete recording · files retained",
                catalogReadable: item.fileCount != nil, createdAt: item.createdAt)
        }
        let old = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, $0) })
        scans = rows.map { row in
            var value = row
            if let previous = old[row.id], row.catalogReadable, previous.catalogReadable,
               row.finalized == previous.finalized, row.originals == previous.originals {
                value.completeOnPC = previous.completeOnPC; value.progress = previous.progress
            }
            return value
        }
    }

    func background() {
        lifetimeEpoch = UUID()
        let closingEpoch = lifetimeEpoch
        reconnectTask?.cancel(); reconnectTask = nil
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Close scanner originals") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        Task {
            // Also wait for an already-requested error stop. isRunning may be false while disk
            // finalization is still queued; ending the background task then would suspend it early.
            do { try await engine.stop(reason: "app_backgrounded") }
            catch { self.error = "Interrupted scan retained; closing did not complete." }
            if lifetimeEpoch == closingEpoch {
                recording = false; UIApplication.shared.isIdleTimerDisabled = false
                await link.disconnect()
            }
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
}
