import AppKit
import QuartzCore

enum TrackListDisplayMode: String, CaseIterable {
    case off
    case vertical
    case horizontal

    private static let defaultsKey = "trackListDisplayMode"
    private static let legacyVisibilityKey = "showTrackList"

    static func load(from defaults: UserDefaults = .standard) -> TrackListDisplayMode {
        if
            let rawValue = defaults.string(forKey: defaultsKey),
            let mode = TrackListDisplayMode(rawValue: rawValue)
        {
            return mode
        }
        return defaults.bool(forKey: legacyVisibilityKey) ? .vertical : .off
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyVisibilityKey)
    }

    var localizationKey: AppStringKey {
        switch self {
        case .off: return .trackListOff
        case .vertical: return .trackListVertical
        case .horizontal: return .trackListHorizontal
        }
    }
}

@MainActor
final class PlayerPopoverView: NSView {
    var onTrackListToggle: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onPlaylistFocused: ((Int) -> Void)?
    var onPlaylistActivated: ((Int) -> Void)?
    var onTrackSelected: ((LibraryTrackSnapshot, Int) -> Void)?
    var onVisibleTrackIDsChange: (([String]) -> Void)?
    var onReloadLibrary: (() -> Void)?
    var onPreferredSizeChange: ((NSSize) -> Void)?

    static let panelWidth: CGFloat = 252
    private static let carouselHeight: CGFloat = 126
    private static let nowPlayingHeight: CGFloat = 126
    private static let verticalTrackListHeight: CGFloat = 286
    private static let horizontalTrackListHeight: CGFloat = 154
    private static let lyricsHeight: CGFloat = 286

    private let stackView = NSStackView()
    private let carouselContainer = NSView()
    private let carouselView = PlaylistCarouselView()
    private let libraryStatusStack = NSStackView()
    private let libraryStatusLabel = NSTextField(labelWithString: "")
    private let reloadButton = NSButton()
    private let nowPlayingView = NowPlayingMenuView()
    private let trackListView = PlaylistTrackListView()
    private let horizontalTrackListView = TrackCarouselView()
    private let lyricsView = LyricsPanelView()

    private var language = AppLanguage.load()
    private var playlists: [LibraryPlaylistSnapshot] = []
    private var tracks: [LibraryTrackSnapshot] = []
    private var libraryStatusKey: AppStringKey?
    private var libraryCanRetry = false
    private var trackStatusKey: AppStringKey?
    private var currentTrack: TrackSnapshot?
    private var currentLyricsTimeline: LyricsTimeline?
    private var currentLyricsPosition: TimeInterval = 0
    private var lyricsNeedsRender = true
    private var lyricsPlaceholderKey: AppStringKey = .lyricsUnavailable
    private(set) var trackListMode: TrackListDisplayMode = .off
    private(set) var isLyricsVisible = false
    private var isSurfaceActive = false
    private var lastVisibleTrackIDs: [String] = []
    private let trackArtworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    private var preferredSize: NSSize {
        let baseHeight = Self.carouselHeight + Self.nowPlayingHeight
        let contentHeight: CGFloat
        if isLyricsVisible {
            contentHeight = Self.lyricsHeight
        } else {
            switch trackListMode {
            case .off: contentHeight = 0
            case .vertical: contentHeight = Self.verticalTrackListHeight
            case .horizontal: contentHeight = Self.horizontalTrackListHeight
            }
        }
        return NSSize(width: Self.panelWidth, height: baseHeight + contentHeight)
    }

    override var intrinsicContentSize: NSSize { preferredSize }

    var visiblePlaylistIDs: [String] { carouselView.visiblePlaylistIDs }
    var focusedPlaylistIndex: Int? { carouselView.selectedIndex }
    var displayedTrackCount: Int {
        switch trackListMode {
        case .vertical: return trackListView.trackCount
        case .horizontal: return horizontalTrackListView.trackCount
        case .off: return tracks.count
        }
    }
    var renderedVerticalTrackRowCount: Int { trackListView.renderedRowCount }
    var isTrackListVisible: Bool { trackListMode != .off }
    var displayedLyricLineCount: Int { lyricsView.lineCount }
    var currentLyricText: String? { lyricsView.currentLineText }

