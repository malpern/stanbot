import AppKit
import SwiftUI

/// One follow session, read back from its log in ~/Library/Logs/Stanbot.
struct FollowSessionSummary: Identifiable, Equatable {
    let url: URL
    let date: Date
    /// The robot's result code (SBMV), or nil if the log has none (the app quit
    /// or the link dropped before the robot reported).
    let result: String?
    let manualInputs: Int?
    let faceTargets: Int?

    var id: URL { url }

    /// The newest `limit` logs in `directory`, newest first.
    static func load(from directory: URL, limit: Int = 30) -> [FollowSessionSummary] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("follow-") && $0.pathExtension == "log" }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { url, date in parse(url: url, date: date, text: (try? String(contentsOf: url, encoding: .utf8)) ?? "") }
    }

    /// Reads the last `SBMV {...}` line: the session's result as the robot reported it.
    static func parse(url: URL, date: Date, text: String) -> FollowSessionSummary {
        let line = text.split(separator: "\n").last { $0.hasPrefix("SBMV ") }
        let object = line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(5).utf8)) as? [String: Any] }
        return FollowSessionSummary(url: url, date: date, result: object?["result"] as? String,
                                    manualInputs: object?["manual_inputs"] as? Int,
                                    faceTargets: object?["observations"] as? Int)
    }
}

/// Everything to read about Stanbot, kept out of the main window: live status,
/// recent follow sessions with their logs, and the activity log. Window menu,
/// ⌥⌘D.
struct DiagnosticsView: View {
    @EnvironmentObject private var robot: RobotConnection
    @State private var sessions: [FollowSessionSummary] = []

    var body: some View {
        HSplitView {
            Form {
                Section("Robot") {
                    LabeledContent("Link", value: robot.linkSummary)
                    LabeledContent("Firmware", value: firmwareValue)
                    ForEach(firmwareWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    LabeledContent("Passphrase", value: robot.passphraseAvailable ? "Available" : "Not available")
                }
                Section("Head") {
                    LabeledContent("Following", value: followValue)
                    LabeledContent("Moves", value: movesValue)
                    if case .finished(let result) = robot.follow {
                        LabeledContent("Last result", value: result.summary)
                    }
                    if let reason = robot.followUnavailableReason {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Seeing") {
                    LabeledContent("Camera", value: robot.cameraState.title)
                    LabeledContent("Face", value: robot.faceState.rawValue)
                    LabeledContent("Turned toward the camera", value: robot.faceBoxes.first.map(facingValue) ?? "No face")
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300, idealWidth: 340)

            Form {
                Section {
                    if sessions.isEmpty {
                        Text("Stanbot hasn’t followed anyone yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { session in
                        SessionRow(session: session)
                    }
                } header: {
                    HStack {
                        Text("Follow sessions")
                        Spacer()
                        Button("Open Folder") { NSWorkspace.shared.open(robot.followLogFolder) }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                Section {
                    if robot.activity.isEmpty {
                        Text("Nothing has happened yet.").foregroundStyle(.secondary)
                    }
                    ForEach(robot.activity.prefix(60)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.date, style: .time)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(entry.text).font(.callout).textSelection(.enabled)
                        }
                    }
                } header: {
                    HStack {
                        Text("Activity")
                        Spacer()
                        Button("Copy") {
                            let text = robot.activity.map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.text)" }
                                .joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(robot.activity.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 360, idealWidth: 460)
        }
        .frame(minWidth: 680, minHeight: 460)
        .task(id: robot.followLogURL) { await reloadSessions() }
        .task(id: followFinished) { await reloadSessions() }
    }

    private var followFinished: Bool {
        if case .finished = robot.follow { return true }
        return false
    }

    private func reloadSessions() async {
        let folder = robot.followLogFolder
        sessions = await Task.detached { FollowSessionSummary.load(from: folder) }.value
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

private struct SessionRow: View {
    let session: FollowSessionSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var detail: String {
        guard let result = session.result else { return "No result in the log" }
        var parts = [FollowResult(code: result).summary]
        if let targets = session.faceTargets, targets > 0 { parts.append("\(targets) face targets") }
        if let manual = session.manualInputs, manual > 0 { parts.append("\(manual) steering inputs") }
        return parts.joined(separator: " · ")
    }
}
