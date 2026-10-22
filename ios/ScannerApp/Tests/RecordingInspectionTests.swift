import XCTest
import Foundation
import ScannerStreamingCore
@testable import ScannerApp

/// Prepared for the native Mac XCTest run. Windows static/preparation checks do not execute these tests.
final class RecordingInspectionTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        while let url = walker.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(url.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return files
    }

    func testClosedFilesAreHashedWithoutChangingAnyPrivateOrOriginalBytes() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        try store.commit(Data([1, 2, 3]), path: "session.json", kind: "session_meta")
        try store.commit(Data("{}".utf8), path: "session_end.json", kind: "session_end")
        let before = try snapshot(parent)
        let report = try RecordingInspection.inspect(parent: parent, sessionID: id)
        XCTAssertTrue(report.catalogReadable)
        XCTAssertTrue(report.recordingFinalized)
        XCTAssertTrue(report.closedFilesIntact)
        XCTAssertEqual(report.verifiedFiles, 2)
        XCTAssertEqual(report.verifiedBytes, 5)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(try snapshot(parent), before)
        let copy = try JSONDecoder().decode(RecordingInspection.self, from: Data(report.shareText.utf8))
        XCTAssertEqual(copy.sessionID, id.uuidString.lowercased())
    }

    func testUnfinishedRecordingAndPendingBytesAreRetained() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        try store.commit(Data([7]), path: "depth/000000.f32", kind: "depth_f32", segment: 0)
        try Data([4, 5, 6]).write(to: store.temporaryURL(extension: "partial"))
        let before = try snapshot(parent)
        let report = try RecordingInspection.inspect(parent: parent, sessionID: id)
        XCTAssertFalse(report.recordingFinalized)
        XCTAssertFalse(report.closedFilesIntact)
        XCTAssertEqual(report.pendingFiles, 1)
        XCTAssertTrue(report.issues.contains { $0.kind == "not_finalized" })
        XCTAssertTrue(report.issues.contains { $0.kind == "unfinished_file" })
        XCTAssertEqual(try snapshot(parent), before)
    }

    func testChangedAndUnlistedOriginalsNeverBecomeAHealthyRecording() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        try store.commit(Data([1]), path: "session.json", kind: "session_meta")
        try store.commit(Data("{}".utf8), path: "session_end.json", kind: "session_end")
        try Data([9]).write(to: store.originals.appendingPathComponent("session.json"))
        try Data([8]).write(to: store.originals.appendingPathComponent("orphan.log"))
        let before = try snapshot(parent)
        let report = try RecordingInspection.inspect(parent: parent, sessionID: id)
        XCTAssertFalse(report.closedFilesIntact)
        XCTAssertEqual(report.verifiedFiles, 1)
        XCTAssertEqual(report.unmatchedOriginalFiles, 1)
        XCTAssertTrue(report.issues.contains { $0.kind == "file_changed" })
        XCTAssertEqual(try snapshot(parent), before)
    }

    func testBrokenCatalogStaysVisibleAndIsNeverSilentlyRepaired() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        try store.commit(Data([1]), path: "session.json", kind: "session_meta")
        let log = store.directory.appendingPathComponent("closed-files.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{partial".utf8)); try handle.close()
        let before = try snapshot(parent)
        let items = try RecordingInventory.list(parent: parent)
        XCTAssertEqual(items.map(\.id), [id])
        XCTAssertNil(items[0].fileCount)
        let report = try RecordingInspection.inspect(parent: parent, sessionID: id)
        XCTAssertFalse(report.catalogReadable)
        XCTAssertFalse(report.closedFilesIntact)
        XCTAssertEqual(report.unmatchedOriginalFiles, 1)
        XCTAssertEqual(try snapshot(parent), before)
    }

    func testDuplicateJournalPathsAreRejected() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        let first = try store.commit(Data([1]), path: "session.json", kind: "session_meta")
        let second = try LocalFile(fileID: 1, path: first.path, kind: first.kind, bytes: first.bytes, sha256: first.sha256, segment: nil)
        var line = try JSONEncoder().encode(second); line.append(10)
        let log = try FileHandle(forWritingTo: store.directory.appendingPathComponent("closed-files.jsonl"))
        try log.seekToEnd(); try log.write(contentsOf: line); try log.close()
        XCTAssertThrowsError(try OriginalStore.readCatalog(directory: store.directory))
        XCTAssertNil(try RecordingInventory.list(parent: parent).first?.fileCount)
        XCTAssertFalse(try RecordingInspection.inspect(parent: parent, sessionID: id).closedFilesIntact)
    }

    func testLinkedRecordingIsVisibleButNeverFollowed() throws {
        let parent = try temporary(), external = try temporary(), id = UUID()
        try Data([9]).write(to: external.appendingPathComponent("keep"))
        let directory = parent.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: external)
        let items = try RecordingInventory.list(parent: parent)
        XCTAssertEqual(items.map(\.id), [id])
        XCTAssertNil(items[0].fileCount)
        let report = try RecordingInspection.inspect(parent: parent, sessionID: id)
        XCTAssertFalse(report.closedFilesIntact)
        XCTAssertEqual(report.issues.first?.kind, "unsafe_folder")
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("keep")), Data([9]))
    }

    func testIssueDetailLimitStillCountsEveryRetainedFile() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        for index in 0..<205 { try Data([1]).write(to: store.originals.appendingPathComponent("orphan-\(index).log")) }
        let report = try RecordingInspection.inspect(parent: parent, sessionID: id)
        XCTAssertEqual(report.unmatchedOriginalFiles, 205)
        XCTAssertEqual(report.issues.count, 200)
        XCTAssertEqual(report.omittedIssueDetails, 6) //205 unlisted +1 unfinished recording.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.originals.path).count, 205)
    }

    func testHashCancellationDoesNotCreateAReplacementOrPartialFile() throws {
        let parent = try temporary(), file = parent.appendingPathComponent("large.bin")
        let bytes = Data(repeating: 7, count: 3_000_000)
        try bytes.write(to: file)
        var checks = 0
        XCTAssertThrowsError(try OriginalStore.digest(file, checkCancellation: {
            checks += 1
            if checks == 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["large.bin"])
    }

    func testUnavailableRootIsAnErrorRatherThanAnEmptyScanLibrary() throws {
        let parent = try temporary(), file = parent.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try RecordingInventory.list(parent: file))
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }

    func testSessionIdentityMismatchDoesNotEnableSending() throws {
        let parent = try temporary(), id = UUID()
        let store = try OriginalStore(parent: parent, sessionID: id, create: true)
        try store.commit(Data([1]), path: "session.json", kind: "session_meta")
        let wrong = OriginalStore.Journal(sessionID: UUID(), files: [], finalized: false)
        try JSONEncoder().encode(wrong).write(to: store.directory.appendingPathComponent("closed-files.json"))
        let items = try RecordingInventory.list(parent: parent)
        XCTAssertEqual(items.map(\.id), [id])
        XCTAssertNil(items[0].fileCount)
        XCTAssertFalse(try RecordingInspection.inspect(parent: parent, sessionID: id).catalogReadable)
    }
}