    init() {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.panelWidth, height: 252)))
        configureViews()
        configureLayout()
        connectActions()
        updateLocalization(language)
        updatePreferredSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateNowPlaying(
        title: String,
        subtitle: String,
        isPlaying: Bool,
        controlsEnabled: Bool,
        position: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        nowPlayingView.update(
            title: title,
            subtitle: subtitle,
            isPlaying: isPlaying,
            controlsEnabled: controlsEnabled,
            position: position,
            duration: duration
        )
    }

    func updatePlaybackPosition(_ position: TimeInterval, duration: TimeInterval) {
        nowPlayingView.updatePlaybackPosition(position, duration: duration)
    }

    func setSurfaceActive(_ active: Bool) {
        guard isSurfaceActive != active else { return }
        isSurfaceActive = active
        nowPlayingView.setActive(active)
        notifyVisibleTrackIDs()
    }

    func setNowPlayingArtwork(_ image: NSImage?) {
        nowPlayingView.setArtwork(image)
    }

    func updatePlaybackAccessibility(
        previous: String,
        play: String,
        pause: String,
        next: String,
        showLyrics: String = "Show Lyrics",
        hideLyrics: String = "Hide Lyrics",
        showTrackList: String = "Show Song List",
        hideTrackList: String = "Hide Song List"
    ) {
        nowPlayingView.updateAccessibility(
            previous: previous,
            play: play,
            pause: pause,
            next: next,
            showLyrics: showLyrics,
            hideLyrics: hideLyrics,
            showTrackList: showTrackList,
            hideTrackList: hideTrackList
        )
    }

    func setCurrentTrack(_ track: TrackSnapshot?) {
        currentTrack = track
        updateCurrentTrackSelection()
        horizontalTrackListView.setPlaybackState(track?.state == .playing)
    }

    func setLyricsLoading() {
        currentLyricsTimeline = nil
        lyricsPlaceholderKey = .loadingLyrics
        lyricsNeedsRender = true
        renderLyricsIfVisible()
    }

    func setLyricsTimeline(_ timeline: LyricsTimeline?) {
        currentLyricsTimeline = timeline
        lyricsPlaceholderKey = .lyricsUnavailable
        lyricsNeedsRender = true
        renderLyricsIfVisible()
    }

    func updateLyricsPosition(_ position: TimeInterval) {
        currentLyricsPosition = position
        if isLyricsVisible {
            lyricsView.updatePosition(position)
        }
    }

    func setLyricsVisible(_ visible: Bool) {
        guard visible != isLyricsVisible else { return }
        isLyricsVisible = visible
        renderLyricsIfVisible()
        nowPlayingView.setLyricsVisible(visible)
        applyContentModeChange()
    }

    func setLibraryState(_ key: AppStringKey, canRetry: Bool) {
        libraryStatusKey = key
        libraryCanRetry = canRetry
        carouselView.isHidden = true
        libraryStatusStack.isHidden = false
        renderLibraryStatus()
    }

    func setPlaylists(_ playlists: [LibraryPlaylistSnapshot], selectedIndex: Int) {
        self.playlists = playlists
        libraryStatusKey = nil
        carouselView.isHidden = false
        libraryStatusStack.isHidden = true
        carouselView.update(
            playlists: playlists,
            selectedIndex: selectedIndex,
            language: language
        )
    }

    func focusPlaylist(at index: Int) {
        carouselView.select(index: index, notify: false)
    }

    func restorePlaybackFocus() {
        horizontalTrackListView.focusCurrentTrack()
        trackListView.scrollToCurrentTrack()
    }

    func setPlaylistArtwork(_ image: NSImage?, for playlistID: String) {
        carouselView.setArtwork(image, for: playlistID)
    }

    func setTrackState(_ key: AppStringKey) {
        tracks = []
        trackStatusKey = key
        trackArtworkCache.removeAllObjects()
        renderActiveTrackList()
        updateCurrentTrackSelection()
    }

    func setTracks(_ tracks: [LibraryTrackSnapshot]) {
        if tracks.map(\.id) != self.tracks.map(\.id) {
            trackArtworkCache.removeAllObjects()
        }
        self.tracks = tracks
        trackStatusKey = tracks.isEmpty ? .emptyTracks : nil
        renderActiveTrackList()
        updateCurrentTrackSelection()
    }

    func hideTracks() {
        tracks = []
        trackStatusKey = nil
        trackArtworkCache.removeAllObjects()
        trackListView.update(tracks: [], placeholder: "", language: language)
        horizontalTrackListView.update(tracks: [], placeholder: "", language: language)
        notifyVisibleTrackIDs()
        updateCurrentTrackSelection()
    }

    func setTrackArtwork(_ image: NSImage?, for trackID: String) {
        let key = trackID as NSString
        if let image {
            let pixelCost = max(
                1,
                Int(image.size.width * image.size.height * 4)
            )
            trackArtworkCache.setObject(image, forKey: key, cost: pixelCost)
        } else {
            trackArtworkCache.removeObject(forKey: key)
        }
        trackListView.setArtwork(image, for: trackID)
        horizontalTrackListView.setArtwork(image, for: trackID)
    }

    func setTrackListMode(_ mode: TrackListDisplayMode) {
        guard mode != trackListMode else { return }
        trackListMode = mode
        renderActiveTrackList()
        applyContentModeChange()
        notifyVisibleTrackIDs()
    }

    func setTrackListVisible(_ visible: Bool) {
        setTrackListMode(visible ? .vertical : .off)
    }

    func updateLocalization(_ language: AppLanguage) {
        self.language = language
        reloadButton.title = language.localized(.reloadLibrary)
        renderLibraryStatus()

        if !playlists.isEmpty, let selectedIndex = carouselView.selectedIndex {
            carouselView.update(
                playlists: playlists,
                selectedIndex: selectedIndex,
                language: language
            )
        }
        renderActiveTrackList()
        lyricsNeedsRender = true
        renderLyricsIfVisible()
        updateCurrentTrackSelection()
    }

    private func configureViews() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 0
        addSubview(stackView)

        [
            carouselContainer,
            nowPlayingView,
            trackListView,
            horizontalTrackListView,
            lyricsView
        ].forEach {
            stackView.addArrangedSubview($0)
        }

        carouselContainer.translatesAutoresizingMaskIntoConstraints = false
        carouselView.translatesAutoresizingMaskIntoConstraints = false
        carouselContainer.addSubview(carouselView)

        libraryStatusStack.translatesAutoresizingMaskIntoConstraints = false
        libraryStatusStack.orientation = .vertical
        libraryStatusStack.alignment = .centerX
        libraryStatusStack.spacing = 8
        carouselContainer.addSubview(libraryStatusStack)

        libraryStatusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        libraryStatusLabel.textColor = .secondaryLabelColor
        libraryStatusLabel.alignment = .center
        libraryStatusLabel.maximumNumberOfLines = 2
        libraryStatusStack.addArrangedSubview(libraryStatusLabel)

        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .small
        reloadButton.font = .systemFont(ofSize: 11, weight: .medium)
        libraryStatusStack.addArrangedSubview(reloadButton)

        trackListView.translatesAutoresizingMaskIntoConstraints = false
        trackListView.isHidden = true
        horizontalTrackListView.translatesAutoresizingMaskIntoConstraints = false
        horizontalTrackListView.isHidden = true
        lyricsView.translatesAutoresizingMaskIntoConstraints = false
        lyricsView.isHidden = true
        libraryStatusStack.isHidden = true
    }

    private func configureLayout() {
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            carouselContainer.widthAnchor.constraint(equalToConstant: 240),
            carouselContainer.heightAnchor.constraint(equalToConstant: Self.carouselHeight),
            carouselView.leadingAnchor.constraint(equalTo: carouselContainer.leadingAnchor),
            carouselView.trailingAnchor.constraint(equalTo: carouselContainer.trailingAnchor),
            carouselView.topAnchor.constraint(equalTo: carouselContainer.topAnchor),
            carouselView.bottomAnchor.constraint(equalTo: carouselContainer.bottomAnchor),
            libraryStatusStack.centerXAnchor.constraint(equalTo: carouselContainer.centerXAnchor),
            libraryStatusStack.centerYAnchor.constraint(equalTo: carouselContainer.centerYAnchor),
            libraryStatusStack.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            trackListView.widthAnchor.constraint(equalToConstant: 240),
            trackListView.heightAnchor.constraint(equalToConstant: Self.verticalTrackListHeight),
            horizontalTrackListView.widthAnchor.constraint(equalToConstant: 240),
            horizontalTrackListView.heightAnchor.constraint(equalToConstant: Self.horizontalTrackListHeight),
            lyricsView.widthAnchor.constraint(equalToConstant: 240),
            lyricsView.heightAnchor.constraint(equalToConstant: Self.lyricsHeight)
        ])
    }

    private func connectActions() {
        nowPlayingView.onTrackListToggle = { [weak self] in
            guard let self else { return }
            if self.isLyricsVisible {
                if self.trackListMode == .off {
                    self.onTrackListToggle?()
                }
                self.setLyricsVisible(false)
                return
            }
            self.onTrackListToggle?()
        }
        nowPlayingView.onPrevious = { [weak self] in self?.onPrevious?() }
        nowPlayingView.onPlayPause = { [weak self] in self?.onPlayPause?() }
        nowPlayingView.onNext = { [weak self] in self?.onNext?() }
        nowPlayingView.onSeek = { [weak self] position in self?.onSeek?(position) }
        nowPlayingView.onLyricsToggle = { [weak self] in
            guard let self else { return }
            self.setLyricsVisible(!self.isLyricsVisible)
        }

        reloadButton.target = self
        reloadButton.action = #selector(reloadLibrary)

        carouselView.onSelectionChanged = { [weak self] index in
            self?.onPlaylistFocused?(index)
        }
        carouselView.onActivate = { [weak self] index in
            self?.onPlaylistActivated?(index)
        }
        trackListView.onTrackSelected = { [weak self] track, index in
            self?.onTrackSelected?(track, index)
        }
        trackListView.onVisibleTrackIDsChange = { [weak self] _ in
            self?.notifyVisibleTrackIDs()
        }
        horizontalTrackListView.onTrackSelected = { [weak self] track, index in
            self?.onTrackSelected?(track, index)
        }
        horizontalTrackListView.onVisibleTrackIDsChange = { [weak self] _ in
            self?.notifyVisibleTrackIDs()
        }
        let artworkProvider: (String) -> NSImage? = { [weak self] trackID in
            self?.trackArtworkCache.object(forKey: trackID as NSString)
        }
        trackListView.artworkProvider = artworkProvider
        horizontalTrackListView.artworkProvider = artworkProvider
        horizontalTrackListView.onPlayPause = { [weak self] in
            self?.onPlayPause?()
        }
    }

    private func renderLibraryStatus() {
        guard let libraryStatusKey else { return }
        libraryStatusLabel.stringValue = language.localized(libraryStatusKey)
        reloadButton.isHidden = !libraryCanRetry
    }

    private func renderLyrics() {
        lyricsView.update(
            timeline: currentLyricsTimeline,
            placeholder: language.localized(lyricsPlaceholderKey),
            language: language
        )
        lyricsView.updatePosition(currentLyricsPosition)
        lyricsNeedsRender = false
    }

    private func renderLyricsIfVisible() {
        guard isLyricsVisible, lyricsNeedsRender else { return }
        renderLyrics()
    }

    private func updateContentVisibility() {
        lyricsView.isHidden = !isLyricsVisible
        trackListView.isHidden = isLyricsVisible || trackListMode != .vertical
        horizontalTrackListView.isHidden = isLyricsVisible || trackListMode != .horizontal
        nowPlayingView.setTrackListVisible(!isLyricsVisible && trackListMode != .off)
        notifyVisibleTrackIDs()
    }

    private func renderActiveTrackList() {
        let placeholder = trackStatusKey.map { language.localized($0) } ?? ""
        switch trackListMode {
        case .off:
            trackListView.update(tracks: [], placeholder: "", language: language)
            horizontalTrackListView.update(tracks: [], placeholder: "", language: language)
        case .vertical:
            horizontalTrackListView.update(tracks: [], placeholder: "", language: language)
            trackListView.update(tracks: tracks, placeholder: placeholder, language: language)
        case .horizontal:
            trackListView.update(tracks: [], placeholder: "", language: language)
            horizontalTrackListView.update(
                tracks: tracks,
                placeholder: placeholder,
                language: language
            )
        }
        notifyVisibleTrackIDs()
    }

    private func notifyVisibleTrackIDs() {
        let ids: [String]
        if !isSurfaceActive || isLyricsVisible {
            ids = []
        } else {
            switch trackListMode {
            case .off: ids = []
            case .vertical: ids = trackListView.visibleTrackIDs
            case .horizontal: ids = horizontalTrackListView.visibleTrackIDs
            }
        }
        let uniqueIDs = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard uniqueIDs != lastVisibleTrackIDs else { return }
        lastVisibleTrackIDs = uniqueIDs
        for id in uniqueIDs {
            if let image = trackArtworkCache.object(forKey: id as NSString) {
                trackListView.setArtwork(image, for: id)
                horizontalTrackListView.setArtwork(image, for: id)
            }
        }
        onVisibleTrackIDsChange?(uniqueIDs)
    }

    private func applyContentModeChange() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            updateContentVisibility()
            layoutSubtreeIfNeeded()
            updatePreferredSize()
            layoutSubtreeIfNeeded()
        }
    }

    private func updateCurrentTrackSelection() {
        let currentTrackID = currentTrack.flatMap { current in
            tracks.first { candidate in
                guard TrackMetadataMatcher.equivalent(candidate.title, current.title) else {
                    return false
                }
                let artistMatches = current.artist.isEmpty
                    || TrackMetadataMatcher.equivalent(candidate.artist, current.artist)
                let albumMatches = current.album.isEmpty
                    || candidate.album.isEmpty
                    || TrackMetadataMatcher.equivalent(candidate.album, current.album)
                return artistMatches && albumMatches
            }?.id
        }
        trackListView.setCurrentTrackID(currentTrackID)
        horizontalTrackListView.setCurrentTrackID(currentTrackID)
    }

    private func updatePreferredSize() {
        let size = preferredSize
        invalidateIntrinsicContentSize()
        onPreferredSizeChange?(size)
    }

    @objc private func reloadLibrary() {
        onReloadLibrary?()
    }
}

