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

    /// The regression this file exists for. At 0.93 frames per second, measured
    /// from the real app on 2026-09-15, the old fixed 0.9 s loss window erased
    /// progress before a second hit could land, so acquisition never completed
    /// and it read as "no face" with a face plainly in view.
    func testSlowStreamStillLocksOn() {
        var tracker = FaceSelection()
        var t = 0.0
        for _ in 0..<6 {
            tracker.update([face()], at: t)
            // The app ages the selection on a 20 Hz timer between frames.
            var tick = t
            while tick < t + 1.07 { tick += 0.05; tracker.expire(at: tick) }
            t += 1.07
        }
        XCTAssertEqual(tracker.state, .tracking)
        XCTAssertNotNil(tracker.box)
    }

    /// A single frame where the face is missed must cost one frame of progress,
    /// not all of it.
    func testOneMissedFrameDoesNotRestartAcquisition() {
        var tracker = FaceSelection()
        tracker.update([face()], at: 0)
        tracker.update([], at: 0.28)          // blink, blur, a bad frame
        XCTAssertEqual(tracker.state, .acquiring)
        tracker.update([face()], at: 0.56)
        tracker.update([face()], at: 0.84)
        XCTAssertEqual(tracker.state, .tracking)
    }

    /// Ambiguity is still not permission to switch, and is still distinct from
    /// a miss: two faces overlapping an unconfirmed candidate start over.
    func testAmbiguityDuringAcquisitionStartsOver() {
        var tracker = FaceSelection()
        tracker.update([face()], at: 0)
        tracker.update([face(0.09), face(0.11)], at: 0.28)
        XCTAssertEqual(tracker.state, .searching)
        XCTAssertNil(tracker.box)
    }

    /// Tolerance scales with the stream, so a fast stream is not made sluggish.
    func testFastStreamStillGivesUpPromptly() {
        var tracker = FaceSelection()
        for t in [0.0, 0.28, 0.56] { tracker.update([face()], at: t) }
        XCTAssertEqual(tracker.state, .tracking)
        tracker.expire(at: 1.5)               // about three frames missed
        XCTAssertEqual(tracker.state, .searching)
    }
}
