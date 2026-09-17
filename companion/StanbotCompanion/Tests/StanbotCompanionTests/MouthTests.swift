import XCTest
import AppKit
import Network
import SwiftUI
@testable import StanbotCompanion

final class MouthTests: XCTestCase {
    /// The app's mouth and the robot's are one model: same geometry and timing.
    func testMouthConstantsMatchTheFirmware() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("firmware/lib/StanbotEyes/src/MouthModel.h")
        let source = try String(contentsOf: header, encoding: .utf8)
        func constant(_ name: String) throws -> Double {
            let pattern = try NSRegularExpression(pattern: "static constexpr \\w+ \(name) = ([-\\d.]+)f?;")
            let match = try XCTUnwrap(pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), name)
            return try XCTUnwrap(Double(String(source[Range(match.range(at: 1), in: source)!])))
        }
        XCTAssertEqual(try constant("kCenterX"), MouthModel.centerX)
        XCTAssertEqual(try constant("kCenterY"), MouthModel.centerY)
        XCTAssertEqual(try constant("kClosedHeight"), MouthModel.closedHeight)
        XCTAssertEqual(try constant("kOpenHeight"), MouthModel.openHeight)
        XCTAssertEqual(try constant("kClosedWidth"), MouthModel.closedWidth)
        XCTAssertEqual(try constant("kOpenWidth"), MouthModel.openWidth)
        XCTAssertEqual(try constant("kRim"), MouthModel.rim)
        XCTAssertEqual(try constant("kSilenceCloseMs"), MouthModel.silenceCloseMs)
        XCTAssertEqual(try constant("kFadeMs"), MouthModel.fadeMs)
        XCTAssertEqual(try constant("kSpringOmega"), MouthModel.springOmega)
        XCTAssertTrue(source.contains("kMouthPort = \(MouthSender.port);"))
    }

    func testModelOpensWithSpeechAndClosesAfterSilence() {
        var model = MouthModel()
        var now = 100.0
        model.update(at: now)
        XCTAssertEqual(model.presence, 0)
        for _ in 0..<20 { now += 1.0 / 60; model.receive(1, at: now); model.update(at: now) }
        XCTAssertEqual(model.presence, 1)
        XCTAssertGreaterThan(model.opening, 0.8)
        XCTAssertEqual(model.height, 3 + 15 * model.opening, accuracy: 1e-9)
        // No more values: shut and gone within a second.
        for _ in 0..<60 { now += 1.0 / 60; model.update(at: now) }
        XCTAssertLessThan(model.opening, 0.02)
        XCTAssertEqual(model.presence, 0)
    }

    func testEnvelopeFollowsLoudnessAndIgnoresSilence() {
        let rate = 24_000.0
        // 0.3 s silence, 0.3 s loud tone (RMS about -9 dBFS), 0.4 s silence.
        var samples = [Float](repeating: 0, count: Int(rate * 0.3))
        samples += (0..<Int(rate * 0.3)).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        samples += [Float](repeating: 0.0005, count: Int(rate * 0.4))   // below the noise floor
        let envelope = LoudnessEnvelope(samples: samples, sampleRate: rate)
        XCTAssertEqual(envelope.duration, 1.0, accuracy: 0.02)
        XCTAssertEqual(envelope.value(at: 0.2), 0)
        XCTAssertGreaterThan(envelope.value(at: 0.55), 0.9)          // attack reached full
        XCTAssertLessThan(envelope.value(at: 0.33), envelope.value(at: 0.45))   // rising, not a step
        XCTAssertLessThan(envelope.value(at: 0.95), 0.05)            // released
        XCTAssertEqual(envelope.value(at: -1), 0)
        XCTAssertEqual(envelope.value(at: 5), 0)
    }

    /// Opt-in, like testScreenLookDrawsTheLCDGrid: renders the face with an open
    /// Metal mouth to $TMPDIR/stanbot-mouth-*.png and checks the mouth is drawn
    /// where the robot draws it: a lit rim around a dark opening.
    @MainActor
    func testMetalMouthDrawsARimAroundADarkOpening() throws {
        guard ProcessInfo.processInfo.environment["STANBOT_SHADER_LIBRARY"] != nil else {
            throw XCTSkip("set STANBOT_SHADER_LIBRARY to a compiled StanbotShaders.metallib")
        }
        XCTAssertNotNil(StanbotShaders.library)
        let speech = SpeechMouth()
        speech.hold(opening: 1, level: 0.8)
        for (name, size) in [("face", CGSize(width: 320, height: 240)), ("large", CGSize(width: 960, height: 720))] {
            let view = StanbotEyesView(emotion: .normal, look: .zero, screenLook: true)
                .environment(speech)
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try rep.representation(using: .png, properties: [:])?
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-mouth-\(name).png"))
            guard name == "face" else { continue }
            // At 320x240 one point is one robot pixel: the mouth is centred at (160, 212),
            // 44 wide and 18 tall when fully open, with a 3-pixel rim.
            func brightness(_ x: Int, _ y: Int) -> Double { Double(rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) }
            XCTAssertGreaterThan(brightness(160, 212 - 8), 0.4, "top rim is lit")
            XCTAssertGreaterThan(brightness(160 - 20, 212), 0.4, "end of the capsule is lit")
            XCTAssertLessThan(brightness(160, 212), 0.2, "the opening is dark")
            XCTAssertLessThan(brightness(160, 236), 0.15, "nothing below the mouth")
        }
    }

    func testPacketFormatMatchesTheFirmware() {
        let packet = MouthSender.packet(value: 55, sequence: 0x0102_0304)
        XCTAssertEqual(Array(packet), Array("SBMO".utf8) + [1, 55, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(MouthSender.packet(value: 200, sequence: 1)[5], 100)   // clamped
    }

    /// The sender really puts packets on the wire, with increasing sequences.
    func testSenderSendsIncreasingSequences() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let received = LockedPackets()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func next() {
                connection.receiveMessage { data, _, _, error in
                    if let data { received.append(data) }
                    if error == nil { next() }
                }
            }
            next()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }

        let sender = MouthSender(host: "127.0.0.1", port: listener.port!.rawValue)
        defer { sender.cancel() }
        sender.send(0.5)
        sender.send(1.0)
        sender.send(0)
        let deadline = Date().addingTimeInterval(5)
        while received.count < 3, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let packets = received.all
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets.map { $0[5] }, [50, 100, 0])
        let sequences = packets.map { $0[6..<10].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        XCTAssertEqual(sequences[1], sequences[0] + 1)
        XCTAssertEqual(sequences[2], sequences[1] + 1)
    }
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func append(_ data: Data) { lock.withLock { packets.append(data) } }
    var count: Int { lock.withLock { packets.count } }
    var all: [Data] { lock.withLock { packets.map { Data($0) } } }
}