@MainActor
final class ActivatingSearchTextView: NSTextView {
    var onPrepareForTextInput: (() -> Void)?
    var onSubmit: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPrepareForTextInput?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onPrepareForTextInput?()
        return super.becomeFirstResponder()
    }

    override func insertNewline(_ sender: Any?) {
        onSubmit?()
    }
}

@MainActor
final class SongSearchInputView: NSView, NSTextViewDelegate {
    var onCommittedTextChange: (() -> Void)?

    let textView = ActivatingSearchTextView()
    private let searchIconView = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var textChangeRevision = 0
    private var preferredInputSource: NSTextInputSourceIdentifier?
    private var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearanceAndInput()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            updatePlaceholderVisibility()
        }
    }

    var placeholderString: String? {
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue ?? "" }
    }

    var isInputEnabled: Bool {
        get { textView.isEditable }
        set {
            textView.isEditable = newValue
            textView.isSelectable = newValue
            searchIconView.alphaValue = newValue ? 1 : 0.45
            placeholderLabel.alphaValue = newValue ? 1 : 0.45
        }
    }

    var isPlaceholderVisible: Bool { !placeholderLabel.isHidden }

    override func layout() {
        super.layout()
        searchIconView.frame = NSRect(
            x: 2,
            y: max(0, (bounds.height - 14) / 2),
            width: 14,
            height: 14
        )
        let textFrame = NSRect(
            x: 21,
            y: max(0, (bounds.height - 19) / 2),
            width: max(0, bounds.width - 21),
            height: 19
        )
        placeholderLabel.frame = textFrame
        textView.frame = textFrame
    }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    func textDidBeginEditing(_ notification: Notification) {
        isEditing = true
        updatePlaceholderVisibility()
        prepareWindowForTextInput()
        configureTextView()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate()
            self.window?.makeKey()
            self.configureTextView()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        isEditing = false
        preferredInputSource = nil
        updatePlaceholderVisibility()
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
        textChangeRevision += 1
        let revision = textChangeRevision
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.textChangeRevision == revision,
                SearchCompositionState.shouldApplyChange(in: self.textView)
            else { return }
            self.onCommittedTextChange?()
        }
    }

    func applyCurrentText() {
        textChangeRevision += 1
        guard SearchCompositionState.shouldApplyChange(in: textView) else { return }
        onCommittedTextChange?()
    }

    @discardableResult
    func beginEditing() -> Bool {
        prepareWindowForTextInput()
        let accepted = window?.makeFirstResponder(textView) ?? false
        configureTextView()
        return accepted
    }

    private func configureAppearanceAndInput() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        searchIconView.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        searchIconView.contentTintColor = .secondaryLabelColor
        searchIconView.imageScaling = .scaleProportionallyDown
        addSubview(searchIconView)

        placeholderLabel.font = .systemFont(ofSize: 11, weight: .regular)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.lineBreakMode = .byTruncatingTail
        addSubview(placeholderLabel)

        textView.font = .systemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = AppVisualStyle.emphasisColor
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 19)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 19)
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.delegate = self
        textView.onPrepareForTextInput = { [weak self] in
            self?.prepareWindowForTextInput()
        }
        textView.onSubmit = { [weak self] in self?.applyCurrentText() }
        addSubview(textView)
        configureTextView()
        updatePlaceholderVisibility()
    }

    private func prepareWindowForTextInput() {
        if preferredInputSource == nil {
            preferredInputSource = NSTextInputContext.current?.selectedKeyboardInputSource
        }
        NSApp.activate()
        window?.makeKey()
    }

    private func configureTextView() {
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.wantsLayer = true
        textView.layer?.backgroundColor = NSColor.clear.cgColor
        textView.insertionPointColor = AppVisualStyle.emphasisColor
        textView.allowedInputSourceLocales = nil
        if
            let preferredInputSource,
            let inputContext = textView.inputContext,
            inputContext.keyboardInputSources?.contains(preferredInputSource) != false
        {
            inputContext.selectedKeyboardInputSource = preferredInputSource
        }
        textView.inputContext?.invalidateCharacterCoordinates()
        textView.updateInsertionPointStateAndRestartTimer(true)
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = isEditing
            || textView.hasMarkedText()
            || !textView.string.isEmpty
    }
}

@MainActor
private final class TrackCarouselView: NSView {
    var onTrackSelected: ((LibraryTrackSnapshot, Int) -> Void)?
    var onPlayPause: (() -> Void)?
    var onVisibleTrackIDsChange: (([String]) -> Void)?
    var artworkProvider: ((String) -> NSImage?)?

    private let farLeftCard = TrackCarouselCard()
    private let leftCard = TrackCarouselCard()
    private let centerCard = TrackCarouselCard()
    private let rightCard = TrackCarouselCard()
    private let farRightCard = TrackCarouselCard()
    private let searchField = SongSearchInputView()
    private let placeholderLabel = NSTextField(labelWithString: "")

    private var allTracks: [LibraryTrackSnapshot] = []
    private var tracks: [LibraryTrackSnapshot] = []
    private var originalTrackIndexes: [Int] = []
    private var sourcePlaceholder = ""
    private var language = AppLanguage.load()
    private var currentTrackID: String?
    private var isCurrentTrackPlaying = false
    private var selectedIndex: Int?
    private var continuousOffset: CGFloat = 0
    private var isInteracting = false
    private var isAnimating = false
    private var settleTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?

    private let slotSpacing: CGFloat = 85
    private let centerX: CGFloat = 120

    private var cardSlots: [(card: TrackCarouselCard, relativePosition: Int)] {
        [
            (farLeftCard, -2),
            (leftCard, -1),
            (centerCard, 0),
            (rightCard, 1),
            (farRightCard, 2)
        ]
    }

