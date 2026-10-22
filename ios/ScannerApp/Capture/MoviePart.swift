import Foundation
import AVFoundation
import CoreVideo

/// Derived from the MIT Stray Scanner VideoEncoder pattern (see THIRD-PARTY.md), with explicit device
/// timestamps, bounded backpressure and a completion barrier before making a video uploadable.
final class MoviePart {
    let segment: UInt32
    let path: String
    let openedAt: Double
    private let store: OriginalStore
    private let temporary: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var index: UInt64 = 0
    private var lastTime: Double = -1
    private var finished = false

    init(store: OriginalStore, segment: UInt32, part: Int, width: Int, height: Int, time: Double) throws {
        self.store = store; self.segment = segment; openedAt = time
        path = String(format: "video/seg%06u-part%03d.mov", segment, part)
        temporary = try store.temporaryURL(extension: "mov")
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = 1_000_000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw OriginalStore.Failure.io("HEVC input unsupported") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? OriginalStore.Failure.io("Video start") }
        writer.startSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 1_000_000))
    }

    /// nil means bounded backpressure: the caller logs the drop and must NOT write a CSV row referring
    /// to an unappended video frame. There is no busy wait or unbounded pixel-buffer retention.
    func append(_ buffer: CVPixelBuffer, time: Double) throws -> UInt64? {
        guard !finished, time.isFinite, time >= openedAt, time > lastTime else {
            throw OriginalStore.Failure.io("Invalid video timestamp/state")
        }
        guard writer.status == .writing else { throw writer.error ?? OriginalStore.Failure.io("Video not writing") }
        guard input.isReadyForMoreMediaData else { return nil }
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 1_000_000)) else {
            throw writer.error ?? OriginalStore.Failure.io("Video append")
        }
        lastTime = time
        defer { index += 1 }
        return index
    }

    /// Called only on capture's utility queue, never the main/delegate callback queue. The completion
    /// barrier is bounded; an unfinished file remains pending and cannot be advertised as complete.
    func close() throws {
        guard !finished else { return }
        finished = true
        input.markAsFinished()
        let barrier = DispatchSemaphore(value: 0)
        writer.finishWriting { barrier.signal() }
        guard barrier.wait(timeout: .now() + 15) == .success else {
            writer.cancelWriting()
            throw OriginalStore.Failure.io("Video close timed out; pending file retained")
        }
        guard writer.status == .completed else { throw writer.error ?? OriginalStore.Failure.io("Video close") }
        try store.seal(temporary, path: path, kind: "video", segment: segment)
    }
}
