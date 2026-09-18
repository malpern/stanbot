import XCTest
@testable import StanbotCompanion

/// The conversation's rules, driven by a fake stream of protocol events. No
/// network, no sound card, no robot: this is the part that can be got right
/// before any of that exists.
final class VoiceSessionTests: XCTestCase {
    private let pcm = Data(count: PlayoutBuffer.bytesPerSecond / 20)   // 50 ms

    func testItFollowsAConversationThrough() {
        var session = VoiceSession()
        XCTAssertEqual(session.state, .off)
        session.begin()
        XCTAssertEqual(session.state, .connecting)
        session.receive(.started(sessionID: "live_1", voice: "vesper", expiresAt: nil))
        XCTAssertEqual(session.state, .listening)
        session.receive(.inputTranscript("what are you"))
        session.receive(.outputAudio(pcm))
        XCTAssertEqual(session.state, .speaking)
        session.receive(.outputTranscript("A small desk robot."))
        session.finishedSpeaking()
        XCTAssertEqual(session.state, .listening, "full duplex: it never stopped listening")
        XCTAssertEqual(session.transcript.map(\.speaker), ["You", "Stanbot"])
        XCTAssertEqual(session.transcript.last?.text, "A small desk robot.")
    }

    /// The service announces nothing when it is talked over, so an input
    /// transcript arriving mid-reply is the only notice there is. Everything
    /// queued must go, or Stanbot finishes its sentence over the person.
    func testBeingTalkedOverDropsWhatWasAboutToBeSaid() {
        var session = VoiceSession()
        session.begin()
        session.receive(.started(sessionID: "live_1", voice: "vesper", expiresAt: nil))
        session.receive(.outputAudio(pcm))
        XCTAssertGreaterThan(session.buffer.seconds, 0)
        session.receive(.inputTranscript("actually, stop"))
        XCTAssertEqual(session.buffer.seconds, 0, "queued speech must not outlive the interruption")
    }

    /// Transcript fragments arrive in pieces and belong to whoever was speaking.
    func testFragmentsJoinUpPerSpeaker() {
        var session = VoiceSession()
        session.begin()
        session.receive(.outputTranscript("I'm a tiny "))
        session.receive(.outputTranscript("desk robot."))
        XCTAssertEqual(session.transcript.count, 1)
        XCTAssertEqual(session.transcript.first?.text, "I'm a tiny desk robot.")
    }

    func testUsageComesFromTheServerAndNeverGoesBackwards() {
        var session = VoiceSession()
        session.begin()
        session.receive(.usage(seconds: 11))
        session.receive(.usage(seconds: 30))
        session.receive(.usage(seconds: 2))       // a late duplicate
        XCTAssertEqual(session.secondsBilled, 30)
    }

    func testEveryEndingClosesTheMouthAndEmptiesTheQueue() {
        for ending: VoiceEnding in [.stoppedByOwner, .idle(200), .dailyLimit, .robotAsleep,
                                    .dropped("socket closed"), .refused("no key")] {
            var session = VoiceSession()
            session.begin()
            session.receive(.outputAudio(pcm))
            session.end(ending)
            XCTAssertTrue(session.mouthShouldClose, "\(ending): a mouth left open is a face mid-word")
            XCTAssertEqual(session.buffer.seconds, 0, "\(ending): nothing may be heard after the end")
        }
    }

    /// A dropped conversation stays dropped and says so. No automatic
    /// reconnect, matching how follow sessions behave.
    func testADroppedConversationDoesNotComeBackByItself() {
        var session = VoiceSession()
        session.begin()
        session.receive(.failed("network went away"))
        guard case .failed(let why) = session.state else { return XCTFail("should be failed") }
        XCTAssertTrue(why.contains("network went away"))
        XCTAssertFalse(session.state.isRunning)
    }

    // MARK: the policy

