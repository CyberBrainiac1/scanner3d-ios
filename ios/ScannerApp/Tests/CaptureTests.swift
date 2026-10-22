import XCTest
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
}
