#!/bin/zsh
# End-to-end, read-only deployment oracle for the side-by-side installed/running host.
set -euo pipefail
umask 077

readonly ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/../.." && pwd -P)"
readonly APP_DIR="/Applications/opensteamer Host.app"
readonly EXPECTED_EXECUTABLE="$APP_DIR/Contents/MacOS/CaptureServer"
readonly EXPECTED_FRAMEWORK="$APP_DIR/Contents/Frameworks/LiveKitWebRTC.framework"
readonly EXPECTED_FRAMEWORK_EXECUTABLE="$EXPECTED_FRAMEWORK/LiveKitWebRTC"
readonly HOST_LABEL="org.example.opensteamer.worldwide"
readonly USER_HOME="/Users/ahmed"
readonly INSTALLED_LAUNCH_AGENT="$USER_HOME/Library/LaunchAgents/$HOST_LABEL.plist"
readonly SOURCE_LAUNCH_AGENT="$ROOT_DIR/macOS/LaunchAgents/$HOST_LABEL.plist"
readonly LEGACY_LABEL="com.elamin.audiostreamer.worldwide"
readonly LEGACY_APP="/Applications/AudioStreamer Host.app"
readonly LEGACY_EXECUTABLE="$LEGACY_APP/Contents/MacOS/CaptureServer"
readonly LEGACY_PLIST="$USER_HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
readonly LEGACY_EXECUTABLE_SHA256="1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc"
readonly LEGACY_PLIST_SHA256="419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730"
readonly EXPECTED_TEAM_ID="MSMG8CJLB3"
readonly EXPECTED_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"
readonly LOCK_DIRECTORY="$USER_HOME/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime"
readonly LOCK_FILE="$LOCK_DIRECTORY/worldwide-host.lock"
readonly ONLINE_LOG="/var/tmp/opensteamer-worldwide-host.log"
readonly ONLINE_MARKER_PREFIX="[info] Worldwide paired-device availability is online"
readonly BUNDLE_VERIFIER="$ROOT_DIR/macOS/scripts/verify-mac-host-bundle.sh"
readonly LIVE_PROCESS_VERIFIER="$ROOT_DIR/macOS/scripts/verify-live-mac-host-process.sh"
readonly LAUNCH_STATE_VERIFIER="$ROOT_DIR/macOS/scripts/verify-mac-host-launch-state.sh"
readonly PINNED_BUNDLE_VERIFIER_SCRIPT="${OPENSTEAMER_PINNED_BUNDLE_VERIFIER_SCRIPT:-}"
readonly PINNED_LIVE_PROCESS_VERIFIER_SCRIPT="${OPENSTEAMER_PINNED_LIVE_PROCESS_VERIFIER_SCRIPT:-}"
readonly PINNED_LAUNCH_STATE_VERIFIER_SCRIPT="${OPENSTEAMER_PINNED_LAUNCH_STATE_VERIFIER_SCRIPT:-}"
readonly STABILITY_SECONDS=11
readonly STABILITY_SAMPLES=44
readonly STABILITY_SAMPLE_DELAY=0.25
readonly MAX_READINESS_LOG_SUFFIX_BYTES=8388608
readonly -a REQUIRED_SYSTEM_COMMANDS=(
    /bin/dd
    /bin/kill
    /bin/launchctl
    /bin/ps
    /bin/rm
    /bin/sleep
    /bin/zsh
    /usr/bin/awk
    /usr/bin/cmp
    /usr/bin/codesign
    /usr/bin/dirname
    /usr/bin/diff
    /usr/bin/grep
    /usr/bin/mktemp
    /usr/bin/shasum
    /usr/bin/stat
)

fail() {
    print -u2 -- "opensteamer host deployment verification failed: $*"
    exit 1
}

run_pinned_or_path() {
    local pinned_script="$1" logical_path="$2"
    shift 2
    if [[ -n "$pinned_script" ]]; then
        /bin/zsh -c "$pinned_script" "$logical_path" "$@"
    else
        "$logical_path" "$@"
    fi
}

