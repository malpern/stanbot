import SwiftUI

/// The right-hand panel: Stanbot itself, large, and little else. Clicking the
/// face puts the robot to sleep or wakes it; the gear opens everything else.
/// Things to read are in the Diagnostics window (⌥⌘D).
struct ControlsPanel: View {
    @EnvironmentObject private var robot: RobotConnection
    let mood: Mood
    let reaction: EyeReaction?
    /// STANBOT_SNAPSHOT_WINDOW=sheet opens it at launch, to photograph it.
    @State private var showingDetails = ProcessInfo.processInfo.environment["STANBOT_SNAPSHOT_WINDOW"] == "sheet"

    private var connected: Bool { robot.connectedOverUSB || robot.connectedOverWiFi }

    /// The video area's empty state already says this, in bigger type: one
    /// message, not two. Every other caption still shows here.
    private var repeatsPlaceholder: Bool {
        mood.caption == Mood.placeholderHeadline(connection: robot.connection, camera: robot.cameraState)
    }

    /// What is wrong, in words, beside the red dot in the title bar: the robot
    /// unreachable, or a refusal that will not clear by itself.
    private var alert: String? {
        if case .finished(let result) = robot.follow, !result.retryable { return result.summary }
        switch robot.connection {
        case .connected, .connecting: return nil
        case .disconnected, .unavailable: return "\(robot.connection.title). \(robot.lastAction)"
        }
    }

    var body: some View {
        ScrollView {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            Button { showingDetails = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.borderless)
            .padding(12)
            .help("Head, camera, expression and connection")
            .accessibilityLabel("Stanbot controls")
        }
        .sheet(isPresented: $showingDetails) { DetailsSheet() }
    }

    private var content: some View {
        VStack(spacing: 14) {
            if let alert {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // As wide as the panel allows, never wider than it looks good.
            GeometryReader { proxy in
                let width = min(max(proxy.size.width, 120), 260)
                RobotFace(mood: mood, width: width, reaction: reaction, detailed: true,
                          onTap: connected ? { robot.asleep ? robot.wake() : robot.sleep() } : nil)
                    .frame(maxWidth: .infinity)
                    .help(connected
                          ? (robot.asleep ? "Click to wake Stanbot" : "Click to put Stanbot to sleep")
                          : mood.caption)
            }
            .frame(height: min(max(0, 260 * RobotFace.aspect), 260 * RobotFace.aspect))
            .frame(maxWidth: .infinity)

            if !repeatsPlaceholder {
                Text(mood.caption)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: mood.caption)
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

/// Everything that is not the face: following, the camera, the expression and
/// how the app reaches the robot. App preferences stay in Settings (⌘,).
private struct DetailsSheet: View {
    @EnvironmentObject private var robot: RobotConnection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("StanbotMirrorVideo") private var mirrorVideo = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Head") {
                    HStack(spacing: 8) {
                        FollowButton(prominent: true)
                        SleepWakeButton(prominent: true)
                    }
                    Toggle("Follow automatically", isOn: $robot.followAutomatically)
                    VStack(spacing: 8) {
                        DirectionPad(diameter: 112)
                        Text(robot.followUnavailableReason ?? "Press and drag to point the head. Arrow keys steer too.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section("Camera") {
                    Toggle("Show the camera", isOn: Binding(
                        get: { robot.cameraState != .off },
                        set: { $0 ? robot.startCamera() : robot.stopCamera() }))
                    Toggle("Mirror the video", isOn: $mirrorVideo)
                }

                Section("Expression") {
                    ExpressionGrid()
                }

                Section("Connection") {
                    Picker("Connect over", selection: $robot.transport) {
                        ForEach(TransportPreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    LabeledContent("Now using", value: robot.linkSummary)
                    Button("Reconnect") { robot.connect() }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 420, height: 660)
    }
}

/// The 18 expressions as small drawings of Stanbot's own eyes: pick the face,
/// not a word. The current one is outlined.
private struct ExpressionGrid: View {
    @EnvironmentObject private var robot: RobotConnection

    var body: some View {
        // Nine across, two rows: all 18 faces without scrolling.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 9), spacing: 5) {
            ForEach(Emotion.allCases) { emotion in
                let selected = robot.selectedEmotion == emotion
                Button { robot.select(emotion) } label: {
                    Image(nsImage: ExpressionIcon.image(for: emotion))
                        .resizable()
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(selected ? Color.stanbot : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(emotion.title)
                .accessibilityLabel(emotion.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

/// A round pad for pointing the head: press anywhere on it and the head turns
/// that way, further from the centre turns faster. Starts a session if needed;
/// following resumes a moment after letting go.
struct DirectionPad: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var knob: CGPoint?
    var diameter: CGFloat = 132

    private var unavailable: Bool { robot.followUnavailableReason != nil }

    var body: some View {
        let radius = diameter / 2
        ZStack {
            Circle()
                .fill(.quaternary)
            Circle()
                .strokeBorder(.separator, lineWidth: 1)
            ForEach(0..<4, id: \.self) { index in
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: -radius + 14)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
            Circle()
                .fill(robot.steering ? Color.stanbot : Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: 34, height: 34)
                .offset(x: knob?.x ?? 0, y: knob?.y ?? 0)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var dx = value.location.x - radius, dy = value.location.y - radius
                    let reach = radius - 17
                    let length = (dx * dx + dy * dy).squareRoot()
                    if length > reach { dx *= reach / length; dy *= reach / length }
                    knob = CGPoint(x: dx, y: dy)
                    // Screen y grows downward; up on the pad tilts the head up.
                    robot.steer(x: dx / reach, y: -dy / reach)
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.25, bounce: 0)) { knob = nil }
                    robot.endSteering()
                }
        )
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .help(robot.followUnavailableReason ?? "Press and drag to point the head")
        .accessibilityLabel("Head direction pad")
    }
}
