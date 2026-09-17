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
    @State private var reaction: EyeReaction?
    @State private var facts: ReactionFacts?
    @State private var lastFaceAt = Date()

    private func mood(at now: Date) -> Mood {
        Mood.of(connection: robot.connection, camera: robot.cameraState, face: robot.faceState,
                box: robot.faceBoxes.first, follow: robot.follow, noFaceFor: now.timeIntervalSince(lastFaceAt),
                engaged: robot.engaged)
    }

    private var currentFacts: ReactionFacts {
        var code: String?
        if case .finished(let result) = robot.follow { code = result.code }
        var commit: String?
        if case .reported(let info) = robot.firmware { commit = info.commit }
        var connected = false
        if case .connected = robot.connection { connected = true }
        var following = false
        if case .following = robot.follow { following = true }
        return ReactionFacts(connected: connected, faceTracked: robot.faceState == .tracking,
                             following: following, finishedCode: code, firmwareCommit: commit)
    }

    var body: some View {
        // Re-evaluated every few seconds so Stanbot can get drowsy on its own.
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let mood = mood(at: timeline.date)
            LiveView(mood: mood, reaction: reaction)
                .overlay(alignment: .bottom) {
                    ControlBar(mood: mood, reaction: reaction)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
        }
            .onChange(of: currentFacts, initial: true) { _, new in
                if let old = facts, let kind = ReactionFacts.reaction(from: old, to: new) {
                    reaction = EyeReaction(kind: kind)
                }
                facts = new
            }
            .onChange(of: robot.faceState) { _, state in
                if state != .searching { lastFaceAt = Date() }
            }
            .onChange(of: robot.cameraState) { _, _ in lastFaceAt = Date() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mood: Mood
    let reaction: EyeReaction?

    private var showingVideo: Bool { robot.cameraImage != nil && robot.cameraState == .receiving }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = robot.cameraImage, showingVideo {
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
                // The picture clears in, like eyes focusing, rather than popping.
                .transition(reduceMotion ? .opacity : .modifier(active: Focusing(amount: 1), identity: Focusing(amount: 0)))
            } else {
                EmptyState(mood: mood, reaction: reaction)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.45), value: showingVideo)
    }

    private func fit(_ image: CGSize, in space: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return space }
        let scale = min(space.width / image.width, space.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// Blur, dim and a touch of scale that settle to nothing: the video focusing.
private struct Focusing: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: 14 * amount)
            .opacity(1 - 0.8 * amount)
            .scaleEffect(1 + 0.03 * amount)
    }
}

/// No picture: Stanbot's face, large, saying why, with the one thing to do.
private struct EmptyState: View {
    @EnvironmentObject private var robot: RobotConnection
    let mood: Mood
    let reaction: EyeReaction?

    var body: some View {
        VStack(spacing: 18) {
            StanbotEyesView(emotion: mood.emotion, asleep: mood.asleep, attending: false, screen: false,
                            scanning: mood.scanning, reaction: reaction, interactive: true, screenLook: true)
                .frame(width: 220, height: 165)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: headline)
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
            // No spinner: Stanbot's eyes scanning or squinting open are the loader.
            EmptyView()
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
                FaceBoxView(label: label(for: face))
                    .frame(width: rect.width * proxy.size.width, height: rect.height * proxy.size.height)
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

/// A newly selected face: the outline draws itself around it and the label
/// pops up from its top edge. Its identity is the selection's, so it draws
/// once per person, not once per frame.
private struct FaceBoxView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    @State private var drawn = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(Color.stanbot, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .overlay(alignment: .top) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .fontDesign(.rounded)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.black)
                    .background(Color.stanbot, in: Capsule())
                    .fixedSize()
                    .contentTransition(.opacity)
                    .scaleEffect(drawn ? 1 : 0.6, anchor: .bottom)
                    .opacity(drawn ? 1 : 0)
                    .offset(y: -28)
            }
            .onAppear {
                if reduceMotion { drawn = true }
                else { withAnimation(.spring(duration: 0.45, bounce: 0.15)) { drawn = true } }
            }
    }
}

