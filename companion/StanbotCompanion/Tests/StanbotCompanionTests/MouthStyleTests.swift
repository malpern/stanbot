import AppKit
import SwiftUI
import XCTest
@testable import StanbotCompanion

/// The two mouths, and the arithmetic the Mac's version draws from. The shapes
/// must agree with the robot's (`MouthModel.h`) -- the app may draw the same
/// face better, but never a different one.
final class MouthStyleTests: XCTestCase {
    func testTheStyleCarriesTheCommandTheRobotUnderstands() {
        XCTAssertEqual(MouthStyle.capsule.command, "C,MOUTH,CAPSULE\n")
        XCTAssertEqual(MouthStyle.grille.command, "C,MOUTH,GRILLE\n")
        // The robot's allowlist has these two exactly; a typo here would be a
        // command silently refused over Wi-Fi.
        XCTAssertEqual(MouthStyle.allCases.count, 2)
    }

    /// The numbers that must match `MouthModel.h`, because the Mac and the robot
    /// draw the same grille and only the quality differs.
    /// Nothing may ever be drawn outside the panel. Slots are cut INTO a
    /// surface; one that spills past the edge stops being a cut and the whole
    /// shape stops meaning anything. At 26 tall this failed at full voice with
    /// a frown, and it took an eye to notice -- so it is a test now, across the
    /// entire range rather than at the corners.
    func testNoSlotEverLeavesThePanel() {
        let limit = GrilleGeometry.height / 2 - GrilleGeometry.rimV
        for openStep in 0...20 {
            for moodStep in -10...10 {
                let open = Double(openStep) / 20
                let mood = Double(moodStep) / 10
                let extent = GrilleGeometry.slotExtent(open: open, mood: mood)
                XCTAssertLessThanOrEqual(extent, limit,
                                         "open \(open), mood \(mood): slots reach \(extent), panel allows \(limit)")
            }
        }
    }

    /// The panel has to be big enough for the expression, and small enough for
    /// the face: the eyes' lowest edge is 191 and the display ends at 240, with
    /// the mouth centred at 212.
    func testThePanelFitsBetweenTheEyesAndTheChin() {
        let half = GrilleGeometry.height / 2
        XCTAssertLessThanOrEqual(212 - half, 240.0)
        XCTAssertGreaterThan(212 - half, 191, "the panel must not reach the eyes")
        XCTAssertLessThan(212 + half, 240, "nor run off the bottom of the display")
    }

    func testTheGrilleAgreesWithTheRobot() {
        XCTAssertEqual(GrilleGeometry.width, 74)
        XCTAssertEqual(GrilleGeometry.height, 36)
        XCTAssertEqual(GrilleGeometry.slots, 3)
        XCTAssertEqual(GrilleGeometry.arcFirstAt, 0.18)
        XCTAssertEqual(GrilleGeometry.arcSecondAt, 0.55)
    }

    func testArcsAppearWithLoudnessAndReachFurtherWhenBright() {
        XCTAssertEqual(GrilleGeometry.arcs(open: 0.0, shape: 0).count, 0, "silence shows no sound")
        XCTAssertEqual(GrilleGeometry.arcs(open: 0.3, shape: 0).count, 1)
        XCTAssertEqual(GrilleGeometry.arcs(open: 0.9, shape: 0).count, 2)
        let flat = GrilleGeometry.arcs(open: 0.9, shape: 0).length
        let bright = GrilleGeometry.arcs(open: 0.9, shape: 1).length
        XCTAssertGreaterThan(bright, flat, "an ee should carry further than an oo")
        XCTAssertLessThanOrEqual(bright, GrilleGeometry.arcMaxLength)
    }

    func testLoudnessOpensTheSlotsApart() {
        XCTAssertLessThan(GrilleGeometry.spacing(open: 0), GrilleGeometry.spacing(open: 1))
    }

    /// The grille's only way to show how it feels. A speaker cannot frown, so
    /// this is the whole of its emotional range -- it had better work.
    func testMoodLeansTheSlotsBothWays() {
        XCTAssertEqual(GrilleGeometry.tilt(mood: 0), 0)
        let sad = GrilleGeometry.tilt(mood: -1)
        let pleased = GrilleGeometry.tilt(mood: 1)
        XCTAssertGreaterThan(sad, 0, "sad sags: positive is downward")
        XCTAssertLessThan(pleased, 0)
        XCTAssertEqual(sad, -pleased)
        XCTAssertEqual(sad, GrilleGeometry.maxTilt)
        // Out of range must not bend it further than the design allows.
        XCTAssertEqual(GrilleGeometry.tilt(mood: -9), GrilleGeometry.maxTilt)
    }

