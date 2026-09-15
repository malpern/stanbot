import XCTest
import Darwin
@testable import StanbotCompanion

final class DisconnectTests: XCTestCase {
    @MainActor
    func testUnplugWhileReadingAndReconnect() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        let robot = RobotConnection(port: String(cString: name), automaticPolling: false)
        robot.startCamera()
        // A partial packet and garbage must not crash or survive a disconnect.
        let noise = Array("garbageSBFR".utf8)
        _ = noise.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        robot.tick()
        Darwin.close(slave)
        Darwin.close(master)
        robot.tick()
        XCTAssertEqual(robot.connection, .unavailable)
        XCTAssertNil(robot.cameraImage)
        XCTAssertTrue(robot.faceBoxes.isEmpty)
        robot.stopCamera() // Also safe after the device disappeared.
        XCTAssertEqual(robot.cameraState, .off)

        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { Darwin.close(slave); Darwin.close(master) }
        robot.selectedPort = String(cString: name)
        robot.connect()
        XCTAssertEqual(robot.connection, .connected(String(cString: name)))
        robot.startCamera()
        robot.stopCamera()
        robot.startCamera()
        robot.tick()
        XCTAssertEqual(robot.cameraState, .waiting)
        robot.stopCamera()
    }

    @MainActor
    func testCameraStreamsWithoutAButtonPress() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { Darwin.close(slave); Darwin.close(master) }
        // Connecting alone must request the stream; nothing calls startCamera().
        let robot = RobotConnection(port: String(cString: name), automaticPolling: false)
        XCTAssertEqual(robot.connection, .connected(String(cString: name)))
        XCTAssertEqual(robot.cameraState, .waiting)
        XCTAssertEqual(Self.read(master), "S\n")

        // An explicit stop is honoured and survives a reconnect.
        robot.stopCamera()
        XCTAssertEqual(robot.cameraState, .off)
        XCTAssertEqual(Self.read(master), "X\n")
        robot.connect()
        XCTAssertEqual(robot.cameraState, .off)
        XCTAssertEqual(Self.read(master), "")

        // Asking for it again resumes automatic behaviour on later reconnects.
        robot.startCamera()
        XCTAssertEqual(Self.read(master), "S\n")
        robot.connect()
        XCTAssertEqual(robot.cameraState, .waiting)
        XCTAssertEqual(Self.read(master), "S\n")
    }

    private static func read(_ fd: Int32) -> String {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return "" }
        return String(decoding: bytes[0..<count], as: UTF8.self)
    }

    @MainActor
    func testUnplugImmediatelyBeforeWrite() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        let robot = RobotConnection(port: String(cString: name), automaticPolling: false)
        Darwin.close(slave)
        Darwin.close(master)
        robot.startCamera()
        XCTAssertEqual(robot.connection, .unavailable)
        robot.select(.happy)
        robot.stopCamera()
    }
}
