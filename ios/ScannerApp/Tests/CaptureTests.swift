import XCTest
import UIKit
import ScannerStreamingCore
import simd
import CoreVideo
@testable import ScannerApp

final class CaptureTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testClosedCatalogSurvivesReopenAndPreservesBytes() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        let bytes = Data([0x00, 0x00, 0x80, 0x3f, 0x01, 0x02, 0x03, 0x04])
        let file = try store.commit(bytes, path: "depth/000000.f32", kind: "depth_f32", segment: 0)
        XCTAssertEqual(file.fileID, 0)
        let reopened = try OriginalStore(parent: parent, sessionID: id, create: false)
        XCTAssertEqual(reopened.files, [file])
        XCTAssertEqual(try Data(contentsOf: reopened.verifiedURL(for: file)), bytes)
        XCTAssertFalse(reopened.finalized)
    }

    func testPendingFileIsNotUploadableAndFinalCatalogCannotGrow() throws {
        let store = try OriginalStore(parent: temporary(), sessionID: UUID(), create: true)
        let pending = try store.temporaryURL(extension: "partial")
        try Data([1]).write(to: pending)
        XCTAssertTrue(store.files.isEmpty)
        try store.commit(Data("{}".utf8), path: "session_end.json", kind: "session_end")
        XCTAssertTrue(store.finalized)
        XCTAssertThrowsError(try store.commit(Data([2]), path: "depth/000002.f32", kind: "depth_f32"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testSourceCannotBeOverwrittenOrEscape() throws {
        let parent = try temporary()
        let store = try OriginalStore(parent: parent, sessionID: UUID(), create: true)
        let entry = try store.commit(Data([1, 2, 3]), path: "session.json", kind: "session_meta")
        XCTAssertThrowsError(try store.commit(Data([9]), path: "session.json", kind: "session_meta"))
        let actual = store.originals.appendingPathComponent("session.json")
        XCTAssertEqual(try Data(contentsOf: actual), Data([1, 2, 3]))
        XCTAssertEqual(store.files, [entry])
        let other = try OriginalStore(parent: parent, sessionID: UUID(), create: true)
        XCTAssertThrowsError(try other.commit(Data([1]), path: "../escape", kind: "log"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.directory.appendingPathComponent("escape").path))
    }

    func testCorruptionOrUnjournaledClosedFileBlocksRecovery() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        let file = try store.commit(Data([1]), path: "session.json", kind: "session_meta")
        try Data([2]).write(to: store.originals.appendingPathComponent(file.path))
        XCTAssertThrowsError(try store.verifiedURL(for: file))
        XCTAssertThrowsError(try OriginalStore(parent: parent, sessionID: id, create: false))
        let id2 = UUID(), orphan = try OriginalStore(parent: parent, sessionID: id2, create: true)
        try Data([1]).write(to: orphan.originals.appendingPathComponent("unrecorded.bin"))
        XCTAssertThrowsError(try OriginalStore(parent: parent, sessionID: id2, create: false))
    }

    func testCSVEscapesSeparatorsAndRotatesByTime() throws {
        XCTAssertEqual(String(data: RotatingCSV.line(["a,b", "c\"d", "e\rf"]), encoding: .utf8), "\"a,b\",\"c\"\"d\",\"e\rf\"\n")
        let store = try OriginalStore(parent: temporary(), sessionID: UUID(), create: true)
        let csv = RotatingCSV(store: store, prefix: "motion/accel", kind: "accel_csv", header: ["t", "x"])
        try csv.append(["1", "2"], time: 1)
        XCTAssertTrue(store.files.isEmpty)
        try csv.append(["11", "3"], time: 11)
        XCTAssertEqual(store.files.count, 1)
        try csv.close()
        XCTAssertEqual(store.files.map(\.path), ["motion/accel/part-000000.csv", "motion/accel/part-000001.csv"])
    }

    func testMeasuredRatesIgnoreInvalidTimeAndUseElapsedWindows() {
        var rate = MeasuredRate()
        for i in 0..<40 { rate.add(10 + Double(i) / 10) }
        rate.add(.nan); rate.add(1)
        let stats = rate.stats(until: 14)
        XCTAssertEqual(stats["mean"]!, 10, accuracy: 0.0001)
        XCTAssertEqual(stats["min"]!, 10, accuracy: 0.0001)
        XCTAssertEqual(stats["max"]!, 10, accuracy: 0.0001)
    }

    func testSIMDColumnsAreStoredAsWireRowsWithoutAnAxisFlip() {
        let matrix = simd_float4x4(columns: (SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8),
                                           SIMD4<Float>(9, 10, 11, 12), SIMD4<Float>(13, 14, 15, 16)))
        XCTAssertEqual(CaptureValues.rowMajor(matrix), [1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15, 4, 8, 12, 16])
    }

    func testIncompleteJournalTailBlocksRecoveryAndDoesNotDeleteOriginals() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        let entry = try store.commit(Data([1, 2]), path: "session.json", kind: "session_meta")
        let log = store.directory.appendingPathComponent("closed-files.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        XCTAssertThrowsError(try OriginalStore(parent: parent, sessionID: id, create: false))
        XCTAssertEqual(try Data(contentsOf: store.originals.appendingPathComponent(entry.path)), Data([1, 2]))
    }

    func testPackedDepthPreservesFloatBitsAndExcludesRowPadding() throws {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_DepthFloat32,
            [kCVPixelBufferBytesPerRowAlignmentKey as String: 64] as CFDictionary, &optional)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for i in 0..<(stride * 2) { base[i] = 0xaa }
        // Preserve even invalid depth bit patterns (NaN payload and negative values) in ORIGINALS.
        let first: [UInt8] = [0, 0, 0x80, 0x3f, 0xcd, 0xab, 0xc0, 0x7f, 0, 0, 0x80, 0xbf]
        let second: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        for i in 0..<12 { base[i] = first[i]; base[stride + i] = second[i] }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(try CaptureValues.packed(buffer, format: kCVPixelFormatType_DepthFloat32, bytesPerPixel: 4), Data(first + second))
        XCTAssertThrowsError(try CaptureValues.packed(buffer, format: kCVPixelFormatType_OneComponent8, bytesPerPixel: 1))
    }

    func testTLSPeerHostComparisonUsesIPv6BytesNotTextCompression() throws {
        let address = try PairingAddress.parse("[fc00::1]:47833")
        XCTAssertTrue(PinnedSocket.matchesHost("fc00:0:0:0:0:0:0:1", address: address))
        XCTAssertTrue(PinnedSocket.matchesHost("[fc00::1]", address: address))
        XCTAssertFalse(PinnedSocket.matchesHost("fc00::2", address: address))
    }

    /// Feeds constant light at 10 Hz for `seconds`; returns every level seen.
    @discardableResult
    private func feed(_ torch: inout TorchController, lumens: Double, from start: Double, seconds: Double,
                      thermal: String = "nominal", enabled: Bool = true) -> [Float] {
        var levels: [Float] = []
        for i in 0..<Int(seconds * 10) {
            torch.update(TorchController.Input(time: start + Double(i) / 10, ambientIntensity: lumens, thermal: thermal,
                                               trackingState: "normal", enabled: enabled))
            levels.append(torch.level)
        }
        return levels
    }

    func testTorchStepsUpInTheDarkOncePerHalfSecondUpToMax() {
        var torch = TorchController()
        let first = torch.update(TorchController.Input(time: 0, ambientIntensity: 50, thermal: "nominal", trackingState: "normal"))
        XCTAssertTrue(first)
        XCTAssertEqual(torch.level, 0.15, accuracy: 1e-5)
        let early = torch.update(TorchController.Input(time: 0.2, ambientIntensity: 50, thermal: "nominal", trackingState: "normal"))
        XCTAssertFalse(early)
        XCTAssertFalse(torch.changed)
        XCTAssertEqual(torch.level, 0.15, accuracy: 1e-5)
        let second = torch.update(TorchController.Input(time: 0.5, ambientIntensity: 50, thermal: "nominal", trackingState: "normal"))
        XCTAssertTrue(second)
        XCTAssertEqual(torch.level, 0.30, accuracy: 1e-5)
        XCTAssertFalse(torch.atMax)
        feed(&torch, lumens: 50, from: 0.6, seconds: 5)
        XCTAssertEqual(torch.level, 1)
        XCTAssertTrue(torch.atMax)
    }

    func testTorchHoldsInTheBand() {
        var torch = TorchController()
        feed(&torch, lumens: 600, from: 0, seconds: 5)
        XCTAssertEqual(torch.level, 0)
        feed(&torch, lumens: 50, from: 5, seconds: 1)
        feed(&torch, lumens: 600, from: 6, seconds: 5)
        let settled = torch.level
        XCTAssertGreaterThan(settled, 0)
        XCTAssertLessThan(settled, 1)
        let levels = feed(&torch, lumens: 600, from: 11, seconds: 10)
        XCTAssertTrue(levels.allSatisfy { $0 == settled })
        XCTAssertFalse(torch.changed)
    }

    func testTorchStepsDownWhenBrightAndTurnsOff() {
        var torch = TorchController()
        feed(&torch, lumens: 50, from: 0, seconds: 5)
        XCTAssertTrue(torch.atMax)
        let levels = feed(&torch, lumens: 3000, from: 5, seconds: 10)
        XCTAssertEqual(levels.last, 0)
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThanOrEqual(b, a)
            XCTAssertLessThanOrEqual(a - b, TorchController.step + 1e-5)
        }
    }

    func testTorchTurnsOffWhenHotOrDisabled() {
        for thermal in ["serious", "critical"] {
            var torch = TorchController()
            feed(&torch, lumens: 50, from: 0, seconds: 5)
            XCTAssertTrue(torch.atMax)
            let changed = torch.update(TorchController.Input(time: 5, ambientIntensity: 50, thermal: thermal, trackingState: "normal"))
            XCTAssertTrue(changed)
            XCTAssertEqual(torch.level, 0)
            XCTAssertTrue(torch.forcedOff)
            let hot = feed(&torch, lumens: 50, from: 5.1, seconds: 3, thermal: thermal)
            XCTAssertTrue(hot.allSatisfy { $0 == 0 })
        }
        var torch = TorchController()
        feed(&torch, lumens: 50, from: 0, seconds: 2)
        XCTAssertGreaterThan(torch.level, 0)
        let disabled = feed(&torch, lumens: 50, from: 2, seconds: 3, enabled: false)
        XCTAssertTrue(disabled.allSatisfy { $0 == 0 })
        feed(&torch, lumens: 50, from: 5, seconds: 1, thermal: "fair")
        XCTAssertGreaterThan(torch.level, 0)
    }

    func testTorchLevelStaysWithinZeroAndOne() {
        var torch = TorchController()
        for i in 0..<2000 {
            let lumens: Double = (i / 37) % 2 == 0 ? 5 : 5000
            torch.update(TorchController.Input(time: Double(i) / 30, ambientIntensity: lumens, thermal: "nominal", trackingState: "normal"))
            XCTAssertGreaterThanOrEqual(torch.level, 0)
            XCTAssertLessThanOrEqual(torch.level, TorchController.maxLevel)
        }
        feed(&torch, lumens: 1, from: 100, seconds: 20)
        XCTAssertEqual(torch.level, 1)
        feed(&torch, lumens: 100_000, from: 120, seconds: 20)
        XCTAssertEqual(torch.level, 0)
    }

    func testDarkTipWaitsForTheTorchAtMaxWhenAutoLightIsOn() {
        func dark(_ light: Double, auto: Bool, atMax: Bool) -> GuidanceTracker.Tip? {
            GuidanceTracker.condition(state: "normal", reason: "none", light: light, depth: 0.3, speed: 0, thermal: "nominal",
                                      autoLight: auto, torchAtMax: atMax)
        }
        XCTAssertEqual(GuidanceTracker.condition(state: "normal", reason: "none", light: 100, depth: 0.3, speed: 0,
                                                 thermal: "nominal")?.text, "More light needed · turn on a lamp")
        XCTAssertEqual(dark(100, auto: false, atMax: true)?.text, "More light needed · turn on a lamp")
        XCTAssertNil(dark(100, auto: true, atMax: false))
        XCTAssertEqual(dark(100, auto: true, atMax: true)?.text, "Still too dark · add a lamp")
        XCTAssertEqual(dark(100, auto: true, atMax: true)?.key, "dark")
        XCTAssertNil(dark(600, auto: true, atMax: true))

        var tracker = GuidanceTracker()
        func step(_ time: Double, atMax: Bool) -> GuidanceTracker.Tip? {
            tracker.update(GuidanceTracker.Input(time: time, trackingState: "normal", trackingReason: "none", ambientIntensity: 100,
                centerDepthM: 0.3, position: SIMD3<Float>(0, 0, 0), thermal: "nominal", autoLight: true, torchAtMax: atMax))
        }
        for i in 0..<30 { XCTAssertNil(step(Double(i) / 10, atMax: false)) }
        var shown: GuidanceTracker.Tip?
        for i in 30..<45 { shown = step(Double(i) / 10, atMax: true) }
        XCTAssertEqual(shown?.text, "Still too dark · add a lamp")
    }

    func testRelativePathsSurviveAFolderAlias() throws {
        // a device's Documents is /var/mobile/... while enumerators return /private/var/mobile/... (an alias of the
        // same folder); the same situation here with a real folder and a symlink to it
        let real = try temporary()
        let alias = real.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: alias) }
        let file = real.appendingPathComponent("originals/depth/000002.f32")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        let viaAlias = alias.appendingPathComponent("originals", isDirectory: true)
        XCTAssertEqual(OriginalStore.relativePath(of: file, under: viaAlias), "depth/000002.f32")
        XCTAssertEqual(OriginalStore.relativePath(of: viaAlias.appendingPathComponent("depth/000002.f32"),
                                                  under: real.appendingPathComponent("originals")), "depth/000002.f32")
        XCTAssertNil(OriginalStore.relativePath(of: real.appendingPathComponent("other.f32"), under: viaAlias))
    }

    func testAFinalizedScanReopensForUpload() throws {
        // the real-device failure: every closed scan threw incompleteCatalog when reopened to send it
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        try store.commit(Data([1, 2, 3, 4]), path: "depth/000000.f32", kind: "depth_f32", segment: 0)
        try store.commit(Data("{}".utf8), path: "session_end.json", kind: "session_end")
        let reopened = try OriginalStore(parent: parent, sessionID: id, create: false)
        XCTAssertTrue(reopened.finalized)
        XCTAssertEqual(reopened.files.count, 2)
    }

    func testPreviewJPEGComesFromACameraBufferOnTheCPU() throws {
        // the preview path that replaced Core Image (which hung the capture queue on the first real scans)
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 200 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let jpeg = try XCTUnwrap(CaptureValues.jpegPreview(buffer, width: 16, height: 12, quality: 0.6))
        let image = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(image.size, CGSize(width: 16, height: 12))
        XCTAssertNil(CaptureValues.jpegPreview(buffer, width: 0, height: 12, quality: 0.6))
    }
}

