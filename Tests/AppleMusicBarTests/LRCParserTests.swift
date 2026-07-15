import XCTest
@testable import AppleMusicBar

final class LRCParserTests: XCTestCase {
    func testParsesAndSortsTimestamps() throws {
        let lyrics = """
        [00:12.50]第二句
        [00:01.25]第一句
        """

        let timeline = try XCTUnwrap(LRCParser.parse(lyrics, source: .lrclibSynced))

        XCTAssertEqual(timeline.lines.count, 2)
        XCTAssertEqual(timeline.lines[0], LyricLine(time: 1.25, text: "第一句"))
        XCTAssertEqual(timeline.lines[1], LyricLine(time: 12.5, text: "第二句"))
    }

    func testSupportsMultipleTimestampsAndOffset() throws {
        let lyrics = """
        [offset:500]
        [00:01.00][00:03.000]重复句
        """

        let timeline = try XCTUnwrap(LRCParser.parse(lyrics, source: .embeddedSynced))

        XCTAssertEqual(timeline.lines.map(\.time), [1.5, 3.5])
        XCTAssertEqual(timeline.lines.map(\.text), ["重复句", "重复句"])
    }

    func testFindsCurrentLine() throws {
        let lyrics = """
        [00:01.00]A
        [00:05.00]B
        [00:10.00]C
        """
        let timeline = try XCTUnwrap(LRCParser.parse(lyrics, source: .lrclibSynced))

        XCTAssertNil(timeline.line(at: 0))
        XCTAssertEqual(timeline.line(at: 7)?.text, "B")
        XCTAssertEqual(timeline.line(at: 10)?.text, "C")
    }

    func testEstimatesPlainLyricsAcrossTrackDuration() throws {
        let timeline = try XCTUnwrap(
            LRCParser.estimate(
                "第一句\n第二句\n第三句",
                duration: 90,
                source: .lrclibEstimated
            )
        )

        XCTAssertEqual(timeline.lines.map(\.time), [0, 30, 60])
        XCTAssertEqual(timeline.line(at: 45)?.text, "第二句")
    }
}
