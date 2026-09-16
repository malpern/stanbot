import AppKit

/// What the app plays when the robot comes back on a different firmware build.
/// Tink, the first choice, reads as an error beep; these are gentler, and Off
/// is a real option.
enum FirmwareChime: String, CaseIterable, Identifiable {
    case purr, submarine, glass, pop, off

    static let defaultsKey = "StanbotFirmwareChime"

    static var stored: FirmwareChime {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(FirmwareChime.init(rawValue:)) ?? .purr
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .purr: "Purr (soft)"
        case .submarine: "Submarine (low)"
        case .glass: "Glass (bright)"
        case .pop: "Pop (short)"
        case .off: "Off"
        }
    }

    private var soundName: String? {
        switch self {
        case .purr: "Purr"
        case .submarine: "Submarine"
        case .glass: "Glass"
        case .pop: "Pop"
        case .off: nil
        }
    }

    func store() { UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey) }

    func play() {
        guard let soundName, let sound = NSSound(named: soundName) else { return }
        sound.volume = 0.4
        sound.play()
    }
}
