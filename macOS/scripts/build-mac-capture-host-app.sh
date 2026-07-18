#!/bin/zsh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT_DIR/build/MacCaptureHost.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

# Keychain item access is bound to the executable's designated requirement. An
# ad-hoc signature is only a changing CDHash, so rebuilding the host would make
# macOS treat it as a new application and prompt for the pairing secrets again.
# Prefer a stable local development identity when one exists; CI or another Mac
# can explicitly select an identity (including "-" for ad-hoc) with this env var.
SIGNING_IDENTITY="${MAC_CAPTURE_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$({
        security find-identity -v -p codesigning 2>/dev/null || true
    } | awk '/"Apple Development:/{print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "warning: no Apple Development identity found; Keychain access may prompt after rebuilds" >&2
fi

cd "$ROOT_DIR"
swift build --product CaptureServer
BIN_DIR="$(swift build --show-bin-path)"
EXECUTABLE_SOURCE="$BIN_DIR/CaptureServer"
WEBRTC_FRAMEWORK_SOURCE="$BIN_DIR/LiveKitWebRTC.framework"
EXECUTABLE="$MACOS_DIR/CaptureServer"
WEBRTC_FRAMEWORK="$FRAMEWORKS_DIR/LiveKitWebRTC.framework"

if [[ ! -x "$EXECUTABLE_SOURCE" ]]; then
    echo "CaptureServer build product is missing: $EXECUTABLE_SOURCE" >&2
    exit 1
fi

if [[ ! -d "$WEBRTC_FRAMEWORK_SOURCE" ]]; then
    echo "LiveKitWebRTC build artifact is missing: $WEBRTC_FRAMEWORK_SOURCE" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR"
cp "$EXECUTABLE_SOURCE" "$EXECUTABLE"
cp -R "$WEBRTC_FRAMEWORK_SOURCE" "$WEBRTC_FRAMEWORK"
cp "macOS/MacCaptureHost/Info.plist" "$CONTENTS_DIR/Info.plist"

if ! otool -l "$EXECUTABLE" | grep -Fq "path @executable_path/../Frameworks "; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
fi

codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$WEBRTC_FRAMEWORK"
codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier org.example.AudioStreamer.CaptureServer \
    --timestamp=none \
    "$EXECUTABLE"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Signed MacCaptureHost with: $SIGNING_IDENTITY" >&2
echo "$APP_DIR"
