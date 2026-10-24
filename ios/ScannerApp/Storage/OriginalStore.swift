import Foundation
import CryptoKit
import Darwin
import ScannerStreamingCore

/// Closed originals are immutable. Temporary files and the private journal live beside, never inside,
/// originals. All operations are serialized, including catalog allocation and journal persistence.
/// A failed disk operation poisons this instance: callers must stop capture and preserve its files.
final class OriginalStore: @unchecked Sendable {
    struct Journal: Codable, Sendable {
        let sessionID: UUID
        var files: [LocalFile]
        var finalized: Bool
    }

    enum Failure: Error, LocalizedError {
        case invalidPath, incompleteCatalog, finalized, io(String)
        var errorDescription: String? {
            switch self {
            case .invalidPath: return "A recording file has an invalid or conflicting path. Existing files are kept."
            case .incompleteCatalog: return "The recording's file list is incomplete or a file changed. All files are retained for recovery."
            case .finalized: return "This recording is already closed or a storage error stopped further writes."
            case .io(let detail): return detail
            }
        }
    }
    let sessionID: UUID
    let directory: URL
    let originals: URL
    private let scratch: URL
    private let journalURL: URL
    private let catalogURL: URL
    private let lock = NSLock()
    private var journal: Journal
    private var poisoned = false

