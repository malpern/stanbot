import XCTest
@testable import StanbotCompanion

/// Where the owner usually is, learned over sessions -- and, more importantly,
/// unlearned when it stops being true. The robot sits on a desk and can be
/// nudged round; the owner may work somewhere else for a day.
final class UsualPlaceTests: XCTestCase {
    private func place(_ yaw: Int) -> RobotState.Place { RobotState.Place(yaw: yaw, pitch: 640) }

    /// The densest cluster, not the average: an average of the desk and the
    /// doorway is the wall between them, where nobody has ever been.
    func testItPicksTheClusterNotTheMean() {
        let history = [place(512), place(516), place(180), place(508)]
        let usual = RobotState.usualPlace(history, misses: 0)
        XCTAssertNotNil(usual)
        XCTAssertLessThan(abs(usual!.yaw - 512), RobotState.sameePlaceRaw, "the desk, not 429")
        // And it is a real sighting, not a computed point.
        XCTAssertTrue(history.contains(usual!))
    }

    /// Nothing seen yet: no guess, and the robot sweeps rather than being sent
    /// to a default that means nothing.
    func testNoHistoryMeansNoGuess() {
        XCTAssertNil(RobotState.usualPlace([], misses: 0))
        XCTAssertNil(RobotState.restoreLine(RobotState.usualPlace([], misses: 0)))
    }

    /// The robot is turned on the desk: every stored place is now wrong by the
    /// same offset. After two fruitless looks it stops leading with any of
    /// them, so it sweeps instead of aiming confidently at a wall.
    func testItStopsTrustingAPlaceThatKeepsBeingEmpty() {
        let history = [place(512), place(514), place(510)]
        XCTAssertNotNil(RobotState.usualPlace(history, misses: 0))
        XCTAssertNotNil(RobotState.usualPlace(history, misses: RobotState.missesBeforeDoubt - 1))
        XCTAssertNil(RobotState.usualPlace(history, misses: RobotState.missesBeforeDoubt),
                     "twice empty: sweep the room rather than insist")
    }

    /// Moving desks: the new place wins once there is more of it than the old,
    /// so it takes a few sittings rather than one -- and never for ever.
    func testTheUsualPlaceCanMove() {
        var history = [place(512), place(514), place(510)]
        XCTAssertLessThan(abs(RobotState.usualPlace(history, misses: 0)!.yaw - 512), RobotState.sameePlaceRaw)
        history += [place(260)]
        XCTAssertLessThan(abs(RobotState.usualPlace(history, misses: 0)!.yaw - 512), RobotState.sameePlaceRaw,
                          "one sighting elsewhere does not move the desk")
        history += [place(264), place(258), place(262)]
        XCTAssertLessThan(abs(RobotState.usualPlace(history, misses: 0)!.yaw - 260), RobotState.sameePlaceRaw,
                          "four sightings there: that is where they sit now")
    }

    /// A tie goes to the newer cluster: two places seen equally often means the
    /// more recent one is the better guess.
    func testATieGoesToTheMoreRecent() {
        let history = [place(180), place(184), place(512), place(516)]
        XCTAssertLessThan(abs(RobotState.usualPlace(history, misses: 0)!.yaw - 514), RobotState.sameePlaceRaw)
    }

    /// Seeing someone anywhere ends the doubt: it is evidence, and the count of
    /// fruitless looks starts again.
    func testASightingClearsTheDoubt() {
        let saved = (UserDefaults.standard.object(forKey: RobotState.sightingsKey),
                     UserDefaults.standard.object(forKey: RobotState.missesKey),
                     UserDefaults.standard.object(forKey: RobotState.lastSeenYawKey),
                     UserDefaults.standard.object(forKey: RobotState.lastSeenPitchKey))
        defer {
            UserDefaults.standard.set(saved.0, forKey: RobotState.sightingsKey)
            UserDefaults.standard.set(saved.1, forKey: RobotState.missesKey)
            UserDefaults.standard.set(saved.2, forKey: RobotState.lastSeenYawKey)
            UserDefaults.standard.set(saved.3, forKey: RobotState.lastSeenPitchKey)
        }
        RobotState.forgetSightings()
        RobotState.priorMissed()
        RobotState.priorMissed()
        XCTAssertEqual(RobotState.priorMisses, RobotState.missesBeforeDoubt)
        RobotState.rememberLastSeen(yaw: 300, pitch: 640)
        XCTAssertEqual(RobotState.priorMisses, 0)
        XCTAssertEqual(RobotState.usualPlace()?.yaw, 300)
        // And only the last `remembered` sightings are kept.
        for yaw in 0..<(RobotState.remembered + 5) { RobotState.rememberLastSeen(yaw: 400 + yaw, pitch: 640) }
        XCTAssertEqual(RobotState.sightings.count, RobotState.remembered)
    }
}