run_bundle_verifier() {
    run_pinned_or_path "$PINNED_BUNDLE_VERIFIER_SCRIPT" "$BUNDLE_VERIFIER" "$@"
}

run_live_process_verifier() {
    run_pinned_or_path "$PINNED_LIVE_PROCESS_VERIFIER_SCRIPT" "$LIVE_PROCESS_VERIFIER" "$@"
}

run_launch_state_verifier() {
    run_pinned_or_path "$PINNED_LAUNCH_STATE_VERIFIER_SCRIPT" "$LAUNCH_STATE_VERIFIER" "$@"
}

# Classify only launchctl's explicit not-found diagnostic as absence. Every other nonzero exit is
# an operational failure. `status` is a read-only special parameter in zsh, so the captured exit
# code deliberately uses a non-special local name.
service_absence_is_proven() {
    local command_exit="$1" captured_stdout="$2" diagnostic="$3" label="$4"
    local expected_diagnostic=$'Bad request.\nCould not find service "'"$label"$'" in domain for user gui: '"$UID"
    [[ "$command_exit" -eq 113 && -z "$captured_stdout" \
        && "$diagnostic" == "$expected_diagnostic" ]]
}

require_service_absent_with_command() {
    (
        local label="$1" launchctl_exit diagnostic captured_stdout
        local capture_stdout_file="" capture_stderr_file=""
        shift
        trap '/bin/rm -f -- "$capture_stdout_file" "$capture_stderr_file"' EXIT HUP INT TERM
        capture_stdout_file="$(/usr/bin/mktemp /var/tmp/opensteamer-launch-out.XXXXXX)" || fail \
            "could not create launchctl capture"
        capture_stderr_file="$(/usr/bin/mktemp /var/tmp/opensteamer-launch-err.XXXXXX)" || fail \
            "could not create launchctl capture"
        if "$@" >"$capture_stdout_file" 2>"$capture_stderr_file"; then
            fail "launchd service is still loaded: $label"
        else
            launchctl_exit=$?
        fi
        diagnostic="$(<"$capture_stderr_file")"
        captured_stdout="$(<"$capture_stdout_file")"
        service_absence_is_proven \
            "$launchctl_exit" "$captured_stdout" "$diagnostic" "$label" || fail \
            "launchctl could not prove service absence for '$label': $diagnostic"
    )
}

require_service_absent() {
    local label="$1"
    require_service_absent_with_command \
        "$label" /bin/launchctl print "gui/$UID/$label"
}

parse_disabled_override() {
    local input="$1" label="$2"
    print -r -- "$input" | /usr/bin/awk -v label="$label" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value
        }
        /^[[:space:]]*$/ { next }
        !started {
            if (trim($0) != "disabled services = {") exit 70
            started=1
            next
        }
        closed { exit 71 }
        {
            line=trim($0)
            if (line == "}") { closed=1; next }
            if (line !~ /^"[^"]+" => (enabled|disabled|true|false)$/) exit 72
            split_at=index(line, " => ")
            key=substr(line, 2, split_at-3)
            value=substr(line, split_at+4)
            if (key == label) {
                matches += 1
                if (matches > 1) exit 73
                if (value == "disabled" || value == "true") result="disabled"
                else result="enabled"
            }
        }
        END {
            if (!started || !closed) exit 74
            if (matches == 0) print "missing"
            else print result
        }
    '
}

contains_exact_line() {
    local input="$1" expected="$2"
    # Do not use grep -q here. With pipefail, an early exact match can close the pipe while the
    # producer still has a bounded-but-large suffix to write, turning valid evidence into SIGPIPE.
    print -r -- "$input" | /usr/bin/grep -Fx -- "$expected" >/dev/null
}

