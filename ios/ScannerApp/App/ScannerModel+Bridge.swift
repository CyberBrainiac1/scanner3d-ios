import Foundation
import UIKit
import ARKit
import ScannerStreamingCore

/// The web UI's bridge commands, the state it receives, UI bundle installs and the PC's debug requests
/// (docs/PHONE-UI-AND-DEBUG.md). Everything here acts exactly like the matching native button.
extension ScannerModel {
    // MARK: web UI lifecycle

    func makeWebUI() -> WebUIController {
        let controller = WebUIController(store: bundles)
        controller.onCommand = { [weak self] command, args in
            guard let self else { return .failure(.failed("closing")) }
            return await self.bridge(command, args)
        }
        controller.onReady = { [weak self] in
            guard let self else { return }
            PhoneLog.shared.info("web UI \(self.bundleVersion ?? "?") ready")
            self.pushState(force: true)
        }
        controller.onFailure = { [weak self] reason in self?.webUIFailed(reason) }
        return controller
    }

    func startWebUIIfInstalled() {
        bundleVersion = bundles.current?.version
        if preferWebUI, let installed = bundles.current { showWebUI(installed) }
    }

    func showWebUI(_ installed: UIBundleStore.Installed) {
        uiNotice = nil
        uiMode = .web
        lastPushedState = ""
        webUI.load(entry: installed.entry)
        startStatePush()
        PhoneLog.shared.info("web UI \(installed.version) loading")
    }

    /// The built-in SwiftUI screens; `remember` keeps them until the user (or PC) picks the new screens again.
    func showNativeUI(remember: Bool) {
        if remember { preferWebUI = false }
        uiMode = .native
        statePushTask?.cancel(); statePushTask = nil
    }

    func useWebUI() {
        preferWebUI = true
        if let installed = bundles.current { showWebUI(installed) }
    }

    func webUIFailed(_ reason: String) {
        guard uiMode == .web else { return }
        PhoneLog.shared.error("web UI failed: \(reason); showing the built-in screens")
        uiNotice = "The new screens could not start (\(reason)). Showing the built-in screens."
        uiMode = .native
        statePushTask?.cancel(); statePushTask = nil
    }

    /// `ui.bundle` from the PC. The same version again (every reconnect) is acknowledged without reloading the screen.
    func installBundle(_ request: UIBundleRequest) -> JSONValue {
        func reply(installed: Bool, version: String, detail: String?) -> JSONValue {
            .object(["version": .string(String(version.prefix(64))), "installed": .bool(installed),
                     "active": .bool(uiMode == .web), "detail": detail.map { JSONValue.string(String($0.prefix(300))) } ?? .null])
        }
        do {
            if let current = bundles.current, current.version == request.version {
                _ = try request.verifiedFiles(nativeVersion: AppVersion.native)
                if preferWebUI, uiMode != .web { showWebUI(current) }
                return reply(installed: true, version: current.version, detail: "already installed")
            }
            let installed = try bundles.install(request, nativeVersion: AppVersion.native)
            bundleVersion = installed.version
            PhoneLog.shared.info("UI bundle \(installed.version) installed (\(request.files.count) files)")
            if preferWebUI { showWebUI(installed) }
            return reply(installed: true, version: installed.version, detail: nil)
        } catch {
            PhoneLog.shared.warn("UI bundle \(request.version) refused: \(error.localizedDescription)")
            return reply(installed: false, version: request.version, detail: error.localizedDescription)
        }
    }

    // MARK: state for the web UI (about 4 Hz, only when it changed)

