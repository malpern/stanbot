import SwiftUI

/// Stanbot's face on the Mac: the same two eyes the robot draws on its own
/// display (firmware/lib/StanbotEyes), so the app and the robot are one
/// character. Poses match the firmware's `poseFor` exactly, in the robot's
/// 320x240 display units, and are scaled to whatever size this is drawn at.
///
/// It is presentation only. The eyes here never claim the robot is looking at
/// anyone: where they look is where the selected face is in the window.
struct EyePose: Equatable {
    var width: Double
    var height: Double
    var tilt: Double        // > 0: brows slope down toward the centre (cross); < 0: outward (sad)
    var pupilScale: Double

    /// The firmware's poses, value for value (StanbotEyes.h, poseFor).
    static func of(_ emotion: Emotion) -> EyePose {
        switch emotion {
        case .normal: EyePose(width: 86, height: 112, tilt: 0, pupilScale: 1)
        case .angry: EyePose(width: 90, height: 56, tilt: 18, pupilScale: 0.85)
        case .glee: EyePose(width: 90, height: 32, tilt: -4, pupilScale: 0.9)
        case .happy: EyePose(width: 90, height: 26, tilt: 0, pupilScale: 0.9)
        case .sad: EyePose(width: 82, height: 48, tilt: -14, pupilScale: 1.05)
        case .worried: EyePose(width: 82, height: 72, tilt: -8, pupilScale: 1.2)
        case .focused: EyePose(width: 92, height: 42, tilt: 9, pupilScale: 0.7)
        case .annoyed: EyePose(width: 92, height: 34, tilt: 12, pupilScale: 0.75)
        case .surprised: EyePose(width: 94, height: 130, tilt: 0, pupilScale: 1.25)
        case .skeptic: EyePose(width: 82, height: 84, tilt: 15, pupilScale: 0.85)
        case .frustrated: EyePose(width: 88, height: 32, tilt: 18, pupilScale: 0.7)
        case .unimpressed: EyePose(width: 94, height: 30, tilt: 0, pupilScale: 0.7)
        case .sleepy: EyePose(width: 88, height: 30, tilt: -10, pupilScale: 0.8)
        case .suspicious: EyePose(width: 84, height: 52, tilt: 12, pupilScale: 0.8)
        case .squint: EyePose(width: 72, height: 48, tilt: 0, pupilScale: 0.65)
        case .furious: EyePose(width: 92, height: 62, tilt: 24, pupilScale: 0.65)
        case .scared: EyePose(width: 92, height: 138, tilt: 0, pupilScale: 1.35)
        case .awe: EyePose(width: 100, height: 142, tilt: 0, pupilScale: 1.1)
        }
    }
}

struct StanbotEyesView: View {
    var emotion: Emotion = .normal
    /// Where to look, -1...1 on each axis (+x right, +y down), or nil to drift idly.
    var look: CGPoint? = nil
    /// Closed eyes: asleep, not connected.
    var asleep = false
    /// Cyan when attending to someone, as on the robot; soft grey otherwise.
    var attending = false
    /// Draw the robot's black screen behind the eyes.
    var screen = true
    /// Glance side to side, for "looking for the robot" while connecting.
    var scanning = false
    /// A one-off movement; a new value plays once.
    var reaction: EyeReaction? = nil
    /// Look at the pointer while it is over the eyes, and giggle when clicked.
    var interactive = false
    /// The robot-screen look: glowing irises and, when large, an LCD pixel grid.
    var screenLook = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer: CGPoint?
    @State private var tapped: EyeReaction?
    /// Idle gaze and blink as state changed a few times a second with SwiftUI
    /// animations, not a 30 fps clock: measured 2026-09-16, the clock cost
    /// 9-13% CPU with the eyes on screen and nothing happening.
    @State private var drift = CGPoint.zero
    @State private var blinking = false

    /// The newest of the reaction handed in and one from a click.
    private var current: EyeReaction? {
        [reaction, tapped].compactMap { $0 }.max { $0.date < $1.date }
    }

