import XCTest
@testable import StanbotCompanion

final class FaceSelectionTests: XCTestCase {
    func face(_ x: Double = 0.1, confidence: Float = 0.95) -> FaceBox {
        FaceBox(rect: CGRect(x: x, y: 0.3, width: 0.2, height: 0.3), confidence: confidence)
    }

    func testAcquisitionAndStableIdentity() {
        var tracker = FaceSelection()
        tracker.update([face()], at: 0)
        XCTAssertEqual(tracker.state, .acquiring)
        XCTAssertNil(tracker.box)
        tracker.update([face()], at: 0.28)
        XCTAssertNil(tracker.box)
        tracker.update([face()], at: 0.56)
        let id = tracker.box?.id
        XCTAssertNotNil(id)
        tracker.update([face(0.12), face(0.7)], at: 0.84)
        XCTAssertEqual(tracker.box?.id, id)
        XCTAssertGreaterThan(tracker.box!.rect.minX, 0.1)
        XCTAssertLessThan(tracker.box!.rect.minX, 0.12)
    }

    func testLossDoesNotJumpToOtherPerson() {
        var tracker = FaceSelection()
        for t in [0.0, 0.28, 0.56] { tracker.update([face()], at: t) }
        tracker.update([face(0.7)], at: 0.84)
        XCTAssertEqual(tracker.state, .uncertain)
        XCTAssertNil(tracker.box)
        tracker.update([face(0.7)], at: 1.12)
        XCTAssertEqual(tracker.state, .uncertain)
        tracker.expire(at: 1.5)
        XCTAssertEqual(tracker.state, .searching)
        tracker.update([face(0.7)], at: 1.6)
        XCTAssertEqual(tracker.state, .acquiring)
        XCTAssertNil(tracker.box)
    }

    func testBriefLossReacquiresSameSelection() {
        var tracker = FaceSelection()
        for t in [0.0, 0.28, 0.56] { tracker.update([face()], at: t) }
        let id = tracker.box?.id
        tracker.update([], at: 0.84)
        XCTAssertNil(tracker.box)
        tracker.update([face()], at: 1.12)
        XCTAssertEqual(tracker.box?.id, id)
    }

    func testConfidenceAmbiguityAndStall() {
        var tracker = FaceSelection()
        tracker.update([face(confidence: 0.6), face(confidence: .nan)], at: 0)
        XCTAssertEqual(tracker.state, .searching)
        for t in [0.1, 0.38, 0.66] { tracker.update([face()], at: t) }
        tracker.update([face(0.09), face(0.11)], at: 0.94)
        XCTAssertEqual(tracker.state, .uncertain)
        XCTAssertNil(tracker.box)
        tracker.expire(at: 1.6)
        XCTAssertEqual(tracker.state, .searching)
    }

    func testResetRequiresFreshConfirmation() {
        var tracker = FaceSelection()
        for t in [0.0, 0.28, 0.56] { tracker.update([face()], at: t) }
        tracker.reset()
        tracker.update([face()], at: 0.84)
        XCTAssertNil(tracker.box)
        XCTAssertEqual(tracker.state, .acquiring)
    }
}
