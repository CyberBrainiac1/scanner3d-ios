import Foundation
import Network

/// One PC address from the QR (`addrs`) or typed by the user: a private IPv4 (RFC 1918 or 169.254/16) or a
/// unique-local IPv6 (fc00::/7), with an explicit port. Parsed with Network.framework, never by regex alone
/// (contract section 2; reference `preview_codec.parse_pairing_addr`).
public struct PairingAddress: Codable, Hashable, Sendable, CustomStringConvertible {
    public let host: String      // canonical text without brackets, lowercase
    public let port: UInt16
    public let isIPv6: Bool

    public static let defaultPort: UInt16 = 47833

    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
    /// Host as shown to people (the PC shows "192.168.1.42" without the default port).
    public var displayHost: String { port == PairingAddress.defaultPort ? (isIPv6 ? "[\(host)]" : host) : description }

    public func url(path: String) -> URL? {
        URL(string: "wss://\(isIPv6 ? "[\(host)]" : host):\(port)\(path)")
    }

    /// Strict QR form: "a.b.c.d:port" or "[ula]:port".
    public static func parse(_ text: String) throws -> PairingAddress {
        guard text.utf8.count <= 64, text == text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw StreamError.invalid("address")
        }
        if text.hasPrefix("[") {
            guard let close = text.range(of: "]:") else { throw StreamError.invalid("IPv6 must be [addr]:port") }
            let host = String(text[text.index(after: text.startIndex)..<close.lowerBound])
            let port = try parsePort(String(text[close.upperBound...]))
            return try ipv6(host, port: port)
        }
        guard let colon = text.lastIndex(of: ":") else { throw StreamError.invalid("missing :port") }
        let host = String(text[..<colon])
        let port = try parsePort(String(text[text.index(after: colon)...]))
        return try ipv4(host, port: port)
    }

    /// Typed form (screen 1b): the PC shows the bare address, so the port is optional (default 47833).
    public static func parseTyped(_ typed: String) throws -> PairingAddress {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("[") {
            if text.contains("]:") { return try parse(text) }
            guard text.hasSuffix("]") else { throw StreamError.invalid("address") }
            return try ipv6(String(text.dropFirst().dropLast()), port: defaultPort)
        }
        if text.filter({ $0 == ":" }).count == 1 { return try parse(text) }
        if text.contains(":") { return try ipv6(text, port: defaultPort) }
        return try ipv4(text, port: defaultPort)
    }

    static func parsePort(_ text: String) throws -> UInt16 {
        guard (1...5).contains(text.count), text.first != "0", text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (1...65535).contains(value) else { throw StreamError.invalid("port") }
        return UInt16(value)
    }

    static func ipv4(_ host: String, port: UInt16) throws -> PairingAddress {
        // Shape first (no leading zeros, exactly four decimal octets), then the platform parser.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { throw StreamError.invalid("IPv4") }
        var bytes: [UInt8] = []
        for octet in octets {
            guard (1...3).contains(octet.count), octet.utf8.allSatisfy({ (48...57).contains($0) }),
                  octet == "0" || octet.first != "0", let value = Int(octet), value <= 255 else {
                throw StreamError.invalid("IPv4 octet")
            }
            bytes.append(UInt8(value))
        }
        guard let parsed = IPv4Address(host), Array(parsed.rawValue) == bytes else { throw StreamError.invalid("IPv4") }
        let isPrivate = bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        guard isPrivate else { throw StreamError.invalid("IPv4 address is not private") }
        return PairingAddress(host: host, port: port, isIPv6: false)
    }

    static func ipv6(_ host: String, port: UInt16) throws -> PairingAddress {
        guard !host.contains("%"), !host.contains("."), host.count <= 39,
              host.allSatisfy({ "0123456789abcdef:".contains($0) }) else {
            throw StreamError.invalid("IPv6 must be lowercase hex without zone id or embedded IPv4")
        }
        guard let parsed = IPv6Address(host) else { throw StreamError.invalid("IPv6") }
        let raw = Array(parsed.rawValue)
        guard raw.count == 16, raw[0] & 0xFE == 0xFC else { throw StreamError.invalid("IPv6 is not unique-local") }
        return PairingAddress(host: host, port: port, isIPv6: true)
    }

    /// IPv4 bytes for subnet matching, nil for IPv6.
    public var ipv4Bytes: [UInt8]? { isIPv6 ? nil : IPv4Address(host).map { Array($0.rawValue) } }
}

