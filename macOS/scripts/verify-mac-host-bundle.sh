#!/bin/zsh
# Performs read-only structural and signing verification of an opensteamer Host app bundle.
#
# Usage: `verify-mac-host-bundle.sh <opensteamer Host.app> [expected-team-id]`.
# It requires standard macOS plist, Mach-O, and code-signing tools. The optional TeamIdentifier
# enables the stronger Apple anchor/organizational-unit requirement; omitting it also permits a
# correctly formed ad-hoc bundle for local tests.
#
# The verifier follows parent directories but rejects a symlink at the app boundary, validates
# metadata, executable/framework layout, linkage, signatures, and designated requirements, and
# never changes the bundle. Success emits a single diagnostic on stderr and exits 0; bad invocation
# exits 64, while every malformed or mismatched artifact exits 1.
set -eu

readonly EXPECTED_APP_BASENAME="opensteamer Host.app"
# The visible bundle name changed, but the shipped code identity is an upgrade compatibility ABI.
readonly EXPECTED_BUNDLE_IDENTIFIER="org.example.AudioStreamer.CaptureServer"
readonly EXPECTED_EXECUTABLE_NAME="CaptureServer"
readonly EXPECTED_FRAMEWORK_IDENTIFIER="io.livekit.LiveKitWebRTC"
readonly EXPECTED_FRAMEWORK_RPATH="@executable_path/../Frameworks"
readonly EXPECTED_FRAMEWORK_INSTALL_NAME="@rpath/LiveKitWebRTC.framework/LiveKitWebRTC"

fail() {
    print -u2 -- "verify-mac-host-bundle: $*"
    exit 1
}

