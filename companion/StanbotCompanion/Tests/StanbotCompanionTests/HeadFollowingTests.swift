import XCTest
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import StanbotCompanion

final class FollowToggleTests: XCTestCase {
    /// Follow is one toggle: on means keep following whoever is there, off means
    /// stop now and stay stopped. There is no separate "automatically" switch.
    @MainActor
    func testTheToggleIsTheStandingIntent() {
        let robot = RobotConnection(port: nil, automaticPolling: false, transport: .usb,
                                    passphrase: { nil }, connectOnStart: false)
        robot.setFollowing(false)
        XCTAssertFalse(robot.followAutomatically)

        // Off, with no robot connected, turning it on is refused: nothing to follow with.
        XCTAssertNotNil(robot.followUnavailableReason)
        robot.setFollowing(true)
        XCTAssertFalse(robot.followAutomatically, "not available, so the toggle stays off")

        // The preference only decides where the toggle starts each launch.
        let key = RobotConnection.followAutomaticallyKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let fresh = RobotConnection(port: nil, automaticPolling: false, transport: .usb,
                                    passphrase: { nil }, connectOnStart: false)
        XCTAssertTrue(fresh.followAutomatically, "on at launch by default")
        fresh.setFollowing(false)
        XCTAssertFalse(fresh.followAutomatically)
        XCTAssertTrue(fresh.followAutomaticallyOnLaunch, "turning it off does not change the preference")
    }
}

final class SteeringSenseTests: XCTestCase {
    /// The pad and arrow keys steer as the owner sees the robot, facing it:
    /// their left is the robot's right, so x is reversed; up stays up.
    @MainActor
    func testSteeringAsSeenReversesLeftAndRightOnly() {
        let robot = RobotConnection(port: nil, automaticPolling: false, transport: .usb,
                                    passphrase: { nil }, connectOnStart: false)
        XCTAssertEqual(RobotConnection.asSeen(x: -1, y: 0.5).x, 1, "the owner's left is the robot's right")
        XCTAssertEqual(RobotConnection.asSeen(x: 0.25, y: 0.5).x, -0.25)
        XCTAssertEqual(RobotConnection.asSeen(x: -1, y: 0.5).y, 0.5, "up is up from either side")
        _ = robot
    }
}

final class SilentFailureTests: XCTestCase {
    /// A session that never reports back is retried once; twice running is a
    /// fault that stops the retrying and is said out loud.
    func testRepeatedSilenceStopsTheRetrying() {
        XCTAssertTrue(FollowResult(code: "no_result").retryable, "one lost line is not a fault")
        let repeated = FollowResult(code: "no_result_repeated")
        XCTAssertFalse(repeated.retryable, "automatic following must not retry into silence for hours")
        XCTAssertTrue(repeated.summary.contains("never reported back"))
        XCTAssertFalse(AutoFollow.shouldStart(enabled: true, unavailableReason: nil, state: .finished(repeated),
                                              faceTracked: true, lastEnded: nil, now: Date()))
    }

    func testAnUnreachableBaseIsAFaultWithAnInstruction() {
        let result = FollowResult(code: "base_unreachable")
        XCTAssertFalse(result.retryable)
        XCTAssertTrue(result.summary.contains("Reboot"))
    }
}

final class WakeScanTests: XCTestCase {
    /// Just after a wake a session starts with nobody in view, so the robot can
    /// look around; otherwise a session still needs a face.
    func testASessionStartsWithoutAFaceOnlyJustAfterAWake() {
        let now = Date()
        func start(faceTracked: Bool, wokeAt: Date?, lastEnded: Date? = nil, enabled: Bool = true,
                   reason: String? = nil) -> Bool {
            AutoFollow.shouldStart(enabled: enabled, unavailableReason: reason, state: .idle,
                                   faceTracked: faceTracked, lastEnded: lastEnded, now: now, wokeAt: wokeAt)
        }
        XCTAssertFalse(start(faceTracked: false, wokeAt: nil), "no face, no wake: nothing to do")
        XCTAssertTrue(start(faceTracked: false, wokeAt: now.addingTimeInterval(-2)), "just woken: look around")
        XCTAssertFalse(start(faceTracked: false, wokeAt: now.addingTimeInterval(-AutoFollow.wakeScanWindow - 1)),
                       "the wake was a while ago")
        XCTAssertTrue(start(faceTracked: true, wokeAt: nil), "a face still starts one")
        // The wake's session is not held back by the gap after the last one...
        XCTAssertTrue(start(faceTracked: false, wokeAt: now.addingTimeInterval(-1), lastEnded: now.addingTimeInterval(-1)))
        // ...but following turned off, or unavailable, still means no.
        XCTAssertFalse(start(faceTracked: false, wokeAt: now, enabled: false))
        XCTAssertFalse(start(faceTracked: false, wokeAt: now, reason: "Connect to the robot first."))
    }