    var trackCount: Int { tracks.count }
    var visibleTrackIDs: [String] {
        cardSlots.compactMap { card, _ in
            guard !card.isHidden, tracks.indices.contains(card.tag) else { return nil }
            return tracks[card.tag].id
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 154))
        wantsLayer = true
        layer?.masksToBounds = true
        cardSlots.forEach {
            addSubview($0.card)
            $0.card.target = self
            $0.card.action = #selector(cardPressed(_:))
        }
        searchField.onCommittedTextChange = { [weak self] in
            self?.searchChanged()
        }
        addSubview(searchField)
        placeholderLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 2
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        tracks: [LibraryTrackSnapshot],
        placeholder: String,
        language: AppLanguage
    ) {
        let previouslySelectedID = selectedIndex.flatMap { index in
            self.tracks.indices.contains(index) ? self.tracks[index].id : nil
        }
        let playlistChanged = tracks.map(\.id) != allTracks.map(\.id)
        allTracks = tracks
        sourcePlaceholder = placeholder
        self.language = language
        if playlistChanged {
            searchField.stringValue = ""
        }
        searchField.placeholderString = language.localized(.searchSongs)
        searchField.isInputEnabled = !tracks.isEmpty
        applySearch(preferredTrackID: previouslySelectedID)
    }

    private func applySearch(preferredTrackID: String?) {
        let indexedTracks = allTracks.enumerated().filter { _, track in
            TrackSearchFilter.matches(track, query: searchField.stringValue, language: language)
        }
        tracks = indexedTracks.map(\.element)
        originalTrackIndexes = indexedTracks.map(\.offset)
        selectedIndex = currentTrackID.flatMap { id in
            tracks.firstIndex { $0.id == id }
        } ?? preferredTrackID.flatMap { id in
            tracks.firstIndex { $0.id == id }
        } ?? (tracks.isEmpty ? nil : 0)
        continuousOffset = 0
        settleTask?.cancel()
        animationTask?.cancel()
        isInteracting = false
        isAnimating = false
        if allTracks.isEmpty {
            placeholderLabel.stringValue = sourcePlaceholder
        } else if tracks.isEmpty {
            placeholderLabel.stringValue = language.localized(.noSearchResults)
        } else {
            placeholderLabel.stringValue = ""
        }
        placeholderLabel.isHidden = !tracks.isEmpty
        renderCards()
    }

    func setArtwork(_ image: NSImage?, for trackID: String) {
        guard visibleTrackIDs.contains(trackID), !isAnimating else { return }
        renderCards()
    }

    func setCurrentTrackID(_ trackID: String?) {
        guard currentTrackID != trackID else { return }
        currentTrackID = trackID
        if
            let trackID,
            let index = tracks.firstIndex(where: { $0.id == trackID })
        {
            selectedIndex = index
            continuousOffset = 0
        }
        renderCards()
    }

    func setPlaybackState(_ isPlaying: Bool) {
        guard isCurrentTrackPlaying != isPlaying else { return }
        isCurrentTrackPlaying = isPlaying
        renderCards()
    }

    func focusCurrentTrack() {
        guard
            let currentTrackID,
            let index = tracks.firstIndex(where: { $0.id == currentTrackID })
        else { return }
        settleTask?.cancel()
        animationTask?.cancel()
        selectedIndex = index
        continuousOffset = 0
        isInteracting = false
        isAnimating = false
        renderCards()
    }

    override func layout() {
        super.layout()
        searchField.frame = NSRect(x: 6, y: bounds.height - 29, width: bounds.width - 12, height: 22)
        if !isInteracting, !isAnimating {
            layoutCards(at: continuousOffset)
        }
        placeholderLabel.frame = NSRect(
            x: 12,
            y: 42,
            width: max(0, bounds.width - 24),
            height: 42
        )
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
        let vertical = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard abs(horizontal) > abs(vertical), abs(horizontal) > 0.1 else {
            super.scrollWheel(with: event)
            return
        }

        if !isInteracting {
            animationTask?.cancel()
            settleTask?.cancel()
            isAnimating = false
            isInteracting = true
        }
        applyScrollDelta(horizontal * 0.92)
        scheduleSettle()
    }

    private func animateNavigate(by offset: Int) {
        guard !tracks.isEmpty, offset != 0 else { return }
        settleTask?.cancel()
        animationTask?.cancel()
        isInteracting = false
        isAnimating = true
        let distance = -CGFloat(offset) * slotSpacing
        let duration = 0.28 + 0.05 * Double(max(0, abs(offset) - 1))
        animationTask = Task { [weak self] in
            guard let self else { return }
            let frameCount = max(1, Int(duration * 60))
            var previousDistance: CGFloat = 0
            for frame in 1...frameCount {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(frame) / CGFloat(frameCount)
                let eased = 1 - pow(1 - progress, 3)
                let currentDistance = distance * eased
                self.applyScrollDelta(currentDistance - previousDistance)
                previousDistance = currentDistance
            }
            self.finishContinuousInteraction()
        }
    }

    private func settleCards() {
        settleTask?.cancel()
        animationTask?.cancel()
        guard !tracks.isEmpty else { return }

        if abs(continuousOffset) >= slotSpacing * 0.36 {
            if continuousOffset < 0 {
                advanceSelection(by: 1)
                continuousOffset += slotSpacing
            } else {
                advanceSelection(by: -1)
                continuousOffset -= slotSpacing
            }
            renderCards()
            layoutCards(at: continuousOffset)
        }

        isInteracting = false
        isAnimating = true
        let startOffset = continuousOffset
        animationTask = Task { [weak self] in
            guard let self else { return }
            let frameCount = 14
            for frame in 1...frameCount {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(frame) / CGFloat(frameCount)
                let eased = 1 - pow(1 - progress, 3)
                self.continuousOffset = startOffset * (1 - eased)
                self.layoutCards(at: self.continuousOffset)
            }
            self.continuousOffset = 0
            self.finishContinuousInteraction()
        }
    }

    private func finishContinuousInteraction() {
        isAnimating = false
        isInteracting = false
        continuousOffset = 0
        renderCards()
        layoutCards(at: 0)
        needsLayout = true
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(85))
            guard !Task.isCancelled else { return }
            self?.settleCards()
        }
    }

    private func applyScrollDelta(_ delta: CGFloat) {
        guard !tracks.isEmpty else { return }
        continuousOffset += delta
        while continuousOffset <= -slotSpacing {
            advanceSelection(by: 1)
            continuousOffset += slotSpacing
            renderCards()
        }
        while continuousOffset >= slotSpacing {
            advanceSelection(by: -1)
            continuousOffset -= slotSpacing
            renderCards()
        }
        layoutCards(at: continuousOffset)
    }

    private func advanceSelection(by offset: Int) {
        guard let selectedIndex, !tracks.isEmpty else { return }
        self.selectedIndex = (
            selectedIndex + offset % tracks.count + tracks.count
        ) % tracks.count
    }

    private func layoutCards(at offset: CGFloat) {
        let progressOffset = offset / slotSpacing
        for (card, relativePosition) in cardSlots where !card.isHidden {
            let position = CGFloat(relativePosition) + progressOffset
            let distance = abs(position)
            let prominence = max(0, 1 - min(distance, 1))
            let width = 66 + 22 * prominence
            let height = 98 + 18 * prominence
            let x = centerX + position * slotSpacing - width / 2
            let y = 14 - 10 * prominence
            let outerFade = max(0, distance - 1)
            let opacity = max(0, 0.68 + 0.32 * prominence - 0.66 * outerFade)

            card.frame = NSRect(x: x, y: y, width: width, height: height)
            card.alphaValue = opacity
            card.updateProminence(prominence)
        }
    }

    private func renderCards() {
        guard let selectedIndex, !tracks.isEmpty else {
            cardSlots.forEach { $0.card.isHidden = true }
            onVisibleTrackIDsChange?([])
            return
        }
        for (card, relativePosition) in cardSlots {
            if tracks.count == 1, relativePosition != 0 {
                card.isHidden = true
                continue
            }
            if tracks.count == 3, abs(relativePosition) == 2 {
                card.isHidden = true
                continue
            }
            if tracks.count == 4, relativePosition == -2 {
                card.isHidden = true
                continue
            }

            let index = (
                selectedIndex + relativePosition % tracks.count + tracks.count
            ) % tracks.count
            let track = tracks[index]
            let position = CGFloat(relativePosition) + continuousOffset / slotSpacing
            let prominence = max(0, 1 - min(abs(position), 1))
            card.isHidden = false
            card.tag = index
            card.configure(
                track: track,
                image: artworkProvider?(track.id),
                prominence: prominence,
                isCurrent: track.id == currentTrackID,
                isPlaying: track.id == currentTrackID && isCurrentTrackPlaying,
                language: language
            )
        }
        layoutCards(at: continuousOffset)
        onVisibleTrackIDsChange?(visibleTrackIDs)
    }

    @objc private func cardPressed(_ sender: NSButton) {
        guard tracks.indices.contains(sender.tag), let selectedIndex else { return }
        if sender.tag == selectedIndex {
            if tracks[sender.tag].id == currentTrackID {
                onPlayPause?()
            } else {
                onTrackSelected?(tracks[sender.tag], originalTrackIndexes[sender.tag])
            }
        } else {
            let forward = (sender.tag - selectedIndex + tracks.count) % tracks.count
            let backward = forward - tracks.count
            animateNavigate(by: abs(backward) < abs(forward) ? backward : forward)
        }
    }

    private func searchChanged() {
        guard SearchCompositionState.shouldApplyChange(in: searchField.textView) else { return }
        let selectedID = selectedIndex.flatMap { index in
            tracks.indices.contains(index) ? tracks[index].id : nil
        }
        applySearch(preferredTrackID: selectedID)
    }
}

@MainActor
private final class NonInteractivePlayOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class TrackCarouselCard: NSButton {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let playOverlay = NonInteractivePlayOverlayView()
    private let playOverlayImage = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var prominence: CGFloat = 0
    private var isCurrent = false
    private var isPlaying = false
    private var isHovered = false
    private var displayedSymbolName: String?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous

        artworkView.imageScaling = .scaleAxesIndependently
        artworkView.wantsLayer = true
        artworkView.layer?.cornerCurve = .continuous
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(artworkView)

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        artistLabel.alignment = .center
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.textColor = .secondaryLabelColor
        addSubview(artistLabel)

        playOverlay.wantsLayer = true
        playOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        playOverlay.layer?.borderWidth = 0
        playOverlay.layer?.cornerCurve = .continuous
        playOverlay.isHidden = true
        playOverlay.setAccessibilityIdentifier("track-play-overlay")
        addSubview(playOverlay)
        playOverlayImage.imageScaling = .scaleProportionallyDown
        playOverlayImage.contentTintColor = .white
        playOverlayImage.wantsLayer = true
        playOverlayImage.layer?.shadowColor = NSColor.black.cgColor
        playOverlayImage.layer?.shadowOpacity = 0.6
        playOverlayImage.layer?.shadowRadius = 1.4
        playOverlayImage.layer?.shadowOffset = .zero
        playOverlay.addSubview(playOverlayImage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        track: LibraryTrackSnapshot,
        image: NSImage?,
        prominence: CGFloat,
        isCurrent: Bool,
        isPlaying: Bool,
        language: AppLanguage
    ) {
        titleLabel.stringValue = language.displayText(track.title)
        artistLabel.stringValue = language.displayText(track.artist)
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        if let image {
            artworkView.image = image
            artworkView.contentTintColor = nil
            artworkView.imageScaling = .scaleAxesIndependently
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .secondaryLabelColor
            artworkView.imageScaling = .scaleProportionallyDown
        }
        setAccessibilityLabel(
            [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        setAccessibilityHelp(language.localized(isPlaying ? .pause : .play))
        updateProminence(prominence)
        updateInteractionAppearance()
    }

    func updateProminence(_ prominence: CGFloat) {
        self.prominence = max(0, min(1, prominence))
        titleLabel.font = .systemFont(
            ofSize: 9 + 1.5 * self.prominence,
            weight: self.prominence > 0.55 ? .semibold : .medium
        )
        artistLabel.font = .systemFont(ofSize: 8.5 + self.prominence, weight: .medium)
        layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: bounds.width)
        updateInteractionAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let coverSize = 58 + 20 * prominence
        artworkView.frame = NSRect(
            x: (bounds.width - coverSize) / 2,
            y: 2,
            width: coverSize,
            height: coverSize
        )
        artworkView.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: coverSize)
        titleLabel.frame = NSRect(x: 0, y: coverSize + 6, width: bounds.width, height: 16)
        artistLabel.frame = NSRect(x: 0, y: coverSize + 21, width: bounds.width, height: 14)
        let overlaySize: CGFloat = 26
        playOverlay.frame = NSRect(
            x: (bounds.width - overlaySize) / 2,
            y: 2 + (coverSize - overlaySize) / 2,
            width: overlaySize,
            height: overlaySize
        )
        playOverlay.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: overlaySize)
        playOverlayImage.frame = playOverlay.bounds.insetBy(dx: 6, dy: 6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
        isHovered = true
        updateInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        isHovered = false
        updateInteractionAppearance()
    }