// MARK: - Control bar

private struct ControlBar: View {
    @EnvironmentObject private var robot: RobotConnection
    let mood: Mood
    let reaction: EyeReaction?

    var body: some View {
        HStack(spacing: 14) {
            StanbotEyesView(emotion: mood.emotion, look: mood.look, asleep: mood.asleep, attending: mood.attending,
                            scanning: mood.scanning, reaction: reaction, interactive: true, screenLook: true,
                            engaged: mood.engaged, closeness: mood.closeness)
                .frame(width: 56, height: 42)
                .help("Stanbot")
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
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
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
        .animation(.spring(duration: 0.35, bounce: 0), value: isFollowing)
    }

    private var isFollowing: Bool {
        if case .following = robot.follow { return true }
        return false
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

    /// One button that becomes Stop while following, so it stays under the
    /// pointer. Safety stays plain: a literal label, red, always one click away.
    private var followButton: some View {
        Button(role: isFollowing ? .destructive : nil) {
            isFollowing ? robot.stopFollowing() : (robot.confirmingFollow = true)
        } label: {
            Label(isFollowing ? "Stop" : "Follow", systemImage: isFollowing ? "stop.fill" : "scope")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .tint(isFollowing ? .red : .stanbot)
        .disabled(!isFollowing && robot.followUnavailableReason != nil)
        .help(isFollowing ? "Stop following and power the head off" : (robot.followUnavailableReason ?? "Turn toward the selected face"))
    }
}

/// Motor power is on: said plainly, in red, with how long.
private struct PoweredBadge: View {
    let since: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
                // One bounce when power comes on, then steady. A repeating pulse
                // cost ~9% CPU for as long as a session ran (measured 2026-09-16);
                // the red label and running timer already say it is live.
                .symbolEffect(.bounce, value: since)
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
                    Label { Text(emotion.title) } icon: { Image(nsImage: ExpressionIcon.image(for: emotion)) }
                        .tag(emotion)
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
                    Text("Stanbot hasn’t followed anyone yet.").foregroundStyle(.secondary)
                }
            }
            Section("Activity") {
                if robot.activity.isEmpty {
                    Text("Nothing has happened yet.").foregroundStyle(.secondary)
                }
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

/// Tiny drawings of Stanbot's own eyes for each expression, for menus: you pick
/// the face, not a word. Rendered once and cached.
@MainActor
enum ExpressionIcon {
    private static var cache: [Emotion: NSImage] = [:]

    static func image(for emotion: Emotion) -> NSImage {
        if let cached = cache[emotion] { return cached }
        let renderer = ImageRenderer(content: StaticEyes(pose: EyePose.of(emotion)).frame(width: 24, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: emotion.symbol, accessibilityDescription: nil) ?? NSImage()
        cache[emotion] = image
        return image
    }
}

/// The eyes without time: no blink, no drift, looking straight ahead. For icons.
private struct StaticEyes: View {
    let pose: EyePose

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 320, proxy.size.height / 240)
            ZStack {
                RoundedRectangle(cornerRadius: 40 * scale, style: .continuous).fill(.black)
                HStack(spacing: (218 - 102) * scale - pose.width * scale) {
                    ForEach(0..<2, id: \.self) { _ in
                        ZStack {
                            RoundedRectangle(cornerRadius: min(30, pose.height / 2) * scale, style: .continuous)
                                .fill(Color(red: 0, green: 1, blue: 1))
                                .frame(width: pose.width * scale, height: pose.height * scale)
                            Path { path in
                                guard abs(pose.tilt) > 0.1 else { return }
                                let w = pose.width * scale, h = pose.height * scale, t = pose.tilt * scale
                                path.move(to: .zero)
                                path.addLine(to: CGPoint(x: w, y: 0))
                                path.addLine(to: t > 0 ? CGPoint(x: w, y: t) : CGPoint(x: 0, y: -t))
                                path.closeSubpath()
                                _ = h
                            }
                            .fill(.black)
                            .frame(width: pose.width * scale, height: pose.height * scale)
                        }
                    }
                }
            }
        }
    }
}
