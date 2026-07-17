import AppKit
import XCTest
@testable import AppleMusicBar

final class MenuPreviewTests: XCTestCase {
    func testPlaylistDisplayFilterHidesOnlySelectedPlaylists() {
        let playlists = [
            LibraryPlaylistSnapshot(id: "one", name: "一", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "two", name: "二", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "three", name: "三", artworkURL: nil)
        ]

        XCTAssertEqual(
            PlaylistDisplayFilter.visiblePlaylists(
                from: playlists,
                hiddenIDs: ["two", "missing"]
            ).map(\.id),
            ["one", "three"]
        )
        XCTAssertEqual(
            PlaylistDisplayFilter.validHiddenIDs(
                ["two", "missing"],
                in: playlists
            ),
            ["two"]
        )
    }

    @MainActor
    func testCompactMenuHeaderSize() {
        let view = NowPlayingMenuView()
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 240, height: 126))
    }

    @MainActor
    func testCompactControlsInvokeCallbacks() {
        let view = NowPlayingMenuView()
        var invoked: [String] = []
        view.onPrevious = { invoked.append("previous") }
        view.onPlayPause = { invoked.append("playPause") }
        view.onNext = { invoked.append("next") }
        view.onLyricsToggle = { invoked.append("lyrics") }
        view.update(title: "Song", subtitle: "Artist", isPlaying: false, controlsEnabled: true)

        let buttons = allSubviews(of: view).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSButton }.count, 4)
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(invoked, ["previous", "playPause", "next", "lyrics"])
    }

    @MainActor
    func testPlaybackProgressCanBeScrubbedAndCommitsSeekPosition() throws {
        let view = NowPlayingMenuView()
        var seekPosition: TimeInterval?
        view.onSeek = { seekPosition = $0 }
        view.update(
            title: "Song",
            subtitle: "Artist",
            isPlaying: true,
            controlsEnabled: true,
            position: 20,
            duration: 200
        )
        let progressView = try XCTUnwrap(
            allSubviews(of: view).compactMap { $0 as? PlaybackProgressView }.first
        )

        progressView.scrub(to: 0.625, commit: true)

        XCTAssertEqual(try XCTUnwrap(seekPosition), 125, accuracy: 0.001)
        XCTAssertEqual(progressView.progress, 0.625, accuracy: 0.001)
        XCTAssertTrue(
            allSubviews(of: view)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "2:05" }
        )
    }

    @MainActor
    func testPlaylistCarouselNavigationWrapsAndInvokesCallback() {
        let view = PlaylistCarouselView()
        let playlists = [
            LibraryPlaylistSnapshot(id: "one", name: "一", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "two", name: "二", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "three", name: "三", artworkURL: nil)
        ]
        var selectedIndexes: [Int] = []
        view.onSelectionChanged = { selectedIndexes.append($0) }
        view.update(playlists: playlists, selectedIndex: 0, language: .simplifiedChinese)

        view.navigate(by: -1)
        view.navigate(by: 1)

        XCTAssertEqual(selectedIndexes, [2, 0])
        XCTAssertEqual(view.selectedIndex, 0)
        XCTAssertEqual(Set(view.visiblePlaylistIDs), Set(["one", "two", "three"]))
    }

    @MainActor
    func testPlaylistNameIsBelowItsArtwork() throws {
        let view = PlaylistCarouselView()
        view.update(
            playlists: [
                LibraryPlaylistSnapshot(id: "one", name: "一", artworkURL: nil),
                LibraryPlaylistSnapshot(id: "two", name: "二", artworkURL: nil),
                LibraryPlaylistSnapshot(id: "three", name: "三", artworkURL: nil)
            ],
            selectedIndex: 1,
            language: .simplifiedChinese
        )
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 126)
        view.layoutSubtreeIfNeeded()

        let centerCard = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSButton }.first { $0.tag == 1 }
        )
        let artwork = try XCTUnwrap(centerCard.subviews.first { $0 is NSImageView })
        let title = try XCTUnwrap(centerCard.subviews.first { $0 is NSTextField })
        XCTAssertTrue(centerCard.isFlipped)
        XCTAssertLessThan(artwork.frame.maxY, title.frame.minY)
    }

    @MainActor
    func testCarouselContinuouslyMovesAndScalesDuringScroll() throws {
        let view = PlaylistCarouselView()
        let playlists = (0..<5).map {
            LibraryPlaylistSnapshot(id: "playlist-\($0)", name: "列表 \($0)", artworkURL: nil)
        }
        view.update(playlists: playlists, selectedIndex: 2, language: .simplifiedChinese)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 126)
        view.layoutSubtreeIfNeeded()

        let cards = view.subviews.compactMap { $0 as? NSButton }
        let initialCenterWidth = try XCTUnwrap(cards.map(\.frame.width).max())
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -42,
            wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertNotEqual(event.scrollingDeltaX, 0)
        view.scrollWheel(with: event)

        let visibleWidths = cards.filter { !$0.isHidden && $0.alphaValue > 0.05 }.map(\.frame.width)
        let movingLargestWidth = try XCTUnwrap(visibleWidths.max())
        XCTAssertEqual(initialCenterWidth, 88, accuracy: 0.1)
        XCTAssertLessThan(movingLargestWidth, initialCenterWidth)
        XCTAssertGreaterThan(movingLargestWidth, 74)
        XCTAssertGreaterThanOrEqual(visibleWidths.count, 3)

        view.select(index: 2, notify: false)
        let restoredLargestWidth = try XCTUnwrap(
            cards.filter { !$0.isHidden && $0.alphaValue > 0.05 }.map(\.frame.width).max()
        )
        XCTAssertEqual(restoredLargestWidth, 88, accuracy: 0.1)
    }

    @MainActor
    func testPopoverSupportsOffVerticalAndHorizontalTrackLists() {
        let view = PlayerPopoverView()
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 252))
        XCTAssertFalse(view.isTrackListVisible)

        view.setTracks([
            LibraryTrackSnapshot(
                id: "track-1",
                title: "夜曲",
                album: "11月的萧邦",
                artist: "周杰伦",
                artworkURL: nil
            )
        ])
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 252))
        XCTAssertEqual(view.displayedTrackCount, 1)

        view.setTrackListMode(.vertical)
        XCTAssertTrue(view.isTrackListVisible)
        XCTAssertEqual(view.trackListMode, .vertical)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 538))

        view.setTrackListMode(.horizontal)
        XCTAssertEqual(view.trackListMode, .horizontal)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 378))

        view.setTrackListMode(.off)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 252))
    }

    @MainActor
    func testLyricsReplaceTrackListAndFollowPlaybackPosition() {
        let view = PlayerPopoverView()
        let timeline = LyricsTimeline(
            lines: [
                LyricLine(time: 0, text: "第一句"),
                LyricLine(time: 5, text: "第二句"),
                LyricLine(time: 10, text: "第三句")
            ],
            source: .lrclibSynced
        )
        view.setTrackListMode(.horizontal)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 378))

        view.setLyricsTimeline(timeline)
        view.updateLyricsPosition(7)
        view.setLyricsVisible(true)

        XCTAssertTrue(view.isLyricsVisible)
        XCTAssertEqual(view.displayedLyricLineCount, 3)
        XCTAssertEqual(view.currentLyricText, "第二句")
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 538))

        view.setLyricsVisible(false)
        XCTAssertFalse(view.isLyricsVisible)
        XCTAssertEqual(view.trackListMode, .horizontal)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 252, height: 378))
    }

    @MainActor
    func testLyricsToggleUsesRedEmphasisAndResizesNativeMenuContent() throws {
        let view = PlayerPopoverView()
        view.setTrackListMode(.horizontal)
        view.updatePlaybackAccessibility(
            previous: "上一首",
            play: "播放",
            pause: "暂停",
            next: "下一首",
            showLyrics: "查看歌词",
            hideLyrics: "关闭歌词"
        )
        let playerMenu = NativePlayerMenu(
            contentView: view,
            contentSize: view.intrinsicContentSize
        )
        view.onPreferredSizeChange = { size in
            playerMenu.updateContentSize(size)
        }

        view.setLyricsVisible(true)

        XCTAssertEqual(view.frame.size, NSSize(width: 252, height: 538))
        let lyricsButton = try XCTUnwrap(
            allSubviews(of: view)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "关闭歌词" }
        )
        XCTAssertEqual(lyricsButton.contentTintColor, AppVisualStyle.emphasisColor)

        view.setLyricsVisible(false)

        XCTAssertEqual(view.frame.size, NSSize(width: 252, height: 378))
        XCTAssertFalse(view.isLyricsVisible)
    }

    @MainActor
    func testHorizontalTrackCarouselContinuouslyMovesAndScalesDuringScroll() throws {
        let view = PlayerPopoverView()
        let tracks = (0..<5).map { index in
            LibraryTrackSnapshot(
                id: "track-\(index)",
                title: "歌曲 \(index)",
                album: "专辑",
                artist: "艺人",
                artworkURL: nil
            )
        }
        view.setTracks(tracks)
        view.updateLocalization(.simplifiedChinese)
        let currentTrack = TrackSnapshot(
            title: tracks[0].title,
            artist: tracks[0].artist,
            album: tracks[0].album,
            duration: 240,
            position: 20,
            state: .playing,
            embeddedLyrics: ""
        )
        view.setCurrentTrack(currentTrack)
        view.setTrackListMode(.horizontal)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let cards = allSubviews(of: view)
            .compactMap { $0 as? NSButton }
            .filter {
                $0.accessibilityLabel()?.hasPrefix("歌曲") == true
                    && !$0.isHiddenOrHasHiddenAncestor
            }
        let carousel = try XCTUnwrap(cards.first?.superview)
        let centerCard = try XCTUnwrap(cards.max { $0.frame.width < $1.frame.width })
        XCTAssertEqual(
            try XCTUnwrap(centerCard.layer?.backgroundColor?.alpha),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(centerCard.accessibilityHelp(), "暂停")
        var playPauseCount = 0
        view.onPlayPause = { playPauseCount += 1 }
        centerCard.performClick(nil)
        XCTAssertEqual(playPauseCount, 1)
        let initialCenterWidth = try XCTUnwrap(cards.filter { !$0.isHidden }.map(\.frame.width).max())
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -42,
            wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        carousel.scrollWheel(with: event)

        let movingWidths = cards
            .filter { !$0.isHidden && $0.alphaValue > 0.05 }
            .map(\.frame.width)
        let movingLargestWidth = try XCTUnwrap(movingWidths.max())
        XCTAssertEqual(initialCenterWidth, 88, accuracy: 0.1)
        XCTAssertLessThan(movingLargestWidth, initialCenterWidth)
        XCTAssertGreaterThan(movingLargestWidth, 74)
        XCTAssertGreaterThanOrEqual(movingWidths.count, 3)

        view.setCurrentTrack(currentTrack)
        let widthsAfterRepeatedPlaybackPoll = cards
            .filter { !$0.isHidden && $0.alphaValue > 0.05 }
            .map(\.frame.width)
        XCTAssertEqual(widthsAfterRepeatedPlaybackPoll, movingWidths)

        view.restorePlaybackFocus()
        let widthsAfterRestore = cards.filter { !$0.isHidden }.map(\.frame.width)
        XCTAssertEqual(try XCTUnwrap(widthsAfterRestore.max()), 88, accuracy: 0.1)
    }

    @MainActor
    func testHorizontalCenterUsesPlayOnHoverAndPauseAfterPlaybackStarts() throws {
        let view = PlayerPopoverView()
        view.updateLocalization(.simplifiedChinese)
        let tracks = (0..<3).map { index in
            LibraryTrackSnapshot(
                id: "hover-track-\(index)",
                title: "横向歌曲 \(index)",
                album: "专辑",
                artist: "艺人",
                artworkURL: nil
            )
        }
        var playedTrackID: String?
        var playPauseCount = 0
        view.onTrackSelected = { track, _ in playedTrackID = track.id }
        view.onPlayPause = { playPauseCount += 1 }
        view.setTracks(tracks)
        view.setTrackListMode(.horizontal)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let cards = allSubviews(of: view)
            .compactMap { $0 as? NSButton }
            .filter {
                $0.accessibilityLabel()?.hasPrefix("横向歌曲") == true
                    && !$0.isHiddenOrHasHiddenAncestor
            }
        let centerCard = try XCTUnwrap(cards.max { $0.frame.width < $1.frame.width })
        let hiddenSubviewsBeforeHover = centerCard.subviews.filter(\.isHidden).count
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        centerCard.mouseEntered(with: event)

        XCTAssertEqual(centerCard.accessibilityHelp(), "播放")
        XCTAssertLessThan(centerCard.subviews.filter(\.isHidden).count, hiddenSubviewsBeforeHover)
        centerCard.performClick(nil)
        XCTAssertEqual(playedTrackID, tracks[0].id)

        view.setCurrentTrack(TrackSnapshot(
            title: tracks[0].title,
            artist: tracks[0].artist,
            album: tracks[0].album,
            duration: 180,
            position: 1,
            state: .playing,
            embeddedLyrics: ""
        ))
        XCTAssertEqual(centerCard.accessibilityHelp(), "暂停")
        XCTAssertEqual(
            try XCTUnwrap(centerCard.layer?.backgroundColor?.alpha),
            0,
            accuracy: 0.001
        )
        centerCard.performClick(nil)
        XCTAssertEqual(playPauseCount, 1)
    }

    func testTrackListDisplayModePersistsAndMigratesLegacySetting() throws {
        let suiteName = "TrackListDisplayModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TrackListDisplayMode.load(from: defaults), .off)
        defaults.set(true, forKey: "showTrackList")
        XCTAssertEqual(TrackListDisplayMode.load(from: defaults), .vertical)

        TrackListDisplayMode.horizontal.save(to: defaults)
        XCTAssertEqual(TrackListDisplayMode.load(from: defaults), .horizontal)
        XCTAssertNil(defaults.object(forKey: "showTrackList"))
    }

    @MainActor
    func testArtworkAccentColorReflectsCoverColor() throws {
        let image = makePreviewArtwork(
            color: NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.86, alpha: 1)
        )
        let color = try XCTUnwrap(
            ArtworkAccentColor.extract(from: image).usingColorSpace(.deviceRGB)
        )
        XCTAssertGreaterThan(color.blueComponent, color.redComponent)
        XCTAssertGreaterThan(color.blueComponent, color.greenComponent)
    }

    @MainActor
    func testVerticalAndHorizontalTracksInvokePlaybackCallback() throws {
        let view = PlayerPopoverView()
        var selectedIndexes: [Int] = []
        var selectedTrackIDs: [String] = []
        view.onTrackSelected = { track, index in
            selectedTrackIDs.append(track.id)
            selectedIndexes.append(index)
        }
        view.setTracks([
            LibraryTrackSnapshot(
                id: "track-1",
                title: "夜曲",
                album: "11月的萧邦",
                artist: "周杰伦",
                artworkURL: nil
            )
        ])
        view.setTrackListMode(.vertical)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let verticalRow = try XCTUnwrap(
            allSubviews(of: view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.accessibilityLabel()?.contains("夜曲") == true
                        && !$0.isHiddenOrHasHiddenAncestor
                }
        )
        verticalRow.performClick(nil)

        view.setTrackListMode(.horizontal)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let horizontalCard = try XCTUnwrap(
            allSubviews(of: view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.accessibilityLabel()?.contains("夜曲") == true
                        && !$0.isHiddenOrHasHiddenAncestor
                }
        )
        horizontalCard.performClick(nil)

        XCTAssertEqual(selectedIndexes, [0, 0])
        XCTAssertEqual(selectedTrackIDs, ["track-1", "track-1"])
    }

    @MainActor
    func testCurrentTrackIsSelectedAndHoverShowsPlayAffordance() throws {
        let view = PlayerPopoverView()
        let tracks = [
            LibraryTrackSnapshot(
                id: "current",
                title: "夜曲",
                album: "11月的萧邦",
                artist: "周杰伦",
                artworkURL: nil
            ),
            LibraryTrackSnapshot(
                id: "hover",
                title: "发如雪",
                album: "11月的萧邦",
                artist: "周杰伦",
                artworkURL: nil
            )
        ]
        view.setTracks(tracks)
        view.setCurrentTrack(TrackSnapshot(
            title: "夜曲",
            artist: "周杰伦",
            album: "11月的萧邦",
            duration: 240,
            position: 10,
            state: .playing,
            embeddedLyrics: ""
        ))
        view.setTrackListMode(.vertical)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let buttons = allSubviews(of: view).compactMap { $0 as? NSButton }
        let selectedRow = try XCTUnwrap(
            buttons.first { $0.accessibilityLabel()?.contains("夜曲") == true }
        )
        let selectedColor = try XCTUnwrap(
            NSColor(cgColor: try XCTUnwrap(selectedRow.layer?.backgroundColor))?
                .usingColorSpace(.deviceRGB)
        )
        XCTAssertEqual(selectedColor.redComponent, selectedColor.greenComponent, accuracy: 0.03)
        XCTAssertEqual(selectedColor.greenComponent, selectedColor.blueComponent, accuracy: 0.03)

        let hoverRow = try XCTUnwrap(
            buttons.first { $0.accessibilityLabel()?.contains("发如雪") == true }
        )
        let hiddenBefore = hoverRow.subviews.filter(\.isHidden).count
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        hoverRow.mouseEntered(with: event)
        XCTAssertLessThan(hoverRow.subviews.filter(\.isHidden).count, hiddenBefore)
        XCTAssertNotNil(hoverRow.layer?.backgroundColor)
    }

    @MainActor
    func testTrackArtworkSurvivesRowRebuild() throws {
        let view = PlayerPopoverView()
        let track = LibraryTrackSnapshot(
            id: "track-1",
            title: "夜曲",
            album: "11月的萧邦",
            artist: "周杰伦",
            artworkURL: nil
        )
        let artwork = makePreviewArtwork(color: .systemOrange)
        view.setTracks([track])
        view.setTrackArtwork(artwork, for: track.id)

        view.updateLocalization(.traditionalChinese)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(
            allSubviews(of: view)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel()?.contains("夜曲") == true }
        )
        let artworkView = try XCTUnwrap(row.subviews.first { $0 is NSImageView } as? NSImageView)
        XCTAssertTrue(artworkView.image === artwork)
    }

    @MainActor
    func testPlayerUsesNativeMenuSurface() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 102))
        let playerMenu = NativePlayerMenu(
            contentView: rootView,
            contentSize: rootView.frame.size
        )
        let settingsMenu = NSMenu()
        settingsMenu.addItem(withTitle: "设置", action: nil, keyEquivalent: "")
        playerMenu.configureSettingsItem(title: "播放列表", submenu: settingsMenu)

        XCTAssertEqual(playerMenu.menu.items.count, 2)
        XCTAssertTrue(playerMenu.menu.items.first === playerMenu.settingsItem)
        XCTAssertEqual(playerMenu.settingsItem.title, "播放列表")
        XCTAssertTrue(playerMenu.settingsItem.submenu === settingsMenu)
        XCTAssertNotNil(playerMenu.settingsItem.image)
        XCTAssertTrue(playerMenu.item.view === rootView)
        XCTAssertEqual(playerMenu.menu.minimumWidth, 252)
        XCTAssertEqual(rootView.frame.size, NSSize(width: 252, height: 102))

        playerMenu.updateContentSize(NSSize(width: 252, height: 228))

        XCTAssertEqual(rootView.frame.size, NSSize(width: 252, height: 228))
    }

    @MainActor
    func testNativeMenuKeepsItsTopAnchoredDuringLiveContentChanges() throws {
        _ = NSApplication.shared
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            throw XCTSkip("需要可用的 WindowServer 才能验证原生菜单窗口")
        }
        let view = PlayerPopoverView()
        view.setTrackListMode(.horizontal)
        let playerMenu = NativePlayerMenu(
            contentView: view,
            contentSize: view.intrinsicContentSize
        )
        view.onPreferredSizeChange = { size in
            playerMenu.updateContentSize(size)
        }

        var initialFrame: NSRect?
        var lyricsFrame: NSRect?
        var restoredFrame: NSRect?
        let failSafe = DispatchWorkItem { playerMenu.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: failSafe)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            initialFrame = playerMenu.windowFrame
            view.setLyricsVisible(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                lyricsFrame = playerMenu.windowFrame
                view.setLyricsVisible(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    restoredFrame = playerMenu.windowFrame
                    playerMenu.cancel()
                }
            }
        }

        playerMenu.present(at: NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 40))
        failSafe.cancel()

        let initial = try XCTUnwrap(initialFrame)
        let lyrics = try XCTUnwrap(lyricsFrame)
        let restored = try XCTUnwrap(restoredFrame)
        XCTAssertEqual(lyrics.maxY, initial.maxY, accuracy: 1)
        XCTAssertEqual(restored.maxY, initial.maxY, accuracy: 1)
        XCTAssertEqual(lyrics.height - initial.height, 160, accuracy: 1)
        XCTAssertEqual(restored.height, initial.height, accuracy: 1)
    }

    @MainActor
    func testRenderCompactMenuHeaderPreview() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["APPLE_MUSIC_BAR_MENU_PREVIEW"] else {
            throw XCTSkip("设置 APPLE_MUSIC_BAR_MENU_PREVIEW 后渲染紧凑菜单预览")
        }

        _ = NSApplication.shared
        let view = NowPlayingMenuView()
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.updateAccessibility(previous: "上一首", play: "播放", pause: "暂停", next: "下一首")
        view.update(
            title: "浪漫手机",
            subtitle: "周杰伦",
            isPlaying: true,
            controlsEnabled: true,
            position: 221,
            duration: 292
        )
        view.setArtwork(makePreviewArtwork())
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @MainActor
    func testRenderPlayerPopoverPreview() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["APPLE_MUSIC_BAR_POPOVER_PREVIEW"] else {
            throw XCTSkip("设置 APPLE_MUSIC_BAR_POPOVER_PREVIEW 后渲染播放器面板预览")
        }

        _ = NSApplication.shared
        let view = PlayerPopoverView()
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.updateLocalization(.simplifiedChinese)
        view.updatePlaybackAccessibility(previous: "上一首", play: "播放", pause: "暂停", next: "下一首")
        view.updateNowPlaying(
            title: "发如雪",
            subtitle: "周杰伦",
            isPlaying: true,
            controlsEnabled: true,
            position: 221,
            duration: 292
        )
        view.setNowPlayingArtwork(makePreviewArtwork(color: .systemBrown))
        let playlists = [
            LibraryPlaylistSnapshot(id: "favorites", name: "我喜欢的音乐", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "jay", name: "11月的萧邦", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "night", name: "深夜播放", artworkURL: nil)
        ]
        view.setPlaylists(playlists, selectedIndex: 1)
        view.setPlaylistArtwork(makePreviewArtwork(color: .systemPink), for: "favorites")
        view.setPlaylistArtwork(makePreviewArtwork(color: .systemBrown), for: "jay")
        view.setPlaylistArtwork(makePreviewArtwork(color: .systemIndigo), for: "night")

        let tracks = [
            ("夜曲", "11月的萧邦", "周杰伦"),
            ("发如雪", "11月的萧邦", "周杰伦"),
            ("黑色毛衣", "11月的萧邦", "周杰伦"),
            ("枫", "11月的萧邦", "周杰伦"),
            ("浪漫手机", "11月的萧邦", "周杰伦"),
            ("珊瑚海", "11月的萧邦", "周杰伦")
        ].enumerated().map { index, values in
            LibraryTrackSnapshot(
                id: "preview-\(index)",
                title: values.0,
                album: values.1,
                artist: values.2,
                artworkURL: nil
            )
        }
        view.setTracks(tracks)
        view.setCurrentTrack(TrackSnapshot(
            title: "发如雪",
            artist: "周杰伦",
            album: "11月的萧邦",
            duration: 292,
            position: 221,
            state: .playing,
            embeddedLyrics: ""
        ))
        view.setTrackListMode(.horizontal)
        for track in tracks {
            view.setTrackArtwork(makePreviewArtwork(color: .systemBrown), for: track.id)
        }
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @MainActor
    func testRenderLyricsPopoverPreview() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["APPLE_MUSIC_BAR_LYRICS_PREVIEW"] else {
            throw XCTSkip("设置 APPLE_MUSIC_BAR_LYRICS_PREVIEW 后渲染歌词面板预览")
        }

        _ = NSApplication.shared
        let view = PlayerPopoverView()
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.updateLocalization(.simplifiedChinese)
        view.updatePlaybackAccessibility(
            previous: "上一首",
            play: "播放",
            pause: "暂停",
            next: "下一首",
            showLyrics: "查看歌词",
            hideLyrics: "关闭歌词"
        )
        view.updateNowPlaying(
            title: "浪漫手机",
            subtitle: "周杰伦",
            isPlaying: true,
            controlsEnabled: true,
            position: 18,
            duration: 292
        )
        view.setNowPlayingArtwork(makePreviewArtwork(color: .systemBrown))
        view.setPlaylists([
            LibraryPlaylistSnapshot(id: "one", name: "我喜欢的音乐", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "two", name: "11月的萧邦", artworkURL: nil),
            LibraryPlaylistSnapshot(id: "three", name: "深夜播放", artworkURL: nil)
        ], selectedIndex: 1)
        view.setLyricsTimeline(LyricsTimeline(
            lines: [
                LyricLine(time: 0, text: "想要有直升机"),
                LyricLine(time: 6, text: "想要和你飞到宇宙去"),
                LyricLine(time: 14, text: "想要和你融化在一起"),
                LyricLine(time: 22, text: "融化在银河里"),
                LyricLine(time: 30, text: "我每天每天每天在想想想想着你"),
                LyricLine(time: 40, text: "这样的甜蜜让我开始相信命运")
            ],
            source: .lrclibSynced
        ))
        view.updateLyricsPosition(18)
        view.setLyricsVisible(true)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @MainActor
    private func makePreviewArtwork() -> NSImage {
        makePreviewArtwork(color: NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.10, alpha: 1))
    }

    @MainActor
    private func makePreviewArtwork(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 88, height: 88))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        NSColor(calibratedWhite: 0.85, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 29, y: 29, width: 30, height: 30)).fill()
        image.unlockFocus()
        return image
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
