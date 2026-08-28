#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077

fail() {
    print -u2 -- "$1"
    exit 65
}

usage() {
    print -u2 "usage: $0 bundle package app-cert-sha1 installer-leaf-sha256 bundle-tree-sha256 executable-sha256 package-sha256"
    exit 64
}

canonical_manifest_text() {
    /usr/bin/printf '%s\n' "$@"
}

manifest_is_exact() {
    [[ "$1" == "$2" ]]
}

self_test_lstat_manifest_v8() {
    local -a sample_nodes=(
        "Directory|755|."
        "Directory|755|Contents"
    )
    local actual_manifest exact_manifest literal_backslash_n_mutant
    actual_manifest="$(canonical_manifest_text "${sample_nodes[@]}")"
    exact_manifest=$'Directory|755|.\nDirectory|755|Contents'
    literal_backslash_n_mutant='Directory|755|.\nDirectory|755|Contents'

    manifest_is_exact "$exact_manifest" "$actual_manifest" || \
        fail "real-LF lstat manifest self-test rejected the exact manifest"
    if manifest_is_exact "$exact_manifest" "$literal_backslash_n_mutant"; then
        fail "real-LF lstat manifest self-test accepted the literal-backslash-n mutant"
    fi
    print "SELF_TEST_OK production-driver-lstat-manifest-v8"
}

