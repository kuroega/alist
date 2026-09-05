import XCTest
@testable import AListTV

final class SubtitleCueTests: XCTestCase {
    func testParsesMultilineSRT() throws {
        let cues = try SubtitleCueParser.parse(data: Data("\u{FEFF}1\r\n00:00:01,000 --> 00:00:03.500\r\nHello\r\nWorld\r\n".utf8), fileName: "sample.srt")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello\nWorld")
        XCTAssertEqual(SubtitleCueParser.activeCues(in: cues, at: 1).count, 1)
        XCTAssertTrue(SubtitleCueParser.activeCues(in: cues, at: 3.5).isEmpty)
    }

    func testParsesASSDialogueAndNormalizesOverrides() throws {
        let source = "[Events]\nDialogue: 0,0:00:01.00,0:00:03.50,Default,Name,0,0,0,,{\\i1}Hello,\\Nworld"
        let cues = try SubtitleCueParser.parse(data: Data(source.utf8), fileName: "sample.ass")
        XCTAssertEqual(cues.map(\.text), ["Hello,\nworld"])
    }
}
