import SwiftUI
import ARKit
import ScannerStreamingCore

struct ScannerRoot: View {
    @Bindable var model: ScannerModel

    var body: some View {
        Group {
            if model.uiMode == .web {
                WebModeView(model: model)
            } else {
                TabView {
                    NavigationStack { ScanScreen(model: model) }
                        .tabItem { Label("Scan", systemImage: "camera") }
                    NavigationStack { SavedScans(model: model) }
                        .tabItem { Label("Scans", systemImage: "square.stack.3d.up") }
                }
                .tint(.black)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet { case .pairing: PairingScreen(model: model) }
        }
        // the web UI asks for its own confirmation; this alert serves the built-in screens
        .alert("The PC asked to stop", isPresented: Binding(get: { model.remoteStop != nil && model.uiMode == .native },
                                                           set: { if !$0 { model.remoteStop = nil } })) {
            Button("Keep scanning", role: .cancel) { Task { await model.declineRemoteStop() } }
            Button("Stop and save") { Task { await model.confirmRemoteStop() } }
        } message: { Text(model.remoteStop?.reason ?? "Stop this recording and save its files?") }
    }
}

/// The PC's screens (docs/PHONE-UI-AND-DEBUG.md): the live camera full screen with the web UI over it.
private struct WebModeView: View {
    @Bindable var model: ScannerModel
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraSurface(engine: model.engine) { view in model.cameraView = view }.ignoresSafeArea()
            WebUIView(controller: model.webUI) { model.showNativeUI(remember: true) }.ignoresSafeArea()
        }
    }
}

private struct ScanScreen: View {
    @Bindable var model: ScannerModel
    @State private var forgetAsked = false
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(model.recording ? "Recording on iPhone" : "Ready to scan").font(.headline)
                Spacer()
                Text(ScanStatusText.timer(model.elapsed)).monospacedDigit()
            }
            CameraSurface(engine: model.engine) { view in model.cameraView = view }
                .overlay(alignment: .topTrailing) {
                    if model.pcViewing {
                        Text("PC is viewing").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.85))).foregroundStyle(.secondary).padding(10)
                    }
                }
                .overlay {
                    if !model.recording { ContentUnavailableView("Scan a small object", systemImage: "cube.transparent", description: Text("Use even light. Move slowly around every side.")) }
                }
                .overlay(alignment: .top) {
                    if model.recording {
                        // ui/README.md iPhone screens 3-4: one status pill, then one guidance card only when there is
                        // something to do. VoiceOver reads the pill, then the card.
                        VStack(spacing: 10) {
                            StatusPill(text: model.pillText, warn: model.pillWarn, elapsed: model.elapsed)
                            if let card = model.card { GuidanceCard(card: card) { model.dismissCard() } }
                        }
                        .padding(12)
                        .animation(.easeInOut(duration: 0.2), value: model.card)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Text(model.linkMessage).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let error = model.error {
                // SwiftUI has no live-region modifier; announce the message to VoiceOver when it appears or changes.
                Text(error).font(.subheadline).foregroundStyle(.orange)
                    .onAppear { AccessibilityNotification.Announcement(error).post() }
                    .onChange(of: error) { _, message in AccessibilityNotification.Announcement(message).post() }
            }
            Toggle("Turn on the flashlight when it's dark", isOn: $model.autoLight).font(.subheadline)
            if let notice = model.uiNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
            DisclosureGroup("Details") {
                if let coverage = model.coverage { LabeledContent("Part covered so far (PC estimate)", value: "\(Int((coverage * 100).rounded())) %") }
                LabeledContent("Saved frames", value: String(model.frames))
                LabeledContent("High-resolution photos", value: String(model.stills))
                LabeledContent("Camera queue drops", value: String(model.dropped))
                LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.freeBytes), countStyle: .file))
                Text("The PC preview is a rough guide. Final reconstruction and accuracy checks happen after the recording closes.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Allow this PC to view and control the app", isOn: $model.allowPCDebug)
                if let version = model.bundleVersion {
                    Button("Use the new screens (\(version))") { model.useWebUI() }.disabled(model.recording)
                }
                LabeledContent("App version", value: AppVersion.native)
                Button("Forget this PC", role: .destructive) { forgetAsked = true }.disabled(model.recording)
            }.font(.subheadline)
            .confirmationDialog("Forget this PC?", isPresented: $forgetAsked, titleVisibility: .visible) {
                Button("Forget this PC", role: .destructive) { Task { _ = await model.bridge("forgetPC", [:]) } }
            } message: { Text("Scans stay on this iPhone. Pair again with the code on the PC.") }
            Button { Task { await model.toggleRecording() } } label: {
                HStack { if model.busy { ProgressView().tint(.white) }; Text(model.recording ? "Stop and save" : "Start scan").font(.headline) }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("capture-toggle")
        }
        .padding(20).navigationTitle("Scanner").navigationBarTitleDisplayMode(.inline)
        .toolbar { if !model.recording { Button("Connect PC") { model.sheet = .pairing } } }
    }
}

