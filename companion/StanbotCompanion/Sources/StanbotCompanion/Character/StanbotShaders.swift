import SwiftUI

/// Metal shaders for Stanbot's look, compiled by build-app.sh from
/// Shaders/StanbotScreen.metal into the app bundle. When the library is not
/// there (swift test, swift run) every effect is simply off. STANBOT_SHADER_LIBRARY
/// points at a compiled library elsewhere, for tests.
enum StanbotShaders {
    static let library: ShaderLibrary? = (ProcessInfo.processInfo.environment["STANBOT_SHADER_LIBRARY"]
        .map { URL(fileURLWithPath: $0) } ?? Bundle.main.url(forResource: "StanbotShaders", withExtension: "metallib"))
        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? ShaderLibrary(url: $0) : nil }

    /// The speaking mouth (Shaders/StanbotMouth.metal). Sizes as StanbotMouthView passes them.
    static func mouth(size: CGSize, unit: Double, mouth: CGSize, rim: Double,
                      level: Double, presence: Double, time: Double) -> Shader? {
        library.map { Shader(function: ShaderFunction(library: $0, name: "stanbotMouth"),
                             arguments: [.float2(size), .float(unit), .float2(mouth), .float(rim),
                                         .float(level), .float(presence), .float(time)]) }
    }

    /// The faint pixel grid of the robot's LCD. `cell` is one "pixel" in points.
    static func lcd(cell: Double, strength: Double) -> Shader? {
        library.map { Shader(function: ShaderFunction(library: $0, name: "stanbotLCD"),
                             arguments: [.float(cell), .float(strength)]) }
    }
}

/// The robot-screen look for a set of eyes: a soft glow around what is lit and,
/// when the eyes are large enough for it to read, the LCD pixel grid. Off with
/// Increase Contrast, where texture and glow only cost legibility.
struct ScreenLook: ViewModifier {
    var enabled: Bool
    var width: Double

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let on = enabled && contrast != .increased
        if on, width >= 120, let shader = StanbotShaders.lcd(cell: max(3, width / 80), strength: 0.32) {
            content.colorEffect(shader)
        } else {
            content
        }
    }
}
