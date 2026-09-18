import Foundation

/// What the app knows, written where a shell can read it.
///
/// The app is the only thing that can talk to the robot (it holds its one Wi-Fi
/// viewer slot), so until this existed the only way to find out whether Follow
/// was on, or why nothing was happening, was to look at the window. On
/// 2026-09-17 that turned a diagnosis into a question put to the owner, twice,
/// about state the machine already knew. The owner, fairly: "why are you asking
/// me if follow is on, can't you know?"
///
/// One JSON object, rewritten atomically about once a second, beside the
/// session logs: `~/Library/Logs/Stanbot/status.json`. Read it with
/// `tools/stanbot status`. It is a report, not an interface: nothing reads it
/// back, so a field can be added or renamed freely.
enum StatusFile {
    static func url(in directory: URL) -> URL { directory.appendingPathComponent("status.json") }

    /// Atomic on purpose: a reader must never see half an object. Writes to a
    /// sibling temp file and renames, which is atomic within a directory.
    static func write(_ fields: [String: Any], to directory: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let destination = url(in: directory)
        let temporary = directory.appendingPathComponent("status.json.\(getpid()).tmp")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }
}
