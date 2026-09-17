import XCTest
@testable import StanbotCompanion

final class FirmwareVersionTests: XCTestCase {
    let clean = #"SBVR {"sketch":"camera_stream","commit":"3aaa2f9c1d2e","dirty":false,"built":"2026-09-16T18:20:00Z","protocol":1,"follow_limits_measured":false}"#

    func packet(sequence: UInt32 = 7, jpeg: [UInt8]) -> [UInt8] {
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) } }
        return Array("SBFR".utf8) + [1] + le(sequence) + le(UInt32(jpeg.count)) + jpeg
    }

    func testParsesCleanBuildWithNoWarnings() throws {
        let info = try XCTUnwrap(FirmwareInfo.parse(clean))
        XCTAssertEqual(info.sketch, "camera_stream")
        XCTAssertEqual(info.shortCommit, "3aaa2f9")
        XCTAssertEqual(info.dirty, false)
        XCTAssertEqual(info.protocolVersion, 1)
        XCTAssertTrue(info.warnings.isEmpty)
    }

    func testWarnsOnEveryUntrustworthyBuild() throws {
        let dirty = try XCTUnwrap(FirmwareInfo.parse(clean.replacingOccurrences(of: #""dirty":false"#, with: #""dirty":true"#)))
        XCTAssertEqual(dirty.warnings, ["Built from uncommitted changes"])

        let unknown = try XCTUnwrap(FirmwareInfo.parse(
            clean.replacingOccurrences(of: #""commit":"3aaa2f9c1d2e","dirty":false"#, with: #""commit":"unknown","dirty":null"#)))
        XCTAssertNil(unknown.dirty)
        XCTAssertEqual(unknown.shortCommit, "unknown")
        XCTAssertEqual(unknown.warnings, ["Not built with firmware/build.sh; commit unknown"])

        let calibration = try XCTUnwrap(FirmwareInfo.parse(
            clean.replacingOccurrences(of: #""follow_limits_measured":false"#, with: #""follow_limits_measured":true"#)))
        XCTAssertEqual(calibration.warnings.first, "Head-following limits are marked measured")

        XCTAssertFalse(try XCTUnwrap(FirmwareInfo.parse(clean)).followPitch)   // older firmware: yaw only
        let pitch = try XCTUnwrap(FirmwareInfo.parse(
            clean.replacingOccurrences(of: #""follow_limits_measured":false"#, with: #""follow_limits_measured":false,"follow_pitch":true"#)))
        XCTAssertTrue(pitch.followPitch)
        XCTAssertEqual(pitch.warnings, ["Head following tilts up and down (pitch build)"])

        let newer = try XCTUnwrap(FirmwareInfo.parse(clean.replacingOccurrences(of: #""protocol":1"#, with: #""protocol":2"#)))
        XCTAssertEqual(newer.warnings, ["Protocol 2; this app expects 1"])
    }

    func testRejectsOtherLinesAndMalformedJSON() {
        XCTAssertNil(FirmwareInfo.parse(#"SBST {"elapsed_ms":1}"#))
        XCTAssertNil(FirmwareInfo.parse("SBVR {not json}"))
        XCTAssertNil(FirmwareInfo.parse("SBVR"))
    }

    func testDecoderSeparatesLinesFromFrames() {
        let decoder = FrameDecoder()
        let jpeg: [UInt8] = [0xff, 0xd8, 0x0a, 0x53, 0x42, 0x0a, 0xff, 0xd9]
        let bytes = Array("SBST {\"a\":1}\n".utf8) + packet(jpeg: jpeg) + Array((clean + "\n").utf8)
        let chunk = decoder.append(Data(bytes))
        XCTAssertEqual(chunk.frames.count, 1)
        XCTAssertEqual(chunk.frames.first?.jpeg, Data(jpeg))
        XCTAssertEqual(chunk.lines, ["SBST {\"a\":1}", clean])
    }

    func testTextInsidePayloadIsNotALine() {
        let decoder = FrameDecoder()
        let fake = Array((clean + "\n").utf8)
        let jpeg: [UInt8] = [0xff, 0xd8] + fake + [0xff, 0xd9]
        let chunk = decoder.append(Data(packet(jpeg: jpeg)))
        XCTAssertEqual(chunk.frames.count, 1)
        XCTAssertTrue(chunk.lines.isEmpty)
    }

    func testLineSplitAcrossReads() {
        let decoder = FrameDecoder()
        let line = Array((clean + "\n").utf8)
        XCTAssertTrue(decoder.append(Data(line[0..<40])).isEmpty)
        XCTAssertEqual(decoder.append(Data(line[40...])).lines, [clean])
    }

    func testPacketSplitAcrossReadsIsNotScannedForText() {
        let decoder = FrameDecoder()
        let jpeg: [UInt8] = [0xff, 0xd8] + Array((clean + "\n").utf8) + [0xff, 0xd9]
        let bytes = packet(jpeg: jpeg)
        XCTAssertTrue(decoder.append(Data(bytes[0..<30])).isEmpty)
        let rest = decoder.append(Data(bytes[30...]))
        XCTAssertEqual(rest.frames.count, 1)
        XCTAssertTrue(rest.lines.isEmpty)
    }
}
