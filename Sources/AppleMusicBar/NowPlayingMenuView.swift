import AppKit
import QuartzCore

@MainActor
final class PlaybackToggleButton: NSButton {
    private(set) var displayedSymbolName: String?
    private(set) var transitionCount = 0

    func setPlaybackState(
        isPlaying: Bool,
        configuration: NSImage.SymbolConfiguration,
        animated: Bool
    ) {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        guard displayedSymbolName != symbolName else { return }

        let shouldAnimate = animated && displayedSymbolName != nil
        if shouldAnimate {
            wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "playback-symbol-fade")

            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 0.88, 1.04, 1]
            pulse.keyTimes = [0, 0.28, 0.7, 1]
            pulse.duration = 0.22
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "playback-symbol-pulse")
            transitionCount += 1
        }

        displayedSymbolName = symbolName
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }
}

@MainActor
final class NowPlayingMenuView: NSView {
    var onTrackListToggle: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onLyricsToggle: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?

    private static let viewSize = NSSize(width: 240, height: 126)

    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Apple Music")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let pulseView = AudioPulseView()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "−0:00")
    private let progressView = PlaybackProgressView()
    private let trackListButton = NSButton()
    private let previousButton = NSButton()
    private let playPauseButton = PlaybackToggleButton()
    private let nextButton = NSButton()
    private let lyricsButton = NSButton()

    private var isPlaying = false
    private var controlsEnabled = false
    private var isActive = false
    private var isShowingTrackList = false
    private var isShowingLyrics = false
    private var currentDuration: TimeInterval = 0
    private var previousAccessibilityTitle = "Previous"
    private var playAccessibilityTitle = "Play"
    private var pauseAccessibilityTitle = "Pause"
    private var nextAccessibilityTitle = "Next"
    private var showTrackListAccessibilityTitle = "Show Song List"
    private var hideTrackListAccessibilityTitle = "Hide Song List"
    private var showLyricsAccessibilityTitle = "Show Lyrics"
    private var hideLyricsAccessibilityTitle = "Hide Lyrics"

