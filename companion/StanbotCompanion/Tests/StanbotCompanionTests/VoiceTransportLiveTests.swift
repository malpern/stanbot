import XCTest
@testable import StanbotCompanion

/// The transport against the real service. Skipped unless
/// `STANBOT_LIVE_TEST=1`, because it costs money and needs a key: a fake server
/// can only prove the app is consistent with its own assumptions, and it was
/// exactly those assumptions the service rejected four times on 2026-09-17.
///
///     STANBOT_LIVE_TEST=1 swift test --filter VoiceTransportLiveTests
final class VoiceTransportLiveTests: XCTestCase {
    private final class Recorder: VoiceTransportDelegate {
        var events: [Live.Event] = []
        var failures: [String] = []
        func transport(_ transport: VoiceTransport, received event: Live.Event) { events.append(event) }
        func transport(_ transport: VoiceTransport, failed reason: String) { failures.append(reason) }
    }

    private func key() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sops -d ~/dotfiles/secrets.env 2>/dev/null | grep '^OPENAI_API_KEY_STANBOT=' | cut -d= -f2-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Opens a session and closes it as soon as the service confirms. A few
    /// seconds, a fraction of a cent, and it proves the one thing the fake
    /// cannot: that the service still accepts the session shape this app sends.
    func testTheRealServiceAcceptsOurSessionShape() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STANBOT_LIVE_TEST"] == "1",
                          "costs money; set STANBOT_LIVE_TEST=1 to run")
        let key = try XCTUnwrap(key(), "no OPENAI_API_KEY_STANBOT in sops")
        let recorder = Recorder()
        let transport = VoiceTransport(key: { key }, deliver: { $0() })
        transport.delegate = recorder

        transport.open(instructions: "Say nothing unless asked.", voice: Live.defaultVoice)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && recorder.events.isEmpty && recorder.failures.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        transport.close()

        XCTAssertTrue(recorder.failures.isEmpty, "socket failed: \(recorder.failures)")
        let first = try XCTUnwrap(recorder.events.first, "the service said nothing in 20 s")
        // A rejected session arrives as .failed with the offending parameter --
        // which is how the four wrong shapes were found. Anything but .started
        // here means this app is sending one of them again.
        guard case .started(let id, let voice, let expires) = first else {
            return XCTFail("the service refused the session: \(first)")
        }
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(voice, Live.defaultVoice, "the voice we asked for is the voice it took")
        if let expires {
            let allowed = expires.timeIntervalSinceNow
            XCTAssertGreaterThan(allowed, 60)
            print("live session: \(id), voice \(voice), may run \(Int(allowed / 60)) minutes")
        }
    }
}
