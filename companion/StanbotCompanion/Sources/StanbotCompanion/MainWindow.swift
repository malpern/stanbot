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

/// The main window: the robot's view fills it, nothing floats over it, and the
/// controls live in a hideable panel on the right (ControlsPanel). Status and
/// logs are in the Diagnostics window.
struct CompanionView: View {
    @EnvironmentObject private var robot: RobotConnection
    @Environment(SpeechMouth.self) private var speech
    @AppStorage("StanbotShowControls") private var showControls = true
    @Environment(\.openWindow) private var openWindow
    @State private var reaction: EyeReaction?
    @State private var facts: ReactionFacts?
    @State private var lastFaceAt = Date()
    @State private var heldArrows: Set<KeyEquivalent> = []

    private func mood(at now: Date) -> Mood {
        Mood.of(connection: robot.connection, camera: robot.cameraState, face: robot.faceState,
                box: robot.faceBoxes.first, follow: robot.follow, noFaceFor: now.timeIntervalSince(lastFaceAt),
                engaged: robot.engaged, sleeping: robot.asleep)
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
            // Nothing floats over the picture: follow controls live in the toolbar.
            LiveView(mood: mood, reaction: reaction)
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
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat, .up]) { press in
                guard robot.followUnavailableReason == nil else { return .ignored }
                if press.phase == .up {
                    heldArrows.remove(press.key)
                } else {
                    heldArrows.insert(press.key)
                }
                if heldArrows.isEmpty {
                    robot.endSteering()
                } else {
                    // Arrow keys steer at half deflection, for fine positioning.
                    let x = (heldArrows.contains(.rightArrow) ? 0.5 : 0) - (heldArrows.contains(.leftArrow) ? 0.5 : 0)
                    let y = (heldArrows.contains(.upArrow) ? 0.5 : 0) - (heldArrows.contains(.downArrow) ? 0.5 : 0)
                    robot.steer(x: x, y: y)
                }
                return .handled
            }
            // The stage is always black (a camera, or Stanbot asleep), so what
            // floats on it is always dark, whatever the system appearance.
            .environment(\.colorScheme, .dark)
            .navigationTitle("Stanbot")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            // Stanbot's face, left of its name. SwiftUI's .navigation toolbar
            // placement drew nothing in this window (2026-09-17), so it is an
            // AppKit titlebar accessory instead.
            .background(TitlebarFace(content: RobotFaceBadge(mood: mood(at: Date()))
                .environmentObject(robot)
                .environment(speech)))
            .inspector(isPresented: $showControls) {
                ControlsPanel(mood: mood(at: Date()), reaction: reaction)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .onAppear {
                // Preview snapshots of the Diagnostics window (docs/app-design.md).
                if ProcessInfo.processInfo.environment["STANBOT_SNAPSHOT_WINDOW"] == "Diagnostics" {
                    openWindow(id: "diagnostics")
                }
            }
            .confirmationDialog("Start head following?", isPresented: $robot.confirmingFollow) {
                Button("Start Following") { robot.startFollowing() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stanbot will turn toward the selected face while it keeps seeing one, for up to 3 minutes, within its calibration limits, and look around if it loses you. Stay at the robot and press Stop if anything looks wrong.")
            }
            .tint(.stanbot)
    }

    /// Nothing in ordinary use: the link and firmware are in Diagnostics, and the
    /// title bar already shows how Stanbot is connected. A standing refusal or
    /// failure is the exception, because it needs answering.
    private var subtitle: String {
        if case .finished(let result) = robot.follow, !result.retryable { return result.summary }
        switch robot.connection {
        case .connected: return ""
        default: return robot.connection.title
        }
    }

    /// Only what must stay one click away with the panel hidden: whether the
    /// robot is reachable, Follow/Stop, and the panel itself.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ReachabilityIndicator()
            SleepWakeButton()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showControls.toggle() } label: {
                Label("Controls", systemImage: "sidebar.right")
            }
            .help(showControls ? "Hide the controls" : "Show the controls")
        }
    }
}

// MARK: - Live view

private struct LiveView: View {
    @EnvironmentObject private var robot: RobotConnection
    @AppStorage("StanbotMirrorVideo") private var mirrorVideo = true
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
                        // Mirrored like a selfie camera, so moving right moves right
                        // on screen. Picture and face boxes flip together; detection
                        // and following use the unmirrored frame.
                        .scaleEffect(x: mirrorVideo ? -1 : 1, y: 1)
                        // Top of the window, not centred: the picture stays put
                        // as the window grows.
                        .position(x: proxy.size.width / 2, y: fitted.height / 2)
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
    @AppStorage("StanbotMirrorVideo") private var mirrorVideo = true
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
                    // The picture and boxes are mirrored; the words must not be.
                    .scaleEffect(x: mirrorVideo ? -1 : 1, y: 1)
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

// MARK: - Controls

/// One button that becomes Stop while following, so it stays under the
/// pointer. Safety stays plain: a literal label, red, always one click away.
struct FollowButton: View {
    @EnvironmentObject private var robot: RobotConnection
    /// Large and full width, for the controls panel.
    var prominent = false

    private var isFollowing: Bool {
        if case .following = robot.follow { return true }
        return false
    }

    var body: some View {
        Button(role: isFollowing ? .destructive : nil) {
            isFollowing ? robot.stopFollowing() : (robot.confirmingFollow = true)
        } label: {
            Label(isFollowing ? "Stop" : "Follow", systemImage: isFollowing ? "stop.fill" : "scope")
                .labelStyle(.titleAndIcon)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: prominent ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(prominent ? .large : .regular)
        .tint(isFollowing ? .red : .stanbot)
        .disabled(!isFollowing && robot.followUnavailableReason != nil)
        .help(isFollowing ? "Stop following and power the head off" : (robot.followUnavailableReason ?? "Turn toward the selected face"))
    }
}

/// Sleep darkens the robot's screen and stops its camera while it stays on
/// Wi-Fi; Wake brings it back. Following lives in the controls panel.
struct SleepWakeButton: View {
    @EnvironmentObject private var robot: RobotConnection
    /// Full width, for the controls panel.
    var prominent = false

    private var connected: Bool { robot.connectedOverUSB || robot.connectedOverWiFi }

    var body: some View {
        Button {
            robot.asleep ? robot.wake() : robot.sleep()
        } label: {
            Label(robot.asleep ? "Wake" : "Sleep", systemImage: robot.asleep ? "sun.max" : "moon.zzz")
                .labelStyle(.titleAndIcon)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: prominent ? .infinity : nil)
        }
        .disabled(!connected)
        .help(robot.asleep
              ? "Wake the robot: its screen and camera come back"
              : "Darken the robot's screen and stop its camera. It stays on Wi-Fi.")
    }
}

/// A small red dot, shown only when the robot has not been reachable for a few
/// seconds; hover for what is wrong. Nothing at all while things are fine, and
/// nothing during the brief connecting at launch or a switch between USB and
/// Wi-Fi.
private struct ReachabilityIndicator: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var showing = false

    private var reachable: Bool {
        if case .connected = robot.connection { return true }
        return false
    }

    var body: some View {
        Group {
            if showing {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .padding(6)
                    .contentShape(Rectangle())
                    .help("\(robot.connection.title). \(robot.lastAction)")
                    .accessibilityLabel("Robot not reachable")
                    .transition(.opacity)
            }
        }
        .task(id: reachable) {
            if reachable {
                withAnimation(.easeOut(duration: 0.2)) { showing = false }
                return
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showing = true }
        }
    }
}


// MARK: - Expressions

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
                                .fill(Color(white: 0.74))   // the irises' grey, as the robot draws them
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
