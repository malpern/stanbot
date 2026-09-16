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
        Settings {
            TransportSettingsView()
                .environmentObject(robot)
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
    @Published private(set) var lastAction = "Waiting to connect"
    @Published private(set) var cameraState: CameraState = .off
    @Published private(set) var cameraImage: NSImage?
    @Published private(set) var faceBoxes: [FaceBox] = []
    @Published private(set) var faceState: FaceSelection.State = .searching
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
    /// Start a session whenever a face is confirmed, without pressing Follow.
    @Published var followAutomatically: Bool = UserDefaults.standard.object(forKey: "StanbotFollowAutomatically") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followAutomatically, forKey: "StanbotFollowAutomatically") }
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
    /// The robot passphrase, for authorizing FOLLOW and REBOOT over Wi-Fi.
    private let passphrase: () -> String?
    /// A Wi-Fi command waiting on the robot's challenge or its verdict.
    private enum PendingAuthorization { case follow, reboot }
    private var pendingAuthorization: PendingAuthorization?
    private var authorizationSentAt = Date.distantPast
    @Published private(set) var passphraseAvailable = false
    private var followLogUntil = Date.distantPast
    /// Longer than the robot's 20 s session plus its telemetry, so a missing
    /// result is reported rather than leaving the Stop button up forever.
    private static let followResultTimeout: TimeInterval = 30
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
         passphrase: (() -> String?)? = nil) {
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
            lastAction = "Connected locally through \(portName). Motion remains locked."
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
            lastAction = "Connected to \(networkHost) over Wi-Fi. Motion remains locked."
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
        lastAction = "Wi-Fi is back; switched from USB to \(networkHost). Motion remains locked."
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
        if let info = FirmwareInfo.parse(line) {
            firmware = .reported(info)
            return
        }
        if line.hasPrefix("SBAC ") || line.hasPrefix("SBAU ") {
            handleAuthorization(line)
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
        follow = .finished(FollowResult(code: code))
        lastFollowEnded = Date()
        lastAction = "Head following: \(FollowResult(code: code).summary)"
        followLogUntil = Date().addingTimeInterval(5)   // the power summary follows the result
    }

    var connectedOverUSB: Bool { serialFD >= 0 && !usingNetwork }
    var connectedOverWiFi: Bool { usingNetwork && networkUp }

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
        targetSequence = 0
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
        let command = purpose == .follow ? "FOLLOW" : "REBOOT"
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
        case (_, false):
            follow = .finished(FollowResult(code: "auth_\(reason)"))
            lastAction = "The robot refused authorization: \(reason)."
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
        let detected = faces.map { String(format: "[%.3f,%.3f,%.3f,%.2f]", $0.rect.midX, $0.rect.midY, $0.rect.width, $0.confidence) }
        var fields = "\"t\":\(String(format: "%.3f", receivedAt)),\"faces\":\(faces.count),\"detections\":[\(detected.joined(separator: ","))],\"state\":\"\(faceSelection.state)\""
        if let sent {
            fields += ",\"sent\":\(targetSequence),\"x\":\(String(format: "%.3f", sent.rect.midX * 2 - 1))"
        }
        followLog.write(Data("APP {\(fields)}\n".utf8))
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
    func sendFollowTarget(_ box: FaceBox) {
        guard case .following = follow else { return }
        targetSequence &+= 1
        if targetSequence == 0 { targetSequence = 1 }
        _ = send(FollowTarget.line(for: box, sequence: targetSequence))
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
            follow = .finished(FollowResult(code: "no_result"))
        }
        if firmware == .asking, Date().timeIntervalSince(versionAskedAt) > Self.versionRetryInterval {
            if versionAttempts < Self.versionMaxAttempts {
                versionAttempts += 1
                versionAskedAt = Date()
                _ = send("V\n")
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
                // Detection always uses the frame as sent; only the displayed image
                // is enhanced. Boxes are normalized, so they fit an upscaled frame.
                self.faceSelection.update(boxes, at: receivedAt)
                self.publishFaces()
                var sent: FaceBox?
                if self.faceSelection.state == .tracking, let box = self.faceSelection.box {
                    self.sendFollowTarget(box)
                    sent = box
                }
                if AutoFollow.shouldStart(enabled: self.followAutomatically, unavailableReason: self.followUnavailableReason,
                                          state: self.follow, faceTracked: self.faceSelection.state == .tracking,
                                          lastEnded: self.lastFollowEnded, now: Date()) {
                    self.startFollowing()
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
                        if let line = String(bytes: raw[..<newline], encoding: .utf8),
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
                    HeadFollowingPanel()
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
                StatusCard(title: "Head movement", value: headMovementValue,
                           detail: headMovementDetail, symbol: headMovementEnabled ? "scope" : "lock.fill")
            }
            GridRow {
                StatusCard(title: "Firmware", value: firmwareValue, detail: firmwareDetail,
                           symbol: firmwareWarnings.isEmpty ? "cpu" : "exclamationmark.triangle.fill",
                           tint: firmwareWarnings.isEmpty ? nil : .orange)
                    .gridCellColumns(2)
            }
        }
    }

    private var headMovementEnabled: Bool {
        if case .reported(let info) = robot.firmware { return info.followLimitsMeasured }
        return false
    }

    private var headMovementValue: String {
        if case .following = robot.follow { return "Following" }
        return headMovementEnabled ? "Calibration build" : "Locked"
    }

    private var headMovementDetail: String {
        headMovementEnabled
            ? "Following can move the head, yaw only, within narrowed limits"
            : "Calibration required before motion can be enabled"
    }

    private var firmwareWarnings: [String] {
        switch robot.firmware {
        case .reported(let info): info.warnings
        case .silent: ["No reply to V; firmware predates the version command"]
        default: []
        }
    }

    private var firmwareValue: String {
        switch robot.firmware {
        case .unknown: "Not connected"
        case .asking: "Asking…"
        case .reported(let info): "\(info.sketch) · \(info.shortCommit)"
        case .silent: "Unidentified"
        }
    }

    private var firmwareDetail: String {
        guard case .reported(let info) = robot.firmware else {
            return firmwareWarnings.first ?? "Reported by the robot on each connect"
        }
        let built = "Built \(info.built), protocol \(info.protocolVersion)"
        return ([built] + firmwareWarnings).joined(separator: " · ")
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
                            .interpolation(.high)
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
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
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