private struct StatusPill: View {
    let text: String
    let warn: Bool
    let elapsed: Double
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.medium))
            Text(ScanStatusText.timer(elapsed)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(warn ? Color(red: 1.0, green: 0.93, blue: 0.80) : .white))
        .foregroundStyle(warn ? Color(red: 0.55, green: 0.33, blue: 0.0) : .primary)
        .accessibilityElement(children: .combine)
    }
}

private struct GuidanceCard: View {
    let card: ScannerModel.ScanCard
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: card.warn ? "exclamationmark.triangle.fill" : "arrow.triangle.turn.up.right.circle")
                .foregroundStyle(card.warn ? Color.orange : Color.secondary).accessibilityHidden(true)
            Text(card.text).font(.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if card.dismissable {
                Button(action: dismiss) { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss tip")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .foregroundStyle(.primary)
        .onAppear { AccessibilityNotification.Announcement(card.text).post() }
        .onChange(of: card.text) { _, text in AccessibilityNotification.Announcement(text).post() }
    }
}

private struct CameraSurface: UIViewRepresentable {
    let engine: CaptureEngine
    var onView: (ARSCNView) -> Void = { _ in }
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        onView(view)
        view.session = engine.session; engine.session.delegate = engine
        view.automaticallyUpdatesLighting = false
        view.backgroundColor = .systemGray6
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) { }
}

private struct SavedScans: View {
    @Bindable var model: ScannerModel
    var body: some View {
        List {
            if let error = model.error { Text(error).font(.subheadline).foregroundStyle(.orange) }
            if let error = model.inventoryError { Text(error).font(.subheadline).foregroundStyle(.orange) }
            if model.scans.isEmpty { ContentUnavailableView("No scans yet", systemImage: "cube", description: Text("Your recordings will stay on this iPhone until you choose what to do with them.")) }
            ForEach(model.scans) { scan in
                VStack(alignment: .leading, spacing: 8) {
                    Text(scan.title).font(.headline)
                    Text(scan.progress).font(.subheadline).foregroundStyle(.secondary)
                    Text(scan.catalogReadable ? "\(scan.originals) closed original files" : "File count unavailable until the catalog is checked")
                        .font(.caption).foregroundStyle(.secondary)
                    if scan.catalogReadable && scan.finalized && !scan.completeOnPC { Button("Send to PC") { Task { await model.send(scan) } }.disabled(model.recording) }
                    NavigationLink("Check saved files") { RecordingCheckScreen(model: model, scan: scan) }
                        .disabled(model.recording || model.busy)
                }.padding(.vertical, 7)
            }
        }
        .navigationTitle("Scans").refreshable { await model.refreshScans() }
        .task { await model.refreshScans() }
        .safeAreaInset(edge: .bottom) { Text("Originals stay on your iPhone. Keep the app open while sending.").font(.footnote).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.background) }
    }
}

