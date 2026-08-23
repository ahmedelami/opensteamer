#!/bin/zsh
# Builds, normalizes, signs, and verifies a fresh Release `opensteamer Host.app`.
set -euo pipefail
umask 077

readonly ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
readonly BUNDLE_VERIFIER="$ROOT_DIR/macOS/scripts/verify-mac-host-bundle.sh"
readonly PINNED_BUNDLE_VERIFIER_SCRIPT="${OPENSTEAMER_PINNED_BUNDLE_VERIFIER_SCRIPT:-}"
readonly APP_OUTPUT_DIR="${OPENSTEAMER_HOST_APP_OUTPUT_DIR:-$ROOT_DIR/build}"
readonly APP_DIR="$APP_OUTPUT_DIR/opensteamer Host.app"
readonly CONTENTS_DIR="$APP_DIR/Contents"
readonly MACOS_DIR="$CONTENTS_DIR/MacOS"
readonly FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
readonly RESOURCES_DIR="$CONTENTS_DIR/Resources"
readonly EXPECTED_TEAM_ID="${OPENSTEAMER_EXPECTED_TEAM_ID:-}"
readonly EXPECTED_SIGNING_IDENTITY_SHA1="${OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1:-}"
readonly DESIGNATED_REQUIREMENT_REFERENCE="${OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE:-}"
readonly REQUIRE_FRESH_RELEASE="${OPENSTEAMER_REQUIRE_FRESH_RELEASE:-0}"
readonly ALLOW_PREBUILT_FOR_TESTS="${OPENSTEAMER_ALLOW_PREBUILT_FOR_TESTS:-0}"
readonly SCRATCH_PATH_INPUT="${OPENSTEAMER_HOST_SCRATCH_PATH:-}"
readonly EXPECTED_ARCHITECTURES="${OPENSTEAMER_EXPECTED_ARCHITECTURES:-}"

fail() {
    print -u2 -- "build-opensteamer-host-app: $*"
    exit 1
}

run_bundle_verifier() {
    if [[ -n "$PINNED_BUNDLE_VERIFIER_SCRIPT" ]]; then
        /bin/zsh -c "$PINNED_BUNDLE_VERIFIER_SCRIPT" "$BUNDLE_VERIFIER" "$@"
    else
        "$BUNDLE_VERIFIER" "$@"
    fi
}

[[ "$REQUIRE_FRESH_RELEASE" == 0 || "$REQUIRE_FRESH_RELEASE" == 1 ]] || fail \
    "OPENSTEAMER_REQUIRE_FRESH_RELEASE must be 0 or 1"
[[ "$ALLOW_PREBUILT_FOR_TESTS" == 0 || "$ALLOW_PREBUILT_FOR_TESTS" == 1 ]] || fail \
    "OPENSTEAMER_ALLOW_PREBUILT_FOR_TESTS must be 0 or 1"

