import AVFoundation
import XCTest
@testable import StanbotCompanion

final class DeskCameraTests: XCTestCase {
    func testPresetOnlyForFormatsItCanKeep() {
        XCTAssertEqual(DeskCamera.preset(matching: "1280x720"), .hd1280x720)
        XCTAssertEqual(DeskCamera.preset(matching: "1920x1080"), .hd1920x1080)
        XCTAssertEqual(DeskCamera.preset(matching: "640x480"), .vga640x480)
        XCTAssertNil(DeskCamera.preset(matching: "1664x1248"), "no preset keeps this format, so it must not start")
    }

    func testAnalysisIsThrottledToFivePerSecond() {
        XCTAssertTrue(DeskCamera.shouldAnalyze(now: 10.0, last: -.infinity))
        XCTAssertFalse(DeskCamera.shouldAnalyze(now: 10.1, last: 10.0))
        XCTAssertTrue(DeskCamera.shouldAnalyze(now: 10.2, last: 10.0))
    }

    func testLogLineCarriesPoseFacingAndCallState() {
        let face = FaceBox(rect: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.12), confidence: 0.93,
                           pose: HeadPose(yaw: -12.34, pitch: 5, roll: 0), frameWidth: 1280)
        let line = DeskAnalysis(time: 1234.5, faces: [face], frameWidth: 1280, inUseByAnotherApp: true, centerStageActive: false).logLine
        XCTAssertTrue(line.hasPrefix("DESK {"))
        let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
        XCTAssertEqual(object?["in_use_by_another_app"] as? Bool, true)
        XCTAssertEqual(object?["center_stage_active"] as? Bool, false)
        let first = (object?["faces"] as? [[Any]])?.first
        XCTAssertEqual(first?[5] as? Double, -12.3)
        XCTAssertEqual(first?[7] as? String, "toward", "128 px wide, turned 12 degrees")
    }

    @MainActor
    func testOffByDefaultAndNeverOpensACameraUnderTests() {
        let camera = DeskCamera()
        camera.start()
        XCTAssertEqual(camera.state, .off)
    }
}
