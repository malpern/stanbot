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
        }
        .padding(20)
        .frame(width: 460)
    }
}
