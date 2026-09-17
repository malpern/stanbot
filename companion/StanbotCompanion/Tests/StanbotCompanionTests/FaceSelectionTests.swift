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

    /// Head following, 2026-09-16: the head's own turn slides the face across
    /// the frame between frames. A face moving 0.15 of the frame per frame at
    /// 5 fps must stay selected, with one identity, the whole way.
    func testFaceMovingAcrossTheFrameStaysSelected() {
        var tracker = FaceSelection()
        var t = 0.0
        for _ in 0..<3 { tracker.update([face(0.05)], at: t); t += 0.2 }
        XCTAssertEqual(tracker.state, .tracking)
        let id = tracker.box?.id
        var x = 0.05
        for _ in 0..<5 {
            x += 0.15
            tracker.update([face(x)], at: t)
            XCTAssertEqual(tracker.state, .tracking, "lost at x = \(x)")
            XCTAssertEqual(tracker.box?.id, id)
            t += 0.2
        }
    }

    /// The wider gate must still not hand the selection to someone else: a
    /// second person clearly away from the selected face is not adopted.
    func testWiderGateDoesNotAdoptADistantPerson() {
        var tracker = FaceSelection()
        for t in [0.0, 0.2, 0.4] { tracker.update([face(0.1)], at: t) }
        let id = tracker.box?.id
        tracker.update([face(0.45)], at: 0.6)     // 0.35 away, gate is 0.24
        XCTAssertNil(tracker.box)
        tracker.update([face(0.1), face(0.45)], at: 0.8)
        XCTAssertEqual(tracker.box?.id, id)
        XCTAssertLessThan(tracker.box!.rect.minX, 0.2)
    }

    /// Two faces both inside the gate and about equally near stay ambiguous.
    func testTwoNearbyFacesStayAmbiguous() {
        var tracker = FaceSelection()
        for t in [0.0, 0.2, 0.4] { tracker.update([face(0.3)], at: t) }
        tracker.update([face(0.2), face(0.4)], at: 0.6)
        XCTAssertEqual(tracker.state, .uncertain)
        XCTAssertNil(tracker.box)
    }

    /// Session 4: a face high in the frame, detected every frame at confidence
    /// 0.8, was reported as "no stable face" for 3.5 s because its box ran past
    /// the top edge. Such a detection is now clipped and used.
    func testFaceAtTheFrameEdgeIsClippedNotDiscarded() {
        var tracker = FaceSelection()
        // Centre y 0.88, height 0.28: the top quarter of the box is outside.
        let high = FaceBox(rect: CGRect(x: 0.7, y: 0.74, width: 0.2, height: 0.28), confidence: 0.8)
        for t in [0.0, 0.2, 0.4] { tracker.update([high], at: t) }
        XCTAssertEqual(tracker.state, .tracking)
        let box = try! XCTUnwrap(tracker.box)
        XCTAssertLessThanOrEqual(box.rect.maxY, 1.0, "clipped to the frame")
        XCTAssertGreaterThan(box.rect.height, 0.15, "most of the face is still there")
    }

    /// A sliver at the edge is not a face worth following.
    func testMostlyOutsideDetectionIsStillRejected() {
        var tracker = FaceSelection()
        let sliver = FaceBox(rect: CGRect(x: 0.4, y: 0.95, width: 0.2, height: 0.28), confidence: 0.9)
        tracker.update([sliver], at: 0)
        XCTAssertEqual(tracker.state, .searching)
        XCTAssertNil(tracker.box)
    }
    /// Two people crossing: the selected one moving right, a stranger moving
    /// left. At the crossing frame the stranger is nearer the last position,
    /// but the selected face is where it was heading, so it keeps the lock.
    func testCrossingFacesKeepTheOneThatWasMovingThatWay() {
        var tracker = FaceSelection()
        var t = 0.0
        for x in [0.1, 0.2, 0.3, 0.4] { tracker.update([face(x)], at: t); t += 0.2 }
        XCTAssertEqual(tracker.state, .tracking)
        let id = tracker.box?.id
        tracker.update([face(0.5), face(0.42)], at: t)
        XCTAssertEqual(tracker.state, .tracking)
        XCTAssertEqual(tracker.box?.id, id)
        XCTAssertGreaterThan(tracker.box!.rect.minX, 0.44, "stayed with the face heading right")
    }

    /// A much smaller face (someone further back) that happens to be nearer is
    /// not taken for the selected person.
    func testMuchSmallerNearbyFaceIsNotTheSelectedPerson() {
        var tracker = FaceSelection()
        for t in [0.0, 0.2, 0.4] { tracker.update([face(0.3)], at: t) }
        let id = tracker.box?.id
        let small = FaceBox(rect: CGRect(x: 0.385, y: 0.4, width: 0.07, height: 0.1), confidence: 0.9)
        tracker.update([face(0.36), small], at: 0.6)
        XCTAssertEqual(tracker.state, .tracking)
        XCTAssertEqual(tracker.box?.id, id)
        XCTAssertGreaterThan(tracker.box!.rect.width, 0.15)
    }

    /// Someone who steps out of view and comes back where they left is chosen
    /// again over a larger stranger elsewhere.
    func testReturningPersonIsPreferredOverALargerStranger() {
        var tracker = FaceSelection()
        for t in [0.0, 0.2, 0.4] { tracker.update([face(0.1)], at: t) }
        tracker.expire(at: 2.0)
        XCTAssertEqual(tracker.state, .searching)
        let stranger = FaceBox(rect: CGRect(x: 0.55, y: 0.2, width: 0.35, height: 0.45), confidence: 0.95)
        for t in [2.2, 2.4, 2.6] { tracker.update([stranger, face(0.12)], at: t) }
        XCTAssertEqual(tracker.state, .tracking)
        XCTAssertLessThan(tracker.box!.rect.minX, 0.3, "the returning person, not the larger stranger")
        // Long after, the memory is gone and the usual rule (largest) applies.
        var fresh = FaceSelection()
        for t in [0.0, 0.2, 0.4] { fresh.update([face(0.1)], at: t) }
        fresh.expire(at: 2.0)
        for t in [6.0, 6.2, 6.4] { fresh.update([stranger, face(0.12)], at: t) }
        XCTAssertGreaterThan(fresh.box!.rect.minX, 0.5)
    }
}
