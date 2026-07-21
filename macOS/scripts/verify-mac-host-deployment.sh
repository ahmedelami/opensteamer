#!/bin/zsh
# End-to-end, read-only deployment oracle for the installed and currently running Mac host.
#
# Required environment: AUDIOSTREAMER_EXPECTED_TEAM_ID. Optional overrides are
# AUDIOSTREAMER_HOST_APP_PATH, AUDIOSTREAMER_HOST_BUILD_APP_PATH,
# AUDIOSTREAMER_HOST_LAUNCH_AGENT_LABEL, AUDIOSTREAMER_HOST_LAUNCH_AGENT_TEMPLATE,
# AUDIOSTREAMER_HOST_INSTALLED_LAUNCH_AGENT, and AUDIOSTREAMER_EXPECTED_HOST_PID. Run after building,
# installing, and loading the signed host.
#
# The script verifies fresh-versus-installed CDHashes, snapshots `launchctl print` into a temporary
# file, validates the loaded job, and binds its PID to the expected live executable/framework. The
# snapshot is removed on every exit. Success prints a key=value deployment manifest; any missing
# prerequisite or mismatch prints a diagnostic and exits nonzero without modifying launchd or apps.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR=${AUDIOSTREAMER_HOST_APP_PATH:-/Applications/AudioStreamer Host.app}
BUILD_APP_DIR=${AUDIOSTREAMER_HOST_BUILD_APP_PATH:-$ROOT_DIR/build/AudioStreamer Host.app}
HOST_LABEL=${AUDIOSTREAMER_HOST_LAUNCH_AGENT_LABEL:-org.example.audiostreamer.worldwide}
EXPECTED_TEAM_ID=${AUDIOSTREAMER_EXPECTED_TEAM_ID:?AUDIOSTREAMER_EXPECTED_TEAM_ID is required}
EXPECTED_EXECUTABLE="$APP_DIR/Contents/MacOS/CaptureServer"
EXPECTED_FRAMEWORK="$APP_DIR/Contents/Frameworks/LiveKitWebRTC.framework"
EXPECTED_FRAMEWORK_EXECUTABLE="$EXPECTED_FRAMEWORK/LiveKitWebRTC"
BUILD_FRAMEWORK="$BUILD_APP_DIR/Contents/Frameworks/LiveKitWebRTC.framework"
SERVICE="gui/${UID}/${HOST_LABEL}"
BUNDLE_VERIFIER="$ROOT_DIR/macOS/scripts/verify-mac-host-bundle.sh"
LIVE_PROCESS_VERIFIER="$ROOT_DIR/macOS/scripts/verify-live-mac-host-process.sh"
LAUNCH_STATE_VERIFIER="$ROOT_DIR/macOS/scripts/verify-mac-host-launch-state.sh"
LAUNCH_AGENT_TEMPLATE=${AUDIOSTREAMER_HOST_LAUNCH_AGENT_TEMPLATE:-$ROOT_DIR/macOS/LaunchAgents/org.example.audiostreamer.worldwide.plist}
INSTALLED_LAUNCH_AGENT=${AUDIOSTREAMER_HOST_INSTALLED_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/$HOST_LABEL.plist}

function fail() {
    print -u2 -- "AudioStreamer host deployment verification failed: $1"
    exit 1
}

function code_hash() {
    local target=$1
    /usr/bin/codesign -dv --verbose=4 "$target" 2>&1 \
        | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
}

[[ -x "$BUNDLE_VERIFIER" ]] || fail "bundle verifier is missing at $BUNDLE_VERIFIER"
[[ -x "$LIVE_PROCESS_VERIFIER" ]] || fail \
    "live-process verifier is missing at $LIVE_PROCESS_VERIFIER"
[[ -x "$LAUNCH_STATE_VERIFIER" ]] || fail \
    "launch-state verifier is missing at $LAUNCH_STATE_VERIFIER"
[[ ! -L "$APP_DIR" ]] || fail "installed host app must not be a symbolic link"
[[ ! -L "$EXPECTED_EXECUTABLE" ]] || fail "installed host executable must not be a symbolic link"

"$BUNDLE_VERIFIER" "$BUILD_APP_DIR" "$EXPECTED_TEAM_ID" >/dev/null
"$BUNDLE_VERIFIER" "$APP_DIR" "$EXPECTED_TEAM_ID" >/dev/null

