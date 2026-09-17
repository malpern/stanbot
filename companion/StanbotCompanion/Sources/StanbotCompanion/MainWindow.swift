import AppKit
import SwiftUI

extension Color {
    /// Stanbot's accent: the robot's eye colour, softened for the Mac.
    static let stanbot = Color(red: 0.13, green: 0.70, blue: 0.80)
}

extension View {
    /// Liquid Glass on macOS 26 and later, a material before that.
    @ViewBuilder
    func stanbotGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// The main window: the robot's view fills it, Stanbot's face and the follow
/// controls float over the bottom, details live in a hideable inspector.
struct CompanionView: View {
    @EnvironmentObject private var robot: RobotConnection
    @AppStorage("StanbotShowInspector") private var showInspector = true

    private var mood: Mood {
        Mood.of(connection: robot.connection, camera: robot.cameraState, face: robot.faceState,
                box: robot.faceBoxes.first, follow: robot.follow)
    }

    var body: some View {
        LiveView(mood: mood)
            .overlay(alignment: .bottom) {
                ControlBar(mood: mood)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
            // The stage is always black (a camera, or Stanbot asleep), so what
            // floats on it is always dark, whatever the system appearance.
            .environment(\.colorScheme, .dark)
            .navigationTitle("Stanbot")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .confirmationDialog("Start head following?", isPresented: $robot.confirmingFollow) {
                Button("Start Following") { robot.startFollowing() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stanbot will turn toward the selected face while it keeps seeing one, for up to 3 minutes, within its calibration limits, and look around if it loses you. Stay at the robot and press Stop if anything looks wrong.")
            }
            .tint(.stanbot)
    }

    private var subtitle: String {
        switch robot.connection {
        case .connected:
            if case .reported(let info) = robot.firmware { return "\(robot.linkSummary) · \(info.shortCommit)" }
            return robot.linkSummary
        default: return robot.connection.title
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                robot.cameraState == .off ? robot.startCamera() : robot.stopCamera()
            } label: {
                Label(robot.cameraState == .off ? "Show Camera" : "Hide Camera",
                      systemImage: robot.cameraState == .off ? "video" : "video.slash")
            }
            .help(robot.cameraState == .off ? "Show what Stanbot sees" : "Stop the camera stream")

            ExpressionMenu()

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
            .help("Connection")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide the inspector" : "Show the inspector")
        }
    }
}

// MARK: - Live view

private struct LiveView: View {
    @EnvironmentObject private var robot: RobotConnection
    let mood: Mood

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = robot.cameraImage, robot.cameraState == .receiving {
                GeometryReader { proxy in
                    let fitted = fit(image.size, in: proxy.size)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay { FaceOverlay(boxes: robot.faceBoxes) }
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
                .accessibilityLabel("What Stanbot sees")
            } else {
                EmptyState(mood: mood)
            }
        }
    }

    private func fit(_ image: CGSize, in space: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return space }
        let scale = min(space.width / image.width, space.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// No picture: Stanbot's face, large, saying why, with the one thing to do.
private struct EmptyState: View {
    @EnvironmentObject private var robot: RobotConnection
    let mood: Mood

    var body: some View {
        VStack(spacing: 18) {
            StanbotEyesView(emotion: mood.emotion, asleep: mood.asleep, attending: false, screen: false)
                .frame(width: 220, height: 165)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .foregroundStyle(.white)
            action
        }
        .padding(.bottom, 80)   // clear of the control bar
    }

    private var headline: String {
        switch robot.connection {
        case .disconnected, .unavailable: "Stanbot is asleep"
        case .connecting: "Waking up…"
        case .connected: robot.cameraState == .waiting ? "Opening my eyes…" : "My eyes are closed"
        }
    }

    private var detail: String {
        switch robot.connection {
        case .disconnected, .unavailable: "Connect StackChan with USB, or put it on this Wi-Fi network."
        case .connecting: "Looking for StackChan on the network."
        case .connected:
            robot.cameraState == .unavailable ? "The camera stream stopped. Try again." : "Show the camera to see what Stanbot sees."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch robot.connection {
        case .disconnected, .unavailable:
            Button("Reconnect") { robot.connect() }
                .buttonStyle(.borderedProminent)
        case .connected where robot.cameraState != .waiting:
            Button("Show Camera") { robot.startCamera() }
                .buttonStyle(.borderedProminent)
        default:
            ProgressView().controlSize(.small).tint(.white)
        }
    }
}

private struct FaceOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let boxes: [FaceBox]

    var body: some View {
        GeometryReader { proxy in
            ForEach(boxes) { face in
                let rect = face.rect
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.stanbot, lineWidth: 3)
                    .frame(width: rect.width * proxy.size.width, height: rect.height * proxy.size.height)
                    .overlay(alignment: .top) {
                        Text(label(for: face))
                            .font(.caption.weight(.semibold))
                            .fontDesign(.rounded)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(.black)
                            .background(Color.stanbot, in: Capsule())
                            .fixedSize()
                            .offset(y: -28)
                    }
                    .position(x: rect.midX * proxy.size.width, y: (1 - rect.midY) * proxy.size.height)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: rect)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boxes.isEmpty ? "No person detected" : "Person detected")
    }

    private func label(for face: FaceBox) -> String {
        switch Facing.classify(face) {
        case .toward: "Facing Stanbot"
        case .away: "Someone"
        case .unknown: "Someone"
        }
    }
}

// MARK: - Control bar

private struct ControlBar: View {
    @EnvironmentObject private var robot: RobotConnection
    let mood: Mood