    private func updateInteractionAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        titleLabel.textColor = .labelColor
        let isCentered = prominence > 0.82
        playOverlay.isHidden = !isCentered || (!isHovered && !isCurrent)
        let symbolName = isCurrent && isPlaying ? "pause.fill" : "play.fill"
        if displayedSymbolName != symbolName {
            displayedSymbolName = symbolName
            playOverlayImage.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        }
    }
}

@MainActor
final class PlaylistCarouselView: NSView {
    var onSelectionChanged: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?

    private let farLeftCard = PlaylistCoverCard()
    private let leftCard = PlaylistCoverCard()
    private let centerCard = PlaylistCoverCard()
    private let rightCard = PlaylistCoverCard()
    private let farRightCard = PlaylistCoverCard()

    private var playlists: [LibraryPlaylistSnapshot] = []
    private var language = AppLanguage.load()
    private var artworkByID: [String: NSImage] = [:]
    private var continuousOffset: CGFloat = 0
    private var gestureStartIndex: Int?
    private var isInteracting = false
    private var isAnimating = false
    private var settleTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?

    private let slotSpacing: CGFloat = 85
    private let centerX: CGFloat = 120

    private var cardSlots: [(card: PlaylistCoverCard, relativePosition: Int)] {
        [
            (farLeftCard, -2),
            (leftCard, -1),
            (centerCard, 0),
            (rightCard, 1),
            (farRightCard, 2)
        ]
    }

    private(set) var selectedIndex: Int?

    var visiblePlaylistIDs: [String] {
        var result: [String] = []
        for (card, _) in cardSlots where !card.isHidden {
            guard let id = card.playlistID, !result.contains(id) else { continue }
            result.append(id)
        }
        return result
    }

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 126))
        wantsLayer = true
        layer?.masksToBounds = true
        cardSlots.forEach {
            addSubview($0.card)
            $0.card.target = self
            $0.card.action = #selector(cardPressed(_:))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        playlists: [LibraryPlaylistSnapshot],
        selectedIndex: Int,
        language: AppLanguage
    ) {
        self.playlists = playlists
        self.language = language
        self.selectedIndex = playlists.isEmpty
            ? nil
            : min(max(selectedIndex, 0), playlists.count - 1)
        continuousOffset = 0
        settleTask?.cancel()
        animationTask?.cancel()
        isInteracting = false
        isAnimating = false
        renderCards()
    }

    func setArtwork(_ image: NSImage?, for playlistID: String) {
        if let image {
            artworkByID[playlistID] = image
        } else {
            artworkByID.removeValue(forKey: playlistID)
        }
        if !isAnimating {
            renderCards()
        }
    }

    func select(index: Int, notify: Bool) {
        guard playlists.indices.contains(index) else { return }
        if selectedIndex == index {
            if !notify {
                settleTask?.cancel()
                animationTask?.cancel()
                continuousOffset = 0
                isInteracting = false
                isAnimating = false
                renderCards()
            }
            if notify { onSelectionChanged?(index) }
            return
        }
        selectedIndex = index
        continuousOffset = 0
        settleTask?.cancel()
        animationTask?.cancel()
        isInteracting = false
        isAnimating = false
        renderCards()
        if notify {
            onSelectionChanged?(index)
        }
    }

    func navigate(by offset: Int) {
        guard !playlists.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = (current + offset % playlists.count + playlists.count) % playlists.count
        select(index: next, notify: true)
    }

    override func layout() {
        super.layout()
        if !isInteracting, !isAnimating {
            layoutCards(at: continuousOffset)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
        let vertical = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard abs(horizontal) > abs(vertical), abs(horizontal) > 0.1 else {
            super.scrollWheel(with: event)
            return
        }

        if !isInteracting {
            animationTask?.cancel()
            settleTask?.cancel()
            isAnimating = false
            isInteracting = true
            gestureStartIndex = selectedIndex
        }
        applyScrollDelta(horizontal * 0.92)
        scheduleSettle()
    }

    private func animateNavigate(by offset: Int) {
        guard !playlists.isEmpty, offset != 0 else { return }
        settleTask?.cancel()
        animationTask?.cancel()
        gestureStartIndex = selectedIndex
        isInteracting = false
        isAnimating = true
        let distance = -CGFloat(offset) * slotSpacing
        let duration = 0.28 + 0.05 * Double(max(0, abs(offset) - 1))
        animationTask = Task { [weak self] in
            guard let self else { return }
            let frameCount = max(1, Int(duration * 60))
            var previousDistance: CGFloat = 0

            for frame in 1...frameCount {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(frame) / CGFloat(frameCount)
                let eased = 1 - pow(1 - progress, 3)
                let currentDistance = distance * eased
                self.applyScrollDelta(currentDistance - previousDistance)
                previousDistance = currentDistance
            }
            self.finishContinuousInteraction()
        }
    }

    private func settleCards() {
        settleTask?.cancel()
        animationTask?.cancel()
        guard !playlists.isEmpty else { return }

        if abs(continuousOffset) >= slotSpacing * 0.36 {
            if continuousOffset < 0 {
                advanceSelection(by: 1)
                continuousOffset += slotSpacing
            } else {
                advanceSelection(by: -1)
                continuousOffset -= slotSpacing
            }
            renderCards()
            layoutCards(at: continuousOffset)
        }

        isInteracting = false
        isAnimating = true
        notifySelectionIfNeeded()
        let startOffset = continuousOffset
        animationTask = Task { [weak self] in
            guard let self else { return }
            let frameCount = 14
            for frame in 1...frameCount {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(frame) / CGFloat(frameCount)
                let eased = 1 - pow(1 - progress, 3)
                self.continuousOffset = startOffset * (1 - eased)
                self.layoutCards(at: self.continuousOffset)
            }
            self.continuousOffset = 0
            self.finishContinuousInteraction(notify: false)
        }
    }

    private func finishContinuousInteraction(notify: Bool = true) {
        if notify {
            notifySelectionIfNeeded()
        }
        isAnimating = false
        isInteracting = false
        continuousOffset = 0
        renderCards()
        layoutCards(at: 0)
        needsLayout = true
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(85))
            guard !Task.isCancelled else { return }
            self?.settleCards()
        }
    }

    private func applyScrollDelta(_ delta: CGFloat) {
        guard !playlists.isEmpty else { return }
        continuousOffset += delta

        while continuousOffset <= -slotSpacing {
            advanceSelection(by: 1)
            continuousOffset += slotSpacing
            renderCards()
        }
        while continuousOffset >= slotSpacing {
            advanceSelection(by: -1)
            continuousOffset -= slotSpacing
            renderCards()
        }
        layoutCards(at: continuousOffset)
    }

    private func advanceSelection(by offset: Int) {
        guard let selectedIndex, !playlists.isEmpty else { return }
        self.selectedIndex = (
            selectedIndex + offset % playlists.count + playlists.count
        ) % playlists.count
    }

    private func notifySelectionIfNeeded() {
        guard let selectedIndex else { return }
        if gestureStartIndex != selectedIndex {
            onSelectionChanged?(selectedIndex)
        }
        gestureStartIndex = selectedIndex
    }

    private func layoutCards(at offset: CGFloat) {
        let progressOffset = offset / slotSpacing
        for (card, relativePosition) in cardSlots where !card.isHidden {
            let position = CGFloat(relativePosition) + progressOffset
            let distance = abs(position)
            let prominence = max(0, 1 - min(distance, 1))
            let width = 66 + 22 * prominence
            let height = 88 + 18 * prominence
            let x = centerX + position * slotSpacing - width / 2
            let y = 19 - 9 * prominence
            let outerFade = max(0, distance - 1)
            let opacity = max(0, 0.68 + 0.32 * prominence - 0.66 * outerFade)

            card.frame = NSRect(x: x, y: y, width: width, height: height)
            card.alphaValue = opacity
            card.updateProminence(prominence)
        }
    }

    private func renderCards() {
        guard let selectedIndex, !playlists.isEmpty else {
            cardSlots.forEach { $0.card.isHidden = true }
            return
        }

        for (card, relativePosition) in cardSlots {
            if playlists.count == 1, relativePosition != 0 {
                card.isHidden = true
                continue
            }
            if playlists.count == 3, abs(relativePosition) == 2 {
                card.isHidden = true
                continue
            }
            if playlists.count == 4, relativePosition == -2 {
                card.isHidden = true
                continue
            }

            let index = (
                selectedIndex + relativePosition % playlists.count + playlists.count
            ) % playlists.count
            let playlist = playlists[index]
            let position = CGFloat(relativePosition) + continuousOffset / slotSpacing
            let prominence = max(0, 1 - min(abs(position), 1))
            card.isHidden = false
            card.tag = index
            card.configure(
                playlistID: playlist.id,
                title: language.displayText(playlist.name),
                image: artworkByID[playlist.id],
                prominence: prominence,
                accessibilityAction: language.localized(.playPlaylist)
            )
        }
        layoutCards(at: continuousOffset)
    }

    @objc private func cardPressed(_ sender: NSButton) {
        guard playlists.indices.contains(sender.tag) else { return }
        if sender.tag == selectedIndex {
            onActivate?(sender.tag)
        } else {
            guard let current = selectedIndex else { return }
            let forward = (sender.tag - current + playlists.count) % playlists.count
            let backward = forward - playlists.count
            let offset = abs(backward) < abs(forward) ? backward : forward
            animateNavigate(by: offset)
        }
    }
}

