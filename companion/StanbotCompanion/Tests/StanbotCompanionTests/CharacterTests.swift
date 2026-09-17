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
        XCTAssertEqual(mood(follow: .finished(FollowResult(code: "preflight_refused"))).emotion, .trouble)
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

    /// STANBOT_SHADER_LIBRARY=/path/StanbotShaders.metallib renders the real
    /// eyes with and without the screen look and checks the LCD grid is there:
    /// neighbouring pixels across a lit iris differ with it, not without.
    /// Also writes both to $TMPDIR for a look. Skipped otherwise.
    @MainActor
    func testScreenLookDrawsTheLCDGrid() throws {
        guard ProcessInfo.processInfo.environment["STANBOT_SHADER_LIBRARY"] != nil else {
            throw XCTSkip("set STANBOT_SHADER_LIBRARY to a compiled StanbotShaders.metallib")
        }
        XCTAssertNotNil(StanbotShaders.library)
        func render(_ look: Bool) throws -> NSBitmapImageRep {
            let view = StanbotEyesView(emotion: .surprised, look: .zero, screenLook: look)
                .frame(width: 320, height: 240)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try rep.representation(using: .png, properties: [:])?
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-eyes-\(look).png"))
            return rep
        }
        // A horizontal run across the upper part of the left iris, clear of the pupil.
        // The subpixel stripes shift one channel at a time, so take the largest
        // spread of any channel.
        func spread(_ rep: NSBitmapImageRep) -> Double {
            let colors = (60..<100).compactMap { rep.colorAt(x: $0, y: 80) }
            return [\NSColor.redComponent, \NSColor.greenComponent, \NSColor.blueComponent].map { channel in
                let values = colors.map { $0[keyPath: channel] }
                return (values.max() ?? 0) - (values.min() ?? 0)
            }.max() ?? 0
        }
        let plain = spread(try render(false)), lcd = spread(try render(true))
        XCTAssertLessThan(plain, 0.01, "a flat iris without the shader")
        XCTAssertGreaterThan(lcd, 0.03, "the grid varies the iris with the shader (measured 0.05)")
    }

    func testEngagementNeedsAMomentOfFacingAndLetsGoGently() {
        func face(yaw: Double, width: Double = 0.2) -> FaceBox {
            FaceBox(rect: CGRect(x: 0.4, y: 0.4, width: width, height: width), confidence: 0.9,
                    pose: HeadPose(yaw: yaw, pitch: 0, roll: 0), frameWidth: 640)
        }
        var tracker = EngagementTracker()
        XCTAssertFalse(tracker.update(face(yaw: 5), at: 0))
        XCTAssertFalse(tracker.update(face(yaw: 5), at: 0.2), "a glance is not engagement")
        XCTAssertTrue(tracker.update(face(yaw: 5), at: 0.45))
        XCTAssertTrue(tracker.update(face(yaw: 60), at: 0.6), "a brief turn away does not break it")
        XCTAssertTrue(tracker.update(face(yaw: 5), at: 0.8))
        XCTAssertTrue(tracker.update(face(yaw: 0, width: 0.05), at: 2.0), "too small to judge: hold")
        XCTAssertTrue(tracker.update(face(yaw: 60), at: 2.1))
        XCTAssertFalse(tracker.update(face(yaw: 60), at: 2.95), "turned away for 0.8 s: let go")
        XCTAssertFalse(tracker.update(nil, at: 3.5))
        var lost = EngagementTracker()
        _ = lost.update(face(yaw: 0), at: 0); _ = lost.update(face(yaw: 0), at: 0.5)
        XCTAssertTrue(lost.engaged)
        _ = lost.update(nil, at: 0.6)
        XCTAssertFalse(lost.update(nil, at: 1.5), "no face for 0.8 s: let go")
    }

    func testGazePlannerMostlyLooksAwayFromSomeoneNotEngaging() {
        var planner = GazePlanner(seed: 42)
        let face = CGPoint(x: 0.3, y: -0.1)
        var peekTime = 0.0, total = 0.0, awaySide = 0, away = 0
        for _ in 0..<2000 {
            let fixation = planner.next(face: face)
            total += fixation.hold
            if fixation.isPeek {
                XCTAssertEqual(fixation.point, face)
                XCTAssertTrue((1.5...2.5).contains(fixation.hold), "an unhurried look, not a flick")
                peekTime += fixation.hold
            } else {
                away += 1
                if fixation.point.x < 0 { awaySide += 1 }
            }
        }
        XCTAssertLessThan(peekTime / total, 0.05, "looking at them rarely")
        XCTAssertGreaterThan(peekTime, 0)
        XCTAssertEqual(awaySide, away, "looks to the other side from where they are")
        var alone = GazePlanner(seed: 7)
        for _ in 0..<500 {
            let fixation = alone.next(face: nil)
            XCTAssertFalse(fixation.isPeek)
            XCTAssertGreaterThanOrEqual(abs(fixation.point.x), 0.15, "not resting dead centre")
            XCTAssertLessThanOrEqual(abs(fixation.point.x), 0.45, "a small drift, not across the screen")
            XCTAssertTrue((5...10).contains(fixation.hold), "held for seconds, not moving constantly")
        }
    }

    func testEngagedMoodLooksAtYouWithoutClaimingEyeContact() {
        let face = FaceBox(rect: CGRect(x: 0.4, y: 0.4, width: 0.25, height: 0.25), confidence: 0.9)
        let engaged = Mood.of(connection: .connected("x"), camera: .receiving, face: .tracking, box: face,
                              follow: .idle, engaged: true)
        XCTAssertTrue(engaged.engaged)
        XCTAssertEqual(engaged.caption, "Looking at you")
        XCTAssertEqual(engaged.closeness, 0.25, accuracy: 0.001)
        let noticed = Mood.of(connection: .connected("x"), camera: .receiving, face: .tracking, box: face, follow: .idle)
        XCTAssertFalse(noticed.engaged)
        XCTAssertNotNil(noticed.look, "knows where they are, to glance at them")
        XCTAssertFalse(Mood.of(connection: .connected("x"), camera: .receiving, face: .searching, box: nil,
                               follow: .idle, engaged: true).engaged, "no face, nothing to lock onto")
    }
}
