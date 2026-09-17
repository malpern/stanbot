import XCTest
import AppKit
import Network
import ImageIO
import UniformTypeIdentifiers
@testable import StanbotCompanion

/// A stand-in robot on loopback: records what the app sends, answers V, and
/// streams real JPEG frames once asked. Loopback needs no Local Network grant.
private final class FakeRobot: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-robot")
    private let lock = NSLock()
    private var received = ""
    private var accepted = 0
    private var current: NWConnection?
    /// The passphrase this fake robot holds, and what it concluded.
    var passphrase = "test-passphrase"
    /// What this fake reports for follow_limits_measured: true is a calibration build.
    var followMeasured = false
    private(set) var authorized: [String] = []
    /// How many connections to accept and then never answer, as the real robot
    /// does while a previous viewer still holds its only slot.
    var unheardConnections = 0
    private static let nonce = "00112233445566778899aabbccddeeff"

    let frameWidth: Int, frameHeight: Int

    init(port: UInt16? = nil, frameWidth: Int = 32, frameHeight: Int = 24) throws {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        listener = try NWListener(using: .tcp, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: UInt16 { listener.port!.rawValue }
    var commands: String { lock.withLock { received } }
    var connections: Int { lock.withLock { accepted } }

    /// Drops the current client, as a robot rebooting or leaving Wi-Fi would.
    func dropClient() { queue.sync { current?.cancel(); current = nil } }

    /// Sends a text line to the connected app, as robot telemetry would arrive.
    func sendLine(_ text: String) { queue.sync { current?.send(content: Data((text + "\n").utf8), completion: .idempotent) } }
    var authorizedCommands: [String] { lock.withLock { authorized } }

    func stop() { dropClient(); listener.cancel() }

    private func accept(_ connection: NWConnection) {
        let ignore = lock.withLock { () -> Bool in
            accepted += 1
            guard unheardConnections > 0 else { return false }
            unheardConnections -= 1
            return true
        }
        current = connection
        connection.start(queue: queue)
        if !ignore { receive(on: connection) }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                lock.withLock { received += text }
                for line in text.split(separator: "\n") where line.hasPrefix("A,") {
                    if line == "A,?" {
                        connection.send(content: Data("SBAC {\"nonce\":\"\(Self.nonce)\",\"lifetime_ms\":30000}\n".utf8), completion: .idempotent)
                    } else {
                        let parts = line.split(separator: ",")
                        let command = parts.count == 3 ? String(parts[1]) : ""
                        let ok = parts.count == 3 && String(parts[2]) == CommandAuthorization.mac(command: command, nonce: Self.nonce, passphrase: passphrase)
                        if ok { lock.withLock { authorized.append(command) } }
                        connection.send(content: Data("SBAU {\"command\":\"\(command)\",\"ok\":\(ok),\"reason\":\"\(ok ? "ok" : "bad_mac")\"}\n".utf8), completion: .idempotent)
                    }
                }
                if text.contains("V\n") {
                    let line = #"SBVR {"sketch":"camera_stream","commit":"0123456789ab","dirty":false,"built":"2026-09-16T18:00:00Z","protocol":1,"follow_limits_measured":"# + "\(followMeasured)}\n"
                    connection.send(content: Data(line.utf8), completion: .idempotent)
                }
                if text.contains("S\n") {
                    for sequence in UInt32(1)...3 { connection.send(content: Self.packet(sequence, width: frameWidth, height: frameHeight), completion: .idempotent) }
                }
            }
            if !done && error == nil { self.receive(on: connection) }
        }
    }

    private static func packet(_ sequence: UInt32, width: Int, height: Int) -> Data {
        let jpeg = jpegBytes(width: width, height: height)
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) } }
        return Data(Array("SBFR".utf8) + [1] + le(sequence) + le(UInt32(jpeg.count))) + jpeg
    }

    private static func jpegBytes(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}