@MainActor
private final class PlaylistCoverCard: NSButton {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private(set) var playlistID: String?
    private var prominence: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        wantsLayer = true

        artworkView.imageScaling = .scaleAxesIndependently
        artworkView.wantsLayer = true
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(artworkView)

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        playlistID: String,
        title: String,
        image: NSImage?,
        prominence: CGFloat,
        accessibilityAction: String
    ) {
        self.playlistID = playlistID
        titleLabel.stringValue = title

        if let image {
            artworkView.image = image
            artworkView.contentTintColor = nil
            artworkView.imageScaling = .scaleAxesIndependently
        } else {
            artworkView.image = NSImage(
                systemSymbolName: "music.note.list",
                accessibilityDescription: nil
            )
            artworkView.contentTintColor = .secondaryLabelColor
            artworkView.imageScaling = .scaleProportionallyDown
        }
        setAccessibilityLabel(title)
        setAccessibilityHelp(prominence > 0.5 ? accessibilityAction : "")
        updateProminence(prominence)
    }

    func updateProminence(_ prominence: CGFloat) {
        self.prominence = max(0, min(1, prominence))
        let pointSize = 9 + 1.5 * self.prominence
        titleLabel.font = .systemFont(
            ofSize: pointSize,
            weight: self.prominence > 0.55 ? .semibold : .medium
        )
        titleLabel.textColor = self.prominence > 0.45 ? .labelColor : .secondaryLabelColor
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let coverSize = 58 + 20 * prominence
        artworkView.frame = NSRect(
            x: (bounds.width - coverSize) / 2,
            y: 2,
            width: coverSize,
            height: coverSize
        )
        artworkView.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: coverSize)
        titleLabel.frame = NSRect(
            x: 0,
            y: coverSize + 6,
            width: bounds.width,
            height: 17 + 3 * prominence
        )
    }
}

enum TrackSearchFilter {
    static func matches(
        _ track: LibraryTrackSnapshot,
        query: String,
        language: AppLanguage
    ) -> Bool {
        let tokens = normalized(query).split(whereSeparator: \Character.isWhitespace)
        guard !tokens.isEmpty else { return true }

        let values = [track.title, track.artist, track.album]
        let searchableValues = values.flatMap { value in
            [value, language.displayText(value)]
        }.map(normalized)
        return tokens.allSatisfy { token in
            searchableValues.contains { $0.contains(token) }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
    }
}

enum SearchCompositionState {
    static func shouldApplyChange(in textView: NSTextView) -> Bool {
        shouldApplyChange(hasMarkedText: textView.hasMarkedText())
    }

    static func shouldApplyChange(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }
}

@MainActor
private final class PlaylistTrackListView: NSView {
    private let searchField = SongSearchInputView()
    private let songHeading = NSTextField(labelWithString: "")
    private let artistHeading = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let contentView = TrackListContentView()
    private var tracks: [LibraryTrackSnapshot] = []
    private var placeholder = ""
    private var language = AppLanguage.load()
    private var boundsObserver: NSObjectProtocol?

    var onTrackSelected: ((LibraryTrackSnapshot, Int) -> Void)? {
        didSet { contentView.onTrackSelected = onTrackSelected }
    }
    var onVisibleTrackIDsChange: (([String]) -> Void)? {
        didSet { contentView.onVisibleTrackIDsChange = onVisibleTrackIDsChange }
    }
    var artworkProvider: ((String) -> NSImage?)? {
        didSet { contentView.artworkProvider = artworkProvider }
    }

    var trackCount: Int { contentView.trackCount }
    var renderedRowCount: Int { contentView.renderedRowCount }
    var visibleTrackIDs: [String] { contentView.visibleTrackIDs }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 286))
        searchField.onCommittedTextChange = { [weak self] in
            self?.searchChanged()
        }
        addSubview(searchField)

        [songHeading, artistHeading].forEach {
            $0.font = .systemFont(ofSize: 10.5, weight: .semibold)
            $0.textColor = .secondaryLabelColor
            addSubview($0)
        }
        artistHeading.alignment = .right

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateVisibleRows()
            }
        }
        addSubview(scrollView)
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        tracks: [LibraryTrackSnapshot],
        placeholder: String,
        language: AppLanguage
    ) {
        let playlistChanged = tracks.map(\.id) != self.tracks.map(\.id)
        self.tracks = tracks
        self.placeholder = placeholder
        self.language = language
        if playlistChanged {
            searchField.stringValue = ""
        }
        searchField.placeholderString = language.localized(.searchSongs)
        searchField.isInputEnabled = !tracks.isEmpty
        songHeading.stringValue = language.localized(.songs)
        artistHeading.stringValue = language.localized(.artist)
        renderFilteredTracks()
        needsLayout = true
    }

    func setArtwork(_ image: NSImage?, for trackID: String) {
        contentView.setArtwork(image, for: trackID)
    }

    func setCurrentTrackID(_ trackID: String?) {
        contentView.setCurrentTrackID(trackID)
    }

    func scrollToCurrentTrack() {
        layoutSubtreeIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        guard let rowFrame = contentView.currentTrackFrame else { return }
        let clipView = scrollView.contentView
        let maximumY = max(0, contentView.bounds.height - clipView.bounds.height)
        let targetY = min(maximumY, max(0, rowFrame.midY - clipView.bounds.height / 2))
        clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        updateVisibleRows()
    }

    override func layout() {
        super.layout()
        searchField.frame = NSRect(x: 6, y: bounds.height - 29, width: bounds.width - 12, height: 22)
        songHeading.frame = NSRect(x: 7, y: bounds.height - 52, width: 150, height: 18)
        artistHeading.frame = NSRect(x: bounds.width - 72, y: bounds.height - 52, width: 64, height: 18)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 55)
        contentView.resize(to: scrollView.contentSize)
        updateVisibleRows()
    }

    private func renderFilteredTracks() {
        let indexedTracks = tracks.enumerated().compactMap { index, track in
            TrackSearchFilter.matches(track, query: searchField.stringValue, language: language)
                ? (index: index, track: track)
                : nil
        }
        let filteredPlaceholder: String
        if tracks.isEmpty {
            filteredPlaceholder = placeholder
        } else if indexedTracks.isEmpty {
            filteredPlaceholder = language.localized(.noSearchResults)
        } else {
            filteredPlaceholder = ""
        }
        contentView.update(
            indexedTracks: indexedTracks,
            placeholder: filteredPlaceholder,
            language: language
        )
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateVisibleRows()
    }

    private func searchChanged() {
        guard SearchCompositionState.shouldApplyChange(in: searchField.textView) else { return }
        renderFilteredTracks()
    }

    private func updateVisibleRows() {
        contentView.updateVisibleRows(in: scrollView.contentView.bounds)
    }
}

@MainActor
private final class TrackListContentView: NSView {
    private static let rowHeight: CGFloat = 52
    private static let overscanRows = 2
    private var indexedTracks: [(index: Int, track: LibraryTrackSnapshot)] = []
    private var rowsByPosition: [Int: TrackRowView] = [:]
    private var language = AppLanguage.load()
    private var lastVisibleRect = NSRect.zero
    private var lastNotifiedTrackIDs: [String] = []
    private var currentTrackID: String?
    private let placeholderLabel = NSTextField(labelWithString: "")

    var onTrackSelected: ((LibraryTrackSnapshot, Int) -> Void)?
    var onVisibleTrackIDsChange: (([String]) -> Void)?
    var artworkProvider: ((String) -> NSImage?)?

    override var isFlipped: Bool { true }
    var trackCount: Int { indexedTracks.count }
    var renderedRowCount: Int { rowsByPosition.count }
    var visibleTrackIDs: [String] {
        rowsByPosition.keys.sorted().compactMap { position in
            guard indexedTracks.indices.contains(position) else { return nil }
            return indexedTracks[position].track.id
        }
    }
    var currentTrackFrame: NSRect? {
        guard
            let currentTrackID,
            let position = indexedTracks.firstIndex(where: { $0.track.id == currentTrackID })
        else { return nil }
        return frameForRow(at: position)
    }

    init() {
        super.init(frame: .zero)
        placeholderLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 2
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        indexedTracks: [(index: Int, track: LibraryTrackSnapshot)],
        placeholder: String,
        language: AppLanguage
    ) {
        self.indexedTracks = indexedTracks
        self.language = language
        rowsByPosition.values.forEach { $0.removeFromSuperview() }
        rowsByPosition = [:]
        placeholderLabel.stringValue = placeholder
        placeholderLabel.isHidden = !indexedTracks.isEmpty
        lastNotifiedTrackIDs = []
        needsLayout = true
        resize(to: bounds.size)
        updateVisibleRows(in: lastVisibleRect)
    }

    func setArtwork(_ image: NSImage?, for trackID: String) {
        for (position, row) in rowsByPosition where indexedTracks.indices.contains(position) {
            if indexedTracks[position].track.id == trackID {
                row.setArtwork(image)
            }
        }
    }

    func setCurrentTrackID(_ trackID: String?) {
        currentTrackID = trackID
        for (position, row) in rowsByPosition where indexedTracks.indices.contains(position) {
            row.setCurrent(indexedTracks[position].track.id == trackID)
        }
    }

