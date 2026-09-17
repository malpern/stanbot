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
    @StateObject private var robot = RobotConnection.fromEnvironment()
    @State private var speech = SpeechMouth()
    @State private var confirmingTurnOff = false
    @AppStorage("StanbotShowControls") private var showControls = true

    var body: some Scene {
        WindowGroup("Stanbot") {
            CompanionView()
                .environmentObject(robot)
                .environment(speech)
                .confirmationDialog("Turn Stanbot off?", isPresented: $confirmingTurnOff) {
                    Button("Turn Off", role: .destructive) { robot.turnOffRobot() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The robot powers down completely. You will have to press its own button to turn it back on. To darken its screen but keep it on Wi-Fi, use Sleep in the controls panel instead.")
                }
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Stanbot") { openWindow(id: "about") }
            }
            CommandGroup(after: .sidebar) {
                Button(showControls ? "Hide Controls" : "Show Controls") { showControls.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandGroup(before: .windowList) {
                Button("Diagnostics") { openWindow(id: "diagnostics") }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                Divider()
            }
            CommandMenu("Robot") {
                if case .following = robot.follow {
                    Button("Stop Following") { robot.stopFollowing() }
                        .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button("Follow…") { robot.confirmingFollow = true }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .disabled(robot.followUnavailableReason != nil)
                }
                Toggle("Follow Automatically", isOn: $robot.followAutomatically)
                Divider()
                Button(robot.cameraState == .off ? "Show Camera" : "Hide Camera") {
                    robot.cameraState == .off ? robot.startCamera() : robot.stopCamera()
                }
                .keyboardShortcut("k", modifiers: [.command])
                Picker("Expression", selection: Binding(get: { robot.selectedEmotion }, set: { robot.select($0) })) {
                    ForEach(Emotion.allCases) { emotion in
                        Label(emotion.title, systemImage: emotion.symbol).tag(emotion)
                    }
                }
                Divider()
                if speech.playing {
                    Button("Stop Mouth Test") { speech.stop() }
                } else {
                    // Phase 1 of docs/voice.md: a recorded voice drives the mouth
                    // in the app and, over Wi-Fi, on the robot.
                    Button("Play Mouth Test") { speech.playTest(robotHost: robot.mouthHost) }
                }
                Divider()
                Button("Reconnect") { robot.connect() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Reboot Robot") { robot.rebootRobot() }
                    .disabled(!(robot.connectedOverUSB || (robot.connectedOverWiFi && robot.passphraseAvailable)))
                Button("Turn Robot Off…") { confirmingTurnOff = true }
                    .disabled(!(robot.connectedOverUSB || (robot.connectedOverWiFi && robot.passphraseAvailable)))
            }
        }
        Settings {
            TransportSettingsView()
                .environmentObject(robot)
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(robot)
        }
        .defaultSize(width: 820, height: 620)
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
                     onChunk: @escaping @Sendable @MainActor (DecodedChunk) -> Void,
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
                    let chunk = self.decoder.append(Data(buffer.prefix(count)))
                    // main.async rather than Task, so frames stay in order.
                    if !chunk.isEmpty {
                        DispatchQueue.main.async { MainActor.assumeIsolated { onChunk(chunk) } }
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
                     onChunk: @escaping @Sendable @MainActor (DecodedChunk) -> Void,
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
                self?.receive(onChunk: onChunk, onState: onState)
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

    private func receive(onChunk: @escaping @Sendable @MainActor (DecodedChunk) -> Void,
                         onState: @escaping @Sendable @MainActor (Bool, String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                let chunk = self.decoder.append(data)
                if !chunk.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onChunk(chunk) } }
                }
            }
            if isComplete || error != nil {
                self.stopped = true
                DispatchQueue.main.async { MainActor.assumeIsolated { onState(false, "disconnected") } }
                return
            }
            self.receive(onChunk: onChunk, onState: onState)
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
            case .connected(let link): link.hasPrefix("/dev/") ? "USB control connected" : "Wi-Fi control connected"
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
    @Published private(set) var lastAction = "Waiting to connect" {
        didSet {
            guard lastAction != oldValue else { return }
            activity.insert(ActivityEntry(date: Date(), text: lastAction), at: 0)
            if activity.count > 100 { activity.removeLast(activity.count - 100) }
        }
    }
    /// Everything `lastAction` has said, newest first, for the inspector.
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var cameraState: CameraState = .off
    @Published private(set) var cameraImage: NSImage?
    @Published private(set) var faceBoxes: [FaceBox] = []
    @Published private(set) var faceState: FaceSelection.State = .searching
    /// The selected person has been facing the robot for a moment (EngagementTracker).
    @Published private(set) var engaged = false
    private var engagement = EngagementTracker()
    @Published private(set) var firmware: FirmwareStatus = .unknown
    /// Display-only enhancements, set in Settings. Face detection is unaffected.
    @Published var enhancement: VideoEnhancement = .stored {
        didSet {
            guard enhancement != oldValue else { return }
            enhancement.store()
            enhancerSession = nil   // start the frame history afresh
        }
    }
    private let enhancer = VideoEnhancer()
    @Published private(set) var follow: FollowState = .idle
    /// The "Start head following?" confirmation is showing. Lives here so the
    /// Robot menu and the control bar ask the same way.
    @Published var confirmingFollow = false
    /// Start a session whenever a face is confirmed, without pressing Follow.
    /// Whether a session starts by itself when a face is confirmed, for this
    /// run of the app. Starts from the Settings preference on every launch, so
    /// a Stop (which turns it off) lasts only until the app is next opened.
    @Published var followAutomatically: Bool = RobotConnection.followAutomaticallyOnLaunch
    /// The Settings preference: follow automatically whenever the app opens.
    @Published var followAutomaticallyOnLaunch: Bool = RobotConnection.followAutomaticallyOnLaunch {
        didSet {
            UserDefaults.standard.set(followAutomaticallyOnLaunch, forKey: Self.followAutomaticallyKey)
            followAutomatically = followAutomaticallyOnLaunch
        }
    }
    static let followAutomaticallyKey = "StanbotFollowAutomatically"
    static var followAutomaticallyOnLaunch: Bool {
        UserDefaults.standard.object(forKey: followAutomaticallyKey) as? Bool ?? true
    }
    private var lastFollowEnded: Date?
    private var targetSequence: UInt32 = 0
    /// Every text line from the robot during a session and shortly after, so the
    /// trace (SBPD), result (SBMV), loop stats (SBFL) and power summary (SBPW)
    /// survive while the app holds the serial port.
    @Published private(set) var followLogURL: URL?
    private var followLog: FileHandle?
    /// Where session logs go. Tests pass a temporary directory so they never
    /// write into the user's Logs folder, as they did on 2026-09-16.
    private let followLogDirectory: URL
    /// Where follow session logs are written, for Diagnostics.
    var followLogFolder: URL { followLogDirectory }
    /// The robot passphrase, for authorizing FOLLOW and REBOOT over Wi-Fi.
    private let passphrase: () -> String?
    /// A Wi-Fi command waiting on the robot's challenge or its verdict.
    private enum PendingAuthorization { case follow, reboot, turnOff }
    private var pendingAuthorization: PendingAuthorization?
    private var authorizationSentAt = Date.distantPast
    @Published private(set) var passphraseAvailable = false
    /// The robot's screen is dark and its stream stopped, but it is still on the
    /// network and Wake brings it back (SBSL).
    @Published private(set) var asleep = false
    private var sleepCommandedAt = Date.distantPast
    /// The robot's own report of whether its head can reach its base (SBHL):
    /// nil healthy or not yet known, otherwise what is wrong, in words. With the
    /// base unreachable there is no motor power and no light bar.
    @Published private(set) var robotFault: String?
    /// Sessions that were started and never reported back, in a row. One may be
    /// a lost line; two is a fault and stops the automatic retrying.
    private var sessionsWithoutResult = 0
    /// When the owner last woke the robot, until the look-around session it asks
    /// for has started (AutoFollow.wakeScanWindow).
    private var wokeAt: Date?
    private var lookingAroundSince: Date?
    /// The robot looked around on waking and found someone: the face reacts
    /// (surprised, glee, focused), as the robot's own does. A new date each time.
    @Published private(set) var foundSomeoneAt: Date?
    private var followLogUntil = Date.distantPast
    private var telemetryCheck = TelemetryCheck()
    /// Longer than the robot's 3 minute maximum session plus its telemetry, so a missing
    /// result is reported rather than leaving the Stop button up forever.
    private static let followResultTimeout: TimeInterval = 200
    private var enhancerSession: UUID?
    private var lastDisplayedAt: TimeInterval?
    private var displayToken = UUID()
    private var versionAttempts = 0
    private var versionAskedAt = Date.distantPast
    private static let versionRetryInterval: TimeInterval = 2
    private static let versionMaxAttempts = 3
    private var faceSelection = FaceSelection()

    private func resetFaces() {
        faceSelection.reset()
        faceBoxes = []
        faceState = .searching
        engagement.reset()
        engaged = false
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
    private let networkHost: String
    private let networkPort: UInt16
    /// Which links the app may use; see TransportPreference. Changing it
    /// reconnects immediately.
    @Published var transport: TransportPreference {
        didSet {
            guard transport != oldValue else { return }
            if persistTransport {
                UserDefaults.standard.set(transport.rawValue, forKey: TransportPreference.defaultsKey)
            }
            connect()
        }
    }
    /// False when a test passed the preference in, so tests never write defaults.
    private let persistTransport: Bool
    /// How often an automatic connection that fell back to USB tries Wi-Fi again.
    private let wifiRetryInterval: TimeInterval
    /// An attempt that has neither connected nor failed by now is treated as failed,
    /// so a silent network cannot leave automatic mode stuck short of its USB fallback.
    private static let wifiConnectTimeout: TimeInterval = 6
    private var networkStartedAt = Date.distantPast
    /// A background Wi-Fi attempt made while automatic mode is on USB. Only
    /// if it connects does the app leave USB, so a failed try costs nothing.
    private var probe: NetworkReader?
    private var probeID = UUID()
    private var probeStartedAt = Date.distantPast
    private var nextWiFiProbe = Date.distantPast
    /// True only while the current Wi-Fi connection is ready. `usingNetwork`
    /// says which transport is chosen; this says whether it is up.
    private var networkUp = false
    /// Identifies the live NetworkReader, so a late callback from one that was
    /// cancelled (every reconnect cancels the last) cannot mark the new link down.
    private var networkReaderID = UUID()
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

    init(port: String? = nil, automaticPolling: Bool = true,
         networkHost: String = "stanbot.local", networkPort: UInt16 = 3333,
         transport: TransportPreference? = nil, wifiRetryInterval: TimeInterval = 30,
         followLogDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Stanbot"),
         passphrase: (() -> String?)? = nil, connectOnStart: Bool = true) {
        self.followLogDirectory = followLogDirectory
        // The Keychain item belongs to the signed app. Reading it from the test
        // runner would raise a macOS permission dialog mid-run, so under XCTest
        // the default is no passphrase and tests that need one inject it.
        // Tests never shell out to sops; they inject what they need.
        let underTests = NSClassFromString("XCTestCase") != nil
        self.passphrase = passphrase ?? (underTests ? { nil } : { RobotPassphrase.read() })
        self.networkHost = networkHost
        self.networkPort = networkPort
        self.transport = transport ?? .stored
        self.persistTransport = transport == nil
        self.wifiRetryInterval = wifiRetryInterval
        selectedPort = port ?? availablePorts.first
        guard connectOnStart else { return }
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

    /// One line for Settings: which link is in use right now.
    var linkSummary: String {
        switch connection {
        case .connected where usingNetwork: "Wi-Fi (\(networkHost))"
        case .connected: "USB (\(portName))"
        case .connecting: "Connecting over Wi-Fi…"
        case .disconnected, .unavailable: "Not connected"
        }
    }

    var portName: String {
        if usingNetwork { return networkHost }
        guard let selectedPort else { return "No USB device" }
        return URL(fileURLWithPath: selectedPort).lastPathComponent
    }

    func connect() {
        closeSerial()
        cameraState = wantsCamera ? .waiting : .off
        switch transport {
        case .usb:
            if !connectUSB() && connection != .unavailable {
                connection = .unavailable
            }
        case .wifi, .automatic:
            // Automatic tries Wi-Fi first and falls back to USB from
            // networkStateChanged, once the attempt has actually failed.
            connectNetwork()
        }
    }

    /// Opens the USB link. Returns false, with `lastAction` saying why, when
    /// there is no usable device. Reopens only the selected device and never
    /// switches to a different one; with none selected, adopts the first.
    @discardableResult
    private func connectUSB(afterWiFi reason: String? = nil) -> Bool {
        if selectedPort == nil { selectedPort = availablePorts.first }
        guard let selectedPort, FileManager.default.fileExists(atPath: selectedPort) else {
            connection = .unavailable
            lastAction = reason.map { "Wi-Fi unavailable (\($0)), and no USB device is connected." }
                ?? "No USB device. Waiting for StackChan to be plugged in."
            return false
        }
        let fd = Darwin.open(selectedPort, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            connection = .unavailable
            lastAction = "Couldn’t open \(URL(fileURLWithPath: selectedPort).lastPathComponent)."
            return false
        }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            Darwin.close(fd)
            connection = .unavailable
            return false
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&settings, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            Darwin.close(fd)
            connection = .unavailable
            return false
        }
        serialFD = fd
        usingNetwork = false
        reader = SerialReader(fd: fd,
                              onChunk: { [weak self] chunk in self?.handle(chunk) },
                              onClosed: { [weak self] in self?.disconnected() })
        connection = .connected(selectedPort)
        if let reason {
            lastAction = "Wi-Fi unavailable (\(reason)); using USB through \(portName). Will return to Wi-Fi when it is back."
        } else {
            lastAction = "Connected locally through \(portName)."
        }
        nextWiFiProbe = Date().addingTimeInterval(wifiRetryInterval)
        requestVersion()
        if wantsCamera { startCamera() }
        return true
    }

    private func connectNetwork() {
        usingNetwork = true
        networkUp = false
        networkStartedAt = Date()
        connection = .connecting
        lastAction = "Looking for \(networkHost) on the network."
        let id = UUID()
        networkReaderID = id
        network = NetworkReader(
            host: networkHost, port: networkPort,
            onChunk: { [weak self] chunk in
                guard let self, self.networkReaderID == id else { return }
                self.handle(chunk)
            },
            onState: { [weak self] up, detail in
                guard let self, self.networkReaderID == id else { return }
                self.networkStateChanged(up, detail)
            })
    }

    private func networkStateChanged(_ up: Bool, _ detail: String) {
        guard usingNetwork else { return }
        networkUp = up
        if up {
            connection = .connected(networkHost)
            refreshPassphrase()
            lastAction = "Connected to \(networkHost) over Wi-Fi."
            requestVersion()
            if wantsCamera { startCamera() }
        } else {
            // Drop the reader so tick() sees no link and reconnects; its own
            // cancellation callback is ignored by the reader ID check.
            networkReaderID = UUID()
            network?.cancel()
            network = nil
            connection = .unavailable
            firmware = .unknown
            cameraImage = nil
            resetFaces()
            lastAction = "\(networkHost): \(detail)"
            cameraState = wantsCamera ? .waiting : .off
            nextReconnect = Date().addingTimeInterval(3)
            if transport == .automatic && connectUSB(afterWiFi: detail) { return }
        }
    }

    /// Automatic mode on USB: try Wi-Fi alongside, and move over only once it
    /// is actually connected.
    private func startWiFiProbe() {
        let id = UUID()
        probeID = id
        probeStartedAt = Date()
        probe = NetworkReader(
            host: networkHost, port: networkPort,
            onChunk: { [weak self] chunk in
                guard let self, self.networkReaderID == id else { return }
                self.handle(chunk)
            },
            onState: { [weak self] up, detail in
                guard let self else { return }
                if self.networkReaderID == id {        // promoted: an ordinary Wi-Fi link now
                    self.networkStateChanged(up, detail)
                } else if self.probeID == id {
                    up ? self.promoteProbe() : self.endProbe()
                }
            })
    }

    private func endProbe() {
        probeID = UUID()
        probe?.cancel()
        probe = nil
        nextWiFiProbe = Date().addingTimeInterval(wifiRetryInterval)
    }

    private func promoteProbe() {
        guard let link = probe else { return }
        let id = probeID
        probe = nil
        probeID = UUID()
        // Leave USB. Drop the descriptor before cancelling, as closeSerial does.
        serialFD = -1
        reader?.cancel()
        reader = nil
        generation = UUID()
        cameraImage = nil
        resetFaces()
        network = link
        networkReaderID = id
        usingNetwork = true
        networkStateChanged(true, "connected")
        lastAction = "Wi-Fi is back; switched from USB to \(networkHost)."
    }

    func startCamera() {
        resetFaces()
        wantsCamera = true
        guard serialFD >= 0 || networkUp else {
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
        networkReaderID = UUID()
        networkUp = false
        network?.cancel()
        network = nil
        probeID = UUID()
        probe?.cancel()
        probe = nil
        generation = UUID()
        cameraImage = nil
        firmware = .unknown
        if case .following = follow { follow = .finished(FollowResult(code: "no_result")) }
        resetFaces()
    }

    /// Asks the robot what it is running. Sent on every connect, because a
    /// reconnect is often a reflash, and retried a few times since a reply can
    /// be lost to a decoder reset while the stream is starting.
    private func requestVersion() {
        versionAttempts = 1
        versionAskedAt = Date()
        firmware = .asking
        _ = send("V\n")
    }

    private func handle(_ chunk: DecodedChunk) {
        chunk.lines.forEach(handleLine)
        chunk.frames.forEach(analyze)
    }

    private func handleLine(_ line: String) {
        if let followLog, Date() < followLogUntil {
            followLog.write(Data((line + "\n").utf8))
        }
        if let outcome = telemetryCheck.consume(line) {
            reportTelemetryCheck(outcome)
        }
        if let info = FirmwareInfo.parse(line) {
            firmware = .reported(info)
            announceFirmwareChange(info)
            return
        }
        if line.hasPrefix("SBAC ") || line.hasPrefix("SBAU ") {
            handleAuthorization(line)
            return
        }
        if line.hasPrefix("SBHL "),
           let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
           let healthy = object["base"] as? Bool {
            let code = object["esp_err"] as? Int ?? 0
            robotFault = healthy ? nil
                : "The robot's head cannot reach its base (I2C error \(code)): no motor power and no light bar. Reboot the robot."
            if !healthy { lastAction = robotFault ?? lastAction }
            return
        }
        if line.hasPrefix("SBSL "),
           let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
           let sleeping = object["asleep"] as? Bool {
            // A report that disagrees with a command sent in the last two seconds
            // is the previous state arriving late (sleep clicked mid-wake made the
            // eyes open, close and open again, 2026-09-17). The robot's next
            // report settles it.
            if sleeping != asleep, Date().timeIntervalSince(sleepCommandedAt) < 2 { return }
            asleep = sleeping
            return
        }
        guard case .following = follow, line.hasPrefix("SBMV ") || line.hasPrefix("SBPW "),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
        else { return }
        // The result line, or a refusal the robot reports before a session opens.
        let code = line.hasPrefix("SBMV ") && object["plan"] as? String == "follow"
            ? object["result"] as? String
            : object["error"] as? String
        guard let code else { return }
        sessionsWithoutResult = 0   // the robot answered
        follow = .finished(FollowResult(code: code))
        lastFollowEnded = Date()
        lastAction = "Head following: \(FollowResult(code: code).summary)"
        followLogUntil = Date().addingTimeInterval(5)   // the power summary follows the result
    }

    /// A soft sound when the robot comes back on a different build, so a flash
    /// is noticed without watching the Firmware card. The last commit is
    /// remembered across launches, since the app is usually closed for a flash.
    private func announceFirmwareChange(_ info: FirmwareInfo) {
        let key = "StanbotLastFirmwareCommit"
        let previous = UserDefaults.standard.string(forKey: key)
        guard previous != info.commit else { return }
        UserDefaults.standard.set(info.commit, forKey: key)
        guard previous != nil else { return }   // nothing to compare against on a first run
        FirmwareChime.stored.play()
        lastAction = "Robot is now running \(info.shortCommit)."
    }

    var connectedOverUSB: Bool { serialFD >= 0 && !usingNetwork }
    var connectedOverWiFi: Bool { usingNetwork && networkUp }
    /// Where the speaking mouth's packets go: the robot, only while connected
    /// over Wi-Fi (the robot accepts them only from its Wi-Fi viewer's address).
    var mouthHost: String? { connectedOverWiFi ? networkHost : nil }

    func refreshPassphrase() { passphraseAvailable = passphrase() != nil }

    /// Why a session cannot start now, or nil when it can.
    var followUnavailableReason: String? {
        guard connectedOverUSB || connectedOverWiFi else { return "Connect to the robot first." }
        if connectedOverWiFi && !passphraseAvailable {
            return "Over Wi-Fi, starting needs the robot passphrase. Add it in Settings."
        }
        guard case .reported(let info) = firmware else { return "Waiting for the robot to report its firmware." }
        guard info.followLimitsMeasured else {
            return "This firmware has following disabled. It needs a calibration build (STANBOT_FOLLOW_CALIBRATION=1)."
        }
        guard cameraState == .receiving else { return "Needs the camera stream, to find a face." }
        return nil
    }

    func startFollowing() {
        guard followUnavailableReason == nil, pendingAuthorization == nil else { return }
        if case .following = follow { return }
        if connectedOverWiFi {
            requestAuthorization(.follow)
            return
        }
        guard send("C,FOLLOW\n") else { return }
        beginFollowing()
    }

    private func beginFollowing() {
        targetSequence = 0   // frame sequences only have to increase within a session
        openFollowLog()
        follow = .following(since: Date())
        lastAction = "Head following started. Stay at the robot."
    }

    private func requestAuthorization(_ purpose: PendingAuthorization) {
        guard send("A,?\n") else { return }
        pendingAuthorization = purpose
        authorizationSentAt = Date()
        lastAction = "Authorizing with the robot over Wi-Fi…"
    }

    /// SBAC carries the challenge to answer; SBAU the robot's verdict.
    private func handleAuthorization(_ line: String) {
        guard let purpose = pendingAuthorization,
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
        else { return }
        let command = switch purpose {
        case .follow: "FOLLOW"
        case .reboot: "REBOOT"
        case .turnOff: "OFF"
        }
        if line.hasPrefix("SBAC "), let nonce = object["nonce"] as? String {
            guard let key = passphrase() else {
                pendingAuthorization = nil
                follow = .finished(FollowResult(code: "auth_no_passphrase"))
                return
            }
            _ = send("A,\(command),\(CommandAuthorization.mac(command: command, nonce: nonce, passphrase: key))\n")
            authorizationSentAt = Date()
            return
        }
        guard line.hasPrefix("SBAU "), object["command"] as? String == command else { return }
        pendingAuthorization = nil
        let ok = object["ok"] as? Bool ?? false
        let reason = object["reason"] as? String ?? "unknown"
        switch (purpose, ok) {
        case (.follow, true): beginFollowing()
        case (.reboot, true): follow = .idle; lastAction = "Rebooting the robot for a fresh motion session."
        case (.turnOff, true):
            follow = .idle
            lastAction = "Turning the robot off. Press its button to turn it back on."
        case (_, false):
            follow = .finished(FollowResult(code: "auth_\(reason)"))
            lastAction = "The robot refused authorization: \(reason)."
        }
    }

    /// Writes the check into the session log, and says so when a block arrived
    /// damaged: its numbers are then not evidence of how the head behaved.
    private func reportTelemetryCheck(_ outcome: TelemetryCheck.Outcome) {
        let summary: String
        switch outcome {
        case .verified(let lines): summary = "\"verified\",\"lines\":\(lines)"
        case .corrupted(let expected, let received):
            summary = "\"corrupted\",\"expected_lines\":\(expected),\"received_lines\":\(received)"
            lastAction = "The robot's session telemetry arrived damaged; don't trust this session's numbers."
        case .unchecked: summary = "\"unchecked\""
        }
        if let followLog, Date() < followLogUntil {
            followLog.write(Data("APP {\"telemetry_check\":\(summary)}\n".utf8))
        }
    }

    private func openFollowLog() {
        let directory = followLogDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("follow-\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? followLog?.close()
        followLog = try? FileHandle(forWritingTo: url)
        followLogUntil = Date().addingTimeInterval(Self.followResultTimeout + 10)
        followLogURL = url
    }

    /// One APP line per analysed frame during a session: how many faces Vision
    /// found, what the selection made of them, and whether a target went out.
    /// Session 2 could not tell a face leaving the frame from the selection
    /// dropping it; these lines can.
    private func logFollowFrame(faces: [FaceBox], sent: FaceBox?, receivedAt: TimeInterval) {
        guard case .following = follow, let followLog, Date() < followLogUntil else { return }
        let angle = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "null" }
        let detected = faces.map {
            String(format: "[%.3f,%.3f,%.3f,%.3f,%.2f,", $0.rect.midX, $0.rect.midY, $0.rect.width, $0.rect.height, $0.confidence)
                + "\(angle($0.pose?.yaw)),\(angle($0.pose?.pitch)),\"\(Facing.classify($0).rawValue)\"]"
        }
        var fields = "\"t\":\(String(format: "%.3f", receivedAt)),\"faces\":\(faces.count),\"detections\":[\(detected.joined(separator: ","))],\"state\":\"\(faceSelection.state)\""
        if let sent {
            fields += ",\"facing\":\"\(Facing.classify(sent).rawValue)\""
            fields += ",\"sent\":\(targetSequence),\"x\":\(String(format: "%.3f", sent.rect.midX * 2 - 1)),\"y\":\(String(format: "%.3f", 1 - sent.rect.midY * 2))"
        }
        followLog.write(Data("APP {\(fields)}\n".utf8))
    }

    // MARK: Manual steering

    /// True while the joystick or arrow keys are held.
    @Published private(set) var steering = false
    private var steerX = 0.0, steerY = 0.0
    private var steerSequence: UInt32 = 0
    private var steerTask: Task<Void, Never>?
    /// How often the stick position is resent while held. The robot holds the
    /// head still if it hears nothing for 300 ms, so this must be well inside.
    static let steerInterval: Duration = .milliseconds(100)

    /// Joystick deflection, each in [-1, 1]: +x turns the head to the robot's
    /// right, +y tilts it up. Starts a session if none is running, without the
    /// confirmation Follow asks for, since grabbing the stick is the intent.
    /// Face targets are ignored while steering; 1.5 s after release the robot
    /// resumes following from wherever the head was left.
    func steer(x: Double, y: Double) {
        guard followUnavailableReason == nil else { return }
        steerX = min(max(x, -1), 1)
        steerY = min(max(y, -1), 1)
        if !steering {
            steering = true
            if case .following = follow {} else if pendingAuthorization == nil { startFollowing() }
            sendSteer()
            steerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.steerInterval)
                    guard let self, self.steering else { return }
                    self.sendSteer()
                }
            }
        }
    }

    func endSteering() {
        guard steering else { return }
        steering = false
        steerTask?.cancel()
        steerTask = nil
        steerX = 0
        steerY = 0
        sendSteer()   // centred: the head stops now rather than after the hold timeout
    }

    private func sendSteer() {
        steerSequence &+= 1
        if steerSequence == 0 { steerSequence = 1 }
        _ = send(String(format: "H,%u,%.2f,%.2f\n", steerSequence, steerX, steerY))
    }

    func stopFollowing() {
        // An explicit stop also turns automatic following off: otherwise it
        // would start again a few seconds later, which is not what Stop means.
        followAutomatically = false
        guard case .following = follow else { return }
        // Allowed on either link without authorization: stopping only makes the
        // robot safer. The robot also ends the session by itself.
        _ = send("C,UNFOLLOW\n")
        lastAction = "Asked the robot to stop following."
    }

    /// Sleep darkens the robot's screen and stops its camera, leaving Wi-Fi up;
    /// Wake brings it back. Neither needs the passphrase: both do less than the
    /// camera commands any viewer may already send.
    func sleep() {
        guard connectedOverUSB || connectedOverWiFi, !asleep else { return }
        if case .following = follow { stopFollowing() }
        guard send("C,SLEEP\n") else { return }
        sleepCommandedAt = Date()
        asleep = true   // confirmed by the robot's SBSL
        lastAction = "Asked the robot to sleep."
        // The robot stops sending straight away; stop analysing once the
        // eyelids have finished closing, so the animation has frames to use.
        let wanted = wantsCamera
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(EyeMotionSequence.sleepDuration + 0.1))
            guard let self, self.asleep else { return }
            self.stopCamera()
            self.wantsCamera = wanted   // wake brings the picture back
        }
    }

    func wake() {
        guard connectedOverUSB || connectedOverWiFi, asleep else { return }
        guard send("C,WAKE\n") else { return }
        sleepCommandedAt = Date()
        wokeAt = Date()
        asleep = false
        lastAction = "Woke the robot."
        if wantsCamera { startCamera() }
    }

    /// Turns the whole robot off. Only its own button turns it back on, so over
    /// Wi-Fi this needs the passphrase, like rebooting.
    func turnOffRobot() {
        if case .following = follow { stopFollowing() }
        if connectedOverWiFi {
            guard passphraseAvailable, pendingAuthorization == nil else { return }
            requestAuthorization(.turnOff)
            return
        }
        guard connectedOverUSB else { return }
        _ = send("C,OFF\n")
        lastAction = "Turning the robot off. Press its button to turn it back on."
    }

    func rebootRobot() {
        if connectedOverWiFi {
            guard passphraseAvailable, pendingAuthorization == nil else { return }
            requestAuthorization(.reboot)
            return
        }
        guard connectedOverUSB else { return }
        _ = send("C,REBOOT\n")
        follow = .idle
        lastAction = "Rebooting the robot for a fresh motion session."
    }

    /// Feeds the selected face to a running session. Only a face the selection
    /// logic has confirmed is sent; with none, the robot's own timeout returns
    /// the head to rest.
    /// `sequence` is the camera frame this face came from. The robot remembers
    /// when it sent each recent frame and applies the correction relative to
    /// where the head was pointing then, which is what stops it overshooting.
    func sendFollowTarget(_ box: FaceBox, sequence: UInt32) {
        guard case .following = follow else { return }
        guard sequence > targetSequence else { return }   // the robot ignores repeats anyway
        targetSequence = sequence
        _ = send(FollowTarget.line(for: box, sequence: sequence))
    }

    /// The robot's eyes look toward the selected face, and lock on with dilated
    /// pupils while the person faces it. Sent during sessions too, since the
    /// follow targets carry no engagement. Moves only pupils on the display.
    func sendGaze(_ box: FaceBox) {
        _ = send(Gaze.line(for: box, engaged: engaged))
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
        guard serialFD >= 0 || networkUp else {
            if network != nil {
                // A Wi-Fi attempt in flight reports its own outcome; cancelling it
                // every tick would mean it never completes. Only give up on one
                // that has gone silent.
                if Date().timeIntervalSince(networkStartedAt) > Self.wifiConnectTimeout {
                    networkStateChanged(false, "no answer from the robot")
                }
                return
            }
            if Date() >= nextReconnect {
                nextReconnect = Date().addingTimeInterval(2)
                connect()
            }
            return
        }
        if transport == .automatic && serialFD >= 0 {
            if probe == nil, Date() >= nextWiFiProbe {
                startWiFiProbe()
            } else if probe != nil, Date().timeIntervalSince(probeStartedAt) > Self.wifiConnectTimeout {
                endProbe()
            }
        }
        if pendingAuthorization != nil, Date().timeIntervalSince(authorizationSentAt) > 5 {
            pendingAuthorization = nil
            follow = .finished(FollowResult(code: "auth_no_reply"))
        }
        if case .following(let since) = follow, Date().timeIntervalSince(since) > Self.followResultTimeout {
            // Once may be a lost line and is retried; twice running is a fault,
            // said out loud, and the retrying stops.
            sessionsWithoutResult += 1
            let code = sessionsWithoutResult >= 2 ? "no_result_repeated" : "no_result"
            follow = .finished(FollowResult(code: code))
            lastFollowEnded = Date()
            lastAction = "Head following: \(FollowResult(code: code).summary)"
        }
        if firmware == .asking, Date().timeIntervalSince(versionAskedAt) > Self.versionRetryInterval {
            if versionAttempts < Self.versionMaxAttempts {
                versionAttempts += 1
                versionAskedAt = Date()
                _ = send("V\n")
            } else if usingNetwork {
                // Over Wi-Fi a connection nobody answers is not a link. The robot
                // serves one viewer and only accepts the next once it notices the
                // last has gone, so an app relaunched within a few seconds sits in
                // its listen queue, connected and unheard, forever. Reconnect.
                networkStateChanged(false, "connected, but the robot did not answer")
            } else {
                firmware = .silent
            }
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
        let frameSequence = frame.sequence
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
            request.revision = VNDetectFaceRectanglesRequestRevision3   // adds pitch to yaw and roll
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try? handler.perform([request])
            let degrees = { (value: NSNumber?) in value.map { $0.doubleValue * 180 / .pi } }
            let boxes = (request.results ?? []).filter { $0.confidence >= 0.7 }.map { face in
                FaceBox(rect: face.boundingBox, confidence: face.confidence,
                        pose: degrees(face.yaw).map { HeadPose(yaw: $0, pitch: degrees(face.pitch), roll: degrees(face.roll)) },
                        frameWidth: image.width)
            }
            DispatchQueue.main.async {
                self?.analyzing = false
                guard let self, self.generation == session,
                      ProcessInfo.processInfo.systemUptime - receivedAt < 0.75 else { return }
                // Detection always uses the frame as sent; only the displayed image
                // is enhanced. Boxes are normalized, so they fit an upscaled frame.
                self.faceSelection.update(boxes, at: receivedAt)
                self.publishFaces()
                let engagedNow = self.engagement.update(self.faceSelection.state == .tracking ? self.faceSelection.box : nil,
                                                        at: receivedAt)
                if engagedNow != self.engaged { self.engaged = engagedNow }
                var sent: FaceBox?
                if self.faceSelection.state == .tracking, let box = self.faceSelection.box {
                    self.sendFollowTarget(box, sequence: frameSequence)
                    self.sendGaze(box)
                    sent = box
                }
                if AutoFollow.shouldStart(enabled: self.followAutomatically, unavailableReason: self.followUnavailableReason,
                                          state: self.follow, faceTracked: self.faceSelection.state == .tracking,
                                          lastEnded: self.lastFollowEnded, now: Date(), wokeAt: self.wokeAt) {
                    // Just woken with nobody in view, this session is the robot
                    // looking around; the first face it then finds is a finding.
                    let lookingAround = self.wokeAt != nil && self.faceSelection.state != .tracking
                    self.wokeAt = nil
                    self.lookingAroundSince = lookingAround ? Date() : nil
                    self.startFollowing()
                }
                if let since = self.lookingAroundSince {
                    if self.faceSelection.state == .tracking {
                        self.foundSomeoneAt = Date()
                        self.lookingAroundSince = nil
                    } else if Date().timeIntervalSince(since) > 20 {
                        self.lookingAroundSince = nil   // the look around is long over
                    }
                }
                self.logFollowFrame(faces: boxes, sent: sent, receivedAt: receivedAt)
                self.display(image, receivedAt: receivedAt, session: session)
            }
        }
    }

    /// Enhances one frame for display. With smooth motion, shows the frame
    /// interpolated between the previous one and this one at once, then this
    /// one half a frame interval later, so the view updates twice per frame at
    /// the cost of that half interval of delay.
    private func display(_ image: CGImage, receivedAt: TimeInterval, session: UUID) {
        let settings = enhancement
        let interval = lastDisplayedAt.map { receivedAt - $0 }
        lastDisplayedAt = receivedAt
        // A new stream, a settings change or a stall: nothing before it is related.
        let discontinuity = enhancerSession != session || (interval ?? .infinity) > 1.0
        enhancerSession = session
        let enhancer = self.enhancer
        Task { @MainActor [weak self] in
            if discontinuity { await enhancer.reset() }
            let frames = await enhancer.process(image, settings: settings)
            guard let self, self.generation == session else { return }
            let token = UUID()
            self.displayToken = token
            if let middle = frames.interpolated, !discontinuity, let interval {
                self.cameraImage = NSImage(cgImage: middle, size: .zero)
                let delay = min(max(interval / 2, 0.03), 0.3)
                try? await Task.sleep(for: .seconds(delay))
                guard self.displayToken == token, self.generation == session else { return }
            }
            self.cameraImage = NSImage(cgImage: frames.current, size: .zero)
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
    /// Head orientation from Vision, when it reported one.
    var pose: HeadPose? = nil
    /// Width in pixels of the frame the face was found in, for its size in pixels.
    var frameWidth: Int? = nil
}

struct CameraFrame: Sendable {
    let sequence: UInt32
    let jpeg: Data
}

/// Frames and text lines decoded from one read.
struct DecodedChunk: Sendable {
    var frames: [CameraFrame] = []
    /// `SB__ {json}` lines, without the newline.
    var lines: [String] = []
    var isEmpty: Bool { frames.isEmpty && lines.isEmpty }
}

/// Splits the link into SBFR packets and `SB__ {json}` text lines.
///
/// Text is only ever looked for in bytes outside a packet: a complete packet is
/// skipped by its length, and an incomplete one stops decoding until the rest
/// arrives, so JPEG payload is never scanned for lines. The firmware writes
/// frames and replies from one task, which keeps lines between packets.
final class FrameDecoder {
    private let magic: [UInt8] = [0x53, 0x42, 0x46, 0x52] // SBFR
    private let headerLength = 13
    private let maximumJPEGBytes = 300_000
    /// Longer than any line the firmware prints; past this, "SB" is noise.
    private let maximumLineBytes = 512
    private var buffer = Data()

    func append(_ bytes: Data) -> DecodedChunk {
        buffer.append(bytes)
        var chunk = DecodedChunk()
        while buffer.count >= headerLength {
            // Data's integer indices need not begin at zero after removeFirst.
            // Normalize each small packet header before indexed inspection.
            let raw = Array(buffer)
            guard Array(raw.prefix(4)) == magic else {
                if raw[0] == 0x53, raw[1] == 0x42 { // "SB": possibly a text line
                    if let newline = raw.prefix(maximumLineBytes).firstIndex(of: 0x0a) {
                        // Serial.println() ends lines with \r\n. Without dropping
                        // the \r every such line failed isTextLine and vanished:
                        // SBTB, and refusals such as follow_requires_stream_on.
                        let end = newline > 0 && raw[newline - 1] == 0x0d ? newline - 1 : newline
                        if let line = String(bytes: raw[..<end], encoding: .utf8),
                           Self.isTextLine(line) {
                            chunk.lines.append(line)
                            buffer.removeFirst(newline + 1)
                            continue
                        }
                    } else if raw.count < maximumLineBytes {
                        break // the rest of the line has not arrived yet
                    }
                }
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
            chunk.frames.append(CameraFrame(sequence: sequence, jpeg: jpeg))
            buffer.removeFirst(headerLength + length)
        }
        return chunk
    }

    /// `SB` + two capitals + space + a JSON object, e.g. `SBVR {...}`.
    static func isTextLine(_ line: String) -> Bool {
        let bytes = Array(line.utf8)
        guard bytes.count >= 7, bytes[4] == 0x20, bytes[5] == 0x7b, bytes.last == 0x7d else { return false }
        return bytes[2...3].allSatisfy { (0x41...0x5a).contains($0) }
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}

enum Emotion: String, CaseIterable, Identifiable {
    case normal, angry, glee, happy, sad, worried, focused, annoyed, surprised
    case skeptic, frustrated, unimpressed, sleepy, suspicious, squint, furious, scared, awe
    /// Something went wrong: crossed-out eyes and a frown, after the Sad Mac.
    case trouble

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
        case .trouble: "xmark.circle"
        }
    }
}

struct ActivityEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
}

