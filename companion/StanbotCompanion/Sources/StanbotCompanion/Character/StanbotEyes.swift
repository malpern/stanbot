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
        case .trouble: EyePose(width: 86, height: 112, tilt: 0, pupilScale: 1)
        }
    }
}

struct StanbotEyesView: View {
    var emotion: Emotion = .normal
    /// Where the person is, -1...1 on each axis (+x right, +y down), or nil.
    var look: CGPoint? = nil
    /// Closed eyes: asleep, not connected.
    var asleep = false
    /// Whether attending to someone. The irises stay grey either way: on the
    /// robot, a face now lights the body's LED bar blue instead.
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
    /// The person faces Stanbot: lock onto `look`, follow it, dilate.
    var engaged = false
    /// How much of the camera frame the face fills, 0...1. Closer draws the eyes together.
    var closeness = 0.0
    /// What a click does instead of giggling.
    var onTap: (() -> Void)? = nil
    /// The mouth's thinnest line in points, so tiny faces keep a visible mouth.
    var mouthMinimumPoints = 0.0
    /// The mouth's Metal glow and inner light; off for tiny faces.
    var mouthGlow = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer: CGPoint?
    @State private var tapped: EyeReaction?
    @State private var recognized: EyeReaction?
    /// Gaze and blink are state changed a few times a second and animated by
    /// SwiftUI, not a 30 fps clock (measured 2026-09-16: the clock cost 9-13% CPU).
    @State private var fixation = CGPoint.zero
    @State private var micro = CGPoint.zero
    @State private var blinking = false
    @State private var dilation = 1.0
    @State private var latestFace: CGPoint?
    @State private var planner = GazePlanner()

    /// The newest of the reactions handed in, from a click, and from recognition.
    private var current: EyeReaction? {
        [reaction, tapped, recognized].compactMap { $0 }.max { $0.date < $1.date }
    }

