import AppKit
import XCTest
@testable import AppleMusicBar

final class MenuPreviewTests: XCTestCase {
    @MainActor
    func testRenderNowPlayingCardPreview() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["APPLE_MUSIC_BAR_MENU_PREVIEW"] else {
            throw XCTSkip("设置 APPLE_MUSIC_BAR_MENU_PREVIEW 后渲染菜单卡片预览")
        }

        _ = NSApplication.shared
        let view = NowPlayingMenuView()
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.updateAccessibility(play: "播放", pause: "暂停", next: "下一首")
        view.update(
            title: "是否 (Live Piano Session)",
            subtitle: "邓紫棋 — G.E.M. Live Piano Session",
            isPlaying: true,
            controlsEnabled: true
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
    private func makePreviewArtwork() -> NSImage {
        let image = NSImage(size: NSSize(width: 112, height: 112))
        image.lockFocus()
        NSColor(calibratedRed: 0.45, green: 0.34, blue: 0.66, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        symbol?.draw(
            in: NSRect(x: 38, y: 38, width: 36, height: 36),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.9
        )
        image.unlockFocus()
        return image
    }
}
