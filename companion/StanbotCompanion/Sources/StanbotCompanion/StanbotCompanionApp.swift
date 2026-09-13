import AppKit
import ImageIO
import SwiftUI
import Vision

@main
struct StanbotCompanionApp: App {
    @StateObject private var robot = RobotConnection()

    var body: some Scene {
        WindowGroup("Stanbot") {
            CompanionView()
                .environmentObject(robot)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reconnect to StackChan") { robot.connect() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
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
        case disconnected
        case connected(String)
        case unavailable

        var title: String {
            switch self {
            case .disconnected: "Not connected"
            case .connected: "USB control connected"
            case .unavailable: "StackChan not found"
            }
        }

        var tint: Color {
            switch self {
            case .connected: .green
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
    @Published var selectedPort: String?
    private var cameraReader: FileHandle?
    private var cameraWriter: FileHandle?
    private let frameDecoder = FrameDecoder()

    init() {
        selectedPort = availablePorts.first
        connect()
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
        stopCamera()
        guard let selectedPort else {
            connection = .unavailable
            lastAction = "Connect StackChan by USB-C, then reconnect."
            return
        }
        guard FileHandle(forWritingAtPath: selectedPort) != nil else {
            connection = .unavailable
            lastAction = "Couldn’t open \(portName)."
            return
        }
        connection = .connected(selectedPort)
        lastAction = "Connected locally through \(portName). Motion remains locked."
    }

    func startCamera() {
        guard case let .connected(port) = connection else {
            cameraState = .unavailable
            lastAction = "Connect StackChan before starting the local camera view."
            return
        }
        guard let reader = FileHandle(forReadingAtPath: port) else {
            cameraState = .unavailable
            lastAction = "Couldn’t open \(portName) for camera frames."
            return
        }
        cameraReader = reader
        cameraWriter = FileHandle(forWritingAtPath: port)
        cameraState = .waiting
        lastAction = "Waiting for the local StackChan camera stream."
        reader.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor in self?.receiveCameraBytes(bytes) }
        }
        cameraWriter?.write(Data("S\\n".utf8))
    }

    func stopCamera() {
        cameraWriter?.write(Data("X\\n".utf8))
        cameraReader?.readabilityHandler = nil
        cameraReader?.closeFile()
        cameraReader = nil
        cameraWriter?.closeFile()
        cameraWriter = nil
        cameraImage = nil
        faceBoxes = []
        cameraState = .off
    }

    private func receiveCameraBytes(_ bytes: Data) {
        for frame in frameDecoder.append(bytes) {
            analyze(frame)
        }
    }

    private func analyze(_ frame: CameraFrame) {
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        if cameraState != .receiving {
            lastAction = "Receiving local camera frames from StackChan."
        }
        cameraState = .receiving
        cameraImage = NSImage(cgImage: image, size: .zero)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try? handler.perform([request])
            let boxes = (request.results ?? []).map {
                FaceBox(rect: $0.boundingBox, confidence: $0.confidence)
            }
            DispatchQueue.main.async {
                self?.faceBoxes = boxes
            }
        }
    }

    func select(_ emotion: Emotion) {
        guard case let .connected(port) = connection else {
            lastAction = "Connect to StackChan before changing its expression."
            return
        }
        guard let handle = FileHandle(forWritingAtPath: port) else {
            connection = .unavailable
            lastAction = "The USB connection is no longer available."
            return
        }
        handle.write(Data("E,\(emotion.rawValue)\\n".utf8))
        selectedEmotion = emotion
        lastAction = "Expression set to \(emotion.title)."
    }
}

struct FaceBox: Identifiable {
    let id = UUID()
    let rect: CGRect  // Vision coordinates: origin at lower left.
    let confidence: Float
}

private struct CameraFrame {
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
                StatusCard(title: "Camera", value: "Standby",
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
            return robot.faceBoxes.isEmpty ? "No person detected" : "Person detected — face outlined"
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
        robot.cameraState == .receiving && !robot.faceBoxes.isEmpty
            ? "Person detected" : "No person detected"
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
                        Text("Person detected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .foregroundStyle(.black)
                            .background(.green, in: Capsule())
                            .offset(y: -26)
                    }
                    .position(x: rect.midX * proxy.size.width,
                              y: (1 - rect.midY) * proxy.size.height)
                    .animation(.smooth(duration: 0.2), value: rect)
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
