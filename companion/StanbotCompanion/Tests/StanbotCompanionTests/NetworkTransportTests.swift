import XCTest
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

    init(port: UInt16? = nil) throws {
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

    func stop() { dropClient(); listener.cancel() }

    private func accept(_ connection: NWConnection) {
        lock.withLock { accepted += 1 }
        current = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                lock.withLock { received += text }
                if text.contains("V\n") {
                    let line = #"SBVR {"sketch":"camera_stream","commit":"0123456789ab","dirty":false,"built":"2026-09-16T18:00:00Z","protocol":1,"follow_limits_measured":false}"# + "\n"
                    connection.send(content: Data(line.utf8), completion: .idempotent)
                }
                if text.contains("S\n") {
                    for sequence in UInt32(1)...3 { connection.send(content: Self.packet(sequence), completion: .idempotent) }
                }
            }
            if !done && error == nil { self.receive(on: connection) }
        }
    }

    private static func packet(_ sequence: UInt32) -> Data {
        let jpeg = jpegBytes()
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) } }
        return Data(Array("SBFR".utf8) + [1] + le(sequence) + le(UInt32(jpeg.count))) + jpeg
    }

    private static func jpegBytes() -> Data {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
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
}
