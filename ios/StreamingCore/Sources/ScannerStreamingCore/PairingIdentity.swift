import Foundation
import CryptoKit

/// Pure identity operations. Does not open a socket or approve a pairing on the user's behalf.
public enum PairingIdentity {
    public static func normalizedToken(_ typed: String) throws -> String {
        // The PC shows the code grouped ("7Q4K 9M2X"), so inner spaces and hyphens are separators, not characters.
        let separators: Set<Character> = [" ", "-", "\u{00A0}", "\t"]
        let value = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).filter { !separators.contains($0) })
            .uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard value.count == 8, value.allSatisfy({ alphabet.contains($0) }) else {
            throw StreamError.invalid("pairing token")
        }
        return value
    }

    public static func fingerprint(leafCertificateDER: Data) -> String {
        SHA256.hash(data: leafCertificateDER).map { String(format: "%02x", $0) }.joined()
    }

    public static func shortCode(token: String, fingerprint: String) throws -> String {
        let normalized = try normalizedToken(token)
        let pin = try fingerprintBytes(fingerprint)
        var material = Data("s3d-sas-v1".utf8)
        material.append(0); material.append(Data(normalized.utf8)); material.append(0); material.append(pin)
        let hex = SHA256.hash(data: material).prefix(4).map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(4)) + " · " + String(hex.suffix(4))
    }

    public static func matchesPin(leafCertificateDER: Data, expectedFingerprint: String) throws -> Bool {
        let expected = try fingerprintBytes(expectedFingerprint)
        let actual = Data(SHA256.hash(data: leafCertificateDER))
        // Fixed-length XOR comparison. Platform-side timing behavior is not yet independently tested.
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func fingerprintBytes(_ value: String) throws -> Data {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StreamError.invalid("lowercase SHA-256 fingerprint")
        }
        var bytes = Data(); bytes.reserveCapacity(32)
        var cursor = value.startIndex
        for _ in 0..<32 {
            let next = value.index(cursor, offsetBy: 2)
            guard let byte = UInt8(value[cursor..<next], radix: 16) else { throw StreamError.invalid("fingerprint") }
            bytes.append(byte); cursor = next
        }
        return bytes
    }
}