    var body: some View {
        HStack(spacing: 14) {
            StanbotEyesView(emotion: mood.emotion, look: mood.look, asleep: mood.asleep, attending: mood.attending)
                .frame(width: 56, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(mood.caption)
                    .font(.headline)
                    .fontDesign(.rounded)
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.2), value: mood.caption)
                status
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if case .following(let since) = robot.follow {
                PoweredBadge(since: since)
            }
            followButton
            Toggle(isOn: $robot.followAutomatically) {
                Text("Automatic").foregroundStyle(.white)
            }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Start following whenever Stanbot sees someone")
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 680)
        .stanbotGlass(in: Capsule())
    }

    @ViewBuilder
    private var status: some View {
        switch robot.follow {
        case .finished(let result):
            Text(result.summary).font(.caption).foregroundStyle(result.retryable ? Color.white.opacity(0.7) : Color.orange)
        default:
            Text(robot.lastAction).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private var followButton: some View {
        if case .following = robot.follow {
            // Safety controls stay plain: a literal label, always one click away.
            Button(role: .destructive) { robot.stopFollowing() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(".", modifiers: .command)
        } else {
            Button { robot.confirmingFollow = true } label: {
                Label("Follow", systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)
            .disabled(robot.followUnavailableReason != nil)
            .help(robot.followUnavailableReason ?? "Turn toward the selected face")
        }
    }
}

/// Motor power is on: said plainly, in red, with how long.
private struct PoweredBadge: View {
    let since: Date

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("Head powered")
            Text(since, style: .timer).monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.red.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Expressions

struct ExpressionMenu: View {
    @EnvironmentObject private var robot: RobotConnection

    var body: some View {
        Menu {
            Picker("Expression", selection: Binding(get: { robot.selectedEmotion }, set: { robot.select($0) })) {
                ForEach(Emotion.allCases) { emotion in
                    Label(emotion.title, systemImage: emotion.symbol).tag(emotion)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Expression", systemImage: "face.smiling")
        }
        .help("Change Stanbot’s expression")
    }
}

// MARK: - Inspector

private struct InspectorView: View {
    @EnvironmentObject private var robot: RobotConnection

    var body: some View {
        Form {
            Section("Robot") {
                LabeledContent("Link", value: robot.linkSummary)
                LabeledContent("Firmware", value: firmwareValue)
                ForEach(firmwareWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Section("Head") {
                LabeledContent("Following", value: followValue)
                LabeledContent("Moves", value: movesValue)
                if let reason = robot.followUnavailableReason, robot.follow == .idle {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Seeing") {
                LabeledContent("Camera", value: robot.cameraState.title)
                LabeledContent("Face", value: robot.faceState.rawValue)
                if let face = robot.faceBoxes.first {
                    LabeledContent("Turned toward the camera", value: facingValue(face))
                }
            }
            Section("Session") {
                if case .finished(let result) = robot.follow {
                    Text(result.summary).font(.callout)
                }
                if let url = robot.followLogURL {
                    Button("Show Session Log") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else {
                    Text("No session yet").foregroundStyle(.secondary)
                }
            }
            Section("Activity") {
                ForEach(robot.activity.prefix(40)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text).font(.callout)
                        Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var firmwareValue: String {
        switch robot.firmware {
        case .unknown: "Not connected"
        case .asking: "Asking…"
        case .reported(let info): "\(info.shortCommit), protocol \(info.protocolVersion)"
        case .silent: "Unidentified"
        }
    }

    private var firmwareWarnings: [String] {
        switch robot.firmware {
        case .reported(let info): info.warnings
        case .silent: ["No reply to V; firmware predates the version command"]
        default: []
        }
    }

    private var followValue: String {
        switch robot.follow {
        case .idle: robot.followUnavailableReason == nil ? "Ready" : "Not available"
        case .following: "Following"
        case .finished: "Finished"
        }
    }

    private var movesValue: String {
        guard case .reported(let info) = robot.firmware, info.followLimitsMeasured else { return "Nothing (locked)" }
        let range = info.followYawRange.map { " ±\($0)" } ?? ""
        return info.followPitch ? "Turn\(range), tilt" : "Turn\(range)"
    }

    private func facingValue(_ face: FaceBox) -> String {
        switch Facing.classify(face) {
        case .toward: "Roughly"
        case .away: "No"
        case .unknown: "Can’t tell"
        }
    }
}