    func testItRefusesForReasonsAPersonCanRead() {
        let policy = VoicePolicy()
        XCTAssertEqual(policy.refusal(usedToday: 0, hasKey: false, audioRoute: "Studio Display", robotAsleep: false),
                       .refused("Talking needs an OpenAI key. Add it in Settings."))
        XCTAssertEqual(policy.refusal(usedToday: 0, hasKey: true, audioRoute: nil, robotAsleep: false),
                       .refused("No microphone and speakers for the conversation."))
        XCTAssertEqual(policy.refusal(usedToday: 0, hasKey: true, audioRoute: "x", robotAsleep: true),
                       .robotAsleep)
        XCTAssertEqual(policy.refusal(usedToday: 3_600, hasKey: true, audioRoute: "x", robotAsleep: false),
                       .dailyLimit)
        XCTAssertNil(policy.refusal(usedToday: 60, hasKey: true, audioRoute: "x", robotAsleep: false))
    }

    func testItStopsForSilenceBeforeItBillsForIt() {
        let policy = VoicePolicy()
        let start = Date()
        XCTAssertNil(policy.ending(startedAt: start, lastVoiceAt: start,
                                   usedToday: 0, now: start.addingTimeInterval(179)))
        guard case .idle(let silence)? = policy.ending(startedAt: start, lastVoiceAt: start,
                                                       usedToday: 0, now: start.addingTimeInterval(181)) else {
            return XCTFail("should have stopped for silence")
        }
        XCTAssertGreaterThan(silence, 180)
        // Stanbot speaking counts as the conversation being alive.
        let spokeRecently = start.addingTimeInterval(170)
        XCTAssertNil(policy.ending(startedAt: start, lastVoiceAt: spokeRecently,
                                   usedToday: 0, now: start.addingTimeInterval(200)))
    }

    func testTheDailyLimitEndsARunningConversationToo() {
        let policy = VoicePolicy()
        let start = Date()
        XCTAssertEqual(policy.ending(startedAt: start, lastVoiceAt: start, usedToday: 3_600, now: start),
                       .dailyLimit)
    }

    func testTheEndingsReadAsSentences() {
        XCTAssertEqual(VoiceEnding.idle(180).summary, "Nobody spoke for 3 minutes, so the conversation ended.")
        XCTAssertTrue(VoiceEnding.dailyLimit.summary.contains("resets tomorrow"))
        XCTAssertTrue(VoiceEnding.robotAsleep.summary.contains("went to sleep"))
    }
}

/// The Talk control's words and appearance, checked without building a window.
final class VoiceControlTests: XCTestCase {
    func testItReadsAsAStandingIntentLikeFollow() {
        XCTAssertEqual(VoiceControl.title(.off), "Talk")
        XCTAssertEqual(VoiceControl.title(.listening), "Listening")
        XCTAssertEqual(VoiceControl.title(.speaking), "Speaking")
        XCTAssertEqual(VoiceControl.symbol(.off), "waveform")
        XCTAssertEqual(VoiceControl.symbol(.listening), "waveform.circle.fill")
        XCTAssertTrue(VoiceControl.pulses(.speaking))
        XCTAssertFalse(VoiceControl.pulses(.listening), "pulsing while silent would be decoration")
    }

    /// A refusal must be readable from the control itself, not hidden behind a
    /// disabled button -- the same rule the Follow toggle follows.
    func testARefusalIsTheHelpText() {
        let refusal = VoiceEnding.refused("Talking needs an OpenAI key. Add it in Settings.")
        XCTAssertEqual(VoiceControl.help(.off, refusal: refusal), refusal.summary)
        XCTAssertEqual(VoiceControl.help(.off, refusal: nil), "Talk with Stanbot")
        XCTAssertTrue(VoiceControl.help(.speaking, refusal: nil).contains("Talk over it"))
    }

    func testMinutesReadTheWayAPersonWouldSayThem() {
        XCTAssertEqual(VoiceControl.minutes(11), "11s")
        XCTAssertEqual(VoiceControl.minutes(600), "10 min")
    }
}
