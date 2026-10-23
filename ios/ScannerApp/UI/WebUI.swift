import Foundation
import SwiftUI
import UIKit
import WebKit
import ScannerStreamingCore

/// Installed UI bundles (docs/PHONE-UI-AND-DEBUG.md) under Application Support/ui: each version in `v-<version>/`,
/// written to a temporary folder first and then renamed; `current.json` names the active one. The previous version is
/// kept and older ones are removed. Nothing here touches scans.
final class UIBundleStore: @unchecked Sendable {
    struct Installed: Codable, Equatable, Sendable {
        let version: String
        let entry: String
        var previous: String?
    }
    let root: URL
    private let lock = NSLock()

    init(root: URL) { self.root = root }

    static let standard = UIBundleStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ui", isDirectory: true))

    private var currentFile: URL { root.appendingPathComponent("current.json") }

    var current: Installed? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: currentFile), let value = try? JSONDecoder().decode(Installed.self, from: data),
              FileManager.default.fileExists(atPath: folder(value.version).appendingPathComponent(value.entry).path) else { return nil }
        return value
    }

    func folder(_ version: String) -> URL { root.appendingPathComponent("v-" + version, isDirectory: true) }

    /// Verifies every file (UIBundleRequest.verifiedFiles) and installs atomically; the old bundle stays on any error.
    func install(_ request: UIBundleRequest, nativeVersion: String) throws -> Installed {
        let files = try request.verifiedFiles(nativeVersion: nativeVersion)
        guard request.version != ".", request.version != ".." else { throw StreamError.invalid("UI bundle version label") }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        do {
            for (path, data) in files {
                let url = temporary.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            let previous = (try? JSONDecoder().decode(Installed.self, from: Data(contentsOf: currentFile)))?.version
            let target = folder(request.version)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temporary, to: target)
            let installed = Installed(version: request.version, entry: request.entry, previous: previous == request.version ? nil : previous)
            try JSONEncoder().encode(installed).write(to: currentFile, options: .atomic)
            // keep the current and the previous version only
            let keep = Set([target.lastPathComponent] + (installed.previous.map { [folder($0).lastPathComponent] } ?? []))
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where (item.lastPathComponent.hasPrefix("v-") || item.lastPathComponent.hasPrefix(".tmp-")) && !keep.contains(item.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
            return installed
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// The bytes of one bundle file of the current version, or nil (bad path, missing file, no bundle).
    func file(_ path: String) -> Data? {
        guard let installed = current else { return nil }
        let relative = path.isEmpty ? installed.entry : path
        guard UIBundleRequest.isValidPath(relative) else { return nil }
        return try? Data(contentsOf: folder(installed.version).appendingPathComponent(relative))
    }

    static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

/// Serves `s3dui://app/<path>` from the installed bundle. Only valid bundle paths resolve; everything else is 404.
final class UIBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: UIBundleStore
    init(store: UIBundleStore) { self.store = store }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return fail(urlSchemeTask) }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard let data = store.file(path),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": UIBundleStore.mimeType(path.isEmpty ? "index.html" : path),
                                 "Content-Length": String(data.count), "Cache-Control": "no-store"]) else { return fail(urlSchemeTask) }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The web view that shows the UI bundle over the camera, and its JS bridge (docs/PHONE-UI-AND-DEBUG.md):
