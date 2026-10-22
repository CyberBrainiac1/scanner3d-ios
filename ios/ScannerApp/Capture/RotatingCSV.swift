import Foundation

/// Capture's serial queue owns each writer. Closed ten-second parts are immediately eligible for upload.
/// Data cells use RFC4180 quoting; numbers always use Swift's locale-independent decimal representation.
final class RotatingCSV {
    private let store: OriginalStore
    private let prefix: String
    private let kind: String
    private let header: [String]
    private var part = 0
    private var openedAt: Double?
    private var segment: UInt32?
    private var temp: URL?
    private var handle: FileHandle?

    init(store: OriginalStore, prefix: String, kind: String, header: [String]) {
        self.store = store; self.prefix = prefix; self.kind = kind; self.header = header
    }

    func append(_ cells: [String], time: Double, segment: UInt32? = nil) throws {
        guard cells.count == header.count, time.isFinite, time >= 0 else { throw OriginalStore.Failure.invalidPath }
        if let start = openedAt, time - start >= 10 || self.segment != segment { try close() }
        if handle == nil {
            let file = try store.temporaryURL(extension: "partial")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw OriginalStore.Failure.io("CSV create") }
            temp = file; handle = try FileHandle(forWritingTo: file); openedAt = time; self.segment = segment
            try handle?.write(contentsOf: Self.line(header))
        }
        try handle?.write(contentsOf: Self.line(cells))
    }

    func close() throws {
        guard let file = temp, let stream = handle else { return }
        try stream.synchronize(); try stream.close()
        handle = nil
        let path = prefix + String(format: "/part-%06d.csv", part)
        try store.seal(file, path: path, kind: kind, segment: segment)
        part += 1; temp = nil; openedAt = nil
    }

    static func line(_ cells: [String]) -> Data {
        Data((cells.map { value in
            value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: ",") + "\n").utf8)
    }
}