    func resize(to viewportSize: NSSize) {
        let height = max(viewportSize.height, CGFloat(indexedTracks.count) * Self.rowHeight)
        frame.size = NSSize(width: viewportSize.width, height: height)
        needsLayout = true
    }

    func updateVisibleRows(in visibleRect: NSRect) {
        lastVisibleRect = visibleRect
        guard !indexedTracks.isEmpty, visibleRect.width > 0, visibleRect.height > 0 else {
            rowsByPosition.values.forEach { $0.removeFromSuperview() }
            rowsByPosition = [:]
            notifyVisibleTracksIfNeeded()
            return
        }

        let firstVisible = max(0, Int(floor(visibleRect.minY / Self.rowHeight)))
        let lastVisible = min(
            indexedTracks.count - 1,
            Int(floor(max(visibleRect.minY, visibleRect.maxY - 1) / Self.rowHeight))
        )
        let lowerBound = max(0, firstVisible - Self.overscanRows)
        let upperBound = min(indexedTracks.count - 1, lastVisible + Self.overscanRows)
        let neededPositions = Set(lowerBound...upperBound)

        for position in Array(rowsByPosition.keys) where !neededPositions.contains(position) {
            rowsByPosition.removeValue(forKey: position)?.removeFromSuperview()
        }
        for position in lowerBound...upperBound where rowsByPosition[position] == nil {
            let item = indexedTracks[position]
            let row = TrackRowView()
            row.update(track: item.track, language: language)
            row.setArtwork(artworkProvider?(item.track.id))
            row.setCurrent(item.track.id == currentTrackID)
            row.onPlay = { [weak self] in
                self?.onTrackSelected?(item.track, item.index)
            }
            row.frame = frameForRow(at: position)
            addSubview(row, positioned: .below, relativeTo: placeholderLabel)
            rowsByPosition[position] = row
        }
        notifyVisibleTracksIfNeeded()
    }

    override func layout() {
        super.layout()
        for (position, row) in rowsByPosition {
            row.frame = frameForRow(at: position)
        }
        placeholderLabel.frame = NSRect(
            x: 12,
            y: max(0, (bounds.height - 42) / 2),
            width: max(0, bounds.width - 24),
            height: 42
        )
    }

    private func frameForRow(at position: Int) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(position) * Self.rowHeight,
            width: bounds.width,
            height: Self.rowHeight
        )
    }

    private func notifyVisibleTracksIfNeeded() {
        let ids = visibleTrackIDs
        guard ids != lastNotifiedTrackIDs else { return }
        lastNotifiedTrackIDs = ids
        onVisibleTrackIDsChange?(ids)
    }
}

@MainActor
private final class TrackRowView: NSButton {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let albumLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let playOverlay = NonInteractivePlayOverlayView()
    private let playOverlayImage = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isCurrent = false
    private var displayedSymbolName: String?

    var onPlay: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(playTrack)
        wantsLayer = true
        layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 52)
        layer?.cornerCurve = .continuous
        artworkView.imageScaling = .scaleAxesIndependently
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 38)
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(artworkView)

        playOverlay.wantsLayer = true
        playOverlay.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 24)
        playOverlay.layer?.cornerCurve = .continuous
        playOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        playOverlay.layer?.borderWidth = 0
        playOverlay.isHidden = true
        playOverlay.setAccessibilityIdentifier("track-play-overlay")
        addSubview(playOverlay)

        playOverlayImage.imageScaling = .scaleProportionallyDown
        playOverlayImage.contentTintColor = .white
        playOverlayImage.wantsLayer = true
        playOverlayImage.layer?.shadowColor = NSColor.black.cgColor
        playOverlayImage.layer?.shadowOpacity = 0.6
        playOverlayImage.layer?.shadowRadius = 1.4
        playOverlayImage.layer?.shadowOffset = .zero
        playOverlay.addSubview(playOverlayImage)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        albumLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        albumLabel.textColor = .secondaryLabelColor
        albumLabel.lineBreakMode = .byTruncatingTail
        addSubview(albumLabel)

        artistLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.alignment = .right
        artistLabel.lineBreakMode = .byTruncatingTail
        addSubview(artistLabel)

        separator.boxType = .separator
        addSubview(separator)
        setArtwork(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(track: LibraryTrackSnapshot, language: AppLanguage) {
        titleLabel.stringValue = language.displayText(track.title)
        albumLabel.stringValue = language.displayText(track.album)
        artistLabel.stringValue = language.displayText(track.artist)
        setAccessibilityLabel(
            [track.title, track.album, track.artist].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        setAccessibilityHelp(language.localized(.play))
    }

    func setArtwork(_ image: NSImage?) {
        if let image {
            artworkView.image = image
            artworkView.contentTintColor = nil
            artworkView.imageScaling = .scaleAxesIndependently
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .secondaryLabelColor
            artworkView.imageScaling = .scaleProportionallyDown
        }
    }

    func setCurrent(_ current: Bool) {
        guard current != isCurrent else { return }
        isCurrent = current
        updateInteractionAppearance()
    }

    override func layout() {
        super.layout()
        artworkView.frame = NSRect(x: 6, y: 7, width: 38, height: 38)
        playOverlay.frame = NSRect(x: 13, y: 14, width: 24, height: 24)
        playOverlayImage.frame = playOverlay.bounds.insetBy(dx: 5, dy: 5)
        let artistWidth: CGFloat = 62
        let mainX: CGFloat = 51
        let mainWidth = max(40, bounds.width - mainX - artistWidth - 13)
        titleLabel.frame = NSRect(x: mainX, y: 7, width: mainWidth, height: 18)
        albumLabel.frame = NSRect(x: mainX, y: 26, width: mainWidth, height: 16)
        artistLabel.frame = NSRect(
            x: bounds.width - artistWidth - 7,
            y: 17,
            width: artistWidth,
            height: 18
        )
        separator.frame = NSRect(x: mainX, y: bounds.height - 1, width: bounds.width - mainX, height: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
        isHovered = true
        updateInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        isHovered = false
        updateInteractionAppearance()
    }

    private func updateInteractionAppearance() {
        if isCurrent {
            layer?.backgroundColor = NSColor.secondaryLabelColor
                .withAlphaComponent(0.14)
                .cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        playOverlay.isHidden = !isHovered && !isCurrent
        let symbolName = isCurrent && !isHovered ? "speaker.wave.2.fill" : "play.fill"
        if displayedSymbolName != symbolName {
            displayedSymbolName = symbolName
            playOverlayImage.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        }
        titleLabel.textColor = .labelColor
    }

    @objc private func playTrack() {
        onPlay?()
    }
}

@MainActor
private final class HorizontalTrackListView: NSView {
    private let headingLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let contentView = HorizontalTrackContentView()

    var onTrackSelected: ((LibraryTrackSnapshot, Int) -> Void)? {
        didSet { contentView.onTrackSelected = onTrackSelected }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 138))
        headingLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        headingLabel.textColor = .secondaryLabelColor
        addSubview(headingLabel)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = contentView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        tracks: [LibraryTrackSnapshot],
        placeholder: String,
        language: AppLanguage
    ) {
        headingLabel.stringValue = language.localized(.songs)
        contentView.update(tracks: tracks, placeholder: placeholder, language: language)
        needsLayout = true
    }

    func setArtwork(_ image: NSImage?, for trackID: String) {
        contentView.setArtwork(image, for: trackID)
    }

    func setCurrentTrackID(_ trackID: String?) {
        contentView.setCurrentTrackID(trackID)
    }

    override func layout() {
        super.layout()
        headingLabel.frame = NSRect(x: 7, y: bounds.height - 22, width: 150, height: 18)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 24)
        contentView.resize(to: scrollView.contentSize)
    }
}

@MainActor
private final class HorizontalTrackContentView: NSView {
    private static let cardWidth: CGFloat = 88
    private static let cardSpacing: CGFloat = 7
    private var cards: [HorizontalTrackCard] = []
    private var cardsByID: [String: HorizontalTrackCard] = [:]
    private var artworkByID: [String: NSImage] = [:]
    private var currentTrackID: String?
    private let placeholderLabel = NSTextField(labelWithString: "")

    var onTrackSelected: ((LibraryTrackSnapshot, Int) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        placeholderLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 2
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        tracks: [LibraryTrackSnapshot],
        placeholder: String,
        language: AppLanguage
    ) {
        if !tracks.isEmpty {
            let visibleIDs = Set(tracks.map(\.id))
            artworkByID = artworkByID.filter { visibleIDs.contains($0.key) }
        }
        cards.forEach { $0.removeFromSuperview() }
        cards = tracks.enumerated().map { index, track in
            let card = HorizontalTrackCard()
            card.update(track: track, language: language)
            card.setArtwork(artworkByID[track.id])
            card.setCurrent(track.id == currentTrackID)
            card.onPlay = { [weak self] in
                self?.onTrackSelected?(track, index)
            }
            addSubview(card)
            return card
        }
        cardsByID = Dictionary(uniqueKeysWithValues: zip(tracks.map(\.id), cards))
        placeholderLabel.stringValue = placeholder
        placeholderLabel.isHidden = !tracks.isEmpty
        needsLayout = true
    }

