import Foundation
import CryptoKit

/// RFC 8785 JSON Canonicalization Scheme for `JSONValue`.
///
/// The PC compares retransmissions (manifest seq bodies, `segment.start`, `session.start {resumed}`) by their JCS
/// form (contract section 4, Decision (i)). The phone uses `JCS.identity` to prove, before re-sending, that a rebuilt
/// body is the one it sent first, so a retransmission can never become a conflict by accident.
/// Shared vectors: workers/tests/data/jcs_vectors.json (copied into the test fixtures).
public enum JCS {
    public static func canonicalize(_ value: JSONValue) throws -> Data {
        var out = ""
        try write(value, into: &out)
        return Data(out.utf8)
    }

    public static func identity(_ value: JSONValue) throws -> String {
        SHA256.hash(data: try canonicalize(value)).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .string(let text): try writeString(text, into: &out)
        case .integer(let number): out += try format(Double(number))
        case .number(let number): out += try format(number)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                try write(item, into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            // Sort by UTF-16 code units (RFC 8785 section 3.2.3).
            let keys = members.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                try writeString(key, into: &out)
                out += ":"
                try write(members[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) throws {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// ECMAScript Number.prototype.toString for a finite double (RFC 8785 section 3.2.2.3).
    /// Swift's `description` yields the shortest round-trip digits; only the layout is re-applied.
    public static func format(_ number: Double) throws -> String {
        guard number.isFinite else { throw StreamError.invalid("JCS: non-finite number") }
        if number == 0 { return "0" }
        var text = "\(number.magnitude)"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let parsed = Int(text[text.index(after: e)...]) else { throw StreamError.invalid("JCS: digits") }
            exponent = parsed
            text = String(text[..<e])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = String(parts[0])
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = integerPart + fractionPart
        var point = integerPart.count + exponent // value = 0.digits × 10^point
        while digits.hasPrefix("0") { digits.removeFirst(); point -= 1 }
        while digits.hasSuffix("0") { digits.removeLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw StreamError.invalid("JCS: digits")
        }
        let k = digits.count
        let n = point
        var result: String
        if k <= n && n <= 21 {
            result = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            result = String(digits[..<split]) + "." + String(digits[split...])
        } else if -6 < n && n <= 0 {
            result = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            let mantissa = k == 1 ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst())
            result = mantissa + "e" + sign + String(abs(e))
        }
        return number < 0 ? "-" + result : result
    }
}