    private var locked: Bool { engaged && look != nil && !asleep }

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
        // Smooth pursuit while locked on: the eyes follow the face between frames.
        .animation(reduceMotion || !locked ? nil : .spring(response: 0.6, dampingFraction: 1), value: look)
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: pointer)
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0), value: asleep)
        .onChange(of: look, initial: true) { _, new in latestFace = new }
        .onChange(of: locked, initial: true) { was, now in
            // Pupils widen quickly and relax slowly, as people's do.
            let spring: Animation = now ? .spring(duration: 0.8, bounce: 0) : .spring(duration: 1.5, bounce: 0)
            withAnimation(reduceMotion ? nil : spring) { dilation = now ? 1.15 : 1 }
            if now && !was { recognized = EyeReaction(kind: .recognize) }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if asleep { return "Stanbot, asleep" }
        return locked ? "Stanbot, looking at you" : "Stanbot, \(emotion.title.lowercased())"
    }

    private func face(motion: EyeMotion) -> some View {
        GeometryReader { proxy in
            // The robot's display is 320x240; everything scales from there.
            let scale = min(proxy.size.width / 320, proxy.size.height / 240)
            let pose = EyePose.of(asleep ? .sleepy : emotion)
            let openness = max(0, (blinking && !asleep ? 0 : 1) * motion.openness)
            let gaze = currentGaze
            // Close faces draw the eyes together a little (vergence).
            let converge = reduceMotion ? 0 : min(max(closeness, 0), 0.4) / 0.4 * 0.16
            ZStack {
                if screen {
                    RoundedRectangle(cornerRadius: 36 * scale, style: .continuous).fill(.black)
                }
                ZStack {
                    HStack(spacing: (218 - 102) * scale - pose.width * scale) {
                        if asleep {
                            closedEye(width: pose.width, scale: scale)
                            closedEye(width: pose.width, scale: scale)
                        } else if emotion == .trouble {
                            TroubleFace(scale: scale, glow: screenLook)
                        } else {
                            eye(pose: pose, scale: scale, openness: openness,
                                gaze: CGPoint(x: gaze.x + converge, y: gaze.y))
                            eye(pose: pose, scale: scale, openness: openness,
                                gaze: CGPoint(x: gaze.x - converge, y: gaze.y))
                        }
                    }
                    // The mouth, where the robot draws it (MouthModel): a resting
                    // line, shaping while Stanbot speaks. The trouble face has its own.
                    if emotion != .trouble {
                        StanbotMouthView(scale: scale, glow: mouthGlow, minimumPoints: mouthMinimumPoints)
                            .offset(y: (MouthModel.centerY - 120) * scale)
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
                if let onTap { onTap(); return }
                guard interactive, !asleep else { return }
                tapped = EyeReaction(kind: .giggle)
            }
        }
        .task(id: BlinkKey(asleep: asleep, locked: locked)) { await blinkLoop() }
        .task(id: IdleKey(scanning: scanning, asleep: asleep, reduceMotion: reduceMotion, locked: locked,
                          hasFace: look != nil)) { await gazeLoop() }
    }

    /// Pointer first; locked on, the face plus a micro-saccade; otherwise the
    /// current fixation (which includes the odd glance at someone who is there).
    private var currentGaze: CGPoint {
        if let pointer { return pointer }
        if locked, let look { return CGPoint(x: look.x + micro.x, y: look.y + micro.y) }
        if reduceMotion { return .zero }
        return fixation
    }

    private struct IdleKey: Hashable { let scanning: Bool, asleep: Bool, reduceMotion: Bool, locked: Bool, hasFace: Bool }
    private struct BlinkKey: Hashable { let asleep: Bool, locked: Bool }

    /// A 180 ms blink every twelve to twenty seconds; less often while locked
    /// on, as people blink less when they attend. A little after locking on,
    /// one slow, soft blink. Every five to eight seconds was lifelike and, on a
    /// face that is always in view, too busy.
    private func blinkLoop() async {
        guard !asleep else { blinking = false; return }
        if locked && !reduceMotion {
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.28)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(380))
            withAnimation(.easeInOut(duration: 0.34)) { blinking = false }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(locked ? Int.random(in: 15000...25000) : Int.random(in: 12000...20000)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.09)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.09)) { blinking = false }
        }
    }

    /// Scanning sweeps side to side. Locked on, a barely visible adjustment
    /// every few seconds. Otherwise slow glides between resting points chosen
    /// by GazePlanner, held 5-10 s. Calm on purpose; see GazePlanner.
    private func gazeLoop() async {
        guard !asleep, !reduceMotion else { fixation = .zero; micro = .zero; return }
        let glide = Animation.spring(response: 0.7, dampingFraction: 1)
        var right = true
        while !Task.isCancelled {
            if scanning {
                // Look, pause, look the other way: reads as searching, and the
                // pauses keep a loader that may run a while from animating constantly.
                withAnimation(.easeInOut(duration: 0.6)) { fixation = CGPoint(x: right ? 0.85 : -0.85, y: 0) }
                right.toggle()
                try? await Task.sleep(for: .milliseconds(1300))
            } else if locked {
                withAnimation(glide) {
                    micro = CGPoint(x: Double.random(in: -0.015...0.015), y: Double.random(in: -0.01...0.01))
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 4000...8000)))
            } else {
                let next = planner.next(face: latestFace)
                withAnimation(glide) { fixation = next.point }
                try? await Task.sleep(for: .milliseconds(Int(next.hold * 1000)))
            }
        }
    }

    /// Asleep: two soft downward curves, not a squashed open eye.
    private func closedEye(width: Double, scale: Double) -> some View {
        ClosedEye()
            .stroke(Color(white: 0.74), style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round))
            .shadow(color: screenLook ? Color(white: 0.74).opacity(0.3) : .clear, radius: 10 * scale)
            .frame(width: width * 0.8 * scale, height: 22 * scale)
            .frame(width: width * scale)
    }

    private func eye(pose: EyePose, scale: Double, openness: Double, gaze: CGPoint) -> some View {
        // Looking down lowers the lids a little, as it does on a face.
        let lid = 1 - 0.18 * max(0, min(gaze.y, 1))
        let height = max(6, pose.height * openness * lid)
        let radius = min(30, height / 2)
        let base = max(6, min(18, height / 4) * pose.pupilScale)
        // Dilation widens the pupil, never past the edge of the eye.
        let pupil = min(base * dilation, min(pose.width, height) / 2 - 4)
        let iris = Color(white: 0.74)
        let px = gaze.x * 18, py = gaze.y * 12
        return ZStack {
            RoundedRectangle(cornerRadius: radius * scale, style: .continuous)
                .fill(iris)
                .frame(width: pose.width * scale, height: height * scale)
                // Lit pixels bleed a little light, as on the robot's screen.
                .shadow(color: screenLook ? iris.opacity(0.35) : .clear, radius: 14 * scale)
            Circle()
                .fill(.black)
                .frame(width: max(pupil, 6) * 2 * scale, height: max(pupil, 6) * 2 * scale)
                .offset(x: px * scale, y: py * scale)
            if height > 24 {
                // Two catchlights, which stay put a little while the pupil moves:
                // the reflection belongs to the room, not the eye.
                Circle()
                    .fill(.white)
                    .frame(width: max(2, pupil / 5) * 2 * scale, height: max(2, pupil / 5) * 2 * scale)
                    .offset(x: (px * 0.85 - pupil / 3) * scale, y: (py * 0.85 - pupil / 3) * scale)
                Circle()
                    .fill(.white.opacity(0.75))
                    .frame(width: max(1, pupil / 9) * 2 * scale, height: max(1, pupil / 9) * 2 * scale)
                    .offset(x: (px * 0.85 + pupil / 2.6) * scale, y: (py * 0.85 + pupil / 3.2) * scale)
            }
            BrowCut(tilt: pose.tilt * scale)
                .fill(.black)
                .frame(width: pose.width * scale, height: height * scale)
        }
        .frame(width: pose.width * scale, height: max(pose.height * 1.2, 6) * scale)
        .compositingGroup()
    }
}

