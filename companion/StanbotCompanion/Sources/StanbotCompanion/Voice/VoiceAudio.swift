import AVFoundation
import Foundation

/// Capture and playback for a conversation: the microphone into the model, the
/// model's speech out of the speakers, and the samples the mouth is drawn from.
///
/// **Nothing here runs until `start()` is called**, deliberately. An
/// `AVAudioEngine` with voice processing takes the microphone and, on macOS 14
/// and later, ducks other applications' audio by default -- which would quietly
/// lower a meeting. The ducking configuration below is the fix, and "other
/// audio is not ducked" is a pass criterion of the phase 2 spike, not something
/// to assume from the documentation.
///
/// The arithmetic -- formats, chunk sizes, how loud a chunk is -- is in
/// `VoiceAudioMath`, which is pure and tested without a sound card.
final class VoiceAudio {
    enum Failure: Error, Equatable {
        case noInputDevice
        case noOutputDevice
        case engineFailed(String)

        var summary: String {
            switch self {
            case .noInputDevice: return "No microphone for the conversation."
            case .noOutputDevice: return "No speakers for the conversation."
            case .engineFailed(let why): return "The audio system refused: \(why)"
            }
        }
    }

    /// Captured microphone audio, already in the model's format: 24 kHz mono
    /// signed 16-bit.
    var onCapture: ((Data) -> Void)?
    /// How loud what is being PLAYED is, 0...1, for the mouth. The mouth is
    /// driven from Stanbot's speech, never from the microphone.
    var onPlaybackLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private(set) var isRunning = false
    private var buffer = PlayoutBuffer()
    private let lock = NSLock()

    /// The format the model speaks, both directions.
    static var modelFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Live.sampleRate),
                      channels: 1, interleaved: true)!
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode

        // Voice processing is what stops the model hearing itself through the
        // speakers and interrupting its own replies -- with full duplex there is
        // nothing else doing echo cancellation for us.
        do {
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw Failure.engineFailed(error.localizedDescription)
        }
        // And this is what stops it dimming everything else on the Mac. The
        // default ducks other applications whenever it hears speech, which
        // would lower a meeting or music without anyone asking.
        if #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw Failure.noInputDevice }
        converter = AVAudioConverter(from: inputFormat, to: Self.modelFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.captured(buffer)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.modelFormat)

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed(error.localizedDescription)
        }
        player.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.lock(); buffer.flush(); lock.unlock()
        onPlaybackLevel?(0)   // the mouth closes with the sound, always
    }

    /// Speech from the model, queued for playback. It goes through
    /// `PlayoutBuffer`, so what can be heard after an interruption is bounded by
    /// the same 200 ms everything else in this design turns on.
    func play(_ pcm: Data) {
        lock.lock()
        buffer.append(pcm)
        let chunk = buffer.take(buffer.queued.count)
        lock.unlock()
        guard !chunk.isEmpty, let audio = VoiceAudioMath.buffer(from: chunk, format: Self.modelFormat) else { return }
        onPlaybackLevel?(VoiceAudioMath.level(of: chunk))
        player.scheduleBuffer(audio, completionHandler: nil)
    }

    /// Someone talked over Stanbot. Everything queued goes, and the mouth shuts:
    /// the service sends no cancel, so this is the only thing that stops it
    /// finishing its sentence over them.
    func flush() {
        lock.lock(); buffer.flush(); lock.unlock()
        player.stop()
        player.play()
        onPlaybackLevel?(0)
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let out = VoiceAudioMath.convert(buffer, with: converter, to: Self.modelFormat) else { return }
        onCapture?(out)
    }
}
