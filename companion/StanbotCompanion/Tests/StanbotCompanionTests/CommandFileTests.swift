import XCTest
@testable import StanbotCompanion

final class CommandFileTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testReadsAWellFormedRequest() throws {
        let dir = try directory()
        try #"{"id":"abc","command":"mouth","argument":"grille"}"#
            .write(to: CommandFile.requestURL(in: dir), atomically: true, encoding: .utf8)
        XCTAssertEqual(CommandFile.read(from: dir),
                       CommandFile.Request(id: "abc", command: "mouth", argument: "grille"))
    }

    /// The file is written by whatever is on the other end. The app has to
    /// survive anything it finds there, including nothing at all.
    func testRubbishIsIgnoredRatherThanFatal() throws {
        let dir = try directory()
        XCTAssertNil(CommandFile.read(from: dir), "no file at all")
        for bad in ["", "{", "[]", "{}", #"{"id":""}"#, #"{"command":"sleep"}"#, #"{"id":"a"}"#] {
            try bad.write(to: CommandFile.requestURL(in: dir), atomically: true, encoding: .utf8)
            XCTAssertNil(CommandFile.read(from: dir), "accepted: \(bad)")
        }
    }

    func testResultRoundTrips() throws {
        let dir = try directory()
        CommandFile.write(.init(id: "xyz", ok: false, detail: "no such command"), to: dir)
        let data = try Data(contentsOf: CommandFile.resultURL(in: dir))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "xyz")
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["detail"] as? String, "no such command")
        XCTAssertNotNil(object["completed"])
    }

    func testTheVocabularyIsCheckedBeforeAnythingIsSent() {
        XCTAssertNil(RobotCommand.parse("explode"))
        XCTAssertEqual(RobotCommand.parse("SLEEP"), .sleep)

        // Arguments: required where they mean something, refused where they do not.
        XCTAssertNil(RobotCommand.mouth.rejection(for: "grille"))
        XCTAssertNil(RobotCommand.mouth.rejection(for: "CAPSULE"))
        XCTAssertNotNil(RobotCommand.mouth.rejection(for: "trumpet"))
        XCTAssertNotNil(RobotCommand.mouth.rejection(for: nil))
        XCTAssertNil(RobotCommand.expression.rejection(for: "sad"))
        XCTAssertNotNil(RobotCommand.expression.rejection(for: "smug"))
        XCTAssertNil(RobotCommand.sleep.rejection(for: nil))
        XCTAssertNotNil(RobotCommand.sleep.rejection(for: "deeply"))
    }

    /// Turning the robot off cannot be undone from software -- only its own
    /// button brings it back -- so it is deliberately not in the vocabulary.
    func testOffIsNotAvailable() {
        XCTAssertNil(RobotCommand.parse("off"))
        XCTAssertFalse(RobotCommand.allCases.map(\.rawValue).contains("off"))
    }
}

/// The decoder now carries two kinds of picture. Keeping them apart matters:
/// a screenshot analysed as a camera frame would have the app looking for faces
/// in a picture of its own face.
final class ScreenshotDecodingTests: XCTestCase {
    private func packet(_ magic: [UInt8], _ payload: [UInt8], sequence: UInt32 = 1) -> Data {
        var bytes = magic + [1]
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((sequence >> UInt32(shift)) & 0xff)) }
        let length = UInt32(payload.count)
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((length >> UInt32(shift)) & 0xff)) }
        return Data(bytes + payload)
    }

    private let jpeg: [UInt8] = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]

    func testScreenshotsAreNotCameraFrames() {
        let decoder = FrameDecoder()
        let chunk = decoder.append(packet([0x53, 0x42, 0x53, 0x53], jpeg))
        XCTAssertEqual(chunk.screenshots.count, 1)
        XCTAssertTrue(chunk.frames.isEmpty, "a screenshot must not be analysed as a camera frame")
        XCTAssertEqual(Array(chunk.screenshots[0]), jpeg)
    }

    func testCameraFramesStillWork() {
        let decoder = FrameDecoder()
        let chunk = decoder.append(packet([0x53, 0x42, 0x46, 0x52], jpeg, sequence: 9))
        XCTAssertEqual(chunk.frames.count, 1)
        XCTAssertEqual(chunk.frames[0].sequence, 9)
        XCTAssertTrue(chunk.screenshots.isEmpty)
    }

    /// The two share the channel with text, and arrive interleaved and split.
    func testMixedTrafficArrivingInPieces() {
        let decoder = FrameDecoder()
        var stream = Data()
        stream.append(packet([0x53, 0x42, 0x46, 0x52], jpeg, sequence: 1))
        stream.append(#"SBVR {"sketch":"camera_stream"}"#.data(using: .utf8)!)
        stream.append(Data([0x0d, 0x0a]))
        stream.append(packet([0x53, 0x42, 0x53, 0x53], jpeg))

        var frames = 0, shots = 0, lines = 0
        for byte in stream {          // one byte at a time: the worst case
            let chunk = decoder.append(Data([byte]))
            frames += chunk.frames.count
            shots += chunk.screenshots.count
            lines += chunk.lines.count
        }
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(shots, 1)
        XCTAssertEqual(lines, 1)
    }
}