// MARK: - Preview scenarios

extension RobotConnection {
    /// STANBOT_PREVIEW=asleep|connecting|connected|seeing|shy|engaged|following|refused launches the app with
    /// made-up state and no link at all: no USB, no Wi-Fi, no camera, no
    /// motion. It exists to look at the interface without a robot.
    static func fromEnvironment() -> RobotConnection {
        guard let scenario = ProcessInfo.processInfo.environment["STANBOT_PREVIEW"] else { return RobotConnection() }
        let robot = RobotConnection(automaticPolling: false, transport: .usb, passphrase: { nil }, connectOnStart: false)
        robot.applyPreview(scenario)
        return robot
    }

    /// With STANBOT_SNAPSHOT=/path.png as well, the preview writes its own window
    /// to that file after it settles: a picture of the interface without screen
    /// recording permission. Preview only.
    private func scheduleSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["STANBOT_SNAPSHOT"] else { return }
        // STANBOT_WINDOW_SIZE=1400x900 forces the window's size first, so a
        // layout can be checked at sizes other than the default.
        if let size = ProcessInfo.processInfo.environment["STANBOT_WINDOW_SIZE"] {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
                    window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                }
            }
        }
        let delay = ProcessInfo.processInfo.environment["STANBOT_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // STANBOT_SNAPSHOT_WINDOW names another window to capture: a window
            // title, e.g. Diagnostics, or "sheet" for whatever sheet is open.
            let title = ProcessInfo.processInfo.environment["STANBOT_SNAPSHOT_WINDOW"] ?? "Stanbot"
            let named = NSApp.windows.first {
                guard $0.isVisible else { return false }
                return title == "sheet" ? $0.sheetParent != nil : $0.title == title
            }
            // The main window's title is a space (the name is in the titlebar
            // accessory), so fall back to the frontmost ordinary window.
            guard let window = named ?? NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }),
                  let frame = window.contentView?.superview else { return }
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // A snapshot run exists only to take the picture: leave nothing on screen.
            NSApp.terminate(nil)
        }
    }

    private func applyPreview(_ scenario: String) {
        scheduleSnapshot()
        // STANBOT_PREVIEW=sleeping is "seeing", then asleep after a second, so a
        // snapshot at a chosen delay catches the eyelids part way (docs/app-design.md).
        if scenario == "sleeping" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.asleep = true }
            applyPreview("seeing")
            return
        }
        // STANBOT_PREVIEW=waking starts asleep with a picture held, and wakes
        // after a second: the eyes-opening sequence, photographed at any delay.
        if scenario == "waking" {
            applyPreview("seeing")
            asleep = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.asleep = false }
            return
        }
        // followAutomatically is left alone: it persists, and with no link it does nothing.
        guard scenario != "asleep" else { lastAction = "Waiting to connect"; return }
        guard scenario != "connecting" else {
            connection = .connecting
            lastAction = "Looking for stanbot.local on the network."
            return
        }
        connection = .connected("stanbot.local")
        firmware = .reported(FirmwareInfo.parse(#"SBVR {"sketch":"camera_stream","commit":"7cd510631e1d","dirty":false,"built":"2026-09-17T01:00:32Z","protocol":1,"follow_limits_measured":true,"follow_pitch":true,"follow_yaw_range":48}"#)!)
        lastAction = "Connected to stanbot.local over Wi-Fi."
        guard scenario != "connected" else { return }
        cameraState = .receiving
        cameraImage = Self.previewImage()
        faceSelection = FaceSelection()
        let face = FaceBox(rect: CGRect(x: 0.42, y: 0.40, width: 0.22, height: 0.30), confidence: 0.94,
                           pose: HeadPose(yaw: 8, pitch: 4, roll: 0), frameWidth: 640)
        faceBoxes = [face]
        faceState = .tracking
        engaged = scenario == "engaged" || scenario == "following"
        if scenario == "shy" {
            faceBoxes = [FaceBox(rect: face.rect, confidence: 0.94, pose: HeadPose(yaw: 55, pitch: 4, roll: 0), frameWidth: 640)]
        }
        lastAction = "Receiving local camera frames from StackChan."
        switch scenario {
        case "following":
            follow = .following(since: Date().addingTimeInterval(-42))
            lastAction = "Head following started. Stay at the robot."
        case "refused":
            follow = .finished(FollowResult(code: "preflight_refused"))
            lastAction = "Head following: \(FollowResult(code: "preflight_refused").summary)"
        default: break
        }
    }

    private static func previewImage() -> NSImage {
        let size = NSSize(width: 640, height: 480)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: NSColor(calibratedRed: 0.32, green: 0.30, blue: 0.27, alpha: 1),
                   ending: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 270, y: 190, width: 140, height: 150)).fill()
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 200, y: -40, width: 280, height: 220), xRadius: 90, yRadius: 90).fill()
        image.unlockFocus()
        return image
    }
}
