import Foundation
import XCTest
@testable import ScannerStreamingCore

/// Fixture access that works under SwiftPM (`Bundle.module`) and in an Xcode test bundle that copies the
/// Fixtures folder as a folder reference.
enum Fixtures {
    private final class Marker {}

    static func url(_ name: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Marker.self)
        #endif
        let candidates = [bundle.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(name),
                          bundle.resourceURL?.appendingPathComponent(name)]
        for case let candidate? in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("Fixture \(name) is not in the test bundle")
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func json(_ name: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data(name)) }
}

final class CoreTests: XCTestCase {
    struct RGBInput: Decodable { let jpeg: Data; let intrinsics: Intrinsics }
    struct DepthInput: Decodable { let codec: UInt8; let bytes: Data; let intrinsics: Intrinsics; let scaleMetersPerUnit: Float }
    struct FrameInput: Decodable {
        let expectedFile: String; let sessionID: UUID; let segment: UInt32
        let frameID: UInt64; let previewSequence: UInt64; let deviceTime: Double; let sentTime: Double
        let cameraToWorld: [Float]; let trackingState: UInt8; let trackingReason: UInt8
        let source: Intrinsics; let scaling: UInt8; let rgb: RGBInput?; let depth: DepthInput?
        let confidence: Data?; let flags: UInt32
        func frame() -> PreviewFrame {
            PreviewFrame(sessionID: sessionID, segment: segment, frameID: frameID,
                         previewSequence: previewSequence, deviceTime: deviceTime, sentTime: sentTime,
                         cameraToWorld: cameraToWorld, trackingState: trackingState,
                         trackingReason: trackingReason, source: source, scaling: scaling,
                         rgb: rgb.map { RGBSection(jpeg: $0.jpeg, intrinsics: $0.intrinsics) },
                         depth: depth.map { DepthSection(codec: DepthSection.Codec(rawValue: $0.codec)!,
                                                       bytes: $0.bytes, intrinsics: $0.intrinsics,
                                                       scaleMetersPerUnit: $0.scaleMetersPerUnit) },
                         confidence: confidence, flags: flags)
        }
    }
    struct ChunkInput: Decodable {
        let sessionID: UUID; let fileID: UInt64; let index: UInt32; let chunkBytes: Int
        let payload: Data; let last: Bool; let expectedFile: String
    }
    struct Vectors: Decodable { let frames: [FrameInput]; let chunk: ChunkInput }

    func vectors() throws -> Vectors { try JSONDecoder().decode(Vectors.self, from: Fixtures.data("vectors.json")) }

    func testPreviewMatchesIndependentReferenceBytes() throws {
        for input in try vectors().frames {
            XCTAssertEqual(try PacketEncoder.preview(input.frame()), try Fixtures.data(input.expectedFile))
            // And the byte-identical copy of contracts/stream/reference/golden.
            XCTAssertEqual(try PacketEncoder.preview(input.frame()), try Fixtures.data("golden/" + input.expectedFile))
        }
    }

    func testChunkMatchesIndependentSHA256AndByteOrder() throws {
        let chunk = try vectors().chunk
        let encoded = try PacketEncoder.chunk(sessionID: chunk.sessionID, fileID: chunk.fileID, index: chunk.index,
                                              chunkBytes: chunk.chunkBytes, payload: chunk.payload, last: chunk.last)
        XCTAssertEqual(encoded, try Fixtures.data(chunk.expectedFile))
        XCTAssertEqual(encoded, try Fixtures.data("golden/chunk_v1_last.s3dc"))
    }

    func testGoldenJPEGIsTheVectorJPEG() throws {
        let jpeg = try XCTUnwrap(try vectors().frames.first?.rgb?.jpeg)
        XCTAssertEqual(jpeg, try Fixtures.data("golden/rgb_16x12.jpg"))
    }

