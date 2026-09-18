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

    /// The mouth as a speaker grille (Shaders/StanbotGrille.metal): the same
    /// panel the robot draws flat, with the depth, bloom and falloff a Mac can
    /// afford. `slots` is (count, thickness, spacing) and `arcs` is
    /// (count, length, gap), both in robot display pixels; `tilt` is how far the
    /// outer slots lean, positive downward for sad.
    static func grille(size: CGSize, unit: Double, body: CGSize,
                       slots: (Double, Double, Double), tilt: Double,
                       arcs: (Double, Double, Double),
                       level: Double, presence: Double, time: Double) -> Shader? {
        library.map { Shader(function: ShaderFunction(library: $0, name: "stanbotGrille"),
                             arguments: [.float2(size), .float(unit), .float2(body),
                                         .float3(slots.0, slots.1, slots.2), .float(tilt),
                                         .float3(arcs.0, arcs.1, arcs.2),
                                         .float(level), .float(presence), .float(time)]) }
    }

    /// Looking out through Stanbot's eyes (Shaders/StanbotEyeView.metal): bokeh
    /// defocus inside the two eye windows, and the room's light glowing warm
    /// through the lids outside them. Eyes are (centre x, centre y, half width,
    /// half height) in the layer's points.
    static func eyeView(size: CGSize, left: CGRect, right: CGRect, radius: Double,
                        focus: Double, lidLight: Double, softness: Double) -> Shader? {
        func eye(_ rect: CGRect) -> Shader.Argument {
            .float4(rect.midX, rect.midY, rect.width / 2, rect.height / 2)
        }
        return library.map { Shader(function: ShaderFunction(library: $0, name: "stanbotEyeView"),
                                    arguments: [.float2(size), eye(left), eye(right), .float(radius),
                                                .float(focus), .float(lidLight), .float(softness)]) }
    }
    /// How far the eye view samples from a pixel: the bokeh disc and the wide
    /// taps for the light through the lids.
    static let eyeViewReach = CGSize(width: 160, height: 160)

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
