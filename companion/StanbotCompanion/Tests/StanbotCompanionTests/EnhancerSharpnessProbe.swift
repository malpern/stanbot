import XCTest
import CoreGraphics
import ImageIO
@testable import StanbotCompanion

/// Diagnostic, skipped unless STANBOT_PREVIEW_FRAMES is set: prints the
/// sharpness of each displayed frame, in display order, for several settings.
final class EnhancerSharpnessProbe: XCTestCase {
    private func sharpness(_ image: CGImage) -> Double {
        let w = 320, h = 240
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0.0, n = 0.0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            let lap = 4 * Double(p[i]) - Double(p[i - 1]) - Double(p[i + 1]) - Double(p[i - w]) - Double(p[i + w])
            sum += lap * lap; n += 1
        } }
        return sum / n
    }

    func testPrintSharpnessSequence() async throws {
        guard let dir = ProcessInfo.processInfo.environment["STANBOT_PREVIEW_FRAMES"] else { throw XCTSkip("diagnostic") }
        var frames: [CGImage] = []
        for i in 0..<24 {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: String(format: "%@/f%03d.jpg", dir, i)) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { break }
            frames.append(img)
        }
        func run(_ name: String, _ s: VideoEnhancement) async {
            let e = VideoEnhancer()
            var line: [String] = []
            for f in frames {
                let r = await e.process(f, settings: s)
                if let m = r.interpolated { line.append("m\(Int(sharpness(m)))") }
                line.append("\(Int(sharpness(r.current)))")
            }
            print(name.padding(toLength: 16, withPad: " ", startingAt: 0), line.prefix(30).joined(separator: " "))
        }
        print("original        ", frames.map { "\(Int(sharpness($0)))" }.joined(separator: " "))
        await run("all on", VideoEnhancement())
        var s = VideoEnhancement(); s.smoothMotion = false; await run("no smooth", s)
        s = VideoEnhancement(); s.denoise = false; await run("no denoise", s)
        s = .off; s.upscale = true; await run("upscale only", s)
        s = .off; s.denoise = true; await run("denoise only", s)
    }
}
