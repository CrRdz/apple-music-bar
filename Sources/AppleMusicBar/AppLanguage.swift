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
        .noTrack: "没有正在播放的歌曲",
        .automationRequired: "需要“自动化”权限",
        .allowMusic: "请允许控制“音乐”",
        .unableToRead: "无法读取 Apple Music",
        .readFailed: "读取失败",
        .previous: "上一首",
        .play: "播放",
        .pause: "暂停",
        .next: "下一首",
        .refreshLyrics: "重新匹配歌词",
        .library: "资料库",
        .playlists: "播放列表",
        .loadingLibrary: "正在读取资料库…",
        .emptyPlaylists: "资料库中没有播放列表",
        .noVisiblePlaylists: "没有启用显示的播放列表",
        .musicKitAccessRequired: "需要 Apple Music 资料库权限",
        .reloadLibrary: "重新载入资料库",
        .libraryUnavailable: "无法读取资料库",
        .choosePlaylist: "选择播放列表",
        .songs: "歌曲",
        .artist: "艺人",
        .loadingTracks: "正在读取歌曲…",
        .emptyTracks: "这个播放列表中没有歌曲",
        .searchSongs: "搜索歌曲、艺人或专辑",
        .noSearchResults: "未找到匹配的歌曲",
        .playlistSettings: "更多选项",
        .playPlaylist: "播放这个列表",
        .playlistVisibility: "显示播放列表",
        .showTrackList: "显示歌曲列表",
        .hideTrackList: "收起歌曲列表",
        .trackListOff: "关闭",
        .trackListVertical: "垂直列表",
        .trackListHorizontal: "横向封面",
        .showLyrics: "查看歌词",
        .hideLyrics: "关闭歌词",
        .loadingLyrics: "正在载入歌词…",
        .lyricsUnavailable: "暂时没有可用歌词",
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
        .noTrack: "沒有正在播放的歌曲",
        .automationRequired: "需要「自動化」權限",
        .allowMusic: "請允許控制「音樂」",
        .unableToRead: "無法讀取 Apple Music",
        .readFailed: "讀取失敗",
        .previous: "上一首",
        .play: "播放",
        .pause: "暫停",
        .next: "下一首",
        .refreshLyrics: "重新配對歌詞",
        .library: "資料庫",
        .playlists: "播放列表",
        .loadingLibrary: "正在讀取資料庫…",
        .emptyPlaylists: "資料庫中沒有播放列表",
        .noVisiblePlaylists: "沒有啟用顯示的播放列表",
        .musicKitAccessRequired: "需要 Apple Music 資料庫權限",
        .reloadLibrary: "重新載入資料庫",
        .libraryUnavailable: "無法讀取資料庫",
        .choosePlaylist: "選擇播放列表",
        .songs: "歌曲",
        .artist: "藝人",
        .loadingTracks: "正在讀取歌曲…",
        .emptyTracks: "這個播放列表中沒有歌曲",
        .searchSongs: "搜尋歌曲、藝人或專輯",
        .noSearchResults: "找不到相符的歌曲",
        .playlistSettings: "更多選項",
        .playPlaylist: "播放這個列表",
        .playlistVisibility: "顯示播放列表",
        .showTrackList: "顯示歌曲列表",
        .hideTrackList: "收起歌曲列表",
        .trackListOff: "關閉",
        .trackListVertical: "垂直列表",
        .trackListHorizontal: "橫向封面",
        .showLyrics: "查看歌詞",
        .hideLyrics: "關閉歌詞",
        .loadingLyrics: "正在載入歌詞…",
        .lyricsUnavailable: "暫時沒有可用歌詞",
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
        .noTrack: "Nothing is playing",
        .automationRequired: "Automation permission required",
        .allowMusic: "Allow access to Music",
        .unableToRead: "Unable to read Apple Music",
        .readFailed: "Read failed",
        .previous: "Previous",
        .play: "Play",
        .pause: "Pause",
        .next: "Next",
        .refreshLyrics: "Rematch Lyrics",
        .library: "Library",
        .playlists: "Playlists",
        .loadingLibrary: "Loading Library…",
        .emptyPlaylists: "No playlists in Library",
        .noVisiblePlaylists: "No playlists are enabled for display",
        .musicKitAccessRequired: "Apple Music Library access required",
        .reloadLibrary: "Reload Library",
        .libraryUnavailable: "Unable to load Library",
        .choosePlaylist: "Choose a Playlist",
        .songs: "Song",
        .artist: "Artist",
        .loadingTracks: "Loading songs…",
        .emptyTracks: "This playlist has no songs",
        .searchSongs: "Search songs, artists, or albums",
        .noSearchResults: "No matching songs",
        .playlistSettings: "More Options",
        .playPlaylist: "Play This Playlist",
        .playlistVisibility: "Visible Playlists",
        .showTrackList: "Show Song List",
        .hideTrackList: "Hide Song List",
        .trackListOff: "Off",
        .trackListVertical: "Vertical List",
        .trackListHorizontal: "Horizontal Covers",
        .showLyrics: "Show Lyrics",
        .hideLyrics: "Hide Lyrics",
        .loadingLyrics: "Loading lyrics…",
        .lyricsUnavailable: "No lyrics available",
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
    case noTrack
    case automationRequired
    case allowMusic
    case unableToRead
    case readFailed
    case previous
    case play
    case pause
    case next
    case refreshLyrics
    case library
    case playlists
    case loadingLibrary
    case emptyPlaylists
    case noVisiblePlaylists
    case musicKitAccessRequired
    case reloadLibrary
    case libraryUnavailable
    case choosePlaylist
    case songs
    case artist
    case loadingTracks
    case emptyTracks
    case searchSongs
    case noSearchResults
    case playlistSettings
    case playPlaylist
    case playlistVisibility
    case showTrackList
    case hideTrackList
    case trackListOff
    case trackListVertical
    case trackListHorizontal
    case showLyrics
    case hideLyrics
    case loadingLyrics
    case lyricsUnavailable
    case language
    case followSystem
    case openAppleMusic
    case quit
}
