import XCTest
@testable import StanbotCompanion

final class CouldNotFindTests: XCTestCase {
    private func mood(couldNotFind: Bool, face: FaceSelection.State = .searching,
                      noFaceFor: TimeInterval = 0) -> Mood {
        Mood.of(connection: .connected("stanbot.local"), camera: .receiving, face: face,
                box: nil, follow: .idle, noFaceFor: noFaceFor, couldNotFind: couldNotFind)
    }

    /// Having looked everywhere and found nobody is a report, not idleness: it
    /// says so, and looks sad about it.
    func testItSaysSoAndLooksSad() {
        let looked = mood(couldNotFind: true)
        XCTAssertEqual(looked.caption, Mood.couldNotFindCaption)
        XCTAssertEqual(looked.emotion, .sad)
        XCTAssertEqual(mood(couldNotFind: false).caption, "Looking around")
    }

    /// It outranks getting drowsy: the robot has just done something and is
    /// reporting the result, which matters more than how long it has waited.
    func testItOutranksDrowsiness() {
        XCTAssertEqual(mood(couldNotFind: true, noFaceFor: Mood.drowsyAfter + 10).emotion, .sad)
        XCTAssertEqual(mood(couldNotFind: false, noFaceFor: Mood.drowsyAfter + 10).emotion, .sleepy)
    }

    /// Someone in view ends it at once, whatever the last session concluded.
    func testAFaceEndsIt() {
        XCTAssertNotEqual(mood(couldNotFind: true, face: .tracking).caption, Mood.couldNotFindCaption)
        XCTAssertNotEqual(mood(couldNotFind: true, face: .acquiring).caption, Mood.couldNotFindCaption)
    }
}