if (( $# == 1 )) && [[ "$1" == "--self-test-lstat-manifest-v8" ]]; then
    self_test_lstat_manifest_v8
    exit 0
fi

(( $# == 7 )) || usage
bundle="$1"
package="$2"
expected_app_certificate_sha1="$3"
expected_installer_leaf_sha256="${4:u}"
expected_tree_sha256="$5"
expected_executable_sha256="$6"
expected_package_sha256="$7"

[[ "$expected_app_certificate_sha1" =~ '^[0-9A-Fa-f]{40}$' ]] || \
    fail "Developer ID Application SHA-1 pin must be exactly 40 hexadecimal characters"
[[ "$expected_installer_leaf_sha256" =~ '^[0-9A-F]{64}$' ]] || \
    fail "Developer ID Installer leaf SHA-256 pin must be exactly 64 uppercase hexadecimal characters"
for digest in \
    "$expected_tree_sha256" \
    "$expected_executable_sha256" \
    "$expected_package_sha256"; do
    [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || \
        fail "artifact SHA-256 pins must be exactly 64 lowercase hexadecimal characters"
done
expected_app_certificate_sha1="${expected_app_certificate_sha1:u}"

[[ "$bundle" == /* ]] && [[ "${bundle:t}" == "OpensteamerVirtualMicrophone.driver" ]] \
    && [[ -d "$bundle" ]] && [[ ! -L "$bundle" ]] || \
    fail "production driver must be an absolute non-symlink OpensteamerVirtualMicrophone.driver"
[[ "$package" == /* ]] && [[ "${package:t}" == "OpensteamerVirtualMicrophone-v8.pkg" ]] \
    && [[ -f "$package" ]] && [[ ! -L "$package" ]] || \
    fail "production package must be an absolute non-symlink OpensteamerVirtualMicrophone-v8.pkg"

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
expected_payload_paths=(
    "."
    "./Library"
    "./Library/Audio"
    "./Library/Audio/Plug-Ins"
    "./Library/Audio/Plug-Ins/HAL"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/Info.plist"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/MacOS"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/MacOS/OpensteamerVirtualMicrophone"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/Resources"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/Resources/APPLE_SAMPLE_LICENSE.txt"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/Resources/en.lproj"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/Resources/en.lproj/Localizable.strings"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/_CodeSignature"
    "./Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/_CodeSignature/CodeResources"
)

collect_nodes() {
    local root="$1"
    local -a nodes=()
    local relative display absolute type_and_mode
    while IFS= read -r -d '' relative; do
        if [[ "$relative" == "." ]]; then
            display="."
            absolute="$root"
        else
            display="${relative#./}"
            absolute="$root/$display"
        fi
        type_and_mode="$(/usr/bin/stat -f '%HT|%Lp' "$absolute")" || \
            fail "unable to lstat production driver node: $display"
        nodes+=("$type_and_mode|$display")
    done < <(cd "$root" && /usr/bin/find -s . -print0)
    print -r -l -- "${nodes[@]}"
}

tree_sha256() {
    local root="$1"
    local nodes relative digest
    nodes="$(collect_nodes "$root")"
    {
        while IFS= read -r node; do
            /usr/bin/printf '%s\0' "$node"
        done <<< "$nodes"
        for relative in "${expected_regular_files[@]}"; do
            digest="$(/usr/bin/shasum -a 256 "$root/$relative" | /usr/bin/awk '{print $1}')"
            /usr/bin/printf '%s\0%s\0' "$relative" "$digest"
        done
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

verify_plist() {
    local plist="$1"
    /usr/bin/plutil -lint "$plist" >/dev/null || fail "production driver Info.plist is invalid"
    /usr/bin/python3 - "$plist" <<'PY' || fail "production driver Info.plist contract is not exact"
import plistlib
import sys

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

with open(sys.argv[1], "rb") as stream:
    actual = plistlib.load(stream)
if actual != expected:
    raise SystemExit("production driver Info.plist contract is not exact")
PY
}

certificate_sha1() {
    local target="$1"
    local arch="$2"
    local certificate_root="$3"
    local prefix="$certificate_root/$arch/certificate"
    /bin/mkdir -p "${prefix:h}"
    /usr/bin/codesign -d -a "$arch" --extract-certificates="$prefix" "$target" \
        >/dev/null 2>&1 || fail "unable to extract $arch leaf signing certificate"
    [[ -f "${prefix}0" ]] && [[ ! -L "${prefix}0" ]] || \
        fail "$arch leaf signing certificate was not extracted"
    /usr/bin/openssl x509 -inform DER -in "${prefix}0" -noout -fingerprint -sha1 \
        | /usr/bin/awk -F= 'NF == 2 { value=toupper($2); gsub(":", "", value); print value }'
}

verify_driver() {
    local target="$1"
    local expected_nodes_text actual_nodes_text xattrs executable archs details entitlements
    local requirement leaf_sha1
    expected_nodes_text="$(canonical_manifest_text "${expected_nodes[@]}")"
    actual_nodes_text="$(collect_nodes "$target")"
    manifest_is_exact "$expected_nodes_text" "$actual_nodes_text" || \
        fail "production driver lstat manifest is not exact"
    xattrs="$(/usr/bin/xattr -lr "$target" 2>&1)" || \
        fail "unable to inspect production driver extended attributes"
    [[ -z "$xattrs" ]] || fail "production driver must not contain extended attributes"
    verify_plist "$target/Contents/Info.plist"
    executable="$target/Contents/MacOS/OpensteamerVirtualMicrophone"
    archs="$(/usr/bin/lipo -archs "$executable")" || \
        fail "unable to inspect production driver architectures"
    [[ " $archs " == *" arm64 "* ]] && [[ " $archs " == *" x86_64 "* ]] \
        && (( ${#${(z)archs}} == 2 )) || \
        fail "production driver must contain exactly arm64 and x86_64"
    /usr/bin/codesign --verify --strict --all-architectures "$target" || \
        fail "production driver signature verification failed"
    requirement='identifier "com.elamin.opensteamer.VirtualMicrophoneDriver" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "MSMG8CJLB3"'
    /usr/bin/codesign --verify --strict --all-architectures "-R=$requirement" "$target" || \
        fail "production driver designated requirement is not exact"

    local certificate_root
    certificate_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-driver-certificates.XXXXXX)"
    case "$certificate_root" in
        /private/tmp/opensteamer-driver-certificates.*) ;;
        *) fail "unsafe certificate scratch path" ;;
    esac
    for arch in arm64 x86_64; do
        details="$(/usr/bin/codesign -d -a "$arch" --verbose=4 "$target" 2>&1)" || \
            fail "unable to inspect $arch production driver signature"
        [[ "$details" == *$'Identifier=com.elamin.opensteamer.VirtualMicrophoneDriver\n'* ]] || \
            fail "$arch production driver identifier is not exact"
        [[ "$details" == *$'TeamIdentifier=MSMG8CJLB3\n'* ]] || \
            fail "$arch production driver Team ID is not exact"
        [[ "$details" == *"Authority=Developer ID Application:"*"(MSMG8CJLB3)"* ]] || \
            fail "$arch production driver lacks the exact Developer ID Application authority"
        [[ "$details" == *"flags=0x10000(runtime)"* ]] || \
            fail "$arch production driver does not use hardened runtime"
        [[ "$details" == *$'Timestamp='* ]] && [[ "$details" != *$'Timestamp=none\n'* ]] || \
            fail "$arch production driver lacks a trusted timestamp"
        entitlements="$(/usr/bin/codesign -d -a "$arch" --entitlements :- "$target" 2>/dev/null)" || \
            fail "unable to inspect $arch production driver entitlements"
        [[ -z "$entitlements" ]] || fail "$arch production driver contains entitlements"
        leaf_sha1="$(certificate_sha1 "$target" "$arch" "$certificate_root")"
        [[ "$leaf_sha1" == "$expected_app_certificate_sha1" ]] || \
            fail "$arch production driver leaf certificate SHA-1 is not pinned"
    done
    /bin/rm -rf -- "$certificate_root"

    local exports dependencies
    exports="$(/usr/bin/nm -gjU "$executable")" || fail "unable to inspect driver exports"
    [[ "$exports" == "_OpensteamerVirtualMicrophone_Create" ]] || \
        fail "production driver export set is not exact"
    dependencies="$(/usr/bin/otool -L "$executable" | /usr/bin/awk '/^[[:space:]]/ {print $1}')" || \
        fail "unable to inspect driver dependencies"
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/Frameworks/CoreAudio.framework/* | \
            /System/Library/Frameworks/CoreFoundation.framework/* | \
            /usr/lib/libSystem.B.dylib) ;;
            *) fail "unexpected production driver dependency: $dependency" ;;
        esac
    done <<< "$dependencies"

    local arch mach_header build_version build_summary load_commands uuid_values uuid_count
    for arch in arm64 x86_64; do
        mach_header="$(/usr/bin/otool -arch "$arch" -hv "$executable")" || \
            fail "unable to inspect $arch production driver Mach-O header"
        [[ "$(/usr/bin/awk '$1 == "MH_MAGIC_64" { rows++; if ($5 == "BUNDLE") bundles++ } END { print (rows + 0) ":" (bundles + 0) }' <<< "$mach_header")" == "1:1" ]] || \
            fail "$arch production driver is not exactly one MH_BUNDLE slice"
        build_version="$(/usr/bin/vtool -arch "$arch" -show-build "$executable")" || \
            fail "unable to inspect $arch production driver build version"
        build_summary="$(/usr/bin/awk '
            $1 == "cmd" && $2 == "LC_BUILD_VERSION" { commands++ }
            $1 == "platform" { platforms++; if ($2 == "MACOS") macos++ }
            $1 == "minos" { versions++; if ($2 == "14.0") minos++ }
            END { print (commands + 0) ":" (platforms + 0) ":" (macos + 0) ":" (versions + 0) ":" (minos + 0) }
        ' <<< "$build_version")"
        [[ "$build_summary" == "1:1:1:1:1" ]] || \
            fail "$arch production driver build-version contract is not exact"
        uuid_values="$(/usr/bin/otool -arch "$arch" -l "$executable" | /usr/bin/awk '$1 == "uuid" { print $2 }')"
        uuid_count="$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' <<< "$uuid_values")"
        [[ "$uuid_count" == "1" ]] && \
            [[ "$uuid_values" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] && \
            [[ "$uuid_values" != "00000000-0000-0000-0000-000000000000" ]] || \
            fail "$arch production driver LC_UUID contract is not exact"
    done
    load_commands="$(/usr/bin/otool -l "$executable")" || \
        fail "unable to inspect production driver load commands"
    if /usr/bin/awk '$1 == "cmd" && $2 == "LC_RPATH" { found=1 } END { exit found ? 0 : 1 }' \
        <<< "$load_commands"; then
        fail "production driver contains forbidden LC_RPATH"
    fi
}

verify_driver "$bundle"

actual_tree_sha256="$(tree_sha256 "$bundle")"
[[ "$actual_tree_sha256" == "$expected_tree_sha256" ]] || \
    fail "production driver tree SHA-256 differs from the reviewed pin"
actual_executable_sha256="$(/usr/bin/shasum -a 256 "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone" | /usr/bin/awk '{print $1}')"
[[ "$actual_executable_sha256" == "$expected_executable_sha256" ]] || \
    fail "production driver executable SHA-256 differs from the reviewed pin"
actual_package_sha256="$(/usr/bin/shasum -a 256 "$package" | /usr/bin/awk '{print $1}')"
[[ "$actual_package_sha256" == "$expected_package_sha256" ]] || \
    fail "production driver package SHA-256 differs from the reviewed pin"

script_dir="${0:A:h}"
installer_signature_parser="$script_dir/parse-installer-signature-v8.sh"
[[ -f "$installer_signature_parser" ]] && [[ ! -L "$installer_signature_parser" ]] \
    && [[ -x "$installer_signature_parser" ]] || \
    fail "pinned installer signature parser is unavailable"
package_signature_path="$(/usr/bin/mktemp /private/tmp/opensteamer-v8-pkg-signature.XXXXXX)"
/usr/sbin/pkgutil --check-signature "$package" >"$package_signature_path" 2>&1 || \
    fail "production driver package signature is invalid"
actual_installer_leaf_sha256="$($installer_signature_parser "$package_signature_path" MSMG8CJLB3)" || \
    fail "unable to extract exact installer leaf certificate SHA-256"
/bin/rm -f -- "$package_signature_path"
[[ "$actual_installer_leaf_sha256" == "$expected_installer_leaf_sha256" ]] || \
    fail "production package leaf certificate SHA-256 is not pinned"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}" \
    /usr/bin/xcrun stapler validate -v "$package" >/dev/null || \
    fail "production driver package has no valid stapled notarization ticket"
/usr/sbin/spctl --assess --type install --verbose=4 "$package" >/dev/null 2>&1 || \
    fail "Gatekeeper did not accept the notarized production driver package"

payload_paths="$(/usr/sbin/pkgutil --payload-files "$package" | /usr/bin/sort)" || \
    fail "unable to inspect production package payload"
expected_payload="$(print -r -l -- "${expected_payload_paths[@]}" | /usr/bin/sort)"
[[ "$payload_paths" == "$expected_payload" ]] || \
    fail "production package payload path set is not exact"

expand_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-driver-package-expand.XXXXXX)"
case "$expand_root" in
    /private/tmp/opensteamer-driver-package-expand.*) ;;
    *) fail "unsafe package expansion path" ;;
esac
cleanup_expand() {
    [[ -d "$expand_root" ]] && [[ ! -L "$expand_root" ]] && /bin/rm -rf -- "$expand_root"
}
trap cleanup_expand EXIT INT TERM HUP
/usr/sbin/pkgutil --expand-full "$package" "$expand_root/package" || \
    fail "unable to expand production driver package"
if /usr/bin/find "$expand_root/package" -name Scripts -print -quit | /usr/bin/grep -q .; then
    fail "production driver package unexpectedly contains installer scripts"
fi
payload_driver="$(/usr/bin/find "$expand_root/package" -type d -name OpensteamerVirtualMicrophone.driver -print)"
[[ "$payload_driver" != *$'\n'* ]] && [[ -n "$payload_driver" ]] || \
    fail "expanded package does not contain exactly one product driver"
verify_driver "$payload_driver"
[[ "$(tree_sha256 "$payload_driver")" == "$expected_tree_sha256" ]] || \
    fail "expanded package driver differs from the reviewed production bundle"

print "bundle_tree_sha256=$actual_tree_sha256"
print "executable_sha256=$actual_executable_sha256"
print "package_sha256=$actual_package_sha256"
print "VERIFIED_DEVELOPER_ID_NOTARIZED_STAPLED_DRIVER_PACKAGE_V8"
