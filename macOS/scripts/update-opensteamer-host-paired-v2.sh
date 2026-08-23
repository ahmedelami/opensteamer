#!/bin/sh
# Compile and invoke the reviewed Rust pairing-preserving v2 host updater. The launcher performs
# no cutover work itself and accepts only the explicit controller modes below.
set -eu
umask 077

PREFLIGHT_MODE='--verify-paired-v2-host-update-preflight'
EXECUTE_MODE='--execute-authorized-paired-v2-host-update'
ROLLBACK_MODE='--rollback-authorized-paired-v2-host-update'
SELF_TEST_MODE='--self-test-paired-v2-host-update'
EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer'
SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-paired-v2-update-controller.rs"
V1_SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-post-v20-update-controller.rs"
RUSTC='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'
EXPECTED_SOURCE_SHA256='5e26447094f85269850f218d0084337116c91e3eddf2cda1e22ec934f55f9104'
EXPECTED_V1_CONTROLLER_SOURCE_SHA256='2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06'
EXPECTED_INCLUDED_SOURCE_SHA256='2020edb76b1f9537afad1ed2ec22686044f2f0cbbb3d95155546b69e0b1442e6'
EXPECTED_BINARY_SHA256='b8e6ca1fcd5ab107c4eb776ad28ed380ea116d3fb6b0b91cccd8a6e015f78589'
BUILD_PARENT='/Users/ahmed/Library/Application Support/opensteamer'

usage() {
    echo "usage: $0 {$PREFLIGHT_MODE|$EXECUTE_MODE|$ROLLBACK_MODE} $EXPECTED_REPO" >&2
    echo "       $0 $SELF_TEST_MODE" >&2
    exit 64
}

[ "$#" -ge 1 ] || usage
MODE=$1
case "$MODE" in
    "$SELF_TEST_MODE") [ "$#" -eq 1 ] || usage ;;
    "$PREFLIGHT_MODE"|"$EXECUTE_MODE"|"$ROLLBACK_MODE")
        [ "$#" -eq 2 ] && [ "$2" = "$EXPECTED_REPO" ] || usage
        ;;
    *) usage ;;
esac

[ "$(/usr/bin/id -u)" = 501 ] || {
    echo 'paired-v2 updater must run as Ahmed without sudo' >&2
    exit 1
}
for reviewed_source in "$SOURCE" "$V1_SOURCE"; do
    [ -f "$reviewed_source" ] && [ ! -L "$reviewed_source" ] \
        && [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$reviewed_source")" = '501:1:644' ] || {
        echo "reviewed paired-v2 source has unsafe metadata: $reviewed_source" >&2
        exit 1
    }
done
[ "$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_SOURCE_SHA256" ] || {
    echo 'paired-v2 controller source differs from the reviewed bytes' >&2
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

BUILD_DIR=$(/usr/bin/mktemp -d "$BUILD_PARENT/.paired-v2-controller-build.XXXXXX") || exit 1
cleanup() {
    /bin/chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
    /bin/rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
/bin/chmod 700 "$BUILD_DIR"
[ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_DIR")" = '501:700' ] || exit 1

CONTROLLER="$BUILD_DIR/controller"
FIRST="$BUILD_DIR/controller.first"
INCLUDED_SOURCE="$BUILD_DIR/opensteamer-host-post-v20-update-controller.module.rs"
/usr/bin/sed '1,7s#^//!#//#' "$V1_SOURCE" >"$INCLUDED_SOURCE"
/bin/chmod 400 "$INCLUDED_SOURCE"
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$INCLUDED_SOURCE")" = '501:1:400' ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$INCLUDED_SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_INCLUDED_SOURCE_SHA256" ] || {
    echo 'private transformed v1 module source differs from the reviewed hash' >&2
    exit 1
}
compile_controller() {
    OPENSTEAMER_PAIRED_V2_INCLUDED_SOURCE="$INCLUDED_SOURCE" \
    "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
        --sysroot "$RUSTC_SYSROOT" \
        --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-paired-v2" \
        --remap-path-prefix "$BUILD_DIR=/reviewed/opensteamer-paired-v2-build" \
        "$SOURCE" -o "$CONTROLLER"
    /bin/chmod 500 "$CONTROLLER"
}

compile_controller
/bin/mv "$CONTROLLER" "$FIRST"
compile_controller
/usr/bin/cmp -s "$FIRST" "$CONTROLLER" || {
    echo 'two reviewed paired-v2 controller compilations were not byte-identical' >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$CONTROLLER" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_BINARY_SHA256" ] || {
    echo 'compiled paired-v2 controller differs from the reviewed binary hash' >&2
    exit 1
}
/bin/chmod u+w "$FIRST"
/bin/rm -f "$FIRST"
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$CONTROLLER")" = '501:1:500' ] || exit 1

case "$MODE" in
    "$SELF_TEST_MODE") "$CONTROLLER" "$MODE" ;;
    *) "$CONTROLLER" "$MODE" "$EXPECTED_REPO" ;;
esac
