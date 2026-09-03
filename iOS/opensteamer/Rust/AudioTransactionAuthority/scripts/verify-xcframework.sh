#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CRATE_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd -P)"
DEFAULT_XCFRAMEWORK="$(cd "${CRATE_DIRECTORY}/../../Frameworks" && pwd -P)/OpensteamerAudioTransactionAuthority.xcframework"
XCFRAMEWORK="${1:-${DEFAULT_XCFRAMEWORK}}"
DEVICE_SLICE="${XCFRAMEWORK}/ios-arm64"
SIMULATOR_SLICE="${XCFRAMEWORK}/ios-arm64_x86_64-simulator"
DEVICE_LIBRARY="${DEVICE_SLICE}/libopensteamer_audio_transaction_authority.a"
SIMULATOR_LIBRARY="${SIMULATOR_SLICE}/libopensteamer_audio_transaction_authority-simulator.a"
VERIFY_DIRECTORY="${CRATE_DIRECTORY}/target/xcframework-verification"

fail() {
    echo "XCFramework verification failed: $*" >&2
    exit 1
}

[[ -d "${XCFRAMEWORK}" ]] || fail "missing bundle ${XCFRAMEWORK}"
[[ -f "${XCFRAMEWORK}/Info.plist" ]] || fail "missing Info.plist"
[[ -f "${XCFRAMEWORK}/ARTIFACT_MANIFEST.sha256" ]] || fail "missing artifact manifest"
[[ -f "${XCFRAMEWORK}/SOURCE_MANIFEST.sha256" ]] || fail "missing source manifest"
[[ -f "${XCFRAMEWORK}/THIRD_PARTY_NOTICES.html" ]] || fail "missing Rust notice"
if [[ -n "$(/usr/bin/find "${XCFRAMEWORK}" -type l -print -quit)" ]]; then
    fail "symlinks are not permitted in the checked artifact"
fi

(
    cd "${XCFRAMEWORK}"
    /usr/bin/shasum -a 256 -c ARTIFACT_MANIFEST.sha256
)
/usr/bin/cmp -s "${CRATE_DIRECTORY}/SOURCE_MANIFEST.sha256" "${XCFRAMEWORK}/SOURCE_MANIFEST.sha256" \
    || fail "source manifest copy differs"
/usr/bin/cmp -s "${CRATE_DIRECTORY}/THIRD_PARTY_NOTICES.html" "${XCFRAMEWORK}/THIRD_PARTY_NOTICES.html" \
    || fail "Rust redistribution notice differs"

[[ "$(/usr/bin/plutil -extract AvailableLibraries raw -o - "${XCFRAMEWORK}/Info.plist")" == 2 ]] \
    || fail "expected exactly two slices"
identifiers="$(
    for index in 0 1; do
        /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${index}:LibraryIdentifier" "${XCFRAMEWORK}/Info.plist"
    done | LC_ALL=C /usr/bin/sort
)"
[[ "${identifiers}" == $'ios-arm64\nios-arm64_x86_64-simulator' ]] \
    || fail "unexpected slice identifiers"
[[ "$(/usr/bin/lipo -archs "${DEVICE_LIBRARY}")" == 'arm64' ]] \
    || fail "device slice must contain only arm64"
simulator_architectures="$(/usr/bin/lipo -archs "${SIMULATOR_LIBRARY}" | /usr/bin/tr ' ' '\n' | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "${simulator_architectures}" == 'arm64 x86_64 ' ]] \
    || fail "simulator slice must contain arm64 and x86_64"

for slice in "${DEVICE_SLICE}" "${SIMULATOR_SLICE}"; do
    /usr/bin/cmp -s \
        "${CRATE_DIRECTORY}/include/opensteamer_audio_transaction_authority.h" \
        "${slice}/Headers/opensteamer_audio_transaction_authority.h" \
        || fail "published header differs in ${slice}"
    /usr/bin/cmp -s \
        "${CRATE_DIRECTORY}/include/module.modulemap" \
        "${slice}/Headers/module.modulemap" \
        || fail "module map differs in ${slice}"
done

/usr/bin/clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
    -I "${DEVICE_SLICE}/Headers" \
    "${CRATE_DIRECTORY}/tests/c_abi_smoke.c"
/usr/bin/swiftc -typecheck \
    -I "${DEVICE_SLICE}/Headers" \
    "${CRATE_DIRECTORY}/tests/swift_import_smoke.swift"

/bin/mkdir -p "${VERIFY_DIRECTORY}"
compile_and_link() {
    local sdk="$1"
    local target="$2"
    local library="$3"
    local name="$4"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    xcrun --sdk "${sdk}" clang \
        -target "${target}" \
        -isysroot "${sdk_path}" \
        -I "${DEVICE_SLICE}/Headers" \
        -c "${CRATE_DIRECTORY}/tests/c_abi_smoke.c" \
        -o "${VERIFY_DIRECTORY}/${name}.o"
    xcrun --sdk "${sdk}" clang \
        -target "${target}" \
        -isysroot "${sdk_path}" \
        -Wl,-r \
        -o "${VERIFY_DIRECTORY}/${name}-linked.o" \
        "${VERIFY_DIRECTORY}/${name}.o" \
        "${library}"
}

compile_and_link iphoneos arm64-apple-ios17.0 "${DEVICE_LIBRARY}" device-arm64
compile_and_link iphonesimulator arm64-apple-ios17.0-simulator "${SIMULATOR_LIBRARY}" simulator-arm64
compile_and_link iphonesimulator x86_64-apple-ios17.0-simulator "${SIMULATOR_LIBRARY}" simulator-x86_64

echo "Verified ${XCFRAMEWORK}"
