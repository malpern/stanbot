// A command-line client for OpenAI's Live API (gpt-live-1), to settle the facts
// docs/voice.md could not verify before anything is built on them: the endpoint,
// the audio format, what the server actually sends, how long a session may run,
// and -- the one that decides whether Live is usable at all -- how a client
// learns it has been interrupted and should stop playing queued audio.
//
// Headless on purpose. It speaks by feeding a file of samples (say(1) via
// afconvert) and listens by writing what comes back to a WAV, so it can run
// with nobody there and no speakers making noise at night.
//
//   swiftc -O live_spike.swift -o live_spike
//   ./live_spike --seconds 45 --say "Hello Stanbot, can you hear me?"
//   ./live_spike --dry-run          # plumbing only, no network, no spend
//
// It never prints the key. It stops at --seconds and at the budget in
// voice-spend.json, whichever comes first, and writes everything it learned to
// live-spike-report.json.
import Foundation

// MARK: - Cost

/// Live is billed per minute ($0.05) plus whatever the delegated model costs.
/// The owner set a ceiling of $5 for this work, so the ledger is a file, not a
/// good intention: every run adds to it and refuses to start past it.
struct Ledger: Codable {
    var capUSD: Double = 5.0
    var spentUSD: Double = 0
    var runs: Int = 0
    var secondsConnected: Double = 0

    static let perMinute = 0.05
    static let path = URL(fileURLWithPath: "voice-spend.json")

    static func load() -> Ledger {
        guard let data = try? Data(contentsOf: path),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Ledger.path)
    }
    /// What a run of this length would cost, charged whole-minute-pessimistically.
    static func estimate(seconds: Double) -> Double { (seconds / 60.0) * perMinute }
    var remainingUSD: Double { max(0, capUSD - spentUSD) }
}

// MARK: - Audio

enum Audio {
    /// Speech as the model wants it: mono signed 16-bit little-endian PCM at
    /// 24 kHz. `say` writes AIFF at its own rate, so afconvert does the work.
    static func speak(_ text: String) throws -> Data {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("spike-say.aiff")
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("spike-say.raw")
        try run("/usr/bin/say", ["-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@24000", "-c", "1", aiff.path, raw.path])
        let caf = try Data(contentsOf: raw)
        return stripCAF(caf)
    }

    /// The samples out of a CAF, without parsing the whole format: find the
    /// `data` chunk, skip its 4-byte edit count, take the rest.
    static func stripCAF(_ caf: Data) -> Data {
        let marker = Array("data".utf8)
        let bytes = [UInt8](caf)
        var index = 8
        while index + 12 <= bytes.count {
            let type = Array(bytes[index..<(index + 4)])
            var size: Int64 = 0
            for byte in bytes[(index + 4)..<(index + 12)] { size = (size << 8) | Int64(byte) }
            let body = index + 12
            if type == marker {
                let start = body + 4                                   // mEditCount
                let end = size > 0 ? min(body + Int(size), bytes.count) : bytes.count
                return start < end ? Data(bytes[start..<end]) : Data()
            }
            if size <= 0 { break }
            index = body + Int(size)
        }
        return Data()
    }

    /// A WAV around raw 24 kHz mono 16-bit samples, so the reply can be listened
    /// to later without any of this having made a sound tonight.
    static func wav(_ pcm: Data, rate: Int = 24_000) -> Data {
        var out = Data()
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        func u16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(pcm.count); out.append(pcm)
        return out
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "spike", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
        }
    }
}

// MARK: - What the run learned

/// The report is the point of the exercise: docs/voice.md lists facts it could
/// not verify, and this is what replaces them. Written whether the run succeeds
/// or fails, because a failure is also an answer.
struct Report: Codable {
    var endpoint = ""
    var model = ""
    var connected = false
    var httpStatus: Int? = nil
    var failure: String? = nil
    var secondsConnected: Double = 0
    var eventsSeen: [String: Int] = [:]
    var firstEventOrder: [String] = []
    var inputTranscript = ""
    var outputTranscript = ""
    var outputAudioBytes = 0
    var outputAudioSeconds: Double = 0
    var firstAudioAfterMs: Double? = nil
    /// The question that decides whether Live is usable: what arrives when the
    /// person talks over it. Every event seen after the interrupting audio was
    /// sent, so the answer is in the record even if nothing is named "cancel".
    var eventsAfterBargeIn: [String] = []
    var sessionObjectFromServer: String? = nil
    /// expires_at minus now: the session length limit, which the docs do not state.
    var sessionSecondsAllowed: Double? = nil
    var lastUsage: String? = nil
    var notes: [String] = []
    var estimatedCostUSD: Double = 0
}

