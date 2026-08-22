#!/bin/zsh
set -euo pipefail

export LC_ALL=C

fail() {
    print -u2 -- "$1"
    exit 65
}

canonical_manifest_text() {
    /usr/bin/printf '%s\n' "$@"
}

manifest_is_exact() {
    [[ "$1" == "$2" ]]
}

if (( $# != 1 )); then
    print -u2 "usage: $0 /absolute/path/OpensteamerVirtualMicrophone.driver"
    exit 64
fi

bundle="$1"
if [[ "$bundle" != /* ]] || \
   [[ "${bundle:t}" != "OpensteamerVirtualMicrophone.driver" ]] || \
   [[ ! -d "$bundle" ]] || [[ -L "$bundle" ]]; then
    print -u2 "expected an absolute, non-symlink OpensteamerVirtualMicrophone.driver bundle"
    exit 66
fi

# Treat the bundle as an exact lstat manifest. In particular, this rejects
# symlinks, unexpected empty directories, special nodes, and mode drift that a
# regular-file-only walk would miss.
expected_nodes=(
    "Directory|755|."
    "Directory|755|Contents"
    "Regular File|644|Contents/Info.plist"
    "Directory|755|Contents/MacOS"
    "Regular File|755|Contents/MacOS/OpensteamerVirtualMicrophone"
    "Directory|755|Contents/Resources"
    "Regular File|644|Contents/Resources/APPLE_SAMPLE_LICENSE.txt"
    "Directory|755|Contents/Resources/en.lproj"
    "Regular File|644|Contents/Resources/en.lproj/Localizable.strings"
    "Directory|755|Contents/_CodeSignature"
    "Regular File|644|Contents/_CodeSignature/CodeResources"
)
expected_regular_files=(
    "Contents/Info.plist"
    "Contents/MacOS/OpensteamerVirtualMicrophone"
    "Contents/Resources/APPLE_SAMPLE_LICENSE.txt"
    "Contents/Resources/en.lproj/Localizable.strings"
    "Contents/_CodeSignature/CodeResources"
)

actual_nodes=()
while IFS= read -r -d '' relative; do
    if [[ "$relative" == "." ]]; then
        display_path="."
        absolute_path="$bundle"
    else
        display_path="${relative#./}"
        absolute_path="$bundle/$display_path"
    fi
    type_and_mode="$(/usr/bin/stat -f '%HT|%Lp' "$absolute_path")" || \
        fail "unable to lstat driver bundle node: $display_path"
    actual_nodes+=("$type_and_mode|$display_path")
done < <(cd "$bundle" && /usr/bin/find -s . -print0)

expected_nodes_text="$(canonical_manifest_text "${expected_nodes[@]}")"
actual_nodes_text="$(canonical_manifest_text "${actual_nodes[@]}")"
if ! manifest_is_exact "$expected_nodes_text" "$actual_nodes_text"; then
    print -u2 "driver bundle lstat manifest is not exact"
    print -u2 "expected:"
    print -u2 -l -- "${expected_nodes[@]}"
    print -u2 "actual:"
    print -u2 -l -- "${actual_nodes[@]}"
    exit 65
fi

xattr_output="$(/usr/bin/xattr -lr "$bundle" 2>&1)" || \
    fail "unable to inspect driver bundle extended attributes"
if [[ -n "$xattr_output" ]]; then
    print -u2 "driver bundle must not contain extended attributes"
    print -u2 -- "$xattr_output"
    exit 65
fi

plist="$bundle/Contents/Info.plist"
executable="$bundle/Contents/MacOS/OpensteamerVirtualMicrophone"
/usr/bin/plutil -lint "$plist" >/dev/null || fail "driver Info.plist is invalid"

# Compare the parsed dictionary rather than plist serialization so dictionary
# order is irrelevant while every key, value, type, and nested cardinality is
# still exact.
if ! /usr/bin/python3 - "$plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
expected = {
    "CFBundleDevelopmentRegion": "English",
    "CFBundleExecutable": "OpensteamerVirtualMicrophone",
    "CFBundleIdentifier": "com.elamin.opensteamer.VirtualMicrophoneDriver",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "opensteamer Virtual Microphone",
    "CFBundlePackageType": "BNDL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleSignature": "????",
    "CFBundleVersion": "1",
    "CFPlugInFactories": {
        "81CE9D28-D187-499B-84EE-F6AC6159C800":
            "OpensteamerVirtualMicrophone_Create",
    },
    "CFPlugInTypes": {
        "443ABAB8-E7B3-491A-B985-BEB9187030DB": [
            "81CE9D28-D187-499B-84EE-F6AC6159C800",
        ],
    },
    "LSMinimumSystemVersion": "14.0",
}

try:
    with open(path, "rb") as stream:
        actual = plistlib.load(stream)
except Exception as error:
    print(f"unable to parse driver Info.plist: {error}", file=sys.stderr)
    raise SystemExit(1)

if actual != expected:
    actual_keys = set(actual) if isinstance(actual, dict) else set()
    expected_keys = set(expected)
    print("driver Info.plist contract is not exact", file=sys.stderr)
    print(f"missing root keys: {sorted(expected_keys - actual_keys)!r}", file=sys.stderr)
    print(f"unexpected root keys: {sorted(actual_keys - expected_keys)!r}", file=sys.stderr)
    raise SystemExit(1)
PY
then
    fail "driver Info.plist verification failed"
fi

archs="$(/usr/bin/lipo -archs "$executable")" || fail "unable to inspect driver architectures"
if [[ " $archs " != *" arm64 "* ]] || \
   [[ " $archs " != *" x86_64 "* ]] || \
   (( ${#${(z)archs}} != 2 )); then
    fail "driver executable must contain exactly arm64 and x86_64 slices (actual: $archs)"
fi

/usr/bin/codesign --verify --strict --all-architectures "$bundle" || \
    fail "driver bundle code signature verification failed"
for arch in arm64 x86_64; do
    signature_details="$(/usr/bin/codesign -d -a "$arch" --verbose=4 "$bundle" 2>&1)" || \
        fail "unable to inspect $arch driver code signature"
    [[ "$signature_details" == *$'Identifier=com.elamin.opensteamer.VirtualMicrophoneDriver\n'* ]] || \
        fail "$arch driver signature identifier is not exact"
    [[ "$signature_details" == *$'Signature=adhoc\n'* ]] || \
        fail "$arch driver slice must use an ad-hoc signature"
    [[ "$signature_details" == *$'TeamIdentifier=not set\n'* ]] || \
        fail "$arch driver slice must not have a team identifier"
    [[ "$signature_details" != *"Authority="* ]] || \
        fail "$arch driver slice must not have a signing authority chain"

    entitlements="$(/usr/bin/codesign -d -a "$arch" --entitlements :- "$bundle" 2>/dev/null)" || \
        fail "unable to inspect $arch driver entitlements"
    [[ -z "$entitlements" ]] || fail "$arch driver slice must not contain entitlements"
done

for arch in arm64 x86_64; do
    mach_header="$(/usr/bin/otool -arch "$arch" -hv "$executable")" || \
        fail "unable to inspect $arch Mach-O header"
    header_summary="$(/usr/bin/awk '
        $1 == "MH_MAGIC_64" {
            rows++
            if ($5 == "BUNDLE") bundles++
        }
        END { print (rows + 0) ":" (bundles + 0) }
    ' <<< "$mach_header")"
    [[ "$header_summary" == "1:1" ]] || \
        fail "$arch driver slice must have Mach-O filetype MH_BUNDLE"

    uuid_values="$(/usr/bin/awk '
        $1 == "uuid" { print $2 }
    ' <<< "$(/usr/bin/otool -arch "$arch" -l "$executable")")"
    uuid_count="$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' \
        <<< "$uuid_values")"
    [[ "$uuid_count" == "1" ]] || \
        fail "$arch driver slice must contain exactly one LC_UUID"
    if ! /usr/bin/grep -Eq \
        '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' \
        <<< "$uuid_values"; then
        fail "$arch driver slice LC_UUID is malformed"
    fi
    [[ "$uuid_values" != "00000000-0000-0000-0000-000000000000" ]] || \
        fail "$arch driver slice LC_UUID must be nonzero"

    build_version="$(/usr/bin/vtool -arch "$arch" -show-build "$executable")" || \
        fail "unable to inspect $arch build version"
    build_summary="$(/usr/bin/awk '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { commands++ }
        $1 == "platform" {
            platforms++
            if ($2 == "MACOS") macos_platforms++
        }
        $1 == "minos" {
            versions++
            if ($2 == "14.0") correct_versions++
        }
        END {
            print (commands + 0) ":" (platforms + 0) ":" \
                  (macos_platforms + 0) ":" (versions + 0) ":" \
                  (correct_versions + 0)
        }
    ' <<< "$build_version")"
    [[ "$build_summary" == "1:1:1:1:1" ]] || \
        fail "$arch driver slice must contain exactly one macOS LC_BUILD_VERSION with minOS 14.0"
done

load_commands="$(/usr/bin/otool -l "$executable")" || fail "unable to inspect load commands"
for forbidden_command in LC_RPATH; do
    forbidden_count="$(/usr/bin/awk -v forbidden="$forbidden_command" '
        $1 == "cmd" && $2 == forbidden { count++ }
        END { print count + 0 }
    ' <<< "$load_commands")"
    [[ "$forbidden_count" == "0" ]] || \
        fail "driver executable must not contain $forbidden_command"
done

exports="$(/usr/bin/nm -gjU "$executable")" || fail "unable to inspect driver exports"
[[ "$exports" == "_OpensteamerVirtualMicrophone_Create" ]] || \
    fail "driver executable export set is not exact"

dependencies="$(/usr/bin/otool -L "$executable" | /usr/bin/awk '/^[[:space:]]/ {print $1}')" || \
    fail "unable to inspect driver dependencies"
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/Frameworks/CoreAudio.framework/* | \
        /System/Library/Frameworks/CoreFoundation.framework/* | \
        /usr/lib/libSystem.B.dylib)
            ;;
        *)
            fail "unexpected driver dependency: $dependency"
            ;;
    esac
done <<< "$dependencies"

tree_sha256="$(
    {
        for node in "${actual_nodes[@]}"; do
            /usr/bin/printf '%s\0' "$node"
        done
        for relative in "${expected_regular_files[@]}"; do
            digest="$(/usr/bin/shasum -a 256 "$bundle/$relative" | /usr/bin/awk '{print $1}')"
            /usr/bin/printf '%s\0%s\0' "$relative" "$digest"
        done
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)"
print "bundle_tree_sha256=$tree_sha256"
print "executable_sha256=$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')"
print "VERIFIED_ADHOC_LOCAL_DRIVER_BUNDLE"
