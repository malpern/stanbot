import Foundation

/// State the Mac keeps on the robot's behalf, and hands back when it connects.
///
/// Three kinds of thing survive a reset here, and they live in three different
/// places on purpose (docs/head-following.md, "State that survives a reset"):
///
/// - **Measured constants** -- the yaw centre, pitch level, the limits -- live
///   in the firmware source, in git, because they are findings and belong in
///   history and review.
/// - **What the robot needs with nobody there** -- the Wi-Fi profiles, the OTA
///   passphrase -- live in the robot's own NVS, because it must work alone.
/// - **Guesses and preferences** -- where someone was last seen -- live *here*.
///   This one was in NVS for an hour on 2026-09-17 and was moved out: a value
///   the robot keeps to itself cannot be shown, diffed or cleared from the Mac,
///   and a stale one that quietly biases where the head looks is the kind of
///   bug that eats an afternoon. Here it can be printed, reset, and tested with
///   no robot present -- and it survives a full erase or a replacement CoreS3.
///
/// Adding another carried value is one key here and one `else if` in the
/// robot's `applyRestore`. Unknown keys are ignored at both ends, so an older
/// robot and a newer app tolerate each other.
enum RobotState {
    struct Place: Equatable {
        let yaw: Int, pitch: Int
    }

    static let lastSeenYawKey = "StanbotLastSeenYaw"
    static let lastSeenPitchKey = "StanbotLastSeenPitch"

    /// Where the robot last saw someone, in raw servo steps, or nil if this Mac
    /// has never watched it find anyone.
    static var lastSeen: Place? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: lastSeenYawKey) != nil,
                  defaults.object(forKey: lastSeenPitchKey) != nil else { return nil }
            return Place(yaw: defaults.integer(forKey: lastSeenYawKey),
                         pitch: defaults.integer(forKey: lastSeenPitchKey))
        }
        set {
            let defaults = UserDefaults.standard
            guard let newValue else {
                defaults.removeObject(forKey: lastSeenYawKey)
                defaults.removeObject(forKey: lastSeenPitchKey)
                return
            }
            defaults.set(newValue.yaw, forKey: lastSeenYawKey)
            defaults.set(newValue.pitch, forKey: lastSeenPitchKey)
        }
    }

    static func rememberLastSeen(yaw: Int, pitch: Int) {
        lastSeen = Place(yaw: yaw, pitch: pitch)
    }

    /// The line that hands it back, or nil when there is nothing to hand back.
    static func restoreLine(_ place: Place?) -> String? {
        guard let place else { return nil }
        return "K,lsy=\(place.yaw),lsp=\(place.pitch)\n"
    }
}
