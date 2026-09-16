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

struct TransportSettingsView: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var passphraseStatus: String?

    var body: some View {
        Form {
            Picker("Connect to StackChan", selection: $robot.transport) {
                ForEach(TransportPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.radioGroup)

            Text(robot.transport.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Now using", value: robot.linkSummary)

            Divider().padding(.vertical, 6)

            Section {
                LabeledContent("Robot passphrase", value: robot.passphraseAvailable ? "Available" : "Not available")
                HStack {
                    Button("Re-read from Secrets") {
                        RobotPassphrase.forget()
                        robot.refreshPassphrase()
                        passphraseStatus = RobotPassphrase.status
                    }
                    if let passphraseStatus {
                        Text(passphraseStatus).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("Read from ~/dotfiles/secrets.env with sops when needed, and kept only in memory. It lets head following start and the robot reboot over Wi-Fi: the passphrase stays on this Mac, and the robot checks a one-time challenge.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Head following").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Toggle("Enhance color", isOn: $robot.enhancement.color)
                Text("Slightly more saturation and contrast. The camera renders flat and grey.")
                    .font(.callout).foregroundStyle(.secondary)
                Group {
                    Toggle("Reduce noise", isOn: $robot.enhancement.denoise)
                    Text("Filters grain using the previous frame.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Smooth motion", isOn: $robot.enhancement.smoothMotion)
                    Text("Adds a generated frame between each pair, doubling the displayed rate. Delays the picture by about a tenth of a second, and fast movement can ghost.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Upscale", isOn: $robot.enhancement.upscale)
                    Text("Machine-learning upscaling from 320×240 to 640×480. Sharper, but the added detail is inferred.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!VideoEnhancement.videoToolboxAvailable)
                if !VideoEnhancement.videoToolboxAvailable {
                    Text("Noise reduction, smooth motion and upscaling need macOS 26 on Apple silicon.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("Display only: face detection always uses the frames exactly as the robot sends them.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Video").font(.headline)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
