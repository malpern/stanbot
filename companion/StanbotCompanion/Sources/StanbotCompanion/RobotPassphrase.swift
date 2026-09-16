import CryptoKit
import Foundation

/// The answer to the robot's challenge: HMAC-SHA256 keyed with the robot's OTA
/// passphrase over "COMMAND:nonce", as lowercase hex. Must match
/// firmware/camera_stream/command_auth.h; both are checked against the same
/// test vector.
enum CommandAuthorization {
    static func mac(command: String, nonce: String, passphrase: String) -> String {
        let key = SymmetricKey(data: Data(passphrase.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(command):\(nonce)".utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

/// The robot's passphrase, read from ~/dotfiles/secrets.env with sops when
/// first needed and kept in memory for the life of the process. Deliberately
/// not the Keychain: a Keychain item raises a macOS permission dialog whenever
/// a different binary (the test runner, a rebuilt app) reads it, which is
/// exactly the interruption this is meant to avoid. It never leaves the Mac;
/// only answers to one-time challenges are sent.
enum RobotPassphrase {
    /// Cache and status behind one lock; `nonisolated(unsafe)` is the claim, and
    /// the invariant is that nothing touches either outside `state.withLock`.
    private struct State { var cached: String?; var status = "Not read yet." }
    private nonisolated(unsafe) static var state = State()
    private static let lock = NSLock()

    private static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// The passphrase, or nil with the reason in `status`.
    static func read() -> String? {
        withState { state in
            if let cached = state.cached { return cached }
            let (value, message) = decrypt()
            state.cached = value
            state.status = message
            return value
        }
    }

    /// A short, non-secret description of the last read.
    static var status: String { withState { $0.status } }

    /// Forgets the cached value, so the next use decrypts again.
    static func forget() { withState { $0.cached = nil } }

    private static func decrypt() -> (String?, String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let sops = ["/opt/homebrew/bin/sops", "/usr/local/bin/sops"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (nil, "sops is not installed.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sops)
        process.arguments = ["-d", "\(home)/dotfiles/secrets.env"]
        var environment = ProcessInfo.processInfo.environment
        environment["SOPS_AGE_KEY_FILE"] = "\(home)/.config/sops/age/keys.txt"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return (nil, "Could not run sops.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return (nil, "sops could not decrypt ~/dotfiles/secrets.env.")
        }
        let prefix = "STANBOT_OTA_PASSWORD="
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            return (nil, "STANBOT_OTA_PASSWORD is not in the secrets file.")
        }
        return (String(line.dropFirst(prefix.count)), "Read from secrets.env.")
    }
}