    func testNegotiatedBoundsThrowRatherThanTrap() throws {
        let chunk = try vectors().chunk
        for maximum in [Int.min, -1, 0, 95, 96, 65536, 65536 + 95, Int.max] {
            XCTAssertThrowsError(try PacketEncoder.chunk(sessionID: chunk.sessionID, fileID: chunk.fileID,
                                                         index: chunk.index, chunkBytes: chunk.chunkBytes,
                                                         payload: chunk.payload, last: true, maximumBytes: maximum))
        }
        XCTAssertThrowsError(try PacketEncoder.preview(try vectors().frames[0].frame(), maximumBytes: Int.min))
        XCTAssertThrowsError(try PacketEncoder.chunk(sessionID: chunk.sessionID, fileID: chunk.fileID,
                                                     index: 0, chunkBytes: Int.max, payload: Data([1]), last: true))
    }

    func testNegotiatedChunkSizesUpTo8MiB() throws {
        let session = try vectors().chunk.sessionID
        // 4 MiB chunks need max_binary_bytes >= 4 MiB + 96 (contract), not the 4 MiB default.
        XCTAssertNoThrow(try PacketEncoder.chunk(sessionID: session, fileID: 1, index: 0, chunkBytes: 4 << 20,
                                                 payload: Data([1]), last: true, maximumBytes: (4 << 20) + 96))
        XCTAssertThrowsError(try PacketEncoder.chunk(sessionID: session, fileID: 1, index: 0, chunkBytes: 4 << 20,
                                                     payload: Data([1]), last: true, maximumBytes: (4 << 20) + 95))
        XCTAssertNoThrow(try PacketEncoder.chunk(sessionID: session, fileID: 1, index: 0, chunkBytes: 8 << 20,
                                                 payload: Data(), last: true, maximumBytes: 16 << 20))
        XCTAssertThrowsError(try PacketEncoder.chunk(sessionID: session, fileID: 1, index: 0,
                                                     chunkBytes: (8 << 20) + 65536, payload: Data(), last: true,
                                                     maximumBytes: 16 << 20))
        var transfer = try OriginalTransfer(sessionID: session, fileID: 1, fileBytes: 10 << 20,
                                            fileSHA256: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try transfer.acceptOffer(chunkBytes: 8 << 20, maximumBinaryBytes: 8 << 20))
        XCTAssertNoThrow(try transfer.acceptOffer(chunkBytes: 8 << 20, maximumBinaryBytes: 16 << 20))
        XCTAssertEqual(transfer.chunksTotal, 2)
    }

