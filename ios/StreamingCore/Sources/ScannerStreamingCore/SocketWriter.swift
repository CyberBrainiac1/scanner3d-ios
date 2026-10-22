import Foundation

/// The ONE writer of a socket (contract section 5: "at most one message inside send(); control before preview").
///
/// Each loop iteration takes, in order: a control message from `ControlOutbox` (pongs first), else one binary item
/// from the socket's binary source (S3DP preview packets from `PreviewWindow`, or S3DC chunks from the uploader).
/// It awaits `send` before taking anything else, so URLSession never holds more than one of our messages and the
/// drop-oldest preview queue keeps working. When idle it sleeps up to `idleSleep`; `poke()` ends the sleep early.
public actor SocketWriter {
    public enum Frame: Sendable, Equatable { case text(Data), binary(Data) }

    public struct BinaryItem: Sendable {
        public let data: Data
        public let tag: UInt64
        public init(data: Data, tag: UInt64) { self.data = data; self.tag = tag }
    }

    public typealias Send = @Sendable (Frame) async throws -> Void
    /// Called with the device-uptime "now"; returns the next binary item, already stamped if needed.
    public typealias BinarySource = @Sendable (Double) async throws -> BinaryItem?
    /// Called after the send attempt: (tag, delivered-to-URLSession). Never an ACK.
    public typealias BinaryDone = @Sendable (UInt64, Bool) async -> Void

    private let outbox: ControlOutbox
    private let clock: @Sendable () -> Double
    private let send: Send
    private var binarySource: BinarySource?
    private var binaryDone: BinaryDone?
    private var sleeper: Task<Void, Never>?
    private let idleSleep: UInt64
    public private(set) var framesSent: UInt64 = 0

    public init(outbox: ControlOutbox, idleSleepSeconds: Double = 0.05,
                clock: @escaping @Sendable () -> Double, send: @escaping Send) {
        self.outbox = outbox; self.clock = clock; self.send = send
        self.idleSleep = UInt64(max(0.001, idleSleepSeconds) * 1_000_000_000)
    }

    public func setBinarySource(_ source: BinarySource?, done: BinaryDone?) {
        binarySource = source; binaryDone = done
        poke()
    }

    /// Wake the loop (new control message, new preview packet, ACK, flow change).
    public func poke() { sleeper?.cancel() }

    /// Runs until the task is cancelled or a send throws (the caller then tears the connection down).
    public func run() async throws {
        while !Task.isCancelled {
            if try await sendOne() { continue }
            let nap = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: idleSleep) }
            sleeper = nap
            await nap.value
            sleeper = nil
        }
    }

    /// One scheduling step; returns true if something was sent. Exposed for tests.
    public func sendOne() async throws -> Bool {
        if let pending = try await outbox.take(now: clock()) {
            try await send(.text(pending.utf8))
            try await outbox.sent(lease: pending.lease)
            framesSent += 1
            return true
        }
        let done = binaryDone // A source replacement during send must not redirect the old completion.
        if let source = binarySource, let item = try await source(clock()) {
            do {
                try await send(.binary(item.data))
            } catch {
                await done?(item.tag, false)
                throw error
            }
            await done?(item.tag, true)
            framesSent += 1
            return true
        }
        return false
    }
}
