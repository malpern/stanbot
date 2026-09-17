import Foundation

/// Stanbot's speaking mouth on the Mac: the same model the robot runs
/// (firmware/lib/StanbotEyes/src/MouthModel.h), so both screens open and close
/// together. `CharacterTests` checks these constants against the header.
///
/// The app feeds it loudness directly rather than through packets, so it has
/// no sequence handling; the silence timeout, spring and fade are the robot's.
struct MouthModel {
    static let centerX = 160.0
    static let centerY = 212.0
    static let closedHeight = 3.0
    static let openHeight = 18.0
    static let closedWidth = 36.0
    static let openWidth = 44.0
    static let rim = 3.0
    static let silenceCloseMs = 400.0
    static let fadeMs = 150.0
    static let springOmega = 28.0

    private(set) var opening = 0.0
    private(set) var presence = 0.0
    private var velocity = 0.0
    private var target = 0.0
    private var lastValueAt: TimeInterval?
    private var lastUpdate: TimeInterval?

    /// Loudness 0...1, as the robot receives it (0-100).
    mutating func receive(_ value: Double, at now: TimeInterval) {
        target = min(max(value, 0), 1)
        lastValueAt = now
    }

    mutating func update(at now: TimeInterval) {
        var dt = now - (lastUpdate ?? now)
        lastUpdate = now
        dt = min(max(dt, 0), 0.1)
        let speaking = lastValueAt.map { (now - $0) * 1000 < Self.silenceCloseMs } ?? false
        let goal = speaking ? target : 0
        var left = dt
        while left > 0 {
            let step = min(left, 0.01)
            let accel = Self.springOmega * Self.springOmega * (goal - opening) - 2 * Self.springOmega * velocity
            velocity += accel * step
            opening += velocity * step
            left -= 0.01
        }
        if opening < 0 { opening = 0; velocity = max(velocity, 0) }
        if opening > 1 { opening = 1; velocity = min(velocity, 0) }
        let present = speaking || opening > 0.02
        let fade = dt * 1000 / Self.fadeMs
        presence = min(max(presence + (present ? fade : -fade), 0), 1)
    }

    /// Outer capsule size in robot display pixels.
    var width: Double { (Self.closedWidth + (Self.openWidth - Self.closedWidth) * opening) * presence }
    var height: Double { Self.closedHeight + (Self.openHeight - Self.closedHeight) * opening }
}