# Matching all nested code objects prevents a copied outer bundle from masking a stale executable
# or WebRTC framework in the installed application.
build_app_hash=$(code_hash "$BUILD_APP_DIR")
installed_app_hash=$(code_hash "$APP_DIR")
build_executable_hash=$(code_hash "$BUILD_APP_DIR/Contents/MacOS/CaptureServer")
installed_executable_hash=$(code_hash "$EXPECTED_EXECUTABLE")
build_framework_hash=$(code_hash "$BUILD_FRAMEWORK")
installed_framework_hash=$(code_hash "$EXPECTED_FRAMEWORK")
[[ -n "$build_app_hash" && "$installed_app_hash" == "$build_app_hash" ]] \
    || fail "installed app CDHash does not match the freshly built host"
[[ -n "$build_executable_hash" && "$installed_executable_hash" == "$build_executable_hash" ]] \
    || fail "installed executable CDHash does not match the freshly built host"
[[ -n "$build_framework_hash" && "$installed_framework_hash" == "$build_framework_hash" ]] \
    || fail "installed framework CDHash does not match the freshly built host"

launch_state_file="$(/usr/bin/mktemp \
    "${TMPDIR:-/tmp}/audiostreamer-launch-state.XXXXXX")" \
    || fail "could not create a launch-state snapshot"
trap 'rm -f "$launch_state_file"' EXIT
# Capture one coherent launchd snapshot; downstream parsing never races multiple `launchctl` calls.
if ! /bin/launchctl print "$SERVICE" > "$launch_state_file" 2>/dev/null; then
    fail "launch agent $SERVICE is not loaded"
fi
launch_manifest=$(
    "$LAUNCH_STATE_VERIFIER" \
        "$launch_state_file" \
        "$EXPECTED_EXECUTABLE" \
        "$LAUNCH_AGENT_TEMPLATE" \
        "$INSTALLED_LAUNCH_AGENT"
) || fail "loaded launch agent does not match the source-controlled configuration"
program=$(print -r -- "$launch_manifest" \
    | /usr/bin/awk -F= '$1 == "program" { print substr($0, index($0, "=") + 1); exit }')
pid=$(print -r -- "$launch_manifest" \
    | /usr/bin/awk -F= '$1 == "pid" { print $2; exit }')
if [[ -n "${AUDIOSTREAMER_EXPECTED_HOST_PID:-}" \
    && "$pid" != "$AUDIOSTREAMER_EXPECTED_HOST_PID" ]]; then
    fail "launch agent PID is '$pid', expected '$AUDIOSTREAMER_EXPECTED_HOST_PID'"
fi
kill -0 "$pid" 2>/dev/null || fail "launch agent PID $pid is not alive"

live_manifest=$(
    "$LIVE_PROCESS_VERIFIER" \
        "$pid" \
        "$EXPECTED_EXECUTABLE" \
        "$build_executable_hash" \
        "org.example.AudioStreamer.CaptureServer" \
        "$EXPECTED_TEAM_ID" \
        "$EXPECTED_FRAMEWORK_EXECUTABLE"
) || fail "PID $pid does not match the freshly built signed executable"
live_process_hash=$(print -r -- "$live_manifest" \
    | /usr/bin/awk -F= '$1 == "live_cdhash" { print $2; exit }')
live_framework_identity=$(print -r -- "$live_manifest" \
    | /usr/bin/awk -F= '$1 == "live_framework_identity" { print $2; exit }')
[[ -n "$live_process_hash" ]] || fail "live-process verifier returned no CDHash"
[[ -n "$live_framework_identity" ]] \
    || fail "live-process verifier returned no framework identity"

# Stable output fields are suitable for human review or collection by higher-level validation.
print -r -- "label=$HOST_LABEL"
print -r -- "pid=$pid"
print -r -- "program=$program"
print -r -- "team=$EXPECTED_TEAM_ID"
print -r -- "app_cdhash=$installed_app_hash"
print -r -- "executable_cdhash=$installed_executable_hash"
print -r -- "framework_cdhash=$installed_framework_hash"
print -r -- "live_cdhash=$live_process_hash"
print -r -- "live_framework_identity=$live_framework_identity"
