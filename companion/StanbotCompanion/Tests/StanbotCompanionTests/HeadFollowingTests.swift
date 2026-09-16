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

        robot.sendFollowTarget(face)
        XCTAssertEqual(usb.read(), "", "no targets outside a session")

        robot.startFollowing()
        guard case .following = robot.follow else { return XCTFail("not following") }
        XCTAssertEqual(usb.read(), "C,FOLLOW\n")

        robot.sendFollowTarget(face)
        robot.sendFollowTarget(face)
        XCTAssertEqual(usb.read(), "T,1,0.500,0.500,0.91\nT,2,0.500,0.500,0.91\n", "sequence starts at 1 and increases")

        robot.stopFollowing()
        XCTAssertEqual(usb.read(), "C,UNFOLLOW\n")

        usb.line(#"SBTB {"telemetry":"begin","plan":"follow"}"#)
        usb.line(#"SBMV {"result":"stopped_by_host","plan":"follow","pitch_enabled":false,"observations":2,"rejected":0,"yaw_final":470,"pitch_final":630,"yaw_commanded":472,"pitch_commanded":630,"mode":1}"#)
        wait(upTo: 2) { if case .finished = robot.follow { return true }; return false }
        XCTAssertEqual(robot.follow, .finished(FollowResult(code: "stopped_by_host")))

        robot.sendFollowTarget(face)
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
}
