import XCTest
import CryptoKit
import ScannerStreamingCore
@testable import ScannerApp

/// Hot-updatable UI pieces that need no web view or device (docs/PHONE-UI-AND-DEBUG.md).
final class WebUITests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func bundle(_ version: String, _ files: [String: String], minNative: String = "0.3.0") -> UIBundleRequest {
        UIBundleRequest(version: version, minNative: minNative, entry: "index.html", files: files.sorted { $0.key < $1.key }.map { path, text in
            let data = Data(text.utf8)
            return .init(path: path, bytes: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                         contentB64: data.base64EncodedString())
        })
    }

    func testInstallServesFilesKeepsPreviousAndPrunesOlder() throws {
        let store = UIBundleStore(root: try temporary())
        XCTAssertNil(store.current)
        _ = try store.install(bundle("a", ["index.html": "<p>a</p>", "js/app.js": "1"]), nativeVersion: "0.3.0")
        XCTAssertEqual(store.current?.version, "a")
        XCTAssertEqual(store.file("js/app.js"), Data("1".utf8))
        XCTAssertEqual(store.file(""), Data("<p>a</p>".utf8))        // the entry page
        XCTAssertNil(store.file("../current.json"))
        _ = try store.install(bundle("b", ["index.html": "<p>b</p>"]), nativeVersion: "0.3.0")
        XCTAssertEqual(store.current, UIBundleStore.Installed(version: "b", entry: "index.html", previous: "a"))
        _ = try store.install(bundle("c", ["index.html": "<p>c</p>"]), nativeVersion: "0.3.0")
        let folders = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix("v-") }.sorted()
        XCTAssertEqual(folders, ["v-b", "v-c"])                    // current + previous only
    }

    func testRefusedBundleLeavesTheCurrentOneUntouched() throws {
        let store = UIBundleStore(root: try temporary())
        _ = try store.install(bundle("good", ["index.html": "ok"]), nativeVersion: "0.3.0")
        XCTAssertThrowsError(try store.install(bundle("new", ["index.html": "x"], minNative: "9.0"), nativeVersion: "0.3.0"))
        var bad = bundle("bad", ["index.html": "x"])
        bad = UIBundleRequest(version: bad.version, minNative: bad.minNative, entry: bad.entry,
                              files: [.init(path: "index.html", bytes: 1, sha256: String(repeating: "a", count: 64), contentB64: Data("x".utf8).base64EncodedString())])
        XCTAssertThrowsError(try store.install(bad, nativeVersion: "0.3.0"))
        XCTAssertEqual(store.current?.version, "good")
        XCTAssertEqual(store.file("index.html"), Data("ok".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".tmp-") })
    }

    func testJSONForTheWebViewNeverTrapsOnNonFiniteNumbers() {
        XCTAssertEqual(WebUIController.json(["a": Double.nan, "b": 1.5, "c": [Double.infinity], "d": "x\"y"] as [String: Any]),
                       WebUIController.json(["a": NSNull(), "b": 1.5, "c": [NSNull()], "d": "x\"y"] as [String: Any]))
        XCTAssertEqual(WebUIController.json(true), "true")
        XCTAssertEqual(WebUIController.json("hi"), "\"hi\"")
        XCTAssertEqual(WebUIController.json(NSNull()), "null")
    }

    func testJSONValueRoundTripKeepsBooleansIntegersAndNumbersApart() throws {
        let value = JSONValue.fromAny(["on": true, "n": 3, "x": 0.5, "s": "t", "list": [1, NSNull()], "bad": Double.nan] as [String: Any])
        guard case .object(let o) = value else { return XCTFail("object") }
        XCTAssertEqual(o["on"], .bool(true))
        XCTAssertEqual(o["n"], .integer(3))
        XCTAssertEqual(o["x"], .number(0.5))
        XCTAssertEqual(o["s"], .string("t"))
        XCTAssertEqual(o["list"], .array([.integer(1), .null]))
        XCTAssertEqual(o["bad"], .null)
        let back = value.anyValue as? [String: Any]
        XCTAssertEqual(back?["on"] as? Bool, true)
        XCTAssertEqual((back?["x"] as? Double), 0.5)
    }

    func testConfigFromTheWebUIIsClampedAndUnknownKeysIgnored() {
        var guidance = GuidanceTracker.Config()
        guidance.apply(["darkLumens": 300, "tooFarM": 99, "fastMPerS": "fast", "nonsense": 1])
        XCTAssertEqual(guidance.darkLumens, 300)
        XCTAssertEqual(guidance.tooFarM, 3)                       // clamped
        XCTAssertEqual(guidance.fastMPerS, GuidanceTracker.fastMPerS)   // not a number: ignored
        XCTAssertEqual(GuidanceTracker.condition(state: "normal", reason: "none", light: 280, depth: 0.3, speed: 0, thermal: "nominal",
                                                 config: guidance)?.key, "dark")
        var torch = TorchController.Config()
        torch.apply(["lowLumens": 600, "highLumens": 100, "step": 5, "maxLevel": 0.5])
        XCTAssertEqual(torch.lowLumens, 600)
        XCTAssertEqual(torch.highLumens, 601)                     // kept above lowLumens
        XCTAssertEqual(torch.step, 1)
        XCTAssertEqual(torch.maxLevel, 0.5)
        var controller = TorchController()
        controller.config = torch
        for i in 0..<20 { controller.update(.init(time: Double(i), ambientIntensity: 50, thermal: "nominal", trackingState: "normal")) }
        XCTAssertEqual(controller.level, 0.5)
        XCTAssertTrue(controller.atMax)
    }

    func testPhoneLogDrainsInBatchesOfFiftyAndCountsDrops() {
        let log = PhoneLog()
        for i in 0..<520 { log.info("line \(i)") }
        let first = log.drain()
        XCTAssertEqual(first?.lines.count, 50)
        XCTAssertEqual(first?.dropped, 20)
        XCTAssertEqual(first?.lines.first?.text, "line 0")
        var total = 50
        while let batch = log.drain() { total += batch.lines.count; XCTAssertEqual(batch.dropped, 0) }
        XCTAssertEqual(total, 500)
        XCTAssertEqual(log.tail(3).map(\.text), ["line 517", "line 518", "line 519"])
        log.add("bogus", "")
        XCTAssertEqual(log.tail(1).first?.level, "info")
        XCTAssertEqual(log.tail(1).first?.text, "-")
    }
}
