import SwiftUI

/// Waking up and falling asleep, as a shot from behind Stanbot's eyes.
///
/// Waking is the one that matters: eyes prising open in the morning. They come
/// up in stages, not one smooth glide; the two lids do not move in step; there
/// is one half-blink on the way (two, and a settle at the end, read as bouncing
/// — owner, 2026-09-17); everything is soft until they are properly open, and
/// only at the very end does the aperture grow past the frame so the picture is
/// simply *there*. Falling asleep is the same machinery,
/// quicker and with one last flutter.
///
/// Every value is a pure function of time since the sequence began, so the whole
/// thing can be rendered frame by frame in tests (`EyelidTests`).
enum EyeMotionSequence {
    /// Slow: a morning, not a shutter. That is the launch. Waking from a sleep
    /// the owner asked for is the same sequence, brisker (owner, 2026-09-17).
    static let wakeDuration = 2.4
    static let wakeFromSleepDuration = 1.5
    static let sleepDuration = 1.1

    struct State: Equatable {
        /// How open each eye is, 0...1. They differ: one lid is always lazier.
        var left: Double
        var right: Double
        /// 0 eye-sized ... 1 covering the frame, whatever the eye pose.
        var growth: Double
        /// 0 soft and washed out, 1 sharp: focus arrives with the lids.
        var focus: Double

        static let open = State(left: 1, right: 1, growth: 1, focus: 1)
        static let closed = State(left: 0, right: 0, growth: 0, focus: 0)

        /// Between two states, for carrying an interrupted sequence into the next.
        func blended(toward other: State, by t: Double) -> State {
            let t = t.clamped()
            return State(left: left + (other.left - left) * t, right: right + (other.right - right) * t,
                         growth: growth + (other.growth - growth) * t, focus: focus + (other.focus - focus) * t)
        }
    }

    /// A sequence interrupted by another (sleep clicked while waking, or the
    /// reverse) must not snap: the new one is blended in from where the eyes
    /// were over this long.
    static let handoverDuration = 0.3

    /// Waking: lids in stages with one half-blink, the right eye a beat behind,
    /// the aperture holding its eye shape until the last quarter.
    static func wake(at time: Double, duration: Double = wakeDuration) -> State {
        let t = (time / duration).clamped()
        guard t < 1 else { return .open }
        // Both lids follow this, the right one later, so they are never in step.
        let left = lidCurve(t)
        let right = lidCurve((t - 0.085 / 1.0).clamped()) * 0.94
        // The aperture stays eye-shaped while the lids work, then opens out.
        let growth = easeIn(progress(t, from: 0.74, to: 1), power: 2.2)
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
        let growth = pow(1 - (t / 0.3).clamped(), 2)
        let focus = easeInOut(progress(max(left, right), from: 0.2, to: 0.9))
        return State(left: left, right: right, growth: growth, focus: focus)
    }

    /// The lid's own rise: a first crack of light, back down, then a long
    /// unbroken rise to open. One dip is effort; more read as bouncing.
    static func lidCurve(_ t: Double) -> Double {
        let stops: [(at: Double, value: Double)] = [
            (0.00, 0.00),
            (0.14, 0.30),   // a first crack of light
            (0.27, 0.10),   // and shut again
            (1.00, 1.00),   // then all the way, slowly
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
        // Fully grown, one window covers the whole frame on its own, whatever
        // the eye pose: a squinting expression must not crop the picture.
        let coverWidth = rect.width * 2.4, coverHeight = rect.height * 2.4
        let g = state.growth.clamped()
        for (centre, openness) in [(102.0, state.left), (218.0, state.right)] {
            let open = openness.clamped()
            guard open > 0.001 else { continue }
            // Lids gather speed at the ends of their travel.
            let eyeHeight = pose.height * scale * pow(open, 1.35)
            let eyeWidth = pose.width * scale
            let height = eyeHeight + (coverHeight - eyeHeight) * g
            let width = eyeWidth + (coverWidth - eyeWidth) * g
            // While the eye is narrow its centre sits low: the upper lid travels.
            let drop = (1 - open) * pose.height * scale * 0.3 * (1 - g)
            let radius = min(min(30, pose.height / 2) * scale * (1 + 3 * g), height / 2)
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
