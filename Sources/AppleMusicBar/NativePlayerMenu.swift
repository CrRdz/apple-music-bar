import AppKit

@MainActor
final class NativePlayerMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let settingsItem = NSMenuItem()
    let item = NSMenuItem()

    private(set) var isOpen = false
    private let contentView: NSView
    private var contentSize: NSSize

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
        guard size != contentSize else { return }
        let previousSize = contentSize
        let previousWindowFrame = contentView.window?.frame
        contentSize = size
        menu.minimumWidth = size.width
        contentView.frame.size = size
        contentView.invalidateIntrinsicContentSize()
        menu.itemChanged(item)
        menu.update()

        guard
            isOpen,
            let window = contentView.window,
            let previousWindowFrame
        else { return }

        let expectedSize = NSSize(
            width: previousWindowFrame.width + size.width - previousSize.width,
            height: previousWindowFrame.height + size.height - previousSize.height
        )
        if abs(window.frame.width - expectedSize.width) > 0.5
            || abs(window.frame.height - expectedSize.height) > 0.5
            || abs(window.frame.maxY - previousWindowFrame.maxY) > 0.5 {
            var frame = window.frame
            let anchoredTop = previousWindowFrame.maxY
            frame.size = expectedSize
            frame.origin.y = anchoredTop - expectedSize.height
            window.setFrame(frame, display: true)
        }
    }

    var windowFrame: NSRect? { contentView.window?.frame }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        onWillOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        onDidClose?()
    }
}
