import XCTest
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import StanbotCompanion

final class HeadFollowingTests: XCTestCase {
    // MARK: helpers

    private struct FakeUSB {
        let master: Int32, slave: Int32, path: String
        init() {
            var m: Int32 = -1, s: Int32 = -1
            var name = [CChar](repeating: 0, count: 128)
            precondition(openpty(&m, &s, &name, nil, nil) == 0)
            _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL, 0) | O_NONBLOCK)
            master = m; slave = s; path = String(cString: name)
        }
        func read() -> String {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let n = bytes.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            return n > 0 ? String(decoding: bytes[0..<n], as: UTF8.self) : ""
        }
        func write(_ data: Data) { _ = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) } }
        func line(_ text: String) { write(Data((text + "\n").utf8)) }
        func close() { Darwin.close(slave); Darwin.close(master) }
    }

    private func frame(_ sequence: UInt32) -> Data {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) } }
        return Data(Array("SBFR".utf8) + [1] + le(sequence) + le(UInt32(out.length))) + (out as Data)
    }

    private func version(measured: Bool) -> String {
        #"SBVR {"sketch":"camera_stream","commit":"0123456789ab","dirty":false,"built":"2026-09-16T22:00:00Z","protocol":1,"follow_limits_measured":\#(measured)}"#
    }

    @MainActor
    private func wait(upTo seconds: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// A robot on the fake USB port, streaming, with the given firmware.
    @MainActor
    private func connected(measured: Bool) -> (RobotConnection, FakeUSB) {
        let usb = FakeUSB()
        let robot = RobotConnection(port: usb.path, automaticPolling: false, transport: .usb,
                                    followLogDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-test-logs"))
        robot.enhancement = .off
        usb.line(version(measured: measured))
        for sequence in UInt32(1)...3 { usb.write(frame(sequence)) }
        wait(upTo: 3) { robot.cameraState == .receiving && robot.firmware != .asking }
        _ = usb.read()   // discard V and S
        return (robot, usb)
    }

    private let face = FaceBox(rect: CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3), confidence: 0.91)

    // MARK: tests

    func testTargetLineMapsVisionCoordinatesToTheRobotConvention() {
        // Centre (0.75, 0.25) in Vision space: right of centre, low in the image.
        XCTAssertEqual(FollowTarget.line(for: face, sequence: 7), "T,7,0.500,0.500,0.91\n")
        let topLeft = FaceBox(rect: CGRect(x: 0, y: 0.8, width: 0.2, height: 0.2), confidence: 1)
        XCTAssertEqual(FollowTarget.line(for: topLeft, sequence: 1), "T,1,-0.800,-0.800,1.00\n")
    }

    @MainActor
    func testNormalFirmwareCannotStartFollowing() {
        let (robot, usb) = connected(measured: false)
        defer { usb.close() }
        XCTAssertEqual(robot.cameraState, .receiving)
        XCTAssertTrue(robot.followUnavailableReason?.contains("calibration build") ?? false)
        robot.startFollowing()
        XCTAssertEqual(robot.follow, .idle)
        XCTAssertEqual(usb.read(), "", "no motion command for firmware that has following disabled")
    }

    @MainActor
    func testSessionStartsSendsTargetsStopsAndReportsTheRobotsResult() {
        let (robot, usb) = connected(measured: true)
        defer { usb.close() }
        XCTAssertNil(robot.followUnavailableReason)

        robot.sendFollowTarget(face, sequence: 7)
        XCTAssertEqual(usb.read(), "", "no targets outside a session")
        robot.sendGaze(face)
        XCTAssertEqual(usb.read(), "G,0.500,0.500\n", "the eyes still look outside a session")

        robot.startFollowing()
        guard case .following = robot.follow else { return XCTFail("not following") }
        XCTAssertEqual(usb.read(), "C,FOLLOW\n")

        // The sequence is the camera frame the face came from.
        robot.sendFollowTarget(face, sequence: 41)
        robot.sendFollowTarget(face, sequence: 42)
        robot.sendFollowTarget(face, sequence: 42)   // a repeat is not sent again
        XCTAssertEqual(usb.read(), "T,41,0.500,0.500,0.91\nT,42,0.500,0.500,0.91\n")
        robot.sendGaze(face)
        XCTAssertEqual(usb.read(), "", "during a session the targets drive the eyes")

        robot.stopFollowing()
        XCTAssertEqual(usb.read(), "C,UNFOLLOW\n")
        let log = try? String(contentsOf: XCTUnwrap(robot.followLogURL), encoding: .utf8)
        XCTAssertNotNil(log, "a session log is opened when following starts")
        XCTAssertTrue(robot.followLogURL?.path.hasPrefix(FileManager.default.temporaryDirectory.path) ?? false,
                      "tests never write into ~/Library/Logs")

        usb.line(#"SBTB {"telemetry":"begin","plan":"follow"}"#)
        usb.line(#"SBMV {"result":"stopped_by_host","plan":"follow","pitch_enabled":false,"observations":2,"rejected":0,"yaw_final":470,"pitch_final":630,"yaw_commanded":472,"pitch_commanded":630,"mode":1}"#)
        wait(upTo: 2) { if case .finished = robot.follow { return true }; return false }
        XCTAssertEqual(robot.follow, .finished(FollowResult(code: "stopped_by_host")))

        robot.sendFollowTarget(face, sequence: 7)
        XCTAssertEqual(usb.read(), "", "no targets after the session ended")
    }

    @MainActor
    func testOneSessionPerBootRefusalOffersReboot() {
        let (robot, usb) = connected(measured: true)
        defer { usb.close() }
        robot.startFollowing()
        _ = usb.read()
        usb.line(#"SBPW {"error":"requires_unused_boot"}"#)
        wait(upTo: 2) { if case .finished = robot.follow { return true }; return false }
        guard case .finished(let result) = robot.follow else { return XCTFail("no result") }
        XCTAssertTrue(result.needsReboot)
        robot.rebootRobot()
        XCTAssertEqual(usb.read(), "C,REBOOT\n")
        XCTAssertEqual(robot.follow, .idle)
    }

    /// The vector computed with Python's hmac module, shared with
    /// companion/test_command_auth.cpp, so app and firmware agree.
    func testAuthorizationMatchesTheSharedVector() {
        XCTAssertEqual(CommandAuthorization.mac(command: "FOLLOW", nonce: "00112233445566778899aabbccddeeff",
                                                passphrase: "correct horse battery staple"),
                       "ddefdb5a5ae93875b5911d6e3dd6bff073c70007431ff2d71f8b84b8ece41f76")
    }

    // MARK: automatic following

    private let now = Date()

    func testAutomaticFollowingStartsOnlyWhenEverythingIsReady() {
        func shouldStart(enabled: Bool = true, reason: String? = nil, state: FollowState = .idle,
                         face: Bool = true, lastEnded: Date? = nil) -> Bool {
            AutoFollow.shouldStart(enabled: enabled, unavailableReason: reason, state: state,
                                   faceTracked: face, lastEnded: lastEnded, now: now)
        }
        XCTAssertTrue(shouldStart())
        XCTAssertFalse(shouldStart(enabled: false), "the toggle is off")
        XCTAssertFalse(shouldStart(reason: "Connect to the robot first."), "following is unavailable")
        XCTAssertFalse(shouldStart(face: false), "no confirmed face")
        XCTAssertFalse(shouldStart(state: .following(since: now)), "a session is already running")
    }

    func testAutomaticFollowingRestartsAfterAGapButNotAfterARefusal() {
        func shouldStart(state: FollowState, lastEnded: Date?) -> Bool {
            AutoFollow.shouldStart(enabled: true, unavailableReason: nil, state: state,
                                   faceTracked: true, lastEnded: lastEnded, now: now)
        }
        let ended = FollowState.finished(FollowResult(code: "session_deadline"))
        XCTAssertFalse(shouldStart(state: ended, lastEnded: now.addingTimeInterval(-1)), "too soon after the last session")
        XCTAssertTrue(shouldStart(state: ended, lastEnded: now.addingTimeInterval(-AutoFollow.restartGap - 0.1)))
        XCTAssertTrue(shouldStart(state: .finished(FollowResult(code: "stopped_by_host")), lastEnded: nil))
        // Longer sessions end when nobody is there or at the maximum; both restart.
        for code in ["session_idle", "session_max_duration"] {
            XCTAssertTrue(shouldStart(state: .finished(FollowResult(code: code)), lastEnded: nil), "did not restart after \(code)")
            XCTAssertFalse(FollowResult(code: code).summary.hasPrefix("Ended early"), "\(code) has no summary")
        }
        // Refusals that would only repeat.
        for code in ["auth_bad_mac", "follow_refused_limits_unmeasured", "preflight_refused", "power_latched"] {
            XCTAssertFalse(shouldStart(state: .finished(FollowResult(code: code)), lastEnded: nil), "retried \(code)")
        }
    }

    @MainActor
    func testStopTurnsAutomaticFollowingOff() {
        let (robot, usb) = connected(measured: true)
        defer { usb.close() }
        robot.followAutomatically = true
        robot.startFollowing()
        _ = usb.read()
        robot.stopFollowing()
        XCTAssertFalse(robot.followAutomatically, "Stop means stop, not start again in four seconds")
    }
}
