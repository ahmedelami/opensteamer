#!/bin/zsh
# Read-only verifier for the exact signed code mapped by a running host process.
set -euo pipefail

fail() {
    print -u2 -- "verify-live-mac-host-process: $*"
    exit 1
}

is_positive_decimal() {
    [[ -n "$1" ]] || return 1
    case "$1" in (*[!0-9]*|0) return 1 ;; esac
    return 0
}

if (( $# != 6 )); then
    print -u2 -- \
        "usage: $0 <pid> <expected-executable> <expected-cdhash> <expected-identifier> <expected-team-id> <expected-framework-executable>"
    exit 64
fi

PID="$1"
EXPECTED_EXECUTABLE_INPUT="${2%/}"
EXPECTED_CDHASH="${3:l}"
EXPECTED_IDENTIFIER="$4"
EXPECTED_TEAM_ID="$5"
EXPECTED_FRAMEWORK_INPUT="${6%/}"

is_positive_decimal "$PID" || fail "PID must be a positive integer"
[[ -f "$EXPECTED_EXECUTABLE_INPUT" && ! -L "$EXPECTED_EXECUTABLE_INPUT" ]] || fail \
    "expected executable is not a real regular file"
[[ "$(/usr/bin/stat -f '%l' "$EXPECTED_EXECUTABLE_INPUT")" == 1 ]] || fail \
    "expected executable must have one hard link"
EXPECTED_EXECUTABLE="${EXPECTED_EXECUTABLE_INPUT:A}"
[[ -x "$EXPECTED_EXECUTABLE" ]] || fail "expected executable is not executable"
[[ "$EXPECTED_CDHASH" =~ ^[[:xdigit:]]{40}$ ]] || fail \
    "expected CDHash must contain exactly 40 hexadecimal characters"
[[ -n "$EXPECTED_IDENTIFIER" ]] || fail "expected identifier must not be empty"
if [[ "$EXPECTED_TEAM_ID" != "not set" ]]; then
    [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail \
        "expected TeamIdentifier must be 10 uppercase alphanumeric characters"
fi
[[ -f "$EXPECTED_FRAMEWORK_INPUT" ]] || fail "expected framework executable does not exist"
if [[ -L "$EXPECTED_FRAMEWORK_INPUT" ]]; then
    [[ "$EXPECTED_FRAMEWORK_INPUT" == */LiveKitWebRTC.framework/LiveKitWebRTC ]] || fail \
        "only the reviewed LiveKitWebRTC framework executable alias may be a symlink"
    framework_root="${EXPECTED_FRAMEWORK_INPUT:h:A}"
    framework_target="$(/usr/bin/readlink "$EXPECTED_FRAMEWORK_INPUT")" || fail \
        "could not read framework executable alias"
    [[ -n "$framework_target" && "$framework_target" != /* ]] || fail \
        "framework executable alias target must be nonempty and relative"
    EXPECTED_FRAMEWORK_EXECUTABLE="${EXPECTED_FRAMEWORK_INPUT:A}"
    [[ "$EXPECTED_FRAMEWORK_EXECUTABLE" == "$framework_root/"* ]] || fail \
        "framework executable alias escapes LiveKitWebRTC.framework"
else
    EXPECTED_FRAMEWORK_EXECUTABLE="${EXPECTED_FRAMEWORK_INPUT:A}"
fi
[[ -f "$EXPECTED_FRAMEWORK_EXECUTABLE" && ! -L "$EXPECTED_FRAMEWORK_EXECUTABLE" ]] || fail \
    "resolved framework executable is not a real regular file"
[[ "$(/usr/bin/stat -f '%l' "$EXPECTED_FRAMEWORK_EXECUTABLE")" == 1 ]] || fail \
    "resolved framework executable must have one hard link"
[[ -x "$EXPECTED_FRAMEWORK_EXECUTABLE" ]] || fail "expected framework executable is not executable"

/bin/kill -0 "$PID" 2>/dev/null || fail "PID $PID is not alive"
START_BEFORE="$(/bin/ps -p "$PID" -o lstart= 2>/dev/null)" || fail \
    "could not read process start identity for PID $PID"
[[ -n "$START_BEFORE" ]] || fail "process start identity is empty"

# `lsof` exit status and output are both checked. Permission/command failures cannot become
# accidental evidence that a mapping is absent.
text_file="$(/usr/bin/mktemp /var/tmp/opensteamer-live-text.XXXXXX)" || fail "could not create lsof capture"
text_error="$(/usr/bin/mktemp /var/tmp/opensteamer-live-text-error.XXXXXX)" || fail "could not create lsof error capture"
framework_file="$(/usr/bin/mktemp /var/tmp/opensteamer-live-framework.XXXXXX)" || fail "could not create framework capture"
framework_error="$(/usr/bin/mktemp /var/tmp/opensteamer-live-framework-error.XXXXXX)" || fail "could not create framework error capture"
trap '/bin/rm -f "$text_file" "$text_error" "$framework_file" "$framework_error"' EXIT
if ! /usr/sbin/lsof -a -p "$PID" -d txt -Fn >"$text_file" 2>"$text_error"; then
    fail "lsof could not inspect executable mappings: $(<"$text_error")"
fi
LIVE_TEXT_FILES="$(/usr/bin/sed -n 's/^n//p' "$text_file")"
[[ "$(print -r -- "$LIVE_TEXT_FILES" | /usr/bin/grep -Fxc "$EXPECTED_EXECUTABLE")" == 1 ]] || fail \
    "PID $PID is not executing the expected path: $EXPECTED_EXECUTABLE"
OTHER_CAPTURE_TEXT="$(print -r -- "$LIVE_TEXT_FILES" | /usr/bin/awk -v expected="$EXPECTED_EXECUTABLE" \
    '$0 ~ /\/CaptureServer( \(deleted\))?$/ && $0 != expected { print }')"
[[ -z "$OTHER_CAPTURE_TEXT" ]] || fail \
    "PID $PID has an additional or deleted CaptureServer text mapping: $OTHER_CAPTURE_TEXT"

EXPECTED_FRAMEWORK_DEVICE_DECIMAL="$(/usr/bin/stat -f '%d' "$EXPECTED_FRAMEWORK_EXECUTABLE")" || fail \
    "could not inspect framework device"
EXPECTED_FRAMEWORK_DEVICE="$(/usr/bin/printf '0x%x' "$EXPECTED_FRAMEWORK_DEVICE_DECIMAL")"
EXPECTED_FRAMEWORK_INODE="$(/usr/bin/stat -f '%i' "$EXPECTED_FRAMEWORK_EXECUTABLE")" || fail \
    "could not inspect framework inode"
EXPECTED_FRAMEWORK_IDENTITY="${EXPECTED_FRAMEWORK_DEVICE:l}:$EXPECTED_FRAMEWORK_INODE"
if ! /usr/sbin/lsof -a -p "$PID" -FDin >"$framework_file" 2>"$framework_error"; then
    fail "lsof could not inspect framework mappings: $(<"$framework_error")"
fi
LIVE_FRAMEWORK_IDENTITIES="$(/usr/bin/awk \
    -v expected="$EXPECTED_FRAMEWORK_EXECUTABLE" \
    -v alias="$EXPECTED_FRAMEWORK_INPUT" '
    /^f/ { device=""; inode="" }
    /^D/ { device=tolower(substr($0,2)) }
    /^i/ { inode=substr($0,2) }
    /^n/ {
        path=substr($0,2)
        if (path == expected || path == expected " (deleted)" || path == alias || path == alias " (deleted)") {
            print device ":" inode
        }
    }
' "$framework_file" | LC_ALL=C /usr/bin/sort -u)"
[[ "$(print -r -- "$LIVE_FRAMEWORK_IDENTITIES" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == 1 \
    && "$LIVE_FRAMEWORK_IDENTITIES" == "$EXPECTED_FRAMEWORK_IDENTITY" ]] || fail \
    "live framework mapping: expected '$EXPECTED_FRAMEWORK_IDENTITY', found '${LIVE_FRAMEWORK_IDENTITIES:-not mapped}'"

/usr/bin/codesign --verify --strict --verbose=1 "$PID" || fail \
    "PID $PID failed dynamic code-signature validation"
LIVE_METADATA="$(/usr/bin/codesign --display --verbose=4 "+$PID" 2>&1)" || fail \
    "could not read dynamic code-signature metadata for PID $PID"
LIVE_IDENTIFIER="$(print -r -- "$LIVE_METADATA" | /usr/bin/awk -F= '$1 == "Identifier" { print substr($0,index($0,"=")+1); exit }')"
LIVE_TEAM_ID="$(print -r -- "$LIVE_METADATA" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print substr($0,index($0,"=")+1); exit }')"
LIVE_CDHASH="$(print -r -- "$LIVE_METADATA" | /usr/bin/awk -F= '$1 == "CDHash" { print tolower($2); exit }')"
[[ "$LIVE_IDENTIFIER" == "$EXPECTED_IDENTIFIER" ]] || fail \
    "live identifier: expected '$EXPECTED_IDENTIFIER', found '$LIVE_IDENTIFIER'"
[[ "$LIVE_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail \
    "live TeamIdentifier: expected '$EXPECTED_TEAM_ID', found '$LIVE_TEAM_ID'"
[[ "$LIVE_CDHASH" == "$EXPECTED_CDHASH" ]] || fail \
    "live CDHash: expected '$EXPECTED_CDHASH', found '$LIVE_CDHASH'"
if [[ "$EXPECTED_TEAM_ID" != "not set" ]]; then
    REQUIREMENT="identifier \"$EXPECTED_IDENTIFIER\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
    /usr/bin/codesign --verify --strict --verbose=1 "-R=$REQUIREMENT" "$PID" || fail \
        "PID $PID does not satisfy the expected identifier/team requirement"
fi

/bin/kill -0 "$PID" 2>/dev/null || fail "PID $PID exited during verification"
START_AFTER="$(/bin/ps -p "$PID" -o lstart= 2>/dev/null)" || fail \
    "could not reread process start identity"
[[ "$START_AFTER" == "$START_BEFORE" ]] || fail "PID $PID was reused during verification"

print -r -- "pid=$PID"
print -r -- "process_start=$START_AFTER"
print -r -- "executable=$EXPECTED_EXECUTABLE"
print -r -- "identifier=$LIVE_IDENTIFIER"
print -r -- "team=$LIVE_TEAM_ID"
print -r -- "live_cdhash=$LIVE_CDHASH"
print -r -- "framework_executable=$EXPECTED_FRAMEWORK_EXECUTABLE"
print -r -- "live_framework_identity=$EXPECTED_FRAMEWORK_IDENTITY"
