import Foundation

/// How much of Stanbot's speech is allowed to be waiting to be heard.
///
/// **This is the interruption mechanism, not a performance tweak.** The Live
/// service has no cancel, cleared or flush event -- verified on 2026-09-17 by
/// `companion/voice-spike`, which talked over a reply and watched it cut off
/// mid-sentence with nothing announcing it. So when the owner interrupts, the
/// only speech they will still hear is whatever this buffer is holding. At
/// `depth` it is a fifth of a second; at two seconds it would be two seconds of
/// Stanbot talking over a person who has asked it to stop, which is the
/// difference between a presence and a nuisance.
///
/// Pure, so the arithmetic is tested without a sound card.
struct PlayoutBuffer {
    /// 200 ms, the figure docs/voice.md set as a pass criterion for adopting
    /// Live at all.
    static let depth: TimeInterval = 0.2
    static let bytesPerSecond = Live.sampleRate * 2   // 16-bit mono

    private(set) var queued = Data()
    private(set) var dropped = 0

    var seconds: TimeInterval { Double(queued.count) / Double(Self.bytesPerSecond) }
    var isOverfull: Bool { seconds > Self.depth }

    /// Accept audio, and drop from the FRONT if that put it over depth. The
    /// front is the oldest sound: keeping it would mean playing yesterday's
    /// sentence before today's, and arriving late at the new one.
    mutating func append(_ pcm: Data) {
        queued.append(pcm)
        let limit = Int(Self.depth * Double(Self.bytesPerSecond))
        if queued.count > limit {
            let excess = queued.count - limit
            queued.removeFirst(excess)
            dropped += excess
        }
    }

    /// Hand the player what it asked for, in order.
    mutating func take(_ bytes: Int) -> Data {
        let count = min(bytes, queued.count)
        guard count > 0 else { return Data() }
        let chunk = queued.prefix(count)
        queued.removeFirst(count)
        return Data(chunk)
    }

    /// Everything Stanbot has not yet said, thrown away. Every ending uses this
    /// -- stopping, failing, the robot going to sleep -- because the alternative
    /// is a voice carrying on after the thing it belongs to has gone.
    mutating func flush() {
        dropped += queued.count
        queued.removeAll(keepingCapacity: true)
    }
}
