import Foundation

/// Head orientation Vision reports with a face rectangle, in degrees.
/// Positive yaw is the face turned toward the image's right; `pitch` is nil
/// where the request revision does not provide it.
struct HeadPose: Equatable, Sendable {
    let yaw: Double
    let pitch: Double?
    let roll: Double?
}

/// A first, deliberately coarse answer to "is this person facing the robot?",
/// from head orientation alone. It is the gate a gaze model would sit behind
/// (docs/gaze.md): a head turned well away is not looking at the robot whatever
/// the eyes do, while a head pointed at the camera is only *facing* it. This
/// never claims eye contact.
///
/// Logged only; nothing in the UI or on the robot uses it yet. The thresholds
/// are starting guesses to be fitted on labelled clips from the robot's camera.
enum Facing: String, Equatable, Sendable {
    /// Head pointed roughly at the camera.
    case toward
    /// Head clearly turned away.
    case away
    /// Too small, or no pose: say nothing rather than guess.
    case unknown

    static let maxYawDegrees = 35.0
    static let maxPitchDegrees = 30.0
    /// Below this the face is a few dozen pixels and orientation is unreliable.
    /// A guess, not a published figure; see docs/gaze.md.
    static let minFacePixels = 48.0

    static func classify(_ box: FaceBox) -> Facing {
        guard let pose = box.pose, let frameWidth = box.frameWidth,
              pose.yaw.isFinite, box.rect.width * Double(frameWidth) >= minFacePixels
        else { return .unknown }
        if abs(pose.yaw) > maxYawDegrees { return .away }
        if let pitch = pose.pitch, pitch.isFinite, abs(pitch) > maxPitchDegrees { return .away }
        return .toward
    }
}
