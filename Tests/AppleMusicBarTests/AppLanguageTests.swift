import XCTest
@testable import AppleMusicBar

final class AppLanguageTests: XCTestCase {
    func testConvertsDisplayTextToSimplifiedChinese() {
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.displayText("無盡的思念"),
            "无尽的思念"
        )
    }

    func testConvertsDisplayTextToTraditionalChinese() {
        XCTAssertEqual(
            AppLanguage.traditionalChinese.displayText("无尽的思念"),
            "無盡的思念"
        )
    }

    func testEnglishPreservesSongAndLyricText() {
        XCTAssertEqual(
            AppLanguage.english.displayText("无尽的思念 Endless Missing"),
            "无尽的思念 Endless Missing"
        )
    }

    func testLocalizesMenuLabels() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized(.language), "语言")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized(.previous), "上一首")
        XCTAssertEqual(AppLanguage.english.localized(.language), "Language")
        XCTAssertEqual(AppLanguage.english.localized(.library), "Library")
        XCTAssertEqual(AppLanguage.english.localized(.choosePlaylist), "Choose a Playlist")
        XCTAssertEqual(AppLanguage.traditionalChinese.localized(.language), "語言")
        XCTAssertEqual(AppLanguage.traditionalChinese.localized(.refreshLyrics), "重新配對歌詞")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized(.loadingTracks), "正在读取歌曲…")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized(.playlistVisibility), "显示播放列表")
        XCTAssertEqual(AppLanguage.english.localized(.showTrackList), "Show Song List")
        XCTAssertEqual(AppLanguage.traditionalChinese.localized(.trackListHorizontal), "橫向封面")
        XCTAssertEqual(AppLanguage.english.localized(.trackListVertical), "Vertical List")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized(.showLyrics), "查看歌词")
        XCTAssertEqual(AppLanguage.english.localized(.lyricsUnavailable), "No lyrics available")
    }
}
