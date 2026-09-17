import Foundation

/// A short, one-off movement of Stanbot's eyes in response to something that
/// just happened. Reactions are brief (under half a second), start from rest,
/// and never loop; Reduce Motion skips them entirely.
struct EyeReaction: Equatable {
    enum Kind: Equatable, CaseIterable {
        case wake       // connected: flutter open
        case surprise   // a face appeared: eyes widen and lift
        case content    // a session ended normally: a slow double blink
        case shake      // refused or failed: a small no
        case giggle     // clicked: a little bounce
        case sparkle    // new firmware: a happy pulse
        case recognize  // someone faces Stanbot: a small widening as the eyes lock on
    }

    let kind: Kind
    let id = UUID()
    let date = Date()

    static func == (a: EyeReaction, b: EyeReaction) -> Bool { a.id == b.id }

    /// Six keyframes per property. Tables rather than builder logic, so every
    /// reaction is visible at a glance and testable.
    struct Plan: Equatable {
        var openness: [Double] = [1, 1, 1, 1, 1, 1]
        var dx: [Double] = [0, 0, 0, 0, 0, 0]
        var dy: [Double] = [0, 0, 0, 0, 0, 0]
        var scale: [Double] = [1, 1, 1, 1, 1, 1]
        var durations: [Double]

        var total: Double { durations.reduce(0, +) }
    }

    var plan: Plan {
        switch kind {
        case .wake:
            Plan(openness: [0.05, 0.05, 0.6, 0.25, 1, 1], durations: [0.01, 0.3, 0.16, 0.1, 0.2, 0.01])
        case .surprise:
            Plan(openness: [1.2, 1.2, 1, 1, 1, 1], dy: [-4, -4, 0, 0, 0, 0], scale: [1.1, 1.1, 1, 1, 1, 1],
                 durations: [0.08, 0.14, 0.18, 0.01, 0.01, 0.01])
        case .content:
            Plan(openness: [0.1, 1, 0.1, 1, 1, 1], durations: [0.08, 0.1, 0.08, 0.12, 0.01, 0.01])
        case .shake:
            Plan(dx: [-8, 8, -6, 5, -2, 0], durations: [0.05, 0.08, 0.08, 0.07, 0.06, 0.06])
        case .giggle:
            Plan(openness: [0.7, 0.7, 1, 1, 1, 1], dy: [-6, 0, -3, 0, -1, 0], durations: [0.09, 0.09, 0.08, 0.08, 0.06, 0.06])
        case .recognize:
            // A slow, slight widening; the quick 14% pop read as a start.
            Plan(openness: [1.05, 1.05, 1, 1, 1, 1], scale: [1.01, 1.01, 1, 1, 1, 1], durations: [0.25, 0.25, 0.27, 0.01, 0.01, 0.01])
        case .sparkle:
            Plan(openness: [1, 0.15, 1, 1, 1, 1], scale: [1.08, 1, 1.05, 1, 1, 1], durations: [0.1, 0.08, 0.12, 0.1, 0.01, 0.01])
        }
    }
}

/// What the app just saw change, reduced to the facts that reactions use.
struct ReactionFacts: Equatable {
    var connected: Bool
    var faceTracked: Bool
    var following: Bool
    var finishedCode: String?
    var firmwareCommit: String?

    /// The reaction for a change from `old` to `new`, if any. At most one: the
    /// most significant wins.
    static func reaction(from old: ReactionFacts, to new: ReactionFacts) -> EyeReaction.Kind? {
        if new.finishedCode != old.finishedCode, let code = new.finishedCode {
            return FollowResult(code: code).retryable ? .content : .shake
        }
        if new.firmwareCommit != old.firmwareCommit, old.firmwareCommit != nil, new.firmwareCommit != nil { return .sparkle }
        if new.connected && !old.connected { return .wake }
        if new.faceTracked && !old.faceTracked { return .surprise }
        return nil
    }
}