if (( $# < 1 || $# > 2 )); then
    print -u2 -- "usage: $0 <opensteamer Host.app> [expected-team-id]"
    exit 64
fi

APP_INPUT="${1%/}"
EXPECTED_TEAM_ID="${2:-}"

[[ -n "$APP_INPUT" ]] || fail "the app path must not be empty"
[[ -e "$APP_INPUT" ]] || fail "app bundle does not exist: $APP_INPUT"

# Collapse dot components without resolving symlinks before checking the bundle
# itself. Checking the raw spelling alone can be bypassed with `Some.app/.` or
# `Some.app/Contents/..`, both of which otherwise hide a final-component symlink.
LEXICAL_APP_PATH="${APP_INPUT:a}"
[[ ! -L "$LEXICAL_APP_PATH" ]] || fail \
    "bundle path must not be a symbolic link: $LEXICAL_APP_PATH"
[[ -d "$LEXICAL_APP_PATH" ]] || fail "app bundle is not a directory: $LEXICAL_APP_PATH"

# Resolve all parent components before checking the name. This verifies the
# privacy-visible artifact macOS will actually execute, not just a caller's
# relative spelling of its path.
APP_PATH="${LEXICAL_APP_PATH:A}"
ACTUAL_APP_BASENAME="${APP_PATH:t}"
[[ "$ACTUAL_APP_BASENAME" == "$EXPECTED_APP_BASENAME" ]] || fail \
    "bundle basename: expected '$EXPECTED_APP_BASENAME', found '$ACTUAL_APP_BASENAME'"

CONTENTS_DIR="$APP_PATH/Contents"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE="$CONTENTS_DIR/MacOS/$EXPECTED_EXECUTABLE_NAME"
FRAMEWORK="$CONTENTS_DIR/Frameworks/LiveKitWebRTC.framework"
FRAMEWORK_EXECUTABLE="$FRAMEWORK/LiveKitWebRTC"

[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing: $INFO_PLIST"

# Read required privacy-visible bundle identity directly from the packaged Info.plist.
assert_plist_value() {
    local key="$1"
    local expected="$2"
    local actual
    if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null)"; then
        fail "Info.plist is missing required key '$key'"
    fi
    [[ "$actual" == "$expected" ]] || fail \
        "$key: expected '$expected', found '$actual'"
}

# Check privacy identity fields before the signature. A mutation then identifies
# the wrong deployment identity directly instead of surfacing only as a generic
# resource-seal failure.
assert_plist_value CFBundleIdentifier "$EXPECTED_BUNDLE_IDENTIFIER"
assert_plist_value CFBundleExecutable "$EXPECTED_EXECUTABLE_NAME"
assert_plist_value CFBundleName "opensteamer Host"
assert_plist_value CFBundleDisplayName "opensteamer Host"
assert_plist_value CFBundlePackageType "APPL"

[[ -f "$EXECUTABLE" ]] || fail "main executable is missing: $EXECUTABLE"
[[ -x "$EXECUTABLE" ]] || fail "main executable is not executable: $EXECUTABLE"
EXECUTABLE_FILE_TYPE="$(/usr/bin/file -b "$EXECUTABLE")"
[[ "$EXECUTABLE_FILE_TYPE" == *"Mach-O"* && "$EXECUTABLE_FILE_TYPE" == *"executable"* ]] || fail \
    "main executable is not a Mach-O executable: $EXECUTABLE_FILE_TYPE"

[[ -d "$FRAMEWORK" ]] || fail "LiveKitWebRTC.framework is missing: $FRAMEWORK"
[[ ! -L "$FRAMEWORK" ]] || fail "LiveKitWebRTC.framework must not be a symbolic link"
[[ -f "$FRAMEWORK_EXECUTABLE" ]] || fail \
    "LiveKitWebRTC framework executable is missing: $FRAMEWORK_EXECUTABLE"
FRAMEWORK_FILE_TYPE="$(/usr/bin/file -b "$FRAMEWORK_EXECUTABLE")"
[[ "$FRAMEWORK_FILE_TYPE" == *"Mach-O"* ]] || fail \
    "LiveKitWebRTC framework executable is not Mach-O: $FRAMEWORK_FILE_TYPE"

RPATHS="$(/usr/bin/otool -l "$EXECUTABLE" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
')"
# The executable must resolve the embedded WebRTC framework relative to its installed app, never
# through a development build directory or ambient loader search path.
if ! print -r -- "$RPATHS" | /usr/bin/grep -Fxq "$EXPECTED_FRAMEWORK_RPATH"; then
    fail "main executable is missing LC_RPATH '$EXPECTED_FRAMEWORK_RPATH'"
fi

LINKED_LIBRARIES="$(/usr/bin/otool -L "$EXECUTABLE" | /usr/bin/awk 'NR > 1 { print $1 }')"
if ! print -r -- "$LINKED_LIBRARIES" | /usr/bin/grep -Fxq "$EXPECTED_FRAMEWORK_INSTALL_NAME"; then
    fail "main executable does not link '$EXPECTED_FRAMEWORK_INSTALL_NAME'"
fi

verify_signature() {
    local target="$1"
    local label="$2"
    if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"; then
        fail "strict code-signature verification failed for $label"
    fi
}

verify_signature "$FRAMEWORK" "LiveKitWebRTC.framework"
verify_signature "$EXECUTABLE" "the main executable"
verify_signature "$APP_PATH" "the app bundle"

# `codesign --display` reports metadata on stderr by design. The helper normalizes the three fields
# that participate in cross-component identity checks below.
read_code_metadata() {
    local target="$1"
    local label="$2"
    if ! CODE_METADATA="$(/usr/bin/codesign --display --verbose=4 "$target" 2>&1)"; then
        fail "could not read code-signature metadata for $label"
    fi
    CODE_IDENTIFIER="$(print -r -- "$CODE_METADATA" | /usr/bin/awk -F= '$1 == "Identifier" { print substr($0, index($0, "=") + 1); exit }')"
    CODE_TEAM_ID="$(print -r -- "$CODE_METADATA" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }')"
    [[ -n "$CODE_IDENTIFIER" ]] || fail "code-signature identifier is missing for $label"
    [[ -n "$CODE_TEAM_ID" ]] || fail "TeamIdentifier metadata is missing for $label"

    if ! CODE_REQUIREMENTS_OUTPUT="$(/usr/bin/codesign --display --requirements - "$target" 2>&1)"; then
        fail "could not read the designated requirement for $label"
    fi
    CODE_DESIGNATED_REQUIREMENT="$(print -r -- "$CODE_REQUIREMENTS_OUTPUT" | /usr/bin/awk '
        /^# designated =>/ { sub(/^# /, ""); print; exit }
        /^designated =>/ { print; exit }
    ')"
    [[ -n "$CODE_DESIGNATED_REQUIREMENT" ]] || fail \
        "designated requirement is missing for $label"
}

read_code_metadata "$APP_PATH" "the app bundle"
APP_CODE_IDENTIFIER="$CODE_IDENTIFIER"
APP_TEAM_ID="$CODE_TEAM_ID"
APP_DESIGNATED_REQUIREMENT="$CODE_DESIGNATED_REQUIREMENT"

read_code_metadata "$EXECUTABLE" "the main executable"
EXECUTABLE_CODE_IDENTIFIER="$CODE_IDENTIFIER"
EXECUTABLE_TEAM_ID="$CODE_TEAM_ID"
EXECUTABLE_DESIGNATED_REQUIREMENT="$CODE_DESIGNATED_REQUIREMENT"

read_code_metadata "$FRAMEWORK" "LiveKitWebRTC.framework"
FRAMEWORK_CODE_IDENTIFIER="$CODE_IDENTIFIER"
FRAMEWORK_TEAM_ID="$CODE_TEAM_ID"

[[ "$APP_CODE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || fail \
    "app signature identifier: expected '$EXPECTED_BUNDLE_IDENTIFIER', found '$APP_CODE_IDENTIFIER'"
[[ "$EXECUTABLE_CODE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || fail \
    "executable signature identifier: expected '$EXPECTED_BUNDLE_IDENTIFIER', found '$EXECUTABLE_CODE_IDENTIFIER'"
[[ "$FRAMEWORK_CODE_IDENTIFIER" == "$EXPECTED_FRAMEWORK_IDENTIFIER" ]] || fail \
    "framework signature identifier: expected '$EXPECTED_FRAMEWORK_IDENTIFIER', found '$FRAMEWORK_CODE_IDENTIFIER'"
[[ "$APP_TEAM_ID" == "$EXECUTABLE_TEAM_ID" ]] || fail \
    "app TeamIdentifier '$APP_TEAM_ID' differs from executable TeamIdentifier '$EXECUTABLE_TEAM_ID'"
[[ "$APP_TEAM_ID" == "$FRAMEWORK_TEAM_ID" ]] || fail \
    "app TeamIdentifier '$APP_TEAM_ID' differs from framework TeamIdentifier '$FRAMEWORK_TEAM_ID'"

# Ad-hoc designated requirements are CDHash-based and intentionally change on
# every build. A stable signing identity instead produces an identifier-based
# requirement; app and executable must then share that privacy identity.
if [[ "$APP_TEAM_ID" == "not set" ]]; then
    [[ "$APP_DESIGNATED_REQUIREMENT" == "designated => cdhash "* ]] || fail \
        "ad-hoc app designated requirement is not CDHash-based"
    [[ "$EXECUTABLE_DESIGNATED_REQUIREMENT" == "designated => cdhash "* ]] || fail \
        "ad-hoc executable designated requirement is not CDHash-based"
else
    REQUIRED_IDENTIFIER_CLAUSE="identifier \"$EXPECTED_BUNDLE_IDENTIFIER\""
    [[ "$APP_DESIGNATED_REQUIREMENT" == *"$REQUIRED_IDENTIFIER_CLAUSE"* ]] || fail \
        "app designated requirement does not contain '$REQUIRED_IDENTIFIER_CLAUSE'"
    [[ "$EXECUTABLE_DESIGNATED_REQUIREMENT" == *"$REQUIRED_IDENTIFIER_CLAUSE"* ]] || fail \
        "executable designated requirement does not contain '$REQUIRED_IDENTIFIER_CLAUSE'"
    [[ "$APP_DESIGNATED_REQUIREMENT" == "$EXECUTABLE_DESIGNATED_REQUIREMENT" ]] || fail \
        "stably signed app and executable designated requirements differ"
fi

if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail \
        "expected TeamIdentifier must be 10 uppercase alphanumeric characters"
    [[ "$APP_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail \
        "TeamIdentifier: expected '$EXPECTED_TEAM_ID', found '$APP_TEAM_ID'"

    verify_identifier_and_team_requirement() {
        local target="$1"
        local label="$2"
        local identifier="$3"
        local requirement
        requirement="identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
        if ! /usr/bin/codesign --verify --strict "-R=$requirement" "$target"; then
            fail "$label does not satisfy the expected identifier/team designated requirement"
        fi
    }

    verify_identifier_and_team_requirement \
        "$APP_PATH" "the app bundle" "$EXPECTED_BUNDLE_IDENTIFIER"
    verify_identifier_and_team_requirement \
        "$EXECUTABLE" "the main executable" "$EXPECTED_BUNDLE_IDENTIFIER"
    verify_identifier_and_team_requirement \
        "$FRAMEWORK" "LiveKitWebRTC.framework" "$EXPECTED_FRAMEWORK_IDENTIFIER"
fi

print -u2 -- "Verified opensteamer Host bundle: $APP_PATH"