/// A local IPv4 interface address (from getifaddrs in the app) used to rank QR addresses.
public struct LocalInterface: Sendable, Equatable {
    public let address: [UInt8]
    public let netmask: [UInt8]
    public init(address: [UInt8], netmask: [UInt8]) { self.address = address; self.netmask = netmask }
}

public enum AddressRanking {
    /// Order in which to try a PC's addresses.
    ///
    /// TODO-RELEASE: the PC ranks `addrs` (at most 2, Decision S10, e.g. Wi-Fi before a Hyper-V switch). Until the
    /// released text says otherwise the phone keeps the PC's order, except that (1) the last address that worked
    /// goes first and (2) addresses on one of the phone's own IPv4 subnets go before addresses that are not.
    public static func rank(_ addresses: [PairingAddress], lastGood: PairingAddress?,
                            interfaces: [LocalInterface]) -> [PairingAddress] {
        func onLocalSubnet(_ address: PairingAddress) -> Bool {
            guard let bytes = address.ipv4Bytes, bytes.count == 4 else { return false }
            return interfaces.contains { interface in
                interface.address.count == 4 && interface.netmask.count == 4 &&
                    (0..<4).allSatisfy { (bytes[$0] & interface.netmask[$0]) == (interface.address[$0] & interface.netmask[$0]) }
            }
        }
        var unique: [PairingAddress] = []
        for address in addresses where !unique.contains(address) { unique.append(address) }
        let indexed = unique.enumerated().map { (offset: $0.offset, address: $0.element) }
        let sorted = indexed.sorted { a, b in
            let aKey = (a.address == lastGood ? 0 : 1, onLocalSubnet(a.address) ? 0 : 1, a.offset)
            let bKey = (b.address == lastGood ? 0 : 1, onLocalSubnet(b.address) ? 0 : 1, b.offset)
            return aKey < bKey
        }
        return sorted.map { $0.address }
    }
}

/// The pairing QR (`schemas/pairing.qr.schema.json`).
public struct PairingPayload: Sendable, Equatable {
    public let pcID: String
    public let pcName: String
    public let addresses: [PairingAddress]
    public let fingerprint: String
    public let token: String
    public let expires: Date

    private struct Wire: Decodable {
        let s3d: String, v: Int, pc_id: String, pc_name: String, addrs: [String], fp: String, tok: String, exp: Int64
    }

    public init(pcID: String, pcName: String, addresses: [PairingAddress], fingerprint: String, token: String,
                expires: Date) {
        self.pcID = pcID; self.pcName = pcName; self.addresses = addresses; self.fingerprint = fingerprint
        self.token = token; self.expires = expires
    }

    public static func parse(_ text: String) throws -> PairingPayload {
        guard text.utf8.count <= 2048 else { throw StreamError.sizeLimit }
        let wire = try JSONDecoder().decode(Wire.self, from: Data(text.utf8))
        guard wire.s3d == "pair", wire.v == 1, isLowercaseUUID(wire.pc_id),
              (1...64).contains(wire.pc_name.count), (1...4).contains(wire.addrs.count),
              (1_700_000_000...4_102_444_800).contains(wire.exp) else {
            throw StreamError.invalid("pairing QR")
        }
        _ = try PairingIdentity.fingerprintBytes(wire.fp)
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard wire.tok.count == 8, wire.tok.allSatisfy({ alphabet.contains($0) }) else {
            throw StreamError.invalid("pairing token")
        }
        let addresses = wire.addrs.compactMap { try? PairingAddress.parse($0) } // invalid entries are ignored
        guard !addresses.isEmpty else { throw StreamError.invalid("no usable PC address") }
        return PairingPayload(pcID: wire.pc_id, pcName: wire.pc_name, addresses: addresses, fingerprint: wire.fp,
                              token: wire.tok, expires: Date(timeIntervalSince1970: TimeInterval(wire.exp)))
    }

    static func isLowercaseUUID(_ text: String) -> Bool {
        guard text.count == 36, UUID(uuidString: text) != nil else { return false }
        return text.allSatisfy { "0123456789abcdef-".contains($0) }
    }
}
