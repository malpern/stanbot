import XCTest
@testable import StanbotCompanion

final class CharacterTests: XCTestCase {
    /// The Mac face and the robot's face are one character: every pose here
    /// must match poseFor in the firmware, value for value.
    func testEyePosesMatchTheFirmware() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("firmware/lib/StanbotEyes/src/StanbotEyes.h")
        let source = try String(contentsOf: header, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"case StanbotEmotion::(\w+): return \{([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)f?\};"#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertEqual(matches.count, Emotion.allCases.count)
        for match in matches {
            let field = { (i: Int) in String(source[Range(match.range(at: i), in: source)!]) }
            let emotion = try XCTUnwrap(Emotion(rawValue: field(1).lowercased()))
            let pose = EyePose.of(emotion)
            XCTAssertEqual(pose, EyePose(width: Double(field(2))!, height: Double(field(3))!,
                                         tilt: Double(field(4))!, pupilScale: Double(field(5))!), "\(emotion)")
        }
    }

    func testBlinkIsShortAndReturnsOpen() {
        XCTAssertEqual(StanbotEyesView.blink(at: 1.0), 0)
        XCTAssertEqual(StanbotEyesView.blink(at: 6.09), 1, accuracy: 0.01)
        XCTAssertEqual(StanbotEyesView.blink(at: 6.2), 0)
    }

    func testMoodFollowsWhatIsTrue() {
        let face = FaceBox(rect: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2), confidence: 0.9)
        func mood(_ connection: RobotConnection.ConnectionState = .connected("stanbot.local"),
                  camera: RobotConnection.CameraState = .receiving, face state: FaceSelection.State = .searching,
                  box: FaceBox? = nil, follow: FollowState = .idle) -> Mood {
            Mood.of(connection: connection, camera: camera, face: state, box: box, follow: follow)
        }
        XCTAssertTrue(mood(.disconnected).asleep)
        XCTAssertEqual(mood(.connecting).caption, "Waking up…")
        XCTAssertEqual(mood(camera: .off).emotion, .sleepy)
        XCTAssertEqual(mood().caption, "Looking around")
        let seen = mood(face: .tracking, box: face)
        XCTAssertEqual(seen.caption, "I see someone")
        XCTAssertTrue(seen.attending)
        XCTAssertEqual(seen.look!.x, 0.4, accuracy: 0.001, "eyes turn toward the face in the window")
        XCTAssertEqual(seen.look!.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(mood(face: .tracking, box: face, follow: .following(since: Date())).caption, "Following you")
        XCTAssertEqual(mood(follow: .following(since: Date())).caption, "Looking for you")
        XCTAssertEqual(mood(follow: .finished(FollowResult(code: "preflight_refused"))).emotion, .worried)
        XCTAssertEqual(mood(follow: .finished(FollowResult(code: "session_idle"))).caption, "Looking around",
                       "an ordinary end is not a worry")
    }

    /// Honesty: no caption claims eye contact or feelings.
    func testNoCaptionClaimsEyeContact() {
        let states: [(RobotConnection.ConnectionState, RobotConnection.CameraState, FaceSelection.State, FollowState)] = [
            (.connected("x"), .receiving, .tracking, .idle), (.connected("x"), .receiving, .tracking, .following(since: Date())),
            (.connected("x"), .receiving, .acquiring, .idle), (.connected("x"), .receiving, .uncertain, .idle),
        ]
        for (connection, camera, face, follow) in states {
            let caption = Mood.of(connection: connection, camera: camera, face: face, box: nil, follow: follow).caption.lowercased()
            for claim in ["eye contact", "looking at me", "love", "happy to"] {
                XCTAssertFalse(caption.contains(claim), caption)
            }
        }
    }
}