    func testDepthInvalidValuesAndDefaultRounding() throws {
        XCTAssertEqual(try DepthSection.quantize([0, -1, .nan, .infinity, 0.001, 0.25, 100]),
                       Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 250, 0, 0, 0]))
        XCTAssertThrowsError(try DepthSection.quantize([1], scale: 0))
    }

    func testSendTimestampIsAppliedAfterQueueing() throws {
        let original = try PacketEncoder.preview(try vectors().frames[0].frame())
        let now = 48214.0
        let stamped = try PacketEncoder.stampingSendTime(original, now: now)
        XCTAssertEqual(stamped.count, original.count)
        XCTAssertEqual(stamped.prefix(56), original.prefix(56))
        XCTAssertEqual(stamped.suffix(from: 64), original.suffix(from: 64))
        var expected = Data(); expected.appendLE(now.bitPattern)
        XCTAssertEqual(stamped.subdata(in: 56..<64), expected)
        XCTAssertThrowsError(try PacketEncoder.stampingSendTime(original, now: 0))
    }

    func testExactQPCStringAndDeviceClockOrder() throws {
        let ticks = try QPCTicks("9072000000000000")
        XCTAssertEqual(ticks.value, 9072000000000000)
        let reply = try ClockReply(pcTransmit: ticks, deviceReceived: 120.125, deviceSent: 120.126)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        XCTAssertEqual(object["t_pc_tx_qpc_ticks"] as? String, ticks.wire)
        for bad in ["01", "-1", "+1", "1.0", "9223372036854775808"] { XCTAssertThrowsError(try QPCTicks(bad)) }
        XCTAssertThrowsError(try ClockReply(pcTransmit: ticks, deviceReceived: .nan, deviceSent: 2))
        XCTAssertThrowsError(try ClockReply(pcTransmit: ticks, deviceReceived: 2, deviceSent: 1))
    }

    func testControlIDsFollowWriterOrderUnderConcurrentProducers() async throws {
        let outbox = try ControlOutbox(capacity: 128)
        try await outbox.markHandshakeComplete(maximumTextBytes: 1_048_576)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask { _ = try await outbox.enqueue(type: "status", kind: "event", body: .object(["test": .integer(Int64(index))])) }
            }
            try await group.waitForAll()
        }
        for index in 1...64 {
            let pending = try await outbox.take(now: Double(index))
            let next = try XCTUnwrap(pending)
            XCTAssertEqual(next.id, "ph-\(index)")
            let concurrentTake = try await outbox.take(now: Double(index)); XCTAssertNil(concurrentTake)
            try await outbox.sent(lease: next.lease)
        }
    }

    func testHelloIsFirstAndPongJumpsTheQueueWithSendTimeStamp() async throws {
        let outbox = try ControlOutbox()
        try await outbox.enqueue(type: "status", kind: "event", body: .object([:]))
        try await outbox.enqueue(type: "hello", kind: "request", body: .object([:]))
        let first = try await outbox.take(now: 1)
        let hello = try XCTUnwrap(first)
        XCTAssertEqual(hello.draft.type, "hello"); XCTAssertEqual(hello.id, "ph-1")
        try await outbox.sent(lease: hello.lease)
        let gated = try await outbox.take(now: 2); XCTAssertNil(gated) // status waits for the hello response
        try await outbox.markHandshakeComplete(maximumTextBytes: 65536)
        try await outbox.enqueuePong(replyTo: "pc-88", pcTransmit: try QPCTicks("103680001234567"), deviceReceived: 10.25)
        let second = try await outbox.take(now: 10.5)
        let pong = try XCTUnwrap(second)
        XCTAssertEqual(pong.id, "ph-2")
        let object = try JSONDecoder().decode(JSONValue.self, from: pong.utf8)
        XCTAssertEqual(object["body"]?["t_device_tx_s"], .number(10.5))     // t3 = take time, not enqueue time
        XCTAssertEqual(object["body"]?["t_device_rx_s"], .number(10.25))
        XCTAssertEqual(object["body"]?["t_pc_tx_qpc_ticks"], .string("103680001234567"))
        XCTAssertEqual(object["reply_to"], .string("pc-88"))
        try await outbox.sent(lease: pong.lease)
        let third = try await outbox.take(now: 11)
        XCTAssertEqual(third?.draft.type, "status"); XCTAssertEqual(third?.id, "ph-3")
    }

    func testOldSendCompletionDoesNotFreeNewConnectionWriter() async throws {
        let outbox = try ControlOutbox()
        try await outbox.markHandshakeComplete(maximumTextBytes: 65536)
        _ = try await outbox.enqueue(type: "status", kind: "event", body: .object([:]))
        let oldPending = try await outbox.take(now: 0)
        let old = try XCTUnwrap(oldPending)
        let drained = await outbox.drainUnsent()
        XCTAssertEqual(drained.count, 1) // handed back, never silently dropped
        _ = try await outbox.enqueue(type: "status", kind: "event", body: .object([:]))
        let currentPending = try await outbox.take(now: 0)
        let current = try XCTUnwrap(currentPending)
        do { try await outbox.sent(lease: old.lease); XCTFail("Old socket completion was accepted") } catch { }
        let blocked = try await outbox.take(now: 0); XCTAssertNil(blocked)
        try await outbox.sent(lease: current.lease)
    }

    func testErrorResponseAndReplyIDLimits() async throws {
        let outbox = try ControlOutbox()
        try await outbox.markHandshakeComplete(maximumTextBytes: 65536)
        try await outbox.enqueueErrorResponse(type: "frobnicate", replyTo: "pc-7", code: "unknown_type",
                                              message: "Unknown request type", retryable: false)
        let pending = try await outbox.take(now: 0)
        let object = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(pending).utf8)
        XCTAssertEqual(object["ok"], .bool(false)); XCTAssertEqual(object["error"]?["code"], .string("unknown_type"))
        XCTAssertNil(object["body"])
        XCTAssertTrue(isValidPCMessageID("pc-999999999999999"))
        XCTAssertFalse(isValidPCMessageID("pc-1000000000000000"))
        XCTAssertFalse(isValidPCMessageID("ph-1"))
        do { _ = try await outbox.enqueue(type: "ping", kind: "response", body: .object([:]), replyTo: "pc-1234567890123456"); XCTFail() } catch { }
    }

    func testPairingReferenceCodeAndWrongPin() throws {
        XCTAssertEqual(try PairingIdentity.shortCode(token: "7Q4K9M2X",
            fingerprint: "4b2e7f1c9a0d38e6b5c4a39281f0e7d6c5b4a3928170f6e5d4c3b2a190807f6e"), "498D · 3104")
        XCTAssertEqual(try PairingIdentity.normalizedToken("o1iL2345"), "01112345")
        XCTAssertEqual(try PairingIdentity.normalizedToken(" 7q4k 9m2x "), "7Q4K9M2X")
        XCTAssertEqual(try PairingIdentity.normalizedToken("7Q4K-9M2X"), "7Q4K9M2X")
        XCTAssertThrowsError(try PairingIdentity.normalizedToken("7Q4K9M2U"))
        XCTAssertThrowsError(try PairingIdentity.normalizedToken("7Q4K9M2"))
        let certificate = Data("fixture-DER-only-not-a-certificate".utf8)
        XCTAssertTrue(try PairingIdentity.matchesPin(leafCertificateDER: certificate,
                                                     expectedFingerprint: PairingIdentity.fingerprint(leafCertificateDER: certificate)))
        XCTAssertFalse(try PairingIdentity.matchesPin(leafCertificateDER: certificate,
                                                      expectedFingerprint: String(repeating: "0", count: 64)))
    }

    func testOriginalResumePinsChunkSizeAndCompleteIsAuthoritative() throws {
        var transfer = try OriginalTransfer(sessionID: try vectors().chunk.sessionID, fileID: 1,
                                            fileBytes: 150000, fileSHA256: String(repeating: "a", count: 64))
        try transfer.acceptOffer(chunkBytes: 65536)
        try transfer.acknowledge([DurableRange(first: 0, last: 0)])
        XCTAssertEqual(try transfer.nextMissingIndex(), 1)
        XCTAssertThrowsError(try transfer.acceptOffer(chunkBytes: 131072))
        XCTAssertThrowsError(try transfer.acknowledge([DurableRange(first: 3, last: 3)])) // outside the file
        // F1: a PC file_complete is authoritative even if earlier ACKs were lost (README ack example).
        try transfer.acknowledge([], complete: true)
        XCTAssertTrue(transfer.fileComplete); XCTAssertNil(try transfer.nextMissingIndex())
        let restored = try OriginalTransfer.restore(JSONEncoder().encode(transfer))
        XCTAssertEqual(restored.chunkBytes, 65536); XCTAssertNil(try restored.nextMissingIndex())
        transfer.restartAfterFileNack()
        XCTAssertEqual(transfer.chunkBytes, 65536); XCTAssertFalse(transfer.fileComplete)
        XCTAssertEqual(try transfer.nextMissingIndex(), 0)
    }

    func testIDRangeConversionIsChecked() throws {
        XCTAssertEqual(try IDRange(first: 3, count: 2).toDurable(total: 5), DurableRange(first: 3, last: 4))
        XCTAssertThrowsError(try IDRange(first: 3, count: 3).toDurable(total: 5))
        XCTAssertThrowsError(try IDRange(first: 0, count: 0).toDurable(total: 5))
        XCTAssertNil(IDRange(first: UInt64.max, count: 2).lastChecked)
        XCTAssertEqual(IDRange.from(DurableRange(first: 2, last: 9)), IDRange(first: 2, count: 8))
    }

    func testPreviewQueueIsBoundedAndSendCompletionIsNotAck() async throws {
        let queue = PreviewWindow(now: 10)
        for sequence in UInt64(0)...5 { try await queue.offer(.init(sequence: sequence, bytes: Data([1]))) }
        let before = await queue.counts(); XCTAssertEqual(before.pending, 2); XCTAssertEqual(before.droppedQueue, 4)
        let first = try await queue.take(now: 10.1); XCTAssertEqual(first?.sequence, 4)
        let whileSending = try await queue.take(now: 10.1); XCTAssertNil(whileSending)
        try await queue.sendCompleted(sequence: 4)
        let after = await queue.counts(); XCTAssertEqual(after.inFlight, 1)
        let second = try await queue.take(now: 10.2); XCTAssertEqual(second?.sequence, 5)
        try await queue.sendCompleted(sequence: 5)
        let windowFull = try await queue.take(now: 10.3); XCTAssertNil(windowFull)
        let fullState = await queue.state(); XCTAssertEqual(fullState, .windowFull)
        try await queue.acknowledge(sequence: 4, now: 10.4)
        try await queue.offer(.init(sequence: 6, bytes: Data([1])))
        let timeout = try await queue.take(now: 13); XCTAssertNil(timeout) // Recording unaffected.
        let timedOut = await queue.counts()
        XCTAssertEqual(timedOut.pending, 0); XCTAssertEqual(timedOut.droppedTimeout, 1); XCTAssertEqual(timedOut.state, .pausedNoAck)
        try await queue.resetConnection(now: 14)
        let reset = await queue.counts(); XCTAssertEqual(reset.inFlight, 0); XCTAssertEqual(reset.state, .idle)
    }

    func testPreviewWindowFollowsNegotiatedInflightAndFlowPause() async throws {
        let queue = PreviewWindow(now: 0, inflightMax: 1)
        try await queue.offer(.init(sequence: 0, bytes: Data([1])))
        try await queue.offer(.init(sequence: 1, bytes: Data([1])))
        let a = try await queue.take(now: 0.1); XCTAssertEqual(a?.sequence, 0)
        try await queue.sendCompleted(sequence: 0)
        let blocked = try await queue.take(now: 0.2); XCTAssertNil(blocked) // window of 1
        try await queue.configure(inflightMax: 2, enabled: true)
        let b = try await queue.take(now: 0.3); XCTAssertEqual(b?.sequence, 1)
        try await queue.sendCompleted(sequence: 1)
        try await queue.configure(inflightMax: 1, enabled: false)
        let paused = await queue.state(); XCTAssertEqual(paused, .pausedByPC)
        try await queue.offer(.init(sequence: 2, bytes: Data([1])))
        let none = try await queue.take(now: 0.4); XCTAssertNil(none)
        do { try await queue.configure(inflightMax: 5, enabled: true); XCTFail("inflight_max 5 accepted") } catch { }
    }

    func testIdlePreviewDoesNotTimeoutWithoutOutstandingPackets() async throws {
        let queue = PreviewWindow(now: 0)
        try await queue.offer(.init(sequence: 0, bytes: Data([1])))
        let first = try await queue.take(now: 100); XCTAssertEqual(first?.sequence, 0)
        try await queue.sendCompleted(sequence: 0)
        try await queue.acknowledge(sequence: 0, now: 100.1)
        try await queue.offer(.init(sequence: 1, bytes: Data([2])))
        let afterIdle = try await queue.take(now: 200); XCTAssertEqual(afterIdle?.sequence, 1)
    }

    func testAckCallbackCanArriveAfterLaterSenderClockSample() async throws {
        let queue = PreviewWindow(now: 100)
        try await queue.offer(.init(sequence: 0, bytes: Data([1])))
        _ = try await queue.take(now: 100)
        try await queue.sendCompleted(sequence: 0)
        _ = try await queue.take(now: 100.2)
        try await queue.acknowledge(sequence: 0, now: 100.1)
        let final = await queue.counts(); XCTAssertEqual(final.inFlight, 0)
        let unknown = try await queue.acknowledge(sequence: 99, now: 101); XCTAssertFalse(unknown)
    }
}