self_test_disabled_parser() {
    local label="$LEGACY_LABEL" output
    output="$(parse_disabled_override $'disabled services = {\n    "other" => enabled\n}' "$label")" || fail \
        "disabled parser rejected a missing-label fixture"
    [[ "$output" == missing ]] || fail "missing-label fixture parsed as '$output'"
    output="$(parse_disabled_override $'disabled services = {\n    "com.elamin.audiostreamer.worldwide" => enabled\n}' "$label")" || fail \
        "disabled parser rejected enabled"
    [[ "$output" == enabled ]] || fail "enabled fixture parsed as '$output'"
    output="$(parse_disabled_override $'disabled services = {\n    "com.elamin.audiostreamer.worldwide" => disabled\n}' "$label")" || fail \
        "disabled parser rejected disabled"
    [[ "$output" == disabled ]] || fail "disabled fixture parsed as '$output'"
    output="$(parse_disabled_override $'disabled services = {\n    "com.elamin.audiostreamer.worldwide" => true\n}' "$label")" || fail \
        "disabled parser rejected unambiguous Boolean compatibility"
    [[ "$output" == disabled ]] || fail "Boolean fixture parsed as '$output'"
    parse_disabled_override $'disabled services = {\n    "com.elamin.audiostreamer.worldwide" => disabled\n    "com.elamin.audiostreamer.worldwide" => disabled\n}' "$label" >/dev/null 2>&1 && fail \
        "disabled parser accepted a duplicate"
    parse_disabled_override $'disabled services = {\n    "com.elamin.audiostreamer.worldwide" => maybe\n}' "$label" >/dev/null 2>&1 && fail \
        "disabled parser accepted a malformed value"
    print -r -- "SELF_TEST_OK disabled-parser"
}

self_test_zsh_runtime() {
    local required_command marker large_suffix padding=""
    for required_command in "${REQUIRED_SYSTEM_COMMANDS[@]}"; do
        [[ -f "$required_command" && ! -L "$required_command" && -x "$required_command" ]] || fail \
            "required system command is unavailable or redirected: $required_command"
    done
    require_service_absent_with_command \
        "isolated-self-test" /bin/zsh -c \
        'print -u2 -- "Bad request."; print -u2 -- "Could not find service \"isolated-self-test\" in domain for user gui: $UID"; exit 113'
    local exact_diagnostic=$'Bad request.\nCould not find service "isolated-self-test" in domain for user gui: '"$UID"
    service_absence_is_proven 0 "" "$exact_diagnostic" "isolated-self-test" && fail \
        "service-absence classifier accepted a successful command"
    service_absence_is_proven 42 "" "$exact_diagnostic" "isolated-self-test" && fail \
        "service-absence classifier accepted the wrong command exit"
    service_absence_is_proven 113 "unexpected" "$exact_diagnostic" "isolated-self-test" && fail \
        "service-absence classifier accepted stdout contamination"
    service_absence_is_proven 113 "" "$exact_diagnostic"$'\nPermission denied' \
        "isolated-self-test" && fail \
        "service-absence classifier accepted mixed diagnostics"
    service_absence_is_proven 113 "" "Permission denied" "isolated-self-test" && fail \
        "service-absence classifier accepted an unrelated diagnostic"
    marker="generation-bound-marker"
    large_suffix="$marker"$'\n'"${(l:262144::x:)padding}"
    contains_exact_line "$large_suffix" "$marker" || fail \
        "exact-line matcher rejected an early marker in a large bounded suffix"
    contains_exact_line "${marker}-suffix" "$marker" && fail \
        "exact-line matcher accepted a substring marker"
    print -r -- "SELF_TEST_OK zsh-runtime"
}

