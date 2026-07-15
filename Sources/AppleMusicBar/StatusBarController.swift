import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject {
    private enum UnavailableState {
        case notRunning
        case noTrack
        case unauthorized
        case failed(String)
    }

    private let maximumWidth: CGFloat = 360
    private let horizontalPadding: CGFloat = 18
    private let marqueeInterval: TimeInterval = 0.16

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let musicClient = MusicAppClient()
    private let lyricsRepository = LyricsRepository()
    private let nowPlayingView = NowPlayingMenuView()

    private let refreshItem = NSMenuItem(title: "", action: #selector(refreshLyrics), keyEquivalent: "r")
    private let languageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openMusicItem = NSMenuItem(title: "", action: #selector(openMusic), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
    private var languageMenuItems: [AppLanguage: NSMenuItem] = [:]

    private var language = AppLanguage.load()
    private var unavailableState: UnavailableState = .noTrack
    private var pollingTimer: Timer?
    private var marqueeTimer: Timer?
    private var isPolling = false
    private var currentTrack: TrackSnapshot?
    private var currentTimeline: LyricsTimeline?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?

    private var rawDisplayText = ""
    private var marqueeCharacters: [Character] = []
    private var marqueeIndex = 0

    func start() {
        configureStatusItem()
        configureMenu()
        refreshLocalizedPresentation()

        pollingTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(pollMusic),
            userInfo: nil,
            repeats: true
        )
        marqueeTimer = Timer.scheduledTimer(
            timeInterval: marqueeInterval,
            target: self,
            selector: #selector(advanceMarquee),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(pollingTimer!, forMode: .common)
        RunLoop.main.add(marqueeTimer!, forMode: .common)
        pollMusic()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.alignment = .center
        button.lineBreakMode = .byClipping
        button.toolTip = "Apple Music Bar"
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        nowPlayingView.onPlayPause = { [weak self] in self?.send(.playPause) }
        nowPlayingView.onNext = { [weak self] in self?.send(.nextTrack) }
        let nowPlayingItem = NSMenuItem()
        nowPlayingItem.view = nowPlayingView
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())

        refreshItem.target = self
        menu.addItem(refreshItem)

        let languageMenu = NSMenu()
        for option in AppLanguage.allCases {
            let item = NSMenuItem(
                title: option.menuTitle,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            languageMenu.addItem(item)
            languageMenuItems[option] = item
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        openMusicItem.target = self
        menu.addItem(openMusicItem)

        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateLocalizedMenu()
    }

    private func updateLocalizedMenu() {
        refreshItem.title = language.localized(.refreshLyrics)
        languageItem.title = language.localized(.language)
        openMusicItem.title = language.localized(.openAppleMusic)
        quitItem.title = language.localized(.quit)
        for option in AppLanguage.allCases {
            languageMenuItems[option]?.title = option == .system
                ? language.localized(.followSystem)
                : option.menuTitle
            languageMenuItems[option]?.state = option == language ? .on : .off
        }
        nowPlayingView.updateAccessibility(
            play: language.localized(.play),
            pause: language.localized(.pause),
            next: language.localized(.next)
        )
        statusItem.button?.setAccessibilityLabel(language.localized(.accessibilityLyrics))
    }

    @objc private func pollMusic() {
        guard !isPolling else { return }
        isPolling = true

        Task {
            let result = await musicClient.nowPlaying()
            isPolling = false
            handle(result)
        }
    }

    private func handle(_ result: MusicReadResult) {
        switch result {
        case .notRunning:
            clearTrackState()
            unavailableState = .notRunning
            refreshLocalizedPresentation()

        case .noTrack:
            clearTrackState()
            unavailableState = .noTrack
            refreshLocalizedPresentation()

        case .unauthorized:
            clearTrackState()
            unavailableState = .unauthorized
            refreshLocalizedPresentation()

        case .failed(let message):
            clearTrackState()
            unavailableState = .failed(message)
            refreshLocalizedPresentation()

        case .track(let track):
            let didChangeTrack = currentTrack?.key != track.key
            currentTrack = track
            updateNowPlayingCard(for: track)

            if didChangeTrack {
                currentTimeline = nil
                nowPlayingView.setArtwork(nil)
                beginArtworkLookup(for: track)
                beginLyricsLookup(for: track)
            }
            refreshCurrentDisplayText()
        }
    }

    private func updateNowPlayingCard(for track: TrackSnapshot) {
        let subtitleParts = [track.artist, track.album].filter { !$0.isEmpty }
        nowPlayingView.update(
            title: language.displayText(track.title),
            subtitle: language.displayText(subtitleParts.joined(separator: " — ")),
            isPlaying: track.state == .playing,
            controlsEnabled: true
        )
    }

    private func beginArtworkLookup(for track: TrackSnapshot) {
        artworkTask?.cancel()
        let key = track.key
        artworkTask = Task {
            let data = await musicClient.currentArtworkData()
            guard !Task.isCancelled, currentTrack?.key == key else { return }
            nowPlayingView.setArtwork(data.flatMap(NSImage.init(data:)))
        }
    }

    private func beginLyricsLookup(for track: TrackSnapshot, invalidate: Bool = false) {
        lyricsTask?.cancel()
        let key = track.key
        lyricsTask = Task {
            if invalidate {
                await lyricsRepository.invalidate(key)
            }
            let timeline = await lyricsRepository.lyrics(for: track)
            guard !Task.isCancelled, currentTrack?.key == key else { return }
            currentTimeline = timeline
            refreshCurrentDisplayText()
        }
    }

    private func clearTrackState() {
        lyricsTask?.cancel()
        artworkTask?.cancel()
        lyricsTask = nil
        artworkTask = nil
        currentTrack = nil
        currentTimeline = nil
        nowPlayingView.setArtwork(nil)
    }

    private func refreshLocalizedPresentation() {
        updateLocalizedMenu()
        if let currentTrack {
            updateNowPlayingCard(for: currentTrack)
            refreshCurrentDisplayText()
            return
        }

        let title: String
        let subtitle: String
        let statusText: String
        switch unavailableState {
        case .notRunning:
            title = language.localized(.musicNotRunning)
            subtitle = language.localized(.musicNotRunningDetail)
            statusText = language.localized(.openAppleMusicPrompt)
        case .noTrack:
            title = language.localized(.noTrack)
            subtitle = language.localized(.noTrackDetail)
            statusText = "♪ \(language.localized(.appleMusic))"
        case .unauthorized:
            title = language.localized(.automationRequired)
            subtitle = language.localized(.automationDetail)
            statusText = language.localized(.allowMusic)
        case .failed(let message):
            title = language.localized(.unableToRead)
            subtitle = message
            statusText = language.localized(.unableToRead)
        }
        nowPlayingView.update(
            title: title,
            subtitle: subtitle,
            isPlaying: false,
            controlsEnabled: false
        )
        setDisplayText(statusText)
    }

    private func refreshCurrentDisplayText() {
        guard let currentTrack else { return }
        if let line = currentTimeline?.line(at: currentTrack.position) {
            setDisplayText(language.displayText(line.text))
        } else {
            setDisplayText(language.displayText(currentTrack.displayName))
        }
    }

    private func setDisplayText(_ text: String) {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? "♪ \(language.localized(.appleMusic))" : cleaned
        guard value != rawDisplayText else { return }

        rawDisplayText = value
        marqueeCharacters = Array(value + "      ·      ")
        marqueeIndex = 0
        renderCurrentText()
    }

    @objc private func advanceMarquee() {
        guard textWidth(rawDisplayText) + horizontalPadding > maximumWidth else { return }
        guard !marqueeCharacters.isEmpty else { return }
        marqueeIndex = (marqueeIndex + 1) % marqueeCharacters.count
        renderCurrentText()
    }

    private func renderCurrentText() {
        guard let button = statusItem.button else { return }
        let width = textWidth(rawDisplayText) + horizontalPadding

        if width <= maximumWidth {
            statusItem.length = max(72, width)
            button.title = rawDisplayText
        } else {
            statusItem.length = maximumWidth
            button.title = marqueeSlice()
        }
        button.setAccessibilityValue(rawDisplayText)
    }

    private func marqueeSlice() -> String {
        guard !marqueeCharacters.isEmpty else { return rawDisplayText }
        let availableWidth = maximumWidth - horizontalPadding
        var result = ""

        for offset in 0..<marqueeCharacters.count {
            let index = (marqueeIndex + offset) % marqueeCharacters.count
            let candidate = result + String(marqueeCharacters[index])
            if textWidth(candidate) > availableWidth { break }
            result = candidate
        }
        return result
    }

    private func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func send(_ command: MusicCommand) {
        Task {
            await musicClient.send(command)
            try? await Task.sleep(for: .milliseconds(150))
            pollMusic()
        }
    }

    @objc private func refreshLyrics() {
        guard let currentTrack else { return }
        currentTimeline = nil
        refreshCurrentDisplayText()
        beginLyricsLookup(for: currentTrack, invalidate: true)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let selectedLanguage = AppLanguage(rawValue: rawValue)
        else { return }
        language = selectedLanguage
        language.save()
        refreshLocalizedPresentation()
    }

    @objc private func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Music"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
