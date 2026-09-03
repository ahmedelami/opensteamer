#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CRATE_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd -P)"
FRAMEWORKS_DIRECTORY="$(cd "${CRATE_DIRECTORY}/../../Frameworks" && pwd -P)"
OUTPUT_XCFRAMEWORK="${FRAMEWORKS_DIRECTORY}/OpensteamerAudioTransactionAuthority.xcframework"
SOURCE_MANIFEST="${CRATE_DIRECTORY}/SOURCE_MANIFEST.sha256"
THIRD_PARTY_NOTICE="${CRATE_DIRECTORY}/THIRD_PARTY_NOTICES.html"
RUSTUP_DIRECTORY="${RUSTUP_HOME:-/Volumes/t7/opensteamer-rustup-1.97.1}"
CARGO_DIRECTORY="${CARGO_HOME:-/Volumes/t7/opensteamer-cargo-1.97.1}"
CARGO_BINARY="${OSATA_CARGO_BIN:-${CARGO_DIRECTORY}/bin/cargo}"
RUSTC_BINARY="${OSATA_RUSTC_BIN:-${CARGO_DIRECTORY}/bin/rustc}"
TARGET_DIRECTORY="${CRATE_DIRECTORY}/target/xcframework"
STAGING_DIRECTORY=""
PREVIOUS_XCFRAMEWORK=""

cleanup() {
    if [[ -n "${STAGING_DIRECTORY}" && -d "${STAGING_DIRECTORY}" ]]; then
        case "${STAGING_DIRECTORY}" in
            "${TARGET_DIRECTORY}"/xcframework-stage.*)
                /bin/rm -R "${STAGING_DIRECTORY}"
                ;;
            *)
                echo "Refusing to clean unexpected staging path: ${STAGING_DIRECTORY}" >&2
                ;;
        esac
    fi
}
trap cleanup EXIT

for required in "${CARGO_BINARY}" "${RUSTC_BINARY}" /usr/bin/lipo /usr/bin/xcodebuild /usr/bin/shasum; do
    if [[ ! -x "${required}" ]]; then
        echo "Required build tool is unavailable: ${required}" >&2
        exit 1
    fi
done
if [[ ! -f "${SOURCE_MANIFEST}" || ! -f "${THIRD_PARTY_NOTICE}" ]]; then
    echo "Source manifest or Rust redistribution notice is missing" >&2
    exit 1
fi

export RUSTUP_HOME="${RUSTUP_DIRECTORY}"
export CARGO_HOME="${CARGO_DIRECTORY}"
export CARGO_TARGET_DIR="${TARGET_DIRECTORY}"

rustc_version="$("${RUSTC_BINARY}" --version --verbose)"
if ! /usr/bin/grep -x 'release: 1.97.1' <<< "${rustc_version}" > /dev/null; then
    echo "Pinned rustc 1.97.1 is unavailable" >&2
    exit 1
fi
RUST_SYSROOT="$("${RUSTC_BINARY}" --print sysroot)"
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    if [[ ! -d "${RUST_SYSROOT}/lib/rustlib/${target}/lib" ]]; then
        echo "Pinned Rust target is unavailable: ${target}" >&2
        exit 1
    fi
done

(
    cd "${CRATE_DIRECTORY}"
    /usr/bin/shasum -a 256 -c "${SOURCE_MANIFEST}"
)

for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    (
        cd "${CRATE_DIRECTORY}"
        "${CARGO_BINARY}" build --locked --release --target "${target}"
    )
done

/bin/mkdir -p "${TARGET_DIRECTORY}"
/usr/bin/lipo -create \
    -output "${TARGET_DIRECTORY}/libopensteamer_audio_transaction_authority-simulator.a" \
    "${TARGET_DIRECTORY}/aarch64-apple-ios-sim/release/libopensteamer_audio_transaction_authority.a" \
    "${TARGET_DIRECTORY}/x86_64-apple-ios/release/libopensteamer_audio_transaction_authority.a"