    func startStatePush() {
        statePushTask?.cancel()
        statePushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pushState(force: false)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func pushState(force: Bool) {
        guard uiMode == .web, webUI.ready else { return }
        let json = WebUIController.json(stateObject())
        guard force || json != lastPushedState else { return }
        lastPushedState = json
        webUI.push(stateJSON: json)
    }

    func stateObject() -> [String: Any] {
        var state: [String: Any] = [
            "nativeVersion": AppVersion.native, "uiVersion": orNull(bundleVersion), "debugAllowed": allowPCDebug,
            "pcViewing": pcViewing, "recording": recording, "busy": busy, "elapsed": elapsed,
            "sessionId": orNull(currentSessionID?.uuidString.lowercased()), "message": message, "error": orNull(error),
            "connected": connected, "pcName": orNull(pcName), "linkMessage": linkMessage,
            "previewOK": connected && linkMessage == "Connected",
            "frames": frames, "stills": stills, "dropped": dropped, "freeBytes": freeBytes, "coverage": orNull(coverage),
            "autoLight": autoLight, "uiNotice": orNull(uiNotice),
        ]
        if let s = sensors {
            state["sensors"] = ["trackingState": s.trackingState, "trackingReason": s.trackingReason,
                                "ambientLumens": orNull(s.ambientLumens), "centerDepthM": orNull(s.centerDepthM),
                                "speedMps": s.speedMps, "thermal": s.thermal] as [String: Any]
        } else { state["sensors"] = NSNull() }
        if let t = torchState {
            state["torch"] = ["autoLight": t.autoLight, "level": Double(t.level), "atMax": t.atMax, "failed": t.failed, "manual": t.manual] as [String: Any]
        } else {
            state["torch"] = ["autoLight": autoLight, "level": 0.0, "atMax": false, "failed": false, "manual": false] as [String: Any]
        }
        state["nativeTip"] = orNull(localTip.map { ["key": $0.key, "text": $0.text, "level": $0.level.rawValue] as [String: Any] })
        state["pcTip"] = orNull(pcTip.map { ["id": $0.id, "severity": $0.severity, "text": $0.text, "conditionKey": $0.conditionKey] as [String: Any] })
        state["remoteStop"] = orNull(remoteStop.map { ["sessionId": $0.sessionID.uuidString.lowercased(), "reason": $0.reason] as [String: Any] })
        state["scans"] = scans.map { row -> [String: Any] in
            ["id": row.id.uuidString.lowercased(), "title": row.title, "originals": row.originals, "finalized": row.finalized,
             "completeOnPC": row.completeOnPC, "progress": row.progress, "catalogReadable": row.catalogReadable,
             "createdAt": row.createdAt.timeIntervalSince1970]
        }
        return state
    }

    // MARK: bridge commands (JS -> native)

    func bridge(_ command: String, _ args: [String: Any]) async -> Result<Any?, WebUIController.BridgeError> {
        switch command {
        case "ready":
            return .success(["nativeVersion": AppVersion.native])
        case "startScan":
            if !recording { await toggleRecording() }
            return recording ? .success(true) : .failure(.failed(error ?? "The scan did not start"))
        case "stopScan":
            if recording { await toggleRecording() }
            return .success(!recording)
        case "setAutoLight":
            guard let on = args["on"] as? Bool else { return .failure(.failed("on must be true or false")) }
            autoLight = on
            return .success(on)
        case "setTorch":
            if args["level"] == nil || args["level"] is NSNull { engine.setManualTorch(nil); return .success(NSNull()) }
            guard let level = (args["level"] as? NSNumber)?.doubleValue, level.isFinite else { return .failure(.failed("level must be 0...1 or null")) }
            engine.setManualTorch(Float(min(max(level, 0), 1)))
            return .success(level)
        case "setConfig":
            guard let values = args["values"] as? [String: Any] else { return .failure(.failed("values must be an object")) }
            engine.applyConfig(guidance: values["guidance"] as? [String: Any], torch: values["torch"] as? [String: Any])
            return .success(true)
        case "openPairing":
            sheet = .pairing
            return .success(true)
        case "forgetPC":
            do { try await link.forgetPC(); connected = false; pcName = nil; return .success(true) }
            catch { return .failure(.failed(error.localizedDescription)) }
        case "sendScan":
            guard let text = args["id"] as? String, let id = UUID(uuidString: text), let row = scans.first(where: { $0.id == id }) else {
                return .failure(.failed("unknown scan"))
            }
            await send(row)
            return error == nil ? .success(true) : .failure(.failed(error ?? ""))
        case "refreshScans":
            await refreshScans()
            return .success(scans.count)
        case "confirmRemoteStop":
            await confirmRemoteStop()
            return .success(true)
        case "declineRemoteStop":
            await declineRemoteStop()
            return .success(true)
        case "showNative":
            showNativeUI(remember: true)
            return .success(true)
        case "log":
            PhoneLog.shared.add(args["level"] as? String ?? "info", "web: " + (args["text"] as? String ?? ""))
            return .success(true)
        case "haptic":
            switch args["style"] as? String {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            return .success(true)
        default:
            return .failure(.failed("unknown command \(command)"))
        }
    }

    // MARK: PC debug requests

    func markPCViewing() {
        pcViewing = true
        viewingResetTask?.cancel()
        viewingResetTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.pcViewing = false
        }
    }

    func handleDebug(type: String, body: JSONValue) async -> DebugReply {
        guard allowPCDebug else { return .error(code: "debug_disabled", message: "PC debugging is turned off on the iPhone") }
        markPCViewing()
        let args = body.anyValue as? [String: Any] ?? [:]
        switch type {
        case "debug.state":
            var state = stateObject()
            state["log"] = PhoneLog.shared.tail(40).map { "\($0.level) \($0.text)" }
            return .ok(.object(["native_version": .string(AppVersion.native), "ui_version": bundleVersion.map { JSONValue.string($0) } ?? .null,
                                "ui_active": .bool(uiMode == .web && webUI.ready), "state": JSONValue.fromAny(state)]))
        case "debug.screenshot":
            let width = (args["max_width"] as? NSNumber)?.intValue ?? 590
            let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.6
            return await screenshot(maxWidth: min(max(width, 160), 1600), quality: min(max(quality, 0.3), 0.95))
        case "debug.eval":
            guard uiMode == .web, webUI.ready, let script = args["js"] as? String else {
                return .error(code: "unsupported", message: "the web UI is not running")
            }
            let (result, failure) = await webUI.evaluate(script)
            return .ok(.object(["result_json": result.map { JSONValue.string(String($0.prefix(262_144))) } ?? .null,
                                "error": failure.map { JSONValue.string($0) } ?? .null]))
        case "debug.action":
            return await debugAction(args["name"] as? String ?? "", args["args"] as? [String: Any] ?? [:])
        default:
            return .error(code: "unsupported", message: "unknown debug request \(type)")
        }
    }

    private func debugAction(_ name: String, _ args: [String: Any]) async -> DebugReply {
        func done(_ ok: Bool, _ detail: String? = nil) -> DebugReply {
            .ok(.object(["done": .bool(ok), "detail": detail.map { JSONValue.string(String($0.prefix(500))) } ?? .null]))
        }
        func fromBridge(_ result: Result<Any?, WebUIController.BridgeError>) -> DebugReply {
            switch result {
            case .success: return done(true)
            case .failure(let failure): return done(false, failure.localizedDescription)
            }
        }
        PhoneLog.shared.info("PC action \(name)")
        switch name {
        case "start_scan": return fromBridge(await bridge("startScan", [:]))
        case "stop_scan": return fromBridge(await bridge("stopScan", [:]))
        case "set_auto_light": return fromBridge(await bridge("setAutoLight", args))
        case "set_torch": return fromBridge(await bridge("setTorch", args))
        case "set_config": return fromBridge(await bridge("setConfig", args))
        case "open_pairing": return fromBridge(await bridge("openPairing", [:]))
        case "show_ui":
            if (args["ui"] as? String) == "native" { showNativeUI(remember: true) } else { useWebUI() }
            return done(true, "showing the \(uiMode.rawValue) screens")
        case "reload_ui":
            guard let installed = bundles.current else { return done(false, "no UI bundle installed") }
            preferWebUI = true
            showWebUI(installed)
            return done(true, "reloading \(installed.version)")
        case "tap":
            guard uiMode == .web, webUI.ready, let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return done(false, "taps reach the web UI only; args {x, y} in points") }
            let (result, failure) = await webUI.evaluate(
                "(() => { const el = document.elementFromPoint(\(x), \(y)); if (!el) return null; el.click(); return el.tagName + (el.id ? '#' + el.id : ''); })()")
            return done(failure == nil && result != "null", failure ?? result)
        case "open_tab":
            guard uiMode == .web, webUI.ready, let tab = args["tab"] as? String else { return done(false, "the web UI is not running") }
            let (result, failure) = await webUI.evaluate(
                "(window.s3dApp && typeof s3dApp.openTab === 'function') ? (s3dApp.openTab(\(WebUIController.json(tab))), true) : false")
            return done(failure == nil && result != "false", failure ?? result)
        default:
            return done(false, "unknown action \(name)")
        }
    }

