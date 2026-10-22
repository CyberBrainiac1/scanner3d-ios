import Foundation
import ScannerStreamingCore

/// File-integrity evidence only. Does not repair, finalize, delete, upload or certify a recording.
struct RecordingInspection: Codable, Sendable {
    struct Issue: Codable, Sendable, Identifiable {
        let kind: String
        let path: String
        let detail: String
        var id: String { kind + ":" + path }
    }
    let schema: String
    let sessionID: String
    let inspectedAt: String
    var catalogReadable = false
    var recordingFinalized = false
    var listedFiles = 0
    var verifiedFiles = 0
    var verifiedBytes: UInt64 = 0
    var unmatchedOriginalFiles = 0
    var pendingFiles = 0
    var issues: [Issue] = []
    var omittedIssueDetails = 0
    var closedFilesIntact = false

    var shareText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "Check report could not be encoded."
    }

    private mutating func add(_ kind: String, _ path: String, _ detail: String) {
        if issues.count < 200 { issues.append(Issue(kind: kind, path: path, detail: detail)) }
        else { omittedIssueDetails += 1 }
    }

    static func inspect(parent: URL, sessionID: UUID) throws -> RecordingInspection {
        try Task.checkCancellation()
        var report = RecordingInspection(schema: "scanner3d.local_file_check/1",
            sessionID: sessionID.uuidString.lowercased(), inspectedAt: ISO8601DateFormatter().string(from: Date()))
        let directory = parent.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        func safeDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard safeDirectory(parent), safeDirectory(directory) else {
            report.add("unsafe_folder", "", "The recording folder is missing or linked. Nothing was followed or changed.")
            return report
        }
        var catalog: OriginalStore.Journal?
        do {
            let value = try OriginalStore.readCatalog(directory: directory)
            guard value.sessionID == sessionID else { throw OriginalStore.Failure.incompleteCatalog }
            catalog = value
            report.catalogReadable = true
            report.recordingFinalized = value.finalized
            report.listedFiles = value.files.count
            if !value.finalized { report.add("not_finalized", "", "The recording did not finish closing. No end record was invented.") }
        } catch {
            report.add("catalog_unreadable", "closed-files.jsonl", "The file list could not be trusted. Existing files are retained; a partial journal is not silently repaired.")
        }
        let originals = directory.appendingPathComponent("originals", isDirectory: true)
        let known = Set(catalog?.files.map(\.path) ?? [])
        if safeDirectory(originals) {
            for file in catalog?.files ?? [] {
                try Task.checkCancellation()
                do {
                    let url = try OriginalStore.existingOriginal(file.path, under: originals)
                    let actual = try OriginalStore.digest(url, checkCancellation: { try Task.checkCancellation() })
                    if actual.bytes == file.bytes && actual.sha256 == file.sha256 {
                        report.verifiedFiles += 1
                        report.verifiedBytes += actual.bytes
                    } else { report.add("file_changed", file.path, "Size or SHA-256 differs from the closed-file list.") }
                } catch is CancellationError { throw CancellationError() }
                catch { report.add("file_unreadable", file.path, "Missing, linked, unreadable or no longer a regular file.") }
            }
            try walk(originals, base: originals) { path, linked in
                if linked { report.add("linked_original", path, "Linked entries are not followed.") }
                else if !known.contains(path) {
                    report.unmatchedOriginalFiles += 1
                    report.add("unmatched_original", path, report.catalogReadable
                        ? "This original is absent from the trusted file list. It was retained."
                        : "The file exists, but its catalog entry could not be verified. It was retained.")
                }
            }
        } else { report.add("originals_unreadable", "originals", "The originals folder is missing or linked.") }
        let pending = directory.appendingPathComponent("pending", isDirectory: true)
        if safeDirectory(pending) {
            try walk(pending, base: pending) { path, linked in
                report.pendingFiles += 1
                report.add(linked ? "linked_pending" : "unfinished_file", "pending/" + path,
                    "Not a closed original. Its bytes are retained and are not offered for upload.")
            }
        } else { report.add("pending_unreadable", "pending", "The pending folder is missing or linked.") }
        report.closedFilesIntact = report.catalogReadable && report.recordingFinalized &&
            report.verifiedFiles == report.listedFiles && report.issues.isEmpty && report.omittedIssueDetails == 0
        return report
    }

    private static func walk(_ directory: URL, base: URL, visit: (String, Bool) -> Void) throws {
        var readFailed = false
        let walker = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, _ in readFailed = true; return false })
        guard let walker else { throw OriginalStore.Failure.io("Could not enumerate saved files; all files retained.") }
        while let url = walker.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let path = String(url.path.dropFirst(base.path.count + 1))
            if values.isSymbolicLink == true { walker.skipDescendants(); visit(path, true) }
            else if values.isRegularFile == true { visit(path, false) }
        }
        if readFailed { throw OriginalStore.Failure.io("Some saved folders could not be read; all files retained.") }
    }
}
