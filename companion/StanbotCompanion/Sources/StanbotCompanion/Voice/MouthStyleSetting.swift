import SwiftUI

/// Where the chosen mouth lives, and how the robot is told about it.
///
/// One setting, read by the app's face and pushed to the robot, so the two
/// never disagree about what Stanbot's face is. It exists because the choice
/// between a mouth and a speaker grille is a matter of taste that can only be
/// settled by looking at both (docs/voice.md, "A second style").
enum MouthStyleSetting {
    static let key = "StanbotMouthStyle"

    static var current: MouthStyle {
        get { MouthStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .capsule }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