[[ "$APP_OUTPUT_DIR" == /* ]] || fail "output directory must be absolute"
[[ -d "${APP_OUTPUT_DIR:h}" && ! -L "${APP_OUTPUT_DIR:h}" ]] || fail \
    "output parent is not a real directory: ${APP_OUTPUT_DIR:h}"
if [[ -e "$APP_OUTPUT_DIR" || -L "$APP_OUTPUT_DIR" ]]; then
    [[ -d "$APP_OUTPUT_DIR" && ! -L "$APP_OUTPUT_DIR" ]] || fail \
        "output directory is not a real directory: $APP_OUTPUT_DIR"
else
    /bin/mkdir "$APP_OUTPUT_DIR" || fail "could not create output directory"
fi
[[ ! -e "$APP_DIR" && ! -L "$APP_DIR" ]] || fail \
    "destination app already exists; use a fresh output directory: $APP_DIR"

SIGNING_IDENTITY="${OPENSTEAMER_HOST_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$({
        /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true
    } | /usr/bin/awk '/"Apple Development:/{print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    print -u2 -- "warning: no Apple Development identity found; using ad-hoc signing"
fi

if [[ -n "$EXPECTED_SIGNING_IDENTITY_SHA1" ]]; then
    [[ "$EXPECTED_SIGNING_IDENTITY_SHA1" =~ ^[[:xdigit:]]{40}$ ]] || fail \
        "expected signing identity SHA-1 must be exactly 40 hexadecimal characters"
    [[ "${SIGNING_IDENTITY:u}" == "${EXPECTED_SIGNING_IDENTITY_SHA1:u}" ]] || fail \
        "signing identity '$SIGNING_IDENTITY' does not equal expected SHA-1"
    identity_count="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -v expected="${EXPECTED_SIGNING_IDENTITY_SHA1:u}" \
          '{ candidate=toupper($2); if (candidate == expected) count += 1 } END { print count + 0 }')"
    [[ "$identity_count" == 1 ]] || fail "expected signing identity is not uniquely available"
fi

if [[ "$REQUIRE_FRESH_RELEASE" == 1 || -n "$EXPECTED_TEAM_ID" \
    || -n "$DESIGNATED_REQUIREMENT_REFERENCE" ]]; then
    [[ -n "$EXPECTED_TEAM_ID" ]] || fail "OPENSTEAMER_EXPECTED_TEAM_ID is required"
    [[ -n "$EXPECTED_SIGNING_IDENTITY_SHA1" ]] || fail \
        "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1 is required"
    [[ -n "$DESIGNATED_REQUIREMENT_REFERENCE" ]] || fail \
        "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE is required"
    [[ "$SIGNING_IDENTITY" != "-" ]] || fail "migration/release builds may not use ad-hoc signing"
fi

if [[ "$REQUIRE_FRESH_RELEASE" == 1 ]]; then
    [[ -n "$SCRATCH_PATH_INPUT" ]] || fail \
        "OPENSTEAMER_HOST_SCRATCH_PATH is required for a fresh Release build"
fi
if [[ -n "$SCRATCH_PATH_INPUT" ]]; then
    [[ "$SCRATCH_PATH_INPUT" == /* ]] || fail "SwiftPM scratch path must be absolute"
    SCRATCH_PATH="${SCRATCH_PATH_INPUT:a}"
    [[ "$SCRATCH_PATH" == "$SCRATCH_PATH_INPUT" ]] || fail \
        "SwiftPM scratch path must be canonical and normalized"
    [[ ! -L "$SCRATCH_PATH" ]] || fail "SwiftPM scratch path must not be a symlink"
    if [[ -e "$SCRATCH_PATH" ]]; then
        [[ -d "$SCRATCH_PATH" ]] || fail "SwiftPM scratch path is not a directory"
        [[ "$(/usr/bin/stat -f '%u' "$SCRATCH_PATH")" == "$UID" ]] || fail \
            "SwiftPM scratch path is not owned by the current uid"
        [[ "$(/usr/bin/stat -f '%Lp' "$SCRATCH_PATH")" == 700 ]] || fail \
            "SwiftPM scratch path must be mode 0700"
        [[ -z "$(/bin/ls -A "$SCRATCH_PATH")" ]] || fail \
            "fresh Release scratch path must be empty"
    else
        [[ -d "${SCRATCH_PATH:h}" && ! -L "${SCRATCH_PATH:h}" ]] || fail \
            "SwiftPM scratch parent is not a real directory"
        /bin/mkdir "$SCRATCH_PATH" || fail "could not create SwiftPM scratch path"
        /bin/chmod 700 "$SCRATCH_PATH" || fail "could not protect SwiftPM scratch path"
    fi
else
    SCRATCH_PATH=''
fi
readonly SCRATCH_PATH

cd "$ROOT_DIR"
BUILD_STARTED_AT="$(/bin/date +%s)" || fail "could not record build start time"
if [[ -n "${OPENSTEAMER_HOST_PREBUILT_BIN_DIR:-}" ]]; then
    [[ "$ALLOW_PREBUILT_FOR_TESTS" == 1 ]] || fail \
        "prebuilt products are test-only and require OPENSTEAMER_ALLOW_PREBUILT_FOR_TESTS=1"
    [[ "$REQUIRE_FRESH_RELEASE" == 0 ]] || fail \
        "fresh migration builds may not use prebuilt products"
    BIN_DIR="${OPENSTEAMER_HOST_PREBUILT_BIN_DIR:A}"
else
    export MACOSX_DEPLOYMENT_TARGET=14.0
    export SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    export OTHER_SWIFT_FLAGS="${OTHER_SWIFT_FLAGS:-} -warnings-as-errors"
    export OTHER_CFLAGS="${OTHER_CFLAGS:-} -Werror"
    export OTHER_CPLUSPLUSFLAGS="${OTHER_CPLUSPLUSFLAGS:-} -Werror"
    if [[ -n "$SCRATCH_PATH" ]]; then
        /usr/bin/swift build --scratch-path "$SCRATCH_PATH" -c release \
            -Xswiftc -warnings-as-errors -Xcc -Werror --product CaptureServer
        BIN_DIR="$(/usr/bin/swift build --scratch-path "$SCRATCH_PATH" -c release --show-bin-path)"
    else
        /usr/bin/swift build -c release -Xswiftc -warnings-as-errors -Xcc -Werror \
            --product CaptureServer
        BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"
    fi
fi
BIN_DIR="${BIN_DIR:A}"
if [[ "$REQUIRE_FRESH_RELEASE" == 1 ]]; then
    [[ "$BIN_DIR" == "${SCRATCH_PATH:A}/"* ]] || fail \
        "Release products escaped the isolated scratch directory"
    [[ "${BIN_DIR:t}" == release ]] || fail "SwiftPM bin path is not Release"
fi
readonly BIN_DIR
readonly EXECUTABLE_SOURCE="$BIN_DIR/CaptureServer"
readonly WEBRTC_FRAMEWORK_SOURCE="$BIN_DIR/LiveKitWebRTC.framework"
readonly EXECUTABLE="$MACOS_DIR/CaptureServer"
readonly WEBRTC_FRAMEWORK="$FRAMEWORKS_DIR/LiveKitWebRTC.framework"
readonly WEBRTC_EXECUTABLE="$WEBRTC_FRAMEWORK/LiveKitWebRTC"

[[ -f "$EXECUTABLE_SOURCE" && ! -L "$EXECUTABLE_SOURCE" && -x "$EXECUTABLE_SOURCE" ]] || fail \
    "CaptureServer build product is not a safe executable"
if [[ "$REQUIRE_FRESH_RELEASE" == 1 ]]; then
    [[ "$(/usr/bin/stat -f '%m' "$EXECUTABLE_SOURCE")" -ge "$BUILD_STARTED_AT" ]] || fail \
        "CaptureServer predates this fresh Release build"
fi
[[ -d "$WEBRTC_FRAMEWORK_SOURCE" && ! -L "$WEBRTC_FRAMEWORK_SOURCE" ]] || fail \
    "LiveKitWebRTC.framework is not a safe directory"

/bin/mkdir "$APP_DIR" "$CONTENTS_DIR" "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR" \
    || fail "could not create app layout"
/bin/cp "$EXECUTABLE_SOURCE" "$EXECUTABLE" || fail "could not copy CaptureServer"
/usr/bin/ditto --noqtn "$WEBRTC_FRAMEWORK_SOURCE" "$WEBRTC_FRAMEWORK" \
    || fail "could not copy LiveKitWebRTC.framework"
/bin/cp "$ROOT_DIR/macOS/OpensteamerHost/Info.plist" "$CONTENTS_DIR/Info.plist" \
    || fail "could not copy host Info.plist"
/bin/cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/ThirdPartyNotices.md" \
    || fail "could not copy third-party notices"

# Require the exact five reviewed versioned-framework aliases before signing. Missing aliases,
# aliases replaced by real entries, redirected aliases, and any extra symlink are all rejected.
framework_root="${WEBRTC_FRAMEWORK:A}"
expected_alias_names=$'Headers\nLiveKitWebRTC\nModules\nResources\nVersions/Current'
actual_alias_names="$(/usr/bin/find "$WEBRTC_FRAMEWORK" -type l -print \
    | /usr/bin/sed "s#^$WEBRTC_FRAMEWORK/##" | LC_ALL=C /usr/bin/sort)" \
    || fail "could not inspect framework aliases"
[[ "$actual_alias_names" == "$expected_alias_names" ]] || fail \
    "framework alias set differs from the exact reviewed set: ${actual_alias_names:-none}"
require_framework_alias() {
    local relative="$1" expected_target="$2"
    local link="$WEBRTC_FRAMEWORK/$relative"
    [[ -L "$link" ]] || fail "required framework alias is missing or not a symlink: $relative"
    local target
    target="$(/usr/bin/readlink "$link")" || fail "could not read framework alias: $relative"
    [[ "$target" == "$expected_target" ]] || fail \
        "framework alias '$relative' targets '$target', expected '$expected_target'"
    local resolved="${link:h}/$target"
    resolved="${resolved:A}"
    [[ "$resolved" == "$framework_root/"* ]] || fail \
        "framework symlink escapes its bundle: $relative -> $target"
}
require_framework_alias LiveKitWebRTC Versions/Current/LiveKitWebRTC
require_framework_alias Headers Versions/Current/Headers
require_framework_alias Modules Versions/Current/Modules
require_framework_alias Resources Versions/Current/Resources
require_framework_alias Versions/Current A

# The pinned LiveKitWebRTC 144.7559.11 artifact contains one exact nested privacy-manifest spine.
version_a="$WEBRTC_FRAMEWORK/Versions/A"
[[ -d "$version_a" && ! -L "$version_a" ]] || fail "framework version A is not a real directory"
version_a_entries="$(/bin/ls -1A "$version_a" | LC_ALL=C /usr/bin/sort)" || fail \
    "could not inspect framework version A"
[[ "$version_a_entries" == $'Headers\nLiveKitWebRTC\nModules\nResources\nVersions' ]] || fail \
    "framework pristine pre-sign version A layout differs from pinned LiveKitWebRTC 144.7559.11: $version_a_entries"
nested_versions="$version_a/Versions"
nested_a="$nested_versions/A"
nested_resources="$nested_a/Resources"
[[ -d "$nested_versions" && ! -L "$nested_versions" \
    && "$(/bin/ls -1A "$nested_versions")" == A ]] || fail \
    "framework pinned nested Versions layout is invalid"
[[ -d "$nested_a" && ! -L "$nested_a" \
    && "$(/bin/ls -1A "$nested_a")" == Resources ]] || fail \
    "framework pinned nested version A layout is invalid"
[[ -d "$nested_resources" && ! -L "$nested_resources" \
    && "$(/bin/ls -1A "$nested_resources")" == PrivacyInfo.xcprivacy ]] || fail \
    "framework pinned nested Resources layout is invalid"
[[ -f "$nested_resources/PrivacyInfo.xcprivacy" \
    && ! -L "$nested_resources/PrivacyInfo.xcprivacy" \
    && "$(/usr/bin/stat -f '%l' "$nested_resources/PrivacyInfo.xcprivacy")" == 1 ]] || fail \
    "framework pinned privacy manifest is unsafe"
/usr/bin/plutil -lint "$nested_resources/PrivacyInfo.xcprivacy" >/dev/null || fail \
    "framework pinned privacy manifest is invalid"

WEBRTC_EXECUTABLE_REAL="${WEBRTC_EXECUTABLE:A}"
[[ "$WEBRTC_EXECUTABLE_REAL" == "$framework_root/"* \
    && -f "$WEBRTC_EXECUTABLE_REAL" && ! -L "$WEBRTC_EXECUTABLE_REAL" \
    && -x "$WEBRTC_EXECUTABLE_REAL" ]] || fail \
    "framework executable does not resolve to a real in-bundle executable"

normalize_arches() {
    print -r -- "$1" | /usr/bin/tr ' ' '\n' | /usr/bin/sed '/^$/d' \
        | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//'
}
host_arches="$(normalize_arches "$(/usr/bin/lipo -archs "$EXECUTABLE")")" \
    || fail "could not read host architectures"
framework_arches="$(normalize_arches "$(/usr/bin/lipo -archs "$WEBRTC_EXECUTABLE_REAL")")" \
    || fail "could not read framework architectures"
[[ -n "$host_arches" && -n "$framework_arches" ]] || fail \
    "host or framework architecture metadata is empty"
for arch in ${(s: :)host_arches}; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || fail \
        "unexpected host architecture: $arch"
    print -r -- "$framework_arches" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -Fxq "$arch" || fail \
        "framework architectures '$framework_arches' do not contain host slice '$arch'"
done
for arch in ${(s: :)framework_arches}; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || fail \
        "unexpected framework architecture: $arch"
done

# Normalize host rpaths before signing. Remove one load command at a time and verify progress so
# duplicate rpaths cannot survive. The final set is exactly the reviewed embedded-framework path.
read_host_rpaths() {
    /usr/bin/otool -l "$EXECUTABLE" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" { print $2; in_rpath = 0 }
    '
}
for removal in {1..64}; do
    rpaths="$(read_host_rpaths)" || fail "could not read host rpaths"
    [[ -n "$rpaths" ]] || break
    rpath="${rpaths%%$'\n'*}"
    before_count="$(print -r -- "$rpaths" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    /usr/bin/install_name_tool -delete_rpath "$rpath" "$EXECUTABLE" \
        || fail "could not remove host rpath: $rpath"
    after_rpaths="$(read_host_rpaths)" || fail "could not reread host rpaths"
    after_count="$(print -r -- "$after_rpaths" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    (( after_count < before_count )) || fail "rpath removal made no progress: $rpath"
done
[[ -z "$(read_host_rpaths)" ]] || fail "host contains more than 64 LC_RPATH entries"
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE" \
    || fail "could not add reviewed host rpath"
[[ "$(read_host_rpaths)" == "@executable_path/../Frameworks" ]] || fail \
    "host LC_RPATH normalization did not produce the exact reviewed value"

# Remove inherited xattrs before signing; the verifier requires an exact empty xattr set.
/usr/bin/xattr -cr "$APP_DIR" || fail "could not clear inherited extended attributes"
/bin/chmod 755 "$APP_DIR" "$CONTENTS_DIR" "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
/bin/chmod 755 "$EXECUTABLE" "$WEBRTC_EXECUTABLE_REAL"
/bin/chmod 644 "$CONTENTS_DIR/Info.plist" "$RESOURCES_DIR/ThirdPartyNotices.md"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$WEBRTC_FRAMEWORK" \
    || fail "could not sign LiveKitWebRTC.framework"
post_sign_version_a_entries="$(/bin/ls -1A "$version_a" | LC_ALL=C /usr/bin/sort)" || fail \
    "could not inspect signed framework version A"
[[ "$post_sign_version_a_entries" == $'Headers\nLiveKitWebRTC\nModules\nResources\nVersions\n_CodeSignature' ]] || fail \
    "framework post-sign version A layout differs from the exact reviewed layout: $post_sign_version_a_entries"
[[ -d "$version_a/_CodeSignature" && ! -L "$version_a/_CodeSignature" ]] || fail \
    "framework post-sign _CodeSignature is missing or unsafe"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier com.elamin.AudioStreamer.CaptureServer --timestamp=none "$EXECUTABLE" \
    || fail "could not sign CaptureServer"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR" \
    || fail "could not sign opensteamer Host.app"

VERIFY_ARGUMENTS=("$APP_DIR")
if [[ -n "$EXPECTED_TEAM_ID" || -n "$DESIGNATED_REQUIREMENT_REFERENCE" ]]; then
    VERIFY_ARGUMENTS+=("$EXPECTED_TEAM_ID")
fi
if [[ -n "$DESIGNATED_REQUIREMENT_REFERENCE" ]]; then
    VERIFY_ARGUMENTS+=("$DESIGNATED_REQUIREMENT_REFERENCE")
fi
OPENSTEAMER_EXPECTED_ARCHITECTURES="$EXPECTED_ARCHITECTURES" \
    run_bundle_verifier "${VERIFY_ARGUMENTS[@]}"

print -u2 -- "Signed opensteamer Host with: $SIGNING_IDENTITY"
print -r -- "$APP_DIR"
