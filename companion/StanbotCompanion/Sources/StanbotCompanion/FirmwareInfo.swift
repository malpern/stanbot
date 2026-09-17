import Foundation

/// What the robot says it is running, from its reply to the `V` command:
///
///     SBVR {"sketch":"camera_stream","commit":"3aaa2f9c1d2e","dirty":false,
///           "built":"2026-09-16T18:20:00Z","protocol":1,"follow_limits_measured":false}
///
/// `firmware/build.sh` stamps the commit and dirty state from git. A build made
/// any other way reports commit "unknown" and dirty null, which is shown as a
/// warning rather than hidden: an unidentified build is the case this exists for.
struct FirmwareInfo: Decodable, Equatable, Sendable {
    /// The protocol this app understands. Must match the firmware's kProtocolVersion.
    static let expectedProtocol = 1

    let sketch: String
    let commit: String
    let dirty: Bool?
    let built: String
    let protocolVersion: Int
    let followLimitsMeasured: Bool
    /// Following tilts the head up and down too (a STANBOT_FOLLOW_PITCH=1 build).
    /// Older firmware does not send it, which means yaw only.
    let followPitch: Bool
    /// Yaw travel either side of centre, in raw steps. Older firmware does not
    /// send it; nil then.
    let followYawRange: Int?
    /// How long the robot has been up when it sent this. Tells a robot that has
    /// just rebooted from one that was up all along and the app merely
    /// reconnected to -- the difference between wanting a look around and not.
    /// Older firmware does not send it; nil then.
    let uptimeMs: Int?
    /// The robot still owes a look around: it has not run a session since it
    /// booted, so its first one will begin by looking for someone. The app asks
    /// for that session on the strength of this, rather than guessing from the
    /// uptime -- a stopwatch cannot agree with the robot, and a flash plus its
    /// checks routinely takes longer than any window worth choosing. Absent on
    /// older firmware; nil then, and the uptime is used instead.
    let scanPending: Bool?

    private enum CodingKeys: String, CodingKey {
        case sketch, commit, dirty, built
        case protocolVersion = "protocol"
        case followLimitsMeasured = "follow_limits_measured"
        case followPitch = "follow_pitch"
        case followYawRange = "follow_yaw_range"
        case uptimeMs = "uptime_ms"
        case scanPending = "scan_pending"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sketch = try c.decode(String.self, forKey: .sketch)
        commit = try c.decode(String.self, forKey: .commit)
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty)
        built = try c.decode(String.self, forKey: .built)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        followLimitsMeasured = try c.decode(Bool.self, forKey: .followLimitsMeasured)
        followPitch = try c.decodeIfPresent(Bool.self, forKey: .followPitch) ?? false
        followYawRange = try c.decodeIfPresent(Int.self, forKey: .followYawRange)
        uptimeMs = try c.decodeIfPresent(Int.self, forKey: .uptimeMs)
        scanPending = try c.decodeIfPresent(Bool.self, forKey: .scanPending)
    }

    static func parse(_ line: String) -> FirmwareInfo? {
        guard line.hasPrefix("SBVR ") else { return nil }
        return try? JSONDecoder().decode(FirmwareInfo.self, from: Data(line.dropFirst(5).utf8))
    }

    var shortCommit: String {
        commit == "unknown" ? commit : String(commit.prefix(7))
    }

    /// Everything about this build a person should notice, most serious first.
    var warnings: [String] {
        var result: [String] = []
        if followLimitsMeasured {
            result.append("Head-following limits are marked measured")
        }
        if followPitch {
            result.append("Head following tilts up and down (pitch build)")
        }
        if protocolVersion != Self.expectedProtocol {
            result.append("Protocol \(protocolVersion); this app expects \(Self.expectedProtocol)")
        }
        if commit == "unknown" {
            result.append("Not built with firmware/build.sh; commit unknown")
        } else if dirty != false {
            result.append("Built from uncommitted changes")
        }
        return result
    }
}

/// Where the app is in finding out what firmware is on the robot.
enum FirmwareStatus: Equatable {
    /// No connection, so nothing to ask.
    case unknown
    /// `V` sent, waiting for the reply.
    case asking
    case reported(FirmwareInfo)
    /// Several requests went unanswered: firmware older than the V command.
    case silent
}
