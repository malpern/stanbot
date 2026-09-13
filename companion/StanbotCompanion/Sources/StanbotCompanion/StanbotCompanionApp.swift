import SwiftUI

@main
struct StanbotCompanionApp: App {
    @StateObject private var robot = RobotConnection()

    var body: some Scene {
        WindowGroup("Stanbot") {
            CompanionView()
                .environmentObject(robot)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reconnect to StackChan") { robot.connect() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class RobotConnection: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connected(String)
        case unavailable

        var title: String {
            switch self {
            case .disconnected: "Not connected"
            case .connected: "USB control connected"
            case .unavailable: "StackChan not found"
            }
        }

        var tint: Color {
            switch self {
            case .connected: .green
            case .disconnected: .secondary
            case .unavailable: .orange
            }
        }
    }

    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var selectedEmotion = Emotion.normal
    @Published private(set) var lastAction = "Waiting to connect"
    @Published var selectedPort: String?

    init() {
        selectedPort = availablePorts.first
        connect()
    }

    var availablePorts: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.SLAB_USBtoUART") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    var portName: String {
        guard let selectedPort else { return "No USB device" }
        return URL(fileURLWithPath: selectedPort).lastPathComponent
    }

    func connect() {
        guard let selectedPort else {
            connection = .unavailable
            lastAction = "Connect StackChan by USB-C, then reconnect."
            return
        }
        guard FileHandle(forWritingAtPath: selectedPort) != nil else {
            connection = .unavailable
            lastAction = "Couldn’t open \(portName)."
            return
        }
        connection = .connected(selectedPort)
        lastAction = "Connected locally through \(portName). Motion remains locked."
    }

    func select(_ emotion: Emotion) {
        guard case let .connected(port) = connection else {
            lastAction = "Connect to StackChan before changing its expression."
            return
        }
        guard let handle = FileHandle(forWritingAtPath: port) else {
            connection = .unavailable
            lastAction = "The USB connection is no longer available."
            return
        }
        handle.write(Data("E,\(emotion.rawValue)\\n".utf8))
        selectedEmotion = emotion
        lastAction = "Expression set to \(emotion.title)."
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
            Button("Reconnect", systemImage: "arrow.clockwise") { robot.connect() }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                StatusCard(title: "Connection", value: connectionValue,
                           detail: robot.portName, symbol: "cable.connector")
                StatusCard(title: "Camera", value: "Standby",
                           detail: "Local capture is not enabled in this build", symbol: "camera")
            }
            GridRow {
                StatusCard(title: "Attention", value: "No live target",
                           detail: "Face detection is not running", symbol: "person.crop.circle")
                StatusCard(title: "Head movement", value: "Locked",
                           detail: "Calibration required before motion can be enabled", symbol: "lock.fill")
            }
        }
    }

    private var connectionValue: String {
        if case .connected = robot.connection { return "Connected" }
        return "Unavailable"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
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
