import Foundation

/// The socket to the Live service, and nothing else: it knows how to open a
/// connection, send audio, and hand back parsed events. It holds no opinion
/// about conversations -- `VoiceSession` has those -- so it can be pointed at a
/// fake server in tests and at OpenAI in life.
///
/// The shapes it sends were verified against the service on 2026-09-17
/// (`companion/voice-spike`). Anything that looks wrong here should be checked
/// against `Live`, and against the service itself, before being "fixed".
protocol VoiceTransportDelegate: AnyObject {
    func transport(_ transport: VoiceTransport, received event: Live.Event)
    /// The socket itself failed -- not the service reporting a problem, which
    /// arrives as `Live.Event.failed`.
    func transport(_ transport: VoiceTransport, failed reason: String)
}

final class VoiceTransport: NSObject {
    weak var delegate: VoiceTransportDelegate?
    private(set) var isOpen = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let endpoint: URL
    private let key: () -> String?
    /// Everything the delegate hears arrives here, so a caller on the main
    /// actor is not surprised by a socket thread.
    private let deliver: (@escaping () -> Void) -> Void

    init(endpoint: URL = Live.endpoint,
         key: @escaping () -> String?,
         deliver: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }) {
        self.endpoint = endpoint
        self.key = key
        self.deliver = deliver
        super.init()
    }

    /// Open the socket and send `session.start`. A missing key is a failure with
    /// a sentence, not a silent no-op: it is the most likely reason this never
    /// works on a fresh machine.
    func open(instructions: String, voice: String) {
        guard task == nil else { return }
        guard let key = key(), !key.isEmpty else {
            report(failed: "No OpenAI key. Add OPENAI_API_KEY_STANBOT with Add Secret.")
            return
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive()
        send(Live.startMessage(instructions: instructions, voice: voice))
    }

    func send(audio pcm: Data) {
        guard !pcm.isEmpty else { return }
        send(Live.audioMessage(pcm))
    }

    /// Closing is always allowed and never reported as a failure: every ending
    /// closes the socket, including the ugly ones, and a "failure" arriving
    /// after the owner pressed stop would be a lie.
    func close() {
        isOpen = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.report(failed: error.localizedDescription)
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // A cancelled socket is this side closing, not a fault.
                if self.task != nil { self.report(failed: error.localizedDescription) }
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = Live.parse(text) else { return }
        deliver { [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, received: event)
        }
    }

    private func report(failed reason: String) {
        deliver { [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, failed: reason)
        }
    }
}

extension VoiceTransport: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        isOpen = true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isOpen = false
        guard task != nil else { return }   // we closed it
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "the connection closed (\(closeCode.rawValue))"
        report(failed: why)
    }
}
