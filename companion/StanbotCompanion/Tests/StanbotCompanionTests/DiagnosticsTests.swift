import XCTest
@testable import StanbotCompanion

final class DiagnosticsTests: XCTestCase {
    func testSessionSummaryReadsTheRobotsResult() {
        let url = URL(fileURLWithPath: "/tmp/follow-20260917-071841.log")
        let log = """
        APP {"t":1.0,"faces":1}
        SBTB {"telemetry":"begin","plan":"follow"}
        SBMV {"result":"session_idle","plan":"follow","observations":28,"manual_inputs":44,"rejected":43}
        SBTE {"telemetry":"end","lines":230,"crc32":"e09dcc7f"}
        """
        let summary = FollowSessionSummary.parse(url: url, date: .distantPast, text: log)
        XCTAssertEqual(summary.result, "session_idle")
        XCTAssertEqual(summary.faceTargets, 28)
        XCTAssertEqual(summary.manualInputs, 44)

        let cut = FollowSessionSummary.parse(url: url, date: .distantPast, text: "APP {\"t\":1.0}\n")
        XCTAssertNil(cut.result, "a session that ended before the robot reported")
    }

    func testLoadListsNewestFollowLogsOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stanbot-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["follow-a.log", "follow-b.log", "voice-a.log", "follow-c.txt"].enumerated() {
            let url = folder.appendingPathComponent(name)
            try "SBMV {\"result\":\"session_idle\"}\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
                                                  ofItemAtPath: url.path)
        }
        let sessions = FollowSessionSummary.load(from: folder)
        XCTAssertEqual(sessions.map { $0.url.lastPathComponent }, ["follow-b.log", "follow-a.log"])
    }
}
