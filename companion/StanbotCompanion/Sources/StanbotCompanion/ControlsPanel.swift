import SwiftUI

/// The right-hand panel: things to do with Stanbot, not things to read about it
/// (those are in the Diagnostics window, ⌥⌘D). Stanbot's face large at the top,
/// then head, voice, expression and camera controls. Hideable and remembered.
struct ControlsPanel: View {
    @EnvironmentObject private var robot: RobotConnection
    @Environment(SpeechMouth.self) private var speech
    @AppStorage("StanbotMirrorVideo") private var mirrorVideo = true
    let mood: Mood
    let reaction: EyeReaction?

    var body: some View {
        Form {
            Section {
                GeometryReader { proxy in
                    RobotFace(mood: mood, width: min(proxy.size.width, 300), reaction: reaction, detailed: true)
                        .frame(maxWidth: .infinity)
                }
                .aspectRatio(1 / RobotFace.aspect, contentMode: .fit)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)
                Text(mood.caption)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: mood.caption)
            }

            Section("Head") {
                FollowButton(prominent: true)
                    .frame(maxWidth: .infinity)
                Toggle("Follow automatically", isOn: $robot.followAutomatically)
                DirectionPad()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                Text(robot.followUnavailableReason ?? "Drag on the pad to point the head; following resumes a moment after you let go. Arrow keys steer too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Voice") {
                if speech.playing {
                    Button("Stop Mouth Test", systemImage: "stop.fill") { speech.stop() }
                } else {
                    Button("Play Mouth Test", systemImage: "waveform") { speech.playTest(robotHost: robot.mouthHost) }
                }
                if let error = speech.lastError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }

            Section("Expression") {
                ExpressionGrid()
            }

            Section("Camera") {
                Button(robot.cameraState == .off ? "Show Camera" : "Hide Camera",
                       systemImage: robot.cameraState == .off ? "video" : "video.slash") {
                    robot.cameraState == .off ? robot.startCamera() : robot.stopCamera()
                }
                Toggle("Mirror the video", isOn: $mirrorVideo)
            }
        }
        .formStyle(.grouped)
    }
}

/// The 18 expressions as small drawings of Stanbot's own eyes: pick the face,
/// not a word. The current one is outlined.
private struct ExpressionGrid: View {
    @EnvironmentObject private var robot: RobotConnection

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: -radius + 16)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
            Circle()
                .fill(robot.steering ? Color.stanbot : Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: 38, height: 38)
                .offset(x: knob?.x ?? 0, y: knob?.y ?? 0)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var dx = value.location.x - radius, dy = value.location.y - radius
                    let reach = radius - 19
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
