#!/bin/zsh
# Read-only structural, linkage, deployment-target, and signing verifier.
set -euo pipefail

readonly EXPECTED_APP_BASENAME="opensteamer Host.app"
readonly EXPECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"
readonly EXPECTED_EXECUTABLE_NAME="CaptureServer"
readonly EXPECTED_FRAMEWORK_IDENTIFIER="io.livekit.LiveKitWebRTC"
readonly EXPECTED_FRAMEWORK_RPATH="@executable_path/../Frameworks"
readonly EXPECTED_FRAMEWORK_INSTALL_NAME="@rpath/LiveKitWebRTC.framework/LiveKitWebRTC"
readonly MINIMUM_MACOS_VERSION="14.0"

fail() {
    print -u2 -- "verify-mac-host-bundle: $*"
    exit 1
}

if (( $# < 1 || $# > 3 )); then
    print -u2 -- \
        "usage: $0 <opensteamer Host.app> [expected-team-id] [designated-requirement-reference-code]"
    exit 64
fi

APP_INPUT="${1%/}"
EXPECTED_TEAM_ID="${2:-}"
EXPECTED_DESIGNATED_REQUIREMENT_REFERENCE="${3:-}"
EXPECTED_ARCHITECTURES="${OPENSTEAMER_EXPECTED_ARCHITECTURES:-}"

[[ -n "$APP_INPUT" && -e "$APP_INPUT" ]] || fail "app bundle does not exist: $APP_INPUT"
LEXICAL_APP_PATH="${APP_INPUT:a}"
[[ ! -L "$LEXICAL_APP_PATH" && -d "$LEXICAL_APP_PATH" ]] || fail \
    "app bundle must be a real directory: $LEXICAL_APP_PATH"
APP_PATH="${LEXICAL_APP_PATH:A}"
[[ "${APP_PATH:t}" == "$EXPECTED_APP_BASENAME" ]] || fail \
    "bundle basename: expected '$EXPECTED_APP_BASENAME', found '${APP_PATH:t}'"

CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE="$MACOS_DIR/$EXPECTED_EXECUTABLE_NAME"
FRAMEWORK="$FRAMEWORKS_DIR/LiveKitWebRTC.framework"
FRAMEWORK_EXECUTABLE_LINK="$FRAMEWORK/LiveKitWebRTC"
NOTICES="$RESOURCES_DIR/ThirdPartyNotices.md"

assert_real_directory() {
    local target="$1" label="$2"
    [[ -d "$target" && ! -L "$target" ]] || fail "$label is not a real directory: $target"
    [[ "${target:a}" == "${target:A}" ]] || fail "$label traverses a symbolic link: $target"
}

assert_real_file() {
    local target="$1" label="$2" expected_mode="$3"
    [[ -f "$target" && ! -L "$target" ]] || fail "$label is not a real regular file: $target"
    [[ "$(/usr/bin/stat -f '%l' "$target")" == 1 ]] || fail "$label must have one hard link"
    [[ "$(/usr/bin/stat -f '%Lp' "$target")" == "$expected_mode" ]] || fail \
        "$label mode is '$(/usr/bin/stat -f '%Lp' "$target")', expected '$expected_mode'"
}

assert_real_directory "$CONTENTS_DIR" "Contents directory"
assert_real_directory "$MACOS_DIR" "MacOS directory"
assert_real_directory "$FRAMEWORKS_DIR" "Frameworks directory"
assert_real_directory "$RESOURCES_DIR" "Resources directory"
assert_real_directory "$FRAMEWORK" "LiveKitWebRTC.framework"
assert_real_file "$INFO_PLIST" "Info.plist" 644
assert_real_file "$EXECUTABLE" "main executable" 755
assert_real_file "$NOTICES" "third-party notices" 644
[[ -x "$EXECUTABLE" ]] || fail "main executable is not executable"

# The versioned framework has one exact reviewed alias set and one exact structural spine.
# Every alias is required, must remain a symbolic link with the reviewed relative target, and no
# other symbolic link is permitted anywhere in the app.
FRAMEWORK_ROOT="${FRAMEWORK:A}"
EXPECTED_ALIAS_NAMES=$'Headers\nLiveKitWebRTC\nModules\nResources\nVersions/Current'
ACTUAL_ALIAS_NAMES="$(
    for relative in Headers LiveKitWebRTC Modules Resources Versions/Current; do
        [[ -L "$FRAMEWORK/$relative" ]] && print -r -- "$relative"
    done | LC_ALL=C /usr/bin/sort
)" || fail "could not enumerate reviewed framework aliases"
[[ "$ACTUAL_ALIAS_NAMES" == "$EXPECTED_ALIAS_NAMES" ]] || fail \
    "framework alias set differs from the exact reviewed set: ${ACTUAL_ALIAS_NAMES:-none}"

require_framework_alias() {
    local relative="$1" expected_target="$2"
    local link="$FRAMEWORK/$relative"
    [[ -L "$link" ]] || fail "required framework alias is missing or not a symlink: $relative"
    local target
    target="$(/usr/bin/readlink "$link")" || fail "could not read framework alias: $relative"
    [[ "$target" == "$expected_target" ]] || fail \
        "framework alias '$relative' targets '$target', expected '$expected_target'"
    [[ -n "$target" && "$target" != /* ]] || fail \
        "framework alias target must be nonempty and relative: $relative"
    local resolved="${link:h}/$target"
    resolved="${resolved:A}"
    [[ "$resolved" == "$FRAMEWORK_ROOT/"* ]] || fail \
        "framework symlink escapes its bundle: $relative -> $target"
}
require_framework_alias LiveKitWebRTC Versions/Current/LiveKitWebRTC
require_framework_alias Headers Versions/Current/Headers
require_framework_alias Modules Versions/Current/Modules
require_framework_alias Resources Versions/Current/Resources
require_framework_alias Versions/Current A


# Reject multiply linked regular files and group/world-writable content. Directory link counts are
# filesystem topology and are intentionally not constrained.
TREE_ERROR="$(/usr/bin/find "$APP_PATH" -print0 | /usr/bin/xargs -0 /usr/bin/stat -f '%HT|%l|%Lp|%N' \
    | /usr/bin/awk -F'|' '
        function writable(digit) { return digit == 2 || digit == 3 || digit == 6 || digit == 7 }
        BEGIN { finding = "" }
        $1 == "Regular File" && $2 != "1" {
            if (finding == "") finding = "hardlink:" $4
            next
        }
        $1 != "Symbolic Link" {
            mode = $3
            world = substr(mode, length(mode), 1) + 0
            group = substr(mode, length(mode) - 1, 1) + 0
            if (finding == "" && writable(world)) finding = "world-writable:" $4
            if (finding == "" && writable(group)) finding = "group-writable:" $4
        }
        END { if (finding != "") print finding }
    ')" || fail "could not validate app tree metadata"
[[ -z "$TREE_ERROR" ]] || fail "unsafe app-tree metadata: $TREE_ERROR"


TOP_FRAMEWORK_ENTRIES="$(/bin/ls -1A "$FRAMEWORK" | LC_ALL=C /usr/bin/sort)" \
    || fail "could not enumerate framework root"
[[ "$TOP_FRAMEWORK_ENTRIES" == $'Headers\nLiveKitWebRTC\nModules\nResources\nVersions' ]] || fail \
    "framework root layout differs from the reviewed layout: $TOP_FRAMEWORK_ENTRIES"
VERSIONS_ENTRIES="$(/bin/ls -1A "$FRAMEWORK/Versions" | LC_ALL=C /usr/bin/sort)" \
    || fail "could not enumerate framework Versions directory"
[[ "$VERSIONS_ENTRIES" == $'A\nCurrent' ]] || fail \
    "framework Versions layout differs from the reviewed layout: $VERSIONS_ENTRIES"
VERSION_A="$FRAMEWORK/Versions/A"
assert_real_directory "$VERSION_A" "framework version A"
VERSION_A_ENTRIES="$(/bin/ls -1A "$VERSION_A" | LC_ALL=C /usr/bin/sort)" \
    || fail "could not enumerate framework version A"
[[ "$VERSION_A_ENTRIES" == $'Headers\nLiveKitWebRTC\nModules\nResources\nVersions\n_CodeSignature' ]] || fail \
    "framework version A layout differs from the reviewed layout: $VERSION_A_ENTRIES"
for inner_directory in Headers Modules Resources Versions _CodeSignature; do
    assert_real_directory "$VERSION_A/$inner_directory" "framework version A $inner_directory"
done
assert_real_file "$VERSION_A/LiveKitWebRTC" "framework version A executable" 755
[[ -x "$VERSION_A/LiveKitWebRTC" ]] || fail "framework version A executable is not executable"
assert_real_file "$VERSION_A/Resources/Info.plist" "framework Info.plist" 644

# LiveKitWebRTC 144.7559.11 intentionally ships one nested privacy-manifest spine. It is not a
# general nested framework: every component and entry is exact, real, in-bundle, and non-aliased.
PINNED_NESTED_VERSIONS="$VERSION_A/Versions"
PINNED_NESTED_A="$PINNED_NESTED_VERSIONS/A"
PINNED_NESTED_RESOURCES="$PINNED_NESTED_A/Resources"
[[ "$(/bin/ls -1A "$PINNED_NESTED_VERSIONS" | LC_ALL=C /usr/bin/sort)" == A \
    && -d "$PINNED_NESTED_A" && ! -L "$PINNED_NESTED_A" \
    && "${PINNED_NESTED_A:a}" == "${PINNED_NESTED_A:A}" ]] || fail \
    "framework pinned nested Versions layout differs from the reviewed layout"
assert_real_directory "$PINNED_NESTED_A" "framework pinned nested version A"
[[ "$(/bin/ls -1A "$PINNED_NESTED_A" | LC_ALL=C /usr/bin/sort)" == Resources ]] || fail \
    "framework pinned nested version A layout differs from the reviewed layout"
assert_real_directory "$PINNED_NESTED_RESOURCES" "framework pinned nested Resources"
[[ "$(/bin/ls -1A "$PINNED_NESTED_RESOURCES" | LC_ALL=C /usr/bin/sort)" == PrivacyInfo.xcprivacy ]] || fail \
    "framework pinned nested Resources layout differs from the reviewed layout"
assert_real_file "$PINNED_NESTED_RESOURCES/PrivacyInfo.xcprivacy" \
    "framework pinned privacy manifest" 644
/usr/bin/plutil -lint "$PINNED_NESTED_RESOURCES/PrivacyInfo.xcprivacy" >/dev/null || fail \
    "framework pinned privacy manifest is not a valid property list"

ALL_FRAMEWORK_SYMLINKS="$(/usr/bin/find "$FRAMEWORK" -type l -print \
    | /usr/bin/sed "s#^$FRAMEWORK/##" | LC_ALL=C /usr/bin/sort)" \
    || fail "could not enumerate all framework symbolic links"
[[ "$ALL_FRAMEWORK_SYMLINKS" == "$EXPECTED_ALIAS_NAMES" ]] || fail \
    "framework alias set differs from the exact reviewed set: ${ALL_FRAMEWORK_SYMLINKS:-none}"

FRAMEWORK_EXECUTABLE="${FRAMEWORK_EXECUTABLE_LINK:A}"
[[ "$FRAMEWORK_EXECUTABLE" == "$VERSION_A/LiveKitWebRTC" ]] || fail \
    "framework executable alias does not resolve to the reviewed version-A executable"
assert_real_file "$FRAMEWORK_EXECUTABLE" "resolved framework executable" 755
[[ -x "$FRAMEWORK_EXECUTABLE" ]] || fail "framework executable is not executable"


# Top-level bundle layout is exact.
TOP_LEVEL="$(/bin/ls -1A "$APP_PATH")" || fail "could not enumerate app root"
[[ "$TOP_LEVEL" == Contents ]] || fail "app root contains unexpected entries: $TOP_LEVEL"
CONTENTS_ENTRIES="$(/bin/ls -1A "$CONTENTS_DIR" | LC_ALL=C /usr/bin/sort)" || fail \
    "could not enumerate Contents"
[[ "$CONTENTS_ENTRIES" == $'Frameworks\nInfo.plist\nMacOS\nResources\n_CodeSignature' ]] || fail \
    "Contents entries differ from the reviewed bundle layout: $CONTENTS_ENTRIES"
MACOS_ENTRIES="$(/bin/ls -1A "$MACOS_DIR")"
[[ "$MACOS_ENTRIES" == "$EXPECTED_EXECUTABLE_NAME" ]] || fail "MacOS directory has unexpected entries"
RESOURCES_ENTRIES="$(/bin/ls -1A "$RESOURCES_DIR")"
[[ "$RESOURCES_ENTRIES" == ThirdPartyNotices.md ]] || fail "Resources directory has unexpected entries"
FRAMEWORKS_ENTRIES="$(/bin/ls -1A "$FRAMEWORKS_DIR")"
[[ "$FRAMEWORKS_ENTRIES" == LiveKitWebRTC.framework ]] || fail "Frameworks directory has unexpected entries"

# Signing should not rely on quarantine/Finder metadata or any unreviewed xattr.
XATTRS="$(/usr/bin/xattr -lr "$APP_PATH" 2>/dev/null)" || fail \
    "could not inspect app bundle extended attributes"
[[ -z "$XATTRS" ]] || fail "app bundle contains extended attributes: $XATTRS"

assert_plist_value() {
    local key="$1" expected="$2" actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null)" \
        || fail "Info.plist is missing required key '$key'"
    [[ "$actual" == "$expected" ]] || fail "$key: expected '$expected', found '$actual'"
}
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
assert_plist_value CFBundleIdentifier "$EXPECTED_BUNDLE_IDENTIFIER"
assert_plist_value CFBundleExecutable "$EXPECTED_EXECUTABLE_NAME"
assert_plist_value CFBundleName "opensteamer Host"
assert_plist_value CFBundleDisplayName "opensteamer Host"
assert_plist_value CFBundlePackageType APPL

EXECUTABLE_FILE_TYPE="$(/usr/bin/file -b "$EXECUTABLE")"
FRAMEWORK_FILE_TYPE="$(/usr/bin/file -b "$FRAMEWORK_EXECUTABLE")"
[[ "$EXECUTABLE_FILE_TYPE" == *Mach-O* && "$EXECUTABLE_FILE_TYPE" == *executable* ]] || fail \
    "main executable is not a Mach-O executable: $EXECUTABLE_FILE_TYPE"
[[ "$FRAMEWORK_FILE_TYPE" == *Mach-O* ]] || fail \
    "framework executable is not Mach-O: $FRAMEWORK_FILE_TYPE"

normalize_arches() {
    print -r -- "$1" | /usr/bin/tr ' ' '\n' | /usr/bin/sed '/^$/d' | LC_ALL=C /usr/bin/sort | \
        /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//'
}
HOST_ARCHES="$(normalize_arches "$(/usr/bin/lipo -archs "$EXECUTABLE")")" || fail \
    "could not read host architectures"
FRAMEWORK_ARCHES="$(normalize_arches "$(/usr/bin/lipo -archs "$FRAMEWORK_EXECUTABLE")")" || fail \
    "could not read framework architectures"
[[ -n "$HOST_ARCHES" && -n "$FRAMEWORK_ARCHES" ]] || fail \
    "host or framework architecture metadata is empty"
for arch in ${(s: :)HOST_ARCHES}; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || fail "unexpected host architecture: $arch"
    print -r -- "$FRAMEWORK_ARCHES" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -Fxq "$arch" || fail \
        "framework architectures '$FRAMEWORK_ARCHES' do not contain required host slice '$arch'"
done
for arch in ${(s: :)FRAMEWORK_ARCHES}; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || fail \
        "unexpected framework architecture: $arch"
done
if [[ -n "$EXPECTED_ARCHITECTURES" ]]; then
    [[ "$HOST_ARCHES" == "$(normalize_arches "$EXPECTED_ARCHITECTURES")" ]] || fail \
        "host architectures '$HOST_ARCHES' differ from expected '$(normalize_arches "$EXPECTED_ARCHITECTURES")'"
fi

minimum_os_for() {
    /usr/bin/vtool -show-build "$1" 2>/dev/null | /usr/bin/awk '
        $1 == "minos" { print $2; exit }
        $1 == "version" { print $2; exit }
    '
}
version_at_most() {
    /usr/bin/awk -v actual="$1" -v maximum="$2" 'BEGIN {
        split(actual, a, "."); split(maximum, m, ".")
        for (i = 1; i <= 3; i++) {
            av = (a[i] == "" ? 0 : a[i] + 0); mv = (m[i] == "" ? 0 : m[i] + 0)
            if (av < mv) exit 0
            if (av > mv) exit 1
        }
        exit 0
    }'
}
HOST_MIN_OS="$(minimum_os_for "$EXECUTABLE")" || fail "could not read host deployment target"
FRAMEWORK_MIN_OS="$(minimum_os_for "$FRAMEWORK_EXECUTABLE")" || fail \
    "could not read framework deployment target"
[[ -n "$HOST_MIN_OS" && -n "$FRAMEWORK_MIN_OS" ]] || fail "deployment target metadata is missing"
[[ "$HOST_MIN_OS" == "$MINIMUM_MACOS_VERSION" ]] || fail \
    "host deployment target '$HOST_MIN_OS' is not exactly macOS $MINIMUM_MACOS_VERSION"
version_at_most "$FRAMEWORK_MIN_OS" "$MINIMUM_MACOS_VERSION" || fail \
    "framework deployment target '$FRAMEWORK_MIN_OS' is newer than macOS $MINIMUM_MACOS_VERSION"

rpaths_for() {
    /usr/bin/otool -l "$1" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" { print $2; in_rpath = 0 }
    '
}
HOST_RPATHS="$(rpaths_for "$EXECUTABLE")" || fail "could not read host rpaths"
[[ "$HOST_RPATHS" == "$EXPECTED_FRAMEWORK_RPATH" ]] || fail \
    "main executable LC_RPATH set must be exactly '$EXPECTED_FRAMEWORK_RPATH', found '${HOST_RPATHS:-none}'"
FRAMEWORK_RPATHS="$(rpaths_for "$FRAMEWORK_EXECUTABLE")" || fail "could not read framework rpaths"
if print -r -- "$FRAMEWORK_RPATHS" | /usr/bin/grep -Eq \
    '(^|/)(\.build|build)(/|$)|/Users/|/private/|/tmp/|/var/tmp/|Xcode\.app|Toolchains|^@loader_path|^/usr/lib/swift'; then
    fail "framework contains an unsafe LC_RPATH: $FRAMEWORK_RPATHS"
fi

libraries_for() {
    /usr/bin/otool -L "$1" | /usr/bin/awk '
        BEGIN { headers = 0; slice = 0; entries = 0; entries_in_slice = 0; malformed = 0 }
        /^[^[:space:]].*:$/ {
            if (headers > 0 && entries_in_slice == 0) malformed = 1
            headers += 1
            slice += 1
            entries_in_slice = 0
            next
        }
        /^[[:space:]]+/ {
            if (headers == 0 || NF < 1) { malformed = 1; next }
            print slice "\t" $1
            entries += 1
            entries_in_slice += 1
            next
        }
        /^[[:space:]]*$/ { next }
        { malformed = 1 }
        END {
            if (headers == 0 || entries == 0 || entries_in_slice == 0 || malformed) exit 2
        }
    '
}

install_ids_for() {
    /usr/bin/otool -D "$1" | /usr/bin/awk '
        BEGIN { headers = 0; slice = 0; entries = 0; entries_in_slice = 0; malformed = 0 }
        /^[^[:space:]].*:$/ {
            if (headers > 0 && entries_in_slice != 1) malformed = 1
            headers += 1
            slice += 1
            entries_in_slice = 0
            next
        }
        /^[[:space:]]*$/ { next }
        {
            if (headers == 0 || NF != 1) { malformed = 1; next }
            print slice "\t" $1
            entries += 1
            entries_in_slice += 1
        }
        END {
            if (headers == 0 || entries == 0 || entries_in_slice != 1 || malformed) exit 2
        }
    '
}

HOST_LIBRARIES="$(libraries_for "$EXECUTABLE")" || fail "could not read host dependencies"
FRAMEWORK_LIBRARIES="$(libraries_for "$FRAMEWORK_EXECUTABLE")" || fail \
    "could not read framework dependencies"
FRAMEWORK_INSTALL_IDS="$(install_ids_for "$FRAMEWORK_EXECUTABLE")" || fail \
    "could not read framework install IDs"
HOST_SLICE_COUNT="$(print -r -- "$HOST_ARCHES" | /usr/bin/awk '{ print NF }')" || fail \
    "could not count host architecture slices"
FRAMEWORK_SLICE_COUNT="$(print -r -- "$FRAMEWORK_ARCHES" | /usr/bin/awk '{ print NF }')" || fail \
    "could not count framework architecture slices"

validate_dependency_set() {
    local label="$1" records="$2" expected_slices="$3"
    local slice dependency current_slice="" reviewed_count=0 slice_count=0
    while IFS=$'\t' read -r slice dependency; do
        [[ -n "$slice" && -n "$dependency" ]] || fail \
            "$label dependency parser emitted an incomplete slice record"
        if [[ "$slice" != "$current_slice" ]]; then
            if [[ -n "$current_slice" ]]; then
                (( reviewed_count == 1 )) || fail \
                    "$label slice $current_slice must contain exactly one reviewed LiveKit install-name entry, found $reviewed_count"
            fi
            slice_count=$((slice_count + 1))
            [[ "$slice" == "$slice_count" ]] || fail \
                "$label dependency slices are missing, duplicated, or out of order at slice $slice"
            current_slice="$slice"
            reviewed_count=0
        fi
        [[ "$dependency" != *'..'* && "$dependency" != *'//'*
            && "$dependency" != *$'\t'* && "$dependency" != *' '* ]] || fail \
            "$label contains a malformed dependency path in slice $slice: $dependency"
        case "$dependency" in
            "$EXPECTED_FRAMEWORK_INSTALL_NAME")
                reviewed_count=$((reviewed_count + 1))
                ;;
            /usr/lib/lib*.dylib|/usr/lib/system/*.dylib)
                ;;
            /usr/lib/swift/*.dylib)
                # System Swift runtime load commands are expected. The same prefix remains
                # forbidden as LC_RPATH above, so these cannot redirect through an ambient path.
                ;;
            /System/Library/Frameworks/*.framework/Versions/*/*)
                ;;
            @loader_path/*|@executable_path/*|@rpath/*)
                fail "$label contains an unreviewed relative dependency in slice $slice: $dependency"
                ;;
            /Users/*|/private/*|/tmp/*|/var/tmp/*|*Xcode.app*|*Toolchains*|*/.build/*|*/build/*)
                fail "$label contains a development or temporary dependency in slice $slice: $dependency"
                ;;
            /*)
                fail "$label contains a non-system absolute dependency in slice $slice: $dependency"
                ;;
            *)
                fail "$label contains an unreviewed dependency in slice $slice: $dependency"
                ;;
        esac
    done <<< "$records"
    [[ -n "$current_slice" ]] || fail "$label dependency set has no architecture slices"
    (( reviewed_count == 1 )) || fail \
        "$label slice $current_slice must contain exactly one reviewed LiveKit install-name entry, found $reviewed_count"
    (( slice_count == expected_slices )) || fail \
        "$label dependency parser covered $slice_count slices, expected $expected_slices"
}

validate_framework_install_ids() {
    local records="$1" expected_slices="$2"
    local slice install_id current_slice="" entries_in_slice=0 slice_count=0
    while IFS=$'\t' read -r slice install_id; do
        [[ -n "$slice" && -n "$install_id" ]] || fail \
            "framework install-ID parser emitted an incomplete slice record"
        if [[ "$slice" != "$current_slice" ]]; then
            if [[ -n "$current_slice" ]]; then
                (( entries_in_slice == 1 )) || fail \
                    "framework slice $current_slice has $entries_in_slice install IDs"
            fi
            slice_count=$((slice_count + 1))
            [[ "$slice" == "$slice_count" ]] || fail \
                "framework install-ID slices are missing, duplicated, or out of order at slice $slice"
            current_slice="$slice"
            entries_in_slice=0
        fi
        entries_in_slice=$((entries_in_slice + 1))
        [[ "$install_id" == "$EXPECTED_FRAMEWORK_INSTALL_NAME" ]] || fail \
            "framework install ID in slice $slice is '$install_id', expected '$EXPECTED_FRAMEWORK_INSTALL_NAME'"
    done <<< "$records"
    [[ -n "$current_slice" ]] || fail "framework install-ID set has no architecture slices"
    (( entries_in_slice == 1 )) || fail \
        "framework slice $current_slice has $entries_in_slice install IDs"
    (( slice_count == expected_slices )) || fail \
        "framework install-ID parser covered $slice_count slices, expected $expected_slices"
}

# `otool -L` emits one header and one complete load-command list per architecture slice.
# Parse only indented load-command rows, reject malformed or empty slices, and validate every
# dependency in every slice. The framework's own LC_ID_DYLIB appears once per framework slice.
validate_dependency_set host "$HOST_LIBRARIES" "$HOST_SLICE_COUNT"
validate_dependency_set framework "$FRAMEWORK_LIBRARIES" "$FRAMEWORK_SLICE_COUNT"
validate_framework_install_ids "$FRAMEWORK_INSTALL_IDS" "$FRAMEWORK_SLICE_COUNT"

verify_signature() {
    local target="$1" label="$2"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$target" || fail \
        "strict code-signature verification failed for $label"
}
verify_signature "$FRAMEWORK" "LiveKitWebRTC.framework"
verify_signature "$EXECUTABLE" "the main executable"
verify_signature "$APP_PATH" "the app bundle"

# The host and framework ship without custom entitlements. Reject any entitlement drift.
for signed_target in "$APP_PATH" "$EXECUTABLE" "$FRAMEWORK"; do
    entitlement_output="$(/usr/bin/codesign -d --entitlements :- "$signed_target" 2>/dev/null)" || fail \
        "could not inspect signed-code entitlements: $signed_target"
    if [[ -n "$entitlement_output" && "$entitlement_output" != *'<dict/>'* \
        && "$entitlement_output" != *'<dict></dict>'* ]]; then
        fail "signed code contains unreviewed entitlements: $signed_target"
    fi
done

read_code_metadata() {
    local target="$1" label="$2"
    CODE_METADATA="$(/usr/bin/codesign --display --verbose=4 "$target" 2>&1)" || fail \
        "could not read code-signature metadata for $label"
    CODE_IDENTIFIER="$(print -r -- "$CODE_METADATA" | /usr/bin/awk -F= '$1 == "Identifier" { print substr($0, index($0, "=") + 1); exit }')"
    CODE_TEAM_ID="$(print -r -- "$CODE_METADATA" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }')"
    CODE_REQUIREMENTS_OUTPUT="$(/usr/bin/codesign --display --requirements - "$target" 2>&1)" || fail \
        "could not read designated requirement for $label"
    CODE_DESIGNATED_REQUIREMENT="$(print -r -- "$CODE_REQUIREMENTS_OUTPUT" | /usr/bin/awk '
        /^# designated =>/ { sub(/^# /, ""); print; exit }
        /^designated =>/ { print; exit }
    ')"
    [[ -n "$CODE_IDENTIFIER" && -n "$CODE_TEAM_ID" && -n "$CODE_DESIGNATED_REQUIREMENT" ]] || fail \
        "code identity metadata is incomplete for $label"
}

read_code_metadata "$APP_PATH" "the app bundle"
APP_CODE_IDENTIFIER="$CODE_IDENTIFIER"; APP_TEAM_ID="$CODE_TEAM_ID"; APP_DR="$CODE_DESIGNATED_REQUIREMENT"
read_code_metadata "$EXECUTABLE" "the main executable"
EXECUTABLE_CODE_IDENTIFIER="$CODE_IDENTIFIER"; EXECUTABLE_TEAM_ID="$CODE_TEAM_ID"; EXECUTABLE_DR="$CODE_DESIGNATED_REQUIREMENT"
read_code_metadata "$FRAMEWORK" "LiveKitWebRTC.framework"
FRAMEWORK_CODE_IDENTIFIER="$CODE_IDENTIFIER"; FRAMEWORK_TEAM_ID="$CODE_TEAM_ID"

[[ "$APP_CODE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || fail "wrong app signature identifier"
[[ "$EXECUTABLE_CODE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || fail "wrong executable signature identifier"
[[ "$FRAMEWORK_CODE_IDENTIFIER" == "$EXPECTED_FRAMEWORK_IDENTIFIER" ]] || fail "wrong framework signature identifier"
[[ "$APP_TEAM_ID" == "$EXECUTABLE_TEAM_ID" && "$APP_TEAM_ID" == "$FRAMEWORK_TEAM_ID" ]] || fail \
    "nested TeamIdentifier values differ"
if [[ "$APP_TEAM_ID" == "not set" ]]; then
    [[ "$APP_DR" == "designated => cdhash "* && "$EXECUTABLE_DR" == "designated => cdhash "* ]] || fail \
        "ad-hoc designated requirements are malformed"
else
    [[ "$APP_DR" == *"identifier \"$EXPECTED_BUNDLE_IDENTIFIER\""* ]] || fail \
        "app designated requirement lacks the preserved identifier"
    [[ "$APP_DR" == "$EXECUTABLE_DR" ]] || fail \
        "stably signed app and executable designated requirements differ"
fi

if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "expected TeamIdentifier is malformed"
    [[ "$APP_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail \
        "TeamIdentifier: expected '$EXPECTED_TEAM_ID', found '$APP_TEAM_ID'"
    verify_requirement() {
        local target="$1" identifier="$2"
        local requirement="identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
        /usr/bin/codesign --verify --strict "-R=$requirement" "$target" || fail \
            "signed code does not satisfy the expected identifier/team requirement: $target"
    }
    verify_requirement "$APP_PATH" "$EXPECTED_BUNDLE_IDENTIFIER"
    verify_requirement "$EXECUTABLE" "$EXPECTED_BUNDLE_IDENTIFIER"
    verify_requirement "$FRAMEWORK" "$EXPECTED_FRAMEWORK_IDENTIFIER"
fi

if [[ -n "$EXPECTED_DESIGNATED_REQUIREMENT_REFERENCE" ]]; then
    REFERENCE_INPUT="${EXPECTED_DESIGNATED_REQUIREMENT_REFERENCE%/}"
    [[ -f "$REFERENCE_INPUT" && ! -L "$REFERENCE_INPUT" ]] || fail \
        "designated-requirement reference is not a real regular file"
    [[ "$(/usr/bin/stat -f '%l' "$REFERENCE_INPUT")" == 1 ]] || fail \
        "designated-requirement reference must have one hard link"
    REFERENCE_PATH="${REFERENCE_INPUT:A}"
    read_code_metadata "$REFERENCE_PATH" "the designated-requirement reference"
    [[ "$CODE_TEAM_ID" == "$EXECUTABLE_TEAM_ID" ]] || fail \
        "main executable TeamIdentifier differs from reference"
    [[ "$CODE_DESIGNATED_REQUIREMENT" == "$EXECUTABLE_DR" ]] || fail \
        "main executable designated requirement does not match the reference code object"
fi

print -u2 -- "Verified opensteamer Host bundle: $APP_PATH"
