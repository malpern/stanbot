import CoreGraphics
import Foundation

/// How Stanbot looks and what it says in the app, from what is actually true
/// about the robot right now. Personality lives here and nowhere near the
/// safety surfaces: motor power, Stop and telemetry stay plain and literal.
///
/// The captions obey the project's rule about perception: a detected face is
/// "someone", never eye contact, and nothing here claims the robot feels
/// anything. They describe what it is doing.
struct Mood: Equatable {
    var emotion: Emotion
    var caption: String
    var asleep = false
    var attending = false
    /// Where the Mac eyes look, -1...1, toward the selected face in the window.
    var look: CGPoint? = nil
    /// Glancing side to side: looking for the robot on the network.
    var scanning = false
    /// The person faces Stanbot: the eyes lock on and the pupils dilate.
    var engaged = false
    /// How much of the frame the face fills, 0...1: closer faces draw the eyes together.
    var closeness = 0.0

    /// No face for this long, camera on and nothing to do: Stanbot gets drowsy.
    static let drowsyAfter: TimeInterval = 90

    /// What the big empty state in the video area says when there is no picture.
    /// The right-hand panel compares its caption against this and stays quiet
    /// when the two would say the same thing, so the window never repeats
    /// itself (e.g. "Opening my eyes…" in both places at once).
    static func placeholderHeadline(connection: RobotConnection.ConnectionState,
                                    camera: RobotConnection.CameraState) -> String {
        switch connection {
        case .disconnected, .unavailable: return "Stanbot is asleep"
        case .connecting: return "Waking up…"
        case .connected: return camera == .waiting ? "Opening my eyes…" : "My eyes are closed"
        }
    }

    static func of(connection: RobotConnection.ConnectionState, camera: RobotConnection.CameraState,
                   face: FaceSelection.State, box: FaceBox?, follow: FollowState,
                   noFaceFor: TimeInterval = 0, engaged: Bool = false, sleeping: Bool = false) -> Mood {
        if sleeping, case .connected = connection {
            return Mood(emotion: .sleepy, caption: "Asleep", asleep: true)
        }
        switch connection {
        case .disconnected, .unavailable:
            return Mood(emotion: .sleepy, caption: "Asleep", asleep: true)
        case .connecting:
            return Mood(emotion: .normal, caption: "Waking up…", scanning: true)
        case .connected:
            break
        }
        if case .finished(let result) = follow, !result.retryable {
            return Mood(emotion: .trouble, caption: "Something’s wrong")
        }
        let look = box.map { CGPoint(x: $0.rect.midX * 2 - 1, y: 1 - $0.rect.midY * 2) }
        let closeness = Double(box?.rect.width ?? 0)
        let locked = engaged && face == .tracking && box != nil
        if case .following = follow {
            return face == .tracking
                ? Mood(emotion: .focused, caption: "Following you", attending: true, look: look,
                       engaged: locked, closeness: closeness)
                : Mood(emotion: .normal, caption: "Looking for you")
        }
        switch camera {
        case .off: return Mood(emotion: .sleepy, caption: "Eyes closed")
        case .waiting: return Mood(emotion: .squint, caption: "Opening my eyes…")
        case .unavailable: return Mood(emotion: .worried, caption: "Can’t see")
        case .receiving: break
        }
        switch face {
        case .searching:
            return noFaceFor >= drowsyAfter
                ? Mood(emotion: .sleepy, caption: "Getting sleepy…")
                : Mood(emotion: .normal, caption: "Looking around")
        case .acquiring: return Mood(emotion: .surprised, caption: "Is someone there?")
        case .tracking:
            // Engaged: Stanbot looks at you. Otherwise it knows someone is there
            // and mostly looks away, with the odd glance.
            return locked
                ? Mood(emotion: .normal, caption: "Looking at you", attending: true, look: look, engaged: true, closeness: closeness)
                : Mood(emotion: .happy, caption: "I see someone", attending: true, look: look, closeness: closeness)
        case .uncertain: return Mood(emotion: .skeptic, caption: "Where did you go?", look: look)
        }
    }
}
