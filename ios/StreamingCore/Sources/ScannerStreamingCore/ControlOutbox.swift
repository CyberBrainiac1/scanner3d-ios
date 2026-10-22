import Foundation

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), string(String), integer(Int64), number(Double)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw StreamError.invalid("non-finite JSON") }
            try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct QPCTicks: Codable, Sendable, Equatable {
    public let value: Int64
    public var wire: String { String(value) }
    public init(_ wire: String) throws {
        guard !wire.isEmpty, wire.utf8.allSatisfy({ (48...57).contains($0) }),
              wire == "0" || !wire.hasPrefix("0"), let parsed = Int64(wire), parsed >= 0 else {
            throw StreamError.invalid("QPC decimal int64 string")
        }
        value = parsed
    }
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(wire)
    }
}

/// The phone echoes exact PC ticks; it never converts long-uptime counters through Double.
public struct ClockReply: Encodable, Sendable {
    public let pcTransmit: QPCTicks
    public let deviceReceived: Double
    public let deviceSent: Double
    enum CodingKeys: String, CodingKey {
        case pcTransmit = "t_pc_tx_qpc_ticks", deviceReceived = "t_device_rx_s", deviceSent = "t_device_tx_s"
    }
    public init(pcTransmit: QPCTicks, deviceReceived: Double, deviceSent: Double) throws {
        guard deviceReceived.isFinite, deviceSent.isFinite, deviceReceived >= 0,
              deviceSent >= deviceReceived else { throw StreamError.invalid("device clock order") }
        self.pcTransmit = pcTransmit; self.deviceReceived = deviceReceived; self.deviceSent = deviceSent
    }

    public var body: JSONValue {
        .object(["t_pc_tx_qpc_ticks": .string(pcTransmit.wire),
                 "t_device_rx_s": .number(deviceReceived), "t_device_tx_s": .number(deviceSent)])
    }
}

/// Validates a PC message id ("pc-" + 1...15 decimal digits, as `common.schema.json#/$defs/msg_id_pc`).
public func isValidPCMessageID(_ id: String) -> Bool {
    guard id.hasPrefix("pc-") else { return false }
    let digits = id.utf8.dropFirst(3)
    return (1...15).contains(digits.count) && digits.allSatisfy { (48...57).contains($0) }
}

