import AVFoundation
import Network
import Observation
import QuartzCore

/// Sends the mouth's loudness to the robot: 10-byte UDP packets to port 3334
/// ("SBMO", version 1, opening 0-100, sequence u32 LE). The robot accepts them
/// only from the address its Wi-Fi viewer connected from, so they must leave
/// from this Mac; they change nothing but the drawn mouth.
final class MouthSender: @unchecked Sendable {
    static let port: UInt16 = 3334
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mouth-sender")
    /// Seeded from the clock (20 per second since 2026), so a relaunched app
    /// always continues above what the robot last accepted.
    private var sequence = UInt32(max(0, (Date().timeIntervalSince1970 - 1_767_225_600) * 20))

    init(host: String, port: UInt16 = MouthSender.port) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: queue)
    }

    static func packet(value: UInt8, sequence: UInt32) -> Data {
        var bytes: [UInt8] = Array("SBMO".utf8) + [1, min(value, 100)]
        bytes += (0..<4).map { UInt8((sequence >> ($0 * 8)) & 0xff) }
        return Data(bytes)
    }

    func send(_ value: Double) {
        let byte = UInt8((min(max(value, 0), 1) * 100).rounded())
        queue.async { [self] in
            sequence &+= 1
            connection.send(content: Self.packet(value: byte, sequence: sequence), completion: .idempotent)
        }
    }

    func cancel() { connection.cancel() }
}

/// Stanbot speaking: plays audio on this Mac, drives the mouth in the app from
/// what is actually being heard, and sends the same loudness to the robot.
///
/// Phase 1 of docs/voice.md plays a recorded voice (`playTest`); the live
/// conversation will feed the same envelope and timing. Kept apart from
/// RobotConnection so a 60 Hz mouth re-renders only the mouth views.
@MainActor
@Observable
final class SpeechMouth {
    /// How often the robot is sent a value while speaking.
    static let sendInterval = 1.0 / 15
    /// How far ahead of the sound the robot is sent each value, to cover the
    /// one-way Wi-Fi delay. To be measured by eye (docs/voice.md, phase 1).
    static let robotLead = 0.060

    private(set) var opening = 0.0
    private(set) var presence = 0.0
    /// The raw loudness now, for the shader's inner light.
    private(set) var level = 0.0
    /// Seconds since this mouth first moved, for gentle shader motion.
    private(set) var time = 0.0
    private(set) var playing = false
    private(set) var lastError: String?

    @ObservationIgnored private var model = MouthModel()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var envelope = LoudnessEnvelope(values: [])
    @ObservationIgnored private var sampleRate = 48_000.0
    @ObservationIgnored private var sender: MouthSender?
    @ObservationIgnored private var lastSent = -Double.infinity
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let started = CACurrentMediaTime()

    var visible: Bool { presence > 0 }

    static let testLine = "Hello. I'm Stanbot. This is a test of my mouth, so you can see whether it moves in time with my voice. When I stop talking, it should close and fade away."

    /// Speaks a recorded line with the "Daniel" voice through the default
    /// output (the Studio Display on the mini). `robotHost` is the robot's
    /// Wi-Fi host, or nil to animate only the app's mouth.
    func playTest(robotHost: String?) {
        guard !playing else { return }
        lastError = nil
        Task {
            do {
                let url = try await Self.renderTestLine()
                try play(url: url, robotHost: robotHost)
            } catch {
                lastError = "Mouth test: \(error.localizedDescription)"
            }
        }
    }

    /// A still, open mouth, for render tests and previews. Nothing plays.
    func hold(opening: Double, level: Double) {
        self.opening = min(max(opening, 0), 1)
        self.level = min(max(level, 0), 1)
        presence = 1
        time = 1
    }

    func stop() {
        guard playing else { return }
        finishPlayback()
    }

    private static func renderTestLine() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-mouth-test.aiff")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let line = testLine
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "Daniel", "-o", url.path, line]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }.value
        return url
    }

    private func play(url: URL, robotHost: String?) throws {
        let file = try AVAudioFile(forReading: url)
        envelope = try LoudnessEnvelope(file: file)
        sampleRate = file.processingFormat.sampleRate
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        try engine.start()
        player.scheduleFile(file, at: nil)
        player.play()
        self.engine = engine
        self.player = player
        sender = robotHost.map { MouthSender(host: $0) }
        lastSent = -.infinity
        playing = true
        startLoop()
    }

    /// Seconds of audio actually heard so far: what the player has rendered,
    /// less the output device's latency.
    private var heardSeconds: Double? {
        guard let player, let engine, let renderTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: renderTime) else { return nil }
        return Double(time.sampleTime) / time.sampleRate - engine.outputNode.presentationLatency
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.tick() else { break }
            }
            self?.loop = nil
        }
    }

    /// One animation step. Returns false once there is nothing left to draw.
    private func tick() -> Bool {
        let now = CACurrentMediaTime()
        if playing {
            let heard = heardSeconds ?? 0
            let value = envelope.value(at: heard)
            model.receive(value, at: now)
            level = value
            if now - lastSent >= Self.sendInterval {
                sender?.send(envelope.value(at: heard + Self.robotLead))
                lastSent = now
            }
            if heard > envelope.duration + 0.1 { finishPlayback() }
        }
        model.update(at: now)
        opening = model.opening
        presence = model.presence
        time = now - started
        return playing || presence > 0
    }

    private func finishPlayback() {
        playing = false
        level = 0
        model.receive(0, at: CACurrentMediaTime())
        // A closing 0, repeated because UDP may drop one; the robot also closes
        // on its own 400 ms after the last packet.
        if let sender {
            for _ in 0..<3 { sender.send(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sender.cancel() }
        }
        sender = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        startLoop()
    }
}
