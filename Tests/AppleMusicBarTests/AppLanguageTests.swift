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
        XCTAssertEqual(AppLanguage.english.localized(.language), "Language")
        XCTAssertEqual(AppLanguage.traditionalChinese.localized(.language), "語言")
    }
}
