import Foundation

/// What a conversation is doing, and why it stopped.
///
/// Pure and testable with no network and no sound card: the app's Talk control,
/// its subtitle and its inspector all read this, so the states are named for
/// what a person would say is happening, not for the protocol underneath.
enum VoiceState: Equatable {
    case off
    case connecting
    /// Connected. Full duplex means it is always listening, including while it
    /// speaks -- `speaking` says only whether sound is coming back right now.
    case listening
    case speaking
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .connecting, .listening, .speaking: return true
        case .off, .failed: return false
        }
    }
}

/// Why a conversation ended, in the words the window subtitle will use.
enum VoiceEnding: Equatable {
    case stoppedByOwner
    case idle(TimeInterval)
    case dailyLimit
    case robotAsleep
    case dropped(String)
    case refused(String)

    var summary: String {
        switch self {
        case .stoppedByOwner: return "Conversation ended."
        case .idle(let seconds):
            return "Nobody spoke for \(Int(seconds / 60)) minutes, so the conversation ended."
        case .dailyLimit: return "That is today's voice limit. It resets tomorrow."
        case .robotAsleep: return "Stanbot went to sleep, so the conversation ended."
        case .dropped(let why): return "The conversation dropped: \(why)"
        case .refused(let why): return why
        }
    }
}

/// The rules a conversation runs by, kept away from the audio and the socket so
/// they can be tested exactly. Nothing here reconnects on its own: a dropped
/// conversation ends and says so, matching how sessions behave everywhere else
/// in this app.
struct VoicePolicy: Equatable {
    /// Nobody has said anything for this long: stop rather than bill for silence.
    var idleStop: TimeInterval = 180
    /// The most voice the owner wants to spend in a day.
    var dailyLimit: TimeInterval = 3_600
    /// Live will end it at two hours anyway (measured); this is far tighter.
    var sessionLimit: TimeInterval = Live.sessionLimit

    /// Whether a conversation may start, and if not, the reason in the words
    /// the subtitle will use.
    func refusal(usedToday: TimeInterval, hasKey: Bool, audioRoute: String?, robotAsleep: Bool) -> VoiceEnding? {
        if !hasKey { return .refused("Talking needs an OpenAI key. Add it in Settings.") }
        if robotAsleep { return .robotAsleep }
        guard let audioRoute, !audioRoute.isEmpty else {
            return .refused("No microphone and speakers for the conversation.")
        }
        if usedToday >= dailyLimit { return .dailyLimit }
        return nil
    }

    /// Whether a running conversation should now end, given when someone last
    /// spoke -- either side, because full duplex means Stanbot talking is also
    /// the conversation being alive.
    func ending(startedAt: Date, lastVoiceAt: Date, usedToday: TimeInterval, now: Date) -> VoiceEnding? {
        if usedToday >= dailyLimit { return .dailyLimit }
        let silence = now.timeIntervalSince(lastVoiceAt)
        if silence >= idleStop { return .idle(silence) }
        if now.timeIntervalSince(startedAt) >= sessionLimit {
            return .dropped("it reached the two hour session limit")
        }
        return nil
    }
}

/// The conversation itself: a state machine fed by protocol events, with no
/// opinion about how bytes reach it. `VoiceSessionTests` drives it with a fake
/// stream of `Live.Event`s.
struct VoiceSession {
    private(set) var state: VoiceState = .off
    private(set) var transcript: [(speaker: String, text: String)] = []
    private(set) var secondsBilled = 0
    private(set) var buffer = PlayoutBuffer()
    private(set) var lastVoiceAt: Date
    private(set) var startedAt: Date
    /// The mouth is driven from the audio this session plays, and must close on
    /// every ending -- including the ugly ones.
    private(set) var mouthShouldClose = false

    let policy: VoicePolicy

    init(policy: VoicePolicy = VoicePolicy(), now: Date = Date()) {
        self.policy = policy
        self.startedAt = now
        self.lastVoiceAt = now
    }

    mutating func begin(now: Date = Date()) {
        state = .connecting
        startedAt = now
        lastVoiceAt = now
        mouthShouldClose = false
    }

    mutating func receive(_ event: Live.Event, now: Date = Date()) {
        switch event {
        case .started:
            state = .listening
            lastVoiceAt = now
        case .outputAudio(let pcm):
            buffer.append(pcm)
            state = .speaking
            lastVoiceAt = now
        case .outputTranscript(let text) where !text.isEmpty:
            append("Stanbot", text)
            lastVoiceAt = now
        case .inputTranscript(let text) where !text.isEmpty:
            append("You", text)
            lastVoiceAt = now
            // Someone talked over it. Nothing announces that, so this is the
            // only notice there is -- and the queued speech goes at once
            // rather than finishing a sentence over them.
            if state == .speaking { buffer.flush() }
        case .usage(let seconds):
            secondsBilled = max(secondsBilled, seconds)
        case .closed(let why):
            end(.dropped(why))
        case .failed(let message):
            end(.dropped(message))
        case .outputTranscript, .inputTranscript, .other:
            break
        }
    }

    /// Audio stopped arriving: back to listening, which is what full duplex
    /// means -- it never stopped listening in the first place.
    mutating func finishedSpeaking() {
        if state == .speaking { state = .listening }
    }

    mutating func end(_ ending: VoiceEnding) {
        buffer.flush()
        mouthShouldClose = true
        state = ending == .stoppedByOwner ? .off : .failed(ending.summary)
        if case .idle = ending { state = .off }
        if ending == .dailyLimit || ending == .robotAsleep { state = .off }
    }

    private mutating func append(_ speaker: String, _ text: String) {
        if let last = transcript.last, last.speaker == speaker {
            transcript[transcript.count - 1].text += text
        } else {
            transcript.append((speaker, text))
        }
    }
}

// MARK: - What the app shows

/// The Talk control's appearance and words, kept here so they can be checked
/// without building a window. The control mirrors Follow deliberately: the same
/// shape of thing (a standing intent you turn on and off), so it should look and
/// read like one.
enum VoiceControl {
    static func title(_ state: VoiceState) -> String {
        switch state {
        case .off, .failed: return "Talk"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        }
    }

    /// `waveform` when off, filled while a conversation runs -- the same
    /// language the Follow toggle uses for on and off.
    static func symbol(_ state: VoiceState) -> String {
        state.isRunning ? "waveform.circle.fill" : "waveform"
    }

    /// Whether the icon should pulse: only while sound is actually moving, as
    /// Follow pulses only while a session is really running.
    static func pulses(_ state: VoiceState) -> Bool { state == .speaking }

    /// The help text. A refusal says why in the same sentence the subtitle
    /// would, so the reason is never hidden behind a disabled control.
    static func help(_ state: VoiceState, refusal: VoiceEnding?) -> String {
        if let refusal { return refusal.summary }
        switch state {
        case .off: return "Talk with Stanbot"
        case .connecting: return "Opening the conversation…"
        case .listening: return "Stanbot is listening. Click to end the conversation."
        case .speaking: return "Stanbot is speaking. Talk over it to interrupt, or click to end."
        case .failed(let why): return why
        }
    }

    /// Minutes for the inspector, from the server's own count rather than a
    /// stopwatch on this side.
    static func minutes(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : String(format: "%.0f min", Double(seconds) / 60)
    }
}
