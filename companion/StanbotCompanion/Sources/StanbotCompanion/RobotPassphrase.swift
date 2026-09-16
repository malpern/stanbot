import CryptoKit
import Foundation
import Security

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

/// The robot's passphrase on this Mac, kept in the login Keychain. It never
/// leaves the Mac: only answers to one-time challenges are sent.
enum RobotPassphrase {
    private static let service = "com.malpern.stanbot-companion.robot-passphrase"
    private static let account = "stanbot"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func store(_ passphrase: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !passphrase.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(passphrase.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Reads STANBOT_OTA_PASSWORD from ~/dotfiles/secrets.env with sops and
    /// stores it. Returns a short, non-secret description of what happened.
    static func loadFromSecrets() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sops = ["/opt/homebrew/bin/sops", "/usr/local/bin/sops"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let sops else { return "sops is not installed." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sops)
        process.arguments = ["-d", "\(home)/dotfiles/secrets.env"]
        var environment = ProcessInfo.processInfo.environment
        environment["SOPS_AGE_KEY_FILE"] = "\(home)/.config/sops/age/keys.txt"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return "Could not run sops." }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return "sops could not decrypt the secrets file."
        }
        let prefix = "STANBOT_OTA_PASSWORD="
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            return "STANBOT_OTA_PASSWORD is not in the secrets file."
        }
        return store(String(line.dropFirst(prefix.count))) ? "Loaded from secrets." : "Could not save to the Keychain."
    }
}