    override var intrinsicContentSize: NSSize { Self.viewSize }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.viewSize))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.viewSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.viewSize.height).isActive = true
        configureViews()
        configureLayout()
        setArtwork(nil)
        updateProgress(position: 0, duration: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        title: String,
        subtitle: String,
        isPlaying: Bool,
        controlsEnabled: Bool,
        position: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
        }
        if subtitleLabel.stringValue != subtitle {
            subtitleLabel.stringValue = subtitle
        }
        if subtitleLabel.isHidden != subtitle.isEmpty {
            subtitleLabel.isHidden = subtitle.isEmpty
        }
        let playbackStateChanged = self.isPlaying != isPlaying
        let controlsStateChanged = self.controlsEnabled != controlsEnabled
        self.isPlaying = isPlaying
        self.controlsEnabled = controlsEnabled
        if previousButton.isEnabled != controlsEnabled {
            previousButton.isEnabled = controlsEnabled
            playPauseButton.isEnabled = controlsEnabled
            nextButton.isEnabled = controlsEnabled
        }
        let progressEnabled = controlsEnabled && duration > 0
        if progressView.isEnabled != progressEnabled {
            progressView.isEnabled = progressEnabled
        }
        currentDuration = max(0, duration)
        pulseView.setPlaying(isPlaying && controlsEnabled)
        if playbackStateChanged || controlsStateChanged {
            updateControlImages(
                animatePlayPause: playbackStateChanged && controlsEnabled
            )
        }
        updateProgress(position: position, duration: duration)
        let accessibilityLabel = subtitle.isEmpty ? title : "\(title), \(subtitle)"
        if self.accessibilityLabel() != accessibilityLabel {
            setAccessibilityLabel(accessibilityLabel)
        }
    }

    func updatePlaybackPosition(_ position: TimeInterval, duration: TimeInterval) {
        currentDuration = max(0, duration)
        updateProgress(position: position, duration: duration)
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        pulseView.setActive(active)
    }

    func updateAccessibility(
        previous: String,
        play: String,
        pause: String,
        next: String,
        showLyrics: String = "Show Lyrics",
        hideLyrics: String = "Hide Lyrics",
        showTrackList: String = "Show Song List",
        hideTrackList: String = "Hide Song List"
    ) {
        previousAccessibilityTitle = previous
        playAccessibilityTitle = play
        pauseAccessibilityTitle = pause
        nextAccessibilityTitle = next
        showTrackListAccessibilityTitle = showTrackList
        hideTrackListAccessibilityTitle = hideTrackList
        showLyricsAccessibilityTitle = showLyrics
        hideLyricsAccessibilityTitle = hideLyrics
        updateControlImages()
    }

    func setTrackListVisible(_ visible: Bool) {
        guard visible != isShowingTrackList else { return }
        isShowingTrackList = visible
        updateControlImages()
    }

    func setLyricsVisible(_ visible: Bool) {
        guard visible != isShowingLyrics else { return }
        isShowingLyrics = visible
        updateControlImages()
    }

    func setArtwork(_ image: NSImage?) {
        if let image {
            artworkView.image = image
            artworkView.imageScaling = .scaleAxesIndependently
            artworkView.contentTintColor = nil
            pulseView.setAccentColor(ArtworkAccentColor.extract(from: image))
        } else {
            artworkView.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: nil
            )
            artworkView.imageScaling = .scaleProportionallyDown
            artworkView.contentTintColor = .secondaryLabelColor
            pulseView.setAccentColor(nil)
        }
    }

    private func configureViews() {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = AppVisualStyle.goldenCornerRadius(for: 44)
        artworkView.layer?.cornerCurve = .continuous
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(artworkView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        pulseView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pulseView)

        [elapsedLabel, remainingLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
            $0.textColor = .secondaryLabelColor
            addSubview($0)
        }
        remainingLabel.alignment = .right

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.onScrub = { [weak self] fraction in
            guard let self else { return }
            self.updateProgress(
                position: self.currentDuration * fraction,
                duration: self.currentDuration,
                respectingUserInteraction: false
            )
        }
        progressView.onCommit = { [weak self] fraction in
            guard let self, self.currentDuration > 0 else { return }
            self.onSeek?(self.currentDuration * fraction)
        }
        addSubview(progressView)

        configureButton(trackListButton, action: #selector(trackListPressed))
        configureButton(previousButton, action: #selector(previousPressed))
        configureButton(playPauseButton, action: #selector(playPausePressed))
        configureButton(nextButton, action: #selector(nextPressed))
        configureButton(lyricsButton, action: #selector(lyricsPressed))
        addSubview(trackListButton)
        addSubview(previousButton)
        addSubview(playPauseButton)
        addSubview(nextButton)
        addSubview(lyricsButton)
        updateControlImages()
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.focusRingType = .none
    }

    private func configureLayout() {
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),

            pulseView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pulseView.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            pulseView.widthAnchor.constraint(equalToConstant: 18),
            pulseView.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: pulseView.leadingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: artworkView.centerYAnchor, constant: -1),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: artworkView.centerYAnchor, constant: 4),

            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            elapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 40),
            elapsedLabel.heightAnchor.constraint(equalToConstant: 14),

            remainingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            remainingLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 40),
            remainingLabel.heightAnchor.constraint(equalToConstant: 14),

            progressView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            progressView.bottomAnchor.constraint(equalTo: elapsedLabel.topAnchor, constant: -1),
            progressView.heightAnchor.constraint(equalToConstant: 8),

            playPauseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: progressView.topAnchor, constant: -1),
            playPauseButton.widthAnchor.constraint(equalToConstant: 42),
            playPauseButton.heightAnchor.constraint(equalToConstant: 42),

            trackListButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            trackListButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            trackListButton.widthAnchor.constraint(equalToConstant: 31),
            trackListButton.heightAnchor.constraint(equalToConstant: 36),

            previousButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -54),
            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 38),
            previousButton.heightAnchor.constraint(equalToConstant: 38),

            nextButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 54),
            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 38),
            nextButton.heightAnchor.constraint(equalToConstant: 38),

            lyricsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            lyricsButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            lyricsButton.widthAnchor.constraint(equalToConstant: 31),
            lyricsButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func updateProgress(
        position: TimeInterval,
        duration: TimeInterval,
        respectingUserInteraction: Bool = true
    ) {
        if respectingUserInteraction, progressView.isUserInteracting { return }
        let safeDuration = max(0, duration)
        let safePosition = min(max(0, position), safeDuration > 0 ? safeDuration : max(0, position))
        let progress = safeDuration > 0 ? safePosition / safeDuration : 0
        if progressView.progress != progress {
            progressView.progress = progress
        }
        let elapsed = Self.formattedTime(safePosition)
        if elapsedLabel.stringValue != elapsed {
            elapsedLabel.stringValue = elapsed
        }
        let remaining = "−\(Self.formattedTime(max(0, safeDuration - safePosition)))"
        if remainingLabel.stringValue != remaining {
            remainingLabel.stringValue = remaining
        }
    }

    private static func formattedTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let totalSeconds = Int(interval.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func updateControlImages(animatePlayPause: Bool = false) {
        let sideConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        let playConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        let trackListConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let lyricsConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        trackListButton.image = NSImage(
            systemSymbolName: "list.bullet",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(trackListConfiguration)
        previousButton.image = NSImage(
            systemSymbolName: "backward.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(sideConfiguration)
        playPauseButton.setPlaybackState(
            isPlaying: isPlaying,
            configuration: playConfiguration,
            animated: animatePlayPause
        )
        nextButton.image = NSImage(
            systemSymbolName: "forward.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(sideConfiguration)
        lyricsButton.image = NSImage(
            systemSymbolName: isShowingLyrics ? "quote.bubble.fill" : "quote.bubble",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(lyricsConfiguration)
        lyricsButton.contentTintColor = isShowingLyrics
            ? AppVisualStyle.emphasisColor
            : .secondaryLabelColor
        trackListButton.contentTintColor = isShowingTrackList
            ? AppVisualStyle.emphasisColor
            : .secondaryLabelColor

        trackListButton.setAccessibilityLabel(
            isShowingTrackList
                ? hideTrackListAccessibilityTitle
                : showTrackListAccessibilityTitle
        )
        previousButton.setAccessibilityLabel(previousAccessibilityTitle)
        playPauseButton.setAccessibilityLabel(isPlaying ? pauseAccessibilityTitle : playAccessibilityTitle)
        nextButton.setAccessibilityLabel(nextAccessibilityTitle)
        lyricsButton.setAccessibilityLabel(
            isShowingLyrics ? hideLyricsAccessibilityTitle : showLyricsAccessibilityTitle
        )
    }

    @objc private func trackListPressed() { onTrackListToggle?() }
    @objc private func previousPressed() { onPrevious?() }
    @objc private func playPausePressed() { onPlayPause?() }
    @objc private func nextPressed() { onNext?() }
    @objc private func lyricsPressed() { onLyricsToggle?() }
}

@MainActor
final class PlaybackProgressView: NSControl {
    var onScrub: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?

    var progress: Double = 0 {
        didSet {
            progress = min(max(progress, 0), 1)
            setAccessibilityValue(progress)
            needsDisplay = true
        }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isScrubbing = false
    private var isInteractionEmphasized = false
    private var interactionEmphasis: CGFloat = 0
    private var interactionAnimationTask: Task<Void, Never>?

    var isUserInteracting: Bool { isScrubbing }
    var renderedTrackThickness: CGFloat { 4 + 4 * interactionEmphasis }

    override var acceptsFirstResponder: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet {
            guard !isEnabled else { return }
            isHovered = false
            isScrubbing = false
            setInteractionEmphasized(false, animated: false)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func scrub(to fraction: Double, commit: Bool) {
        guard isEnabled else { return }
        progress = min(max(fraction, 0), 1)
        onScrub?(progress)
        if commit {
            onCommit?(progress)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isScrubbing = true
        setInteractionEmphasized(true, animated: true)
        updateProgress(with: event, commit: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        updateProgress(with: event, commit: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbing else { return }
        updateProgress(with: event, commit: true)
        isScrubbing = false
        setInteractionEmphasized(isHovered, animated: true)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            scrub(to: progress - 0.02, commit: true)
        case 124:
            scrub(to: progress + 0.02, commit: true)
        default:
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        NSCursor.pointingHand.set()
        isHovered = true
        setInteractionEmphasized(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        isHovered = false
        setInteractionEmphasized(isScrubbing, animated: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let thickness = min(bounds.height, renderedTrackThickness)
        let radius = thickness / 2
        let trackRect = NSRect(
            x: 0,
            y: (bounds.height - thickness) / 2,
            width: bounds.width,
            height: thickness
        )
        let backgroundAlpha = 0.28 + 0.08 * interactionEmphasis
        NSColor.tertiaryLabelColor.withAlphaComponent(backgroundAlpha).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

        let fillWidth = trackRect.width * progress
        if fillWidth > 0 {
            let fillAlpha = 0.8 + 0.15 * interactionEmphasis
            NSColor.secondaryLabelColor.withAlphaComponent(fillAlpha).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: fillWidth,
                    height: thickness
                ),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
    }

    func setInteractionEmphasized(_ emphasized: Bool, animated: Bool) {
        isInteractionEmphasized = emphasized
        interactionAnimationTask?.cancel()
        let target: CGFloat = emphasized ? 1 : 0
        guard animated, abs(target - interactionEmphasis) > 0.001 else {
            interactionEmphasis = target
            needsDisplay = true
            return
        }

        let start = interactionEmphasis
        interactionAnimationTask = Task { [weak self] in
            guard let self else { return }
            let frameCount = 8
            for frame in 1...frameCount {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(frame) / CGFloat(frameCount)
                let eased = 1 - pow(1 - progress, 3)
                self.interactionEmphasis = start + (target - start) * eased
                self.needsDisplay = true
            }
            self.interactionEmphasis = target
            self.needsDisplay = true
        }
    }

    private func updateProgress(with event: NSEvent, commit: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = bounds.width > 0 ? Double(point.x / bounds.width) : 0
        scrub(to: fraction, commit: commit)
    }
}

enum ArtworkAccentColor {
    static func extract(from image: NSImage) -> NSColor? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }

        let sampleSide = 12
        let bytesPerPixel = 4
        let bytesPerRow = sampleSide * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: sampleSide * sampleSide * bytesPerPixel
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSide,
                height: sampleSide,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide)
            )
            return true
        }
        guard rendered else { return nil }

        var redTotal: CGFloat = 0
        var greenTotal: CGFloat = 0
        var blueTotal: CGFloat = 0
        var totalWeight: CGFloat = 0
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = CGFloat(pixels[offset + 3]) / 255
            guard alpha > 0.1 else { continue }
            let red = min(1, CGFloat(pixels[offset]) / 255 / alpha)
            let green = min(1, CGFloat(pixels[offset + 1]) / 255 / alpha)
            let blue = min(1, CGFloat(pixels[offset + 2]) / 255 / alpha)
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
            let weight = alpha * (0.35 + 0.65 * saturation)
            redTotal += red * weight
            greenTotal += green * weight
            blueTotal += blue * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return NSColor(
            srgbRed: redTotal / totalWeight,
            green: greenTotal / totalWeight,
            blue: blueTotal / totalWeight,
            alpha: 1
        )
    }
}

@MainActor
final class AudioPulseView: NSView {
    private static let barCount = 5
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2
    private static let minimumBarHeight: CGFloat = 3
    private static let maximumBarHeight: CGFloat = 10

    private var phase: CGFloat = 0
    private var isPlaying = false
    private var isActive = false
    private var timer: Timer?
    private var accentColor: NSColor?

    var isAnimating: Bool { timer != nil }

    var renderedBarColor: NSColor {
        (accentColor ?? .secondaryLabelColor)
            .withAlphaComponent(isPlaying ? 0.78 : 0.38)
    }

    var renderedBarHeights: [CGFloat] {
        guard isPlaying else {
            return Array(repeating: Self.minimumBarHeight, count: Self.barCount)
        }
        return (0..<Self.barCount).map { index in
            let offset = CGFloat(index)
            let primary = sin(phase * (0.9 + offset * 0.04) + offset * 1.17)
            let secondary = sin(phase * 0.47 + offset * 2.03)
            let energy = min(1, abs(primary * 0.72 + secondary * 0.28))
            return Self.minimumBarHeight
                + (Self.maximumBarHeight - Self.minimumBarHeight) * energy
        }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateTimer()
        needsDisplay = true
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updateTimer()
        needsDisplay = true
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        if isPlaying && isActive {
            let timer = Timer(timeInterval: 0.075, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else {
                        timer.invalidate()
                        return
                    }
                    self.phase += 0.32
                    self.needsDisplay = true
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func setAccentColor(_ color: NSColor?) {
        accentColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let heights = renderedBarHeights
        let contentWidth = Self.barWidth * CGFloat(Self.barCount)
            + Self.barSpacing * CGFloat(Self.barCount - 1)
        let leading = (bounds.width - contentWidth) / 2
        renderedBarColor.setFill()

        for (index, requestedHeight) in heights.enumerated() {
            let height = min(bounds.height, requestedHeight)
            let rect = NSRect(
                x: leading + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                y: (bounds.height - height) / 2,
                width: Self.barWidth,
                height: height
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: Self.barWidth / 2,
                yRadius: Self.barWidth / 2
            ).fill()
        }
    }
}
