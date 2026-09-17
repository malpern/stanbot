import Foundation
import SwiftUI

/// Where the app is with a head-following session. The robot owns the session:
/// it enforces the limits, the 20 s cutoff and the one power window per boot.
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
        ["session_complete", "session_deadline", "stopped_by_host", "follow_cooldown", "no_result"].contains(code)
    }

    var summary: String {
        switch code {
        case "session_complete", "session_deadline": "Session finished. The head is powered off."
        case "stopped_by_host": "Stopped. The head is powered off."
        case "follow_refused_limits_unmeasured": "Refused: this firmware has following disabled."
        case "requires_unused_boot": "Refused: one motion session per boot. Reboot the robot to run another."
        case "follow_cooldown": "The robot is between sessions."
        case "power_latched": "Refused: the robot's motor power is latched off. Reboot it."
        case "follow_requires_stream_on": "Refused: the camera stream must be on."
        case "preflight_refused": "Refused before moving: the servos were not where the robot expects."
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

    static func shouldStart(enabled: Bool, unavailableReason: String?, state: FollowState,
                            faceTracked: Bool, lastEnded: Date?, now: Date) -> Bool {
        guard enabled, unavailableReason == nil, faceTracked else { return false }
        switch state {
        case .following: return false
        case .idle: break
        case .finished(let result):
            // A refusal that will just repeat is not retried; an ordinary end is.
            guard result.retryable else { return false }
        }
        if let lastEnded, now.timeIntervalSince(lastEnded) < restartGap { return false }
        return true
    }
}

enum Gaze {
    /// The G line for a face: the same image coordinates as a follow target.
    static func line(for box: FaceBox) -> String {
        let x = min(max(box.rect.midX * 2 - 1, -1), 1)
        let y = min(max(1 - box.rect.midY * 2, -1), 1)
        return String(format: "G,%.3f,%.3f\n", x, y)
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

/// Start, stop and result for head following, under the status cards.
struct HeadFollowingPanel: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Head following").font(.title2.weight(.semibold))
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Automatic", isOn: $robot.followAutomatically)
                    .toggleStyle(.switch)
                    .help("Start a session whenever a face is selected")
                switch robot.follow {
                case .following:
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { robot.stopFollowing() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                case .finished(let result) where result.needsReboot:
                    Button("Reboot Robot", systemImage: "arrow.triangle.2.circlepath") { robot.rebootRobot() }
                        .buttonStyle(.bordered)
                        .disabled(!(robot.connectedOverUSB || (robot.connectedOverWiFi && robot.passphraseAvailable)))
                default:
                    Button("Follow", systemImage: "scope") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(robot.followUnavailableReason != nil)
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .confirmationDialog("Start head following?", isPresented: $confirming) {
            Button("Start Following") { robot.startFollowing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The head will turn toward the selected face for up to 20 seconds (\(axes)), within the calibration limits, and look around briefly if it loses the face. Stay at the robot, and press Stop if anything looks wrong. Over Wi-Fi the robot checks the passphrase first.")
        }
    }

    private var detail: String {
        switch robot.follow {
        case .following: return pitchBuild ? "Following the selected face, left, right, up and down."
                                            : "Following the selected face. Yaw only; pitch stays unpowered."
        case .finished(let result): return result.summary
        case .idle: return robot.followUnavailableReason ?? "Ready. Turns toward the selected face, \(axes)."
        }
    }

    /// What the firmware says following may move. Anything unreported is yaw only.
    private var pitchBuild: Bool {
        if case .reported(let info) = robot.firmware { return info.followPitch }
        return false
    }

    private var axes: String { pitchBuild ? "left, right, up and down" : "yaw only" }
}
