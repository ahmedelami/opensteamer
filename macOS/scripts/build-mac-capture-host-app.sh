#!/bin/zsh
# Builds, assembles, signs, and verifies `AudioStreamer Host.app` from the repository root.
#
# Usage: run without arguments. SwiftPM, Xcode command-line tools, and macOS `codesign` tooling
# must be available. The script deletes and recreates only the target app bundle beneath the output
# directory, then prints its absolute path on stdout. Diagnostics and signing identity go to stderr.
#
# Environment:
# - MAC_CAPTURE_APP_OUTPUT_DIR: destination parent (defaults to `<repo>/build`).
# - MAC_CAPTURE_PREBUILT_BIN_DIR: reuse already-built SwiftPM products instead of invoking a build.
# - MAC_CAPTURE_CODESIGN_IDENTITY: explicit identity; `-` selects ad-hoc signing.
# - MAC_CAPTURE_EXPECTED_TEAM_ID: optional TeamIdentifier enforced by the final verifier.
#
# Any missing product, packaging, rpath, signing, or verification failure exits nonzero before the
# final path is printed. A successful run leaves a complete signed app bundle at that path.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_OUTPUT_DIR="${MAC_CAPTURE_APP_OUTPUT_DIR:-$ROOT_DIR/build}"
APP_DIR="$APP_OUTPUT_DIR/AudioStreamer Host.app"
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
if [[ -n "${MAC_CAPTURE_PREBUILT_BIN_DIR:-}" ]]; then
    # Integration tests already hold SwiftPM's workspace lock. Reuse the exact
    # products compiled for that test run while still exercising all packaging,
    # rpath, signing, and artifact-verification steps below.
    BIN_DIR="$MAC_CAPTURE_PREBUILT_BIN_DIR"
else
    swift build --product CaptureServer
    BIN_DIR="$(swift build --show-bin-path)"
fi
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
# Bundle assembly is intentionally from a clean destination so removed frameworks or metadata
# cannot survive from an earlier build and accidentally satisfy verification.
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR"
cp "$EXECUTABLE_SOURCE" "$EXECUTABLE"
cp -R "$WEBRTC_FRAMEWORK_SOURCE" "$WEBRTC_FRAMEWORK"
cp "macOS/MacCaptureHost/Info.plist" "$CONTENTS_DIR/Info.plist"

if ! otool -l "$EXECUTABLE" | grep -Fq "path @executable_path/../Frameworks "; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
fi

codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$WEBRTC_FRAMEWORK"
# Sign from the innermost code outward so the final app seal covers the signed framework and main
# executable exactly as they will be installed.
codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier org.example.AudioStreamer.CaptureServer \
    --timestamp=none \
    "$EXECUTABLE"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"

VERIFY_ARGUMENTS=("$APP_DIR")
if [[ -n "${MAC_CAPTURE_EXPECTED_TEAM_ID:-}" ]]; then
    VERIFY_ARGUMENTS+=("$MAC_CAPTURE_EXPECTED_TEAM_ID")
fi
"$ROOT_DIR/macOS/scripts/verify-mac-host-bundle.sh" "${VERIFY_ARGUMENTS[@]}"

echo "Signed AudioStreamer Host with: $SIGNING_IDENTITY" >&2
echo "$APP_DIR"
