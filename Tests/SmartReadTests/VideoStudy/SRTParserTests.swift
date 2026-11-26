import Foundation
import XCTest
@testable import SmartRead

final class SRTParserTests: XCTestCase {
    func testParsesUTF8CRLFCommaMillisecondsMultilineAndMarkup() throws {
        let source = """
        1\r
        00:00:01,250 --> 00:00:03,500\r
        <i>What are you</i>\r
        up to?\r
        \r
        2\r
        00:00:04.5 --> 00:00:06.25\r
        Nothing &amp; everything.\r
        """

        let result = try SRTParser.parse(data: Data(source.utf8))

        XCTAssertEqual(result.skippedBlockCount, 0)
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].startMilliseconds, 1_250)
        XCTAssertEqual(result.cues[0].endMilliseconds, 3_500)
        XCTAssertEqual(result.cues[0].text, "What are you\nup to?")
        XCTAssertEqual(result.cues[1].startMilliseconds, 4_500)
        XCTAssertEqual(result.cues[1].endMilliseconds, 6_250)
        XCTAssertEqual(result.cues[1].text, "Nothing & everything.")
    }

    func testParsesUTF8BOMWithoutNumericIndexes() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(
            Data(
                """
                00:00:00,000 --> 00:00:01,000
                Hello.

                00:00:01,000 --> 00:00:02,000
                World.
                """.utf8
            )
        )

        let result = try SRTParser.parse(data: data)

        XCTAssertEqual(result.cues.map(\.text), ["Hello.", "World."])
    }

    func testParsesUTF16AndSkipsOnlyMalformedBlocks() throws {
        let source = """
        1
        00:00:00,000 --> 00:00:01,000
        第一条

        broken
        block

        3
        00:00:02,000 --> 00:00:03,000
        第三条
        """
        let data = try XCTUnwrap(source.data(using: .utf16))

        let result = try SRTParser.parse(data: data)

        XCTAssertEqual(result.cues.map(\.text), ["第一条", "第三条"])
        XCTAssertEqual(result.skippedBlockCount, 1)
    }

    func testParsesBOMlessUTF16LittleEndian() throws {
        let source = """
        1
        00:00:00,000 --> 00:00:01,000
        Hello.
        """
        let data = try XCTUnwrap(source.data(using: .utf16LittleEndian))

        let result = try SRTParser.parse(data: data)

        XCTAssertEqual(result.cues.first?.text, "Hello.")
    }

    func testRejectsUnsupportedEncoding() {
        XCTAssertThrowsError(try SRTParser.parse(data: Data([0x80, 0x81, 0x82]))) {
            XCTAssertEqual($0 as? SRTParserError, .unsupportedEncoding)
        }
    }

    func testRejectsFileWithNoValidCues() {
        XCTAssertThrowsError(try SRTParser.parse(data: Data("not srt".utf8))) {
            XCTAssertEqual($0 as? SRTParserError, .noValidCues)
        }
    }
}
