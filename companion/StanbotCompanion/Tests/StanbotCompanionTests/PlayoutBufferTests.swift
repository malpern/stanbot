import XCTest
@testable import StanbotCompanion

/// The buffer is what stands between an interruption and Stanbot talking over
/// the person who interrupted it, because the service sends no cancel event.
final class PlayoutBufferTests: XCTestCase {
    private func audio(seconds: Double) -> Data {
        Data(count: Int(seconds * Double(PlayoutBuffer.bytesPerSecond)))
    }

    func testItNeverHoldsMoreThanAFifthOfASecond() {
        var buffer = PlayoutBuffer()
        buffer.append(audio(seconds: 3))
        XCTAssertLessThanOrEqual(buffer.seconds, PlayoutBuffer.depth + 0.001,
                                 "three seconds queued would be three seconds of talking over someone")
        XCTAssertGreaterThan(buffer.dropped, 0)
    }

    /// Overrun drops the OLDEST audio. Keeping it would play the stale sentence
    /// first and arrive late at the new one.
    func testOverrunDropsTheOldestSound() {
        var buffer = PlayoutBuffer()
        let old = Data(repeating: 0x11, count: PlayoutBuffer.bytesPerSecond / 10)
        let fresh = Data(repeating: 0x22, count: PlayoutBuffer.bytesPerSecond / 5)
        buffer.append(old)
        buffer.append(fresh)
        let out = buffer.take(buffer.queued.count)
        XCTAssertFalse(out.contains(0x11), "the stale audio should have gone, not the new")
        XCTAssertTrue(out.allSatisfy { $0 == 0x22 })
    }

    func testItHandsBackWhatWasPutInInOrder() {
        var buffer = PlayoutBuffer()
        buffer.append(Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(buffer.take(2), Data([1, 2]))
        XCTAssertEqual(buffer.take(2), Data([3, 4]))
        XCTAssertEqual(buffer.take(99), Data([5, 6]), "asking for more than there is gives what there is")
        XCTAssertEqual(buffer.take(1), Data(), "and then nothing, rather than a crash")
    }

    func testFlushLeavesNothingToBeHeard() {
        var buffer = PlayoutBuffer()
        buffer.append(audio(seconds: 0.1))
        buffer.flush()
        XCTAssertEqual(buffer.seconds, 0)
        XCTAssertEqual(buffer.take(1), Data())
    }

    /// The claim this whole design rests on, in one number.
    func testTheWorstStaleSpeechIsUnderAFifthOfASecond() {
        var buffer = PlayoutBuffer()
        for _ in 0..<50 { buffer.append(audio(seconds: 0.5)) }   // a fire hose
        XCTAssertLessThanOrEqual(buffer.seconds, PlayoutBuffer.depth + 0.001)
    }
}
