import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import VideoToolbox

/// Which enhancements the camera view applies. Each is a Settings toggle,
/// stored in UserDefaults. Face detection never sees any of them: it runs on
/// the frame exactly as the robot sent it.
struct VideoEnhancement: Equatable, Sendable {
    /// Mild saturation, contrast and vibrance: the GC0308 renders flat and grey.
    var color = true
    /// VideoToolbox temporal noise filter, using the previous frame only.
    var denoise = true
    /// One interpolated frame between each pair, doubling the displayed rate at
    /// the cost of about half a frame interval of delay.
    var smoothMotion = true
    /// VideoToolbox low-latency super resolution, 320×240 to 640×480.
    var upscale = true

    static let off = VideoEnhancement(color: false, denoise: false, smoothMotion: false, upscale: false)

    private static let keys = (color: "StanbotVideoColor", denoise: "StanbotVideoDenoise",
                               smoothMotion: "StanbotVideoSmoothMotion", upscale: "StanbotVideoUpscale")

    static var stored: VideoEnhancement {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return VideoEnhancement(color: flag(keys.color), denoise: flag(keys.denoise),
                                smoothMotion: flag(keys.smoothMotion), upscale: flag(keys.upscale))
    }

    func store() {
        let defaults = UserDefaults.standard
        defaults.set(color, forKey: Self.keys.color)
        defaults.set(denoise, forKey: Self.keys.denoise)
        defaults.set(smoothMotion, forKey: Self.keys.smoothMotion)
        defaults.set(upscale, forKey: Self.keys.upscale)
    }

    /// Denoise, smooth motion and upscale need the macOS 26 VideoToolbox processors.
    static var videoToolboxAvailable: Bool {
        if #available(macOS 26, *) {
            return VTTemporalNoiseFilterConfiguration.isSupported
                && VTLowLatencySuperResolutionScalerConfiguration.isSupported
                && VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return false
    }
}

/// Frames to show for one frame from the robot.
struct EnhancedFrames: @unchecked Sendable {
    /// Halfway between the previous frame and this one. Show it first.
    let interpolated: CGImage?
    let current: CGImage
}

/// Turns each decoded camera frame into display frames. An actor, so frames are
/// processed strictly in order: denoising and interpolation both depend on the
/// frame before. Measured on 2026-09-16 at 320×240, each VideoToolbox stage took
/// 1–2 ms end to end, against ~190 ms between frames.
actor VideoEnhancer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var processors: AnyObject?   // VideoToolboxStages, when available
    /// The frame in progress. An actor still admits a new call while an earlier
    /// one is suspended at an await, which would let two frames interleave; each
    /// call instead waits for the one before it.
    private var tail: Task<Void, Never>?

    init() {}

    /// Forget the frame history, after a reconnect or a stall, so nothing is
    /// denoised against or interpolated from an unrelated frame.
    func reset() {
        let previous = tail
        tail = Task {
            await previous?.value
            await self.resetNow()
        }
    }

    private func resetNow() {
        if #available(macOS 26, *) { (processors as? VideoToolboxStages)?.reset() }
    }

    func process(_ image: CGImage, settings: VideoEnhancement) async -> EnhancedFrames {
        let previous = tail
        let task = Task { () -> EnhancedFrames in
            await previous?.value
            return await self.run(image, settings: settings)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func run(_ image: CGImage, settings: VideoEnhancement) async -> EnhancedFrames {
        var current = image
        var interpolated: CGImage?
        let wantsVT = settings.denoise || settings.smoothMotion || settings.upscale
        if wantsVT, #available(macOS 26, *), VideoEnhancement.videoToolboxAvailable {
            let stages: VideoToolboxStages
            if let existing = processors as? VideoToolboxStages, existing.matches(image) {
                stages = existing
            } else {
                (processors as? VideoToolboxStages)?.close()
                stages = VideoToolboxStages(width: image.width, height: image.height, context: context)
                processors = stages
            }
            if let result = await stages.process(image, settings: settings) {
                current = result.current
                interpolated = result.interpolated
            }
        }
        if settings.color {
            current = adjustColor(current)
            interpolated = interpolated.map(adjustColor)
        }
        return EnhancedFrames(interpolated: interpolated, current: current)
    }

    private func adjustColor(_ image: CGImage) -> CGImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = CIImage(cgImage: image)
        controls.saturation = 1.1
        controls.contrast = 1.05
        controls.brightness = 0
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = controls.outputImage
        vibrance.amount = 0.15
        guard let output = vibrance.outputImage,
              let result = context.createCGImage(output, from: output.extent) else { return image }
        return result
    }
}

