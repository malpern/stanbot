import AppKit
import ImageIO
import Network
import SwiftUI
import Vision
import Darwin

@main
struct StanbotCompanionApp: App {
    @NSApplicationDelegateAdaptor(StanbotAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var robot = RobotConnection()

    var body: some Scene {
        WindowGroup("Stanbot") {
            CompanionView()
                .environmentObject(robot)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Stanbot") { openWindow(id: "about") }
            }
            CommandGroup(after: .toolbar) {
                Button("Reconnect to StackChan") { robot.connect() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
        Window("About Stanbot", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}


/// Drains a serial file descriptor as bytes arrive rather than on a timer.
///
/// A polled reader silently loses data. The robot writes each JPEG as a single
/// burst, so a 21 KB frame lands in about 24 ms, entirely between two 50 ms
/// polls, and the terminal input buffer is smaller than that: the tail of the
/// frame is discarded by the kernel before anyone reads it. The decoder then
/// resyncs and the whole frame is gone. Measured on 2026-09-15, that cost two
/// thirds of the stream at quality 90 (0.93 of 3.5 frames per second arriving)
/// while smaller frames mostly survived, which is why it looked like a camera
/// problem rather than a reader problem.
///
/// Reading from a dispatch source removes the window entirely and does not care
/// how large frames are. It is also the shape a socket transport would want, so
/// nothing here is specific to USB.
private final class SerialReader {
    private let source: DispatchSourceRead
    private var decoder = FrameDecoder()
    private var stopped = false

    /// Takes ownership of `fd` and closes it when cancelled.
    fileprivate init(fd: Int32,
                     onFrames: @escaping @Sendable @MainActor ([CameraFrame]) -> Void,
                     onClosed: @escaping @Sendable @MainActor () -> Void) {
        let queue = DispatchQueue(label: "com.malpern.stanbot.serial", qos: .userInitiated)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !self.stopped {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let frames = self.decoder.append(Data(buffer.prefix(count)))
                    // main.async rather than Task, so frames stay in order.
                    if !frames.isEmpty {
                        DispatchQueue.main.async { MainActor.assumeIsolated { onFrames(frames) } }
                    }
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    return  // drained for now; the source fires again on more data
                } else {
                    self.stopped = true
                    DispatchQueue.main.async { MainActor.assumeIsolated { onClosed() } }
                    return
                }
            }
        }
        source.resume()
    }

    /// Discards anything buffered mid-frame, without disturbing the connection.
    func resetDecoder() { stopped ? () : (decoder = FrameDecoder()) }

    func cancel() {
        stopped = true
        source.cancel()
    }
}


/// Carries the same SBFR packets and newline commands as the serial link, over
/// TCP, so the robot can sit on the far side of the room with only a power
/// cable. The firmware speaks one protocol on both transports, so the decoder
/// and every command are shared.
///
/// macOS gates this behind the Local Network permission. The app must declare
/// NSLocalNetworkUsageDescription and NSBonjourServices or the prompt never
/// appears and the connection simply never completes.
// @unchecked Sendable is a claim, so here is the invariant behind it: `decoder`
// and `stopped` are touched only from the single serial queue the connection
// runs on, and every hand-off to the app hops to the main actor explicitly.
private final class NetworkReader: @unchecked Sendable {
    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private var stopped = false

    fileprivate init(host: String, port: UInt16,
                     onFrames: @escaping @Sendable @MainActor ([CameraFrame]) -> Void,
                     onState: @escaping @Sendable @MainActor (Bool, String) -> Void) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true                 // frames are latency sensitive
        options.connectionTimeout = 5
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: nil, tcp: options))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { MainActor.assumeIsolated { onState(true, "connected") } }
                self?.receive(onFrames: onFrames, onState: onState)
            case .waiting(let error):
                // Local Network denial surfaces here rather than as a failure,
                // so say so plainly instead of looking like an unreachable robot.
                DispatchQueue.main.async { MainActor.assumeIsolated { onState(false, Self.describe(error)) } }
            case .failed(let error):
                DispatchQueue.main.async { MainActor.assumeIsolated { onState(false, Self.describe(error)) } }
            case .cancelled:
                DispatchQueue.main.async { MainActor.assumeIsolated { onState(false, "disconnected") } }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.malpern.stanbot.network", qos: .userInitiated))
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EPERM || code == .EHOSTUNREACH {
            return "blocked; allow Stanbot under Local Network"
        }
        return "\(error)"
    }

