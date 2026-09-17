import XCTest
import AppKit
import SwiftUI
@testable import StanbotCompanion

final class EyeApertureTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
    private let pose = EyePose.of(.normal)

    private func wakeSamples(step: Double = 0.02) -> [(t: Double, state: EyeMotionSequence.State)] {
        stride(from: 0.0, through: EyeMotionSequence.wakeDuration, by: step)
            .map { ($0, EyeMotionSequence.wake(at: $0)) }
    }

    func testWakingIsSlowEnoughToRead() {
        XCTAssertGreaterThan(EyeMotionSequence.wakeDuration, 2, "waking up in the morning, not a shutter")
        XCTAssertLessThan(EyeMotionSequence.sleepDuration, EyeMotionSequence.wakeDuration)
        // Waking from a sleep the owner asked for is brisker, but the same shot.
        XCTAssertLessThan(EyeMotionSequence.wakeFromSleepDuration, EyeMotionSequence.wakeDuration)
        XCTAssertGreaterThan(EyeMotionSequence.wakeFromSleepDuration, 1)
        let brisk = EyeMotionSequence.wakeFromSleepDuration
        XCTAssertEqual(EyeMotionSequence.wake(at: brisk * 0.5, duration: brisk),
                       EyeMotionSequence.wake(at: EyeMotionSequence.wakeDuration * 0.5))
        XCTAssertEqual(EyeMotionSequence.wake(at: brisk, duration: brisk), .open)
    }

    func testWakingStartsShutAndEndsFullyOpen() {
        let start = EyeMotionSequence.wake(at: 0)
        XCTAssertEqual(start.left, 0)
        XCTAssertEqual(start.right, 0)
        XCTAssertEqual(start.focus, 0, "nothing is in focus yet")
        let end = EyeMotionSequence.wake(at: EyeMotionSequence.wakeDuration)
        XCTAssertEqual(end, .open)
        XCTAssertEqual(EyeMotionSequence.wake(at: 99), .open, "and stays open")
    }

    /// The lids must come up in stages: a crack of light, shut again, then open.
    /// Without the dip it reads as a slider; with more than one it bounces.
    func testWakingBlinksOnceOnTheWayUp() {
        let samples = wakeSamples()
        // A blink is a peak the lid falls back from: count interior maxima.
        var dips = 0
        for index in 1..<(samples.count - 1) {
            let previous = samples[index - 1].state.left
            let current = samples[index].state.left
            let next = samples[index + 1].state.left
            if current > previous + 0.001, next < current - 0.001 { dips += 1 }
        }
        XCTAssertEqual(dips, 1, "exactly one half-blink: more read as bouncing")
        // And no wobble once open: from the blink on, the lid only rises.
        let afterBlink = samples.filter { $0.t > 0.8 }.map(\.state.left)
        XCTAssertEqual(afterBlink, afterBlink.sorted(), "an unbroken rise after the blink")
        // And they really are half-blinks: the eye closes a good way, not a wobble.
        let opennessAfterFirstRise = samples.first { $0.state.left > 0.28 }?.state.left ?? 0
        let lowest = samples.first { $0.t > 0.4 && $0.t < 0.7 }.map { _ in
            samples.filter { $0.t > 0.2 && $0.t < 0.6 }.map(\.state.left).min() ?? 1
        } ?? 1
        XCTAssertLessThan(lowest, opennessAfterFirstRise - 0.1, "the lid drops back noticeably")
    }

    func testTheTwoLidsAreNeverInStep() {
        let samples = wakeSamples()
        let differences = samples.map { abs($0.state.left - $0.state.right) }
        XCTAssertGreaterThan(differences.max() ?? 0, 0.1, "one lid lags the other")
        let middle = samples.filter { $0.t > 0.2 && $0.t < EyeMotionSequence.wakeDuration - 0.2 }
        XCTAssertTrue(middle.allSatisfy { $0.state.left != $0.state.right }, "never identical while moving")
    }

    func testFocusArrivesWithTheLidsAndOnlyAtTheEnd() {
        XCTAssertLessThan(EyeMotionSequence.wake(at: 0.5).focus, 0.5, "still soft early on")
        XCTAssertEqual(EyeMotionSequence.wake(at: EyeMotionSequence.wakeDuration).focus, 1)
        // Focus never runs ahead of the lids: a sharp picture through shut eyes
        // would give the game away.
        for (_, state) in wakeSamples() where state.focus > 0.9 {
            XCTAssertGreaterThan(max(state.left, state.right), 0.55)
        }
    }

    /// The aperture must stay eye-shaped almost all the way: that is the whole
    /// point of the shot. Only at the end does it grow past the frame.
    func testApertureIsEyeShapedUntilTheVeryEnd() {
        for (t, state) in wakeSamples(step: 0.05) where t < EyeMotionSequence.wakeDuration * 0.7 {
            let path = EyeApertureShape(state: state, pose: pose).path(in: frame)
            guard !path.isEmpty else { continue }
            XCTAssertFalse(path.contains(CGPoint(x: 6, y: 6)), "a corner shows through at \(t)")
            XCTAssertFalse(path.contains(CGPoint(x: 160, y: 30)), "above the eyes shows through at \(t)")
            XCTAssertEqual(state.growth, 0, accuracy: 0.001, "still eye-sized at \(t)")
        }
        // By the end one window covers the frame, so the picture is simply there,
        // whatever expression the eyes have (a smile's eyes are 26 px tall: with
        // the window sized from them, a detected face cropped the picture).
        for emotion in Emotion.allCases {
            let open = EyeApertureShape(state: .open, pose: EyePose.of(emotion)).path(in: frame)
            for corner in [CGPoint(x: 2, y: 2), CGPoint(x: 318, y: 2), CGPoint(x: 2, y: 238), CGPoint(x: 318, y: 238)] {
                XCTAssertTrue(open.contains(corner), "the whole picture at \(corner) with \(emotion)")
            }
        }
    }

    func testEachEyeOpensFromItsOwnPlaceAndTheLidFallsFromAbove() {
        // Mid-blink, the two windows are different heights and sit apart.
        let state = EyeMotionSequence.wake(at: 0.35)
        let path = EyeApertureShape(state: state, pose: pose).path(in: frame)
        XCTAssertFalse(path.isEmpty)
        XCTAssertFalse(path.contains(CGPoint(x: 160, y: 120)), "nothing between the eyes")
        // A narrow eye's slit sits below the eye's centre: the upper lid travels.
        let narrow = EyeApertureShape(state: .init(left: 0.15, right: 0, growth: 0, focus: 0), pose: pose)
            .path(in: frame).boundingRect
        XCTAssertGreaterThan(narrow.midY, 120)
        XCTAssertLessThan(narrow.height, pose.height * 0.25)
    }

    func testFallingAsleepClosesWithOneFlutter() {
        XCTAssertEqual(EyeMotionSequence.sleep(at: 0).left, 1, accuracy: 0.001)
        XCTAssertEqual(EyeMotionSequence.sleep(at: EyeMotionSequence.sleepDuration), .closed)
        let samples = stride(from: 0.0, through: EyeMotionSequence.sleepDuration, by: 0.02)
            .map { EyeMotionSequence.sleep(at: $0).left }
        let rises = zip(samples, samples.dropFirst()).filter { $1 > $0 + 0.001 }.count
        XCTAssertGreaterThan(rises, 0, "the lids catch themselves once on the way down")
        XCTAssertLessThan(EyeMotionSequence.sleep(at: EyeMotionSequence.sleepDuration * 0.5).growth, 0.05,
                          "the aperture is eye-sized almost at once")
    }

    /// Renders the real sequence to $TMPDIR/stanbot-wake-*.png to be looked at.
    @MainActor
    func testWriteWakeFilmstrip() throws {
        guard ProcessInfo.processInfo.environment["STANBOT_WAKE_STRIP"] != nil else {
            throw XCTSkip("set STANBOT_WAKE_STRIP to write the frames")
        }
        let photo = Image(nsImage: Self.scene())
        for step in stride(from: 0.0, through: EyeMotionSequence.wakeDuration, by: 0.15) {
            let state = EyeMotionSequence.wake(at: step)
            let view = photo
                .resizable()
                .frame(width: 320, height: 240)
                .eyeAperture(state, pose: EyePose.of(.normal))
                .background(.black)
                .frame(width: 320, height: 240)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try rep.representation(using: .png, properties: [:])?
                .write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent(String(format: "stanbot-wake-%04d.png", Int(step * 100))))
        }
    }

    /// A bright window and a dim room: something where focus and light read.
    private static func scene() -> NSImage {
        let size = NSSize(width: 320, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.22, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.95, alpha: 1).setFill()
        NSRect(x: 20, y: 60, width: 110, height: 160).fill()   // the window
        NSColor(calibratedRed: 0.35, green: 0.5, blue: 0.3, alpha: 1).setFill()
        NSRect(x: 30, y: 70, width: 40, height: 80).fill()     // a tree through it
        NSColor(calibratedRed: 0.75, green: 0.55, blue: 0.45, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 180, y: 90, width: 90, height: 110)).fill()   // a face
        NSColor(white: 0.1, alpha: 1).setFill()
        NSRect(x: 200, y: 130, width: 12, height: 8).fill()
        NSRect(x: 238, y: 130, width: 12, height: 8).fill()
        image.unlockFocus()
        return image
    }
}
