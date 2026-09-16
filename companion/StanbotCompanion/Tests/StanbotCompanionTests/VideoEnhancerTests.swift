import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StanbotCompanion

final class VideoEnhancerTests: XCTestCase {
    /// A 320×240 grey frame with a white square whose left edge is at `x`.
    private func frame(squareAt x: Int) -> CGImage {
        let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        // Checkered, so the motion estimator has texture to follow.
        for row in 0..<6 {
            for column in 0..<6 {
                let bright = (row + column) % 2 == 0
                context.setFillColor(CGColor(red: bright ? 1 : 0.75, green: bright ? 1 : 0.75, blue: bright ? 1 : 0.75, alpha: 1))
                context.fill(CGRect(x: x + column * 10, y: 80 + row * 10, width: 10, height: 10))
            }
        }
        return context.makeImage()!
    }

    /// Mean x of bright pixels, as a fraction of the width.
    private func squareCenter(_ image: CGImage) -> Double {
        let width = 160, height = 120
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0.0, count = 0.0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > 180 {
                sum += Double(x); count += 1
            }
        }
        return count > 0 ? sum / count / Double(width) : -1
    }

    func testEverythingOffPassesFramesThrough() async {
        let enhancer = VideoEnhancer()
        let result = await enhancer.process(frame(squareAt: 40), settings: .off)
        XCTAssertNil(result.interpolated)
        XCTAssertEqual(result.current.width, 320)
        XCTAssertEqual(result.current.height, 240)
    }

    func testFullPipelineUpscalesAndInterpolatesBetweenRealFrames() async throws {
        try XCTSkipUnless(VideoEnhancement.videoToolboxAvailable, "needs macOS 26 VideoToolbox processors")
        let enhancer = VideoEnhancer()
        var settings = VideoEnhancement()
        settings.denoise = false   // isolate interpolation; the filter blends toward the previous frame

        // A modest move. A 160-pixel jump of the same square came out as two faint
        // ghosts, a crossfade rather than motion: that is the processor's limit on
        // large movement, and why Settings says fast motion can ghost.
        let first = await enhancer.process(frame(squareAt: 100), settings: settings)
        XCTAssertNil(first.interpolated, "nothing to interpolate from on the first frame")
        XCTAssertEqual(first.current.width, 640, "upscaled 2x")
        XCTAssertEqual(first.current.height, 480)

        let second = await enhancer.process(frame(squareAt: 140), settings: settings)
        let middle = try XCTUnwrap(second.interpolated)
        XCTAssertEqual(middle.width, 640)
        let a = squareCenter(first.current), m = squareCenter(middle), b = squareCenter(second.current)
        XCTAssertLessThan(a, m, "the interpolated square sits between the two real ones")
        XCTAssertLessThan(m, b)

        await enhancer.reset()
        let afterReset = await enhancer.process(frame(squareAt: 100), settings: settings)
        XCTAssertNil(afterReset.interpolated, "no interpolation across a reset")
    }

    func testSmoothMotionWorksWithoutUpscaling() async throws {
        try XCTSkipUnless(VideoEnhancement.videoToolboxAvailable, "needs macOS 26 VideoToolbox processors")
        let enhancer = VideoEnhancer()
        var settings = VideoEnhancement.off
        settings.smoothMotion = true
        _ = await enhancer.process(frame(squareAt: 100), settings: settings)
        let second = await enhancer.process(frame(squareAt: 140), settings: settings)
        let middle = try XCTUnwrap(second.interpolated)
        XCTAssertEqual(middle.width, 320)

        settings.upscale = true   // size changes: no interpolation across it, then it resumes at 640
        let resized = await enhancer.process(frame(squareAt: 180), settings: settings)
        XCTAssertNil(resized.interpolated)
        let next = await enhancer.process(frame(squareAt: 220), settings: settings)
        XCTAssertEqual(next.interpolated?.width, 640)
    }

    /// Writes before/after PNGs for frames recorded from the robot, to look at:
    /// STANBOT_PREVIEW_FRAMES=<dir of f000.jpg…> swift test --filter testPreview
    func testPreviewRecordedFrames() async throws {
        guard let directory = ProcessInfo.processInfo.environment["STANBOT_PREVIEW_FRAMES"] else {
            throw XCTSkip("set STANBOT_PREVIEW_FRAMES to a directory of recorded frames")
        }
        let output = directory + "/enhanced"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let enhancer = VideoEnhancer()
        var times: [Double] = []
        for index in 0..<30 {
            let url = URL(fileURLWithPath: String(format: "%@/f%03d.jpg", directory, index))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { break }
            let start = Date()
            let result = await enhancer.process(image, settings: VideoEnhancement())
            times.append(Date().timeIntervalSince(start) * 1000)
            if index == 20 {
                write(image, "\(output)/original.png")
                write(result.current, "\(output)/enhanced.png")
                if let middle = result.interpolated { write(middle, "\(output)/interpolated.png") }
            }
        }
        let steady = times.dropFirst(3).sorted()
        print("enhancer ms per frame: median \(steady[steady.count / 2]), max \(steady.last ?? 0)")
    }

    private func write(_ image: CGImage, _ path: String) {
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
