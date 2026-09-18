import Foundation

/// A way to ask the app to do something, from a shell.
///
/// `StatusFile` answered "what is the robot doing"; this answers "make it do
/// something". Without it the only way to command the robot from outside the
/// app was to open its USB port directly -- and the app holds that port, so the
/// two fight over it. Every symptom of that fight looks like a broken robot: a
/// `C,REBOOT` that vanished with seven copies sent, `SBST` replies that never
/// arrived, a session result eaten mid-flight. The app owns the transport, so
/// the app should be the one carrying the command.
///
/// Two files beside the status, in `~/Library/Logs/Stanbot`:
///
///   `command.json`         written by the caller: {id, command, argument}
///   `command-result.json`  written by the app:    {id, ok, detail, completed}
///
/// The caller writes a fresh `id` (any unique string) and waits for a result
/// carrying the same one, so an old result is never mistaken for an answer to a
/// new question -- the same stale-answer trap that had `tools/screenshot.py`
/// handing back a previous picture.
///
/// **This is as privileged as the user's own shell, and no more.** Anything
/// that can write this file can already open the robot's USB port, and the
/// robot's own authorization (`command_auth.h`) still applies to everything
/// that moves the head. It is not a remote control: it is local, user-owned,
/// and read only by the app running as that user.
enum CommandFile {
    static func requestURL(in directory: URL) -> URL { directory.appendingPathComponent("command.json") }
    static func resultURL(in directory: URL) -> URL { directory.appendingPathComponent("command-result.json") }

    struct Request: Equatable {
        var id: String
        var command: String
        var argument: String?
    }

    struct Result: Equatable {
        var id: String
        var ok: Bool
        var detail: String
    }

    /// The pending request, or nil if there is none or it cannot be read. A
    /// malformed file is ignored rather than crashing the app: it is written by
    /// whatever is on the other end, and the app must survive that.
    static func read(from directory: URL) -> Request? {
        guard let data = try? Data(contentsOf: requestURL(in: directory)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty,
              let command = object["command"] as? String, !command.isEmpty
        else { return nil }
        return Request(id: id, command: command, argument: object["argument"] as? String)
    }

    /// Written atomically, for the same reason the status is: a reader must
    /// never see half an object.
    static func write(_ result: Result, to directory: URL) {
        let fields: [String: Any] = [
            "id": result.id, "ok": result.ok, "detail": result.detail,
            "completed": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let destination = resultURL(in: directory)
        let temporary = directory.appendingPathComponent("command-result.\(getpid()).tmp")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }
}

/// What the app can be asked to do, and what it says back. Pure, so the whole
/// vocabulary is testable without a robot or a running app.
enum RobotCommand: String, CaseIterable {
    case sleep, wake, reboot, follow, unfollow
    case mouth        // argument: capsule | grille
    case expression   // argument: one of the firmware's emotions
    case screenshot   // argument: where to write it (default stanbot-screen.jpg)

    /// Commands deliberately absent, and why: `off` cannot be undone from
    /// software (only the robot's own button turns it back on), and anything
    /// that steers the head needs someone watching it.
    static func parse(_ name: String) -> RobotCommand? { RobotCommand(rawValue: name.lowercased()) }

    /// Whether `argument` is usable for this command, and why not if it is not.
    func rejection(for argument: String?) -> String? {
        switch self {
        case .mouth:
            guard let argument else { return "mouth needs an argument: capsule or grille" }
            return ["capsule", "grille"].contains(argument.lowercased())
                ? nil : "mouth takes capsule or grille, not \(argument)"
        case .expression:
            guard let argument, !argument.isEmpty else { return "expression needs a name" }
            return Emotion(rawValue: argument.lowercased()) == nil
                ? "no such expression: \(argument)" : nil
        case .screenshot:
            return nil          // a path, or the default; nothing to check here
        default:
            return argument == nil ? nil : "\(rawValue) takes no argument"
        }
    }
}