/// Separate from Scan: opening a saved-file report never starts sensors or changes the recording.
private struct RecordingCheckScreen: View {
    let model: ScannerModel
    let scan: ScannerModel.ScanRow
    @State private var report: RecordingInspection?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(scan.title).font(.headline)
                Text("Checks the closed-file list and SHA-256 hashes. Original and unfinished files stay unchanged.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let report {
                Section("File check") {
                    Text(report.closedFilesIntact ? "Closed files match their saved hashes" : "Recording needs attention")
                        .font(.headline)
                    LabeledContent("Trusted file list", value: report.catalogReadable ? "Readable" : "Could not verify")
                    LabeledContent("Recording closed", value: report.recordingFinalized ? "Yes" : "No")
                    LabeledContent("Files verified", value: report.catalogReadable
                        ? "\(report.verifiedFiles) of \(report.listedFiles)" : "\(report.verifiedFiles); file count unavailable")
                    LabeledContent("Checked at", value: report.inspectedAt)
                    LabeledContent("Files outside verified list", value: String(report.unmatchedOriginalFiles))
                    LabeledContent("Unfinished files retained", value: String(report.pendingFiles))
                    Text("A matching hash confirms saved bytes. It does not prove the scan's shape, completeness or physical accuracy. PC import checks are still required.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !report.issues.isEmpty {
                    Section("Details") {
                        ForEach(report.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                if !issue.path.isEmpty { Text(issue.path).font(.caption.monospaced()).textSelection(.enabled) }
                                Text(issue.detail).font(.subheadline)
                            }
                        }
                        if report.omittedIssueDetails > 0 { Text("\(report.omittedIssueDetails) more details omitted; counts above include all checked entries.").font(.footnote) }
                    }
                }
                Section { ShareLink("Share check report", item: report.shareText) }
            } else if let error {
                Section { Text(error).foregroundStyle(.orange) }
            } else {
                Section { ProgressView("Checking saved files…"); Text("Large videos may take a while. Go back to cancel.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Text("An interrupted recording is kept for recovery. This check does not invent missing frames, close an unfinished video or create a final recording marker.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Saved-file check").navigationBarTitleDisplayMode(.inline)
        .task {
            report = nil; error = nil
            do { report = try await model.inspect(scan) }
            catch is CancellationError { }
            catch { self.error = "Check could not finish: \(error.localizedDescription). All files are retained." }
        }
    }
}

private struct PairingScreen: View {
    let model: ScannerModel
    @Environment(\.dismiss) private var dismiss
    @State private var payloadText = ""
    @State private var proposal: PairingPayload?
    @State private var error: String?
    @State private var busy = false
    @State private var addressText = ""
    @State private var codeText = ""
    @State private var typed: TypedProposal?
    private struct TypedProposal {
        let address: PairingAddress
        let pin: String
        let token: String
        let code: String
    }

    var body: some View {
        NavigationStack {
            Form {
                if let proposal {
                    Section("Does your PC show this code?") {
                        Text((try? PairingIdentity.shortCode(token: proposal.token, fingerprint: proposal.fingerprint)) ?? "Invalid code")
                            .font(.largeTitle.monospaced()).textSelection(.enabled)
                        Text(proposal.pcName)
                        Text("Confirm the PC code under Connection details. iPhone may ask for Local Network access.").font(.footnote).foregroundStyle(.secondary)
                        Button("Yes, connect") { Task { await confirm(proposal) } }.disabled(busy)
                        Button("Try another code") { self.proposal = nil }
                    }
                } else if let typed {
                    Section("Does your PC show this code?") {
                        Text(typed.code).font(.largeTitle.monospaced())
                        Text(typed.address.displayHost)
                        Text("Confirm the PC code under Connection details. Nothing authenticates until you confirm.").font(.footnote)
                        Button("Yes, connect") { Task { await confirmTyped(typed) } }.disabled(busy)
                        Button("Try another code") { self.typed = nil }
                    }
                } else {
                    Section("Connect to your Windows PC") {
                        Text("Open Connect phone on the PC. Scan its QR code or paste the QR text.").font(.subheadline)
                        QRReader { value in parse(value) }.frame(height: 220)
                        TextField("Pairing QR text", text: $payloadText, axis: .vertical).lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Check code") { parse(payloadText) }.disabled(payloadText.isEmpty)
                    }
                    Section("Type the address and code instead") {
                        TextField("PC address", text: $addressText).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Pairing code", text: $codeText).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Check PC code") { Task { await probeTyped() } }.disabled(busy || addressText.isEmpty || codeText.isEmpty)
                    }
                }
                if busy { ProgressView("Connecting…") }
                if let error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle("Connect PC").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func parse(_ value: String) {
        do { let parsed = try PairingPayload.parse(value); guard parsed.expires > Date() else { throw StreamError.invalid("Code expired") }; proposal = parsed; error = nil }
        catch { self.error = "This pairing code is invalid or expired. Open Connect phone on your PC again." }
    }
    private func confirm(_ value: PairingPayload) async {
        busy = true; error = nil; defer { busy = false }
        do { try await model.connectConfirmed(value); dismiss() }
        catch { self.error = "Could not connect. Check that both devices use the same Wi-Fi and allow Local Network access in Settings." }
    }

    private func probeTyped() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let address = try PairingAddress.parseTyped(addressText)
            let token = try PairingIdentity.normalizedToken(codeText)
            let pin = try await CertificateProbe(address: address).fingerprint()
            typed = TypedProposal(address: address, pin: pin, token: token,
                                  code: try PairingIdentity.shortCode(token: token, fingerprint: pin))
        } catch { self.error = "Cannot reach that PC. Check its address and that both devices use the same Wi-Fi." }
    }

    private func confirmTyped(_ value: TypedProposal) async {
        busy = true; error = nil; defer { busy = false }
        do { try await model.connectTyped(address: value.address, fingerprint: value.pin, token: value.token); dismiss() }
        catch { self.error = "Connection failed. Check the PC's current code and Local Network permission." }
    }
}
