import SwiftUI

/// Stanbot's mouth, drawn from `SpeechMouth` in robot display pixels scaled by
/// `scale` (points per robot pixel). A thin resting line when silent, a shaping
/// capsule while speaking. With the shader library it is the Metal mouth
/// (Shaders/StanbotMouth.metal); without it (swift test, swift run) the same
/// shape in plain SwiftUI. With no SpeechMouth in the environment, the resting line.
///
/// Reads SpeechMouth itself, so a 60 Hz mouth re-renders only this view.
struct StanbotMouthView: View {
    @Environment(SpeechMouth.self) private var speech: SpeechMouth?
    var scale: Double
    /// The glow and inner light; off for tiny faces, where they only blur.
    var glow = true
    /// The thinnest the mouth is drawn, in points.
    var minimumPoints = 0.0

    /// Room around the mouth for its glow, in robot pixels.
    private static let box = CGSize(width: 96, height: 56)

    var body: some View {
        let opening = speech?.opening ?? 0
        let mouth = MouthModel.size(open: opening, shape: speech?.shape ?? 0)
        let size = CGSize(width: Self.box.width * scale, height: Self.box.height * scale)
        ZStack {
            if glow, let shader = StanbotShaders.mouth(size: size, unit: scale, mouth: mouth, rim: MouthModel.rim,
                                                       level: speech?.level ?? 0, presence: 1, time: speech?.time ?? 0) {
                Rectangle().fill(.white).colorEffect(shader)
            } else {
                Capsule().fill(Color(white: glow ? 0.60 : 0.66))
                    .frame(width: mouth.width * scale, height: max(mouth.height * scale, minimumPoints))
                if mouth.height > 2 * MouthModel.rim + 2 {
                    Capsule().fill(.black)
                        .frame(width: max(0, mouth.width - 2 * MouthModel.rim) * scale,
                               height: (mouth.height - 2 * MouthModel.rim) * scale)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