/// One socket's ordered control queue.
///
/// - Message ids are allocated in `take()`, i.e. by the socket's single writer, so wire order == id order
///   ("ids strictly increase within a connection, in send order", Decision (h)), even though pongs jump the queue.
/// - Pongs (`ping` responses) are serialized lazily: `t_device_tx_s` (t3) is stamped at `take(now:)`, immediately
///   before the writer calls `send()` (contract section 7). They go before every other queued control message.
/// - Until `markHandshakeComplete()`, only `hello` can be taken (hello is the first and only message before the
///   handshake, at most 16 KiB, Decision F4). Everything else waits in order.
/// - One instance per connection. `drainUnsent()` hands queued drafts back on a disconnect so the caller can
///   re-enqueue idempotent requests on the next connection or fail them explicitly (never silently dropped).
public actor ControlOutbox {
    public typealias Ticket = UUID

    public enum Payload: Sendable, Equatable {
        case message(type: String, kind: String, body: JSONValue, replyTo: String?)
        case errorResponse(type: String, replyTo: String, error: JSONValue)
        case pong(replyTo: String, pcTransmit: QPCTicks, deviceReceived: Double)
    }

    public struct Draft: Sendable, Equatable {
        public let ticket: Ticket
        public let payload: Payload
        public var type: String {
            switch payload {
            case .message(let type, _, _, _), .errorResponse(let type, _, _): return type
            case .pong: return "ping"
            }
        }
        public var isRequest: Bool {
            if case .message(_, let kind, _, _) = payload { return kind == "request" }
            return false
        }
    }

    public struct Pending: Sendable {
        public let id: String
        public let lease: UUID
        public let utf8: Data
        public let draft: Draft
    }

    public static let helloMaximumBytes = 16 * 1024

    private var nextSequence: UInt64 = 1
    private var pongs: [Draft] = []
    private var queue: [Draft] = []
    private var writing: (lease: UUID, draft: Draft)?
    private var handshakeComplete = false
    private var maximumBytes: Int
    private let capacity: Int
    private var sentRequests: [String: Ticket] = [:]

    public init(maximumBytes: Int = 1024 * 1024, capacity: Int = 64) throws {
        guard (65536...1048576).contains(maximumBytes), (1...256).contains(capacity) else {
            throw StreamError.invalid("control queue limits")
        }
        self.maximumBytes = maximumBytes; self.capacity = capacity
    }

    /// Apply `hello.limits.max_text_bytes` and open the queue for non-hello messages.
    public func markHandshakeComplete(maximumTextBytes: Int) throws {
        guard (65536...1048576).contains(maximumTextBytes) else { throw StreamError.invalid("max_text_bytes") }
        maximumBytes = maximumTextBytes
        handshakeComplete = true
    }

    @discardableResult
    public func enqueue(type: String, kind: String, body: JSONValue, replyTo: String? = nil) throws -> Ticket {
        guard ["request", "response", "event"].contains(kind), (kind == "response") == (replyTo != nil),
              !type.isEmpty, type.utf8.count <= 64 else {
            throw StreamError.invalid("control envelope")
        }
        if let replyTo { guard isValidPCMessageID(replyTo) else { throw StreamError.invalid("reply id") } }
        return try append(.message(type: type, kind: kind, body: body, replyTo: replyTo))
    }

    /// `error` response (`ok: false`) to a PC request, e.g. `unknown_type` or `session_not_active`.
    @discardableResult
    public func enqueueErrorResponse(type: String, replyTo: String, code: String, message: String,
                                     retryable: Bool, details: [String: JSONValue] = [:]) throws -> Ticket {
        guard isValidPCMessageID(replyTo) else { throw StreamError.invalid("reply id") }
        let error: JSONValue = .object(["code": .string(code), "message": .string(String(message.prefix(2000))),
                                        "retryable": .bool(retryable), "details": .object(details)])
        return try append(.errorResponse(type: type, replyTo: replyTo, error: error))
    }

    /// Pong with t2 captured by the receive handler; t3 is stamped when the writer takes it.
    @discardableResult
    public func enqueuePong(replyTo: String, pcTransmit: QPCTicks, deviceReceived: Double) throws -> Ticket {
        guard isValidPCMessageID(replyTo) else { throw StreamError.invalid("reply id") }
        guard deviceReceived.isFinite, deviceReceived >= 0 else { throw StreamError.invalid("device clock") }
        guard pongs.count + queue.count < capacity else { throw StreamError.invalid("control queue full") }
        let draft = Draft(ticket: UUID(), payload: .pong(replyTo: replyTo, pcTransmit: pcTransmit,
                                                         deviceReceived: deviceReceived))
        pongs.append(draft)
        return draft.ticket
    }

    /// Re-queue drafts drained from a previous connection (ids are re-allocated here; bodies are unchanged).
    public func requeue(_ drafts: [Draft]) throws {
        for draft in drafts {
            guard pongs.count + queue.count < capacity else { throw StreamError.invalid("control queue full") }
            if case .pong = draft.payload { continue } // A stale pong is useless on a new connection.
            queue.append(draft)
        }
    }

    private func append(_ payload: Payload) throws -> Ticket {
        guard pongs.count + queue.count < capacity else { throw StreamError.invalid("control queue full") }
        let draft = Draft(ticket: UUID(), payload: payload)
        // Size check now (fail at the producer), using the longest possible id.
        let probe = try ControlOutbox.encode(draft, id: "ph-999999999999999", now: 0, wallTime: Date())
        let limit = draft.type == "hello" ? ControlOutbox.helloMaximumBytes : maximumBytes
        guard probe.count <= limit else { throw StreamError.sizeLimit }
        queue.append(draft)
        return draft.ticket
    }

    public var hasWork: Bool { writing == nil && (!pongs.isEmpty || queue.contains { handshakeComplete || $0.type == "hello" }) }

    /// Called only by the socket's single writer. `now` is the device uptime clock (t3 for pongs).
    public func take(now: Double, wallTime: Date = Date()) throws -> Pending? {
        guard writing == nil, nextSequence <= 999_999_999_999_999 else { return nil }
        var draft: Draft?
        if handshakeComplete, !pongs.isEmpty {
            draft = pongs.removeFirst()
        } else if let index = queue.firstIndex(where: { handshakeComplete || $0.type == "hello" }) {
            draft = queue.remove(at: index)
        }
        guard let draft else { return nil }
        let id = "ph-\(nextSequence)"
        let data = try ControlOutbox.encode(draft, id: id, now: now, wallTime: wallTime)
        nextSequence += 1
        let lease = UUID()
        writing = (lease, draft)
        if draft.isRequest { sentRequests[id] = draft.ticket }
        return Pending(id: id, lease: lease, utf8: data, draft: draft)
    }

    public func sent(lease: UUID) throws {
        guard writing?.lease == lease else { throw StreamError.invalid("stale control send completion") }
        writing = nil
    }

    /// Ticket of the request this PC response answers (nil for unknown reply ids).
    public func ticket(forReplyTo id: String) -> Ticket? { sentRequests.removeValue(forKey: id) }

    /// Disconnect: returns every draft that was queued or inside `send()` (which may or may not have arrived).
    public func drainUnsent() -> [Draft] {
        var drafts: [Draft] = []
        if let writing { drafts.append(writing.draft) }
        drafts += queue
        queue.removeAll(); pongs.removeAll(); writing = nil; sentRequests.removeAll()
        return drafts
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func encode(_ draft: Draft, id: String, now: Double, wallTime: Date) throws -> Data {
        var envelope: [String: JSONValue] = ["v": .integer(1), "id": .string(id),
                                             "sent_at": .string(iso8601(wallTime))]
        switch draft.payload {
        case .message(let type, let kind, let body, let replyTo):
            envelope["type"] = .string(type); envelope["kind"] = .string(kind); envelope["body"] = body
            if let replyTo { envelope["reply_to"] = .string(replyTo); envelope["ok"] = .bool(true) }
        case .errorResponse(let type, let replyTo, let error):
            envelope["type"] = .string(type); envelope["kind"] = .string("response")
            envelope["reply_to"] = .string(replyTo); envelope["ok"] = .bool(false); envelope["error"] = error
        case .pong(let replyTo, let pcTransmit, let deviceReceived):
            let reply = try ClockReply(pcTransmit: pcTransmit, deviceReceived: deviceReceived,
                                       deviceSent: max(now, deviceReceived))
            envelope["type"] = .string("ping"); envelope["kind"] = .string("response")
            envelope["reply_to"] = .string(replyTo); envelope["ok"] = .bool(true); envelope["body"] = reply.body
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(envelope))
    }
}
