import XCTest
import AppKit
import SwiftUI
@testable import StanbotCompanion

final class EyelidTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 320, height: 240)

    /// The app's lids and the robot's close over the same time.
    func testTimingsMatchTheFirmware() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("firmware/lib/StanbotEyes/src/SleepCurtain.h")
        let source = try String(contentsOf: header, encoding: .utf8)
        func constant(_ name: String) throws -> Double {
            let pattern = try NSRegularExpression(pattern: "static constexpr \\w+ \(name) = (\\d+);")
            let match = try XCTUnwrap(pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), name)
            return try XCTUnwrap(Double(String(source[Range(match.range(at: 1), in: source)!])))
        }
        XCTAssertEqual(try constant("kCloseMs") / 1000, Eyelids.closeDuration)
        XCTAssertEqual(try constant("kOpenMs") / 1000, Eyelids.openDuration)
    }

    func testClosedEyesShowNothingAndTheSurroundArrivesOnlyAtTheEnd() {
        let pose = EyePose.of(.normal)
        XCTAssertTrue(EyelidShape(openness: 0, pose: pose).path(in: frame).isEmpty,
                      "nothing shows through closed lids")
        // Most of the animation is the two eye windows alone: no surround at all.
        XCTAssertEqual(Eyelids.surroundOpacity(0), 0)
        XCTAssertEqual(Eyelids.surroundOpacity(0.5), 0)
        XCTAssertEqual(Eyelids.surroundOpacity(Eyelids.lidPhase), 0)
        XCTAssertLessThan(Eyelids.surroundOpacity(0.9), 0.4, "still mostly through the eyes")
        XCTAssertEqual(Eyelids.surroundOpacity(1), 1, "and then the whole picture")
        XCTAssertGreaterThan(Eyelids.lidPhase, 0.7, "the eyes hold the view for most of it")
    }

    func testMostOfTheAnimationIsTwoEyeShapesWhereTheRobotDrawsThem() {
        let pose = EyePose.of(.normal)
        for openness in [0.3, 0.5, Eyelids.lidPhase] {
            let path = EyelidShape(openness: openness, pose: pose).path(in: frame)
            XCTAssertFalse(path.contains(CGPoint(x: 160, y: 120)), "the bridge stays masked at \(openness)")
            XCTAssertFalse(path.contains(CGPoint(x: 8, y: 8)), "the corners stay masked at \(openness)")
            XCTAssertEqual(path.boundingRect.width, pose.width + 116, accuracy: 2, "both eyes, where the robot draws them")
        }
        let path = EyelidShape(openness: Eyelids.lidPhase, pose: pose).path(in: frame)
        // The eyes themselves, where the robot draws them, and nothing between.
        XCTAssertTrue(path.contains(CGPoint(x: 102, y: 120)), "looking out through the left eye")
        XCTAssertTrue(path.contains(CGPoint(x: 218, y: 120)), "and the right")
        XCTAssertEqual(path.boundingRect.height, pose.height, accuracy: 2)
    }

    func testLidsCloseFromTheTopAndShrinkAllTheWay() {
        let pose = EyePose.of(.normal)
        let heights = [0.78, 0.5, 0.3, 0.1].map {
            EyelidShape(openness: $0, pose: pose).path(in: frame).boundingRect.height
        }
        XCTAssertEqual(heights, heights.sorted(by: >), "each step is more closed than the last")
        XCTAssertLessThan(heights.last!, 12)
        // The remaining slit sits below the eye's centre: the upper lid travels.
        let slit = EyelidShape(openness: 0.12, pose: pose).path(in: frame).boundingRect
        XCTAssertGreaterThan(slit.midY, 120)
    }

    /// Renders the closing sequence to $TMPDIR/stanbot-eyelid-*.png to be looked at.
    @MainActor
    func testWriteEyelidSequence() throws {
        guard ProcessInfo.processInfo.environment["STANBOT_EYELID_SHEET"] != nil else {
            throw XCTSkip("set STANBOT_EYELID_SHEET to write the frames")
        }
        let picture = Image(nsImage: Self.checkerboard())
        for step in [1.0, 0.92, 0.85, 0.78, 0.6, 0.4, 0.15, 0.0] {
            let view = picture
                .resizable()
                .frame(width: 320, height: 240)
                .eyelidVeil(openness: step, pose: EyePose.of(.normal))
                .background(.black)
                .frame(width: 320, height: 240)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try rep.representation(using: .png, properties: [:])?
                .write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("stanbot-eyelid-\(Int(step * 100)).png"))
        }
    }

    /// Something with detail in it, so blur and masking are visible.
    private static func checkerboard() -> NSImage {
        let size = NSSize(width: 320, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        for row in 0..<12 {
            for column in 0..<16 {
                let light = (row + column) % 2 == 0
                (light ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1)).setFill()
                NSRect(x: Double(column) * 20, y: Double(row) * 20, width: 20, height: 20).fill()
            }
        }
        NSColor.systemTeal.setFill()
        NSRect(x: 120, y: 80, width: 80, height: 80).fill()
        image.unlockFocus()
        return image
    }
}