/// JS -> native `webkit.messageHandlers.s3d.postMessage({id, cmd, args})`, answered with `s3d._reply(id, ok, value)`;
/// native -> JS `s3d._state(state)` and `s3d._event(name, data)`.
@MainActor
final class WebUIController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    enum BridgeError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
    }
    let webView: WKWebView
    /// One bridge command; the result must be JSON-serializable (or nil).
    var onCommand: ((String, [String: Any]) async -> Result<Any?, BridgeError>)?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var ready = false
    private var readyTimer: Task<Void, Never>?

    init(store: UIBundleStore) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(UIBundleSchemeHandler(store: store), forURLScheme: "s3dui")
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        let content = WKUserContentController()
        configuration.userContentController = content
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        content.add(WeakScriptHandler(self), name: "s3d")
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
    }

    /// Loads the installed bundle's entry page; `ready` must arrive within 8 s or onFailure runs.
    func load(entry: String) {
        ready = false
        readyTimer?.cancel()
        guard let url = URL(string: "s3dui://app/" + entry) else { onFailure?("bad UI entry \(entry)"); return }
        webView.load(URLRequest(url: url))
        readyTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, !self.ready else { return }
            self.onFailure?("the screen update did not start within 8 s")
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "s3d", let body = message.body as? [String: Any], let command = body["cmd"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        let args = body["args"] as? [String: Any] ?? [:]
        if command == "ready" { ready = true; readyTimer?.cancel() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onCommand?(command, args) ?? .failure(.failed("no handler"))
            if id > 0 { self.reply(id, result) }
            if command == "ready" { self.onReady?() }
        }
    }

    private func reply(_ id: Int, _ result: Result<Any?, BridgeError>) {
        switch result {
        case .success(let value): run("window.s3d&&s3d._reply&&s3d._reply(\(id),true,\(Self.json(value ?? NSNull())))")
        case .failure(let error): run("window.s3d&&s3d._reply&&s3d._reply(\(id),false,\(Self.json(error.localizedDescription)))")
        }
    }

    func push(stateJSON: String) { run("window.s3d&&s3d._state&&s3d._state(\(stateJSON))") }

    func event(_ name: String, _ data: Any) { run("window.s3d&&s3d._event&&s3d._event(\(Self.json(name)),\(Self.json(data)))") }

    private func run(_ script: String) { webView.evaluateJavaScript(script, completionHandler: nil) }

    /// Developer eval (debug.eval): the script's value, JSON-encoded, or its error message.
    func evaluate(_ script: String) async -> (result: String?, error: String?) {
        let wrapper = """
            const value = (0, eval)(code);
            const settled = (value && typeof value.then === "function") ? await value : value;
            return JSON.stringify(settled === undefined ? null : settled);
            """
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(wrapper, arguments: ["code": script], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: (value as? String ?? "null", nil))
                case .failure(let error): continuation.resume(returning: (nil, String(error.localizedDescription.prefix(2000))))
                }
            }
        }
    }

    /// Any JSON-serializable value (non-finite numbers become null) as a JSON text; never throws or traps.
    nonisolated static func json(_ value: Any) -> String {
        let wrapped: [Any] = [sanitize(value)]
        guard JSONSerialization.isValidJSONObject(wrapped), let data = try? JSONSerialization.data(withJSONObject: wrapped),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    nonisolated static func sanitize(_ value: Any) -> Any {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n      // true/false stay booleans
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return f.isFinite ? Double(f) : NSNull()
        case let n as NSNumber: return n.doubleValue.isFinite ? n : NSNull()
        case let a as [Any]: return a.map(sanitize)
        case let o as [String: Any]: return o.mapValues(sanitize)
        case is String, is NSNull: return value
        default: return String(describing: value)
        }
    }

    // MARK: navigation (only the s3dui:// bundle is served; the web view has no other content)

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure?("the screen update did not load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?("the screen update failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        PhoneLog.shared.warn("web UI process ended; reloading")
        webView.reload()
    }
}

/// The web UI in SwiftUI. A two-finger triple tap anywhere switches back to the built-in screens (escape hatch).
struct WebUIView: UIViewRepresentable {
    let controller: WebUIController
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

    func makeUIView(context: Context) -> WKWebView {
        let view = controller.webView
        let escape = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.escape))
        escape.numberOfTouchesRequired = 2
        escape.numberOfTapsRequired = 3
        escape.cancelsTouchesInView = false
        view.addGestureRecognizer(escape)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.onEscape = onEscape }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        for recognizer in view.gestureRecognizers ?? [] where recognizer.view === view && recognizer is UITapGestureRecognizer {
            view.removeGestureRecognizer(recognizer)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onEscape: () -> Void
        init(onEscape: @escaping () -> Void) { self.onEscape = onEscape }
        @objc func escape() { onEscape() }
    }
}
