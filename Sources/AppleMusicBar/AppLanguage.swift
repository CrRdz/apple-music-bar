import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese
    case english
    case traditionalChinese

    private static let defaultsKey = "appLanguage"
    private static let traditionalToSimplified = StringTransform("Hant-Hans")
    private static let simplifiedToTraditional = StringTransform("Hans-Hant")

    static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        guard
            let rawValue = defaults.string(forKey: defaultsKey),
            let language = AppLanguage(rawValue: rawValue)
        else { return .system }
        return language
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        guard identifier.hasPrefix("zh") else { return .english }
        if identifier.contains("hant")
            || identifier.contains("-tw")
            || identifier.contains("-hk")
            || identifier.contains("-mo") {
            return .traditionalChinese
        }
        return .simplifiedChinese
    }

    var menuTitle: String {
        switch self {
        case .system: return localized(.followSystem)
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }

    func displayText(_ text: String) -> String {
        switch resolved {
        case .simplifiedChinese:
            return text.applyingTransform(Self.traditionalToSimplified, reverse: false) ?? text
        case .traditionalChinese:
            return text.applyingTransform(Self.simplifiedToTraditional, reverse: false) ?? text
        case .system, .english:
            return text
        }
    }

    func localized(_ key: AppStringKey) -> String {
        switch resolved {
        case .simplifiedChinese:
            return Self.simplifiedChineseStrings[key] ?? Self.englishStrings[key] ?? ""
        case .traditionalChinese:
            return Self.traditionalChineseStrings[key] ?? Self.englishStrings[key] ?? ""
        case .system, .english:
            return Self.englishStrings[key] ?? ""
        }
    }

    private static let simplifiedChineseStrings: [AppStringKey: String] = [
        .accessibilityLyrics: "Apple Music 当前歌词",
        .appleMusic: "Apple Music",
        .openAppleMusicPrompt: "♪ 打开 Apple Music",
        .musicNotRunning: "Apple Music 未运行",
        .musicNotRunningDetail: "打开 Apple Music 以显示歌词",
        .noTrack: "没有正在播放的歌曲",
        .noTrackDetail: "请在 Apple Music 中播放歌曲",
        .automationRequired: "需要“自动化”权限",
        .automationDetail: "请允许 Apple Music Bar 控制“音乐”",
        .allowMusic: "请允许控制“音乐”",
        .unableToRead: "无法读取 Apple Music",
        .play: "播放",
        .pause: "暂停",
        .next: "下一首",
        .refreshLyrics: "重新匹配歌词",
        .language: "语言",
        .followSystem: "跟随系统",
        .openAppleMusic: "打开 Apple Music",
        .quit: "退出 Apple Music Bar"
    ]

    private static let traditionalChineseStrings: [AppStringKey: String] = [
        .accessibilityLyrics: "Apple Music 目前歌詞",
        .appleMusic: "Apple Music",
        .openAppleMusicPrompt: "♪ 開啟 Apple Music",
        .musicNotRunning: "Apple Music 未執行",
        .musicNotRunningDetail: "開啟 Apple Music 以顯示歌詞",
        .noTrack: "沒有正在播放的歌曲",
        .noTrackDetail: "請在 Apple Music 中播放歌曲",
        .automationRequired: "需要「自動化」權限",
        .automationDetail: "請允許 Apple Music Bar 控制「音樂」",
        .allowMusic: "請允許控制「音樂」",
        .unableToRead: "無法讀取 Apple Music",
        .play: "播放",
        .pause: "暫停",
        .next: "下一首",
        .refreshLyrics: "重新配對歌詞",
        .language: "語言",
        .followSystem: "跟隨系統",
        .openAppleMusic: "開啟 Apple Music",
        .quit: "結束 Apple Music Bar"
    ]

    private static let englishStrings: [AppStringKey: String] = [
        .accessibilityLyrics: "Current Apple Music lyric",
        .appleMusic: "Apple Music",
        .openAppleMusicPrompt: "♪ Open Apple Music",
        .musicNotRunning: "Apple Music is not running",
        .musicNotRunningDetail: "Open Apple Music to show lyrics",
        .noTrack: "Nothing is playing",
        .noTrackDetail: "Play a song in Apple Music",
        .automationRequired: "Automation permission required",
        .automationDetail: "Allow Apple Music Bar to control Music",
        .allowMusic: "Allow access to Music",
        .unableToRead: "Unable to read Apple Music",
        .play: "Play",
        .pause: "Pause",
        .next: "Next",
        .refreshLyrics: "Rematch Lyrics",
        .language: "Language",
        .followSystem: "Follow System",
        .openAppleMusic: "Open Apple Music",
        .quit: "Quit Apple Music Bar"
    ]
}

enum AppStringKey: Hashable {
    case accessibilityLyrics
    case appleMusic
    case openAppleMusicPrompt
    case musicNotRunning
    case musicNotRunningDetail
    case noTrack
    case noTrackDetail
    case automationRequired
    case automationDetail
    case allowMusic
    case unableToRead
    case play
    case pause
    case next
    case refreshLyrics
    case language
    case followSystem
    case openAppleMusic
    case quit
}
