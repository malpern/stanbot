import AVFoundation

/// How loud speech is over time, 0...1, for the mouth. RMS over 20 ms windows
/// every 10 ms, mapped from a noise floor to a comfortable full level, then
/// smoothed with a quick attack and a slower release so syllables read as
/// openings without flicker. See docs/voice.md.
struct LoudnessEnvelope {
    static let hop = 0.010
    static let window = 0.020
    // Tuned on a macOS "Daniel" recording (2026-09-17): speech RMS runs about
    // -23 dBFS median and -15 at the 90th percentile, so typical speech opens
    // the mouth about two thirds and only emphasis opens it fully.
    static let floorDB = -45.0
    static let fullDB = -10.0
    static let attack = 0.030
    static let release = 0.120

    let values: [Double]
    var duration: Double { Double(values.count) * Self.hop }

    init(values: [Double]) { self.values = values }

    /// Analyses mono samples.
    init(samples: [Float], sampleRate: Double) {
        let hop = max(1, Int(sampleRate * Self.hop))
        let window = max(1, Int(sampleRate * Self.window))
        var out: [Double] = []
        out.reserveCapacity(samples.count / hop + 1)
        var level = 0.0
        let rise = 1 - exp(-Self.hop / Self.attack)
        let fall = 1 - exp(-Self.hop / Self.release)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var sum = 0.0
            for i in start..<end { sum += Double(samples[i]) * Double(samples[i]) }
            let rms = (sum / Double(max(1, end - start))).squareRoot()
            let db = 20 * log10(max(rms, 1e-9))
            let raw = min(max((db - Self.floorDB) / (Self.fullDB - Self.floorDB), 0), 1)
            level += (raw - level) * (raw > level ? rise : fall)
            out.append(level)
            start += hop
        }
        values = out
    }

    /// The first channel of an audio file.
    init(file: AVAudioFile) throws {
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        file.framePosition = 0
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        self.init(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                  sampleRate: file.processingFormat.sampleRate)
    }

    /// Loudness at a time in seconds; 0 before the start and after the end.
    func value(at seconds: Double) -> Double {
        guard seconds >= 0 else { return 0 }
        let index = Int(seconds / Self.hop)
        return index < values.count ? values[index] : 0
    }
}
