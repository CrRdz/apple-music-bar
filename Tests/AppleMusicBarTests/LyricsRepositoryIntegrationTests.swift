import XCTest
@testable import AppleMusicBar

final class LyricsRepositoryIntegrationTests: XCTestCase {
    func testFindsTraditionalLRCLIBEntryFromSimplifiedMetadata() async throws {
        guard ProcessInfo.processInfo.environment["APPLE_MUSIC_BAR_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("设置 APPLE_MUSIC_BAR_INTEGRATION_TESTS=1 后运行在线集成测试")
        }
        URLCache.shared.removeAllCachedResponses()

        let track = TrackSnapshot(
            title: "无尽的思念",
            artist: "林俊杰",
            album: "编号89757",
            duration: 226,
            position: 30,
            state: .playing,
            embeddedLyrics: ""
        )

        let timeline = await LyricsRepository().lyrics(for: track)

        XCTAssertEqual(timeline?.source, .lrclibSynced)
        XCTAssertFalse(timeline?.lines.isEmpty ?? true)
    }
}
