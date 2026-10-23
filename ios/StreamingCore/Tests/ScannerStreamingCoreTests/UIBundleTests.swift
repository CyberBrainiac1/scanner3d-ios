import XCTest
import CryptoKit
@testable import ScannerStreamingCore

final class UIBundleTests: XCTestCase {
    private func file(_ path: String, _ text: String) -> UIBundleRequest.File {
        let data = Data(text.utf8)
        return .init(path: path, bytes: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     contentB64: data.base64EncodedString())
    }

    func testExampleBundleDecodesAndVerifies() throws {
        guard case .uiBundle(let id, let request) = try IncomingMessage.decode(Fixtures.data("examples/ui.bundle.request.json")) else {
            return XCTFail("not a ui.bundle request")
        }
        XCTAssertEqual(id, "pc-7")
        let files = try request.verifiedFiles(nativeVersion: "0.3.0")
        XCTAssertEqual(Set(files.keys), ["index.html", "app.js"])
        XCTAssertTrue(String(decoding: files["index.html"]!, as: UTF8.self).hasPrefix("<!doctype html>"))
    }

    func testTamperedTooNewOrEscapingBundlesAreRefused() throws {
        let good = file("index.html", "<p>hi</p>")
        XCTAssertNoThrow(try UIBundleRequest(version: "1", minNative: "0.3.0", entry: "index.html", files: [good]).verifiedFiles(nativeVersion: "0.3.0"))
        // a newer native shell required
        XCTAssertThrowsError(try UIBundleRequest(version: "1", minNative: "0.4.0", entry: "index.html", files: [good]).verifiedFiles(nativeVersion: "0.3.0"))
        // content does not match its hash
        let tampered = UIBundleRequest.File(path: "index.html", bytes: good.bytes, sha256: String(repeating: "0", count: 64), contentB64: good.contentB64)
        XCTAssertThrowsError(try UIBundleRequest(version: "1", minNative: "0.3.0", entry: "index.html", files: [tampered]).verifiedFiles(nativeVersion: "0.3.0"))
        // entry missing, duplicate paths, escaping paths
        XCTAssertThrowsError(try UIBundleRequest(version: "1", minNative: "0.3.0", entry: "main.html", files: [good]).verifiedFiles(nativeVersion: "0.3.0"))
        XCTAssertThrowsError(try UIBundleRequest(version: "1", minNative: "0.3.0", entry: "index.html", files: [good, good]).verifiedFiles(nativeVersion: "0.3.0"))
        for bad in ["../evil.html", "/abs.js", "a//b.js", ".hidden", "A.js", "a/./b.js", "a b.js", ""] {
            XCTAssertFalse(UIBundleRequest.isValidPath(bad), bad)
        }
        for ok in ["index.html", "js/app.js", "img/icon-1.svg", "_x/y_z.css"] { XCTAssertTrue(UIBundleRequest.isValidPath(ok), ok) }
        let escaping = try JSONDecoder().decode(JSONValue.self, from: Fixtures.data("negative/ui.bundle.request--path-dotdot.json"))
        guard case .uiBundle(_, let request) = try IncomingMessage.decode(JSONEncoder().encode(escaping)) else { return XCTFail("decode") }
        XCTAssertThrowsError(try request.verifiedFiles(nativeVersion: "0.3.0"))
    }

    func testVersionComparison() {
        XCTAssertTrue(UIVersion.atLeast("0.3.0", "0.3.0"))
        XCTAssertTrue(UIVersion.atLeast("0.3.0", "0.3"))
        XCTAssertTrue(UIVersion.atLeast("0.10.0", "0.9.5"))
        XCTAssertFalse(UIVersion.atLeast("0.2.9", "0.3.0"))
        XCTAssertFalse(UIVersion.atLeast("0.3", "0.3.1"))
    }

    func testDebugRequestsDecodeWithTheirType() throws {
        for (name, type) in [("debug.eval.request", "debug.eval"), ("debug.screenshot.request", "debug.screenshot"),
                             ("debug.action.request", "debug.action"), ("debug.state.request", "debug.state")] {
            guard case .debugRequest(let decodedType, let id, let body) = try IncomingMessage.decode(Fixtures.data("examples/\(name).json")) else {
                return XCTFail(name)
            }
            XCTAssertEqual(decodedType, type)
            XCTAssertTrue(id.hasPrefix("pc-"))
            if case .object = body {} else { XCTFail("body of \(name)") }
        }
    }
}
