import SwiftUI

/// Falling asleep and waking, seen from inside Stanbot's head: what the robot
/// sees is visible only through two eye-shaped windows, exactly where and what
/// shape the robot draws its own eyes, and the lids open and close over them.
/// The robot does the same thing on its own screen over the same times
/// (firmware SleepCurtain.h); `EyelidTests` checks the timings against it.
///
/// `openness` is 1 awake (the whole picture) and 0 asleep (black). Most of the
/// animation is spent looking through the two eyes: only at the very end does
/// the darkness around them dissolve into the full picture, so the first-person
/// "these are my eyes" reading is what you notice, not a widening rectangle.
enum Eyelids {
    /// The robot's own closing and opening times, from SleepCurtain.h.
    static let closeDuration = 0.700
    static let openDuration = 0.400

    /// Up to here the eyes are opening: two windows, lids rising. Above it the
    /// black around them fades away and the whole picture arrives.
    static let lidPhase = 0.78

    /// How much of what surrounds the eyes is visible: nothing at all while the
    /// lids are still moving, then the darkness dissolves.
    static func surroundOpacity(_ openness: Double) -> Double {
        guard openness > lidPhase else { return 0 }
        let t = (openness - lidPhase) / (1 - lidPhase)
        return t * t   // slow to start, so the eye shapes hold the picture
    }

    /// How far the eyes have opened, 0...1, over the lid part of the animation.
    static func lidOpening(_ openness: Double) -> Double {
        min(max(openness, 0), 1) / lidPhase
    }

    /// Closing: quick at first, settling at the end, like a lid falling.
    /// Opening: a little faster with a touch of overshoot, as eyes do.
    static func animation(asleep: Bool) -> Animation {
        asleep ? .timingCurve(0.35, 0, 0.25, 1, duration: closeDuration)
               : .spring(duration: openDuration, bounce: 0.18)
    }
}

/// The two eye windows, in the robot's own 320x240 display units scaled to the
/// view: rounded rectangles where the robot draws its eyes, the size of the
/// current expression's, with the upper lid falling as they close. Past
/// `lidPhase` they swell a little, as the surrounding darkness dissolves.
struct EyelidShape: Shape {
    var openness: Double
    var pose: EyePose

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let o = min(max(openness, 0), 1)
        guard o > 0.001 else { return path }
        // The robot's display, mapped onto this view: its eyes land where they
        // would be if you were looking out through them.
        let scale = min(rect.width / 320, rect.height / 240)
        let sx = rect.width / 320, sy = rect.height / 240

        // Lids gather speed as they close, so the last of the light goes quickly.
        let lid = min(Eyelids.lidOpening(o), 1)
        let full = pose.height * scale
        let height = max(0, full * pow(lid, 1.5))
        // Past the lid phase the windows swell, as if leaning into the view.
        let swell = 1 + 0.35 * Eyelids.surroundOpacity(o)
        let width = pose.width * scale * swell
        // The eye's centre sits lower while the top lid is down.
        let centerY = 120 * sy + (full - height) * 0.32
        let radius = min(min(30, pose.height / 2) * scale, height / 2)
        for center in [102.0, 218.0] {
            let x = center * sx
            path.addRoundedRect(in: CGRect(x: x - width / 2, y: centerY - height * swell / 2,
                                           width: width, height: height * swell),
                                cornerSize: CGSize(width: radius, height: radius),
                                style: .continuous)
        }
        return path
    }
}

/// Masks what it is applied to with `EyelidShape`, and lets it lose focus as
/// the lids close: blur, less colour and light, and a little scale, as if the
/// lens behind the eyes were relaxing. Fully open it does nothing at all.
struct EyelidVeil: ViewModifier {
    var openness: Double
    var pose: EyePose
    /// Reduce Motion: no lids, just a fade.
    var reduceMotion = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(openness)
        } else if openness >= 0.999 {
            content
        } else {
            let closing = 1 - openness
            let surround = Eyelids.surroundOpacity(openness)
            content
                // Out of focus while the eyes are nearly shut, sharp once open.
                .blur(radius: 16 * pow(1 - Eyelids.lidOpening(openness).clamped(), 1.5))
                .saturation(1 - 0.4 * closing)
                .brightness(-0.1 * closing)
                // Waking leans into the view: the picture settles back from a
                // slight push-in as the eyes finish opening.
                .scaleEffect(1 + 0.05 * closing)
                .mask {
                    ZStack {
                        // What surrounds the eyes: nothing until the very end.
                        Color.white.opacity(surround)
                        // A soft edge: eyelids are skin, not a stencil.
                        EyelidShape(openness: openness, pose: pose)
                            .fill(.white)
                            .blur(radius: 4)
                    }
                }
        }
    }
}

private extension Double {
    func clamped() -> Double { min(max(self, 0), 1) }
}

extension View {
    /// See `Eyelids`: 1 awake, 0 asleep.
    func eyelidVeil(openness: Double, pose: EyePose, reduceMotion: Bool = false) -> some View {
        modifier(EyelidVeil(openness: openness, pose: pose, reduceMotion: reduceMotion))
    }
}
