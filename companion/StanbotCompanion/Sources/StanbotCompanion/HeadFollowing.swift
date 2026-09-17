import Foundation
import SwiftUI

/// Where the app is with a head-following session. The robot owns the session:
/// it enforces the limits and the power cutoff: a 20 s lease it renews while it
/// keeps receiving targets, under a 3 minute maximum.
/// The app starts it over USB, feeds it targets, and reports what the robot
/// says happened.
enum FollowState: Equatable {
    case idle
    /// C,FOLLOW sent; targets flow until the robot reports a result.
    case following(since: Date)
    case finished(FollowResult)
}

struct FollowResult: Equatable {
    let code: String

    var needsReboot: Bool { code == "requires_unused_boot" }

    /// Whether starting again straight away makes sense. Refusals about the
    /// firmware, the passphrase or the servos would only repeat.
    var retryable: Bool {
        // "no_result" once may be a dropped line; "no_result_repeated" is a
        // fault and stops the retrying, so silence cannot go on for hours.
        ["session_complete", "session_deadline", "session_idle", "session_max_duration",
         "stopped_by_host", "follow_cooldown", "no_result"].contains(code)
    }

    var summary: String {
        switch code {
        case "session_complete", "session_deadline": "Session finished. The head is powered off."
        case "session_idle": "No face for 12 seconds, so the session ended. The head is powered off."
        case "session_max_duration": "Reached the 3 minute limit for one session. The head is powered off."
        case "stopped_by_host": "Stopped. The head is powered off."
        case "stopped_for_update": "Stopped for a firmware update. The head is powered off."
        case "update_in_progress": "Refused: a firmware update is in progress."
        case "follow_refused_limits_unmeasured": "Refused: this firmware has following disabled."
        case "follow_refused_asleep": "Refused: the robot is asleep. Wake it first."
        case "requires_unused_boot": "Refused: one motion session per boot. Reboot the robot to run another."
        case "follow_cooldown": "The robot is between sessions."
        case "power_latched": "Refused: the robot's motor power is latched off. Reboot it."
        case "follow_requires_stream_on": "Refused: the camera stream must be on."
        case "preflight_refused": "Refused before moving: the servos were not where the robot expects."
        case "base_unreachable": "The robot's head cannot reach its base, so it cannot power the motors. Reboot the robot."
        case "no_result_repeated": "The robot accepted following and never reported back, twice. Something is wrong: see Diagnostics."
        case "no_result": "No result arrived from the robot."
        case "auth_bad_mac": "Refused: the robot passphrase on this Mac does not match the robot."
        case "auth_no_passphrase_stored": "Refused: the robot has no passphrase stored. Set one over USB."
        case "auth_no_passphrase": "The robot passphrase is missing from this Mac. Add it in Settings."
        case "auth_no_reply": "The robot did not answer the authorization request."
        case let other where other.hasPrefix("auth_"): "Authorization failed (\(other.dropFirst(5)))."
        default: "Ended early (\(code)). The head is powered off; see the robot's telemetry."
        }
    }
}

/// When a session should start by itself. Pure, so the rule is testable without
/// a robot: only with the toggle on, following available, a confirmed face, no
/// session in flight, and a gap after the last one (the robot enforces its own
/// cooldown between sessions).
enum AutoFollow {
    static let restartGap: TimeInterval = 4

    /// How long after a wake a session may start with nobody in view, so the
    /// robot can look around for someone (the firmware's wake scan).
    static let wakeScanWindow: TimeInterval = 12

    /// A robot reporting an uptime under this has just booted -- a flash, a
    /// power cycle -- rather than having been up while the app reconnected to
    /// it. The firmware looks around on its first session after a boot, so the
    /// app asks for that session; matching the two is the point of the test,
    /// since a session started for a scan that never runs would power the head
    /// and do nothing for 12 s.
    static let justBootedUptime: TimeInterval = 30

    /// `wokeAt`: when the owner last woke the robot. `bootedAt`: when the app
    /// learned the robot had just come back (nil if it had been up a while).
    /// After either, a session starts even with no face and the robot looks
    /// around for someone. Otherwise a session needs a face to follow.
    static func shouldStart(enabled: Bool, unavailableReason: String?, state: FollowState,
                            faceTracked: Bool, lastEnded: Date?, now: Date, wokeAt: Date? = nil,
                            bootedAt: Date? = nil) -> Bool {
        let justWoke = wokeAt.map { now.timeIntervalSince($0) < wakeScanWindow } ?? false
        let justBooted = bootedAt.map { now.timeIntervalSince($0) < wakeScanWindow } ?? false
        guard enabled, unavailableReason == nil, faceTracked || justWoke || justBooted else { return false }
        switch state {
        case .following: return false
        case .idle: break
        case .finished(let result):
            // A refusal that will just repeat is not retried; an ordinary end is.
            guard result.retryable else { return false }
        }
        // The gap between sessions still applies, except to the one a wake asks for.
        if !justWoke, !justBooted, let lastEnded, now.timeIntervalSince(lastEnded) < restartGap { return false }
        return true
    }
}

enum Gaze {
    /// The G line for a face: the same image coordinates as a follow target,
    /// and 1 when the person faces the robot (the eyes lock on and dilate).
    static func line(for box: FaceBox, engaged: Bool = false) -> String {
        let x = min(max(box.rect.midX * 2 - 1, -1), 1)
        let y = min(max(1 - box.rect.midY * 2, -1), 1)
        return String(format: "G,%.3f,%.3f,%d\n", x, y, engaged ? 1 : 0)
    }
}

enum FollowTarget {
    /// The T line for a selected face. Vision rectangles are normalized with
    /// the origin at the lower left; the robot wants x and y in [-1, 1] with
    /// -1 at the left and top of the image.
    static func line(for box: FaceBox, sequence: UInt32) -> String {
        let x = min(max(box.rect.midX * 2 - 1, -1), 1)
        let y = min(max(1 - box.rect.midY * 2, -1), 1)
        let confidence = min(max(Double(box.confidence), 0), 1)
        return String(format: "T,%u,%.3f,%.3f,%.2f\n", sequence, x, y, confidence)
    }
}
