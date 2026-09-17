import SwiftUI
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

    func testReactionsAreShortAndWellFormed() {
        for kind in EyeReaction.Kind.allCases {
            let plan = EyeReaction(kind: kind).plan
            for track in [plan.openness, plan.dx, plan.dy, plan.scale, plan.durations] { XCTAssertEqual(track.count, 6, "\(kind)") }
            XCTAssertLessThanOrEqual(plan.total, 0.8, "\(kind) should be a moment, not a performance")
            XCTAssertEqual(plan.openness.last, 1, "\(kind) ends with eyes open")
            XCTAssertEqual(plan.dx.last, 0); XCTAssertEqual(plan.dy.last, 0); XCTAssertEqual(plan.scale.last, 1)
        }
    }

    func testReactionsFireForTheRightChanges() {
        let idle = ReactionFacts(connected: true, faceTracked: false, following: false, finishedCode: nil, firmwareCommit: "a")
        func after(_ change: (inout ReactionFacts) -> Void, from old: ReactionFacts = idle) -> EyeReaction.Kind? {
            var new = old; change(&new); return ReactionFacts.reaction(from: old, to: new)
        }
        var asleep = idle; asleep.connected = false
        XCTAssertEqual(after({ $0.connected = true }, from: asleep), .wake)
        XCTAssertEqual(after { $0.faceTracked = true }, .surprise)
        XCTAssertEqual(after { $0.finishedCode = "session_idle" }, .content)
        XCTAssertEqual(after { $0.finishedCode = "preflight_refused" }, .shake)
        XCTAssertEqual(after { $0.firmwareCommit = "b" }, .sparkle)
        var unknown = idle; unknown.firmwareCommit = nil
        XCTAssertNil(after({ $0.firmwareCommit = "b" }, from: unknown), "learning the commit on connect is not new firmware")
        XCTAssertNil(after { $0.following = true })
        XCTAssertNil(ReactionFacts.reaction(from: idle, to: idle))
    }

    func testWakingScansAndIdleGetsDrowsy() {
        let waking = Mood.of(connection: .connecting, camera: .off, face: .searching, box: nil, follow: .idle)
        XCTAssertTrue(waking.scanning)
        XCTAssertFalse(waking.asleep)
        let look = { (seconds: TimeInterval) in
            Mood.of(connection: .connected("x"), camera: .receiving, face: .searching, box: nil, follow: .idle, noFaceFor: seconds)
        }
        XCTAssertEqual(look(10).caption, "Looking around")
        XCTAssertEqual(look(Mood.drowsyAfter).caption, "Getting sleepy…")
        XCTAssertFalse(look(600).asleep, "drowsy, not asleep: the camera is still on")
        XCTAssertEqual(Mood.of(connection: .connected("x"), camera: .waiting, face: .searching, box: nil, follow: .idle).emotion, .squint)
    }

    /// STANBOT_ICON_SHEET=/path.png writes every expression icon to one image,
    /// to look at them. Skipped otherwise.
    @MainActor
    func testWriteExpressionIconSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["STANBOT_ICON_SHEET"] else { throw XCTSkip("set STANBOT_ICON_SHEET to write the sheet") }
        let sheet = HStack(spacing: 8) {
            ForEach(Emotion.allCases) { emotion in
                VStack(spacing: 2) {
                    Image(nsImage: ExpressionIcon.image(for: emotion)).resizable().frame(width: 48, height: 36)
                    Text(emotion.title).font(.system(size: 9))
                }
            }
        }.padding(8).background(.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        try XCTUnwrap(rep?.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
