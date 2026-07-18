import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private enum UnavailableState {
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
    private let marqueeInterval: TimeInterval = 0.16
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
    private var marqueeTimer: Timer?
    private var isPolling = false
    private var currentTrack: TrackSnapshot?
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
    private var marqueeCharacters: [Character] = []
    private var marqueeIndex = 0

    func start() {
        configureStatusItem()
        configurePanel()
        playerView.setTrackListMode(trackListMode)
        refreshLocalizedPresentation()
        loadMusicKitLibrary()

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

    private func configurePanel() {
        _ = playerMenu
        settingsMenu.autoenablesItems = false
        settingsMenu.delegate = self
        populateSettingsMenu(settingsMenu)
        playerMenu.configureSettingsItem(
            title: language.localized(.playlists),
            submenu: settingsMenu
        )
        playerMenu.onWillOpen = { [weak self] in
            guard let self else { return }
            NSApp.activate()
            self.restorePlaybackContext()
            self.playerMenu.updateContentSize(self.playerView.intrinsicContentSize)
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
            playerView.setCurrentTrack(track)
            updateNowPlayingHeader(for: track)
            playerView.updateLyricsPosition(track.position)

            if didChangeTrack {
                currentTimeline = nil
                playerView.setNowPlayingArtwork(nil)
                playerView.setLyricsLoading()
                beginArtworkLookup(for: track)
                beginLyricsLookup(for: track)
                beginCurrentPlaylistLookup(for: track)
            }
            refreshCurrentDisplayText()
        }
    }

    private func updateNowPlayingHeader(for track: TrackSnapshot) {
        playerView.updateNowPlaying(
            title: language.displayText(track.title),
            subtitle: language.displayText(track.artist),
            isPlaying: track.state == .playing,
            controlsEnabled: true,
            position: track.position,
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

        libraryTask = Task {
            do {
                let loadedPlaylists = try await musicKitLibraryClient.loadPlaylists()
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                allPlaylists = loadedPlaylists

                guard !loadedPlaylists.isEmpty else {
                    libraryState = .empty
                    playerView.setLibraryState(.emptyPlaylists, canRetry: true)
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
                    return
                }
                let matchedIndex = indexOfPlaylist(named: currentPlaylistName)
                let initialIndex = matchedIndex ?? 0
                playerView.setPlaylists(playlists, selectedIndex: initialIndex)
                focusPlaylist(at: initialIndex)
            } catch MusicKitLibraryError.accessDenied,
                    MusicKitLibraryError.accessRestricted {
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                libraryState = .permissionDenied
                playerView.setLibraryState(.musicKitAccessRequired, canRetry: true)
            } catch {
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                libraryState = .failed(error.localizedDescription)
                playerView.setLibraryState(.libraryUnavailable, canRetry: true)
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
                beginTrackArtworkLookup(
                    content.tracks,
                    playlistID: playlist.id,
                    generation: generation
                )
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

    private func beginTrackArtworkLookup(
        _ tracks: [LibraryTrackSnapshot],
        playlistID: String,
        generation: Int
    ) {
        trackArtworkTask?.cancel()
        let client = musicKitLibraryClient
        trackArtworkTask = Task {
            let tracksWithArtwork = tracks.filter { $0.artworkURL != nil }
            for startIndex in stride(from: 0, to: tracksWithArtwork.count, by: 6) {
                guard
                    !Task.isCancelled,
                    generation == playlistGeneration,
                    selectedPlaylistIndex.flatMap({ playlists.indices.contains($0) ? playlists[$0].id : nil }) == playlistID
                else { return }

                let endIndex = min(startIndex + 6, tracksWithArtwork.count)
                let chunk = Array(tracksWithArtwork[startIndex..<endIndex])
                await withTaskGroup(of: (String, Data?).self) { group in
                    for track in chunk {
                        group.addTask {
                            guard let url = track.artworkURL else { return (track.id, nil) }
                            return (track.id, await client.artworkData(at: url))
                        }
                    }
                    for await (trackID, data) in group {
                        guard
                            !Task.isCancelled,
                            generation == playlistGeneration,
                            let data,
                            let image = NSImage(data: data)
                        else { continue }
                        playerView.setTrackArtwork(image, for: trackID)
                    }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === settingsMenu else { return }
        populateSettingsMenu(menu)
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
        if allPlaylists.isEmpty {
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
            for playlist in allPlaylists {
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
