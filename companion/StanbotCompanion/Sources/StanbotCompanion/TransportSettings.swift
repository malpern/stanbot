import SwiftUI

/// How the app reaches the robot. Chosen in Settings, stored in UserDefaults
/// under `StanbotTransport`, so a launch argument also works for one run:
/// `open Stanbot.app --args -StanbotTransport usb`
enum TransportPreference: String, CaseIterable, Identifiable, Sendable {
    /// Wi-Fi first. USB when Wi-Fi is unavailable, and back to Wi-Fi when it returns.
    case automatic
    case wifi
    case usb

    static let defaultsKey = "StanbotTransport"

    /// `automatic` unless something else is stored. "wifi" is also what the
    /// older `-StanbotTransport wifi` launch argument wrote.
    static var stored: TransportPreference {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TransportPreference.init(rawValue:)) ?? .automatic
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Wi-Fi, falling back to USB"
        case .wifi: "Wi-Fi only"
        case .usb: "USB only"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Connects over Wi-Fi when the robot is on the network. If it is not, uses the USB cable in the side port, and switches back to Wi-Fi when the robot reappears."
        case .wifi:
            "Never opens the USB port, so the cable stays free for flashing and probe scripts."
        case .usb:
            "Never contacts the robot over the network. Use this for flashing, recovery, or a network you do not trust."
        }
    }
}

/// Settings (⌘,), in tabs: General, Connection, Video. Only preferences live
/// here; live status and logs are in the Diagnostics window.
struct TransportSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
            VideoSettings()
                .tabItem { Label("Video", systemImage: "video") }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var chime = FirmwareChime.stored

    var body: some View {
        Form {
            Section {
                Toggle("Follow when Stanbot opens", isOn: $robot.followAutomaticallyOnLaunch)
            } footer: {
                Text("Whether the Follow toggle starts on each time the app opens. Turning Follow off in the window lasts until the app is next opened.")
                    .settingsFootnote()
            }
            Section {
                Picker("Sound on firmware change", selection: $chime) {
                    ForEach(FirmwareChime.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: chime) { _, new in
                    new.store()
                    new.play()
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ConnectionSettings: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var passphraseStatus: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Connect over", value: robot.transport.title)
                LabeledContent("Now using", value: robot.linkSummary)
            } footer: {
                Text("\(robot.transport.detail) Change it in the controls panel.").settingsFootnote()
            }
            Section {
                Picker("USB device", selection: $robot.selectedPort) {
                    if robot.availablePorts.isEmpty {
                        Text("No compatible USB device").tag(Optional<String>.none)
                    } else {
                        ForEach(robot.availablePorts, id: \.self) { port in
                            Text(URL(fileURLWithPath: port).lastPathComponent).tag(Optional(port))
                        }
                    }
                }
                LabeledContent("Robot") {
                    HStack {
                        Button("Reconnect") { robot.connect() }
                        Button("Reboot") { robot.rebootRobot() }
                            .disabled(!(robot.connectedOverUSB || (robot.connectedOverWiFi && robot.passphraseAvailable)))
                    }
                }
            }
            Section {
                LabeledContent("Robot passphrase") {
                    HStack {
                        Text(passphraseStatus ?? (robot.passphraseAvailable ? "Available" : "Not available"))
                            .foregroundStyle(.secondary)
                        Button("Re-read") {
                            RobotPassphrase.forget()
                            robot.refreshPassphrase()
                            passphraseStatus = RobotPassphrase.status
                        }
                    }
                }
            } footer: {
                Text("Read from ~/dotfiles/secrets.env with sops and kept only in memory. Over Wi-Fi it lets head following start and the robot reboot: the passphrase stays on this Mac, and the robot checks a one-time challenge.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VideoSettings: View {
    @EnvironmentObject private var robot: RobotConnection
    @AppStorage("StanbotMirrorVideo") private var mirrorVideo = true

    var body: some View {
        Form {
            Section {
                Toggle("Mirror the video", isOn: $mirrorVideo)
            } footer: {
                Text("Like a selfie camera: when you move right, you move right on screen.").settingsFootnote()
            }
            Section {
                Toggle("Enhance color", isOn: $robot.enhancement.color)
                Group {
                    Toggle("Reduce noise", isOn: $robot.enhancement.denoise)
                    Toggle("Smooth motion", isOn: $robot.enhancement.smoothMotion)
                    Toggle("Upscale", isOn: $robot.enhancement.upscale)
                }
                .disabled(!VideoEnhancement.videoToolboxAvailable)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Color adds a little saturation and contrast. Noise reduction filters grain using the previous frame. Smooth motion adds a generated frame between each pair (about 0.1 s delay; fast movement can ghost). Upscale infers detail from 320×240 to 640×480.")
                    if !VideoEnhancement.videoToolboxAvailable {
                        Text("Noise reduction, smooth motion and upscaling need macOS 26 on Apple silicon.")
                            .foregroundStyle(.orange)
                    }
                    Text("Display only: face detection always uses the frames exactly as the robot sends them.")
                }
                .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    func settingsFootnote() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
