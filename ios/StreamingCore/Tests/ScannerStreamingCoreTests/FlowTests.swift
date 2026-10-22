import XCTest
@testable import ScannerStreamingCore

final class FlowTests: XCTestCase {
    func testZeroRatesAreValidPauseInstructions() throws {
        let flow = FlowEvent(preview: .init(enabled: true, targetHz: 0, inflightMax: 1, reason: nil),
                             originals: .init(enabled: true, maxBytesPerS: 0, windowChunks: 1, reason: nil))
        XCTAssertNoThrow(try flow.validate())
    }
    func testImpossibleWindowsAndRatesAreRejected() {
        for rate in [-1.0, 31, .infinity] {
            let flow = FlowEvent(preview: .init(enabled: true, targetHz: rate, inflightMax: 1, reason: nil),
                                 originals: .init(enabled: true, maxBytesPerS: nil, windowChunks: 1, reason: nil))
            XCTAssertThrowsError(try flow.validate())
        }
        let flow = FlowEvent(preview: .init(enabled: true, targetHz: 5, inflightMax: 1, reason: nil),
                             originals: .init(enabled: true, maxBytesPerS: -1, windowChunks: 65, reason: nil))
        XCTAssertThrowsError(try flow.validate())
    }
}
