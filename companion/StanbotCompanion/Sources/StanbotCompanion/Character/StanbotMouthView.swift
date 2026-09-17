import SwiftUI

/// Stanbot's speaking mouth, drawn from `SpeechMouth` in robot display pixels
/// scaled by `scale` (points per robot pixel). With the shader library it is the
/// Metal mouth (Shaders/StanbotMouth.metal); without it (swift test, swift run)
/// the same shape in plain SwiftUI. Nothing at all while Stanbot is silent.
///
/// Reads SpeechMouth itself, so a 60 Hz mouth re-renders only this view.
struct StanbotMouthView: View {
    @Environment(SpeechMouth.self) private var speech: SpeechMouth?
    var scale: Double

    /// Room around the mouth for its glow, in robot pixels.
    private static let box = CGSize(width: 84, height: 50)

    var body: some View {
        if let speech, speech.visible {
            let width = MouthModel.closedWidth + (MouthModel.openWidth - MouthModel.closedWidth) * speech.opening
            let mouth = CGSize(width: width * speech.presence,
                               height: MouthModel.closedHeight + (MouthModel.openHeight - MouthModel.closedHeight) * speech.opening)
            let size = CGSize(width: Self.box.width * scale, height: Self.box.height * scale)
            ZStack {
                if let shader = StanbotShaders.mouth(size: size, unit: scale, mouth: mouth, rim: MouthModel.rim,
                                                     level: speech.level, presence: speech.presence, time: speech.time) {
                    Rectangle().fill(.white).colorEffect(shader)
                } else {
                    Capsule().fill(Color(white: 0.60))
                        .frame(width: mouth.width * scale, height: mouth.height * scale)
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
}

/// While Stanbot speaks and the video fills the window, a small piece of the
/// robot's screen in the toolbar shows the mouth. Nothing while it is silent.
struct SpeakingIndicator: View {
    @Environment(SpeechMouth.self) private var speech: SpeechMouth?

    var body: some View {
        // Wrapped: a toolbar item must not be a bare shape or image (see Joystick).
        ZStack {
            if let speech, speech.visible {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black)
                    .frame(width: 46, height: 26)
                StanbotMouthView(scale: 0.8)
                    .frame(width: 46, height: 26)
                    .clipped()
            }
        }
        .help("Stanbot is speaking")
        .accessibilityLabel(speech?.visible == true ? "Stanbot is speaking" : "")
    }
}
