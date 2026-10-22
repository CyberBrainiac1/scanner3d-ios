import Foundation

/// Scheduling state only: the socket's single writer (`SocketWriter`) owns exactly one send operation at a time.
/// Payloads must not retain ARFrame/CVPixelBuffer. Capturing originals is outside this queue.
///
/// - Bounded queue of 2, drop-oldest (`droppedQueue` = status `preview_dropped_queue`).
/// - At most `inflightMax` (hello `preview_inflight_max`, then `flow.preview.inflight_max`, 1...4) packets not yet
///   acknowledged with `preview.ack`. Send completion never frees a window slot.
/// - `flow.preview.enabled = false` pauses sending (state `.pausedByPC`); queued packets are dropped.
/// - If an outstanding packet has no ACK for `ackTimeout` (2 s), the queue is cleared and the state is
///   `.pausedNoAck` (UI: "Weak Wi-Fi"). A late ACK for an outstanding packet un-pauses; a reconnect resets.
public actor PreviewWindow {
    public struct Packet: Sendable {
        public let sequence: UInt64
        public let bytes: Data
        public init(sequence: UInt64, bytes: Data) { self.sequence = sequence; self.bytes = bytes }
    }

    public enum State: Equatable, Sendable {
        case idle, sending, windowFull, pausedByPC, pausedNoAck
    }

    public struct Counts: Sendable, Equatable {
        public let pending: Int
        public let inFlight: Int
        public let sending: Bool
        public let droppedQueue: UInt64
        public let droppedTimeout: UInt64
        public let state: State
    }

    public static let ackTimeout: Double = 2

    private var pending: [Packet] = []
    private var inFlight: [UInt64: Double] = [:]
    private var sending: UInt64?
    private var lastClock: Double
    private var newestSequence: UInt64?
    private var inflightMax: Int
    private var enabled = true
    private var timedOut = false
    public private(set) var droppedQueue: UInt64 = 0
    public private(set) var droppedTimeout: UInt64 = 0

    public init(now: Double, inflightMax: Int = 2) {
        self.lastClock = now
        self.inflightMax = min(4, max(1, inflightMax))
    }

    /// From hello `limits.preview_inflight_max` or `flow.preview.inflight_max`. Outstanding packets beyond a lowered
    /// limit stay outstanding; no new packet is sent until the count drops below the new limit.
    public func configure(inflightMax value: Int, enabled: Bool) throws {
        guard (1...4).contains(value) else { throw StreamError.invalid("preview inflight_max") }
        inflightMax = value
        self.enabled = enabled
        if !enabled { droppedQueue += UInt64(pending.count); pending.removeAll() }
    }

    public func offer(_ packet: Packet) throws {
        guard packet.bytes.count <= PacketEncoder.schemaMaximumBinaryBytes,
              packet.sequence < 1 << 53, newestSequence == nil || packet.sequence > newestSequence! else {
            throw StreamError.invalid("preview sequence/size")
        }
        newestSequence = packet.sequence
        guard enabled else { droppedQueue += 1; return }
        if pending.count == 2 { pending.removeFirst(); droppedQueue += 1 }
        pending.append(packet)
    }

    public func take(now: Double) throws -> Packet? {
        guard now.isFinite, now >= lastClock else { throw StreamError.invalid("monotonic clock") }
        lastClock = now
        // An idle connection has no missing ACK. The deadline applies only to outstanding packets.
        if let oldestUnacknowledged = inFlight.values.min(), now - oldestUnacknowledged >= PreviewWindow.ackTimeout {
            if !timedOut { timedOut = true }
            droppedTimeout += UInt64(pending.count); pending.removeAll()
            return nil
        }
        guard enabled, sending == nil, inFlight.count < inflightMax, !pending.isEmpty else { return nil }
        let packet = pending.removeFirst()
        sending = packet.sequence; inFlight[packet.sequence] = now
        return packet
    }

    public func sendCompleted(sequence: UInt64) throws {
        guard sending == sequence else { throw StreamError.invalid("send completion sequence") }
        sending = nil // Does not free the ACK window.
    }

    /// A send that failed (socket error) never reached the PC; forget it so it cannot hold the window.
    public func sendFailed(sequence: UInt64) {
        if sending == sequence { sending = nil }
        inFlight.removeValue(forKey: sequence)
    }

    /// Returns false for an unknown/duplicate sequence (e.g. an ACK for a packet from before a reset); callers
    /// log and ignore it. Throws only for impossible timestamps.
    @discardableResult
    public func acknowledge(sequence: UInt64, now: Double) throws -> Bool {
        guard now.isFinite else { throw StreamError.invalid("ACK clock") }
        guard let sentAt = inFlight[sequence] else { return false }
        guard now >= sentAt else { throw StreamError.invalid("ACK before send") }
        // A receive callback can capture its timestamp before a later sender task reaches this actor.
        inFlight.removeValue(forKey: sequence); lastClock = max(lastClock, now)
        if timedOut, (inFlight.values.min().map { lastClock - $0 < PreviewWindow.ackTimeout } ?? true) { timedOut = false }
        return true
    }

    public func resetConnection(now: Double) throws {
        guard now.isFinite, now >= lastClock else { throw StreamError.invalid("monotonic clock") }
        droppedQueue += UInt64(pending.count); pending.removeAll(); inFlight.removeAll(); sending = nil
        timedOut = false
        lastClock = now // Keep per-session sequence monotonic across reconnects.
    }

    public func state() -> State {
        if !enabled { return .pausedByPC }
        if timedOut { return .pausedNoAck }
        if sending != nil { return .sending }
        if inFlight.count >= inflightMax { return .windowFull }
        return .idle
    }

    public func counts() -> Counts {
        Counts(pending: pending.count, inFlight: inFlight.count, sending: sending != nil,
               droppedQueue: droppedQueue, droppedTimeout: droppedTimeout, state: state())
    }

    public var hasPending: Bool { !pending.isEmpty }
}
