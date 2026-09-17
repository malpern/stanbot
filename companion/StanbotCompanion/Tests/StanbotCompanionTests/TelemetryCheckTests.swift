import XCTest
@testable import StanbotCompanion

final class TelemetryCheckTests: XCTestCase {
    /// The vector shared with test_telemetry_check.cpp and zlib.crc32.
    let block = [#"SBMV {"result":"session_idle"}"#, #"SBFL {"renewals":3}"#]

    func run(_ lines: [String], end: String = #"SBTE {"telemetry":"end","lines":2,"crc32":"76f85edc"}"#) -> TelemetryCheck.Outcome? {
        var check = TelemetryCheck()
        XCTAssertNil(check.consume(#"SBTB {"telemetry":"begin","plan":"follow"}"#))
        for line in lines { XCTAssertNil(check.consume(line)) }
        return check.consume(end)
    }

    func testIntactBlockVerifies() {
        XCTAssertEqual(run(block), .verified(lines: 2))
        XCTAssertEqual(run(block.map { $0 + "\r" }), .verified(lines: 2), "a carriage return is not hashed")
    }

    func testSessionTwosLostByteIsCaught() {
        XCTAssertEqual(run([#"SBMV {"result":"session_idl"}"#, block[1]]), .corrupted(expectedLines: 2, receivedLines: 2))
    }

    func testMergedOrMissingLinesAreCaught() {
        XCTAssertEqual(run([block[0] + block[1]]), .corrupted(expectedLines: 2, receivedLines: 1))
        XCTAssertEqual(run([block[0]]), .corrupted(expectedLines: 2, receivedLines: 1))
    }

    /// A reply from another firmware task landing inside the block is not damage.
    func testUnrelatedRepliesInsideTheBlockAreNotCounted() {
        XCTAssertEqual(run([block[0], #"SBWF {"stored":"ssid","profile":0}"#, #"SBNR {"x":1}"#, block[1]]), .verified(lines: 2))
    }

    func testOlderFirmwareIsUncheckedNotCorrupt() {
        XCTAssertEqual(run(block, end: #"SBTE {"telemetry":"end"}"#), .unchecked)
    }

    func testLinesOutsideABlockAreIgnored() {
        var check = TelemetryCheck()
        XCTAssertNil(check.consume(#"SBVR {"sketch":"camera_stream"}"#))
        XCTAssertNil(check.consume(#"SBTE {"telemetry":"end","lines":0,"crc32":"00000000"}"#))
    }
}
