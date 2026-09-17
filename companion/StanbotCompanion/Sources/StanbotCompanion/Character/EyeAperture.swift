import SwiftUI

/// Waking up and falling asleep, as a shot from behind Stanbot's eyes.
///
/// Waking is the one that matters: eyes prising open in the morning. They come
/// up in stages, not one smooth glide; the two lids do not move in step; there
/// are a couple of half-blinks on the way; everything is soft until they are
/// properly open, and only at the very end does the aperture grow past the
/// frame so the picture is simply *there*. Falling asleep is the same machinery,
/// quicker and with one last flutter.
///
/// Every value is a pure function of time since the sequence began, so the whole
/// thing can be rendered frame by frame in tests (`EyelidTests`).
enum EyeMotionSequence {
    /// Slow: a morning, not a shutter.
    static let wakeDuration = 2.4
    static let sleepDuration = 1.1

    struct State: Equatable {
        /// How open each eye is, 0...1. They differ: one lid is always lazier.
        var left: Double
        var right: Double
        /// How far the eye windows have grown past the frame, 1 = eye-sized.
        var growth: Double
        /// 0 soft and washed out, 1 sharp: focus arrives with the lids.
        var focus: Double

        static let open = State(left: 1, right: 1, growth: Self.fullGrowth, focus: 1)
        static let closed = State(left: 0, right: 0, growth: 1, focus: 0)
        /// Enough for one eye window to cover a 4:3 frame on its own.
        static let fullGrowth = 4.6
    }

    /// Waking: lids in stages with two half-blinks, the right eye a beat behind,
    /// the aperture holding its eye shape until the last quarter.
    static func wake(at time: Double) -> State {
        let t = (time / wakeDuration).clamped()
        guard t < 1 else { return .open }
        // Both lids follow this, the right one later, so they are never in step.
        let left = lidCurve(t)
        let right = lidCurve((t - 0.085 / 1.0).clamped()) * 0.94
        // The aperture stays eye-shaped while the lids work, then opens out.
        let growth = 1 + (State.fullGrowth - 1) * easeIn(progress(t, from: 0.74, to: 1), power: 2.2)
        // Focus follows the lids, and arrives a little after them.
        let focus = easeInOut(progress(min(left, right + 0.1), from: 0.25, to: 0.95))
        return State(left: left, right: right, growth: growth, focus: focus)
    }

    /// Falling asleep: the lids come down, catch themselves once, then go.
    static func sleep(at time: Double) -> State {
        let t = (time / sleepDuration).clamped()
        guard t < 1 else { return .closed }
        let fall = 1 - easeInOut(t)
        // One flutter: the lids lift a little on the way down, then lose.
        let flutter = 0.28 * bump(t, at: 0.46, width: 0.14)
        let left = (fall + flutter).clamped()
        let right = (fall + flutter * 0.6 - 0.05).clamped()
        // The aperture closes in from the frame almost at once.
        let growth = 1 + (State.fullGrowth - 1) * pow(1 - (t / 0.3).clamped(), 2)
        let focus = easeInOut(progress(max(left, right), from: 0.2, to: 0.9))
        return State(left: left, right: right, growth: growth, focus: focus)
    }

    /// The lid's own rise: up, a half-blink back, further up, a smaller dip,
    /// then all the way with a touch of overshoot. Values are how open the eye
    /// is at each stage; the animation reads as effort, not a slider.
    static func lidCurve(_ t: Double) -> Double {
        let stops: [(at: Double, value: Double)] = [
            (0.00, 0.00),
            (0.12, 0.30),   // a first crack of light
            (0.22, 0.10),   // and shut again
            (0.40, 0.62),
            (0.50, 0.34),   // a second, smaller blink
            (0.72, 0.92),
            (0.82, 0.86),   // settling
            (1.00, 1.00),
        ]
        for index in 1..<stops.count where t <= stops[index].at {
            let previous = stops[index - 1], next = stops[index]
            let span = next.at - previous.at
            let local = span > 0 ? (t - previous.at) / span : 1
            return previous.value + (next.value - previous.value) * easeInOut(local)
        }
        return 1
    }

    // MARK: - Shaping

    private static func progress(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return ((value - from) / (to - from)).clamped()
    }
    private static func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private static func easeIn(_ t: Double, power: Double) -> Double { pow(t.clamped(), power) }
    /// A soft hump, 0 either side of `at`.
    private static func bump(_ t: Double, at centre: Double, width: Double) -> Double {
        let x = (t - centre) / width
        return exp(-x * x)
    }
}

extension Double {
    func clamped() -> Double { min(max(self, 0), 1) }
}

/// The two eye windows: rounded rectangles where the robot draws its eyes, each
/// with its own openness, growing past the frame as the eyes finish opening.
struct EyeApertureShape: Shape {
    var state: EyeMotionSequence.State
    var pose: EyePose

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(state.left, state.right), state.growth) }
        set {
            state.left = newValue.first.first
            state.right = newValue.first.second
            state.growth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width / 320, rect.height / 240)
        let sx = rect.width / 320, sy = rect.height / 240
        for (centre, openness) in [(102.0, state.left), (218.0, state.right)] {
            let open = openness.clamped()
            guard open > 0.001 else { continue }
            // Lids gather speed at the ends of their travel.
            let height = pose.height * scale * pow(open, 1.35) * state.growth
            let width = pose.width * scale * state.growth
            // While the eye is narrow its centre sits low: the upper lid travels.
            let drop = (1 - open) * pose.height * scale * 0.3
            let radius = min(min(30, pose.height / 2) * scale * state.growth, height / 2)
            path.addRoundedRect(in: CGRect(x: centre * sx - width / 2,
                                           y: 120 * sy + drop - height / 2,
                                           width: width, height: height),
                                cornerSize: CGSize(width: radius, height: radius),
                                style: .continuous)
        }
        return path
    }
}

/// What the aperture does to the picture: masks it to the eye windows, and keeps
/// it out of focus — soft, dim and drained of colour — until the eyes are open.
struct EyeApertureVeil: ViewModifier {
    var state: EyeMotionSequence.State
    var pose: EyePose
    /// Reduce Motion: no lids, just a fade.
    var reduceMotion = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(max(state.left, state.right))
        } else {
            // One view tree at every state, deliberately: an `if` that skipped
            // the mask while awake made SwiftUI rebuild the subtree, and the
            // animation was lost (2026-09-17).
            let soft = 1 - state.focus
            content
                .blur(radius: 18 * soft * soft)
                .saturation(1 - 0.55 * soft)
                // Morning light: washed out at first, settling as focus arrives.
                .brightness(0.06 * soft)
                .contrast(1 - 0.25 * soft)
                .scaleEffect(1 + 0.06 * soft)
                .mask {
                    EyeApertureShape(state: state, pose: pose)
                        .fill(.white)
                        // Lids are skin, not a stencil; softer while barely open.
                        .blur(radius: 3 + 5 * soft)
                }
        }
    }
}

extension View {
    func eyeAperture(_ state: EyeMotionSequence.State, pose: EyePose, reduceMotion: Bool = false) -> some View {
        modifier(EyeApertureVeil(state: state, pose: pose, reduceMotion: reduceMotion))
    }
}
