import Network
import XCTest
@testable import StanbotCompanion

/// A WebSocket server standing in for OpenAI's Live service: it accepts the
/// connection, records what the app sent, and replies with the events the real
/// service sends. Like `FakeRobot`, it is a real socket rather than a stubbed
/// object, so the transport's own framing and threading are exercised.
private final class FakeLiveService: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-live")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var messages: [String] = []
    /// Sent to the client as soon as it says session.start.
    var replies: [String] = []
    private(set) var authorization: String?

    init() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.connection = connection; self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        // Wait for a real port before anyone asks for the URL: on .any the
        // listener reports none until it is ready, and dialling port 0 fails in
        // a way that looks like the transport's fault.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)")! }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return messages }

    func stop() {
        listener.cancel()
        lock.lock(); connection?.cancel(); lock.unlock()
    }

    /// Push an event to the client at any time, as the service does.
    func push(_ text: String) {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "push", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                self.lock.lock(); self.messages.append(text); self.lock.unlock()
                if text.contains("session.start") { self.replies.forEach(self.push) }
            }
            if error == nil { self.receive(on: connection) }
        }
    }
}

private final class Recorder: VoiceTransportDelegate {
    var events: [Live.Event] = []
    var failures: [String] = []
    func transport(_ transport: VoiceTransport, received event: Live.Event) { events.append(event) }
    func transport(_ transport: VoiceTransport, failed reason: String) { failures.append(reason) }
}

final class VoiceTransportTests: XCTestCase {
    private func wait(upTo seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testItOpensWithTheSessionShapeTheServiceAccepts() throws {
        let service = try FakeLiveService()
        defer { service.stop() }
        let recorder = Recorder()
        let transport = VoiceTransport(endpoint: service.url, key: { "test-key" },
                                       deliver: { $0() })
        transport.delegate = recorder
        transport.open(instructions: "Be brief.", voice: "vesper")
        defer { transport.close() }

        wait(upTo: 5) { !service.sent.isEmpty }
        let first = try XCTUnwrap(service.sent.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "session.start")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["model"] as? String, "gpt-live-1")
        XCTAssertNil(session["voice"], "the service rejects session.voice")
    }

    func testItDeliversTheEventsTheServiceSends() throws {
        let service = try FakeLiveService()
        defer { service.stop() }
        let pcm = Data([9, 8, 7, 6])
        service.replies = [
            #"{"type":"session.started","session":{"id":"live_x","audio":{"output":{"voice":"vesper"}}}}"#,
            #"{"type":"session.output_audio.delta","audio":"\#(pcm.base64EncodedString())"}"#,
            #"{"type":"session.output_transcript.delta","delta":"hello"}"#,
        ]
        let recorder = Recorder()
        let transport = VoiceTransport(endpoint: service.url, key: { "test-key" }, deliver: { $0() })
        transport.delegate = recorder
        transport.open(instructions: "Be brief.", voice: "vesper")
        defer { transport.close() }

        wait(upTo: 5) { recorder.events.count >= 3 }
        XCTAssertEqual(recorder.events.count, 3)
        XCTAssertEqual(recorder.events[1], .outputAudio(pcm), "audio must survive base64 intact")
        XCTAssertEqual(recorder.events[2], .outputTranscript("hello"))
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func testAudioGoesUpAsTheServiceExpects() throws {
        let service = try FakeLiveService()
        defer { service.stop() }
        let transport = VoiceTransport(endpoint: service.url, key: { "test-key" }, deliver: { $0() })
        transport.delegate = Recorder()
        transport.open(instructions: "Be brief.", voice: "vesper")
        defer { transport.close() }
        wait(upTo: 5) { !service.sent.isEmpty }

        transport.send(audio: Data([1, 2, 3, 4]))
        wait(upTo: 5) { service.sent.count >= 2 }
        let audio = try XCTUnwrap(service.sent.last)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(audio.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "session.input_audio.append")
        XCTAssertEqual(Data(base64Encoded: object["audio"] as? String ?? ""), Data([1, 2, 3, 4]))

        transport.send(audio: Data())   // silence is not a message
        XCTAssertEqual(service.sent.count, 2)
    }

    /// The likeliest reason this never works on a fresh machine, and it must say
    /// so rather than fail silently.
    func testNoKeyIsASentenceNotSilence() {
        let recorder = Recorder()
        let transport = VoiceTransport(endpoint: URL(string: "ws://127.0.0.1:1")!, key: { nil },
                                       deliver: { $0() })
        transport.delegate = recorder
        transport.open(instructions: "x", voice: "vesper")
        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertTrue(recorder.failures[0].contains("OPENAI_API_KEY_STANBOT"))
    }

    /// Closing is the owner's doing. It must never arrive as a failure, or every
    /// ended conversation would report an error it did not have.
    func testClosingIsNotAFailure() throws {
        let service = try FakeLiveService()
        defer { service.stop() }
        let recorder = Recorder()
        let transport = VoiceTransport(endpoint: service.url, key: { "test-key" }, deliver: { $0() })
        transport.delegate = recorder
        transport.open(instructions: "x", voice: "vesper")
        wait(upTo: 5) { !service.sent.isEmpty }
        transport.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(recorder.failures.isEmpty, "stopping is not an error: \(recorder.failures)")
    }

    /// An unreachable service is a failure with the system's own words.
    func testAnUnreachableServiceIsReported() {
        let recorder = Recorder()
        let transport = VoiceTransport(endpoint: URL(string: "ws://127.0.0.1:1")!, key: { "k" },
                                       deliver: { $0() })
        transport.delegate = recorder
        transport.open(instructions: "x", voice: "vesper")
        wait(upTo: 5) { !recorder.failures.isEmpty }
        XCTAssertFalse(recorder.failures.isEmpty)
    }
}
