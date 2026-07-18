import AppKit

@MainActor
final class NativePlayerMenu: NSObject, NSMenuDelegate {
    private struct WindowResizeAnchor {
        let top: CGFloat
        let leading: CGFloat
        let chromeSize: NSSize
    }

    let menu = NSMenu()
    let settingsItem = NSMenuItem()
    let item = NSMenuItem()

    private(set) var isOpen = false
    private let contentView: NSView
    private var contentSize: NSSize
    private var windowResizeAnchor: WindowResizeAnchor?
    private var resizeRevision = 0
    private var pendingContentSize: NSSize?
    private var isContentSizeUpdateScheduled = false

    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?

    init(contentView: NSView, contentSize: NSSize) {
        self.contentView = contentView
        self.contentSize = contentSize
        super.init()

        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.frame = NSRect(origin: .zero, size: contentSize)
        contentView.autoresizingMask = []
        item.view = contentView
        item.isEnabled = true

        menu.autoenablesItems = false
        menu.minimumWidth = contentSize.width
        menu.delegate = self
        settingsItem.isEnabled = true
        settingsItem.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        menu.addItem(settingsItem)
        menu.addItem(item)
    }

    func configureSettingsItem(title: String, submenu: NSMenu) {
        settingsItem.title = title
        settingsItem.submenu = submenu
        menu.itemChanged(settingsItem)
    }

    func updateSettingsTitle(_ title: String) {
        guard settingsItem.title != title else { return }
        settingsItem.title = title
        menu.itemChanged(settingsItem)
    }

    func present(at screenPoint: NSPoint) {
        guard !isOpen else { return }
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    func cancel() {
        menu.cancelTracking()
    }

    func updateContentSize(_ size: NSSize) {
        if isOpen {
            guard pendingContentSize != size else { return }
            guard pendingContentSize != nil || contentSize != size else { return }
            pendingContentSize = size
            guard !isContentSizeUpdateScheduled else { return }
            isContentSizeUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isContentSizeUpdateScheduled = false
                guard let pendingContentSize = self.pendingContentSize else { return }
                self.pendingContentSize = nil
                self.applyContentSize(pendingContentSize)
            }
            return
        }

        pendingContentSize = nil
        applyContentSize(size)
    }

    private func applyContentSize(_ size: NSSize) {
        guard size != contentSize else { return }
        let previousSize = contentSize
        let previousWindowFrame = contentView.window?.frame
        if isOpen, windowResizeAnchor == nil, let previousWindowFrame {
            windowResizeAnchor = WindowResizeAnchor(
                top: previousWindowFrame.maxY,
                leading: previousWindowFrame.minX,
                chromeSize: NSSize(
                    width: max(0, previousWindowFrame.width - previousSize.width),
                    height: max(0, previousWindowFrame.height - previousSize.height)
                )
            )
        }
        contentSize = size
        menu.minimumWidth = size.width
        contentView.frame.size = size
        contentView.invalidateIntrinsicContentSize()
        menu.itemChanged(item)
        menu.update()

        guard isOpen, let anchor = windowResizeAnchor else { return }
        resizeRevision += 1
        let revision = resizeRevision
        reanchorWindow(contentSize: size, anchor: anchor)

        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.isOpen,
                self.resizeRevision == revision,
                let anchor = self.windowResizeAnchor
            else { return }
            self.reanchorWindow(contentSize: self.contentSize, anchor: anchor)
        }
    }

    var windowFrame: NSRect? { contentView.window?.frame }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        windowResizeAnchor = nil
        resizeRevision += 1
        onWillOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        windowResizeAnchor = nil
        resizeRevision += 1
        onDidClose?()
    }

    private func reanchorWindow(contentSize: NSSize, anchor: WindowResizeAnchor) {
        guard let window = contentView.window else { return }
        let expectedSize = NSSize(
            width: contentSize.width + anchor.chromeSize.width,
            height: contentSize.height + anchor.chromeSize.height
        )
        var frame = NSRect(
            x: anchor.leading,
            y: anchor.top - expectedSize.height,
            width: expectedSize.width,
            height: expectedSize.height
        )

        if let visibleFrame = window.screen?.visibleFrame {
            if frame.maxX > visibleFrame.maxX {
                frame.origin.x = visibleFrame.maxX - frame.width
            }
            frame.origin.x = max(visibleFrame.minX, frame.origin.x)
            frame.origin.y = max(visibleFrame.minY, frame.origin.y)
        }

        let currentFrame = window.frame
        guard
            abs(currentFrame.minX - frame.minX) > 0.5
                || abs(currentFrame.minY - frame.minY) > 0.5
                || abs(currentFrame.width - frame.width) > 0.5
                || abs(currentFrame.height - frame.height) > 0.5
        else { return }
        window.setFrame(frame, display: true)
    }
}
