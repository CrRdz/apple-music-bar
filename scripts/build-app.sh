#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="AppleMusicBar"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
SIGNING_IDENTITY="${APPLE_MUSIC_BAR_SIGN_IDENTITY:--}"
BUNDLE_ID="${APPLE_MUSIC_BAR_BUNDLE_ID:-}"

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swiftpm-cache"
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"

cp "$BIN_DIR/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -n "$BUNDLE_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
fi
chmod +x "$APP_PATH/Contents/MacOS/$APP_NAME"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_PATH"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP_PATH"
fi

echo "$APP_PATH"
