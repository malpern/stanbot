import AVFoundation
import Foundation

/// The arithmetic behind `VoiceAudio`, kept apart from the engine so it can be
/// tested without a microphone, without speakers, and -- the reason it matters
/// tonight -- without making a sound or touching anyone's meeting.
enum VoiceAudioMath {
    /// How loud a block of 16-bit samples is, 0...1, as the mouth needs it.
    /// Root mean square rather than peak: a single loud sample is a click, not
    /// a syllable, and a mouth that jumps open on clicks reads as broken.
    static func level(of pcm: Data) -> Float {
        guard pcm.count >= 2 else { return 0 }
        var sum = 0.0
        let samples = pcm.count / 2
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<samples {
                let value = Double(Int16(littleEndian: values[index])) / 32_768.0
                sum += value * value
            }
        }
        return Float(min(1, (sum / Double(samples)).squareRoot()))
    }

    /// Raw model samples as something the engine can schedule.
    static func buffer(from pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<Int(frames) { channel[0][index] = Int16(littleEndian: values[index]) }
        }
        return buffer
    }

    /// Whatever the microphone gave us, in the format the model wants. The input
    /// device decides its own rate and channel count -- the Studio Display's
    /// microphone is not 24 kHz mono -- so this is not optional plumbing.
    static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter,
                        to format: AVAudioFormat) -> Data? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }

    /// Captured audio goes up in chunks about this long. Small enough that the
    /// model hears a stream rather than a parcel; large enough not to spend the
    /// morning sending headers.
    static let captureChunk: TimeInterval = 0.1

    static func chunkBytes(_ seconds: TimeInterval = captureChunk) -> Int {
        Int(seconds * Double(Live.sampleRate)) * 2
    }

    /// Split a run of samples on chunk boundaries, keeping the remainder for
    /// next time. Sending a half-sample would put a click in Stanbot's ear.
    static func chunks(_ pending: inout Data, size: Int = chunkBytes()) -> [Data] {
        var out: [Data] = []
        while pending.count >= size {
            out.append(pending.prefix(size))
            pending.removeFirst(size)
        }
        return out
    }
}
