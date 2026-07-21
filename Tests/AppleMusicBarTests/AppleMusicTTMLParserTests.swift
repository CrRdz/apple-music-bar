import XCTest
@testable import AppleMusicBar

final class AppleMusicTTMLParserTests: XCTestCase {
    func testParsesLineAndWordTimedTTML() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body>
            <div>
              <p begin="00:00:12.500" end="00:00:15.000">
                <span begin="12.5s">Hello </span><span begin="13.1s">world</span>
              </p>
              <p begin="01:02.250" end="01:05.000">Second line</p>
            </div>
          </body>
        </tt>
        """

        let timeline = try XCTUnwrap(AppleMusicTTMLParser.parse(ttml, duration: 90))

        XCTAssertEqual(timeline.source, .appleMusicSynced)
        XCTAssertEqual(timeline.lines.count, 2)
        XCTAssertEqual(timeline.lines[0].time, 12.5, accuracy: 0.001)
        XCTAssertEqual(timeline.lines[0].text, "Hello world")
        XCTAssertEqual(timeline.lines[1].time, 62.25, accuracy: 0.001)
    }

    func testEstimatesUntimedTTML() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p>First</p><p>Second</p></div></body>
        </tt>
        """

        let timeline = try XCTUnwrap(AppleMusicTTMLParser.parse(ttml, duration: 20))

        XCTAssertEqual(timeline.source, .appleMusicEstimated)
        XCTAssertEqual(timeline.lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(timeline.lines.map(\.time), [0, 10])
    }

    func testParsesTTMLTimeExpressions() {
        XCTAssertEqual(AppleMusicTTMLParser.parseTime("01:02:03.500"), 3_723.5)
        XCTAssertEqual(AppleMusicTTMLParser.parseTime("62.25s"), 62.25)
        XCTAssertEqual(AppleMusicTTMLParser.parseTime("1250ms"), 1.25)
        XCTAssertNil(AppleMusicTTMLParser.parseTime("unknown"))
    }
}
