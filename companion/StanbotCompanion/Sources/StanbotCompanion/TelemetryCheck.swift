import Foundation

/// Verifies a telemetry block (`SBTB` ... `SBTE`) against the line count and
/// CRC-32 the robot puts in `SBTE` (firmware/camera_stream/telemetry_check.h).
/// Session 2 lost a byte on USB and its result still looked valid; this is
/// what notices. Firmware older than the check sends a bare `SBTE`, which is
/// reported as unchecked rather than as corrupt.
struct TelemetryCheck {
    enum Outcome: Equatable {
        case verified(lines: Int)
        case corrupted(expectedLines: Int, receivedLines: Int)
        case unchecked
    }

    private var active = false
    private var crc: UInt32 = 0xFFFF_FFFF
    private var lines = 0

    /// Feed every text line in order. Returns an outcome when a block ends.
    mutating func consume(_ line: String) -> Outcome? {
        if line.hasPrefix("SBTB ") {
            active = true
            crc = 0xFFFF_FFFF
            lines = 0
            return nil
        }
        guard active else { return nil }
        if line.hasPrefix("SBTE ") {
            active = false
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                  let expectedLines = object["lines"] as? Int,
                  let text = object["crc32"] as? String, let expected = UInt32(text, radix: 16)
            else { return .unchecked }
            let received = crc ^ 0xFFFF_FFFF
            return expected == received && expectedLines == lines
                ? .verified(lines: lines)
                : .corrupted(expectedLines: expectedLines, receivedLines: lines)
        }
        for byte in line.utf8 where byte != 0x0d && byte != 0x0a {
            crc = Self.update(crc, byte)
        }
        lines += 1
        return nil
    }

    static func update(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        var crc = crc ^ UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        return crc
    }
}
