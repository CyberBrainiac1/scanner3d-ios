import Foundation
import XCTest
@testable import ScannerStreamingCore

private actor Signal {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { open = true; let pending = waiting; waiting = []; for item in pending { item.resume() } }
}
private actor Completions {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

final class WriterSwapTests: XCTestCase {
    func testReplacingSourceCannotRedirectCompletionOfAnOlderSend() async throws {
        let entered = expectation(description: "old binary send entered"), release = Signal(), completions = Completions()
        let outbox = try ControlOutbox()
        let writer = SocketWriter(outbox: outbox, clock: { 10 }, send: { _ in entered.fulfill(); await release.wait() })
        await writer.setBinarySource({ _ in SocketWriter.BinaryItem(data: Data([1]), tag: 1) },
                                     done: { tag, _ in await completions.add("old-\(tag)") })
        let send = Task { try await writer.sendOne() }
        await fulfillment(of: [entered], timeout: 2)
        await writer.setBinarySource(nil, done: { tag, _ in await completions.add("new-\(tag)") })
        await release.release()
        _ = try await send.value
        let actual = await completions.values
        XCTAssertEqual(actual, ["old-1"])
    }
}
