#!/bin/sh
# Compile and invoke the reviewed host-only paired-v8 updater. This launcher has no privileged
# route and performs no cutover work itself. Release pins remain invalid until final review.
set -eu
umask 077

PREFLIGHT_MODE='--verify-paired-v8-host-update-preflight'
EXECUTE_MODE='--execute-authorized-paired-v8-host-update'
ROLLBACK_MODE='--rollback-authorized-paired-v8-host-update'
SELF_TEST_MODE='--self-test-paired-v8-host-update'
EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer'
SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
V1_SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-post-v20-update-controller.rs"
RUSTC='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'
RELEASE_PIN_STATUS='PINNED_FINAL_REVIEW'
EXPECTED_SOURCE_SHA256='9ca05ff323a7412256df2395418a82ff61d09dd83869747b92c233489926a46b'
EXPECTED_V1_CONTROLLER_SOURCE_SHA256='2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06'
EXPECTED_INCLUDED_SOURCE_SHA256='2020edb76b1f9537afad1ed2ec22686044f2f0cbbb3d95155546b69e0b1442e6'
# B is pinned only here, outside the Rust source whose bytes it identifies. Embedding B in that
# source would require an impossible SHA-256 fixed point.
EXPECTED_BINARY_SHA256='a233400d68f58adcf3a0aa11037634cc6e8c970b07e5e1e59248b771793a576a'
BUILD_PARENT='/Users/ahmed/Library/Application Support/opensteamer'

usage() {
    echo "usage: $0 $PREFLIGHT_MODE $EXPECTED_REPO" >&2
    echo "       $0 $EXECUTE_MODE $EXPECTED_REPO <authorized-release-commit> <authorized-release-tree>" >&2
    echo "       $0 $ROLLBACK_MODE $EXPECTED_REPO" >&2
    echo "       $0 $SELF_TEST_MODE" >&2
    exit 64
}

[ "$#" -ge 1 ] || usage
MODE=$1
case "$MODE" in
    "$SELF_TEST_MODE") [ "$#" -eq 1 ] || usage ;;
    "$PREFLIGHT_MODE"|"$ROLLBACK_MODE")
        [ "$#" -eq 2 ] && [ "$2" = "$EXPECTED_REPO" ] || usage
        ;;
    "$EXECUTE_MODE")
        [ "$#" -eq 4 ] && [ "$2" = "$EXPECTED_REPO" ] || usage
        ;;
    *) usage ;;
esac

[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ] || {
    echo 'paired-v8 updater is intentionally unrunnable until final source/artifact pins are reviewed' >&2
    exit 78
}
case "$EXPECTED_SOURCE_SHA256:$EXPECTED_BINARY_SHA256" in
    *PIN_AFTER_FINAL_REVIEW*)
        echo 'paired-v8 updater still contains release-pin placeholders' >&2
        exit 78
        ;;
esac
for reviewed_pin in "$EXPECTED_SOURCE_SHA256" "$EXPECTED_BINARY_SHA256"; do
    case "$reviewed_pin" in
        ''|*[!0-9a-f]*)
            echo 'paired-v8 source/binary pin is not lowercase hexadecimal' >&2
            exit 78
            ;;
    esac
    [ "${#reviewed_pin}" -eq 64 ] || {
        echo 'paired-v8 source/binary pin is not exactly 64 characters' >&2
        exit 78
    }
done

[ "$(/usr/bin/id -u)" = 501 ] || {
    echo 'paired-v8 updater must run as UID 501' >&2
    exit 1
}
for reviewed_source in "$SOURCE" "$V1_SOURCE"; do
    [ -f "$reviewed_source" ] && [ ! -L "$reviewed_source" ] \
        && [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$reviewed_source")" = '501:1:644' ] || {
        echo "reviewed paired-v8 source has unsafe metadata: $reviewed_source" >&2
        exit 1
    }
