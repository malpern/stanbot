import SwiftUI

/// Falling asleep and waking, seen from inside Stanbot's head: the picture is
/// masked by the shape of the robot's own eyes, which narrow to two eye-shaped
/// windows and then close like lids, losing focus as they go. Waking reverses
/// it. The robot does the same thing on its own screen over the same times
/// (firmware SleepCurtain.h); `MouthTests` checks the timings against it.
///
/// `openness` is 1 awake (the whole picture) and 0 asleep (black).
enum Eyelids {
    /// The robot's own closing and opening times, from SleepCurtain.h.
    static let closeDuration = 0.700
    static let openDuration = 0.400

    /// Below this the view has narrowed to eye shapes and the lids are closing;
    /// above it the eye windows are widening out to the whole picture.
    static let lidPhase = 0.5

    /// Closing: quick at first, settling at the end, like a lid falling.
    /// Opening: a little faster with a touch of overshoot, as eyes do.
    static func animation(asleep: Bool) -> Animation {
        asleep ? .timingCurve(0.35, 0, 0.25, 1, duration: closeDuration)
               : .spring(duration: openDuration, bounce: 0.18)
    }
}

/// The two eye windows, in the robot's own 320x240 display units scaled to the
/// view: rounded rectangles the size of the current expression's eyes, widening
/// to cover everything as the eyes open, and closing from the top like lids.
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
        // The robot's display, mapped onto this view.
        let scale = min(rect.width / 320, rect.height / 240)
        let sx = rect.width / 320, sy = rect.height / 240
        let centers = [102.0, 218.0]

        if o >= Eyelids.lidPhase {
            // Widening out: each eye window grows until the two together cover
            // the whole picture, and their corners straighten as they go.
            let t = (o - Eyelids.lidPhase) / (1 - Eyelids.lidPhase)
            let eased = t * t
            for center in centers {
                let width = pose.width * scale + (rect.width * 1.25 - pose.width * scale) * eased
                let height = pose.height * scale + (rect.height * 1.25 - pose.height * scale) * eased
                let x = center * sx + (rect.midX - center * sx) * eased
                let radius = (min(30, pose.height / 2) * scale) * (1 - eased) + 4 * eased
                path.addRoundedRect(in: CGRect(x: x - width / 2, y: 120 * sy - height / 2,
                                               width: width, height: height),
                                    cornerSize: CGSize(width: radius, height: radius),
                                    style: .continuous)
            }
            return path
        }

        // Closing: the upper lid travels most of the way down, the lower lid a
        // little up, as a real eye closes.
        // Lids gather speed as they close, so the last of the light goes quickly.
        let t = o / Eyelids.lidPhase
        let full = pose.height * scale
        let height = max(0, full * pow(t, 1.6))
        let centerY = 120 * sy + (full - height) * 0.3   // the eye's centre drops as the top lid falls
        for center in centers {
            let width = pose.width * scale
            let radius = min(min(30, pose.height / 2) * scale, height / 2)
            path.addRoundedRect(in: CGRect(x: center * sx - width / 2, y: centerY - height / 2,
                                           width: width, height: height),
                                cornerSize: CGSize(width: radius, height: radius),
                                style: .continuous)
        }
        return path
    }
}

/// Masks what it is applied to with `EyelidShape`, and lets it lose focus as
/// the lids close: blur, a little less light, and the faintest lens-like scale.
/// Fully open it does nothing at all.
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
            content
                .blur(radius: 14 * closing * closing)
                .saturation(1 - 0.35 * closing)
                .brightness(-0.12 * closing)
                .scaleEffect(1 + 0.04 * closing)
                .mask {
                    // A soft edge: eyelids are skin, not a stencil.
                    EyelidShape(openness: openness, pose: pose)
                        .fill(.white)
                        .blur(radius: 3)
                }
        }
    }
}

extension View {
    /// See `Eyelids`: 1 awake, 0 asleep.
    func eyelidVeil(openness: Double, pose: EyePose, reduceMotion: Bool = false) -> some View {
        modifier(EyelidVeil(openness: openness, pose: pose, reduceMotion: reduceMotion))
    }
}
