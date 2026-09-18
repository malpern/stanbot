import SwiftUI
import XCTest
@testable import StanbotCompanion

/// The eye aperture must not paint outside the picture.
///
/// `layerEffect(maxSampleOffset:)` GROWS the layer so the shader's wide taps
/// have somewhere to read from -- 160 points on every side -- and the shader
/// runs over all of it. StanbotEyeView.metal returned alpha 1 unconditionally,
/// so it painted an opaque black frame far beyond the picture, landing on top
/// of the face behind it: during the opening sequence a black box appeared over
/// the eyes and vanished a second later. Reported 2026-09-18.
///
/// Needs the compiled shaders, since the bug lives in Metal and the SwiftUI
/// fallback never had it:
///
///     STANBOT_SHADER_LIBRARY=/tmp/StanbotShaders.metallib swift test
final class EyeApertureVeilTests: XCTestCase {
    /// A small white picture with the veil on it, on a red ground, rendered
    /// large enough to include the margin the layer effect adds.
    @MainActor
    private func render(_ state: EyeMotionSequence.State) throws -> NSBitmapImageRep {
        let picture = 120.0, canvas = 420.0
        let view = ZStack {
            Color.red
            Color.white
                .frame(width: picture, height: picture)
                .eyeAperture(state, pose: EyePose.of(.normal))
        }
        .frame(width: canvas, height: canvas)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            throw XCTSkip("could not render the veil")
        }
        return bitmap
    }

    /// Is this pixel the red ground we put behind everything?
    private func isGround(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let colour = bitmap.colorAt(x: x, y: y) else { return false }
        return colour.redComponent > 0.5 && colour.greenComponent < 0.3 && colour.blueComponent < 0.3
    }

    private func requireShaders() throws {
        guard StanbotShaders.library != nil else {
            throw XCTSkip("set STANBOT_SHADER_LIBRARY to a compiled StanbotShaders.metallib")
        }
    }

    /// Closed eyes: the state during the opening sequence, and the one that
    /// blacked out the face.
    @MainActor
    func testTheVeilDoesNotPaintOutsideThePicture() throws {
        try requireShaders()
        let bitmap = try render(.closed)

        // A corner of the canvas, far outside the 120-point picture but well
        // inside the margin the layer effect adds. This is where the black box
        // appeared.
        for (x, y) in [(20, 20), (400, 20), (20, 400), (400, 400)] {
            XCTAssertTrue(isGround(bitmap, x, y),
                          "the veil painted over the ground at (\(x), \(y)): "
                          + "\(bitmap.colorAt(x: x, y: y).map(String.init(describing:)) ?? "nothing")")
        }
    }

    /// The same must hold part-way through the opening, not only at the ends --
    /// the black box was visible for about a second, in the middle.
    @MainActor
    func testNotDuringTheOpeningEither() throws {
        try requireShaders()
        for step in [0.15, 0.4, 0.75] {
            let state = EyeMotionSequence.State(left: step, right: step * 0.9,
                                                growth: step, focus: step, lidLight: 1 - step)
            let bitmap = try render(state)
            XCTAssertTrue(isGround(bitmap, 20, 20),
                          "the veil painted over the ground at openness \(step)")
        }
    }
}
