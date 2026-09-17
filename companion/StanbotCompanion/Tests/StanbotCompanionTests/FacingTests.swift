import XCTest
@testable import StanbotCompanion

final class FacingTests: XCTestCase {
    func face(width: Double = 0.2, frame: Int? = 320, yaw: Double? = 0, pitch: Double? = 0) -> FaceBox {
        FaceBox(rect: CGRect(x: 0.4, y: 0.4, width: width, height: width), confidence: 0.9,
                pose: yaw.map { HeadPose(yaw: $0, pitch: pitch, roll: 0) }, frameWidth: frame)
    }

    func testHeadPointedAtTheCameraIsToward() {
        XCTAssertEqual(Facing.classify(face()), .toward)
        XCTAssertEqual(Facing.classify(face(yaw: 30, pitch: -25)), .toward)
        XCTAssertEqual(Facing.classify(face(yaw: -34, pitch: nil)), .toward, "no pitch: judged on yaw alone")
    }

    func testHeadTurnedAwayIsAway() {
        XCTAssertEqual(Facing.classify(face(yaw: 45)), .away)
        XCTAssertEqual(Facing.classify(face(yaw: -90)), .away)
        XCTAssertEqual(Facing.classify(face(yaw: 0, pitch: 40)), .away)
    }

    func testTooSmallOrNoPoseIsUnknownNotAway() {
        // 0.1 of a 320 px frame is 32 px: below the minimum, even turned away.
        XCTAssertEqual(Facing.classify(face(width: 0.1, yaw: 80)), .unknown)
        XCTAssertEqual(Facing.classify(face(width: 0.15)), .toward, "48 px is enough")
        XCTAssertEqual(Facing.classify(face(yaw: nil)), .unknown)
        XCTAssertEqual(Facing.classify(face(frame: nil)), .unknown)
        XCTAssertEqual(Facing.classify(face(yaw: .nan)), .unknown)
    }

    func testSelectionKeepsThePose() {
        var selection = FaceSelection()
        for t in [0.0, 0.2, 0.4] { selection.update([face(yaw: 50)], at: t) }
        XCTAssertEqual(selection.box?.pose?.yaw, 50)
        XCTAssertEqual(selection.box.map(Facing.classify), .away)
    }
}