if (( $# == 1 )) && [[ "$1" == --self-test-disabled-parser ]]; then
    self_test_disabled_parser
    exit 0
elif (( $# == 1 )) && [[ "$1" == --self-test-zsh-runtime ]]; then
    self_test_zsh_runtime
    exit 0
fi

if (( $# != 12 )); then
    print -u2 -- \
        "usage: $0 <fresh-staged-app> <offline-legacy-executable> <reviewed-launch-agent-plist> <generation-log-offset> <log-device> <log-inode> <expected-pid> <expected-runs> <expected-process-start> <expected-generation-nonce> <lock-device> <lock-inode>"
    exit 64
fi
BUILD_APP_DIR="${1%/}"
DESIGNATED_REQUIREMENT_REFERENCE="${2%/}"
REVIEWED_LAUNCH_AGENT="$3"
LOG_OFFSET="$4"
LOG_DEVICE="$5"
LOG_INODE="$6"
EXPECTED_PID="$7"
EXPECTED_RUNS="$8"
EXPECTED_PROCESS_START="$9"
EXPECTED_GENERATION_NONCE="${10}"
EXPECTED_LOCK_DEVICE="${11}"
EXPECTED_LOCK_INODE="${12}"
case "$LOG_OFFSET" in
    ''|*[!0-9]*) fail "generation-bound log offset must be a nonnegative integer" ;;
esac
for identity_value in "$LOG_DEVICE" "$LOG_INODE" "$EXPECTED_RUNS" \
    "$EXPECTED_LOCK_DEVICE" "$EXPECTED_LOCK_INODE"; do
    case "$identity_value" in
        ''|*[!0-9]*) fail "generation identity values must be nonnegative integers" ;;
    esac
done
case "$EXPECTED_PID" in
    *[!0-9]*|0|'') fail "expected PID must be a positive integer" ;;
esac
[[ "$EXPECTED_RUNS" != 0 ]] || fail "expected launchd runs must be positive"
[[ -n "$EXPECTED_PROCESS_START" && "$EXPECTED_PROCESS_START" != *$'\n'* \
    && "$EXPECTED_PROCESS_START" != *$'\r'* ]] || fail "expected process start identity is malformed"
print -r -- "$EXPECTED_GENERATION_NONCE" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || fail \
    "expected generation nonce must be 64 lowercase hexadecimal characters"
readonly EXPECTED_ONLINE_MARKER="$ONLINE_MARKER_PREFIX pid=$EXPECTED_PID nonce=$EXPECTED_GENERATION_NONCE"

sha256_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
code_hash() {
    /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print tolower($2); exit}'
}

require_legacy_disabled() {
    local output state
    output="$(/bin/launchctl print-disabled "gui/$UID" 2>&1)" || fail \
        "launchctl could not read persistent disabled state: $output"
    state="$(parse_disabled_override "$output" "$LEGACY_LABEL")" || fail \
        "launchctl returned malformed or ambiguous disabled-state output"
    [[ "$state" == disabled ]] || fail \
        "legacy launchd label is not durably disabled: $state"
}

capture_processes() {
    local output
    output="$(/bin/ps -ww -axo pid=,comm= 2>&1)" || fail "ps could not enumerate processes: $output"
    print -r -- "$output"
}

validate_process_snapshot() {
    print -r -- "$1" | /usr/bin/awk '
        NF == 0 { next }
        {
            pid=$1
            if (pid !~ /^[0-9]+$/) exit 2
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
            if ($0 == "") exit 3
        }
    ' >/dev/null || fail "ps returned malformed process output"
}

exact_pids() {
    local executable="$1"
    print -r -- "$PROCESS_SNAPSHOT" | /usr/bin/awk -v expected="$executable" '
        { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0); if ($0 == expected) print pid }
    '
}

other_capture_servers() {
    print -r -- "$PROCESS_SNAPSHOT" | /usr/bin/awk -v expected="$EXPECTED_EXECUTABLE" '
        { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0); if ($0 ~ /\/CaptureServer$/ && $0 != expected) print pid ":" $0 }
    '
}

