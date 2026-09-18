import XCTest
@testable import StanbotCompanion

/// The two faces must describe the same face.
///
/// `companion/face-geometry.json` is the ROBOT's answer, generated from its own
/// `StanbotEyes::geometry()` and committed (see companion/test_face_geometry.py).
/// This checks the Mac against it, state by state.
///
/// Semantic, not pixels: where each thing is, how big, and what kind. Nothing
/// here is about glow, bokeh, shadows, springs or anti-aliasing -- those are
/// fidelity, they are supposed to differ, and a test that compared them would
/// cry wolf on every frame.
///
///     State and shape may not differ. Fidelity may.
final class FaceGeometryTests: XCTestCase {
    private struct Contract: Decodable {
        struct Screen: Decodable { let width: Int; let height: Int }
        struct State: Decodable {
            /// How far open the lids are, and an INPUT: the robot was asked for
            /// this and reported what it drew, so the Mac is asked for exactly
            /// the same thing rather than guessing at it.
            let lids: Double
            let eyeKind: String
            let eyeWidth: Int
            let eyeHeight: Int
            let shut: Int
            let frownVisible: Bool
            let frownY: Int
            let frownRadius: Int
            let mouthVisible: Bool
            let mouthX: Int
            let mouthY: Int
        }
        let screen: Screen
        let eyeLeftX: Int
        let eyeRightX: Int
        let eyeY: Int
        let states: [String: State]
    }

    private func contract() throws -> Contract {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("face-geometry.json")
        return try JSONDecoder().decode(Contract.self, from: try Data(contentsOf: url))
    }

    /// The same states the robot reported, built the Mac's way, from the same
    /// inputs the robot was given.
    private func mac(_ name: String, lids: Double) -> FaceGeometry? {
        let emotion: Emotion
        switch name {
        case "normal", "half_closed", "nearly_shut", "closed", "speaking": emotion = .normal
        case "happy": emotion = .happy
        case "sad": emotion = .sad
        case "focused": emotion = .focused
        case "sleepy": emotion = .sleepy
        case "surprised": emotion = .surprised
        case "squint": emotion = .squint
        case "trouble", "trouble_closed": emotion = .trouble
        default: return nil
        }
        return .of(emotion: emotion, openness: lids, speaking: name == "speaking")
    }

    func testTheMacsFaceMatchesTheRobots() throws {
        let robot = try contract()

        // The panel itself, before anything is drawn on it.
        XCTAssertEqual(Int(FaceGeometry.screenWidth), robot.screen.width)
        XCTAssertEqual(Int(FaceGeometry.screenHeight), robot.screen.height)
        XCTAssertEqual(Int(FaceGeometry.eyeLeftX), robot.eyeLeftX)
        XCTAssertEqual(Int(FaceGeometry.eyeRightX), robot.eyeRightX)
        XCTAssertEqual(Int(FaceGeometry.eyeY), robot.eyeY)

        var unchecked: [String] = []
        for (name, theirs) in robot.states.sorted(by: { $0.key < $1.key }) {
            guard let ours = mac(name, lids: theirs.lids) else { unchecked.append(name); continue }
            XCTAssertEqual(ours.shut, theirs.shut, "\(name): how far shut")
            XCTAssertEqual(ours.eyeKind.rawValue, theirs.eyeKind, "\(name): eye kind")
            XCTAssertEqual(ours.eyeWidth, theirs.eyeWidth, "\(name): eye width")
            XCTAssertEqual(ours.eyeHeight, theirs.eyeHeight, "\(name): eye height")
            XCTAssertEqual(ours.frownVisible, theirs.frownVisible, "\(name): frown shown")
            XCTAssertEqual(ours.frownY, theirs.frownY, "\(name): frown height")
            XCTAssertEqual(ours.frownRadius, theirs.frownRadius, "\(name): frown size")
            XCTAssertEqual(ours.mouthVisible, theirs.mouthVisible, "\(name): mouth shown")
            XCTAssertEqual(ours.mouthX, theirs.mouthX, "\(name): mouth x")
            XCTAssertEqual(ours.mouthY, theirs.mouthY, "\(name): mouth y")
        }
        // A state the robot describes and the Mac has no answer for is a hole
        // in the contract, not something to pass over quietly.
        XCTAssertTrue(unchecked.isEmpty, "the Mac has no geometry for: \(unchecked)")
    }

    /// The lids come down the same way on both, all the way through the close
    /// -- not merely at the two ends. This is the shape of the transition, and
    /// it is where the two faces drifted apart before: the Mac curved while the
    /// robot flattened to a bar.
    func testTheEyesCloseTheSameWayThroughout() {
        var sawOpen = false, sawClosed = false
        var lastHeight = Int.max
        for step in stride(from: 1.0, through: 0.0, by: -0.02) {
            let face = FaceGeometry.of(emotion: .normal, openness: step)
            switch face.eyeKind {
            case .open:
                sawOpen = true
                XCTAssertLessThanOrEqual(face.eyeHeight, lastHeight, "an open eye grew while closing")
                lastHeight = face.eyeHeight
            case .closed:
                sawClosed = true
                XCTAssertEqual(face.eyeWidth, FaceGeometry.closedWidth)
            case .crossed:
                XCTFail("a normal eye must never be crossed")
            }
        }
        XCTAssertTrue(sawOpen && sawClosed, "the eye never became a lid")
        // And the switch happens near the end, not halfway: the curve is the
        // last of the close, so the eye melts into it.
        XCTAssertEqual(FaceGeometry.of(emotion: .normal, openness: 0.5).eyeKind, .open)
        XCTAssertEqual(FaceGeometry.of(emotion: .normal, openness: 0.1).eyeKind, .closed)
    }

    /// Being in trouble does not stop Stanbot sleeping, and it does not stop it
    /// being in trouble either.
    func testTroubleSleepsWithoutForgettingItIsInTrouble() {
        let awake = FaceGeometry.of(emotion: .trouble)
        XCTAssertEqual(awake.eyeKind, .crossed)
        XCTAssertTrue(awake.frownVisible)

        let asleep = FaceGeometry.of(emotion: .trouble, openness: 0)
        XCTAssertEqual(asleep.eyeKind, .closed, "the X's should give way to lids")
        XCTAssertTrue(asleep.frownVisible, "it is still in trouble")
    }
}