STAGING_DIRECTORY="$(/usr/bin/mktemp -d "${TARGET_DIRECTORY}/xcframework-stage.XXXXXX")"
DEVICE_HEADERS="${STAGING_DIRECTORY}/device-headers"
SIMULATOR_HEADERS="${STAGING_DIRECTORY}/simulator-headers"
/bin/mkdir -p "${DEVICE_HEADERS}" "${SIMULATOR_HEADERS}"
for headers in "${DEVICE_HEADERS}" "${SIMULATOR_HEADERS}"; do
    /bin/cp "${CRATE_DIRECTORY}/include/opensteamer_audio_transaction_authority.h" "${headers}/"
    /bin/cp "${CRATE_DIRECTORY}/include/module.modulemap" "${headers}/"
done

STAGED_XCFRAMEWORK="${STAGING_DIRECTORY}/OpensteamerAudioTransactionAuthority.xcframework"
/usr/bin/xcodebuild -create-xcframework \
    -library "${TARGET_DIRECTORY}/aarch64-apple-ios/release/libopensteamer_audio_transaction_authority.a" \
    -headers "${DEVICE_HEADERS}" \
    -library "${TARGET_DIRECTORY}/libopensteamer_audio_transaction_authority-simulator.a" \
    -headers "${SIMULATOR_HEADERS}" \
    -output "${STAGED_XCFRAMEWORK}"

/bin/cp "${SOURCE_MANIFEST}" "${STAGED_XCFRAMEWORK}/SOURCE_MANIFEST.sha256"
/bin/cp "${THIRD_PARTY_NOTICE}" "${STAGED_XCFRAMEWORK}/THIRD_PARTY_NOTICES.html"
{
    echo 'rust-toolchain=1.97.1'
    "${RUSTC_BINARY}" --version --verbose
    /usr/bin/xcodebuild -version
    echo "iphoneos-sdk=$(xcrun --sdk iphoneos --show-sdk-version)"
    echo "iphonesimulator-sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)"
} > "${STAGED_XCFRAMEWORK}/BUILD_METADATA.txt"
(
    cd "${STAGED_XCFRAMEWORK}"
    /usr/bin/find . -type f ! -name ARTIFACT_MANIFEST.sha256 -print \
        | LC_ALL=C /usr/bin/sort \
        | while IFS= read -r artifact; do
            /usr/bin/shasum -a 256 "${artifact}"
        done > ARTIFACT_MANIFEST.sha256
)

"${SCRIPT_DIRECTORY}/verify-xcframework.sh" "${STAGED_XCFRAMEWORK}"

PREVIOUS_XCFRAMEWORK="${FRAMEWORKS_DIRECTORY}/.OpensteamerAudioTransactionAuthority.previous.$$"
if [[ -e "${PREVIOUS_XCFRAMEWORK}" ]]; then
    echo "Refusing to overwrite unexpected backup: ${PREVIOUS_XCFRAMEWORK}" >&2
    exit 1
fi
if [[ -e "${OUTPUT_XCFRAMEWORK}" ]]; then
    /bin/mv "${OUTPUT_XCFRAMEWORK}" "${PREVIOUS_XCFRAMEWORK}"
fi
if ! /bin/mv "${STAGED_XCFRAMEWORK}" "${OUTPUT_XCFRAMEWORK}"; then
    if [[ -e "${PREVIOUS_XCFRAMEWORK}" ]]; then
        /bin/mv "${PREVIOUS_XCFRAMEWORK}" "${OUTPUT_XCFRAMEWORK}"
    fi
    exit 1
fi
if ! "${SCRIPT_DIRECTORY}/verify-xcframework.sh" "${OUTPUT_XCFRAMEWORK}"; then
    /bin/mv "${OUTPUT_XCFRAMEWORK}" "${STAGED_XCFRAMEWORK}"
    if [[ -e "${PREVIOUS_XCFRAMEWORK}" ]]; then
        /bin/mv "${PREVIOUS_XCFRAMEWORK}" "${OUTPUT_XCFRAMEWORK}"
    fi
    exit 1
fi
if [[ -d "${PREVIOUS_XCFRAMEWORK}" ]]; then
    case "${PREVIOUS_XCFRAMEWORK}" in
        "${FRAMEWORKS_DIRECTORY}"/.OpensteamerAudioTransactionAuthority.previous.*)
            /bin/rm -R "${PREVIOUS_XCFRAMEWORK}"
            ;;
        *)
            echo "Refusing to clean unexpected backup path: ${PREVIOUS_XCFRAMEWORK}" >&2
            exit 1
            ;;
    esac
fi

echo "Built and verified ${OUTPUT_XCFRAMEWORK}"
