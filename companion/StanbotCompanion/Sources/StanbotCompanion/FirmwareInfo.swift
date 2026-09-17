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

    private enum CodingKeys: String, CodingKey {
        case sketch, commit, dirty, built
        case protocolVersion = "protocol"
        case followLimitsMeasured = "follow_limits_measured"
        case followPitch = "follow_pitch"
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
