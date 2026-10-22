import Foundation
import XCTest
@testable import ScannerStreamingCore

final class PlannerTests: XCTestCase {
    private func planner() throws -> OriginalsPlanner {
        let id = UUID()
        let file = try LocalFile(fileID: 0, path: "session_end.json", kind: "session_end", bytes: 2,
                                 sha256: String(repeating: "a", count: 64), segment: nil)
        var result = OriginalsPlanner(journal: UploadJournal(sessionID: id), files: [file])
        try result.setFinal(totalFiles: 1)
        _ = try result.nextManifestBatch(maximumEntries: 1, flushPartial: true)
        return result
    }

    func testFreshPCSnapshotRevokesOldCompletionAndOffersMissingFileAgain() throws {
        var value = try planner()
        let full = ResumeSnapshot(sessionID: value.sessionID, snapshotRev: 1, known: true,
            manifestSeqDurable: 0, finalManifestReceived: true, completeFiles: [0...0], partial: [:], allComplete: true)
        try value.applyResume(full)
        XCTAssertTrue(value.canOfferRemoval)
        let restored = ResumeSnapshot(sessionID: value.sessionID, snapshotRev: 2, known: true,
            manifestSeqDurable: 0, finalManifestReceived: true, completeFiles: [], partial: [:], allComplete: false)
        try value.applyResume(restored)
        XCTAssertFalse(value.canOfferRemoval)
        XCTAssertEqual(value.progress.filesCompleteOnPC, 0)
        XCTAssertEqual(value.filesToOffer(), [0])
    }

    func testPersistedCompletionCannotAuthorizeRemovalBeforeResume() throws {
        var value = try planner()
        let full = ResumeSnapshot(sessionID: value.sessionID, snapshotRev: 1, known: true,
            manifestSeqDurable: 0, finalManifestReceived: true, completeFiles: [0...0], partial: [:], allComplete: true)
        try value.applyResume(full)
        let reopened = OriginalsPlanner(journal: value.journal, files: Array(value.files.values), totalFiles: 1)
        XCTAssertFalse(reopened.canOfferRemoval)
    }

    func testUnknownPCSnapshotCannotClaimSuccess() throws {
        var value = try planner()
        let contradictory = ResumeSnapshot(sessionID: value.sessionID, snapshotRev: 1, known: false,
            manifestSeqDurable: 0, finalManifestReceived: true, completeFiles: [0...0], partial: [:], allComplete: true)
        XCTAssertThrowsError(try value.applyResume(contradictory))
        XCTAssertFalse(value.canOfferRemoval)
    }
}
