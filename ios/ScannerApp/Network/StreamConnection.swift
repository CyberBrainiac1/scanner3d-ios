import Foundation
import ScannerStreamingCore

/// One socket, one writer, one reader. Existing StreamingCore owns message IDs, pong priority and
/// preview/chunk scheduling. Correlated replies must match the outstanding request's type.
actor StreamConnection {
    enum Failure: Error, LocalizedError {
        case disconnected, timeout, wrongReply, remote(String)
        /// The PC answered a request with an error response (code from contracts error_code, e.g. not_paired).
        case rejected(code: String, message: String)
        var errorDescription: String? {
            switch self {
            case .disconnected: return "The PC connection closed. Original scan files remain on iPhone."
            case .timeout: return "The PC did not reply in time. Reconnect to continue sending."
            case .wrongReply: return "The PC sent an unexpected reply."
            case .remote(let text): return text
            case .rejected(_, let text): return text
            }
        }
    }
    private struct Waiter {
        let type: String
        let continuation: CheckedContinuation<IncomingMessage, Error>
        let timer: Task<Void, Never>
    }
    let channel: String
    private let socket: PinnedSocket
    private let outbox: ControlOutbox
    private let writer: SocketWriter
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    private var idleSeconds: Double = 5
    private var waiters: [UUID: Waiter] = [:]
    private var earlyReplies: [UUID: (String, IncomingMessage)] = [:]
    private var closed = false
    private var maximumTextBytes = ControlOutbox.helloMaximumBytes
    private var lastPCSequence: UInt64 = 0
    private let onEvent: @Sendable (IncomingMessage) async throws -> Void

    init(address: PairingAddress, fingerprint: String, channel: String,
         onEvent: @escaping @Sendable (IncomingMessage) async throws -> Void) throws {
        self.channel = channel; self.onEvent = onEvent
        let transport = try PinnedSocket(address: address, fingerprint: fingerprint, channel: channel)
        socket = transport
        let queue = try ControlOutbox()
        outbox = queue
        writer = SocketWriter(outbox: queue, clock: { ProcessInfo.processInfo.systemUptime },
                              send: { frame in try await transport.send(frame) })
    }

    func hello(auth: HelloAuth, app: AppInfo, device: DeviceInfo) async throws -> HelloResponse {
        guard readerTask == nil else { throw Failure.wrongReply }
        readerTask = Task { [weak self] in guard let self else { return }; await self.readLoop() }
        writerTask = Task { [weak self, writer] in
            do { try await writer.run() } catch { await self?.close(error: error) }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                await self.checkIdle()
            }
        }
        let result = try await request("hello", Wire.hello(socket: channel, auth: auth, app: app, device: device,
                                                           depthCodecs: ["u16", "f32"], maxPreviewHz: 5))
        guard case .helloResponse(_, let response) = result else { throw Failure.wrongReply }
        if case .pairingToken = auth { try response.validate(socket: channel, sentPairingToken: true) }
        else { try response.validate(socket: channel, sentPairingToken: false) }
        maximumTextBytes = response.limits.maxTextBytes
        idleSeconds = Double(response.limits.idleTimeoutMs) / 1000
        // (the socket's own limit is fixed at creation; maximumTextBytes is enforced per message in readLoop)
        try await outbox.markHandshakeComplete(maximumTextBytes: maximumTextBytes)
        await writer.poke()
        return response
    }

    func request(_ type: String, _ body: JSONValue) async throws -> IncomingMessage {
        guard !closed else { throw Failure.disconnected }
        let ticket = try await outbox.enqueue(type: type, kind: "request", body: body)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if closed { continuation.resume(throwing: Failure.disconnected); return }
                if let (replyType, value) = earlyReplies.removeValue(forKey: ticket) {
                    resolve(continuation, expected: type, actual: replyType, value: value); return
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    await self?.expire(ticket)
                }
                waiters[ticket] = Waiter(type: type, continuation: continuation, timer: timer)
                Task { await writer.poke() }
            }
        } onCancel: { Task { await self.expire(ticket) } }
    }

    func event(_ type: String, _ body: JSONValue) async throws {
        guard !closed else { throw Failure.disconnected }
        try await outbox.enqueue(type: type, kind: "event", body: body); await writer.poke()
    }

    func respond(_ type: String, replyTo: String, body: JSONValue) async throws {
        guard !closed else { throw Failure.disconnected }
        try await outbox.enqueue(type: type, kind: "response", body: body, replyTo: replyTo); await writer.poke()
    }

    func respondError(_ type: String, replyTo: String, code: String, message: String) async throws {
        guard !closed else { throw Failure.disconnected }
        try await outbox.enqueueErrorResponse(type: type, replyTo: replyTo, code: code, message: message, retryable: false)
        await writer.poke()
    }

    func binarySource(_ source: SocketWriter.BinarySource?, done: SocketWriter.BinaryDone?) async {
        await writer.setBinarySource(source, done: done)
    }
    func poke() async { await writer.poke() }
    var isClosed: Bool { closed }

    func close(error: Error = Failure.disconnected) async {
        guard !closed else { return }
        closed = true; socket.close(); readerTask?.cancel(); writerTask?.cancel(); watchdogTask?.cancel()
        let pending = waiters; waiters = [:]; earlyReplies = [:]
        for value in pending.values { value.timer.cancel(); value.continuation.resume(throwing: error) }
        _ = await outbox.drainUnsent()
    }

    private func expire(_ ticket: UUID) async {
        // A timed-out request may have reached the PC. Tear down instead of reusing this connection
        // with an ambiguous outcome; immutable manifests and resume reconcile on the next one.
        guard waiters[ticket] != nil else { return }
        await close(error: Failure.timeout)
    }

    private func checkIdle() async {
        if !closed, ProcessInfo.processInfo.systemUptime - lastReceived > idleSeconds { await close(error: Failure.timeout) }
    }

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await socket.receive()
                let received = ProcessInfo.processInfo.systemUptime
                lastReceived = received
                guard data.count <= maximumTextBytes,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["id"] as? String, isValidPCMessageID(id),
                      let sequence = UInt64(id.dropFirst(3)), sequence > lastPCSequence else {
                    throw StreamError.invalid("PC message order or size")
                }
                lastPCSequence = sequence
                let message = try IncomingMessage.decode(data, maximumBytes: maximumTextBytes)
                if case .ping(let id, let ticks) = message {
                    try await outbox.enqueuePong(replyTo: id, pcTransmit: ticks, deviceReceived: received)
                    await writer.poke(); continue
                }
                if let response = Self.reply(message) {
                    guard let ticket = await outbox.ticket(forReplyTo: response.id) else { throw Failure.wrongReply }
                    if let waiter = waiters.removeValue(forKey: ticket) {
                        waiter.timer.cancel(); resolve(waiter.continuation, expected: waiter.type, actual: response.type, value: message)
                    } else {
                        guard earlyReplies.count < 64 else { throw StreamError.sizeLimit }
                        earlyReplies[ticket] = (response.type, message)
                    }
                } else if case .unknownRequest(let type, let id) = message {
                    try await outbox.enqueueErrorResponse(type: type, replyTo: id, code: "unknown_type",
                                                         message: "Unsupported request \(type)", retryable: false)
                    await writer.poke()
                } else { try await onEvent(message) }
            }
        } catch { await close(error: error) }
    }

    private func resolve(_ continuation: CheckedContinuation<IncomingMessage, Error>, expected: String,
                         actual: String, value: IncomingMessage) {
        if case .errorResponse(_, _, let error) = value {
            continuation.resume(throwing: Failure.rejected(code: error.code, message: error.message))
        }
        else if expected != actual { continuation.resume(throwing: Failure.wrongReply) }
        else { continuation.resume(returning: value) }
    }

    private static func reply(_ value: IncomingMessage) -> (id: String, type: String)? {
        switch value {
        case .helloResponse(let id, _): return (id, "hello")
        case .sessionStartResponse(let id, _): return (id, "session.start")
        case .sessionStopResponse(let id, _): return (id, "session.stop")
        case .resumeResponse(let id, _): return (id, "originals.resume")
        case .manifestResponse(let id, _): return (id, "originals.manifest")
        case .offerResponse(let id, _): return (id, "originals.offer")
        case .errorResponse(let type, let id, _): return (id, type)
        case .unknownResponse(let type, let id): return (id, type)
        default: return nil
        }
    }
}