    private func receive(onFrames: @escaping @Sendable @MainActor ([CameraFrame]) -> Void,
                         onState: @escaping @Sendable @MainActor (Bool, String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                let frames = self.decoder.append(data)
                if !frames.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onFrames(frames) } }
                }
            }
            if isComplete || error != nil {
                self.stopped = true
                DispatchQueue.main.async { MainActor.assumeIsolated { onState(false, "disconnected") } }
                return
            }
            self.receive(onFrames: onFrames, onState: onState)
        }
    }

    /// Fire and forget: a send failure arrives through the state handler, which
    /// is the same path an unplugged cable takes on the serial side.
    fileprivate func send(_ text: String) {
        guard !stopped else { return }
        connection.send(content: Data(text.utf8), completion: .idempotent)
    }

    fileprivate func resetDecoder() { if !stopped { decoder = FrameDecoder() } }

    fileprivate func cancel() {
        stopped = true
        connection.cancel()
    }
}

@MainActor
final class RobotConnection: ObservableObject {
    enum CameraState: Equatable {
        case off
        case waiting
        case receiving
        case unavailable

        var title: String {
            switch self {
            case .off: "Off"
            case .waiting: "Waiting for camera stream"
            case .receiving: "Live · local only"
            case .unavailable: "Unavailable"
            }
        }
    }
    enum ConnectionState: Equatable {
        case connecting
        case disconnected
        case connected(String)
        case unavailable

        var title: String {
            switch self {
            case .connecting: "Connecting over Wi-Fi"
            case .disconnected: "Not connected"
            case .connected: "USB control connected"
            case .unavailable: "StackChan not found"
            }
        }

        var tint: Color {
            switch self {
            case .connected: .green
            case .connecting: .orange
            case .disconnected: .secondary
            case .unavailable: .orange
            }
        }
    }

    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var selectedEmotion = Emotion.normal
    @Published private(set) var lastAction = "Waiting to connect"
    @Published private(set) var cameraState: CameraState = .off
    @Published private(set) var cameraImage: NSImage?
    @Published private(set) var faceBoxes: [FaceBox] = []
    @Published private(set) var faceState: FaceSelection.State = .searching
    private var faceSelection = FaceSelection()

    private func resetFaces() {
        faceSelection.reset()
        faceBoxes = []
        faceState = .searching
    }

    private func publishFaces() {
        faceBoxes = faceSelection.box.map { [$0] } ?? []
        faceState = faceSelection.state
    }
    @Published var selectedPort: String?
    private var serialFD: Int32 = -1
    private var reader: SerialReader?
    private var network: NetworkReader?
    /// Where the robot is when there is no USB cable. Resolved by mDNS, so
    /// nothing hardcodes an address that DHCP can change.
    private let networkHost = "stanbot.local"
    private let networkPort: UInt16 = 3333
    private var timer: Timer?
    // The camera stream starts by itself on connect and on every automatic
    // reconnect: the feed is the point of the app, so it should not wait for a
    // button. An explicit Stop Camera clears this and stays stopped until the
    // user asks for the feed again.
    private var wantsCamera = true
    /// True while the Wi-Fi link is the active transport rather than USB.
    private var usingNetwork = false
    private var generation = UUID()
    private var analyzing = false
    private var lastFrameAt = Date.distantPast
    private var nextReconnect = Date.distantPast

    init(port: String? = nil, automaticPolling: Bool = true) {
        selectedPort = port ?? availablePorts.first
        connect()
        guard automaticPolling else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var availablePorts: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.SLAB_USBtoUART") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    var portName: String {
        guard let selectedPort else { return "No USB device" }
        return URL(fileURLWithPath: selectedPort).lastPathComponent
    }