    func testTheSettingRemembersAndDefaultsToTheMouth() {
        let saved = UserDefaults.standard.string(forKey: MouthStyleSetting.key)
        defer { UserDefaults.standard.set(saved, forKey: MouthStyleSetting.key) }
        UserDefaults.standard.removeObject(forKey: MouthStyleSetting.key)
        XCTAssertEqual(MouthStyleSetting.current, .capsule, "the mouth is what Stanbot has worn until now")
        MouthStyleSetting.current = .grille
        XCTAssertEqual(MouthStyleSetting.current, .grille)
    }
}

/// The grille as the Mac actually draws it. Rendered offscreen with the real
/// shader, because the whole point of the Metal version is what it looks like,
/// and a window snapshot cannot capture shader effects.
///
///     STANBOT_SHADER_LIBRARY=$PWD/build/Stanbot.app/Contents/Resources/StanbotShaders.metallib \
///       swift test --filter MouthStyleRenderingTests
@MainActor
final class MouthStyleRenderingTests: XCTestCase {
    private func render(level: Double, mood: Double) throws -> NSBitmapImageRep {
        let speech = SpeechMouth()
        speech.previewSpeaking(opening: level, shape: 0, level: level, mood: mood)
        // The frame must be the grille's own box, or the view is clipped and
        // every measurement below lands somewhere other than it thinks.
        let view = StanbotMouthView(scale: 3, glow: true)
            .environment(speech)
            .frame(width: 136 * 3, height: 56 * 3)
            .background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        // Keep the picture: measurements say the shader draws something, only
        // an eye says whether it is any good.
        if let out = ProcessInfo.processInfo.environment["STANBOT_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: out).appendingPathComponent(
                    String(format: "grille-level%.0f-mood%.0f.png", level * 100, mood * 100)))
        }
        return rep
    }

    /// Brightest pixel in a horizontal band, which is how a lit slot or an arc
    /// shows up against the dark panel.
    private func brightest(_ rep: NSBitmapImageRep, x: Range<Int>, y: Int) -> Double {
        var best = 0.0
        for column in x {
            guard let colour = rep.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            best = max(best, Double(colour.brightnessComponent))
        }
        return best
    }

    func testTheGrilleLightsUpAndSoundLeavesIt() throws {
        guard ProcessInfo.processInfo.environment["STANBOT_SHADER_LIBRARY"] != nil else {
            throw XCTSkip("set STANBOT_SHADER_LIBRARY to a compiled StanbotShaders.metallib")
        }
        let saved = UserDefaults.standard.string(forKey: MouthStyleSetting.key)
        defer { UserDefaults.standard.set(saved, forKey: MouthStyleSetting.key) }
        MouthStyleSetting.current = .grille

        let quiet = try render(level: 0.05, mood: 0)
        let loud = try render(level: 0.95, mood: 0)
        _ = try render(level: 0.7, mood: -1)   // sad: the slots sag
        _ = try render(level: 0.7, mood: 1)    // pleased: they lift
        let middle = quiet.pixelsHigh / 2
        let centre = quiet.pixelsWide / 2
        let pixelsPerRobotPixel = Double(quiet.pixelsWide) / 136.0   // the grille's box

        // The slots are brighter when the voice is louder: the panel does not
        // change size, so brightness is the only thing that can carry loudness.
        let slotBand = (centre - 40)..<(centre + 40)
        let quietSlot = brightest(quiet, x: slotBand, y: middle)
        let loudSlot = brightest(loud, x: slotBand, y: middle)
        XCTAssertGreaterThan(loudSlot, quietSlot + 0.05,
                             "the slots must brighten with the voice (quiet \(quietSlot), loud \(loudSlot))")

        // And sound leaves it: something is drawn outside the panel when loud
        // that is not there when quiet.
        let panelHalfWidth = Int(GrilleGeometry.width / 2 * pixelsPerRobotPixel)
        let arcBand = Int(4 * pixelsPerRobotPixel)
        let outside = (centre + panelHalfWidth + arcBand)..<(quiet.pixelsWide - 2)
        let quietOutside = brightest(quiet, x: outside, y: middle)
        let loudOutside = brightest(loud, x: outside, y: middle)
        XCTAssertLessThan(quietOutside, 0.1, "nothing should leave a grille that is barely speaking")
        XCTAssertGreaterThan(loudOutside, quietOutside + 0.05,
                             "arcs must appear beside it when loud (quiet \(quietOutside), loud \(loudOutside))")
    }
}
