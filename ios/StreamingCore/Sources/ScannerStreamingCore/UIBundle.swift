import Foundation
import CryptoKit

/// `ui.bundle` request (PC -> phone): the hot-updatable phone UI (HTML/JS/CSS for the app's web view;
/// docs/PHONE-UI-AND-DEBUG.md). The phone installs it only after every check here passes.
public struct UIBundleRequest: Decodable, Sendable, Equatable {
    public struct File: Decodable, Sendable, Equatable {
        public let path: String, bytes: Int, sha256: String, contentB64: String
        enum CodingKeys: String, CodingKey { case path, bytes, sha256, contentB64 = "content_b64" }
        public init(path: String, bytes: Int, sha256: String, contentB64: String) {
            self.path = path; self.bytes = bytes; self.sha256 = sha256; self.contentB64 = contentB64
        }
    }
    public let version: String, minNative: String, entry: String, files: [File]
    enum CodingKeys: String, CodingKey { case version, minNative = "min_native", entry, files }

    public init(version: String, minNative: String, entry: String, files: [File]) {
        self.version = version; self.minNative = minNative; self.entry = entry; self.files = files
    }

    public static let maxFiles = 64, maxFileBytes = 786_432, maxTotalBytes = 786_432

    /// Every check of the schema and the spec (paths, sizes, SHA-256, entry, min_native); the decoded files by path.
    public func verifiedFiles(nativeVersion: String) throws -> [String: Data] {
        guard Self.isValidVersionLabel(version) else { throw StreamError.invalid("UI bundle version label") }
        guard UIVersion.atLeast(nativeVersion, minNative) else {
            throw StreamError.invalid("This screen update needs app \(minNative) or newer; this iPhone has \(nativeVersion)")
        }
        guard (1...Self.maxFiles).contains(files.count) else { throw StreamError.invalid("UI bundle file count") }
        var out: [String: Data] = [:]
        var total = 0
        for file in files {
            guard Self.isValidPath(file.path), out[file.path] == nil else { throw StreamError.invalid("UI bundle path \(file.path)") }
            guard let data = Data(base64Encoded: file.contentB64), data.count == file.bytes, data.count <= Self.maxFileBytes else {
                throw StreamError.invalid("UI bundle file size \(file.path)")
            }
            guard Self.hex(SHA256.hash(data: data)) == file.sha256 else { throw StreamError.invalid("UI bundle file hash \(file.path)") }
            total += data.count
            guard total <= Self.maxTotalBytes else { throw StreamError.invalid("UI bundle too large") }
            out[file.path] = data
        }
        guard Self.isValidEntry(entry), out[entry] != nil else { throw StreamError.invalid("UI bundle entry \(entry)") }
        return out
    }

    /// `^[a-z0-9_-][a-z0-9._-]*(/[a-z0-9_-][a-z0-9._-]*)*$`, at most 128 characters: no `..`, no absolute or empty parts.
    public static func isValidPath(_ path: String) -> Bool {
        guard (1...128).contains(path.count) else { return false }
        let first = Set("abcdefghijklmnopqrstuvwxyz0123456789_-"), rest = first.union(".")
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            guard let head = part.first, first.contains(head) else { return false }
            return part.dropFirst().allSatisfy { rest.contains($0) }
        }
    }

    public static func isValidVersionLabel(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-")
        return (1...64).contains(value.count) && value.allSatisfy { allowed.contains($0) }
    }

    public static func isValidEntry(_ value: String) -> Bool {
        guard value.hasSuffix(".html"), (6...69).contains(value.count) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.dropLast(5).allSatisfy { allowed.contains($0) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

public enum UIVersion {
    /// Dotted numeric comparison: "0.3.0" >= "0.3", "0.10" > "0.9". A non-numeric part counts as 0.
    public static func atLeast(_ value: String, _ minimum: String) -> Bool {
        let a = parts(value), b = parts(minimum)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
    private static func parts(_ value: String) -> [Int] { value.split(separator: ".").map { Int($0) ?? 0 } }
}
