import CoreGraphics
import Foundation

/// What the Mac's face IS, separately from how it is painted.
///
/// The mirror of `firmware/lib/StanbotEyes/src/FaceGeometry.h`. Stanbot has two
/// faces and they are meant to be one character at two fidelities: the same
/// state read the same way, drawn with whatever each machine can afford. That
/// held only while somebody kept two piles of numbers equal by hand, and it
/// repeatedly did not -- closed eyes were a sagging curve here and a 2 px bar
/// on the robot; the frown sat 12 px off the bottom of the screen in both,
/// hand-copied and wrong twice over.
///
///     State and shape may not differ. Fidelity may.
///
/// So this describes where each thing is, how big, and what kind -- and says
/// nothing about glow, bokeh, springs, shadows or anti-aliasing, all of which
/// are supposed to differ and none of which anyone experiences as the two faces
/// disagreeing. `FaceGeometryTests` checks this against
/// `companion/face-geometry.json`, which is the robot's own answer for the same
/// states.
struct FaceGeometry: Equatable {
    /// The panel both faces are laid out in. The view scales this; it does not
    /// re-describe it.
    static let screenWidth = 320.0
    static let screenHeight = 240.0
    static let eyeLeftX = 102.0
    static let eyeRightX = 218.0
    static let eyeY = 120.0

    enum EyeKind: String, Equatable {
        case open, closed, crossed
    }

    var eyeKind: EyeKind = .open
    var eyeWidth = 0
    var eyeHeight = 0
    /// How far the lids have come down, 0 open and 100 shut. Whole numbers, so
    /// the two sides cannot disagree about floating point.
    var shut = 0

    var frownVisible = false
    var frownY = 0
    var frownRadius = 0

    var mouthVisible = false
    var mouthX = 0
    var mouthY = 0

    /// The trouble face's numbers, matching `kTroubleArm`/`kTroubleStroke` and
    /// `kFrownY`/`kFrownInner`/`kFrownOuter` in the firmware.
    static let troubleArm = 30
    static let troubleStroke = 6
    static let frownY = 210
    static let frownRadius = 26
    /// The closed lid's box: `kClosedWidth` and `kClosedSag + kClosedStroke`.
    static let closedWidth = 70
    static let closedHeight = 27
    /// Below this much lid left, an eye is drawn as the closed curve
    /// (`kClosedLidsFrom`).
    static let closedLidsFrom = 0.16

    /// The face for a state. `openness` is the sleep curtain, 1 open and 0
    /// shut; `emotion` is what the robot was last told to show.
    /// Whether a mouth is being drawn at all. Its size is not part of the
    /// agreement: each side runs its own spring from its own audio.
    static func of(emotion: Emotion, openness: Double = 1, speaking: Bool = false) -> FaceGeometry {
        var face = FaceGeometry()
        let lids = max(0, min(1, openness))
        face.shut = Int(((1 - lids) * 100).rounded())

        if emotion == .trouble && lids > closedLidsFrom {
            face.eyeKind = .crossed
            face.eyeWidth = 2 * (troubleArm + troubleStroke)
            face.eyeHeight = 2 * (troubleArm + troubleStroke)
        } else if lids <= closedLidsFrom {
            face.eyeKind = .closed
            face.eyeWidth = closedWidth
            face.eyeHeight = closedHeight
        } else {
            let pose = EyePose.of(emotion)
            face.eyeKind = .open
            face.eyeWidth = Int(pose.width)
            face.eyeHeight = max(2, Int(pose.height * lids))
        }

        if emotion == .trouble {
            face.frownVisible = true
            face.frownY = frownY
            face.frownRadius = frownRadius
        } else if speaking {
            // The speaking mouth and the frown never appear together: the robot
            // draws the frown and returns before the mouth.
            face.mouthVisible = true
            face.mouthX = Int(MouthModel.centerX)
            face.mouthY = Int(MouthModel.centerY)
        }
        return face
    }
}
