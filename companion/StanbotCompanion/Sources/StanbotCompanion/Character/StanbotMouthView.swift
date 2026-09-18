import SwiftUI

/// Stanbot's mouth, drawn from `SpeechMouth` in robot display pixels scaled by
/// `scale` (points per robot pixel), only while Stanbot speaks: it grows in as a
/// line, shapes with the voice, and shrinks away after. With the shader library it is the Metal mouth
/// (Shaders/StanbotMouth.metal); without it (swift test, swift run) the same
/// shape in plain SwiftUI. With no SpeechMouth in the environment, nothing.
///
/// Reads SpeechMouth itself, so a 60 Hz mouth re-renders only this view.
struct StanbotMouthView: View {
    @Environment(SpeechMouth.self) private var speech: SpeechMouth?
    @AppStorage(MouthStyleSetting.key) private var styleName = MouthStyle.capsule.rawValue
    var scale: Double
    /// The glow and inner light; off for tiny faces, where they only blur.
    var glow = true
    /// The thinnest the mouth is drawn, in points.
    var minimumPoints = 0.0

    /// Room around the mouth for its glow, in robot pixels. The grille needs a
    /// wider one: its panel is 74 across and the outer arc sits 36 beyond that,
    /// so the capsule's box clipped the second arc clean off -- the grille drew
    /// one arc a side at full voice and looked like it had been built that way.
    private static let box = CGSize(width: 96, height: 56)
    private static let grilleBox = CGSize(width: 136, height: 56)

    private var style: MouthStyle { MouthStyle(rawValue: styleName) ?? .capsule }

    var body: some View {
        if let speech, speech.presence > 0 {
            if style == .grille {
                grille(speech)
            } else {
                mouth(speech)
            }
        }
    }

    /// The speaker grille. On the robot this is flat fills with hard edges,
    /// because an ESP32 painting a 16-bit sprite has nothing else; here it is
    /// the same panel with the depth, bloom and falloff a Mac can afford --
    /// same shape, same timing, better drawn (docs/app-design.md, "Two faces").
    private func grille(_ speech: SpeechMouth) -> some View {
        let size = CGSize(width: Self.grilleBox.width * scale, height: Self.grilleBox.height * scale)
        let arcs = GrilleGeometry.arcs(open: speech.opening, shape: speech.shape)
        let body = CGSize(width: GrilleGeometry.width * speech.presence, height: GrilleGeometry.height)
        return ZStack {
            if glow, let shader = StanbotShaders.grille(
                size: size, unit: scale, body: body,
                slots: (GrilleGeometry.slots, GrilleGeometry.slotThickness,
                        GrilleGeometry.spacing(open: speech.opening)),
                tilt: GrilleGeometry.tilt(mood: speech.mood),
                arcs: (arcs.count, arcs.length, GrilleGeometry.arcGap),
                level: speech.level, presence: speech.presence, time: speech.time) {
                Rectangle().fill(.white).colorEffect(shader)
            } else {
                // Without the shader library (swift test, swift run): the plain
                // shape, so the tests still see a grille rather than nothing.
                plainGrille(speech, body: body, arcs: arcs)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func plainGrille(_ speech: SpeechMouth, body: CGSize,
                             arcs: (count: Double, length: Double)) -> some View {
        let spacing = GrilleGeometry.spacing(open: speech.opening)
        let tilt = GrilleGeometry.tilt(mood: speech.mood)
        return ZStack {
            RoundedRectangle(cornerRadius: body.height * scale * 0.25)
                .fill(Color(white: 0.09))
                .frame(width: body.width * scale, height: body.height * scale)
            ForEach(0..<Int(GrilleGeometry.slots), id: \.self) { index in
                let fromCentre = Double(index) - (GrilleGeometry.slots - 1) / 2
                let lean = fromCentre == 0 ? 0 : (fromCentre > 0 ? tilt : -tilt)
                Capsule().fill(Color(white: 0.62 + 0.30 * speech.level))
                    .frame(width: (body.width - 12) * scale, height: GrilleGeometry.slotThickness * scale)
                    .offset(y: (fromCentre * spacing + lean) * scale)
            }
            ForEach(0..<Int(arcs.count), id: \.self) { index in
                let offset = body.width / 2 + GrilleGeometry.arcGap
                    + Double(index) * (3 + GrilleGeometry.arcGap)
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule().fill(Color(white: 0.70))
                        .frame(width: 3 * scale, height: arcs.length * scale)
                        .offset(x: side * offset * scale)
                }
            }
        }
        .opacity(speech.presence)
    }

    private func mouth(_ speech: SpeechMouth) -> some View {
        var mouth = MouthModel.size(open: speech.opening, shape: speech.shape)
        mouth.width *= speech.presence   // grows in from the centre, as on the robot
        let size = CGSize(width: Self.box.width * scale, height: Self.box.height * scale)
        return ZStack {
            if glow, let shader = StanbotShaders.mouth(size: size, unit: scale, mouth: mouth, rim: MouthModel.rim,
                                                       level: speech.level, presence: speech.presence, time: speech.time) {
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