// @unchecked Sendable, and the invariant behind it: only VideoEnhancer uses this,
// and its tail chain runs one process() or reset() at a time.
@available(macOS 26, *)
private final class VideoToolboxStages: @unchecked Sendable {
    let width: Int, height: Int
    private let context: CIContext
    private var transfer: VTPixelTransferSession?
    private let noiseConfig: VTTemporalNoiseFilterConfiguration?
    private let noise = VTFrameProcessor()
    // Interpolation runs on the frames as displayed, after upscaling. Before
    // upscaling, the in-between frames measured about a third as sharp as the
    // real ones, and alternating the two made the picture pulse soft and sharp
    // (reported 2026-09-16); after, they are within about 11%. Its session is
    // rebuilt when the display size changes, as when upscaling is toggled.
    private var interpolationConfig: VTLowLatencyFrameInterpolationConfiguration?
    private var interpolation = VTFrameProcessor()
    private var interpolationWidth = 0
    private let scalerConfig: VTLowLatencySuperResolutionScalerConfiguration?
    private let scaler = VTFrameProcessor()
    private var started = (noise: false, interpolation: false, scaler: false)
    private var previousNoisy: VTFrameProcessorFrame?     // lossless-format source, for the noise filter
    private var previousClean: VTFrameProcessorFrame?     // as displayed (denoised, upscaled), for interpolation
    private var frameIndex: Int64 = 0

    init(width: Int, height: Int, context: CIContext) {
        self.width = width
        self.height = height
        self.context = context
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        noiseConfig = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height,
                                                         sourcePixelFormat: kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange)
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
        scalerConfig = factors.contains(2.0)
            ? VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: 2.0)
            : nil
    }

    func matches(_ image: CGImage) -> Bool { image.width == width && image.height == height }

    func reset() {
        previousNoisy = nil
        previousClean = nil
    }

    func close() {
        if started.noise { noise.endSession() }
        if started.interpolation { interpolation.endSession() }
        if started.scaler { scaler.endSession() }
        started = (false, false, false)
    }

    deinit { close() }

    func process(_ image: CGImage, settings: VideoEnhancement) async -> (interpolated: CGImage?, current: CGImage)? {
        frameIndex += 1
        let time = CMTime(value: frameIndex, timescale: 5)
        guard let plain = makeBuffer(width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else { return nil }
        context.render(CIImage(cgImage: image), to: plain)
        var clean = plain

        if settings.denoise, let config = noiseConfig, ensure(&started.noise, noise, config),
           let lossless = makeBuffer(width, height, kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange),
           let losslessOut = makeBuffer(width, height, kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange),
           transfer(plain, to: lossless),
           let source = VTFrameProcessorFrame(buffer: lossless, presentationTimeStamp: time),
           let destination = VTFrameProcessorFrame(buffer: losslessOut, presentationTimeStamp: time),
           let parameters = VTTemporalNoiseFilterParameters(
               sourceFrame: source, nextFrames: [], previousFrames: previousNoisy.map { [$0] } ?? [],
               destinationFrame: destination, filterStrength: 0.6, hasDiscontinuity: previousNoisy == nil),
           (try? await noise.process(parameters: parameters)) != nil,
           let denoised = makeBuffer(width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
           transfer(losslessOut, to: denoised) {
            previousNoisy = source
            clean = denoised
        } else {
            previousNoisy = nil
        }

        var current = clean
        if settings.upscale, let config = scalerConfig, ensure(&started.scaler, scaler, config),
           let up = await upscale(clean, time) {
            current = up
        }
        var middle: CVPixelBuffer?
        let outWidth = CVPixelBufferGetWidth(current), outHeight = CVPixelBufferGetHeight(current)
        if outWidth != interpolationWidth {
            if started.interpolation { interpolation.endSession() }
            interpolation = VTFrameProcessor()
            started.interpolation = false
            interpolationConfig = VTLowLatencyFrameInterpolationConfiguration(frameWidth: outWidth, frameHeight: outHeight,
                                                                              numberOfInterpolatedFrames: 1)
            interpolationWidth = outWidth
            previousClean = nil      // a frame of the other size cannot be interpolated from
        }
        let currentFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: time)
        if settings.smoothMotion, let config = interpolationConfig, ensure(&started.interpolation, interpolation, config),
           let previous = previousClean, let currentFrame,
           let output = makeBuffer(outWidth, outHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
           let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time),
           let parameters = VTLowLatencyFrameInterpolationParameters(
               sourceFrame: currentFrame, previousFrame: previous, interpolationPhase: [0.5], destinationFrames: [destination]),
           (try? await interpolation.process(parameters: parameters)) != nil {
            middle = output
        }
        previousClean = currentFrame
        guard let currentImage = cgImage(current) else { return nil }
        return (middle.flatMap(cgImage), currentImage)
    }

    private func upscale(_ source: CVPixelBuffer, _ time: CMTime) async -> CVPixelBuffer? {
        guard let output = makeBuffer(width * 2, height * 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let src = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
              let dst = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time),
              (try? await scaler.process(parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: src, destinationFrame: dst))) != nil
        else { return nil }
        return output
    }

    private func ensure(_ flag: inout Bool, _ processor: VTFrameProcessor, _ configuration: any VTFrameProcessorConfiguration) -> Bool {
        if flag { return true }
        flag = (try? processor.startSession(configuration: configuration)) != nil
        return flag
    }

    private func makeBuffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        return CVPixelBufferCreate(nil, w, h, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess ? buffer : nil
    }

    private func transfer(_ from: CVPixelBuffer, to: CVPixelBuffer) -> Bool {
        guard let transfer else { return false }
        return VTPixelTransferSessionTransferImage(transfer, from: from, to: to) == noErr
    }

    private func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }
}
