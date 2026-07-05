#!/bin/zsh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT_DIR/build/MacCaptureHost.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build --product CaptureServer

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/arm64-apple-macosx/debug/CaptureServer" "$MACOS_DIR/CaptureServer"
cp "macOS/MacCaptureHost/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - --timestamp=none "$APP_DIR"
echo "$APP_DIR"
