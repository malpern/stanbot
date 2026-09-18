import AVFoundation
import XCTest
@testable import StanbotCompanion

/// The audio arithmetic, checked without a microphone, without speakers and
/// without making a sound -- which is the only way it could be checked at all
/// while the owner was in a meeting.
final class VoiceAudioMathTests: XCTestCase {
    private func tone(seconds: Double, amplitude: Double, rate: Double = Double(Live.sampleRate)) -> Data {
        var data = Data()
        let frames = Int(seconds * rate)
        for index in 0..<frames {
            let value = sin(2 * .pi * 440 * Double(index) / rate) * amplitude * 32_767
            var sample = Int16(max(-32_768, min(32_767, value))).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testLevelFollowsLoudness() {
        XCTAssertEqual(VoiceAudioMath.level(of: Data()), 0)
        XCTAssertEqual(VoiceAudioMath.level(of: Data(count: 2_000)), 0, "digital silence is silent")
        let quiet = VoiceAudioMath.level(of: tone(seconds: 0.1, amplitude: 0.1))
        let loud = VoiceAudioMath.level(of: tone(seconds: 0.1, amplitude: 0.9))
        XCTAssertLessThan(quiet, loud)
        XCTAssertLessThanOrEqual(loud, 1.0)
        // A sine's RMS is its amplitude over root two; the mouth depends on this
        // being a measure of loudness rather than of peaks.
        XCTAssertEqual(Double(loud), 0.9 / 2.0.squareRoot(), accuracy: 0.02)
    }

    /// One loud sample is a click, not a syllable. Peak detection would throw
    /// the mouth wide open on it.
    func testASingleClickDoesNotReadAsShouting() {
        var data = Data(count: 4_000)
        data[0] = 0xFF
        data[1] = 0x7F
        XCTAssertLessThan(VoiceAudioMath.level(of: data), 0.05)
    }

    func testSamplesSurviveTheRoundTripIntoABuffer() throws {
        let pcm = tone(seconds: 0.05, amplitude: 0.5)
        let buffer = try XCTUnwrap(VoiceAudioMath.buffer(from: pcm, format: VoiceAudio.modelFormat))
        XCTAssertEqual(Int(buffer.frameLength), pcm.count / 2)
        let channel = try XCTUnwrap(buffer.int16ChannelData)
        let roundTripped = Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
        XCTAssertEqual(roundTripped, pcm, "what goes to the speakers must be what arrived")
        XCTAssertNil(VoiceAudioMath.buffer(from: Data(), format: VoiceAudio.modelFormat))
    }

    /// Chunking must never split a sample in half: a stray byte would put a
    /// click in the model's ear and shift every sample after it.
    func testChunkingNeverSplitsASample() {
        let size = VoiceAudioMath.chunkBytes()
        XCTAssertEqual(size % 2, 0)
        var pending = Data(count: size * 2 + 7)
        let chunks = VoiceAudioMath.chunks(&pending)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count == size })
        XCTAssertEqual(pending.count, 7, "the remainder waits for the rest of its sample")
        XCTAssertTrue(VoiceAudioMath.chunks(&pending).isEmpty)
    }

    func testAChunkIsAboutATenthOfASecond() {
        let seconds = Double(VoiceAudioMath.chunkBytes()) / 2 / Double(Live.sampleRate)
        XCTAssertEqual(seconds, 0.1, accuracy: 0.001)
    }

    /// The microphone is not 24 kHz mono -- the Studio Display's certainly is
    /// not -- so conversion is load-bearing, not plumbing.
    func testItConvertsFromADifferentRateAndChannelCount() throws {
        let microphone = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                     sampleRate: 48_000, channels: 2, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: microphone, to: VoiceAudio.modelFormat))
        let frames = AVAudioFrameCount(4_800)   // 100 ms at 48 kHz
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: microphone, frameCapacity: frames))
        input.frameLength = frames
        let channels = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<Int(frames) {
            let value = Float(sin(2 * .pi * 440 * Double(frame) / 48_000)) * 0.5
            channels[0][frame] = value
            channels[1][frame] = value
        }
        // A resampler holds frames back to prime its filter, so the first call
        // returns short and every call keeps a small tail. What would be a real
        // fault is a LEAK -- audio lost on every buffer for ever, so the
        // microphone quietly runs 3% short of what was said. A single
        // measurement cannot tell a constant tail from a leak; two can, because
        // a tail stays the same size while a leak grows with the run.
        var loudest: Float = 0
        func deficit(after calls: Int) -> Int {
            var total = 0
            for _ in 0..<calls {
                guard let out = VoiceAudioMath.convert(input, with: converter, to: VoiceAudio.modelFormat) else {
                    return .max
                }
                total += out.count
                loudest = max(loudest, VoiceAudioMath.level(of: out))
            }
            return calls * 4_800 - total   // 100 ms at 24 kHz, 16-bit mono
        }
        let short = deficit(after: 10)
        let long = deficit(after: 40)
        XCTAssertGreaterThan(loudest, 0.2, "the tone must survive the conversion")
        XCTAssertLessThan(long, short + 800,
                          "the deficit must not grow with the run: that would be audio lost on every buffer")
        XCTAssertLessThan(Double(long) / (40 * 4_800), 0.02, "and it must stay small in any case")
    }
}