    /// The app window as drawn. Web mode: the camera's own snapshot under the web view's snapshot (Metal and web
    /// content may be blank in drawHierarchy). Native mode: the window, plus the camera separately.
    private func screenshot(maxWidth: Int, quality: Double) async -> DebugReply {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return .error(code: "internal", message: "no app window") }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return .error(code: "internal", message: "empty window") }
        let scale = min(CGFloat(maxWidth) / bounds.width, window.traitCollection.displayScale)
        let camera = cameraView.flatMap { $0.window != nil ? $0 : nil }
        let cameraImage = camera?.snapshot()
        var webImage: UIImage?
        if uiMode == .web, webUI.ready {
            webImage = await withCheckedContinuation { continuation in
                webUI.webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.black.setFill(); context.fill(bounds)
            if uiMode == .web {
                if let cameraImage, let camera { cameraImage.draw(in: camera.convert(camera.bounds, to: window)) }
                if let webImage { webImage.draw(in: webUI.webView.convert(webUI.webView.bounds, to: window)) }
                else { window.drawHierarchy(in: bounds, afterScreenUpdates: false) }
            } else {
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
        }
        // stay well under max_text_bytes (1 MiB) with both images
        var q = quality
        var data = image.jpegData(compressionQuality: q) ?? Data()
        while data.count > 480_000, q > 0.3 { q -= 0.15; data = image.jpegData(compressionQuality: max(q, 0.3)) ?? data }
        guard data.count <= 600_000 else { return .error(code: "internal", message: "screenshot too large; ask for a smaller max_width") }
        var cameraB64: JSONValue = .null
        if uiMode == .native, let cameraImage, cameraImage.size.width > 0 {
            let small = CGSize(width: CGFloat(maxWidth) / 2, height: CGFloat(maxWidth) / 2 * cameraImage.size.height / cameraImage.size.width)
            let thumb = UIGraphicsImageRenderer(size: small).image { _ in cameraImage.draw(in: CGRect(origin: .zero, size: small)) }
            if let jpeg = thumb.jpegData(compressionQuality: 0.5), jpeg.count < 150_000 { cameraB64 = .string(jpeg.base64EncodedString()) }
        }
        return .ok(.object([
            "width": .int(Int((bounds.width * scale).rounded())), "height": .int(Int((bounds.height * scale).rounded())),
            "ui": .string(uiMode == .web ? "web" : "native"), "jpeg_b64": .string(data.base64EncodedString()),
            "camera_jpeg_b64": cameraB64, "t_device_s": .num(ProcessInfo.processInfo.systemUptime),
        ]))
    }
}

/// Optional -> value or NSNull, for Foundation JSON dictionaries.
func orNull(_ value: Any?) -> Any { value ?? NSNull() }

extension JSONValue {
    /// Foundation form (NSNull, Bool, Int64, Double, String, arrays, dictionaries).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .string(let value): return value
        case .integer(let value): return NSNumber(value: value)
        case .number(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }

    /// From Foundation JSON-like values; anything else (and non-finite numbers) becomes null.
    static func fromAny(_ value: Any) -> JSONValue {
        switch value {
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { let d = number.doubleValue; return d.isFinite ? .number(d) : .null }
            return .integer(number.int64Value)
        case let values as [Any]: return .array(values.map(fromAny))
        case let values as [String: Any]: return .object(values.mapValues(fromAny))
        default: return .null
        }
    }
}
