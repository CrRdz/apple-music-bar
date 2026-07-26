#!/bin/zsh

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <app-path> <dmg-path> <volume-name>" >&2
    exit 64
fi

APP_PATH="${1:A}"
DMG_PATH="${2:A}"
VOLUME_NAME="$3"
APP_NAME="${APP_PATH:t}"
APP_DISPLAY_NAME="${APP_NAME:r}"
WORK_DIR="$(mktemp -d)"
RW_DMG="$WORK_DIR/${VOLUME_NAME}.rw.dmg"
MOUNT_DIR="$WORK_DIR/mount"

cleanup() {
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "Application bundle not found: $APP_PATH" >&2
    exit 66
fi

mkdir -p "${DMG_PATH:h}" "$MOUNT_DIR"

hdiutil create \
    -size 96m \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -ov \
    "$RW_DMG" >/dev/null

hdiutil attach "$RW_DMG" -nobrowse -quiet -mountpoint "$MOUNT_DIR"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "Failed to mount temporary DMG." >&2
    exit 1
fi

ditto "$APP_PATH" "$MOUNT_DIR/$APP_NAME"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"

BACKGROUND_PATH="$MOUNT_DIR/.background/background.png"
swift - "$BACKGROUND_PATH" "$APP_DISPLAY_NAME" <<'SWIFT'
import AppKit
import Foundation

let outputPath = CommandLine.arguments[1]
let appName = CommandLine.arguments[2]
let size = NSSize(width: 560, height: 360)
let image = NSImage(size: size)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

image.lockFocus()
color(248, 249, 251).setFill()
NSRect(origin: .zero, size: size).fill()

let path = NSBezierPath(roundedRect: NSRect(x: 32, y: 44, width: 496, height: 272), xRadius: 24, yRadius: 24)
color(255, 255, 255, 0.88).setFill()
path.fill()
color(224, 228, 235).setStroke()
path.lineWidth = 1
path.stroke()

let title = "Install \(appName)"
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: color(31, 35, 42)
]
title.draw(at: NSPoint(x: 52, y: 258), withAttributes: titleAttributes)

let subtitle = "Drag the app into Applications"
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: color(103, 111, 124)
]
subtitle.draw(at: NSPoint(x: 54, y: 232), withAttributes: subtitleAttributes)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 232, y: 161))
arrow.line(to: NSPoint(x: 324, y: 161))
arrow.move(to: NSPoint(x: 304, y: 181))
arrow.line(to: NSPoint(x: 324, y: 161))
arrow.line(to: NSPoint(x: 304, y: 141))
color(255, 64, 105).setStroke()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

let footer = "Open \(appName) from Applications after copying."
let footerAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: color(130, 137, 150)
]
footer.draw(at: NSPoint(x: 54, y: 66), withAttributes: footerAttributes)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let data = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Unable to render DMG background.")
}

try data.write(to: URL(fileURLWithPath: outputPath))
SWIFT

/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
    set dmgFolder to POSIX file "$MOUNT_DIR" as alias
    tell folder dmgFolder
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {120, 120, 680, 480}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set text size of opts to 13
        set label position of opts to bottom
        set background picture of opts to (POSIX file "$BACKGROUND_PATH")
        set position of item "$APP_NAME" to {150, 170}
        set position of item "Applications" to {410, 170}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

if command -v SetFile >/dev/null 2>&1; then
    SetFile -a V "$MOUNT_DIR/.background"
elif xcrun -f SetFile >/dev/null 2>&1; then
    xcrun SetFile -a V "$MOUNT_DIR/.background"
fi

sync
hdiutil detach "$MOUNT_DIR" -quiet

hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" \
    >/dev/null