// MARK: - The client

final class LiveSpike: NSObject, URLSessionWebSocketDelegate {
    private let key: String
    private let model: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let started = Date()
    private var connectedAt: Date?
    private var report = Report()
    private var audioOut = Data()
    private var bargeInAt: Date?
    private let finished = DispatchSemaphore(value: 0)
    private var closing = false

    private let voice: String
    init(key: String, model: String, voice: String) {
        self.key = key
        self.model = model
        self.voice = voice
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func run(seconds: Double, saying text: String, bargeIn: String?) -> (Report, Data) {
        report.model = model
        report.endpoint = "wss://api.openai.com/v1/live/sessions"
        var request = URLRequest(url: URL(string: report.endpoint)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        task?.resume()
        receive()

        // Everything after this is on a clock: the run must end even if the
        // server says nothing at all, or a spike becomes an open tab on a
        // metered API overnight.
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop("time limit") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.send(["type": "session.start", "session": [
                "model": self.model,
                "instructions": "You are Stanbot, a small desk robot. Be brief and plain: a sentence or two.",
                // The shape the server itself echoed back on 2026-09-17.
                // NOT session.voice, and NOT audio.input/audio.output.format:
                // both were rejected as unknown parameters.
                "audio": ["format": ["type": "audio/pcm", "rate": 24_000],
                          "output": ["voice": voice]],
            ]])
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            if let pcm = try? Audio.speak(text) { self.sendAudio(pcm, note: "opening line, \(pcm.count) bytes") }
        }
        if let bargeIn {
            // Talk over it while it is most likely still speaking. What comes
            // back in the next moments IS the interruption answer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 12.0) { [weak self] in
                guard let self else { return }
                self.bargeInAt = Date()
                self.report.notes.append("barge-in audio sent at 12 s")
                if let pcm = try? Audio.speak(bargeIn) { self.sendAudio(pcm, note: "barge-in") }
            }
        }
        _ = finished.wait(timeout: .now() + seconds + 15)
        report.secondsConnected = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        report.outputAudioBytes = audioOut.count
        report.outputAudioSeconds = Double(audioOut.count) / 2.0 / 24_000.0
        report.estimatedCostUSD = Ledger.estimate(seconds: report.secondsConnected)
        return (report, audioOut)
    }

    /// Audio goes in chunks about a fifth of a second long: the model expects a
    /// stream, not a file, and a single enormous frame is the easiest way to
    /// look nothing like a person talking.
    private func sendAudio(_ pcm: Data, note: String) {
        let chunk = 24_000 / 5 * 2
        var offset = 0
        var frames = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            let slice = pcm.subdata(in: offset..<end)
            send(["type": "session.input_audio.append", "audio": slice.base64EncodedString()])
            offset = end
            frames += 1
            Thread.sleep(forTimeInterval: 0.2)   // real time, as a speaker would
        }
        report.notes.append("\(note): \(frames) frames")
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.report.notes.append("send failed: \(error.localizedDescription)") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if !self.closing { self.report.failure = error.localizedDescription }
                self.stop("receive failed")
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                if case .data(let data) = message { self.handle(String(decoding: data, as: UTF8.self)) }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }
        report.eventsSeen[type, default: 0] += 1
        if !report.firstEventOrder.contains(type) { report.firstEventOrder.append(type) }
        if let bargeInAt, Date() > bargeInAt, !report.eventsAfterBargeIn.contains(type) {
            report.eventsAfterBargeIn.append(type)
        }
        switch type {
        case "session.started":
            connectedAt = Date()
            report.connected = true
            if let session = object["session"],
               let data = try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys]) {
                report.sessionObjectFromServer = String(decoding: data, as: UTF8.self)
            }
            if let session = object["session"] as? [String: Any], let expires = session["expires_at"] as? Double {
                report.sessionSecondsAllowed = expires - Date().timeIntervalSince1970
            }
        case "session.output_audio.delta":
            if let base64 = (object["audio"] ?? object["delta"]) as? String, let pcm = Data(base64Encoded: base64) {
                if report.firstAudioAfterMs == nil, let connectedAt {
                    report.firstAudioAfterMs = Date().timeIntervalSince(connectedAt) * 1000
                }
                audioOut.append(pcm)
            }
        case "session.output_transcript.delta":
            report.outputTranscript += (object["delta"] as? String) ?? (object["text"] as? String) ?? ""
        case "session.input_transcript.delta":
            report.inputTranscript += (object["delta"] as? String) ?? (object["text"] as? String) ?? ""
        case "session.usage.updated":
            if let usage = object["usage"],
               let data = try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys]) {
                report.lastUsage = String(decoding: data, as: UTF8.self)
            }
        case "session.closed":
            report.notes.append("server closed: \(text.prefix(300))")
            stop("server closed")
        case "error", "session.error":
            report.failure = String(text.prefix(400))
            stop("server error")
        default:
            break
        }
    }

    private func stop(_ why: String) {
        guard !closing else { return }
        closing = true
        report.notes.append("stopped: \(why)")
        task?.cancel(with: .goingAway, reason: nil)
        finished.signal()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        report.notes.append("socket open")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response as? HTTPURLResponse { report.httpStatus = response.statusCode }
        if let error, report.failure == nil, !closing { report.failure = error.localizedDescription }
        stop("socket closed")
    }
}