    /// A robot that owes a look around gets one session with nobody in view.
    /// The allowance has NO clock: on 2026-09-17 a 12 s one, and a 30 s test on
    /// the uptime, both lapsed during a 90 s flash-and-check cycle, and the
    /// robot came back and sat still.
    func testASessionStartsWithoutAFaceWhileTheRobotOwesALookAround() {
        let now = Date()
        func start(faceTracked: Bool, owes: Bool, lastEnded: Date? = nil) -> Bool {
            AutoFollow.shouldStart(enabled: true, unavailableReason: nil, state: .idle,
                                   faceTracked: faceTracked, lastEnded: lastEnded, now: now,
                                   wokeAt: nil, robotOwesLookAround: owes)
        }
        XCTAssertFalse(start(faceTracked: false, owes: false), "no face, nothing owed: nothing to do")
        XCTAssertTrue(start(faceTracked: false, owes: true), "owed: look around")
        // However long the camera took to come up, the allowance is still good.
        XCTAssertTrue(start(faceTracked: false, owes: true, lastEnded: now.addingTimeInterval(-99999)))
        // Nor is it held back by the gap after the last session.
        XCTAssertTrue(start(faceTracked: false, owes: true, lastEnded: now.addingTimeInterval(-1)))
    }

    /// The robot's own answer is preferred over the uptime guess.
    func testTheRobotSaysWhetherItStillOwesALookAround() {
        let base = #"SBVR {"sketch":"camera_stream","commit":"abc","dirty":false,"built":"x","protocol":1,"# +
                   #""follow_limits_measured":true,"follow_pitch":true,"follow_yaw_range":288,"uptime_ms":"#
        XCTAssertEqual(FirmwareInfo.parse(base + #"91000,"scan_pending":true}"#)?.scanPending, true,
                       "up 91 s and still owes one: a stopwatch would have said no")
        XCTAssertEqual(FirmwareInfo.parse(base + #"4000,"scan_pending":false}"#)?.scanPending, false,
                       "just booted but already scanned: no second one")
        XCTAssertNil(FirmwareInfo.parse(base + "4000}")?.scanPending, "older firmware: fall back to the uptime")
    }

    /// Stanbot opens its eyes before it moves its head: while the app's own
    /// waking sequence runs, nothing starts a session at all.
    func testNothingStartsWhileTheEyesAreStillOpening() {
        let now = Date()
        func start(faceTracked: Bool, waking: Bool) -> Bool {
            AutoFollow.shouldStart(enabled: true, unavailableReason: nil, state: .idle,
                                   faceTracked: faceTracked, lastEnded: nil, now: now,
                                   wokeAt: nil, robotOwesLookAround: true, appIsWaking: waking)
        }
        XCTAssertTrue(start(faceTracked: false, waking: false), "eyes open: the look around may start")
        XCTAssertFalse(start(faceTracked: false, waking: true), "eyes still opening: wait")
        XCTAssertFalse(start(faceTracked: true, waking: true), "even for a face in view")
    }

    /// A reboot asked for during a session ends it, and that ending must not be
    /// retried: nothing should shout C,FOLLOW at a robot that is restarting.
    func testAStopForARebootIsNotRetried() {
        let result = FollowResult(code: "stopped_for_reboot")
        XCTAssertFalse(result.retryable)
        XCTAssertTrue(result.summary.contains("reboot"))
        XCTAssertFalse(AutoFollow.shouldStart(enabled: true, unavailableReason: nil, state: .finished(result),
                                              faceTracked: true, lastEnded: nil, now: Date()))
        // ...but once the robot is back, its look around must still start, which
        // is why a new boot clears the finished state (RobotConnection).
        XCTAssertTrue(AutoFollow.shouldStart(enabled: true, unavailableReason: nil, state: .idle,
                                             faceTracked: false, lastEnded: nil, now: Date(),
                                             robotOwesLookAround: true))
    }

    /// The uptime that tells a reboot from a reconnection.
    func testTheVersionReportCarriesUptime() {
        let line = #"SBVR {"sketch":"camera_stream","commit":"abc","dirty":false,"built":"x","protocol":1,"# +
                   #""follow_limits_measured":true,"follow_pitch":true,"follow_yaw_range":288,"uptime_ms":6200}"#
        let info = FirmwareInfo.parse(line)
        XCTAssertEqual(info?.uptimeMs, 6200)
        XCTAssertLessThan(Double(info!.uptimeMs!) / 1000, AutoFollow.justBootedUptime, "a fresh boot")
        // Firmware that predates the field still parses, and claims nothing.
        let older = #"SBVR {"sketch":"camera_stream","commit":"abc","dirty":false,"built":"x","protocol":1,"# +
                    #""follow_limits_measured":true}"#
        XCTAssertNil(FirmwareInfo.parse(older)?.uptimeMs)
    }
}

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
        /// Every byte, or the test fails. The master is non-blocking, and a frame
        /// written while the pty buffer was full used to be cut short silently;
        /// the app's decoder then waited for the rest of that frame and took the
        /// next line written (the robot's reply) as picture data. That made
        /// testOneSessionPerBootRefusalOffersReboot fail about one run in seven.
        func write(_ data: Data) {
            var offset = 0
            let deadline = Date().addingTimeInterval(5)
            while offset < data.count, Date() < deadline {
                let n = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, $0.count - offset) }
                if n > 0 { offset += n } else { usleep(2000) }
            }
            precondition(offset == data.count, "fake USB could not write everything")
        }
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
        // Up to 10 s, not 3: the first frame goes through Vision, and in the full
        // suite its first face request (loading the model) has taken longer than
        // 3 s. When this wait ran out, every later step failed with a misleading
        // "no result" (seen 2026-09-16); now it fails here, saying why.
        wait(upTo: 10) { robot.cameraState == .receiving && robot.firmware != .asking }
        XCTAssertEqual(robot.cameraState, .receiving, "fake robot never reached a live camera")
        XCTAssertNotEqual(robot.firmware, .asking, "fake robot's version was never parsed")
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
        XCTAssertEqual(usb.read(), "G,0.500,0.500,0\n", "the eyes still look outside a session; not engaged")

        robot.startFollowing()
        guard case .following = robot.follow else { return XCTFail("not following") }
        XCTAssertEqual(usb.read(), "C,FOLLOW\n")

        // The sequence is the camera frame the face came from.
        robot.sendFollowTarget(face, sequence: 41)
        robot.sendFollowTarget(face, sequence: 42)
        robot.sendFollowTarget(face, sequence: 42)   // a repeat is not sent again
        XCTAssertEqual(usb.read(), "T,41,0.500,0.500,0.91\nT,42,0.500,0.500,0.91\n")
        robot.sendGaze(face)
        XCTAssertEqual(usb.read(), "G,0.500,0.500,0\n", "gaze goes during a session too: targets carry no engagement")

        robot.stopFollowing()
        XCTAssertEqual(usb.read(), "C,UNFOLLOW\n")
        let log = try? String(contentsOf: XCTUnwrap(robot.followLogURL), encoding: .utf8)
        XCTAssertNotNil(log, "a session log is opened when following starts")
        XCTAssertTrue(robot.followLogURL?.path.hasPrefix(FileManager.default.temporaryDirectory.path) ?? false,
                      "tests never write into ~/Library/Logs")

        usb.line(#"SBTB {"telemetry":"begin","plan":"follow"}"#)
        usb.line(#"SBMV {"result":"stopped_by_host","plan":"follow","pitch_enabled":false,"observations":2,"rejected":0,"yaw_final":470,"pitch_final":630,"yaw_commanded":472,"pitch_commanded":630,"mode":1}"#)
        // 5 s, not 2: in the full suite, under load, the reader has taken longer
        // than 2 s to deliver these lines (seen twice on 2026-09-16), while the
        // test alone passes every time.
        wait(upTo: 5) { if case .finished = robot.follow { return true }; return false }
        XCTAssertEqual(robot.follow, .finished(FollowResult(code: "stopped_by_host")))

        robot.sendFollowTarget(face, sequence: 7)
        XCTAssertEqual(usb.read(), "", "no targets after the session ended")
    }

    @MainActor
    func testOneSessionPerBootRefusalOffersReboot() {
        let (robot, usb) = connected(measured: true)
        defer { usb.close() }
        robot.startFollowing()
        guard case .following = robot.follow else {
            return XCTFail("did not start: follow \(robot.follow), reason \(robot.followUnavailableReason ?? "none"), camera \(robot.cameraState)")
        }
        let sent = usb.read()
        usb.line(#"SBPW {"error":"requires_unused_boot"}"#)
        wait(upTo: 2) { if case .finished = robot.follow { return true }; return false }
        guard case .finished(let result) = robot.follow else {
            return XCTFail("no result: follow \(robot.follow), app sent \(sent.debugDescription)")
        }
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

    /// Following is automatic at every launch: Stop pauses it for this run
    /// only, and only the Settings switch changes what happens next time.
    @MainActor
    func testFollowingIsAutomaticAgainOnTheNextLaunch() {
        let key = RobotConnection.followAutomaticallyKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let (first, usb) = connected(measured: true)
        XCTAssertTrue(first.followAutomatically, "on by default")
        first.startFollowing()
        first.stopFollowing()
        XCTAssertFalse(first.followAutomatically)
        XCTAssertTrue(first.followAutomaticallyOnLaunch, "Stop does not change the preference")
        usb.close()

        let (relaunched, usb2) = connected(measured: true)
        XCTAssertTrue(relaunched.followAutomatically, "automatic again after relaunch")
        relaunched.followAutomaticallyOnLaunch = false
        XCTAssertFalse(relaunched.followAutomatically, "the Settings switch applies now")
        usb2.close()
        let (afterSetting, usb3) = connected(measured: true)
        XCTAssertFalse(afterSetting.followAutomatically, "and on later launches")
        usb3.close()
    }

    // MARK: manual steering

    private func lines(_ text: String, prefix: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
    }

    @MainActor
    func testSteeringStartsASessionAndResendsWhileHeld() {
        let (robot, usb) = connected(measured: true)
        defer { usb.close() }
        robot.steer(x: 0.75, y: -0.5)
        XCTAssertTrue(robot.steering)
        guard case .following = robot.follow else { return XCTFail("steering should start a session") }
        var sent = usb.read()
        XCTAssertTrue(sent.hasPrefix("C,FOLLOW\n"), "no confirmation: grabbing the stick is the intent")
        XCTAssertEqual(lines(sent, prefix: "H,"), ["H,1,0.75,-0.50"])

        // Held: resent every 100 ms, well inside the robot's 300 ms hold.
        robot.steer(x: -1, y: 0)
        wait(upTo: 0.45) { false }
        sent = usb.read()
        let held = lines(sent, prefix: "H,")
        XCTAssertGreaterThanOrEqual(held.count, 3)
        XCTAssertTrue(held.allSatisfy { $0.hasSuffix(",-1.00,0.00") })
        let sequences = held.compactMap { UInt32($0.split(separator: ",")[1]) }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count, "every resend has a fresh sequence")

        // Released: one centred line, then silence.
        robot.endSteering()
        XCTAssertFalse(robot.steering)
        XCTAssertTrue(lines(usb.read(), prefix: "H,").last?.hasSuffix(",0.00,0.00") ?? false)
        wait(upTo: 0.35) { false }
        XCTAssertEqual(lines(usb.read(), prefix: "H,"), [], "nothing after release")
        guard case .following = robot.follow else { return XCTFail("the session carries on: following resumes") }
    }

    @MainActor
    func testSteeringDuringASessionDoesNotStartAnother() {
        let (robot, usb) = connected(measured: true)
        defer { usb.close() }
        robot.startFollowing()
        _ = usb.read()
        robot.steer(x: 0.2, y: 0)
        XCTAssertFalse(usb.read().contains("C,FOLLOW"))
        robot.endSteering()
    }

    @MainActor
    func testSteeringIsRefusedWhenFollowingIsUnavailable() {
        let (robot, usb) = connected(measured: false)
        defer { usb.close() }
        robot.steer(x: 1, y: 0)
        XCTAssertFalse(robot.steering)
        XCTAssertEqual(robot.follow, .idle)
        XCTAssertEqual(usb.read(), "", "nothing sent to a robot that has following disabled")
    }
}