if [[ -n "$PINNED_BUNDLE_VERIFIER_SCRIPT$PINNED_LIVE_PROCESS_VERIFIER_SCRIPT$PINNED_LAUNCH_STATE_VERIFIER_SCRIPT" ]]; then
    [[ -n "$PINNED_BUNDLE_VERIFIER_SCRIPT" && -n "$PINNED_LIVE_PROCESS_VERIFIER_SCRIPT" \
        && -n "$PINNED_LAUNCH_STATE_VERIFIER_SCRIPT" ]] || fail \
        "pinned deployment verifier set is incomplete"
else
    [[ -x "$BUNDLE_VERIFIER" && -x "$LIVE_PROCESS_VERIFIER" && -x "$LAUNCH_STATE_VERIFIER" ]] || fail \
        "one or more deployment verifiers are missing"
fi
[[ -d "$BUILD_APP_DIR" && ! -L "$BUILD_APP_DIR" ]] || fail "staged app is not a real directory"
[[ -f "$DESIGNATED_REQUIREMENT_REFERENCE" && ! -L "$DESIGNATED_REQUIREMENT_REFERENCE" ]] || fail \
    "offline legacy reference is not a real file"
[[ -f "$REVIEWED_LAUNCH_AGENT" && ! -L "$REVIEWED_LAUNCH_AGENT" ]] || fail \
    "reviewed LaunchAgent is not a real file"

# Side-by-side rollback sources remain present and unchanged while unloaded.
[[ -d "$LEGACY_APP" && ! -L "$LEGACY_APP" ]] || fail "untouched legacy app is missing"
[[ -f "$LEGACY_EXECUTABLE" && ! -L "$LEGACY_EXECUTABLE" ]] || fail "legacy executable is missing"
[[ -f "$LEGACY_PLIST" && ! -L "$LEGACY_PLIST" ]] || fail "untouched legacy plist is missing"
[[ "$(sha256_file "$LEGACY_EXECUTABLE")" == "$LEGACY_EXECUTABLE_SHA256" ]] || fail \
    "legacy executable bytes changed during side-by-side migration"
[[ "$(sha256_file "$LEGACY_PLIST")" == "$LEGACY_PLIST_SHA256" ]] || fail \
    "legacy plist bytes changed during side-by-side migration"
[[ "$(sha256_file "$DESIGNATED_REQUIREMENT_REFERENCE")" == "$LEGACY_EXECUTABLE_SHA256" ]] || fail \
    "offline legacy snapshot hash is wrong"
require_service_absent "$LEGACY_LABEL"
require_legacy_disabled

