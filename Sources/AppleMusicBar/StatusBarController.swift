import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject {
    private let maximumWidth: CGFloat = 360
    private let horizontalPadding: CGFloat = 18
    private let marqueeInterval: TimeInterval = 0.16

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let musicClient = MusicAppClient()
    private let lyricsRepository = LyricsRepository()

    private let trackMenuItem = NSMenuItem(title: "没有正在播放的歌曲", action: nil, keyEquivalent: "")
    private let sourceMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let playPauseMenuItem = NSMenuItem(title: "播放 / 暂停", action: #selector(playPause), keyEquivalent: "")

    private var pollingTimer: Timer?
    private var marqueeTimer: Timer?
    private var isPolling = false
    private var currentTrack: TrackSnapshot?
    private var currentTimeline: LyricsTimeline?
    private var lyricsTask: Task<Void, Never>?

    private var rawDisplayText = ""
    private var marqueeCharacters: [Character] = []
    private var marqueeIndex = 0

    func start() {
        configureStatusItem()
        configureMenu()
        setDisplayText("♪ Apple Music")

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
        button.setAccessibilityLabel("Apple Music 当前歌词")
    }

    private func configureMenu() {
        let menu = NSMenu()
        trackMenuItem.isEnabled = false
        sourceMenuItem.isEnabled = false
        sourceMenuItem.isHidden = true
        menu.addItem(trackMenuItem)
        menu.addItem(sourceMenuItem)
        menu.addItem(.separator())

        let previousItem = NSMenuItem(title: "上一首", action: #selector(previousTrack), keyEquivalent: "")
        previousItem.target = self
        menu.addItem(previousItem)

        playPauseMenuItem.target = self
        menu.addItem(playPauseMenuItem)

        let nextItem = NSMenuItem(title: "下一首", action: #selector(nextTrack), keyEquivalent: "")
        nextItem.target = self
        menu.addItem(nextItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "重新匹配歌词", action: #selector(refreshLyrics), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openMusicItem = NSMenuItem(title: "打开 Apple Music", action: #selector(openMusic), keyEquivalent: "")
        openMusicItem.target = self
        menu.addItem(openMusicItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Apple Music Bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
            trackMenuItem.title = "Apple Music 未运行"
            setDisplayText("♪ 打开 Apple Music")

        case .noTrack:
            clearTrackState()
            trackMenuItem.title = "没有正在播放的歌曲"
            setDisplayText("♪ Apple Music")

        case .unauthorized:
            clearTrackState()
            trackMenuItem.title = "需要“自动化”权限"
            setDisplayText("请允许控制“音乐”")

        case .failed(let message):
            clearTrackState()
            trackMenuItem.title = "读取失败：\(message)"
            setDisplayText("无法读取 Apple Music")

        case .track(let track):
            let didChangeTrack = currentTrack?.key != track.key
            currentTrack = track
            trackMenuItem.title = track.displayName
            playPauseMenuItem.title = track.state == .playing ? "暂停" : "播放"

            if didChangeTrack {
                currentTimeline = nil
                sourceMenuItem.isHidden = true
                beginLyricsLookup(for: track)
            }

            if let line = currentTimeline?.line(at: track.position) {
                setDisplayText(line.text)
            } else {
                setDisplayText(track.displayName)
            }
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
            if let timeline {
                sourceMenuItem.title = timeline.source.rawValue
                sourceMenuItem.isHidden = false
                if let position = currentTrack?.position,
                   let line = timeline.line(at: position) {
                    setDisplayText(line.text)
                }
            } else {
                sourceMenuItem.title = "没有匹配到歌词"
                sourceMenuItem.isHidden = false
            }
        }
    }

    private func clearTrackState() {
        lyricsTask?.cancel()
        lyricsTask = nil
        currentTrack = nil
        currentTimeline = nil
        sourceMenuItem.isHidden = true
        playPauseMenuItem.title = "播放 / 暂停"
    }

    private func setDisplayText(_ text: String) {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? "♪ Apple Music" : cleaned
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

    @objc private func previousTrack() {
        send(.previousTrack)
    }

    @objc private func playPause() {
        send(.playPause)
    }

    @objc private func nextTrack() {
        send(.nextTrack)
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
        sourceMenuItem.title = "正在重新匹配歌词…"
        sourceMenuItem.isHidden = false
        beginLyricsLookup(for: currentTrack, invalidate: true)
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