/// Something went wrong: two crossed-out eyes where the eyes were and a frown
/// below, after the Sad Mac, in the same grey and the same places the robot
/// draws its own (StanbotEyes::drawTrouble). Still, so it reads as a state.
struct TroubleFace: View {
    var scale: Double
    var glow = false

    var body: some View {
        let grey = Color(white: 0.74)
        let arm = 30 * scale, stroke = 12 * scale
        // Laid out in the robot's 320x240 frame: eyes at x 102 and 218, y 120,
        // the frown's arc centred at (160, 210) -- StanbotEyes.h kFrownY, and
        // the two must stay equal. It was 232 until 2026-09-18, which put the
        // curve 12 px off the bottom of a 240-tall screen against 84 px of
        // space above it; every other expression sits evenly.
        ZStack {
            ForEach([102.0, 218.0], id: \.self) { centre in
                Path { path in
                    path.move(to: CGPoint(x: -arm, y: -arm)); path.addLine(to: CGPoint(x: arm, y: arm))
                    path.move(to: CGPoint(x: -arm, y: arm)); path.addLine(to: CGPoint(x: arm, y: -arm))
                }
                .stroke(grey, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: 1, height: 1)
                .offset(x: (centre - 160) * scale)
            }
            Path { path in
                path.addArc(center: .zero, radius: 26 * scale, startAngle: .degrees(190), endAngle: .degrees(350), clockwise: false)
            }
            .stroke(grey, style: StrokeStyle(lineWidth: 8 * scale, lineCap: .round))
            .frame(width: 1, height: 1)
            .offset(y: (210 - 120) * scale)
        }
        .shadow(color: glow ? grey.opacity(0.35) : .clear, radius: 14 * scale)
        .frame(width: 320 * scale, height: 240 * scale)
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