    func connect() {
        closeSerial()
        cameraState = wantsCamera ? .waiting : .off
        guard let selectedPort else {
            // No cable: the robot may be on Wi-Fi with the cable in its base
            // carrying power only, which is the normal arrangement once
            // provisioned. Try the network rather than declaring failure.
            connectNetwork()
            return
        }
        let fd = Darwin.open(selectedPort, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            connection = .unavailable
            lastAction = "Couldn’t open \(portName)."
            return
        }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            Darwin.close(fd)
            connection = .unavailable
            return
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&settings, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            Darwin.close(fd)
            connection = .unavailable
            return
        }
        serialFD = fd
        usingNetwork = false
        reader = SerialReader(fd: fd,
                              onFrames: { [weak self] frames in frames.forEach { self?.analyze($0) } },
                              onClosed: { [weak self] in self?.disconnected() })
        connection = .connected(selectedPort)
        lastAction = "Connected locally through \(portName). Motion remains locked."
        if wantsCamera { startCamera() }
    }

    private func connectNetwork() {
        usingNetwork = true
        connection = .connecting
        lastAction = "Looking for \(networkHost) on the network."
        network = NetworkReader(
            host: networkHost, port: networkPort,
            onFrames: { [weak self] frames in frames.forEach { self?.analyze($0) } },
            onState: { [weak self] up, detail in self?.networkStateChanged(up, detail) })
    }

    private func networkStateChanged(_ up: Bool, _ detail: String) {
        guard usingNetwork else { return }
        if up {
            connection = .connected(networkHost)
            lastAction = "Connected to \(networkHost) over Wi-Fi. Motion remains locked."
            if wantsCamera { startCamera() }
        } else {
            connection = .unavailable
            lastAction = "\(networkHost): \(detail)"
            cameraState = wantsCamera ? .waiting : .off
            nextReconnect = Date().addingTimeInterval(3)
        }
    }

    func startCamera() {
        resetFaces()
        wantsCamera = true
        guard serialFD >= 0 else {
            cameraState = .unavailable
            lastAction = "Connect StackChan before starting the local camera view."
            return
        }
        generation = UUID()
        reader?.resetDecoder(); network?.resetDecoder()
        lastFrameAt = Date()
        cameraState = .waiting
        lastAction = "Waiting for the local StackChan camera stream."
        _ = send("S\n")
    }

    func stopCamera() {
        wantsCamera = false
        _ = send("X\n")
        generation = UUID()
        reader?.resetDecoder(); network?.resetDecoder()
        cameraImage = nil
        resetFaces()
        cameraState = .off
    }

    private func closeSerial() {
        // Cancelling closes the descriptor, so drop our copy first: no write can
        // then race the close, and nothing closes it twice.
        serialFD = -1
        reader?.cancel()
        reader = nil
        network?.cancel()
        network = nil
        generation = UUID()
        cameraImage = nil
        resetFaces()
    }

    private func disconnected() {
        closeSerial()
        connection = .unavailable
        cameraState = wantsCamera ? .waiting : .off
        lastAction = "USB disconnected. Waiting for StackChan to reconnect."
        nextReconnect = Date().addingTimeInterval(1)
    }

    private func send(_ command: String) -> Bool {
        if usingNetwork {
            guard let network else { return false }
            network.send(command)
            return true   // failures surface through the connection state
        }
        guard serialFD >= 0 else { return false }
        let bytes = Array(command.utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(serialFD, $0.baseAddress, $0.count) }
        guard count == bytes.count else {
            disconnected()
            return false
        }
        return true
    }

    func tick() {
        faceSelection.expire(at: ProcessInfo.processInfo.systemUptime)
        publishFaces()
        guard serialFD >= 0 || usingNetwork else {
            // Reopen only the selected device; never switch to another USB device.
            if Date() >= nextReconnect, let selectedPort,
               FileManager.default.fileExists(atPath: selectedPort) {
                nextReconnect = Date().addingTimeInterval(2)
                connect()
            } else if Date() >= nextReconnect {
                nextReconnect = Date().addingTimeInterval(3)
                connect()
            }
            return
        }
        // Reading happens on the SerialReader's dispatch source, not here: this
        // timer only ages the face selection and watches for a stalled stream.
        if wantsCamera && Date().timeIntervalSince(lastFrameAt) > 3 {
            cameraImage = nil
            resetFaces()
            cameraState = .waiting
            generation = UUID()
            reader?.resetDecoder(); network?.resetDecoder()
            lastFrameAt = Date()
            _ = send("S\n")
        }
    }

    private func analyze(_ frame: CameraFrame) {
        guard wantsCamera, !analyzing else { return }
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        if cameraState != .receiving {
            lastAction = "Receiving local camera frames from StackChan."
        }
        cameraState = .receiving
        lastFrameAt = Date()
        analyzing = true
        let session = generation
        let receivedAt = ProcessInfo.processInfo.systemUptime

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try? handler.perform([request])
            let boxes = (request.results ?? []).filter { $0.confidence >= 0.7 }.map {
                FaceBox(rect: $0.boundingBox, confidence: $0.confidence)
            }
            DispatchQueue.main.async {
                self?.analyzing = false
                guard let self, self.generation == session,
                      ProcessInfo.processInfo.systemUptime - receivedAt < 0.75 else { return }
                // Publish the image and its detection together, never an old box on a new frame.
                self.cameraImage = NSImage(cgImage: image, size: .zero)
                self.faceSelection.update(boxes, at: receivedAt)
                self.publishFaces()
            }
        }
    }

    func select(_ emotion: Emotion) {
        guard case .connected = connection else {
            lastAction = "Connect to StackChan before changing its expression."
            return
        }
        guard send("E,\(emotion.rawValue)\n") else { return }
        selectedEmotion = emotion
        lastAction = "Expression set to \(emotion.title)."
    }
}

