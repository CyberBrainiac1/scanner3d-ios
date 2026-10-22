import Foundation

/// Lightweight list metadata. A broken recording stays visible with an unknown file count.
struct RecordingInventory: Sendable {
    let id: UUID
    let createdAt: Date
    let fileCount: Int?
    let finalized: Bool

    static func list(parent: URL) throws -> [RecordingInventory] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: parent.path) else { return [] }
        let parentInfo = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentInfo.isDirectory == true, parentInfo.isSymbolicLink != true else { throw OriginalStore.Failure.invalidPath }
        let folders = try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])
        return folders.compactMap { folder -> RecordingInventory? in
            guard let id = UUID(uuidString: folder.lastPathComponent), folder.lastPathComponent == id.uuidString.lowercased() else { return nil }
            let stamp = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            guard let catalog = try? OriginalStore.readCatalog(directory: folder), catalog.sessionID == id else {
                return RecordingInventory(id: id, createdAt: stamp, fileCount: nil, finalized: false)
            }
            return RecordingInventory(id: id, createdAt: stamp, fileCount: catalog.files.count, finalized: catalog.finalized)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
