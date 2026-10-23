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
    func testGuidanceTipAndClearDecode() throws {
        guard case .guidance(let shown) = try IncomingMessage.decode(Fixtures.data("examples/guidance.event.json")) else {
            return XCTFail("not a guidance event")
        }
        XCTAssertEqual(shown.tip?.text, "Next: lower the phone and scan the back-right underside.")
        XCTAssertEqual(shown.tip?.conditionKey, "scan_underside:3")
        XCTAssertEqual(shown.coverageScore, 0.62)
        guard case .guidance(let cleared) = try IncomingMessage.decode(Fixtures.data("examples/guidance.event--cleared.json")) else {
            return XCTFail("not a guidance event")
        }
        XCTAssertNil(cleared.tip)
    }
    func testInvalidGuidanceIsRejected() throws {
        for name in ["negative/guidance.event--sent-by-phone.json", "negative/guidance.event--score-above-1.json"] {
            let data = try Fixtures.data(name)
            XCTAssertThrowsError(try IncomingMessage.decode(data), name)
        }
    }
}
