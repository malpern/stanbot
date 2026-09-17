import CoreGraphics
import Foundation

/// Whether the selected person is engaging with Stanbot: their face turned
/// toward the camera, held for a moment. Drives the eyes locking on and the
/// pupils dilating, on the Mac and on the robot (the G line's engaged flag).
///
/// Built on the head-pose check (Facing), so it means "facing the robot", not
/// eye contact. Hysteresis keeps the eyes from flickering between states: it
/// takes a steady 0.4 s of facing to engage, and 0.8 s of not facing (or no
/// face) to let go. A face too small to judge holds whatever state it was in.
struct EngagementTracker {
    static let engageAfter: TimeInterval = 0.4
    static let releaseAfter: TimeInterval = 0.8

    private(set) var engaged = false
    private var facingSince: TimeInterval?
    private var notFacingSince: TimeInterval?

    mutating func update(_ face: FaceBox?, at now: TimeInterval) -> Bool {
        let facing = face.map(Facing.classify) ?? .away
        switch facing {
        case .toward:
            notFacingSince = nil
            if facingSince == nil { facingSince = now }
            if !engaged, let since = facingSince, now - since >= Self.engageAfter { engaged = true }
        case .away:
            facingSince = nil
            if notFacingSince == nil { notFacingSince = now }
            if engaged, let since = notFacingSince, now - since >= Self.releaseAfter { engaged = false }
        case .unknown:
            break   // too small to tell: hold
        }
        return engaged
    }

    mutating func reset() { self = EngagementTracker() }
}

/// Where the eyes rest next when nobody is engaging: the Mac side of the
/// firmware's GazeBrain.chooseFixation, with the same proportions. Pure and
/// seeded, so it can be tested for how often it looks at someone.
struct GazePlanner {
    static let peekChance = 0.22

    struct Fixation: Equatable {
        var point: CGPoint
        /// How long to hold it before the next jump.
        var hold: TimeInterval
        var isPeek: Bool
    }

    private var generator: SplitMix64

    init(seed: UInt64 = .random(in: 1...UInt64.max)) { generator = SplitMix64(seed: seed) }

    mutating func next(face: CGPoint?) -> Fixation {
        if let face, uniform(0, 1) < Self.peekChance {
            return Fixation(point: face, hold: uniform(0.26, 0.52), isPeek: true)
        }
        if let face {
            let side: Double = face.x > 0.05 ? -1 : (face.x < -0.05 ? 1 : (uniform(0, 1) < 0.5 ? 1 : -1))
            return Fixation(point: CGPoint(x: side * uniform(0.45, 0.9), y: uniform(0.1, 0.55)),
                            hold: uniform(0.9, 2.6), isPeek: false)
        }
        let side: Double = uniform(0, 1) < 0.5 ? 1 : -1
        return Fixation(point: CGPoint(x: side * uniform(0.3, 0.9), y: uniform(-0.35, 0.5)),
                        hold: uniform(0.9, 2.6), isPeek: false)
    }

    private mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(generator.next() % 10_000) / 10_000
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
