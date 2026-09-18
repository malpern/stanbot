import XCTest
@testable import StanbotCompanion

/// The wire protocol, pinned to what the service actually did on 2026-09-17
/// (companion/voice-spike). These are the shapes the documentation got wrong,
/// so they are the ones worth a test.
final class VoiceModelClientTests: XCTestCase {
    func testTheSessionStartIsTheShapeTheServerAccepted() throws {
        let message = Live.startMessage(instructions: "Be brief.", voice: "vesper")
        let session = try XCTUnwrap(message["session"] as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "session.start")
        XCTAssertEqual(session["model"] as? String, "gpt-live-1")
        // The four things the server rejected, kept rejected.
        XCTAssertNil(session["voice"], "session.voice is an unknown parameter")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        XCTAssertNil(audio["input"], "audio.input is an unknown parameter")
        let format = try XCTUnwrap(audio["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertEqual((audio["output"] as? [String: Any])?["voice"] as? String, "vesper")
    }

    func testCedarIsNotALiveVoice() {
        XCTAssertFalse(Live.voices.contains("cedar"), "the plan chose a voice Live does not have")
        XCTAssertTrue(Live.voices.contains(Live.defaultVoice))
        XCTAssertTrue(Live.voices.contains("marin"), "the service default")
    }

    func testItReadsTheEventsTheServiceSends() throws {
        let started = #"{"type":"session.started","session":{"id":"live_abc","expires_at":1789714301,"# +
                      #""audio":{"output":{"voice":"vesper"}}}}"#
        guard case .started(let id, let voice, let expires) = try XCTUnwrap(Live.parse(started)) else {
            return XCTFail("not a started event")
        }
        XCTAssertEqual(id, "live_abc")
        XCTAssertEqual(voice, "vesper")
        XCTAssertEqual(expires?.timeIntervalSince1970, 1789714301)

        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let audio = #"{"type":"session.output_audio.delta","audio":"\#(pcm.base64EncodedString())"}"#
        XCTAssertEqual(Live.parse(audio), .outputAudio(pcm))

        XCTAssertEqual(Live.parse(#"{"type":"session.output_transcript.delta","delta":"hello"}"#),
                       .outputTranscript("hello"))
        XCTAssertEqual(Live.parse(#"{"type":"session.input_transcript.delta","delta":"hi"}"#),
                       .inputTranscript("hi"))
        XCTAssertEqual(Live.parse(#"{"type":"session.usage.updated","usage":{"seconds":11}}"#),
                       .usage(seconds: 11))
    }

    /// A wrong session shape is refused before the session starts, which is why
    /// the spike could converge for nothing. The app must read that as a
    /// failure with the server's own words, not as silence.
    func testAnUnknownParameterIsReportedWithTheServersWords() throws {
        let error = #"{"type":"error","error":{"type":"invalid_request_error","#
                  + #""code":"unknown_parameter","message":"Unknown parameter: 'session.voice'."}}"#
        guard case .failed(let message) = try XCTUnwrap(Live.parse(error)) else {
            return XCTFail("not a failure")
        }
        XCTAssertTrue(message.contains("session.voice"))
    }

    func testAnUnknownEventIsNotAFailure() {
        // The service will grow events; meeting one is not a reason to end a
        // conversation.
        XCTAssertEqual(Live.parse(#"{"type":"session.something.new"}"#), .other("session.something.new"))
        XCTAssertNil(Live.parse("not json at all"))
    }

    func testTheSessionLimitIsRecordedAsMeasured() {
        XCTAssertEqual(Live.sessionLimit, 7_200, accuracy: 1, "expires_at was two hours ahead")
    }
}
