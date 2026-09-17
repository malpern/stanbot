// Can Stanbot share the Studio Display camera with a Google Meet call without
// changing the call? Step 1 of docs/desk-camera.md.
//
//   tools/desk_camera/probe.sh               # capture for 60 s, one JSON line per second
//   tools/desk_camera/probe.sh --seconds 300
//   tools/desk_camera/probe.sh --watch-only  # never start capture; camera light stays off
//
// Runs only on the Mac mini with the Studio Display attached: the host must be
// the mini (LocalHostName "openclaw" and product name "Mac mini") and a camera
// named "Studio Display Camera" must be present. Anything else exits 3 without
// touching a camera.
//
// It is a passive client by construction. It never calls lockForConfiguration,
// so it cannot change the format, frame rate, exposure, zoom or Center Stage
// directly. A session preset still picks a device format when the session
// starts, and macOS has no input-priority preset, so the probe uses the preset
// that matches the format the camera is ALREADY using (for example the one a
// call chose) and refuses to capture if none matches. It saves no frames: each frame is counted and
// dropped. Every second it prints what it receives and the device state; at the
// end it says whether the device's active format or frame duration changed
// while it ran, which would mean the call's camera was affected.
import AVFoundation
import Foundation

struct Options {
    var seconds = 60
    var watchOnly = false
}

func parse() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--seconds": options.seconds = arguments.next().flatMap(Int.init) ?? options.seconds
        case "--watch-only": options.watchOnly = true
        default:
            FileHandle.standardError.write("usage: DeskCameraProbe [--seconds N] [--watch-only]\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return options
}

func emit(_ fields: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

// MARK: - Only on the mini

/// "Mac mini", from System Information. Apple silicon's IO registry has no
/// product name, only the model identifier (Mac16,11), which changes by year.
func productName() -> String? {
    guard let output = run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]),
          let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
          let hardware = (json["SPHardwareDataType"] as? [[String: Any]])?.first else { return nil }
    return hardware["machine_name"] as? String
}

func run(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func localHostName() -> String? { run("/usr/sbin/scutil", ["--get", "LocalHostName"]) }

let options = parse()
let host = localHostName() ?? "unknown"
let product = productName() ?? "unknown"
let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video,
                                              position: .unspecified).devices
    .first { $0.localizedName == "Studio Display Camera" }
guard host.hasPrefix("openclaw"), product.hasPrefix("Mac mini"), let camera else {
    emit(["refused": "not_the_mini_with_studio_display", "host": host, "product": product,
          "studio_display_camera": camera != nil])
    exit(3)
}

// MARK: - Device state

func describe(_ format: AVCaptureDevice.Format) -> String {
    let d = format.formatDescription.dimensions
    return "\(d.width)x\(d.height)"
}

func deviceState() -> [String: Any] {
    [
        "active_format": describe(camera.activeFormat),
        "active_fps": camera.activeVideoMinFrameDuration.seconds > 0 ? (1 / camera.activeVideoMinFrameDuration.seconds * 10).rounded() / 10 : 0,
        "in_use_by_another_app": camera.isInUseByAnotherApplication,
        "center_stage_active": camera.isCenterStageActive,
        "center_stage_enabled": AVCaptureDevice.isCenterStageEnabled,
        "center_stage_control": ["user", "app", "cooperative"][min(Int(AVCaptureDevice.centerStageControlMode.rawValue), 2)],
    ]
}

let before = deviceState()
emit(["phase": "start", "host": host, "product": product, "watch_only": options.watchOnly,
      "camera_permission": ["not_determined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .video).rawValue]]
     .merging(before) { a, _ in a })

// MARK: - Passive capture

final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var frames = 0, dropped = 0
    private var size = "none"

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let dimensions = sampleBuffer.formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
        lock.lock()
        frames += 1
        if let dimensions { size = "\(dimensions.width)x\(dimensions.height)" }
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); dropped += 1; lock.unlock()
    }

    func take() -> (frames: Int, dropped: Int, size: String) {
        lock.lock(); defer { lock.unlock() }
        let result = (frames, dropped, size)
        frames = 0; dropped = 0
        return result
    }
}

let counter = Counter()
let session = AVCaptureSession()
if !options.watchOnly {
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        let asked = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .video) { _ in asked.signal() }
        asked.wait()
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        emit(["refused": "camera_permission_not_granted",
              "hint": "allow the terminal app in System Settings > Privacy & Security > Camera"])
        exit(4)
    }
    session.beginConfiguration()
    // The preset matching the current format, so starting cannot pick another.
    let presets: [String: AVCaptureSession.Preset] = [
        "640x480": .vga640x480, "1280x720": .hd1280x720, "1920x1080": .hd1920x1080,
    ]
    let current = describe(camera.activeFormat)
    guard let preset = presets[current], session.canSetSessionPreset(preset) else {
        emit(["refused": "no_preset_matches_active_format", "active_format": current,
              "hint": "not capturing, to avoid switching the camera's format; --watch-only still works"])
        exit(6)
    }
    session.sessionPreset = preset
    guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
        emit(["refused": "cannot_open_camera"]); exit(5)
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "desk-camera-probe"))
    guard session.canAddOutput(output) else { emit(["refused": "cannot_add_output"]); exit(5) }
    session.addOutput(output)
    session.commitConfiguration()
    session.startRunning()
}

var changes: [String] = []
for second in 1...max(options.seconds, 1) {
    Thread.sleep(forTimeInterval: 1)
    let (frames, dropped, size) = counter.take()
    let state = deviceState()
    for key in ["active_format", "active_fps", "center_stage_active", "in_use_by_another_app"] {
        if "\(state[key]!)" != "\(before[key]!)", !changes.contains(key) { changes.append(key) }
    }
    var line: [String: Any] = ["t": second]
    if !options.watchOnly {
        line["received_fps"] = frames
        line["dropped"] = dropped
        line["frame_size"] = size
        line["session_running"] = session.isRunning
    }
    emit(line.merging(state) { a, _ in a })
}
if !options.watchOnly { session.stopRunning() }

let after = deviceState()
let formatChanged = "\(after["active_format"]!)" != "\(before["active_format"]!)" || "\(after["active_fps"]!)" != "\(before["active_fps"]!)"
emit(["phase": "end", "changed_during_run": changes,
      "format_or_rate_changed": formatChanged,
      "note": formatChanged
        ? "The device's format or frame rate changed while probing. If a call was running, check whether it was affected; this may also be the call itself changing it."
        : "No format or frame-rate change seen on the device."]
     .merging(after) { a, _ in a })
