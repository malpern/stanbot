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