final class NetworkTransportTests: XCTestCase {
    @MainActor
    private func wait(upTo seconds: TimeInterval, tick robot: RobotConnection? = nil, for condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            robot?.tick()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    func testCameraStartsAndStreamsOverWiFi() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        // preferNetwork: a USB port may exist on the test machine and must be ignored.
        let robot = RobotConnection(port: nil, automaticPolling: false,
                                    networkHost: "127.0.0.1", networkPort: fake.port, transport: .wifi)
        wait(upTo: 5) { robot.connection == .connected("127.0.0.1") }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"))
        XCTAssertEqual(robot.portName, "127.0.0.1")
        // The bug: this used to be .unavailable, because startCamera required USB.
        XCTAssertNotEqual(robot.cameraState, .unavailable)

        wait(upTo: 5) { robot.cameraState == .receiving && robot.firmware != .asking }
        XCTAssertEqual(robot.cameraState, .receiving)
        guard case .reported(let info) = robot.firmware else { return XCTFail("no firmware over Wi-Fi: \(robot.firmware)") }
        XCTAssertEqual(info.shortCommit, "0123456")
        XCTAssertEqual(fake.commands, "V\nS\n")
    }

    @MainActor
    func testReconnectsAfterTheWiFiLinkDrops() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = RobotConnection(port: nil, automaticPolling: false,
                                    networkHost: "127.0.0.1", networkPort: fake.port, transport: .wifi)
        wait(upTo: 5) { robot.cameraState == .receiving }
        XCTAssertEqual(fake.connections, 1)

        fake.dropClient()
        wait(upTo: 3) { robot.connection == .unavailable }
        XCTAssertEqual(robot.connection, .unavailable)
        XCTAssertEqual(robot.firmware, .unknown)
        XCTAssertNil(robot.cameraImage)

