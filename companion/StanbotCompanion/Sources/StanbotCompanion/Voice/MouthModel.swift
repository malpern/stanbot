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

    private(set) var opening = 0.0
    private(set) var shape = 0.0
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
    }

    /// True while the mouth is still moving toward rest or a target.
    var settled: Bool {
        abs(opening) < 0.001 && abs(shape) < 0.001 && abs(openVelocity) < 0.001 && abs(shapeVelocity) < 0.001
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
