import AVFoundation
import Network
import Observation
import QuartzCore

/// Sends the mouth to the robot: 11-byte UDP packets to port 3334 ("SBMO",
/// version 2, opening 0-100, shape -100...100 as int8, sequence u32 LE). The robot accepts them
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

    static func packet(open: UInt8, shape: Int8, sequence: UInt32) -> Data {
        var bytes: [UInt8] = Array("SBMO".utf8) + [2, min(open, 100), UInt8(bitPattern: max(-100, min(shape, 100)))]
        bytes += (0..<4).map { UInt8((sequence >> ($0 * 8)) & 0xff) }
        return Data(bytes)
    }

    func send(_ frame: MouthEnvelope.Frame) {
        let open = UInt8((min(max(frame.open, 0), 1) * 100).rounded())
        let shape = Int8((min(max(frame.shape, -1), 1) * 100).rounded())
        queue.async { [self] in
            sequence &+= 1
            connection.send(content: Self.packet(open: open, shape: shape, sequence: sequence), completion: .idempotent)
        }
    }

    func cancel() { connection.cancel() }
}

/// Stanbot speaking: plays audio on this Mac, drives the mouth in the app from
/// what is actually being heard, and sends the same mouth to the robot.
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
    /// The app's own mouth leads the sound slightly too.
    static let appLead = 0.030

    private(set) var opening = 0.0
    /// -1 round ... +1 wide.
    private(set) var shape = 0.0
    /// 0 silent, no mouth ... 1 speaking.
    private(set) var presence = 0.0
    /// How open the voice wants the mouth right now, for the shader's inner light.
    private(set) var level = 0.0
    /// Seconds since this mouth first moved, for gentle shader motion.
    private(set) var time = 0.0
    /// How Stanbot feels, -1 sad to +1 pleased. Only the grille uses it: a
    /// speaker cannot frown, so its slots lean instead. The capsule ignores it,
    /// because a mouth already has a shape for this.
    var mood = 0.0
    private(set) var playing = false
    private(set) var lastError: String?

    @ObservationIgnored private var model = MouthModel()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var envelope = MouthEnvelope(frames: [])
    @ObservationIgnored private var sampleRate = 48_000.0
    @ObservationIgnored private var sender: MouthSender?
    @ObservationIgnored private var lastSent = -Double.infinity
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let started = CACurrentMediaTime()

    static let testLine = "Hello. I'm Stanbot. This is a test of my mouth, so you can see whether it moves in time with my voice. When I stop talking, it should close and fade away."

    /// Speaks a recorded line with the "Daniel" voice through the default
    /// output (the Studio Display on the mini). `robotHost` is the robot's
    /// Wi-Fi host, or nil to animate only the app's mouth.
    /// Put the mouth in a given state for a rendering test or a preview, with no
    /// sound and no robot. Only a test calls this; speech itself goes through
    /// the envelope follower.
    func previewSpeaking(opening: Double, shape: Double, level: Double, mood: Double = 0) {
        self.opening = opening
        self.shape = shape
        self.level = level
        self.mood = mood
        self.presence = 1
        self.time = 0
    }

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

    /// A still mouth, for render tests and previews. Nothing plays.
    func hold(opening: Double, shape: Double = 0, level: Double) {
        self.opening = min(max(opening, 0), 1)
        self.shape = min(max(shape, -1), 1)
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
        envelope = try MouthEnvelope(file: file)
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

    /// One animation step. Returns false once the mouth has settled at rest.
    private func tick() -> Bool {
        let now = CACurrentMediaTime()
        if playing {
            let heard = heardSeconds ?? 0
            // The picture a little ahead of the sound: people forgive a mouth
            // that leads far more readily than one that lags (ITU-R BT.1359).
            let frame = envelope.frame(at: heard + Self.appLead)
            model.receive(frame, at: now)
            level = frame.open
            if now - lastSent >= Self.sendInterval {
                sender?.send(envelope.frame(at: heard + Self.robotLead))
                lastSent = now
            }
            if heard > envelope.duration + 0.1 { finishPlayback() }
        }
        model.update(at: now)
        opening = model.opening
        shape = model.shape
        presence = model.presence
        time = now - started
        return playing || !model.settled
    }

    private func finishPlayback() {
        playing = false
        level = 0
        model.receive(.rest, at: CACurrentMediaTime())
        // A closing rest, repeated because UDP may drop one; the robot also
        // returns to rest on its own 400 ms after the last packet.
        if let sender {
            for _ in 0..<3 { sender.send(.rest) }
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
