import XCTest
import AppKit
import Network
import SwiftUI
@testable import StanbotCompanion

final class MouthTests: XCTestCase {
    private static var header: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("firmware/lib/StanbotEyes/src/MouthModel.h")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The app's mouth and the robot's are one model: same geometry and timing.
    func testMouthConstantsMatchTheFirmware() throws {
        let source = try Self.header
        func constant(_ name: String) throws -> Double {
            let pattern = try NSRegularExpression(pattern: "static constexpr \\w+ \(name) = ([-\\d.]+)f?;")
            let match = try XCTUnwrap(pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), name)
            return try XCTUnwrap(Double(String(source[Range(match.range(at: 1), in: source)!])))
        }
        let pairs: [(String, Double)] = [
            ("kCenterX", MouthModel.centerX), ("kCenterY", MouthModel.centerY),
            ("kRestWidth", MouthModel.restWidth), ("kRestHeight", MouthModel.restHeight),
            ("kOpenHeight", MouthModel.openHeight), ("kWideWidth", MouthModel.wideWidth),
            ("kRoundWidth", MouthModel.roundWidth), ("kOpenNarrowing", MouthModel.openNarrowing),
            ("kWideFlatten", MouthModel.wideFlatten), ("kRoundDeepen", MouthModel.roundDeepen),
            ("kRim", MouthModel.rim), ("kSilenceRestMs", MouthModel.silenceRestMs),
            ("kSpringOmega", MouthModel.springOmega), ("kFadeMs", MouthModel.fadeMs),
        ]
        for (name, value) in pairs { XCTAssertEqual(try constant(name), value, name) }
        XCTAssertTrue(source.contains("kMouthPort = \(MouthSender.port);"))
    }

    func testModelShowsOnlyWhileSpeakingAndShapesWithTheVoice() {
        var model = MouthModel()
        var now = 100.0
        model.update(at: now)
        XCTAssertEqual(model.presence, 0, "no mouth while silent")
        XCTAssertTrue(model.settled)
        func hold(_ frame: MouthEnvelope.Frame, _ seconds: Double) {
            for _ in 0..<Int(seconds * 60) { now += 1.0 / 60; model.receive(frame, at: now); model.update(at: now) }
        }
        hold(MouthEnvelope.Frame(open: 1, shape: 0), 0.4)
        let ah = MouthModel.size(open: model.opening, shape: model.shape)
        hold(MouthEnvelope.Frame(open: 0.6, shape: 1), 0.4)
        let ee = MouthModel.size(open: model.opening, shape: model.shape)
        hold(MouthEnvelope.Frame(open: 0.6, shape: -1), 0.5)
        let oo = MouthModel.size(open: model.opening, shape: model.shape)
        XCTAssertGreaterThan(ah.height, 20)
        XCTAssertGreaterThan(ee.width, 46)
        XCTAssertLessThan(ee.height, ah.height)
        XCTAssertLessThan(oo.width, 30)
        XCTAssertEqual(model.presence, 1)
        // No more targets: eases back to the line, then goes.
        for _ in 0..<120 { now += 1.0 / 60; model.update(at: now) }
        XCTAssertEqual(model.presence, 0)
        XCTAssertTrue(model.settled)
    }

    /// Mirrors test_mouth_model.cpp's sizes, so the two implementations agree.
    func testSizesMatchTheFirmwareFormula() {
        XCTAssertEqual(MouthModel.size(open: 1, shape: 0), CGSize(width: 34, height: 22))
        XCTAssertEqual(MouthModel.size(open: 0.5, shape: 1).width, 53, accuracy: 1e-9)
        XCTAssertEqual(MouthModel.size(open: 0.5, shape: 1).height, 4 + 18 * 0.5 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(MouthModel.size(open: 0.5, shape: -1).width, 40 - 7 - 3, accuracy: 1e-9)
    }

    private static func tone(_ frequency: Double, seconds: Double, amplitude: Double = 0.5, rate: Double = 24_000) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    func testEnvelopeOpensWithSpeechPartsThroughPausesAndRests() {
        let rate = 24_000.0
        var samples = [Float](repeating: 0, count: Int(rate * 0.3))
        samples += Self.tone(220, seconds: 0.3)
        samples += [Float](repeating: 0.0005, count: Int(rate * 0.2))   // a short pause, below the floor
        samples += Self.tone(220, seconds: 0.2)
        samples += [Float](repeating: 0, count: Int(rate * 0.8))        // the end
        let envelope = MouthEnvelope(samples: samples, sampleRate: rate)
        XCTAssertEqual(envelope.frame(at: 0.2), .rest)
        XCTAssertGreaterThan(envelope.frame(at: 0.55).open, 0.9)           // attack reached full
        XCTAssertLessThan(envelope.frame(at: 0.33).open, envelope.frame(at: 0.45).open)   // rising, not a step
        XCTAssertGreaterThanOrEqual(envelope.frame(at: 0.75).open, MouthEnvelope.partedOpen)   // parted in the pause
        XCTAssertLessThan(envelope.frame(at: 1.7).open, 0.02)              // resting after speech
        XCTAssertEqual(envelope.frame(at: -1), .rest)
        XCTAssertEqual(envelope.frame(at: 10), .rest)
    }

    func testEnvelopeShapesDarkSoundsRoundAndBrightSoundsWide() {
        // A low tone is "dark" (little first-difference energy), a high one "bright".
        let dark = MouthEnvelope(samples: Self.tone(150, seconds: 0.6), sampleRate: 24_000)
        let bright = MouthEnvelope(samples: Self.tone(3500, seconds: 0.6), sampleRate: 24_000)
        XCTAssertLessThan(dark.frame(at: 0.5).shape, -0.8)
        XCTAssertGreaterThan(bright.frame(at: 0.5).shape, 0.5)
        XCTAssertEqual(MouthEnvelope.shape(brightness: MouthEnvelope.neutralBrightness), 0)
    }

    func testPacketFormatMatchesTheFirmware() {
        let packet = MouthSender.packet(open: 55, shape: -40, sequence: 0x0102_0304)
        XCTAssertEqual(Array(packet), Array("SBMO".utf8) + [2, 55, UInt8(bitPattern: -40), 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(MouthSender.packet(open: 200, shape: 0, sequence: 1)[5], 100)   // clamped
        XCTAssertEqual(packet.count, 11)
        XCTAssertTrue(try Self.header.contains("kMouthPacketSize = 11;"))
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
        sender.send(MouthEnvelope.Frame(open: 0.5, shape: 1))
        sender.send(MouthEnvelope.Frame(open: 1.0, shape: -0.5))
        sender.send(.rest)
        let deadline = Date().addingTimeInterval(5)
        while received.count < 3, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let packets = received.all
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets.map { $0[5] }, [50, 100, 0])
        XCTAssertEqual(packets.map { Int8(bitPattern: $0[6]) }, [100, -50, 0])
        let sequences = packets.map { $0[7..<11].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        XCTAssertEqual(sequences[1], sequences[0] + 1)
        XCTAssertEqual(sequences[2], sequences[1] + 1)
    }

    /// Opt-in, like testScreenLookDrawsTheLCDGrid: renders the face with the Metal
    /// mouth as a line, open, wide and round to $TMPDIR/stanbot-mouth-*.png, and
    /// checks the open mouth is a lit rim around a dark opening where the robot
    /// draws it.
    @MainActor
    func testMetalMouthDrawsARimAroundADarkOpening() throws {
        guard ProcessInfo.processInfo.environment["STANBOT_SHADER_LIBRARY"] != nil else {
            throw XCTSkip("set STANBOT_SHADER_LIBRARY to a compiled StanbotShaders.metallib")
        }
        XCTAssertNotNil(StanbotShaders.library)
        let speech = SpeechMouth()
        let poses: [(String, Double, Double)] = [("rest", 0, 0), ("ah", 1, 0), ("ee", 0.6, 1), ("oo", 0.6, -1)]
        for (name, open, shape) in poses {
            speech.hold(opening: open, shape: shape, level: open)
            let view = StanbotEyesView(emotion: .normal, look: .zero, screenLook: true)
                .environment(speech)
                .frame(width: 960, height: 720)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try rep.representation(using: .png, properties: [:])?
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-mouth-\(name).png"))
            guard name == "ah" else { continue }
            // At 960x720 one robot pixel is 3 points: the mouth centre is (480, 636),
            // 22 robot pixels tall when fully open, with a 3-pixel rim.
            func brightness(_ x: Int, _ y: Int) -> Double { Double(rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) }
            XCTAssertGreaterThan(brightness(480, 636 - 30), 0.4, "top rim is lit")
            XCTAssertLessThan(brightness(480, 636), 0.2, "the opening is dark")
            XCTAssertLessThan(brightness(480, 718), 0.15, "nothing below the mouth")
        }
    }
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func append(_ data: Data) { lock.withLock { packets.append(data) } }
    var count: Int { lock.withLock { packets.count } }
    var all: [Data] { lock.withLock { packets.map { Data($0) } } }
}
