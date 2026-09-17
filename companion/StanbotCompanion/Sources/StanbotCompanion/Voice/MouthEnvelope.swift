import AVFoundation

/// What the mouth should do over a stretch of speech, every 10 ms: how open
/// (0...1) and what shape (-1 round ... +1 wide). All the sound analysis for both
/// mouths happens here; the robot only eases toward the result. See docs/voice.md.
///
/// - Opening: RMS over 20 ms mapped from a noise floor to a full level, with a
///   quick attack, a short hold at each peak and a slower release, so it follows
///   syllables rather than every sample. A dip well below the recent peak closes
///   it quickly, standing in for the lips meeting on consonants.
/// - Shape: how bright the sound is, measured cheaply as the energy of the
///   signal's first difference against its own energy. Dark vowels ("oo") read
///   round, bright sounds ("ee", "s") read wide.
/// - Pauses: within speech the lips stay parted; after 400 ms of silence the
///   mouth returns to its resting line. It never disappears.
struct MouthEnvelope {
    struct Frame: Equatable {
        var open: Double
        var shape: Double
        static let rest = Frame(open: 0, shape: 0)
    }

    static let hop = 0.010
    static let window = 0.020
    // Tuned on a macOS "Daniel" recording (2026-09-17): speech RMS runs about
    // -23 dBFS median and -15 at the 90th percentile.
    static let floorDB = -45.0
    static let fullDB = -10.0
    static let attack = 0.040
    static let release = 0.150
    static let peakHold = 0.070
    /// A dip below this share of the recent peak, lasting `dipTime`, closes quickly.
    static let dipRatio = 0.6
    static let dipTime = 0.040
    static let dipRelease = 0.040
    /// Lips parted through pauses shorter than `pauseHold`.
    static let partedOpen = 0.18
    static let pauseHold = 0.400
    // Brightness: the log of diff-RMS / RMS. Measured on the same voice: "oo"
    // about -2.4, ordinary vowels about -1.3, "ee" and "s" toward 0 and above.
    static let neutralBrightness = -1.3
    static let roundSpan = 1.1
    static let wideSpan = 1.3
    static let shapeTime = 0.060

    let frames: [Frame]
    var duration: Double { Double(frames.count) * Self.hop }

    init(frames: [Frame]) { self.frames = frames }

    /// Shape from the brightness measure, -1...1.
    static func shape(brightness: Double) -> Double {
        let offset = brightness - neutralBrightness
        return offset >= 0 ? min(1, offset / wideSpan) : max(-1, offset / roundSpan)
    }

    /// Analyses mono samples.
    init(samples: [Float], sampleRate: Double) {
        let hop = max(1, Int(sampleRate * Self.hop))
        let window = max(2, Int(sampleRate * Self.window))
        let rise = 1 - exp(-Self.hop / Self.attack)
        let fall = 1 - exp(-Self.hop / Self.release)
        let fastFall = 1 - exp(-Self.hop / Self.dipRelease)
        let shapeStep = 1 - exp(-Self.hop / Self.shapeTime)
        let peakDecay = exp(-Self.hop / 0.3)
        var out: [Frame] = []
        out.reserveCapacity(samples.count / hop + 1)
        var level = 0.0, peak = 0.0, shape = 0.0
        var holdLeft = 0.0, dipFor = 0.0
        var sinceVoiced = Double.infinity
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var energy = 0.0, diffEnergy = 0.0
            for i in start..<end {
                let x = Double(samples[i])
                energy += x * x
                if i > start { let d = x - Double(samples[i - 1]); diffEnergy += d * d }
            }
            let count = Double(max(1, end - start))
            let rms = (energy / count).squareRoot()
            let db = 20 * log10(max(rms, 1e-9))
            let raw = min(max((db - Self.floorDB) / (Self.fullDB - Self.floorDB), 0), 1)
            let voiced = raw > 0

            peak = max(raw, peak * peakDecay)
            dipFor = voiced && raw < Self.dipRatio * peak ? dipFor + Self.hop : 0
            if raw > level {
                level += (raw - level) * rise
                holdLeft = Self.peakHold
            } else if holdLeft > 0 {
                holdLeft -= Self.hop
            } else {
                level += (raw - level) * (dipFor >= Self.dipTime ? fastFall : fall)
            }

            sinceVoiced = voiced ? 0 : sinceVoiced + Self.hop
            let inSpeech = sinceVoiced < Self.pauseHold
            if voiced, rms > 0 {
                let brightness = log(max((diffEnergy / max(1, count - 1)).squareRoot() / rms, 1e-6))
                shape += (Self.shape(brightness: brightness) - shape) * shapeStep
            } else if !inSpeech {
                shape += (0 - shape) * shapeStep
            }
            let open = inSpeech ? max(level, Self.partedOpen) : level
            out.append(Frame(open: min(max(open, 0), 1), shape: min(max(shape, -1), 1)))
            start += hop
        }
        frames = out
    }

    /// The first channel of an audio file.
    init(file: AVAudioFile) throws {
        let length = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        file.framePosition = 0
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        self.init(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                  sampleRate: file.processingFormat.sampleRate)
    }

    /// The mouth at a time in seconds; the resting line before and after.
    func frame(at seconds: Double) -> Frame {
        guard seconds >= 0 else { return .rest }
        let index = Int(seconds / Self.hop)
        return index < frames.count ? frames[index] : .rest
    }
}
