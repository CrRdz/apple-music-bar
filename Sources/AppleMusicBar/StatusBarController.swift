import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject {
    private enum UnavailableState: Equatable {
        case notRunning
        case noTrack
        case unauthorized
        case failed(String)
    }

    private enum LibraryState {
        case idle
        case loading
        case loaded
        case empty
        case permissionDenied
        case failed(String)
    }

    private let maximumWidth: CGFloat = 360
    private let horizontalPadding: CGFloat = 18
    private let marqueeInterval: TimeInterval = 0.20
    private let statusFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let playingFallbackPollInterval: TimeInterval = 15
    private let idleFallbackPollInterval: TimeInterval = 45
    private let playlistIdentityFailureTTL: TimeInterval = 15
    private let hiddenPlaylistIDsDefaultsKey = "hiddenPlaylistIDs"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let playerView = PlayerPopoverView()
    private lazy var playerMenu = NativePlayerMenu(
        contentView: playerView,
        contentSize: playerView.intrinsicContentSize
    )
    private let settingsMenu = NSMenu()
    private let musicClient = MusicAppClient()
    private let musicKitLibraryClient = MusicKitLibraryClient()
    private let lyricsRepository = LyricsRepository()

    private var language = AppLanguage.load()
    private var unavailableState: UnavailableState = .noTrack
    private var libraryState: LibraryState = .idle
    private var allPlaylists: [LibraryPlaylistSnapshot] = []
    private var playlists: [LibraryPlaylistSnapshot] = []
    private var selectedPlaylistIndex: Int?
    private var selectedPlaylistTracks: [LibraryTrackSnapshot] = []
    private var musicAppPlaylistIDs: [String: String] = [:]
    private var playlistIdentityTasks: [String: Task<String?, Never>] = [:]
    private var playlistIdentityFailures: [String: Date] = [:]
    private var hiddenPlaylistIDs = Set(
        UserDefaults.standard.stringArray(forKey: "hiddenPlaylistIDs") ?? []
    )
    private var trackListMode = TrackListDisplayMode.load()
    private var lastVisibleTrackListMode: TrackListDisplayMode = {
        let savedMode = TrackListDisplayMode.load()
        return savedMode == .off ? .vertical : savedMode
    }()
    private var hasUserSelectedPlaylist = false
    private var currentPlaylistName: String?
    private var libraryGeneration = 0
    private var playlistGeneration = 0
    private var pollingTimer: Timer?
    private var playbackUITimer: Timer?
    private var lyricTransitionTimer: Timer?
    private var marqueeTimer: Timer?
    private var isPolling = false
    private var shouldPollAgain = false
    private var isSessionActive = true
    private var currentTrack: TrackSnapshot?
    private var positionAnchorUptime = ProcessInfo.processInfo.systemUptime
    private var currentTimeline: LyricsTimeline?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var playlistNameTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var playlistContentTask: Task<Void, Never>?
    private var playlistArtworkTask: Task<Void, Never>?
    private var trackArtworkTask: Task<Void, Never>?
    private var shouldRestorePlaybackFocusAfterPlaylistLoad = false
    private var rawDisplayText = ""
    private var rawDisplayTextWidth: CGFloat = 0
    private var marqueeCharacters: [Character] = []
    private var marqueeSlices: [String] = []
    private var marqueeIndex = 0
    private var distributedNotificationObservers: [NSObjectProtocol] = []
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var isStopped = false

    func start() {
        guard !isStopped else { return }
        configureStatusItem()
        configurePanel()
        playerView.setTrackListMode(trackListMode)
        refreshLocalizedPresentation()
        loadMusicKitLibrary()
        observeMusicChanges()
        pollMusic()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

        pollingTimer?.invalidate()
        pollingTimer = nil
        playbackUITimer?.invalidate()
        playbackUITimer = nil
        lyricTransitionTimer?.invalidate()
        lyricTransitionTimer = nil
        marqueeTimer?.invalidate()
        marqueeTimer = nil

        lyricsTask?.cancel()
        artworkTask?.cancel()
        playlistNameTask?.cancel()
        libraryTask?.cancel()
        playlistContentTask?.cancel()
        playlistArtworkTask?.cancel()
        trackArtworkTask?.cancel()
        playlistIdentityTasks.values.forEach { $0.cancel() }
        playlistIdentityTasks = [:]

        let distributedCenter = DistributedNotificationCenter.default()
        distributedNotificationObservers.forEach { distributedCenter.removeObserver($0) }
        distributedNotificationObservers = []

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceNotificationObservers = []

        statusItem.button?.title = ""
        statusItem.length = NSStatusItem.variableLength
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.font = statusFont
        button.alignment = .center
        button.lineBreakMode = .byClipping
        button.toolTip = "Apple Music Bar"
    }

    private func configurePanel() {
        _ = playerMenu
        settingsMenu.autoenablesItems = false
        refreshSettingsMenu()
        playerMenu.configureSettingsItem(
            title: language.localized(.playlists),
            submenu: settingsMenu
        )
        playerMenu.onWillOpen = { [weak self] in
            guard let self else { return }
            self.refreshSettingsMenu(force: true)
            self.playerView.setSurfaceActive(true)
            self.refreshPlaybackPresentation()
            self.updatePlaybackUITimer()
            self.restorePlaybackContext()
            self.playerMenu.updateContentSize(self.playerView.intrinsicContentSize)
        }
        playerMenu.onDidClose = { [weak self] in
            guard let self else { return }
            self.playerView.setSurfaceActive(false)
            self.playbackUITimer?.invalidate()
            self.playbackUITimer = nil
            self.trackArtworkTask?.cancel()
            self.trackArtworkTask = nil
        }
        statusItem.menu = playerMenu.menu
        playerView.onTrackListToggle = { [weak self] in self?.toggleTrackList() }
        playerView.onPrevious = { [weak self] in self?.send(.previousTrack) }
        playerView.onPlayPause = { [weak self] in self?.send(.playPause) }
        playerView.onNext = { [weak self] in self?.send(.nextTrack) }
        playerView.onSeek = { [weak self] position in self?.seek(to: position) }
        playerView.onPlaylistFocused = { [weak self] index in
            self?.focusPlaylist(at: index, userInitiated: true)
        }
        playerView.onPlaylistActivated = { [weak self] index in
            self?.activatePlaylist(at: index)
        }
        playerView.onTrackSelected = { [weak self] track, index in
            self?.playTrack(track, fallbackIndex: index)
        }
        playerView.onVisibleTrackIDsChange = { [weak self] trackIDs in
            self?.beginVisibleTrackArtworkLookup(trackIDs)
        }
        playerView.onReloadLibrary = { [weak self] in self?.loadMusicKitLibrary() }
        playerView.onPreferredSizeChange = { [weak self] size in
            self?.playerMenu.updateContentSize(size)
        }
    }

    private func restorePlaybackContext() {
        hasUserSelectedPlaylist = false
        if let playlistIndex = indexOfPlaylist(named: currentPlaylistName) {
            if selectedPlaylistIndex == playlistIndex {
                playerView.focusPlaylist(at: playlistIndex)
            } else {
                shouldRestorePlaybackFocusAfterPlaylistLoad = true
                focusPlaylist(at: playlistIndex)
            }
        }
        playerView.restorePlaybackFocus()
    }

    @objc private func pollMusic() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        guard !isPolling else {
            shouldPollAgain = true
            return
        }
        isPolling = true

        Task { [weak self] in
            guard let self else { return }
            let result = await musicClient.nowPlaying()
            isPolling = false
            handle(result)
            if shouldPollAgain {
                shouldPollAgain = false
                schedulePoll(after: 0.1)
            } else {
                scheduleFallbackPoll()
            }
        }
    }

    private func observeMusicChanges() {
        let distributedCenter = DistributedNotificationCenter.default()
        for rawName in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            let observer = distributedCenter.addObserver(
                forName: Notification.Name(rawName),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.schedulePoll(after: 0.1) }
            }
            distributedNotificationObservers.append(observer)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    application.bundleIdentifier == "com.apple.Music"
                else { return }
                Task { @MainActor in self?.schedulePoll(after: 0.1) }
            }
            workspaceNotificationObservers.append(observer)
        }

        for name in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ] {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.suspendForInactiveSession() }
            }
            workspaceNotificationObservers.append(observer)
        }
        for name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.resumeForActiveSession() }
            }
            workspaceNotificationObservers.append(observer)
        }
    }

    private func schedulePoll(after delay: TimeInterval) {
        guard isSessionActive else { return }
        if isPolling {
            shouldPollAgain = true
            return
        }
        pollingTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.05, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMusic()
            }
        }
        timer.tolerance = min(1, max(0.02, delay * 0.1))
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    private func scheduleFallbackPoll() {
        let interval = currentTrack?.state == .playing
            ? playingFallbackPollInterval
            : idleFallbackPollInterval
        schedulePoll(after: interval)
    }

    private func suspendForInactiveSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        pollingTimer?.invalidate()
        pollingTimer = nil
        playbackUITimer?.invalidate()
        playbackUITimer = nil
        lyricTransitionTimer?.invalidate()
        lyricTransitionTimer = nil
        updateMarqueeTimer()
    }

    private func resumeForActiveSession() {
        guard !isSessionActive else { return }
        isSessionActive = true
        updateMarqueeTimer()
        scheduleNextLyricTransition()
        schedulePoll(after: 0.1)
    }

    private func handle(_ result: MusicReadResult) {
        switch result {
        case .notRunning:
            showUnavailableState(.notRunning)

        case .noTrack:
            showUnavailableState(.noTrack)

        case .unauthorized:
            showUnavailableState(.unauthorized)

        case .failed(let message):
            showUnavailableState(.failed(message))

        case .track(let track):
            let previousTrack = currentTrack
            let didChangeTrack = currentTrack?.key != track.key
            let didChangePlaybackState = previousTrack?.state != track.state
            currentTrack = track
            if previousTrack == nil {
                refreshSettingsMenu()
            }
            positionAnchorUptime = ProcessInfo.processInfo.systemUptime
            if didChangeTrack || didChangePlaybackState {
                playerView.setCurrentTrack(track)
                updateNowPlayingHeader(for: track)
            } else if playerMenu.isOpen {
                playerView.updatePlaybackPosition(track.position, duration: track.duration)
            }
            if playerMenu.isOpen {
                playerView.updateLyricsPosition(track.position)
            }

            if didChangeTrack {
                currentTimeline = nil
                playerView.setNowPlayingArtwork(nil)
                playerView.setLyricsLoading()
                beginArtworkLookup(for: track)
                beginLyricsLookup(for: track)
                beginCurrentPlaylistLookup(for: track)
            }
            refreshCurrentDisplayText()
            updatePlaybackUITimer()
            scheduleNextLyricTransition()
        }
    }

    private func showUnavailableState(_ state: UnavailableState) {
        let hadTrack = currentTrack != nil || currentPlaylistName != nil
        guard hadTrack || unavailableState != state else { return }
        clearTrackState()
        unavailableState = state
        refreshLocalizedPresentation()
    }

    private func updateNowPlayingHeader(for track: TrackSnapshot) {
        let position = playbackPosition(for: track)
        playerView.updateNowPlaying(
            title: language.displayText(track.title),
            subtitle: language.displayText(track.artist),
            isPlaying: track.state == .playing,
            controlsEnabled: true,
            position: position,
            duration: track.duration
        )
    }

    private func beginArtworkLookup(for track: TrackSnapshot) {
        artworkTask?.cancel()
        let key = track.key
        artworkTask = Task {
            let data = await musicClient.currentArtworkData()
            guard !Task.isCancelled, currentTrack?.key == key else { return }
            playerView.setNowPlayingArtwork(data.flatMap(NSImage.init(data:)))
        }
    }

    private func beginCurrentPlaylistLookup(for track: TrackSnapshot) {
        playlistNameTask?.cancel()
        let key = track.key
        playlistNameTask = Task {
            let name = await musicClient.currentPlaylistName()
            guard !Task.isCancelled, currentTrack?.key == key else { return }
            currentPlaylistName = name

            guard
                !hasUserSelectedPlaylist,
                case .loaded = libraryState,
                let index = indexOfPlaylist(named: name),
                selectedPlaylistIndex != index
            else { return }
            focusPlaylist(at: index)
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
            playerView.setLyricsTimeline(timeline)
            refreshCurrentDisplayText()
            scheduleNextLyricTransition()
        }
    }

    private func clearTrackState() {
        guard currentTrack != nil || currentPlaylistName != nil else { return }
        lyricsTask?.cancel()
        artworkTask?.cancel()
        playlistNameTask?.cancel()
        lyricsTask = nil
        artworkTask = nil
        playlistNameTask = nil
        currentTrack = nil
        currentTimeline = nil
        currentPlaylistName = nil
        playbackUITimer?.invalidate()
        playbackUITimer = nil
        lyricTransitionTimer?.invalidate()
        lyricTransitionTimer = nil
        playerView.setCurrentTrack(nil)
        playerView.setLyricsTimeline(nil)
        playerView.setNowPlayingArtwork(nil)
    }

    private func refreshLocalizedPresentation() {
        playerView.updateLocalization(language)
        playerMenu.updateSettingsTitle(language.localized(.playlists))
        playerView.updatePlaybackAccessibility(
            previous: language.localized(.previous),
            play: language.localized(.play),
            pause: language.localized(.pause),
            next: language.localized(.next),
            showLyrics: language.localized(.showLyrics),
            hideLyrics: language.localized(.hideLyrics),
            showTrackList: language.localized(.showTrackList),
            hideTrackList: language.localized(.hideTrackList)
        )
        statusItem.button?.setAccessibilityLabel(language.localized(.accessibilityLyrics))
        renderLibraryState()
        refreshSettingsMenu()

        if let currentTrack {
            updateNowPlayingHeader(for: currentTrack)
            refreshCurrentDisplayText()
            return
        }

        switch unavailableState {
        case .notRunning:
            playerView.updateNowPlaying(
                title: language.localized(.musicNotRunning),
                subtitle: language.localized(.appleMusic),
                isPlaying: false,
                controlsEnabled: false
            )
            setDisplayText(language.localized(.openAppleMusicPrompt))
        case .noTrack:
            playerView.updateNowPlaying(
                title: language.localized(.noTrack),
                subtitle: language.localized(.appleMusic),
                isPlaying: false,
                controlsEnabled: false
            )
            setDisplayText("♪ \(language.localized(.appleMusic))")
        case .unauthorized:
            playerView.updateNowPlaying(
                title: language.localized(.automationRequired),
                subtitle: language.localized(.appleMusic),
                isPlaying: false,
                controlsEnabled: false
            )
            setDisplayText(language.localized(.allowMusic))
        case .failed(let message):
            playerView.updateNowPlaying(
                title: language.localized(.readFailed),
                subtitle: message,
                isPlaying: false,
                controlsEnabled: false
            )
            setDisplayText(language.localized(.unableToRead))
        }
    }

    private func refreshCurrentDisplayText() {
        guard let currentTrack else { return }
        let position = playbackPosition(for: currentTrack)
        if let line = currentTimeline?.line(at: position) {
            setDisplayText(language.displayText(line.text))
        } else {
            setDisplayText(language.displayText(currentTrack.displayName))
        }
    }

    private func playbackPosition(for track: TrackSnapshot) -> TimeInterval {
        guard track.state == .playing else { return track.position }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - positionAnchorUptime)
        let estimated = track.position + elapsed
        return track.duration > 0 ? min(track.duration, estimated) : estimated
    }

    private func refreshPlaybackPresentation() {
        guard let currentTrack else { return }
        let position = playbackPosition(for: currentTrack)
        updateNowPlayingHeader(for: currentTrack)
        playerView.updateLyricsPosition(position)
    }

    private func updatePlaybackUITimer() {
        playbackUITimer?.invalidate()
        playbackUITimer = nil
        guard
            isSessionActive,
            playerMenu.isOpen,
            currentTrack?.state == .playing
        else { return }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let track = self.currentTrack, track.state == .playing else {
                    timer.invalidate()
                    return
                }
                let position = self.playbackPosition(for: track)
                self.playerView.updatePlaybackPosition(position, duration: track.duration)
                self.playerView.updateLyricsPosition(position)
                if track.duration > 0, position >= track.duration {
                    timer.invalidate()
                    self.schedulePoll(after: 0.1)
                }
            }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        playbackUITimer = timer
    }

    private func scheduleNextLyricTransition() {
        lyricTransitionTimer?.invalidate()
        lyricTransitionTimer = nil
        guard
            isSessionActive,
            let track = currentTrack,
            track.state == .playing,
            let timeline = currentTimeline,
            !timeline.lines.isEmpty
        else { return }

        let position = playbackPosition(for: track)
        guard let nextTime = timeline.lines.first(where: { $0.time > position + 0.01 })?.time else {
            return
        }
        let delay = max(0.05, nextTime - position)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCurrentDisplayText()
                self?.scheduleNextLyricTransition()
            }
        }
        timer.tolerance = min(0.08, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        lyricTransitionTimer = timer
    }

    private func setDisplayText(_ text: String) {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? "♪ \(language.localized(.appleMusic))" : cleaned
        guard value != rawDisplayText else {
            renderCurrentText()
            updateMarqueeTimer()
            return
        }

        rawDisplayText = value
        rawDisplayTextWidth = textWidth(value)
        marqueeCharacters = Array(value + "      ·      ")
        marqueeSlices = rawDisplayTextWidth + horizontalPadding > maximumWidth
            ? prepareMarqueeSlices()
            : []
        marqueeIndex = 0
        renderCurrentText()
        updateMarqueeTimer()
        statusItem.button?.setAccessibilityValue(rawDisplayText)
    }

    @objc private func advanceMarquee() {
        guard !marqueeSlices.isEmpty, let button = statusItem.button else { return }
        marqueeIndex = (marqueeIndex + 1) % marqueeSlices.count
        let title = marqueeSlices[marqueeIndex]
        if button.title != title {
            button.title = title
        }
    }

    private func updateMarqueeTimer() {
        let shouldRun = isSessionActive
            && rawDisplayTextWidth + horizontalPadding > maximumWidth
        if shouldRun, marqueeTimer == nil {
            let timer = Timer(
                timeInterval: marqueeInterval,
                target: self,
                selector: #selector(advanceMarquee),
                userInfo: nil,
                repeats: true
            )
            timer.tolerance = marqueeInterval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            marqueeTimer = timer
        } else if !shouldRun {
            marqueeTimer?.invalidate()
            marqueeTimer = nil
        }
    }

    private func renderCurrentText() {
        guard let button = statusItem.button else { return }
        let width = rawDisplayTextWidth + horizontalPadding

        if width <= maximumWidth {
            statusItem.length = max(72, width)
            if button.title != rawDisplayText {
                button.title = rawDisplayText
            }
        } else {
            statusItem.length = maximumWidth
            let title = marqueeSlices.indices.contains(marqueeIndex)
                ? marqueeSlices[marqueeIndex]
                : rawDisplayText
            if button.title != title {
                button.title = title
            }
        }
    }

    private func prepareMarqueeSlices() -> [String] {
        guard !marqueeCharacters.isEmpty else { return [rawDisplayText] }
        let availableWidth = maximumWidth - horizontalPadding
        let characterWidths = marqueeCharacters.map { textWidth(String($0)) }
        return marqueeCharacters.indices.map { startIndex in
            var characters: [Character] = []
            var estimatedWidth: CGFloat = 0
            for offset in 0..<marqueeCharacters.count {
                let index = (startIndex + offset) % marqueeCharacters.count
                let nextWidth = characterWidths[index]
                if estimatedWidth + nextWidth > availableWidth { break }
                characters.append(marqueeCharacters[index])
                estimatedWidth += nextWidth
            }
            var result = String(characters)
            while !result.isEmpty, textWidth(result) > availableWidth {
                result.removeLast()
            }
            return result
        }
    }

    private func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: statusFont]).width)
    }

    private func loadMusicKitLibrary() {
        libraryGeneration += 1
        let generation = libraryGeneration
        libraryTask?.cancel()
        playlistContentTask?.cancel()
        playlistIdentityTasks.values.forEach { $0.cancel() }
        playlistArtworkTask?.cancel()
        trackArtworkTask?.cancel()
        libraryState = .loading
        allPlaylists = []
        playlists = []
        selectedPlaylistIndex = nil
        selectedPlaylistTracks = []
        musicAppPlaylistIDs = [:]
        playlistIdentityTasks = [:]
        playlistIdentityFailures = [:]
        hasUserSelectedPlaylist = false
        shouldRestorePlaybackFocusAfterPlaylistLoad = false
        playerView.hideTracks()
        playerView.setLibraryState(.loadingLibrary, canRetry: false)
        refreshSettingsMenu()

        libraryTask = Task {
            do {
                let loadedPlaylists = try await musicKitLibraryClient.loadPlaylists()
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                allPlaylists = loadedPlaylists

                guard !loadedPlaylists.isEmpty else {
                    libraryState = .empty
                    playerView.setLibraryState(.emptyPlaylists, canRetry: true)
                    refreshSettingsMenu()
                    return
                }

                libraryState = .loaded
                hiddenPlaylistIDs = PlaylistDisplayFilter.validHiddenIDs(
                    hiddenPlaylistIDs,
                    in: loadedPlaylists
                )
                saveHiddenPlaylistIDs()
                playlists = PlaylistDisplayFilter.visiblePlaylists(
                    from: loadedPlaylists,
                    hiddenIDs: hiddenPlaylistIDs
                )
                guard !playlists.isEmpty else {
                    playerView.setLibraryState(.noVisiblePlaylists, canRetry: false)
                    refreshSettingsMenu()
                    return
                }
                refreshSettingsMenu()
                let matchedIndex = indexOfPlaylist(named: currentPlaylistName)
                let initialIndex = matchedIndex ?? 0
                playerView.setPlaylists(playlists, selectedIndex: initialIndex)
                focusPlaylist(at: initialIndex)
            } catch MusicKitLibraryError.accessDenied,
                    MusicKitLibraryError.accessRestricted {
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                libraryState = .permissionDenied
                playerView.setLibraryState(.musicKitAccessRequired, canRetry: true)
                refreshSettingsMenu()
            } catch {
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                libraryState = .failed(error.localizedDescription)
                playerView.setLibraryState(.libraryUnavailable, canRetry: true)
                refreshSettingsMenu()
            }
        }
    }

    private func renderLibraryState() {
        switch libraryState {
        case .idle:
            playerView.setLibraryState(.loadingLibrary, canRetry: false)
        case .loading:
            playerView.setLibraryState(.loadingLibrary, canRetry: false)
        case .loaded:
            guard !playlists.isEmpty else {
                playerView.setLibraryState(.noVisiblePlaylists, canRetry: false)
                return
            }
            playerView.setPlaylists(
                playlists,
                selectedIndex: selectedPlaylistIndex ?? playerView.focusedPlaylistIndex ?? 0
            )
        case .empty:
            playerView.setLibraryState(.emptyPlaylists, canRetry: true)
        case .permissionDenied:
            playerView.setLibraryState(.musicKitAccessRequired, canRetry: true)
        case .failed:
            playerView.setLibraryState(.libraryUnavailable, canRetry: true)
        }
    }

    private func applyPlaylistVisibility() {
        let previouslySelectedID = selectedPlaylistIndex.flatMap { index in
            playlists.indices.contains(index) ? playlists[index].id : nil
        }
        playlists = PlaylistDisplayFilter.visiblePlaylists(
            from: allPlaylists,
            hiddenIDs: hiddenPlaylistIDs
        )

        guard !playlists.isEmpty else {
            playlistGeneration += 1
            playlistContentTask?.cancel()
            trackArtworkTask?.cancel()
            selectedPlaylistIndex = nil
            selectedPlaylistTracks = []
            playerView.hideTracks()
            playerView.setLibraryState(.noVisiblePlaylists, canRetry: false)
            refreshSettingsMenu()
            return
        }

        let nextIndex = previouslySelectedID.flatMap { selectedID in
            playlists.firstIndex { $0.id == selectedID }
        } ?? indexOfPlaylist(named: currentPlaylistName) ?? 0
        playerView.setPlaylists(playlists, selectedIndex: nextIndex)

        if playlists[nextIndex].id == previouslySelectedID {
            selectedPlaylistIndex = nextIndex
            playerView.focusPlaylist(at: nextIndex)
            beginVisiblePlaylistArtworkLookup(skipping: playlists[nextIndex].id)
        } else {
            selectedPlaylistIndex = nil
            selectedPlaylistTracks = []
            focusPlaylist(at: nextIndex)
        }
        refreshSettingsMenu()
    }

    private func saveHiddenPlaylistIDs() {
        UserDefaults.standard.set(
            hiddenPlaylistIDs.sorted(),
            forKey: hiddenPlaylistIDsDefaultsKey
        )
    }

    private func focusPlaylist(at index: Int, userInitiated: Bool = false) {
        guard playlists.indices.contains(index) else { return }
        if userInitiated {
            hasUserSelectedPlaylist = true
            shouldRestorePlaybackFocusAfterPlaylistLoad = false
        }
        guard selectedPlaylistIndex != index else { return }
        selectedPlaylistIndex = index
        playlistGeneration += 1
        let generation = playlistGeneration
        let playlist = playlists[index]

        playlistContentTask?.cancel()
        trackArtworkTask?.cancel()
        selectedPlaylistTracks = []
        playerView.focusPlaylist(at: index)
        playerView.setTrackState(.loadingTracks)
        beginVisiblePlaylistArtworkLookup(skipping: playlist.id)

        playlistContentTask = Task {
            do {
                let content = try await musicKitLibraryClient.loadContent(for: playlist.id)
                guard
                    !Task.isCancelled,
                    generation == playlistGeneration,
                    selectedPlaylistIndex == index
                else { return }

                playerView.setTracks(content.tracks)
                selectedPlaylistTracks = content.tracks
                if shouldRestorePlaybackFocusAfterPlaylistLoad {
                    shouldRestorePlaybackFocusAfterPlaylistLoad = false
                    playerView.restorePlaybackFocus()
                }
                beginPlaylistIdentityLookup(
                    playlist,
                    tracks: content.tracks
                )
                if let artworkURL = content.artworkURL,
                   let data = await musicKitLibraryClient.artworkData(at: artworkURL),
                   !Task.isCancelled,
                   generation == playlistGeneration {
                    playerView.setPlaylistArtwork(NSImage(data: data), for: playlist.id)
                }
            } catch {
                guard
                    !Task.isCancelled,
                    generation == playlistGeneration,
                    selectedPlaylistIndex == index
                else { return }
                playerView.setTrackState(.libraryUnavailable)
                shouldRestorePlaybackFocusAfterPlaylistLoad = false
            }
        }
    }

    private func activatePlaylist(at index: Int) {
        guard playlists.indices.contains(index) else { return }
        focusPlaylist(at: index, userInitiated: true)
        let playlist = playlists[index]
        currentPlaylistName = playlist.name
        let knownTracks = selectedPlaylistIndex == index ? selectedPlaylistTracks : []

        Task {
            var matchingTracks = knownTracks
            if matchingTracks.isEmpty {
                matchingTracks = (try? await musicKitLibraryClient.loadContent(for: playlist.id))?.tracks ?? []
            }
            let persistentID = await resolvedMusicAppPlaylistID(
                for: playlist,
                matching: matchingTracks
            )
            await musicClient.playPlaylist(
                named: playlist.name,
                persistentID: persistentID
            )
            try? await Task.sleep(for: .milliseconds(200))
            pollMusic()
        }
    }

    private func playTrack(_ track: LibraryTrackSnapshot, fallbackIndex index: Int) {
        guard
            index >= 0,
            let selectedPlaylistIndex,
            playlists.indices.contains(selectedPlaylistIndex)
        else { return }

        let playlist = playlists[selectedPlaylistIndex]
        hasUserSelectedPlaylist = true
        currentPlaylistName = playlist.name
        let matchingTracks = selectedPlaylistTracks.isEmpty ? [track] : selectedPlaylistTracks
        Task {
            let persistentID = await resolvedMusicAppPlaylistID(
                for: playlist,
                matching: matchingTracks
            )
            await musicClient.playTrack(
                track,
                fallbackIndex: index,
                inPlaylistNamed: playlist.name,
                playlistPersistentID: persistentID
            )
            try? await Task.sleep(for: .milliseconds(200))
            pollMusic()
        }
    }

    private func beginPlaylistIdentityLookup(
        _ playlist: LibraryPlaylistSnapshot,
        tracks: [LibraryTrackSnapshot]
    ) {
        guard musicAppPlaylistIDs[playlist.id] == nil, !tracks.isEmpty else { return }
        Task { [weak self] in
            _ = await self?.resolvedMusicAppPlaylistID(
                for: playlist,
                matching: tracks
            )
        }
    }

    private func resolvedMusicAppPlaylistID(
        for playlist: LibraryPlaylistSnapshot,
        matching tracks: [LibraryTrackSnapshot]
    ) async -> String? {
        if let persistentID = musicAppPlaylistIDs[playlist.id] {
            return persistentID
        }
        if
            let failedAt = playlistIdentityFailures[playlist.id],
            Date().timeIntervalSince(failedAt) < playlistIdentityFailureTTL
        {
            return nil
        }
        guard !tracks.isEmpty else { return nil }

        let task: Task<String?, Never>
        let ownsTask: Bool
        if let inFlightTask = playlistIdentityTasks[playlist.id] {
            task = inFlightTask
            ownsTask = false
        } else {
            let musicClient = self.musicClient
            task = Task {
                await musicClient.playlistPersistentID(
                    named: playlist.name,
                    matching: tracks
                )
            }
            playlistIdentityTasks[playlist.id] = task
            ownsTask = true
        }

        let persistentID = await task.value
        if ownsTask {
            playlistIdentityTasks.removeValue(forKey: playlist.id)
        }
        guard !task.isCancelled else { return nil }
        if let persistentID {
            musicAppPlaylistIDs[playlist.id] = persistentID
            playlistIdentityFailures.removeValue(forKey: playlist.id)
        } else {
            playlistIdentityFailures[playlist.id] = Date()
        }
        return persistentID
    }

    private func beginVisiblePlaylistArtworkLookup(skipping skippedID: String? = nil) {
        playlistArtworkTask?.cancel()
        let generation = libraryGeneration
        let visibleIDs = playerView.visiblePlaylistIDs.filter { $0 != skippedID }
        let visiblePlaylists = visibleIDs.compactMap { id in
            playlists.first { $0.id == id }
        }

        playlistArtworkTask = Task {
            for playlist in visiblePlaylists {
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                var artworkURL = playlist.artworkURL
                if artworkURL == nil {
                    let content = try? await musicKitLibraryClient.loadContent(for: playlist.id)
                    artworkURL = content?.artworkURL
                }
                guard
                    let artworkURL,
                    let data = await musicKitLibraryClient.artworkData(at: artworkURL),
                    let image = NSImage(data: data),
                    !Task.isCancelled,
                    generation == libraryGeneration
                else { continue }
                playerView.setPlaylistArtwork(image, for: playlist.id)
            }
        }
    }

    private func beginVisibleTrackArtworkLookup(_ trackIDs: [String]) {
        trackArtworkTask?.cancel()
        trackArtworkTask = nil
        guard
            !trackIDs.isEmpty,
            let selectedPlaylistIndex,
            playlists.indices.contains(selectedPlaylistIndex)
        else { return }

        let playlistID = playlists[selectedPlaylistIndex].id
        let generation = playlistGeneration
        let tracksByID = Dictionary(
            uniqueKeysWithValues: selectedPlaylistTracks.map { ($0.id, $0) }
        )
        let visibleTracks = trackIDs.compactMap { tracksByID[$0] }
        guard !visibleTracks.isEmpty else { return }
        let client = musicKitLibraryClient
        trackArtworkTask = Task {
            await withTaskGroup(of: (String, Data?).self) { group in
                for track in visibleTracks {
                    group.addTask {
                        guard let url = track.artworkURL else { return (track.id, nil) }
                        return (track.id, await client.artworkData(at: url))
                    }
                }
                for await (trackID, data) in group {
                    guard
                        !Task.isCancelled,
                        generation == playlistGeneration,
                        playlists.indices.contains(selectedPlaylistIndex),
                        playlists[selectedPlaylistIndex].id == playlistID,
                        let data,
                        let image = NSImage(data: data)
                    else { continue }
                    playerView.setTrackArtwork(image, for: trackID)
                }
            }
        }
    }

    private func indexOfPlaylist(named name: String?) -> Int? {
        guard let name, !name.isEmpty else { return nil }
        return playlists.firstIndex {
            $0.name.localizedStandardCompare(name) == .orderedSame
        }
    }

    private func refreshSettingsMenu(force: Bool = false) {
        guard force || !playerMenu.isOpen else { return }
        populateSettingsMenu(settingsMenu)
    }

    private func populateSettingsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let refreshItem = NSMenuItem(
            title: language.localized(.refreshLyrics),
            action: #selector(refreshLyrics),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.isEnabled = currentTrack != nil
        menu.addItem(refreshItem)

        let reloadItem = NSMenuItem(
            title: language.localized(.reloadLibrary),
            action: #selector(reloadMusicKitLibrary),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let playlistVisibilityItem = NSMenuItem(
            title: language.localized(.playlistVisibility),
            action: nil,
            keyEquivalent: ""
        )
        let playlistVisibilityMenu = NSMenu()
        let configurablePlaylists = allPlaylists.filter { !$0.isFolder }
        if configurablePlaylists.isEmpty {
            let emptyKey: AppStringKey
            if case .loading = libraryState {
                emptyKey = .loadingLibrary
            } else {
                emptyKey = .emptyPlaylists
            }
            let emptyItem = NSMenuItem(
                title: language.localized(emptyKey),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            playlistVisibilityMenu.addItem(emptyItem)
        } else {
            for playlist in configurablePlaylists {
                let item = NSMenuItem(
                    title: language.displayText(playlist.name),
                    action: #selector(togglePlaylistVisibility(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = playlist.id
                item.state = hiddenPlaylistIDs.contains(playlist.id) ? .off : .on
                playlistVisibilityMenu.addItem(item)
            }
        }
        playlistVisibilityItem.submenu = playlistVisibilityMenu
        menu.addItem(playlistVisibilityItem)

        let trackListItem = NSMenuItem(
            title: language.localized(.showTrackList),
            action: nil,
            keyEquivalent: ""
        )
        let trackListMenu = NSMenu()
        for mode in TrackListDisplayMode.allCases {
            let item = NSMenuItem(
                title: language.localized(mode.localizationKey),
                action: #selector(selectTrackListMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == trackListMode ? .on : .off
            trackListMenu.addItem(item)
        }
        trackListItem.submenu = trackListMenu
        menu.addItem(trackListItem)

        let languageItem = NSMenuItem(
            title: language.localized(.language),
            action: nil,
            keyEquivalent: ""
        )
        let languageMenu = NSMenu()
        for option in AppLanguage.allCases {
            let item = NSMenuItem(
                title: option == .system ? language.localized(.followSystem) : option.menuTitle,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let openMusicItem = NSMenuItem(
            title: language.localized(.openAppleMusic),
            action: #selector(openMusic),
            keyEquivalent: ""
        )
        openMusicItem.target = self
        menu.addItem(openMusicItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: language.localized(.quit),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

    }

    private func send(_ command: MusicCommand) {
        Task {
            await musicClient.send(command)
            try? await Task.sleep(for: .milliseconds(150))
            pollMusic()
        }
    }

    private func seek(to position: TimeInterval) {
        Task {
            await musicClient.seek(to: position)
            try? await Task.sleep(for: .milliseconds(80))
            pollMusic()
        }
    }

    private func toggleTrackList() {
        let nextMode = trackListMode == .off ? lastVisibleTrackListMode : .off
        applyTrackListMode(nextMode)
    }

    private func applyTrackListMode(_ mode: TrackListDisplayMode) {
        trackListMode = mode
        if mode != .off {
            lastVisibleTrackListMode = mode
        }
        mode.save()
        playerView.setTrackListMode(mode)
        refreshSettingsMenu()
    }

    @objc private func refreshLyrics() {
        guard let currentTrack else { return }
        currentTimeline = nil
        playerView.setLyricsLoading()
        refreshCurrentDisplayText()
        beginLyricsLookup(for: currentTrack, invalidate: true)
    }

    @objc private func reloadMusicKitLibrary() {
        loadMusicKitLibrary()
    }

    @objc private func togglePlaylistVisibility(_ sender: NSMenuItem) {
        guard let playlistID = sender.representedObject as? String else { return }
        if hiddenPlaylistIDs.contains(playlistID) {
            hiddenPlaylistIDs.remove(playlistID)
        } else {
            hiddenPlaylistIDs.insert(playlistID)
        }
        saveHiddenPlaylistIDs()
        applyPlaylistVisibility()
    }

    @objc private func selectTrackListMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = TrackListDisplayMode(rawValue: rawValue)
        else { return }
        applyTrackListMode(mode)
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
