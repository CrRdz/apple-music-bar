import AppKit

@MainActor
final class NowPlayingMenuView: NSView {
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    private let cardView = RoundedCardView()
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Apple Music")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()

    private var isPlaying = false
    private var playAccessibilityTitle = "Play"
    private var pauseAccessibilityTitle = "Pause"

    override var intrinsicContentSize: NSSize {
        NSSize(width: 380, height: 96)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 380).isActive = true
        heightAnchor.constraint(equalToConstant: 96).isActive = true
        configureViews()
        configureLayout()
        setArtwork(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        title: String,
        subtitle: String,
        isPlaying: Bool,
        controlsEnabled: Bool
    ) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        self.isPlaying = isPlaying
        playPauseButton.isEnabled = controlsEnabled
        nextButton.isEnabled = controlsEnabled
        updatePlayPauseImage()
        setAccessibilityLabel("\(title), \(subtitle)")
    }

    func setArtwork(_ image: NSImage?) {
        if let image {
            artworkView.image = image
            artworkView.imageScaling = .scaleAxesIndependently
            artworkView.contentTintColor = nil
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.imageScaling = .scaleProportionallyDown
            artworkView.contentTintColor = .secondaryLabelColor
        }
    }

    func updateAccessibility(play: String, pause: String, next: String) {
        playAccessibilityTitle = play
        pauseAccessibilityTitle = pause
        nextButton.setAccessibilityLabel(next)
        updatePlayPauseImage()
    }

    private func configureViews() {
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 11
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        cardView.addSubview(artworkView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(subtitleLabel)

        configureButton(playPauseButton, action: #selector(playPausePressed))
        configureButton(nextButton, action: #selector(nextPressed))
        cardView.addSubview(playPauseButton)
        cardView.addSubview(nextButton)
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
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            artworkView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            artworkView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 56),
            artworkView.heightAnchor.constraint(equalToConstant: 56),

            nextButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            nextButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 36),
            nextButton.heightAnchor.constraint(equalToConstant: 44),

            playPauseButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -4),
            playPauseButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -10),
            titleLabel.bottomAnchor.constraint(equalTo: cardView.centerYAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
        ])
    }

    private func updatePlayPauseImage() {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: 21, weight: .bold)
        playPauseButton.image = image?.withSymbolConfiguration(configuration)
        playPauseButton.setAccessibilityLabel(
            isPlaying ? pauseAccessibilityTitle : playAccessibilityTitle
        )

        let nextImage = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
        nextButton.image = nextImage?.withSymbolConfiguration(configuration)
    }

    @objc private func playPausePressed() {
        onPlayPause?()
    }

    @objc private func nextPressed() {
        onNext?()
    }
}

@MainActor
private final class RoundedCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color: NSColor
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            color = NSColor.white.withAlphaComponent(0.10)
        } else {
            color = NSColor.black.withAlphaComponent(0.10)
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 25, yRadius: 25).fill()
    }
}