        // The bug: tick() treated a chosen-but-dead network as up and never retried.
        wait(upTo: 8, tick: robot) { robot.cameraState == .receiving && fake.connections == 2 }
        XCTAssertEqual(fake.connections, 2, "exactly one reconnect, not a cancel-and-retry loop")
        XCTAssertEqual(robot.cameraState, .receiving)
    }

    @MainActor
    func testReconnectsWhenAConnectedRobotNeverAnswers() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        // The bug: relaunched while the robot still served the old app, Stanbot
        // connected into the robot's listen queue and waited there forever.
        fake.unheardConnections = 1
        let robot = RobotConnection(port: nil, automaticPolling: false,
                                    networkHost: "127.0.0.1", networkPort: fake.port, transport: .wifi)
        wait(upTo: 15, tick: robot) { robot.cameraState == .receiving && fake.connections == 2 }
        XCTAssertEqual(fake.connections, 2)
        XCTAssertEqual(robot.cameraState, .receiving)
        guard case .reported = robot.firmware else { return XCTFail("no firmware after reconnecting: \(robot.firmware)") }
    }

    @MainActor
    func testSleepAndWakeNeedNoPassphraseAndTrackTheRobot() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = calibratedWiFiRobot(fake, passphrase: "test-passphrase")
        wait(upTo: 5, tick: robot) { robot.cameraState == .receiving }
        XCTAssertFalse(robot.asleep)

        robot.sleep()
        wait(upTo: 2) { fake.commands.contains("C,SLEEP") }
        XCTAssertTrue(fake.commands.contains("C,SLEEP"))
        XCTAssertEqual(fake.authorizedCommands, [], "sleeping needs no authorization")
        // The robot's own report is what the app trusts.
        fake.sendLine("SBSL {\"asleep\":true}")
        wait(upTo: 2, tick: robot) { robot.asleep }
        XCTAssertTrue(robot.asleep)

        robot.wake()
        wait(upTo: 2) { fake.commands.contains("C,WAKE") }
        fake.sendLine("SBSL {\"asleep\":false}")
        wait(upTo: 2, tick: robot) { !robot.asleep }
        XCTAssertFalse(robot.asleep)

        // Sleep clicked again straight away: the robot's report of the earlier
        // wake, arriving late, must not flip the app back (it made the eyes open,
        // close and open again). A report that agrees, or a later one, is taken.
        robot.sleep()
        XCTAssertTrue(robot.asleep)
        fake.sendLine("SBSL {\"asleep\":false}")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(robot.asleep, "a contradicting report just after a command is the old state, late")
        fake.sendLine("SBSL {\"asleep\":true}")
        wait(upTo: 2, tick: robot) { robot.asleep }
        XCTAssertTrue(robot.asleep)
    }

    /// The robot reports when its head cannot reach its base (SBHL). That must be
    /// an alarm in the app, not a silence: it was hours of dead following, once.
    @MainActor
    func testTheRobotsOwnFaultReportIsSurfacedAndClears() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = calibratedWiFiRobot(fake, passphrase: "test-passphrase")
        wait(upTo: 5, tick: robot) { robot.cameraState == .receiving }
        XCTAssertNil(robot.robotFault)

        fake.sendLine("SBHL {\"base\":false,\"esp_err\":259}")
        wait(upTo: 2, tick: robot) { robot.robotFault != nil }
        let fault = try XCTUnwrap(robot.robotFault)
        XCTAssertTrue(fault.contains("259"), "the error code is there for whoever debugs it")
        XCTAssertTrue(fault.contains("Reboot"), "and what to do about it")

        fake.sendLine("SBHL {\"base\":true,\"esp_err\":0}")
        wait(upTo: 2, tick: robot) { robot.robotFault == nil }
        XCTAssertNil(robot.robotFault)
    }

    @MainActor
    func testTurningTheRobotOffOverWiFiIsAuthorized() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = calibratedWiFiRobot(fake, passphrase: "test-passphrase")
        wait(upTo: 5, tick: robot) { robot.cameraState == .receiving }

        robot.turnOffRobot()
        wait(upTo: 3, tick: robot) { fake.authorizedCommands == ["OFF"] }
        XCTAssertEqual(fake.authorizedCommands, ["OFF"])
        XCTAssertFalse(fake.commands.contains("C,OFF"), "over Wi-Fi only the authorized form is used")
        XCTAssertFalse(fake.commands.contains("test-passphrase"))
    }

    // MARK: - Transport preference

    /// A loopback port with nothing listening, so a Wi-Fi attempt is refused.
    private func closedPort() throws -> UInt16 {
        let fake = try FakeRobot()
        let port = fake.port
        fake.stop()
        return port
    }

    /// A pseudo-terminal standing in for the robot's USB serial port.
    private struct FakeUSB {
        var master: Int32 = -1, slave: Int32 = -1
        let path: String
        init() {
            var master: Int32 = -1, slave: Int32 = -1
            var name = [CChar](repeating: 0, count: 128)
            precondition(openpty(&master, &slave, &name, nil, nil) == 0)
            self.master = master; self.slave = slave
            path = String(cString: name)
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        }
        /// Everything the app has written to the robot so far.
        func read() -> String {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            return count > 0 ? String(decoding: bytes[0..<count], as: UTF8.self) : ""
        }
        func close() { Darwin.close(slave); Darwin.close(master) }
    }

    @MainActor
    func testAutomaticPrefersWiFiWhenBothAreAvailable() throws {
        let fake = try FakeRobot()
        let usb = FakeUSB()
        defer { fake.stop(); usb.close() }
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: fake.port, transport: .automatic)
        wait(upTo: 5, tick: robot) { robot.cameraState == .receiving }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"))
        XCTAssertEqual(robot.linkSummary, "Wi-Fi (127.0.0.1)")
        XCTAssertEqual(usb.read(), "", "USB must stay untouched while Wi-Fi works")
    }

    @MainActor
    func testAutomaticFallsBackToUSBWhenWiFiIsUnreachable() throws {
        let usb = FakeUSB()
        defer { usb.close() }
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: try closedPort(), transport: .automatic)
        wait(upTo: 8, tick: robot) { robot.connection == .connected(usb.path) }
        XCTAssertEqual(robot.connection, .connected(usb.path))
        XCTAssertTrue(robot.linkSummary.hasPrefix("USB"))
        XCTAssertEqual(usb.read(), "V\nS\n")
    }

    @MainActor
    func testAutomaticReturnsToWiFiWhenTheRobotReappears() throws {
        let usb = FakeUSB()
        defer { usb.close() }
        let port = try closedPort()
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: port, transport: .automatic, wifiRetryInterval: 0.3)
        wait(upTo: 8, tick: robot) { robot.connection == .connected(usb.path) }
        XCTAssertEqual(robot.connection, .connected(usb.path))

        // Failed background tries must not disturb the USB link.
        wait(upTo: 1.5, tick: robot) { false }
        XCTAssertEqual(robot.connection, .connected(usb.path))

        let fake = try FakeRobot(port: port)
        defer { fake.stop() }
        wait(upTo: 8, tick: robot) { robot.connection == .connected("127.0.0.1") && robot.cameraState == .receiving }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"))
        XCTAssertEqual(robot.cameraState, .receiving)
        XCTAssertEqual(fake.connections, 1, "one promoted attempt, not a reconnect loop")
    }

    @MainActor
    func testAutomaticFallsBackWhenWiFiDropsThenReturns() throws {
        let fake = try FakeRobot()
        let usb = FakeUSB()
        defer { fake.stop(); usb.close() }
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: fake.port, transport: .automatic, wifiRetryInterval: 0.5)
        wait(upTo: 5, tick: robot) { robot.cameraState == .receiving }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"))

        fake.dropClient()
        wait(upTo: 5, tick: robot) { robot.connection == .connected(usb.path) }
        XCTAssertEqual(robot.connection, .connected(usb.path), "falls back to USB at once")
        XCTAssertEqual(usb.read(), "V\nS\n")

        wait(upTo: 8, tick: robot) { robot.connection == .connected("127.0.0.1") }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"), "and returns to Wi-Fi")
    }

    @MainActor
    func testUSBOnlyNeverContactsWiFi() throws {
        let fake = try FakeRobot()
        let usb = FakeUSB()
        defer { fake.stop(); usb.close() }
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: fake.port, transport: .usb, wifiRetryInterval: 0.2)
        wait(upTo: 1.5, tick: robot) { false }
        XCTAssertEqual(robot.connection, .connected(usb.path))
        XCTAssertEqual(fake.connections, 0)
        XCTAssertEqual(usb.read(), "V\nS\n")
    }

    @MainActor
    func testWiFiOnlyNeverOpensUSB() throws {
        let usb = FakeUSB()
        defer { usb.close() }
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: try closedPort(), transport: .wifi)
        wait(upTo: 3, tick: robot) { false }
        XCTAssertNotEqual(robot.connection, .connected(usb.path))
        XCTAssertEqual(usb.read(), "")
    }

    @MainActor
    func testChangingThePreferenceReconnectsAtOnce() throws {
        let fake = try FakeRobot()
        let usb = FakeUSB()
        defer { fake.stop(); usb.close() }
        let robot = RobotConnection(port: usb.path, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: fake.port, transport: .automatic)
        wait(upTo: 5, tick: robot) { robot.connection == .connected("127.0.0.1") }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"))

        robot.transport = .usb
        XCTAssertEqual(robot.connection, .connected(usb.path))
        XCTAssertEqual(usb.read(), "V\nS\n")

        robot.transport = .wifi
        // The client side is ready at the handshake, before the listener's
        // accept handler has counted it, so wait for both.
        wait(upTo: 5, tick: robot) { robot.connection == .connected("127.0.0.1") && fake.connections == 2 }
        XCTAssertEqual(robot.connection, .connected("127.0.0.1"))
        XCTAssertEqual(fake.connections, 2)
    }

    @MainActor
    func testDisplayedFramesAreEnhancedAtRobotResolution() throws {
        try XCTSkipUnless(VideoEnhancement.videoToolboxAvailable, "needs macOS 26 VideoToolbox processors")
        let fake = try FakeRobot(frameWidth: 320, frameHeight: 240)
        defer { fake.stop() }
        let robot = RobotConnection(port: nil, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: fake.port, transport: .wifi)
        robot.enhancement = VideoEnhancement()   // all on, whatever this machine has stored
        wait(upTo: 5) { pixelWidth(robot.cameraImage) == 640 }
        XCTAssertEqual(pixelWidth(robot.cameraImage), 640, "upscaled for display")

        robot.enhancement = .off
        robot.stopCamera(); robot.startCamera()
        wait(upTo: 5) { pixelWidth(robot.cameraImage) == 320 }
        XCTAssertEqual(pixelWidth(robot.cameraImage), 320, "untouched when off")
    }

    /// The backing CGImage's width. NSImage representations report doubled
    /// pixels on a Retina display, which is not the frame's size.
    private func pixelWidth(_ image: NSImage?) -> Int {
        var rect = CGRect.zero
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)?.width ?? 0
    }

    @MainActor
    func testHeadFollowingNeverStartsOverWiFiWithoutAPassphrase() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = RobotConnection(port: nil, automaticPolling: false, networkHost: "127.0.0.1",
                                    networkPort: fake.port, transport: .wifi, passphrase: { nil })
        wait(upTo: 5) { robot.cameraState == .receiving }
        XCTAssertTrue(robot.followUnavailableReason?.contains("passphrase") ?? false)
        robot.startFollowing()
        XCTAssertEqual(robot.follow, .idle)
        XCTAssertFalse(fake.commands.contains("C,FOLLOW"))
    }

    @MainActor
    private func calibratedWiFiRobot(_ fake: FakeRobot, passphrase: String) -> RobotConnection {
        fake.followMeasured = true
        let robot = RobotConnection(port: nil, automaticPolling: false, networkHost: "127.0.0.1", networkPort: fake.port,
                                    transport: .wifi,
                                    followLogDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-test-logs"),
                                    passphrase: { passphrase })
        robot.enhancement = .off
        wait(upTo: 5) { robot.cameraState == .receiving }
        wait(upTo: 3) { if case .reported = robot.firmware { return true }; return false }
        return robot
    }

    @MainActor
    func testFollowingOverWiFiIsAuthorizedWithThePassphrase() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = calibratedWiFiRobot(fake, passphrase: "test-passphrase")
        XCTAssertNil(robot.followUnavailableReason)

        robot.startFollowing()
        wait(upTo: 3) { if case .following = robot.follow { return true }; return false }
        guard case .following = robot.follow else { return XCTFail("not following: \(robot.follow)") }
        XCTAssertEqual(fake.authorizedCommands, ["FOLLOW"])
        XCTAssertFalse(fake.commands.contains("test-passphrase"), "the passphrase never crosses the network")
        XCTAssertFalse(fake.commands.contains("C,FOLLOW"), "over Wi-Fi only the authorized form is used")

        robot.sendFollowTarget(FaceBox(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), confidence: 0.9), sequence: 1)
        robot.stopFollowing()
        wait(upTo: 2) { fake.commands.contains("C,UNFOLLOW") }
        XCTAssertTrue(fake.commands.contains("T,1,"))
        XCTAssertTrue(fake.commands.contains("C,UNFOLLOW"))

        // The result now reaches a Wi-Fi viewer too.
        fake.sendLine(#"SBMV {"result":"stopped_by_host","plan":"follow","pitch_enabled":false,"observations":1,"rejected":0,"yaw_final":460,"pitch_final":602,"yaw_commanded":460,"pitch_commanded":602,"mode":0}"#)
        wait(upTo: 2) { if case .finished = robot.follow { return true }; return false }
        XCTAssertEqual(robot.follow, .finished(FollowResult(code: "stopped_by_host")))
    }

    @MainActor
    func testWrongPassphraseIsRefusedAndNothingIsSent() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = calibratedWiFiRobot(fake, passphrase: "not-the-robots")
        robot.startFollowing()
        wait(upTo: 3) { if case .finished = robot.follow { return true }; return false }
        XCTAssertEqual(robot.follow, .finished(FollowResult(code: "auth_bad_mac")))
        XCTAssertEqual(fake.authorizedCommands, [])
        robot.sendFollowTarget(FaceBox(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), confidence: 0.9), sequence: 1)
        XCTAssertFalse(fake.commands.contains("T,"))
    }

    @MainActor
    func testRebootOverWiFiIsAuthorized() throws {
        let fake = try FakeRobot()
        defer { fake.stop() }
        let robot = calibratedWiFiRobot(fake, passphrase: "test-passphrase")
        robot.rebootRobot()
        wait(upTo: 3) { fake.authorizedCommands == ["REBOOT"] }
        XCTAssertEqual(fake.authorizedCommands, ["REBOOT"])
        XCTAssertFalse(fake.commands.contains("C,REBOOT"))
    }
}