    func setArtwork(_ image: NSImage?, for trackID: String) {
        if let image {
            artworkByID[trackID] = image
        } else {
            artworkByID.removeValue(forKey: trackID)
        }
        cardsByID[trackID]?.setArtwork(image)
    }

    func setCurrentTrackID(_ trackID: String?) {
        currentTrackID = trackID
        for (id, card) in cardsByID {
            card.setCurrent(id == trackID)
        }
    }

    func resize(to viewportSize: NSSize) {
        let contentWidth = CGFloat(cards.count) * (Self.cardWidth + Self.cardSpacing) + 7
        frame.size = NSSize(width: max(viewportSize.width, contentWidth), height: viewportSize.height)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(
                x: 4 + CGFloat(index) * (Self.cardWidth + Self.cardSpacing),
                y: 0,
                width: Self.cardWidth,
                height: bounds.height
            )
        }
        placeholderLabel.frame = NSRect(
            x: 12,
            y: max(0, (bounds.height - 42) / 2),
            width: max(0, min(bounds.width, 240) - 24),
            height: 42
        )
    }
}

@MainActor
private final class HorizontalTrackCard: NSButton {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let playOverlay = NonInteractivePlayOverlayView()
    private let playOverlayImage = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isCurrent = false
    private var displayedSymbolName: String?

    var onPlay: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(playTrack)
        wantsLayer = true
        layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 88)
        layer?.cornerCurve = .continuous

        artworkView.imageScaling = .scaleAxesIndependently
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 72)
        artworkView.layer?.cornerCurve = .continuous
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(artworkView)

        playOverlay.wantsLayer = true
        playOverlay.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 28)
        playOverlay.layer?.cornerCurve = .continuous
        playOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        playOverlay.layer?.borderWidth = 0
        playOverlay.isHidden = true
        playOverlay.setAccessibilityIdentifier("track-play-overlay")
        addSubview(playOverlay)

        playOverlayImage.imageScaling = .scaleProportionallyDown
        playOverlayImage.contentTintColor = .white
        playOverlayImage.wantsLayer = true
        playOverlayImage.layer?.shadowColor = NSColor.black.cgColor
        playOverlayImage.layer?.shadowOpacity = 0.6
        playOverlayImage.layer?.shadowRadius = 1.4
        playOverlayImage.layer?.shadowOffset = .zero
        playOverlay.addSubview(playOverlayImage)

        titleLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        artistLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.alignment = .center
        artistLabel.lineBreakMode = .byTruncatingTail
        addSubview(artistLabel)
        setArtwork(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(track: LibraryTrackSnapshot, language: AppLanguage) {
        titleLabel.stringValue = language.displayText(track.title)
        artistLabel.stringValue = language.displayText(track.artist)
        setAccessibilityLabel(
            [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        setAccessibilityHelp(language.localized(.play))
    }

    func setArtwork(_ image: NSImage?) {
        if let image {
            artworkView.image = image
            artworkView.contentTintColor = nil
            artworkView.imageScaling = .scaleAxesIndependently
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .secondaryLabelColor
            artworkView.imageScaling = .scaleProportionallyDown
        }
    }

    func setCurrent(_ current: Bool) {
        guard current != isCurrent else { return }
        isCurrent = current
        updateInteractionAppearance()
    }

    override func layout() {
        super.layout()
        let coverSize = min(72, bounds.height - 34)
        artworkView.frame = NSRect(
            x: (bounds.width - coverSize) / 2,
            y: 2,
            width: coverSize,
            height: coverSize
        )
        playOverlay.frame = NSRect(
            x: (bounds.width - 28) / 2,
            y: 2 + (coverSize - 28) / 2,
            width: 28,
            height: 28
        )
        playOverlayImage.frame = playOverlay.bounds.insetBy(dx: 6, dy: 6)
        titleLabel.frame = NSRect(x: 2, y: coverSize + 6, width: bounds.width - 4, height: 15)
        artistLabel.frame = NSRect(x: 2, y: coverSize + 21, width: bounds.width - 4, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
        isHovered = true
        updateInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        isHovered = false
        updateInteractionAppearance()
    }

    private func updateInteractionAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        playOverlay.isHidden = !isHovered && !isCurrent
        let symbolName = isCurrent && !isHovered ? "speaker.wave.2.fill" : "play.fill"
        if displayedSymbolName != symbolName {
            displayedSymbolName = symbolName
            playOverlayImage.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        }
        titleLabel.textColor = .labelColor
    }

    @objc private func playTrack() { onPlay?() }
}

@MainActor
private final class LyricsPanelView: NSView {
    private let scrollView = NSScrollView()
    private let contentView = LyricsContentView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let edgeFadeMask = CAGradientLayer()
    private var timeline: LyricsTimeline?
    private var position: TimeInterval = 0

    var lineCount: Int { timeline?.lines.count ?? 0 }
    var currentLineText: String? { contentView.currentLineText }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 286))
        wantsLayer = true
        layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentView
        scrollView.wantsLayer = true
        edgeFadeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor
        ]
        edgeFadeMask.locations = [0, 0.10, 0.90, 1]
        edgeFadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeFadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        scrollView.layer?.mask = edgeFadeMask
        addSubview(scrollView)

        placeholderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 2
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        timeline: LyricsTimeline?,
        placeholder: String,
        language: AppLanguage
    ) {
        self.timeline = timeline
        let lines = timeline?.lines.map {
            LyricLine(time: $0.time, text: language.displayText($0.text))
        } ?? []
        placeholderLabel.stringValue = placeholder
        placeholderLabel.isHidden = !lines.isEmpty
        scrollView.isHidden = lines.isEmpty
        contentView.update(lines: lines)
        needsLayout = true
        layoutSubtreeIfNeeded()
        updatePosition(position, animated: false)
    }

    func updatePosition(_ position: TimeInterval) {
        updatePosition(position, animated: true)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        edgeFadeMask.frame = scrollView.bounds
        placeholderLabel.frame = NSRect(
            x: 16,
            y: max(0, (bounds.height - 44) / 2),
            width: max(0, bounds.width - 32),
            height: 44
        )
        contentView.resize(to: scrollView.contentSize)
    }

    private func updatePosition(_ position: TimeInterval, animated: Bool) {
        self.position = position
        guard let timeline, !timeline.lines.isEmpty else { return }
        var lowerBound = 0
        var upperBound = timeline.lines.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if timeline.lines[middle].time <= position {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let index = max(0, lowerBound - 1)
        guard contentView.setCurrentIndex(index) else { return }
        contentView.resize(to: scrollView.contentSize)
        scrollCurrentLine(animated: animated)
    }

    private func scrollCurrentLine(animated: Bool) {
        guard let lineFrame = contentView.currentLineFrame else { return }
        let clipView = scrollView.contentView
        let maxY = max(0, contentView.bounds.height - clipView.bounds.height)
        let targetY = min(maxY, max(0, lineFrame.midY - clipView.bounds.height * 0.22))
        let origin = NSPoint(x: 0, y: targetY)
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clipView)
    }
}

@MainActor
private final class LyricsContentView: NSView {
    private var lines: [LyricLine] = []
    private var labels: [NSTextField] = []
    private var currentIndex: Int?
    private var lastViewportSize = NSSize(width: 240, height: 286)

    override var isFlipped: Bool { true }
    var currentLineFrame: NSRect? {
        currentIndex.flatMap { labels.indices.contains($0) ? labels[$0].frame : nil }
    }
    var currentLineText: String? {
        currentIndex.flatMap { lines.indices.contains($0) ? lines[$0].text : nil }
    }

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(lines: [LyricLine]) {
        self.lines = lines
        labels.forEach { $0.removeFromSuperview() }
        labels = lines.map { line in
            let label = NSTextField(wrappingLabelWithString: line.text)
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            addSubview(label)
            return label
        }
        currentIndex = lines.isEmpty ? nil : 0
        resize(to: lastViewportSize)
    }

    @discardableResult
    func setCurrentIndex(_ index: Int) -> Bool {
        guard lines.indices.contains(index), currentIndex != index else { return false }
        currentIndex = index
        resize(to: lastViewportSize)
        return true
    }

    func resize(to viewportSize: NSSize) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        lastViewportSize = viewportSize
        let horizontalInset: CGFloat = 14
        let textWidth = max(80, viewportSize.width - horizontalInset * 2 - 5)
        var y: CGFloat = 54

        for (index, label) in labels.enumerated() {
            let activeIndex = currentIndex ?? 0
            let distance = abs(index - activeIndex)
            let isCurrent = index == currentIndex
            let font = NSFont.systemFont(
                ofSize: 16,
                weight: isCurrent ? .bold : .semibold
            )
            label.font = font
            if isCurrent {
                label.textColor = .labelColor
                label.alphaValue = 1
            } else if index < activeIndex {
                label.textColor = .tertiaryLabelColor
                label.alphaValue = max(0.16, 0.34 - CGFloat(distance) * 0.08)
            } else {
                label.textColor = distance <= 1 ? .secondaryLabelColor : .tertiaryLabelColor
                label.alphaValue = max(0.30, 0.78 - CGFloat(distance) * 0.11)
            }
            let measured = (label.stringValue as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            let height = max(22, ceil(measured.height))
            label.frame = NSRect(x: horizontalInset, y: y, width: textWidth, height: height)
            y += height + 24
        }
        frame.size = NSSize(
            width: viewportSize.width,
            height: max(viewportSize.height, y + 82)
        )
    }
}
