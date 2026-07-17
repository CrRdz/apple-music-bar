import AppKit

@MainActor
final class NowPlayingMenuView: NSView {
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
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()
    private let lyricsButton = NSButton()

    private var isPlaying = false
    private var isShowingLyrics = false
    private var currentDuration: TimeInterval = 0
    private var previousAccessibilityTitle = "Previous"
    private var playAccessibilityTitle = "Play"
    private var pauseAccessibilityTitle = "Pause"
    private var nextAccessibilityTitle = "Next"
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
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        self.isPlaying = isPlaying
        previousButton.isEnabled = controlsEnabled
        playPauseButton.isEnabled = controlsEnabled
        nextButton.isEnabled = controlsEnabled
        progressView.isEnabled = controlsEnabled && duration > 0
        currentDuration = max(0, duration)
        pulseView.setPlaying(isPlaying && controlsEnabled)
        updateControlImages()
        updateProgress(position: position, duration: duration)
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    func updateAccessibility(
        previous: String,
        play: String,
        pause: String,
        next: String,
        showLyrics: String = "Show Lyrics",
        hideLyrics: String = "Hide Lyrics"
    ) {
        previousAccessibilityTitle = previous
        playAccessibilityTitle = play
        pauseAccessibilityTitle = pause
        nextAccessibilityTitle = next
        showLyricsAccessibilityTitle = showLyrics
        hideLyricsAccessibilityTitle = hideLyrics
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
            pulseView.accentColor = ArtworkAccentColor.extract(from: image)
        } else {
            artworkView.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: nil
            )
            artworkView.imageScaling = .scaleProportionallyDown
            artworkView.contentTintColor = .secondaryLabelColor
            pulseView.accentColor = .secondaryLabelColor
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

        configureButton(previousButton, action: #selector(previousPressed))
        configureButton(playPauseButton, action: #selector(playPausePressed))
        configureButton(nextButton, action: #selector(nextPressed))
        configureButton(lyricsButton, action: #selector(lyricsPressed))
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
            pulseView.heightAnchor.constraint(equalToConstant: 20),

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
        progressView.progress = safeDuration > 0 ? safePosition / safeDuration : 0
        elapsedLabel.stringValue = Self.formattedTime(safePosition)
        remainingLabel.stringValue = "−\(Self.formattedTime(max(0, safeDuration - safePosition)))"
    }

    private static func formattedTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let totalSeconds = Int(interval.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func updateControlImages() {
        let sideConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        let playConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        let lyricsConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        previousButton.image = NSImage(
            systemSymbolName: "backward.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(sideConfiguration)
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(playConfiguration)
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

        previousButton.setAccessibilityLabel(previousAccessibilityTitle)
        playPauseButton.setAccessibilityLabel(isPlaying ? pauseAccessibilityTitle : playAccessibilityTitle)
        nextButton.setAccessibilityLabel(nextAccessibilityTitle)
        lyricsButton.setAccessibilityLabel(
            isShowingLyrics ? hideLyricsAccessibilityTitle : showLyricsAccessibilityTitle
        )
    }

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

    var isUserInteracting: Bool { isScrubbing }

    override var acceptsFirstResponder: Bool { isEnabled }

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
        needsDisplay = true
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let trackRect = NSRect(x: 0, y: (bounds.height - 4) / 2, width: bounds.width, height: 4)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()

        let fillWidth = trackRect.width * progress
        if fillWidth > 0 {
            NSColor.secondaryLabelColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: 4),
                xRadius: 2,
                yRadius: 2
            ).fill()
        }

        if isEnabled, isHovered || isScrubbing {
            let knobSize: CGFloat = 7
            let knobX = min(max(trackRect.minX, trackRect.minX + fillWidth), trackRect.maxX)
            NSColor.labelColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: knobX - knobSize / 2,
                    y: trackRect.midY - knobSize / 2,
                    width: knobSize,
                    height: knobSize
                )
            ).fill()
        }
    }

    private func updateProgress(with event: NSEvent, commit: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = bounds.width > 0 ? Double(point.x / bounds.width) : 0
        scrub(to: fraction, commit: commit)
    }
}

@MainActor
final class AudioPulseView: NSView {
    var accentColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    private var phase: CGFloat = 0
    private var isPlaying = false
    private var timer: Timer?

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        timer?.invalidate()
        timer = nil
        if playing {
            let timer = Timer(timeInterval: 0.095, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else {
                        timer.invalidate()
                        return
                    }
                    self.phase += 0.58
                    self.needsDisplay = true
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let count = 4
        let spacing: CGFloat = 2
        let barWidth = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)

        for index in 0..<count {
            let wave = sin(phase * (1 + CGFloat(index) * 0.07) + CGFloat(index) * 1.23)
            let normalized = isPlaying ? 0.52 + 0.48 * wave : 0.18
            let height = max(5, bounds.height * max(0.12, normalized))
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + spacing),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            )
            accentColor.withAlphaComponent(0.38).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.32).setStroke()
            path.lineWidth = 0.65
            path.stroke()

            let highlight = NSRect(
                x: rect.minX + barWidth * 0.22,
                y: rect.minY + rect.height * 0.18,
                width: max(0.7, barWidth * 0.22),
                height: rect.height * 0.62
            )
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(
                roundedRect: highlight,
                xRadius: highlight.width / 2,
                yRadius: highlight.width / 2
            ).fill()
        }
    }
}

enum ArtworkAccentColor {
    static func extract(from image: NSImage) -> NSColor {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10,
            pixelsHigh: 10,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return .secondaryLabelColor }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return .secondaryLabelColor
        }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 10, height: 10))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var totalWeight: CGFloat = 0
        for x in 0..<10 {
            for y in 0..<10 {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    color.alphaComponent > 0.15
                else { continue }
                let saturation = max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent)
                let weight = 0.25 + saturation * 1.75
                red += color.redComponent * weight
                green += color.greenComponent * weight
                blue += color.blueComponent * weight
                totalWeight += weight
            }
        }
        guard totalWeight > 0 else { return .secondaryLabelColor }
        let sampled = NSColor(
            calibratedRed: red / totalWeight,
            green: green / totalWeight,
            blue: blue / totalWeight,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        sampled.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return NSColor(
            calibratedHue: hue,
            saturation: max(0.38, saturation),
            brightness: min(0.92, max(0.48, brightness)),
            alpha: 1
        )
    }
}