struct FaceBox: Identifiable {
    var id = UUID()
    let rect: CGRect  // Vision coordinates: origin at lower left.
    let confidence: Float
}

private struct CameraFrame: Sendable {
    let sequence: UInt32
    let jpeg: Data
}

private final class FrameDecoder {
    private let magic: [UInt8] = [0x53, 0x42, 0x46, 0x52] // SBFR
    private let headerLength = 13
    private let maximumJPEGBytes = 300_000
    private var buffer = Data()

    func append(_ bytes: Data) -> [CameraFrame] {
        buffer.append(bytes)
        var frames: [CameraFrame] = []
        while buffer.count >= headerLength {
            // Data's integer indices need not begin at zero after removeFirst.
            // Normalize each small packet header before indexed inspection.
            let raw = Array(buffer)
            guard Array(raw.prefix(4)) == magic else {
                buffer.removeFirst()
                continue
            }
            guard raw[4] == 1 else {
                buffer.removeFirst(4)
                continue
            }
            let sequence = uint32(raw, at: 5)
            let length = Int(uint32(raw, at: 9))
            guard (1...maximumJPEGBytes).contains(length) else {
                buffer.removeFirst(4)
                continue
            }
            guard buffer.count >= headerLength + length else { break }
            let jpeg = Data(raw[headerLength..<(headerLength + length)])
            // A USB reader may attach partway through a frame. Do not let that
            // stale header swallow a later valid packet; a JPEG payload always
            // begins with SOI (FF D8).
            guard jpeg.starts(with: [0xff, 0xd8]) else {
                buffer.removeFirst(4)
                continue
            }
            frames.append(CameraFrame(sequence: sequence, jpeg: jpeg))
            buffer.removeFirst(headerLength + length)
        }
        return frames
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}

enum Emotion: String, CaseIterable, Identifiable {
    case normal, angry, glee, happy, sad, worried, focused, annoyed, surprised
    case skeptic, frustrated, unimpressed, sleepy, suspicious, squint, furious, scared, awe

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .normal: "face.smiling"
        case .angry, .furious: "flame"
        case .glee, .happy: "sparkles"
        case .sad, .worried, .scared: "cloud.rain"
        case .focused, .skeptic, .suspicious, .squint: "eye"
        case .annoyed, .frustrated, .unimpressed: "ellipsis"
        case .surprised, .awe: "exclamationmark.bubble"
        case .sleepy: "moon.zzz"
        }
    }
}

private struct CompanionView: View {
    @EnvironmentObject private var robot: RobotConnection