done
[ "$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_SOURCE_SHA256" ] || {
    echo 'paired-v8 controller source differs from the reviewed bytes' >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$V1_SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_V1_CONTROLLER_SOURCE_SHA256" ] || {
    echo 'included immutable v1 controller source differs from the reviewed bytes' >&2
    exit 1
}
[ -f "$RUSTC" ] && [ ! -L "$RUSTC" ] && [ -x "$RUSTC" ] \
    && [ "$(/usr/bin/shasum -a 256 "$RUSTC" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_SHA256" ] \
    && [ "$("$RUSTC" --version)" = "$EXPECTED_RUSTC_VERSION" ] || {
    echo 'reviewed Rust compiler is unavailable or changed' >&2
    exit 1
}
[ -f "$RUSTC_DRIVER" ] && [ ! -L "$RUSTC_DRIVER" ] \
    && [ "$(/usr/bin/shasum -a 256 "$RUSTC_DRIVER" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_DRIVER_SHA256" ] \
    && [ "$("$RUSTC" --print sysroot)" = "$RUSTC_SYSROOT" ] || {
    echo 'reviewed Rust compiler driver or sysroot changed' >&2
    exit 1
}
[ -d "$BUILD_PARENT" ] && [ ! -L "$BUILD_PARENT" ] \
    && [ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_PARENT")" = '501:700' ] || {
    echo 'private opensteamer application-support directory is unsafe' >&2
    exit 1
}

BUILD_ROOT_A=$(/usr/bin/mktemp -d "$BUILD_PARENT/.paired-v8-controller-build-a.XXXXXX") || exit 1
BUILD_ROOT_B=$(/usr/bin/mktemp -d "$BUILD_PARENT/.paired-v8-controller-build-b.XXXXXX") || {
    /bin/rmdir "$BUILD_ROOT_A" 2>/dev/null || true
    exit 1
}
cleanup() {
    /bin/chmod -R u+w "$BUILD_ROOT_A" "$BUILD_ROOT_B" 2>/dev/null || true
    /bin/rm -rf "$BUILD_ROOT_A" "$BUILD_ROOT_B" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
for build_root in "$BUILD_ROOT_A" "$BUILD_ROOT_B"; do
    /bin/chmod 700 "$build_root"
    [ "$(/usr/bin/stat -f '%u:%Lp' "$build_root")" = '501:700' ] || exit 1
done

prepare_included_source() {
    build_root=$1
    included_source="$build_root/opensteamer-host-post-v20-update-controller.module.rs"
    /usr/bin/sed '1,7s#^//!#//#' "$V1_SOURCE" >"$included_source"
    /bin/chmod 400 "$included_source"
    [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$included_source")" = '501:1:400' ] || exit 1
    [ "$(/usr/bin/shasum -a 256 "$included_source" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_INCLUDED_SOURCE_SHA256" ] || {
        echo 'private transformed v1 module source differs from the reviewed hash' >&2
        exit 1
    }
}

compile_controller() {
    build_root=$1
    included_source="$build_root/opensteamer-host-post-v20-update-controller.module.rs"
    controller="$build_root/controller"
    OPENSTEAMER_PAIRED_V8_INCLUDED_SOURCE="$included_source" \
    "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
        --sysroot "$RUSTC_SYSROOT" \
        --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-paired-v8" \
        --remap-path-prefix "$build_root=/reviewed/opensteamer-paired-v8-build" \
        "$SOURCE" -o "$controller"
    /bin/chmod 500 "$controller"
    [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$controller")" = '501:1:500' ] || exit 1
}

prepare_included_source "$BUILD_ROOT_A"
prepare_included_source "$BUILD_ROOT_B"
compile_controller "$BUILD_ROOT_A"
compile_controller "$BUILD_ROOT_B"
CONTROLLER_A="$BUILD_ROOT_A/controller"
CONTROLLER_B="$BUILD_ROOT_B/controller"
/usr/bin/cmp -s "$CONTROLLER_A" "$CONTROLLER_B" || {
    echo 'two reviewed paired-v8 controller compilations were not byte-identical' >&2
    exit 1
}
CONTROLLER_BINARY_SHA256=$(/usr/bin/shasum -a 256 "$CONTROLLER_B" | /usr/bin/awk '{print $1}')
[ "$CONTROLLER_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ] || {
    echo 'compiled paired-v8 controller differs from the reviewed binary hash' >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$CONTROLLER_B" | /usr/bin/awk '{print $1}')" = \
  "$CONTROLLER_BINARY_SHA256" ] || {
    echo 'compiled paired-v8 controller changed after its deterministic binary pin' >&2
    exit 1
}

case "$MODE" in
    "$SELF_TEST_MODE") "$CONTROLLER_B" "$MODE" ;;
    *) "$CONTROLLER_B" "$@" ;;
esac
