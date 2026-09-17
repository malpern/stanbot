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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinkSeed = Double.random(in: 0...1000)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: asleep)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                // The robot's display is 320x240; everything scales from there.
                let scale = min(proxy.size.width / 320, proxy.size.height / 240)
                let pose = EyePose.of(asleep ? .sleepy : emotion)
                let blink = asleep ? 1 : Self.blink(at: t + blinkSeed)
                let gaze = look ?? (reduceMotion ? .zero : CGPoint(x: sin(t / 2.4) * 0.18, y: sin(t / 3.1) * 0.08))
                ZStack {
                    if screen {
                        RoundedRectangle(cornerRadius: 36 * scale, style: .continuous).fill(.black)
                    }
                    HStack(spacing: (218 - 102) * scale - pose.width * scale) {
                        if asleep {
                            closedEye(width: pose.width, scale: scale)
                            closedEye(width: pose.width, scale: scale)
                        } else {
                            eye(pose: pose, scale: scale, blink: blink, gaze: gaze)
                            eye(pose: pose, scale: scale, blink: blink, gaze: gaze)
                        }
                    }
                }
                .frame(width: 320 * scale, height: 240 * scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: emotion)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: look)
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0), value: asleep)
        .accessibilityElement()
        .accessibilityLabel(asleep ? "Stanbot, asleep" : "Stanbot, \(emotion.title.lowercased())")
    }

    /// 0 open ... 1 closed. A 180 ms blink roughly every six seconds, livelier
    /// than the robot's twenty so the Mac face reads as awake at a glance.
    static func blink(at t: TimeInterval) -> Double {
        let period = 6.0, length = 0.18
        let phase = t.truncatingRemainder(dividingBy: period)
        guard phase < length else { return 0 }
        let p = phase / length
        return p < 0.5 ? p * 2 : (1 - p) * 2
    }

    /// Asleep: two soft downward curves, not a squashed open eye.
    private func closedEye(width: Double, scale: Double) -> some View {
        ClosedEye()
            .stroke(Color(white: 0.74), style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round))
            .frame(width: width * 0.8 * scale, height: 22 * scale)
            .frame(width: width * scale)
    }

    private func eye(pose: EyePose, scale: Double, blink: Double, gaze: CGPoint) -> some View {
        let height = max(6, pose.height * (1 - blink))
        let radius = min(30, height / 2)
        let pupil = max(6, min(18, height / 4) * pose.pupilScale)
        let iris: Color = attending ? Color(red: 0, green: 1, blue: 1) : Color(white: 0.74)
        return ZStack {
            RoundedRectangle(cornerRadius: radius * scale, style: .continuous)
                .fill(iris)
                .frame(width: pose.width * scale, height: height * scale)
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
        .frame(width: pose.width * scale, height: max(pose.height, 6) * scale)
        .compositingGroup()
    }
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