    init(parent: URL, sessionID: UUID, create: Bool) throws {
        guard !Self.isSymlink(parent) else { throw Failure.invalidPath }
        self.sessionID = sessionID
        directory = parent.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        originals = directory.appendingPathComponent("originals", isDirectory: true)
        scratch = directory.appendingPathComponent("pending", isDirectory: true)
        journalURL = directory.appendingPathComponent("closed-files.json")
        catalogURL = directory.appendingPathComponent("closed-files.jsonl")
        let fm = FileManager.default
        if create {
            guard !fm.fileExists(atPath: directory.path) else { throw Failure.io("Session already exists") }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try fm.createDirectory(at: originals, withIntermediateDirectories: false)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            journal = Journal(sessionID: sessionID, files: [], finalized: false)
            try Self.atomicJournal(journal, to: journalURL)
            guard fm.createFile(atPath: catalogURL.path, contents: nil) else { throw Failure.io("Catalog create") }
            let file = try FileHandle(forWritingTo: catalogURL)
            do { try file.synchronize(); try file.close() } catch { try? file.close(); throw error }
            try Self.syncDirectory(directory)
            try Self.syncDirectory(parent)
        } else {
            journal = try Self.readCatalog(directory: directory)
            guard journal.sessionID == sessionID else { throw Failure.incompleteCatalog }
            guard !Self.isSymlink(directory), !Self.isSymlink(originals), !Self.isSymlink(scratch) else {
                throw Failure.invalidPath
            }
            for (index, file) in journal.files.enumerated() {
                guard file.fileID == UInt64(index) else { throw Failure.incompleteCatalog }
                _ = try LocalFile(fileID: file.fileID, path: file.path, kind: file.kind, bytes: file.bytes,
                                  sha256: file.sha256, segment: file.segment)
                let url = try Self.child(originals, path: file.path, makeParents: false)
                let check = try Self.digest(url)
                guard check.bytes == file.bytes, check.sha256 == file.sha256 else { throw Failure.incompleteCatalog }
            }
            // A crash between rename and journal persistence leaves an orphan. Preserve it, but never
            // upload a supposedly complete catalog or silently allocate its ID to another file.
            let known = Set(journal.files.map(\.path))
            let walker = fm.enumerator(at: originals, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            while let url = walker?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw Failure.invalidPath }
                if values.isRegularFile == true {
                    guard let relative = Self.relativePath(of: url, under: originals), known.contains(relative) else {
                        throw Failure.incompleteCatalog
                    }
                }
            }
        }
    }

    var files: [LocalFile] { lock.lock(); defer { lock.unlock() }; return journal.files }
    var snapshot: Journal { lock.lock(); defer { lock.unlock() }; return journal }
    var finalized: Bool { lock.lock(); defer { lock.unlock() }; return journal.finalized }

    func temporaryURL(extension suffix: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !poisoned, !journal.finalized, suffix.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw Failure.finalized
        }
        return scratch.appendingPathComponent(UUID().uuidString.lowercased() + "." + suffix)
    }

    @discardableResult
    func commit(_ data: Data, path: String, kind: String, segment: UInt32? = nil) throws -> LocalFile {
        let temp = try temporaryURL(extension: "partial")
        do {
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw Failure.io("Create") }
            let handle = try FileHandle(forWritingTo: temp)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            return try seal(temp, path: path, kind: kind, segment: segment)
        } catch {
            lock.lock(); poisoned = true; lock.unlock()
            throw error
        }
    }

    /// The producer must close its handle/AVAssetWriter before sealing. No overwrite is possible.
    @discardableResult
    func seal(_ temp: URL, path: String, kind: String, segment: UInt32? = nil) throws -> LocalFile {
        lock.lock(); defer { lock.unlock() }
        guard !poisoned, !journal.finalized else { throw Failure.finalized }
        do {
            guard temp.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL,
                  !Self.isSymlink(temp), !journal.files.contains(where: { $0.path == path }),
                  (path == "session_end.json") == (kind == "session_end") else {
                throw Failure.invalidPath
            }
            let dest = try Self.child(originals, path: path, makeParents: true)
            guard !FileManager.default.fileExists(atPath: dest.path) else { throw Failure.invalidPath }
            let file = try FileHandle(forWritingTo: temp)
            do { try file.synchronize(); try file.close() } catch { try? file.close(); throw error }
            let hash = try Self.digest(temp)
            let entry = try LocalFile(fileID: UInt64(journal.files.count), path: path, kind: kind,
                                      bytes: hash.bytes, sha256: hash.sha256, segment: segment)
            try FileManager.default.moveItem(at: temp, to: dest)
            try Self.syncDirectory(dest.deletingLastPathComponent())
            try Self.syncDirectory(scratch)
            // Append one small durable record. Rewriting the whole growing catalog per depth frame
            // would cause quadratic metadata I/O and copy the entire Array on every commit.
            var record = try JSONEncoder().encode(entry); record.append(10)
            let log = try FileHandle(forWritingTo: catalogURL)
            do { try log.seekToEnd(); try log.write(contentsOf: record); try log.synchronize(); try log.close() }
            catch { try? log.close(); throw error }
            journal.files.append(entry)
            if path == "session_end.json" {
                guard kind == "session_end" else { throw Failure.invalidPath }
                journal.finalized = true
                try Self.atomicJournal(journal, to: journalURL) // One final human-readable snapshot.
            }
            return entry
        } catch { poisoned = true; throw error }
    }

    /// Upload reads recheck the whole original before its first offer. Never read a pending file.
    func verifiedURL(for file: LocalFile) throws -> URL {
        lock.lock()
        let accepted = !poisoned && journal.files.contains(file)
        lock.unlock()
        guard accepted else { throw Failure.incompleteCatalog }
        // These files are closed and immutable. Hashing a large video must not hold the capture
        // catalog's lock and stall writes of unrelated new depth/confidence files.
        let url = try Self.child(originals, path: file.path, makeParents: false)
        let actual = try Self.digest(url)
        guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw Failure.incompleteCatalog }
        return url
    }

    static func digest(_ url: URL, checkCancellation: () throws -> Void = {}) throws -> (bytes: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256(), count: UInt64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try checkCancellation()
            count += UInt64(data.count); sha.update(data: data)
        }
        return (count, sha.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Reads private bookkeeping without verifying all large originals (suitable for the Scans list).
    /// Reopening for upload still independently checks every file hash and rejects orphaned files.
    static func readCatalog(directory: URL) throws -> Journal {
        let headerURL = directory.appendingPathComponent("closed-files.json")
        let logURL = directory.appendingPathComponent("closed-files.jsonl")
        guard !isSymlink(directory), !isSymlink(headerURL), !isSymlink(logURL) else { throw Failure.invalidPath }
        var result = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: headerURL))
        let bytes = try Data(contentsOf: logURL)
        guard bytes.isEmpty || bytes.last == 10 else { throw Failure.incompleteCatalog }
        let entries = try bytes.split(separator: 10).map { try JSONDecoder().decode(LocalFile.self, from: Data($0)) }
        guard result.files.isEmpty || result.files == entries else { throw Failure.incompleteCatalog }
        var paths: Set<String> = []
        for (index, file) in entries.enumerated() {
            guard file.fileID == UInt64(index), paths.insert(file.path).inserted else { throw Failure.incompleteCatalog }
            if file.path == "session_end.json" || file.kind == "session_end" {
                guard file.path == "session_end.json", file.kind == "session_end", index == entries.count - 1 else {
                    throw Failure.incompleteCatalog
                }
            }
            _ = try LocalFile(fileID: file.fileID, path: file.path, kind: file.kind, bytes: file.bytes,
                              sha256: file.sha256, segment: file.segment)
        }
        result.files = entries
        result.finalized = entries.last?.path == "session_end.json" && entries.last?.kind == "session_end"
        return result
    }

    /// Read-only path resolution shared with inspection. Never creates a directory or follows a link.
    static func existingOriginal(_ path: String, under root: URL) throws -> URL {
        let url = try child(root, path: path, makeParents: false)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.invalidPath }
        return url
    }

    private static func child(_ root: URL, path: String, makeParents: Bool) throws -> URL {
        guard LocalFile.isValidSessionPath(path), !isSymlink(root) else { throw Failure.invalidPath }
        let parts = path.split(separator: "/")
        var current = root
        for (index, component) in parts.enumerated() {
            current.appendPathComponent(String(component))
            guard !isSymlink(current) else { throw Failure.invalidPath }
            if index < parts.count - 1, makeParents, !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                try syncDirectory(current.deletingLastPathComponent())
            }
        }
        return current
    }

    /// `url` relative to `base` ("depth/000002.f32"), or nil when it is not inside it. The base and the file's folder
    /// are symlink-resolved first (the file itself is not, so a symlinked file keeps its own name): on a device the
    /// Documents URL is /var/mobile/... while an enumerator returns /private/var/mobile/..., and plain prefix arithmetic
    /// garbled every path, so every reopened scan looked incomplete (first real device run, 2026-10-24).
    static func relativePath(of url: URL, under base: URL) -> String? {
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let full = (folder as NSString).appendingPathComponent(url.lastPathComponent)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard full.hasPrefix(prefix), full.count > prefix.count else { return nil }
        return String(full.dropFirst(prefix.count))
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func atomicJournal(_ journal: Journal, to url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".journal")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw Failure.io("Journal create") }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let result = temp.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination in Darwin.rename(source!, destination!) }
        }
        guard result == 0 else { throw Failure.io("Journal rename errno=\(errno)") }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDONLY) }
        guard fd >= 0 else { throw Failure.io("Directory open errno=\(errno)") }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw Failure.io("Directory sync errno=\(errno)") }
    }
}
