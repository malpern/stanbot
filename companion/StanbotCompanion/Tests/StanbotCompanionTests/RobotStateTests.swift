import XCTest
@testable import StanbotCompanion

final class RobotStateTests: XCTestCase {
    private var savedYaw: Any?
    private var savedPitch: Any?

    override func setUp() {
        savedYaw = UserDefaults.standard.object(forKey: RobotState.lastSeenYawKey)
        savedPitch = UserDefaults.standard.object(forKey: RobotState.lastSeenPitchKey)
        RobotState.lastSeen = nil
    }

    override func tearDown() {
        UserDefaults.standard.set(savedYaw, forKey: RobotState.lastSeenYawKey)
        UserDefaults.standard.set(savedPitch, forKey: RobotState.lastSeenPitchKey)
    }

    /// Nothing kept yet: nothing is handed back, rather than a zero that would
    /// send the head to one end of its travel.
    func testNothingKeptSendsNothing() {
        XCTAssertNil(RobotState.lastSeen)
        XCTAssertNil(RobotState.restoreLine(RobotState.lastSeen))
    }

    func testAPlaceSurvivesAndIsHandedBack() {
        RobotState.rememberLastSeen(yaw: 512, pitch: 630)
        XCTAssertEqual(RobotState.lastSeen, RobotState.Place(yaw: 512, pitch: 630))
        XCTAssertEqual(RobotState.restoreLine(RobotState.lastSeen), "K,lsy=512,lsp=630\n")
    }

    /// A yaw of 0 is a real position, not "unset": storing it must not read
    /// back as nothing kept.
    func testZeroIsAPositionNotAnAbsence() {
        RobotState.rememberLastSeen(yaw: 0, pitch: 0)
        XCTAssertEqual(RobotState.lastSeen, RobotState.Place(yaw: 0, pitch: 0))
        XCTAssertEqual(RobotState.restoreLine(RobotState.lastSeen), "K,lsy=0,lsp=0\n")
    }
}
