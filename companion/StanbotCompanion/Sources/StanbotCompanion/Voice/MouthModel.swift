import Foundation

/// Stanbot's mouth on the Mac: the same model the robot runs
/// (firmware/lib/StanbotEyes/src/MouthModel.h), so both screens move together.
/// `MouthTests` checks these constants against the header.
///
/// The app feeds it targets directly rather than through packets, so it has no
/// sequence handling; the silence timeout and springs are the robot's.
struct MouthModel {
    static let centerX = 160.0
    static let centerY = 212.0
    static let restWidth = 40.0
    static let restHeight = 4.0
    static let openHeight = 22.0
    static let wideWidth = 16.0
    static let roundWidth = 14.0
    static let openNarrowing = 6.0
    static let wideFlatten = 0.4
    static let roundDeepen = 4.0
    static let rim = 3.0
    static let silenceRestMs = 400.0
    static let springOmega = 26.0
    static let fadeMs = 150.0

    private(set) var opening = 0.0
    private(set) var shape = 0.0
    /// 0 silent (no mouth) ... 1 speaking; the mouth grows in and shrinks away with it.
    private(set) var presence = 0.0
    private var openVelocity = 0.0
    private var shapeVelocity = 0.0
    private var target = MouthEnvelope.Frame.rest
    private var lastTargetAt: TimeInterval?
    private var lastUpdate: TimeInterval?

    mutating func receive(_ frame: MouthEnvelope.Frame, at now: TimeInterval) {
        target = MouthEnvelope.Frame(open: min(max(frame.open, 0), 1), shape: min(max(frame.shape, -1), 1))
        lastTargetAt = now
    }

    mutating func update(at now: TimeInterval) {
        let dt = min(max(now - (lastUpdate ?? now), 0), 0.1)
        lastUpdate = now
        let speaking = lastTargetAt.map { (now - $0) * 1000 < Self.silenceRestMs } ?? false
        let goal = speaking ? target : .rest
        var left = dt
        while left > 0 {
            let step = min(left, 0.01)
            Self.spring(&opening, &openVelocity, goal.open, step)
            Self.spring(&shape, &shapeVelocity, goal.shape, step)
            left -= 0.01
        }
        if opening < 0 { opening = 0; openVelocity = max(openVelocity, 0) }
        if opening > 1 { opening = 1; openVelocity = min(openVelocity, 0) }
        if shape < -1 { shape = -1; shapeVelocity = max(shapeVelocity, 0) }
        if shape > 1 { shape = 1; shapeVelocity = min(shapeVelocity, 0) }
        let present = speaking || opening > 0.02 || abs(shape) > 0.02
        presence = min(max(presence + (present ? 1 : -1) * dt * 1000 / Self.fadeMs, 0), 1)
    }

    /// True once the mouth has gone: nothing left to animate.
    var settled: Bool {
        presence == 0 && abs(opening) < 0.001 && abs(shape) < 0.001
    }

    /// Width and height in robot display pixels, exactly as MouthModel::size.
    static func size(open: Double, shape: Double) -> CGSize {
        let wide = max(shape, 0), round = max(-shape, 0)
        return CGSize(width: restWidth + wideWidth * wide - roundWidth * round * open - openNarrowing * open,
                      height: restHeight + (openHeight - restHeight) * open * (1 - wideFlatten * wide) + roundDeepen * round * open)
    }

    private static func spring(_ value: inout Double, _ velocity: inout Double, _ goal: Double, _ step: Double) {
        let accel = springOmega * springOmega * (goal - value) - 2 * springOmega * velocity
        velocity += accel * step
        value += velocity * step
    }
}

/// Which mouth Stanbot wears. Mirrors `stanbot::MouthStyle` on the robot, and
/// the app tells the robot which to draw (`C,MOUTH,...`) so the two never
/// disagree about what Stanbot's face is.
enum MouthStyle: String, CaseIterable, Identifiable {
    case capsule, grille

    var id: String { rawValue }
    var title: String { self == .capsule ? "Mouth" : "Speaker" }
    /// What choosing it actually changes, for the Settings row.
    var detail: String {
        switch self {
        case .capsule: return "A mouth that opens and shapes with the voice."
        case .grille: return "A speaker panel with sound coming out of it."
        }
    }
    var command: String { self == .capsule ? "C,MOUTH,CAPSULE\n" : "C,MOUTH,GRILLE\n" }
}

/// The grille's geometry, in robot display pixels, matching `GrilleShape` in
/// `MouthModel.h` so the Mac and the robot agree about shape and differ only in
/// how well it is drawn.
struct GrilleGeometry {
    static let width = 74.0
    /// The panel, and everything inside derived from it. At 26 the slots broke
    /// out through the top and bottom at full voice and full mood, which
    /// destroys the metaphor: slots are cut INTO a panel. The container is the
    /// constraint; the expression is fitted to it.
    static let height = 36.0
    static let slots = 3.0
    static let slotThickness = 3.0
    static let rimV = 2.0
    static let maxTilt = 4.0
    /// How far from the middle a slot's outermost pixel may ever be.
    static var slotRoom: Double { height / 2 - rimV - slotThickness / 2 }
    /// What is left to spread into once the bow has taken its share.
    static var maxSpacing: Double { slotRoom - maxTilt }
    static let arcGap = 6.0
    static let arcMinLength = 4.0
    static let arcMaxLength = 11.0
    static let arcFirstAt = 0.18
    static let arcSecondAt = 0.55

    /// Slot spacing: louder speech opens the slots apart, the way a cone moves.
    /// The widest is what fits once the bow has its room, so a shout with a
    /// frown still sits inside the panel.
    static func spacing(open: Double) -> Double {
        maxSpacing * (0.5 + 0.5 * max(0, min(1, open)))
    }

    /// The outermost pixel any slot reaches, for this loudness and mood. Must
    /// never exceed `height / 2 - rimV`, and there is a test that says so.
    static func slotExtent(open: Double, mood: Double) -> Double {
        spacing(open: open) + abs(tilt(mood: mood)) + slotThickness / 2
    }

    /// How many arcs are showing, and how far they reach. Brightness stretches
    /// them, so an "ee" carries further than an "oo" at the same loudness.
    static func arcs(open: Double, shape: Double) -> (count: Double, length: Double) {
        let count = open >= arcSecondAt ? 2.0 : (open >= arcFirstAt ? 1.0 : 0.0)
        let reach = open * (1 + 0.25 * max(0, shape))
        return (count, min(arcMaxLength, arcMinLength + (arcMaxLength - arcMinLength) * reach))
    }

    /// Mood bends the outer slots: down when sad, up when pleased.
    static func tilt(mood: Double) -> Double { -max(-1, min(1, mood)) * maxTilt }
}