    var body: some View {
        NavigationSplitView {
            List {
                Section("StackChan") {
                    Label("Control", systemImage: "slider.horizontal.3")
                    Label("Status", systemImage: "wave.3.right")
                }
                Section("Safety") {
                    Label("Motion locked", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Stanbot")
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    cameraPanel
                    statusGrid
                    expressionPicker
                    activity
                }
                .padding(28)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .navigationTitle("Control")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("USB device", selection: $robot.selectedPort) {
                            if robot.availablePorts.isEmpty {
                                Text("No compatible USB device").tag(Optional<String>.none)
                            } else {
                                ForEach(robot.availablePorts, id: \.self) { port in
                                    Text(URL(fileURLWithPath: port).lastPathComponent).tag(Optional(port))
                                }
                            }
                        }
                        Divider()
                        Button("Reconnect") { robot.connect() }
                    } label: {
                        Label("Connection", systemImage: "cable.connector")
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "face.smiling.inverse")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 76, height: 76)
                .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("Stanbot")
                    .font(.largeTitle.weight(.bold))
                StatusLabel(state: robot.connection)
            }
            Spacer()
            HStack {
                Button("Reconnect", systemImage: "arrow.clockwise") { robot.connect() }
                    .buttonStyle(.bordered)
                Button(robot.cameraState == .off ? "Show Camera" : "Stop Camera",
                       systemImage: robot.cameraState == .off ? "video" : "stop.fill") {
                    if robot.cameraState == .off { robot.startCamera() } else { robot.stopCamera() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                StatusCard(title: "Connection", value: connectionValue,
                           detail: robot.portName, symbol: "cable.connector")
                StatusCard(title: "Camera", value: robot.cameraState == .receiving ? "Live" : "Standby",
                           detail: robot.cameraState.title, symbol: "camera")
            }
            GridRow {
                StatusCard(title: "Person detection", value: personDetectionValue,
                           detail: "Visual indication only; it does not claim eye contact", symbol: "person.crop.circle")
                StatusCard(title: "Head movement", value: "Locked",
                           detail: "Calibration required before motion can be enabled", symbol: "lock.fill")
            }
        }
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Camera")
                        .font(.title2.weight(.semibold))
                    Text(cameraDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if robot.cameraState == .receiving {
                    Label("Local only", systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black)
                if let image = robot.cameraImage {
                    GeometryReader { proxy in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .overlay { FaceOverlay(boxes: robot.faceBoxes) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    ContentUnavailableView {
                        Label("Camera not streaming", systemImage: "camera")
                    } description: {
                        Text(cameraPlaceholder)
                    } actions: {
                        if robot.cameraState == .off {
                            Button("Show Camera") { robot.startCamera() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .accessibilityLabel("StackChan camera feed")
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var cameraDescription: String {
        switch robot.cameraState {
        case .receiving:
            return robot.faceState.rawValue
        case .waiting: return "Waiting for StackChan’s local USB stream"
        case .off: return "Camera feed is off"
        case .unavailable: return "Camera stream unavailable"
        }
    }

    private var cameraPlaceholder: String {
        switch robot.cameraState {
        case .waiting: "The app is listening for local camera frames over USB."
        case .unavailable: "Reconnect StackChan, then try again."
        default: "Start the local USB camera stream to see StackChan’s view."
        }
    }

    private var connectionValue: String {
        if case .connected = robot.connection { return "Connected" }
        return "Unavailable"
    }

    private var personDetectionValue: String {
        robot.cameraState == .receiving ? robot.faceState.rawValue : "Not observing"
    }

    private var expressionPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Expression")
                .font(.title2.weight(.semibold))
            Text("Changes the on-device eyes only. It cannot move the head.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                ForEach(Emotion.allCases) { emotion in
                    Button {
                        robot.select(emotion)
                    } label: {
                        Label(emotion.title, systemImage: emotion.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ExpressionButtonStyle(selected: robot.selectedEmotion == emotion))
                    .accessibilityHint("Sets Stanbot’s display-only expression")
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var activity: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Activity")
                    .font(.headline)
                Text(robot.lastAction)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FaceOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let boxes: [FaceBox]

    var body: some View {
        GeometryReader { proxy in
            ForEach(boxes) { face in
                let rect = face.rect
                let width = rect.width * proxy.size.width
                let height = rect.height * proxy.size.height
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.green, lineWidth: 3)
                    .frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        Text("Face selected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .foregroundStyle(.black)
                            .background(.green, in: Capsule())
                            .offset(y: -26)
                    }
                    .position(x: rect.midX * proxy.size.width,
                              y: (1 - rect.midY) * proxy.size.height)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: rect)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boxes.isEmpty ? "No person detected" : "Person detected")
    }
}

private struct StatusLabel: View {
    let state: RobotConnection.ConnectionState

    var body: some View {
        Label(state.title, systemImage: "circle.fill")
            .font(.subheadline)
            .foregroundStyle(state.tint)
            .symbolRenderingMode(.hierarchical)
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ExpressionButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
            .animation(.smooth(duration: 0.22), value: selected)
    }
}