// MARK: - Entry

func loadKey() -> String? {
    // The same way every other tool here reads a secret, and never printed.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "sops -d ~/dotfiles/secrets.env 2>/dev/null | grep '^OPENAI_API_KEY_STANBOT=' | cut -d= -f2-"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
}

var seconds = 45.0
var text = "Hello Stanbot. In one short sentence, what are you?"
var bargeIn: String? = "Sorry, stop for a moment."
var dryRun = false
var model = "gpt-live-1"
var voice = "vesper"
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--seconds": seconds = Double(arguments.removeFirst()) ?? 45
    case "--say": text = arguments.removeFirst()
    case "--no-barge-in": bargeIn = nil
    case "--barge-in": bargeIn = arguments.removeFirst()
    case "--model": model = arguments.removeFirst()
    case "--voice": voice = arguments.removeFirst()
    case "--dry-run": dryRun = true
    default: FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8)); exit(2)
    }
}

if dryRun {
    // Everything except the network and the money: proves say/afconvert, the
    // CAF strip and the WAV writer before a paid session depends on them.
    guard let pcm = try? Audio.speak(text), !pcm.isEmpty else {
        print("dry run FAILED: no samples from say/afconvert"); exit(1)
    }
    let wav = Audio.wav(pcm)
    try? wav.write(to: URL(fileURLWithPath: "dry-run-input.wav"))
    let seconds = Double(pcm.count) / 2.0 / 24_000.0
    print(String(format: "dry run ok: %d bytes of 24 kHz mono PCM, %.1f s, wrote dry-run-input.wav", pcm.count, seconds))
    exit(0)
}

var ledger = Ledger.load()
let estimate = Ledger.estimate(seconds: seconds)
if ledger.spentUSD + estimate > ledger.capUSD {
    print(String(format: "refusing: this run would cost about $%.3f and $%.2f of the $%.2f cap is spent",
                 estimate, ledger.spentUSD, ledger.capUSD))
    exit(3)
}
guard let key = loadKey() else { print("no OPENAI_API_KEY_STANBOT in sops"); exit(1) }

let spike = LiveSpike(key: key, model: model, voice: voice)
let (report, audio) = spike.run(seconds: seconds, saying: text, bargeIn: bargeIn)

ledger.runs += 1
ledger.secondsConnected += report.secondsConnected
ledger.spentUSD += report.estimatedCostUSD
ledger.save()

if !audio.isEmpty { try? Audio.wav(audio).write(to: URL(fileURLWithPath: "live-reply.wav")) }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? encoder.encode(report) {
    try? data.write(to: URL(fileURLWithPath: "live-spike-report.json"))
    print(String(decoding: data, as: UTF8.self))
}
print(String(format: "\n$%.3f this run, $%.3f of $%.2f spent overall",
             report.estimatedCostUSD, ledger.spentUSD, ledger.capUSD))
exit(report.connected ? 0 : 1)