[[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] || fail "installed new app is not a real directory"
[[ -f "$INSTALLED_LAUNCH_AGENT" && ! -L "$INSTALLED_LAUNCH_AGENT" ]] || fail \
    "installed new LaunchAgent is not a real file"
run_launch_state_verifier --verify-plist "$EXPECTED_EXECUTABLE" "$SOURCE_LAUNCH_AGENT" >/dev/null
run_launch_state_verifier --verify-plist "$EXPECTED_EXECUTABLE" "$REVIEWED_LAUNCH_AGENT" >/dev/null
/usr/bin/cmp -s "$SOURCE_LAUNCH_AGENT" "$REVIEWED_LAUNCH_AGENT" || fail \
    "reviewed LaunchAgent bytes differ from checked-in contract"
/usr/bin/cmp -s "$REVIEWED_LAUNCH_AGENT" "$INSTALLED_LAUNCH_AGENT" || fail \
    "installed LaunchAgent bytes differ from reviewed contract"
run_bundle_verifier "$BUILD_APP_DIR" "$EXPECTED_TEAM_ID" "$DESIGNATED_REQUIREMENT_REFERENCE" >/dev/null
run_bundle_verifier --installed-runtime \
    "$APP_DIR" "$EXPECTED_TEAM_ID" "$DESIGNATED_REQUIREMENT_REFERENCE" >/dev/null
/usr/bin/diff -qr "$BUILD_APP_DIR" "$APP_DIR" >/dev/null || fail \
    "installed app bytes differ from fresh staged app"

build_app_hash="$(code_hash "$BUILD_APP_DIR")"
installed_app_hash="$(code_hash "$APP_DIR")"
build_executable_hash="$(code_hash "$BUILD_APP_DIR/Contents/MacOS/CaptureServer")"
installed_executable_hash="$(code_hash "$EXPECTED_EXECUTABLE")"
build_framework_hash="$(code_hash "$BUILD_APP_DIR/Contents/Frameworks/LiveKitWebRTC.framework")"
installed_framework_hash="$(code_hash "$EXPECTED_FRAMEWORK")"
[[ -n "$build_app_hash" && "$installed_app_hash" == "$build_app_hash" ]] || fail "app CDHash mismatch"
[[ -n "$build_executable_hash" && "$installed_executable_hash" == "$build_executable_hash" ]] || fail \
    "executable CDHash mismatch"
[[ -n "$build_framework_hash" && "$installed_framework_hash" == "$build_framework_hash" ]] || fail \
    "framework CDHash mismatch"

state_one="$(/usr/bin/mktemp /var/tmp/opensteamer-launch-one.XXXXXX)" || fail "could not create state capture"
state_two="$(/usr/bin/mktemp /var/tmp/opensteamer-launch-two.XXXXXX)" || fail "could not create state capture"
trap '/bin/rm -f "$state_one" "$state_two"' EXIT
capture_state() {
    local state_path="$1"
    /bin/launchctl print "gui/$UID/$HOST_LABEL" >"$state_path" 2>/dev/null || fail \
        "new LaunchAgent is not loaded"
    run_launch_state_verifier "$state_path" "$EXPECTED_EXECUTABLE" \
        "$REVIEWED_LAUNCH_AGENT" "$INSTALLED_LAUNCH_AGENT"
}

manifest_one="$(capture_state "$state_one")" || fail "first launch-state validation failed"
pid_one="$(print -r -- "$manifest_one" | /usr/bin/awk -F= '$1 == "pid" {print $2; exit}')"
runs_one="$(print -r -- "$manifest_one" | /usr/bin/awk -F= '$1 == "runs" {print $2; exit}')"
[[ -n "$pid_one" && -n "$runs_one" ]] || fail "first launch-state manifest is incomplete"
[[ "$pid_one" == "$EXPECTED_PID" ]] || fail \
    "launch agent PID is '$pid_one', expected '$EXPECTED_PID'"
[[ "$runs_one" == "$EXPECTED_RUNS" ]] || fail \
    "launch agent runs is '$runs_one', expected '$EXPECTED_RUNS'"
/bin/kill -0 "$pid_one" 2>/dev/null || fail "new PID is not alive"

PROCESS_SNAPSHOT="$(capture_processes)"
validate_process_snapshot "$PROCESS_SNAPSHOT"
[[ "$(exact_pids "$EXPECTED_EXECUTABLE")" == "$pid_one" ]] || fail \
    "installed executable does not have exactly the launchd PID"
[[ -z "$(other_capture_servers)" ]] || fail "another CaptureServer is running"

# Error-checked holder attribution and the nonblocking flock/inode proof are implemented by the
# exact freshly compiled Rust controller binary that owns this migration transaction.
CONTROLLER_BINARY="${OPENSTEAMER_MIGRATION_CONTROLLER_BINARY:-}"
[[ -n "$CONTROLLER_BINARY" && -f "$CONTROLLER_BINARY" && ! -L "$CONTROLLER_BINARY" \
    && -x "$CONTROLLER_BINARY" ]] || fail "fresh Rust controller binary is unavailable for lock proof"
LOCK_PROBE_OUTPUT="$("$CONTROLLER_BINARY" --probe-lock "$LOCK_DIRECTORY" "$LOCK_FILE" "$pid_one")" \
    || fail "shared-lock proof failed: $LOCK_PROBE_OUTPUT"
[[ "$LOCK_PROBE_OUTPUT" == "lock_holder=$pid_one" ]] || fail \
    "shared-lock proof returned unexpected output: $LOCK_PROBE_OUTPUT"

live_one="$(run_live_process_verifier "$pid_one" "$EXPECTED_EXECUTABLE" \
    "$build_executable_hash" "$EXPECTED_IDENTIFIER" "$EXPECTED_TEAM_ID" "$EXPECTED_FRAMEWORK_EXECUTABLE")" \
    || fail "first live-process verification failed"
start_one="$(/bin/ps -p "$pid_one" -o lstart= 2>/dev/null)" || fail "could not read process start identity"
[[ "$start_one" == "$EXPECTED_PROCESS_START" ]] || fail \
    "process start identity differs from the controller-observed generation"

validate_generation_record() {
    local before after content expected
    [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || fail \
        "generation lock is not a real regular file"
    [[ "$(/usr/bin/stat -f '%l' "$LOCK_FILE")" == 1 ]] || fail \
        "generation lock must have one hard link"
    [[ "$(/usr/bin/stat -f '%Lp' "$LOCK_FILE")" == 600 ]] || fail \
        "generation lock mode must be 0600"
    before="$(/usr/bin/stat -f '%d:%i' "$LOCK_FILE")" || fail \
        "could not inspect generation lock identity"
    [[ "$before" == "$EXPECTED_LOCK_DEVICE:$EXPECTED_LOCK_INODE" ]] || fail \
        "generation lock inode differs from the controller-observed generation"
    content="$(<"$LOCK_FILE")" || fail "could not read generation record"
    after="$(/usr/bin/stat -f '%d:%i' "$LOCK_FILE")" || fail \
        "could not reinspect generation lock identity"
    [[ "$after" == "$before" ]] || fail "generation lock changed while being read"
    expected=$'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid='"$EXPECTED_PID"$'\nnonce='"$EXPECTED_GENERATION_NONCE"
    [[ "$content" == "$expected" ]] || fail \
        "generation record is not bound to the expected PID and nonce"
}
validate_generation_record

[[ -f "$ONLINE_LOG" && ! -L "$ONLINE_LOG" ]] || fail "online log is not a real regular file"
[[ "$(/usr/bin/stat -f '%l' "$ONLINE_LOG")" == 1 ]] || fail "online log must have one hard link"
log_size="$(/usr/bin/stat -f '%z' "$ONLINE_LOG")" || fail "could not inspect online log size"
log_device="$(/usr/bin/stat -f '%d' "$ONLINE_LOG")" || fail "could not inspect online log device"
log_inode="$(/usr/bin/stat -f '%i' "$ONLINE_LOG")" || fail "could not inspect online log inode"
[[ "$log_device" == "$LOG_DEVICE" && "$log_inode" == "$LOG_INODE" ]] || fail \
    "online log inode differs from the pre-start checkpoint"
[[ "$log_size" -ge "$LOG_OFFSET" ]] || fail "online log shrank below the pre-start offset"
LOG_SUFFIX_BYTES=$((log_size - LOG_OFFSET))
(( LOG_SUFFIX_BYTES <= MAX_READINESS_LOG_SUFFIX_BYTES )) || fail \
    "post-start log suffix exceeds the bounded readiness limit"
readonly LOG_READ_LIMIT=$((MAX_READINESS_LOG_SUFFIX_BYTES + 1))
LOG_SUFFIX="$(/bin/dd if="$ONLINE_LOG" bs=1 skip="$LOG_OFFSET" \
    count="$LOG_READ_LIMIT" 2>/dev/null)" || fail \
    "could not read post-start log suffix"
[[ "$(/usr/bin/stat -f '%d:%i' "$ONLINE_LOG")" == "$LOG_DEVICE:$LOG_INODE" ]] || fail \
    "online log inode changed while reading readiness evidence"
log_size_after="$(/usr/bin/stat -f '%z' "$ONLINE_LOG")" || fail \
    "could not reinspect online log size"
[[ "$log_size_after" -ge "$LOG_OFFSET" ]] || fail \
    "online log shrank while reading readiness evidence"
LOG_SUFFIX_BYTES=$((log_size_after - LOG_OFFSET))
(( LOG_SUFFIX_BYTES <= MAX_READINESS_LOG_SUFFIX_BYTES )) || fail \
    "post-start log suffix exceeds the bounded readiness limit"
contains_exact_line "$LOG_SUFFIX" "$EXPECTED_ONLINE_MARKER" || fail \
    "no generation-bound post-start online readiness record was observed"

sample=0
manifest_two="$manifest_one"
pid_two="$pid_one"
runs_two="$runs_one"
while (( sample < STABILITY_SAMPLES )); do
    /bin/sleep "$STABILITY_SAMPLE_DELAY"
    manifest_two="$(capture_state "$state_two")" || fail \
        "continuous launch-state validation failed at sample $sample"
    pid_two="$(print -r -- "$manifest_two" \
        | /usr/bin/awk -F= '$1 == "pid" {print $2; exit}')"
    runs_two="$(print -r -- "$manifest_two" \
        | /usr/bin/awk -F= '$1 == "runs" {print $2; exit}')"
    [[ "$pid_two" == "$pid_one" ]] || fail \
        "PID changed during the continuous throttle-interval proof"
    [[ "$runs_two" == "$runs_one" && "$runs_two" == "$EXPECTED_RUNS" ]] || fail \
        "launch count changed during the continuous throttle-interval proof"
    [[ "$(/bin/ps -p "$pid_two" -o lstart= 2>/dev/null)" == "$start_one" ]] || fail \
        "PID start identity changed during the continuous proof"
    validate_generation_record
    require_service_absent "$LEGACY_LABEL"
    require_legacy_disabled
    PROCESS_SNAPSHOT="$(capture_processes)"
    validate_process_snapshot "$PROCESS_SNAPSHOT"
    [[ "$(exact_pids "$EXPECTED_EXECUTABLE")" == "$pid_two" ]] || fail \
        "new process set changed during the continuous proof"
    [[ -z "$(other_capture_servers)" ]] || fail \
        "another CaptureServer appeared during the continuous proof"
    LOCK_PROBE_OUTPUT="$("$CONTROLLER_BINARY" --probe-lock \
        "$LOCK_DIRECTORY" "$LOCK_FILE" "$pid_two")" || fail \
        "shared-lock proof failed during continuous sample $sample"
    [[ "$LOCK_PROBE_OUTPUT" == "lock_holder=$pid_two" ]] || fail \
        "shared-lock proof changed during continuous sample $sample"
    sample=$((sample + 1))
done
live_two="$(run_live_process_verifier "$pid_two" "$EXPECTED_EXECUTABLE" \
    "$build_executable_hash" "$EXPECTED_IDENTIFIER" "$EXPECTED_TEAM_ID" "$EXPECTED_FRAMEWORK_EXECUTABLE")" \
    || fail "final live-process verification failed"
[[ "$live_two" == "$live_one" ]] || fail \
    "live code identity changed across the continuous throttle interval"

print -r -- "label=$HOST_LABEL"
print -r -- "pid=$pid_two"
print -r -- "runs=$runs_two"
print -r -- "process_start=$start_one"
print -r -- "generation_nonce=$EXPECTED_GENERATION_NONCE"
print -r -- "generation_lock=$EXPECTED_LOCK_DEVICE:$EXPECTED_LOCK_INODE"
print -r -- "team=$EXPECTED_TEAM_ID"
print -r -- "app_cdhash=$installed_app_hash"
print -r -- "executable_cdhash=$installed_executable_hash"
print -r -- "framework_cdhash=$installed_framework_hash"
print -r -- "stable_seconds=$STABILITY_SECONDS"
print -r -- "fresh_online_log_offset=$LOG_OFFSET"
