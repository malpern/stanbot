import AVFoundation
import Foundation
import Vision

/// The Studio Display camera as a second, passive view of the desk: faces, head
/// pose and the facing class, logged beside the robot's own view during follow
/// sessions (docs/desk-camera.md, step 2). Off by default. Nothing reads it for
/// control; it exists to label and compare.
///
/// It must never disturb a video call using the same camera. So it never locks
/// the device for configuration, uses the session preset that matches the
/// camera's CURRENT format (macOS has no input-priority preset) and refuses to
/// run if none matches, and analyses at most `analysisInterval` apart.
/// Coexistence with Google Meet is what tools/desk_camera/probe.sh tests;
/// leave this off until that test has passed.
final class DeskCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case off
        case running(format: String)
        case unavailable(String)
    }

    static let deviceName = "Studio Display Camera"
    static let analysisInterval: TimeInterval = 0.2   // 5 fps at most

    @Published private(set) var state: State = .off
    /// Called on the main queue after each analysed frame.
    var onAnalysis: ((DeskAnalysis) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "desk-camera")
    private var lastAnalysis: TimeInterval = -.infinity
    private var device: AVCaptureDevice?

    /// The preset that leaves a device's current format alone, if there is one.
    static func preset(matching format: String) -> AVCaptureSession.Preset? {
        ["640x480": .vga640x480, "1280x720": .hd1280x720, "1920x1080": .hd1920x1080][format]
    }

    static func shouldAnalyze(now: TimeInterval, last: TimeInterval) -> Bool {
        now - last >= analysisInterval - 0.001   // a frame a hair early still counts
    }

    func start() {
        guard state == .off || { if case .unavailable = state { return true }; return false }() else { return }
        guard NSClassFromString("XCTestCase") == nil else { return }   // tests never open a camera
        guard let camera = Self.findCamera() else {
            state = .unavailable("No Studio Display camera on this Mac.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure(camera)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    // Looked up again rather than captured: devices are not Sendable.
                    if granted, let camera = Self.findCamera() { self.configure(camera) }
                    else { self.state = .unavailable("Camera access was not allowed.") }
                }
            }
        default:
            state = .unavailable("Camera access is off for Stanbot in System Settings, Privacy & Security.")
        }
    }

    static func findCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video,
                                         position: .unspecified)
            .devices.first { $0.localizedName == deviceName }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        state = .off
    }

    private func configure(_ camera: AVCaptureDevice) {
        let dimensions = camera.activeFormat.formatDescription.dimensions
        let format = "\(dimensions.width)x\(dimensions.height)"
        guard let preset = Self.preset(matching: format) else {
            state = .unavailable("The camera is using \(format); not starting, to avoid changing it.")
            return
        }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        guard session.canSetSessionPreset(preset),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            session.commitConfiguration()
            state = .unavailable("Could not open the Studio Display camera.")
            return
        }
        session.sessionPreset = preset
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            state = .unavailable("Could not read frames from the Studio Display camera.")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        device = camera
        state = .running(format: format)
        queue.async { self.session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.shouldAnalyze(now: now, last: lastAnalysis),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let width = CVPixelBufferGetWidth(pixels)
        let degrees = { (value: NSNumber?) in value.map { $0.doubleValue * 180 / .pi } }
        let faces = (request.results ?? []).filter { $0.confidence >= 0.7 }.map { face in
            FaceBox(rect: face.boundingBox, confidence: face.confidence,
                    pose: degrees(face.yaw).map { HeadPose(yaw: $0, pitch: degrees(face.pitch), roll: degrees(face.roll)) },
                    frameWidth: width)
        }
        let analysis = DeskAnalysis(time: now, faces: faces, frameWidth: width,
                                    inUseByAnotherApp: device?.isInUseByAnotherApplication ?? false,
                                    centerStageActive: device?.isCenterStageActive ?? false)
        DispatchQueue.main.async { self.onAnalysis?(analysis) }
    }
}

/// One analysed desk-camera frame.
struct DeskAnalysis: Equatable {
    let time: TimeInterval          // host uptime, the same clock as the robot frames' receivedAt
    let faces: [FaceBox]
    let frameWidth: Int
    let inUseByAnotherApp: Bool
    let centerStageActive: Bool

    /// The DESK line for a session log. Center Stage pans and crops, so frames
    /// taken while it is active are flagged as unusable for geometry.
    var logLine: String {
        let angle = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "null" }
        let faces = faces.map {
            String(format: "[%.3f,%.3f,%.3f,%.3f,%.2f,", $0.rect.midX, $0.rect.midY, $0.rect.width, $0.rect.height, $0.confidence)
                + "\(angle($0.pose?.yaw)),\(angle($0.pose?.pitch)),\"\(Facing.classify($0).rawValue)\"]"
        }
        return "DESK {\"t\":\(String(format: "%.3f", time)),\"frame_width\":\(frameWidth),\"faces\":[\(faces.joined(separator: ","))],"
            + "\"in_use_by_another_app\":\(inUseByAnotherApp),\"center_stage_active\":\(centerStageActive)}"
    }
}

extension FaceBox: Equatable {
    static func == (a: FaceBox, b: FaceBox) -> Bool {
        a.id == b.id && a.rect == b.rect && a.confidence == b.confidence && a.pose == b.pose && a.frameWidth == b.frameWidth
    }
}
