import Foundation
import Security
import ScannerStreamingCore

struct PairedPC: Codable, Sendable {
    let pcID: String
    let name: String
    var addresses: [String]
    let fingerprint: String
    let deviceID: String
    let secret: String

    var auth: HelloAuth { .deviceSecret(deviceID: deviceID, secret: secret) }
}

/// The device credential is never stored in Documents, logs, screenshots or the upload catalog.
enum PairedPCStore {
    private static let service = "org.scanner3d.capture.paired-pc"
    private static let account = "current"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() throws -> PairedPC? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else {
            throw OriginalStore.Failure.io("Keychain read status \(status)")
        }
        return try JSONDecoder().decode(PairedPC.self, from: bytes)
    }

    static func save(_ pc: PairedPC) throws {
        let data = try JSONEncoder().encode(pc)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw OriginalStore.Failure.io("Keychain save status \(inserted)") }
        } else if status != errSecSuccess { throw OriginalStore.Failure.io("Keychain update status \(status)") }
    }

    static func forget() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OriginalStore.Failure.io("Keychain delete status \(status)")
        }
    }
}