    var body: some View {
        let playing = reduceMotion ? nil : current
        KeyframeAnimator(initialValue: EyeMotion(), trigger: playing?.id) { motion in
            face(motion: motion)
        } keyframes: { _ in
                let plan = playing?.plan ?? EyeReaction.Plan(durations: [0.01, 0.01, 0.01, 0.01, 0.01, 0.01])
                KeyframeTrack(\.openness) {
                    CubicKeyframe(plan.openness[0], duration: plan.durations[0])
                    CubicKeyframe(plan.openness[1], duration: plan.durations[1])
                    CubicKeyframe(plan.openness[2], duration: plan.durations[2])
                    CubicKeyframe(plan.openness[3], duration: plan.durations[3])
                    CubicKeyframe(plan.openness[4], duration: plan.durations[4])
                    CubicKeyframe(plan.openness[5], duration: plan.durations[5])
                }
                KeyframeTrack(\.dx) {
                    CubicKeyframe(plan.dx[0], duration: plan.durations[0])
                    CubicKeyframe(plan.dx[1], duration: plan.durations[1])
                    CubicKeyframe(plan.dx[2], duration: plan.durations[2])
                    CubicKeyframe(plan.dx[3], duration: plan.durations[3])
                    CubicKeyframe(plan.dx[4], duration: plan.durations[4])
                    CubicKeyframe(plan.dx[5], duration: plan.durations[5])
                }
                KeyframeTrack(\.dy) {
                    CubicKeyframe(plan.dy[0], duration: plan.durations[0])
                    CubicKeyframe(plan.dy[1], duration: plan.durations[1])
                    CubicKeyframe(plan.dy[2], duration: plan.durations[2])
                    CubicKeyframe(plan.dy[3], duration: plan.durations[3])
                    CubicKeyframe(plan.dy[4], duration: plan.durations[4])
                    CubicKeyframe(plan.dy[5], duration: plan.durations[5])
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(plan.scale[0], duration: plan.durations[0])
                    SpringKeyframe(plan.scale[1], duration: plan.durations[1])
                    SpringKeyframe(plan.scale[2], duration: plan.durations[2])
                    SpringKeyframe(plan.scale[3], duration: plan.durations[3])
                    SpringKeyframe(plan.scale[4], duration: plan.durations[4])
                    SpringKeyframe(plan.scale[5], duration: plan.durations[5])
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: emotion)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: look)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: pointer)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0), value: asleep)
            .accessibilityElement()
            .accessibilityLabel(asleep ? "Stanbot, asleep" : "Stanbot, \(emotion.title.lowercased())")
    }

    private func face(motion: EyeMotion) -> some View {
        GeometryReader { proxy in
            // The robot's display is 320x240; everything scales from there.
            let scale = min(proxy.size.width / 320, proxy.size.height / 240)
            let pose = EyePose.of(asleep ? .sleepy : emotion)
            let openness = max(0, (blinking && !asleep ? 0 : 1) * motion.openness)
            ZStack {
                if screen {
                    RoundedRectangle(cornerRadius: 36 * scale, style: .continuous).fill(.black)
                }
                HStack(spacing: (218 - 102) * scale - pose.width * scale) {
                    if asleep {
                        closedEye(width: pose.width, scale: scale)
                        closedEye(width: pose.width, scale: scale)
                    } else {
                        eye(pose: pose, scale: scale, openness: openness, gaze: gaze)
                        eye(pose: pose, scale: scale, openness: openness, gaze: gaze)
                    }
                }
                .scaleEffect(motion.scale)
                .offset(x: motion.dx * scale * 2, y: motion.dy * scale * 2)
            }
            .frame(width: 320 * scale, height: 240 * scale)
            // The pixel grid re-renders every frame the eyes move: about 4% CPU
            // while scanning (measured 2026-09-16), so the loader goes without it.
            .modifier(ScreenLook(enabled: screenLook && !scanning, width: 320 * scale))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard interactive, !asleep else { pointer = nil; return }
                switch phase {
                case .active(let location):
                    pointer = CGPoint(x: max(-1, min(1, (location.x / proxy.size.width) * 2 - 1)),
                                      y: max(-1, min(1, (location.y / proxy.size.height) * 2 - 1)))
                case .ended:
                    pointer = nil
                }
            }
            .onTapGesture {
                guard interactive, !asleep else { return }
                tapped = EyeReaction(kind: .giggle)
            }
        }
        .task(id: asleep) { await blinkLoop() }
        .task(id: IdleKey(scanning: scanning, asleep: asleep, reduceMotion: reduceMotion)) { await gazeLoop() }
    }

    private struct IdleKey: Hashable { let scanning: Bool, asleep: Bool, reduceMotion: Bool }

    /// A 180 ms blink every five to eight seconds while awake.
    private func blinkLoop() async {
        guard !asleep else { blinking = false; return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 5000...8000)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.09)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.09)) { blinking = false }
        }
    }

    /// Scanning sweeps side to side; otherwise a slow wander. Nothing under
    /// Reduce Motion, and nothing while asleep.
    private func gazeLoop() async {
        guard !asleep, !reduceMotion else { drift = .zero; return }
        var right = true
        while !Task.isCancelled {
            if scanning {
                // Look, pause, look the other way: reads as searching, and the
                // pauses keep a loader that may run a while from animating constantly.
                withAnimation(.easeInOut(duration: 0.6)) { drift = CGPoint(x: right ? 0.85 : -0.85, y: 0) }
                right.toggle()
                try? await Task.sleep(for: .milliseconds(1300))
            } else {
                // An occasional glance, not a constant wander: the wander animated
                // ~60% of the time and cost ~10% CPU with the large eyes on screen
                // (measured 2026-09-16). Resting between glances is also calmer.
                withAnimation(.easeInOut(duration: 0.8)) {
                    drift = CGPoint(x: Double.random(in: -0.25...0.25), y: Double.random(in: -0.1...0.1))
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 4000...7000)))
            }
        }
    }

    /// Pointer first, then the face being looked at, then a scan or an idle drift.
    private var gaze: CGPoint { pointer ?? look ?? drift }

    /// Asleep: two soft downward curves, not a squashed open eye.
    private func closedEye(width: Double, scale: Double) -> some View {
        ClosedEye()
            .stroke(Color(white: 0.74), style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round))
            .shadow(color: screenLook ? Color(white: 0.74).opacity(0.3) : .clear, radius: 10 * scale)
            .frame(width: width * 0.8 * scale, height: 22 * scale)
            .frame(width: width * scale)
    }

    private func eye(pose: EyePose, scale: Double, openness: Double, gaze: CGPoint) -> some View {
        let height = max(6, pose.height * openness)
        let radius = min(30, height / 2)
        let pupil = max(6, min(18, height / 4) * pose.pupilScale)
        let iris: Color = attending ? Color(red: 0, green: 1, blue: 1) : Color(white: 0.74)
        return ZStack {
            RoundedRectangle(cornerRadius: radius * scale, style: .continuous)
                .fill(iris)
                .frame(width: pose.width * scale, height: height * scale)
                // Lit pixels bleed a little light, as on the robot's screen.
                .shadow(color: screenLook ? iris.opacity(attending ? 0.7 : 0.35) : .clear, radius: 14 * scale)
            Circle()
                .fill(.black)
                .frame(width: pupil * 2 * scale, height: pupil * 2 * scale)
                .offset(x: gaze.x * 18 * scale, y: gaze.y * 12 * scale)
            if height > 24 {
                Circle()
                    .fill(.white)
                    .frame(width: max(2, pupil / 5) * 2 * scale, height: max(2, pupil / 5) * 2 * scale)
                    .offset(x: (gaze.x * 18 - pupil / 3) * scale, y: (gaze.y * 12 - pupil / 3) * scale)
            }
            BrowCut(tilt: pose.tilt * scale)
                .fill(.black)
                .frame(width: pose.width * scale, height: height * scale)
        }
        .frame(width: pose.width * scale, height: max(pose.height * 1.2, 6) * scale)
        .compositingGroup()
    }
}

/// The animatable part of a reaction.
struct EyeMotion {
    var openness = 1.0
    var dx = 0.0
    var dy = 0.0
    var scale = 1.0
}

/// The black triangle the firmware draws across the top of each eye for a
/// brow. Animatable, so expressions slide into each other.
private struct BrowCut: Shape {
    var tilt: Double
    var animatableData: Double {
        get { tilt }
        set { tilt = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard abs(tilt) > 0.1 else { return path }
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: tilt > 0 ? CGPoint(x: rect.maxX, y: rect.minY + tilt) : CGPoint(x: rect.minX, y: rect.minY - tilt))
        path.closeSubpath()
        return path
    }
}

private struct ClosedEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return path
    }
}
