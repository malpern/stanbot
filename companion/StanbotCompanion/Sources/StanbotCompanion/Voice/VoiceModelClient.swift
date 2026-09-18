import Foundation

/// The wire protocol for OpenAI's Live API, as the robot's companion needs it.
///
/// Every shape here was **verified against the live service** by
/// `companion/voice-spike` on 2026-09-17, after four guesses in `docs/voice.md`
/// turned out to be wrong. Do not "correct" it back toward the documentation
/// without running the spike again: the server rejects a wrong session shape
/// before the session starts, so checking costs nothing.
enum Live {
    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    static let model = "gpt-live-1"
    /// Mono signed 16-bit little-endian, 24 kHz. Both directions.
    static let sampleRate = 24_000

    /// The voices Live offers. `cedar`, which the plan chose, is not among them;
    /// `marin` is the service default and `vesper` was confirmed working.
    static let voices = ["marin", "vesper", "quartz", "ripple", "willow", "stone",
                         "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]
    static let defaultVoice = "vesper"

    /// A session may run two hours (`expires_at`, measured). The app's own idle
    /// stop and daily limit are far tighter, so this never binds in practice.
    static let sessionLimit: TimeInterval = 7_200

    /// The first message. Minimal on purpose: the server echoes the whole
    /// session object back in `session.started`, and anything it did not ask
    /// for is an error that ends the session before it begins.
    static func startMessage(instructions: String, voice: String) -> [String: Any] {
        [
            "type": "session.start",
            "session": [
                "model": model,
                "instructions": instructions,
                // NOT session.voice, and NOT an audio.input/audio.output format
                // pair: both were rejected as unknown parameters.
                "audio": ["format": ["type": "audio/pcm", "rate": sampleRate],
                          "output": ["voice": voice]],
            ],
        ]
    }

    static func audioMessage(_ pcm: Data) -> [String: Any] {
        ["type": "session.input_audio.append", "audio": pcm.base64EncodedString()]
    }

    /// What the service sends. There is deliberately no "reply finished" case:
    /// the service does not emit one, which is the fact the whole playback
    /// design turns on.
    enum Event: Equatable {
        case started(sessionID: String, voice: String, expiresAt: Date?)
        case outputAudio(Data)
        case outputTranscript(String)
        case inputTranscript(String)
        case usage(seconds: Int)
        case closed(String)
        case failed(String)
        case other(String)
    }

    static func parse(_ text: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "session.started":
            let session = object["session"] as? [String: Any] ?? [:]
            let audio = session["audio"] as? [String: Any] ?? [:]
            let output = audio["output"] as? [String: Any] ?? [:]
            let expiry = (session["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return .started(sessionID: session["id"] as? String ?? "",
                            voice: output["voice"] as? String ?? "",
                            expiresAt: expiry)
        case "session.output_audio.delta":
            // The spike saw it under "audio"; accept "delta" too rather than go
            // deaf if the service renames it.
            let base64 = (object["audio"] as? String) ?? (object["delta"] as? String) ?? ""
            guard let pcm = Data(base64Encoded: base64) else { return .other(type) }
            return .outputAudio(pcm)
        case "session.output_transcript.delta":
            return .outputTranscript((object["delta"] as? String) ?? (object["text"] as? String) ?? "")
        case "session.input_transcript.delta":
            return .inputTranscript((object["delta"] as? String) ?? (object["text"] as? String) ?? "")
        case "session.usage.updated":
            let usage = object["usage"] as? [String: Any] ?? [:]
            return .usage(seconds: usage["seconds"] as? Int ?? 0)
        case "session.closed":
            return .closed(text)
        case "error", "session.error":
            let error = object["error"] as? [String: Any] ?? [:]
            return .failed(error["message"] as? String ?? text)
        default:
            return .other(type)
        }
    }
}
