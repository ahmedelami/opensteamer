#!/bin/zsh
set -eu

fail() {
    print -u2 -- "verify-live-mac-host-process: $*"
    exit 1
}

if (( $# != 6 )); then
    print -u2 -- \
        "usage: $0 <pid> <expected-executable> <expected-cdhash> <expected-identifier> <expected-team-id> <expected-framework-executable>"
    exit 64
fi

PID="$1"
EXPECTED_EXECUTABLE_INPUT="$2"
EXPECTED_CDHASH="${3:l}"
EXPECTED_IDENTIFIER="$4"
EXPECTED_TEAM_ID="$5"
EXPECTED_FRAMEWORK_EXECUTABLE_INPUT="$6"

[[ "$PID" == <1-> ]] || fail "PID must be a positive integer"
[[ -e "$EXPECTED_EXECUTABLE_INPUT" ]] || fail \
    "expected executable does not exist: $EXPECTED_EXECUTABLE_INPUT"
EXPECTED_EXECUTABLE="${EXPECTED_EXECUTABLE_INPUT:A}"
[[ -x "$EXPECTED_EXECUTABLE" ]] || fail \
    "expected executable is not executable: $EXPECTED_EXECUTABLE"
[[ "$EXPECTED_CDHASH" =~ ^[[:xdigit:]]{40}$ ]] || fail \
    "expected CDHash must contain exactly 40 hexadecimal characters"
[[ -n "$EXPECTED_IDENTIFIER" ]] || fail "expected identifier must not be empty"
if [[ "$EXPECTED_TEAM_ID" != "not set" ]]; then
    [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail \
        "expected TeamIdentifier must be 10 uppercase alphanumeric characters"
fi
[[ -e "$EXPECTED_FRAMEWORK_EXECUTABLE_INPUT" ]] || fail \
    "expected framework executable does not exist: $EXPECTED_FRAMEWORK_EXECUTABLE_INPUT"
EXPECTED_FRAMEWORK_EXECUTABLE="${EXPECTED_FRAMEWORK_EXECUTABLE_INPUT:A}"
[[ -x "$EXPECTED_FRAMEWORK_EXECUTABLE" ]] || fail \
    "expected framework executable is not executable: $EXPECTED_FRAMEWORK_EXECUTABLE"

kill -0 "$PID" 2>/dev/null || fail "PID $PID is not alive"

# A process can keep an old vnode mapped after its on-disk path is atomically
# replaced. The path check is useful provenance; the dynamic SecCode identity,
# main CDHash, and framework vnode checks bind the running code to this build.
LIVE_TEXT_FILES="$(/usr/sbin/lsof -a -p "$PID" -d txt -Fn 2>/dev/null \
    | /usr/bin/sed -n 's/^n//p')"
if [[ "$(print -r -- "$LIVE_TEXT_FILES" \
    | /usr/bin/grep -Fxc "$EXPECTED_EXECUTABLE")" != 1 ]]; then
    fail "PID $PID is not executing the expected path: $EXPECTED_EXECUTABLE"
fi
if print -r -- "$LIVE_TEXT_FILES" \
    | /usr/bin/grep -Eq '/MacCaptureHost\.app/|/\.build/.*/CaptureServer$'; then
    fail "PID $PID has a legacy or naked CaptureServer executable mapped"
fi

# SecCode's dynamic identity binds the main executable, but it does not prove
# that a long-running process remapped an embedded framework after the app was
# replaced on disk. Match the live framework vnode to the verified installed
# vnode so an unchanged CaptureServer cannot hide a stale LiveKitWebRTC image.
EXPECTED_FRAMEWORK_DEVICE_DECIMAL="$(/usr/bin/stat \
    -f '%d' "$EXPECTED_FRAMEWORK_EXECUTABLE")"
EXPECTED_FRAMEWORK_DEVICE="$(/usr/bin/printf \
    '0x%x' "$EXPECTED_FRAMEWORK_DEVICE_DECIMAL")"
EXPECTED_FRAMEWORK_INODE="$(/usr/bin/stat \
    -f '%i' "$EXPECTED_FRAMEWORK_EXECUTABLE")"
EXPECTED_FRAMEWORK_IDENTITY="${EXPECTED_FRAMEWORK_DEVICE:l}:$EXPECTED_FRAMEWORK_INODE"
LIVE_FRAMEWORK_IDENTITIES="$(/usr/sbin/lsof -a -p "$PID" -FDin 2>/dev/null \
    | /usr/bin/awk -v expected="$EXPECTED_FRAMEWORK_EXECUTABLE" '
        /^f/ { device = ""; inode = "" }
        /^D/ { device = tolower(substr($0, 2)) }
        /^i/ { inode = substr($0, 2) }
        /^n/ {
            path = substr($0, 2)
            if (path == expected || path == expected " (deleted)") {
                print device ":" inode
            }
        }
    ')"
if [[ "$(print -r -- "$LIVE_FRAMEWORK_IDENTITIES" \
    | /usr/bin/grep -Fxc "$EXPECTED_FRAMEWORK_IDENTITY")" != 1 \
    || "$(print -r -- "$LIVE_FRAMEWORK_IDENTITIES" \
    | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" != 1 ]]; then
    LIVE_FRAMEWORK_DIAGNOSTIC="${LIVE_FRAMEWORK_IDENTITIES:-not mapped}"
    fail "live framework mapping: expected '$EXPECTED_FRAMEWORK_IDENTITY' at '$EXPECTED_FRAMEWORK_EXECUTABLE', found '$LIVE_FRAMEWORK_DIAGNOSTIC'"
fi

if ! /usr/bin/codesign --verify --strict --verbose=1 "$PID"; then
    fail "PID $PID failed dynamic code-signature validation"
fi

if ! LIVE_METADATA="$(/usr/bin/codesign --display --verbose=4 "+$PID" 2>&1)"; then
    fail "could not read dynamic code-signature metadata for PID $PID"
fi
LIVE_IDENTIFIER="$(print -r -- "$LIVE_METADATA" \
    | /usr/bin/awk -F= '$1 == "Identifier" { print substr($0, index($0, "=") + 1); exit }')"
LIVE_TEAM_ID="$(print -r -- "$LIVE_METADATA" \
    | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }')"
LIVE_CDHASH="$(print -r -- "$LIVE_METADATA" \
    | /usr/bin/awk -F= '$1 == "CDHash" { print tolower($2); exit }')"

[[ "$LIVE_IDENTIFIER" == "$EXPECTED_IDENTIFIER" ]] || fail \
    "live identifier: expected '$EXPECTED_IDENTIFIER', found '$LIVE_IDENTIFIER'"
[[ "$LIVE_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail \
    "live TeamIdentifier: expected '$EXPECTED_TEAM_ID', found '$LIVE_TEAM_ID'"
[[ "$LIVE_CDHASH" == "$EXPECTED_CDHASH" ]] || fail \
    "live CDHash: expected '$EXPECTED_CDHASH', found '$LIVE_CDHASH'"

if [[ "$EXPECTED_TEAM_ID" != "not set" ]]; then
    REQUIREMENT="identifier \"$EXPECTED_IDENTIFIER\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
    if ! /usr/bin/codesign \
        --verify \
        --strict \
        --verbose=1 \
        "-R=$REQUIREMENT" \
        "$PID"; then
        fail "PID $PID does not satisfy the expected identifier/team requirement"
    fi
fi

print -r -- "pid=$PID"
print -r -- "executable=$EXPECTED_EXECUTABLE"
print -r -- "identifier=$LIVE_IDENTIFIER"
print -r -- "team=$LIVE_TEAM_ID"
print -r -- "live_cdhash=$LIVE_CDHASH"
print -r -- "framework_executable=$EXPECTED_FRAMEWORK_EXECUTABLE"
print -r -- "live_framework_identity=$EXPECTED_FRAMEWORK_IDENTITY"
