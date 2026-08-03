#!/bin/sh
# Compile and invoke the reviewed Rust post-v20 host updater without shelling individual cutover
# steps. The live execution mode is deliberately long and explicit; preflight/self-test are safe.
set -eu
umask 077

PREFLIGHT_MODE='--verify-post-v20-host-update-preflight'
EXECUTE_MODE='--execute-authorized-post-v20-host-update'
PREBUILT_EXECUTE_MODE='--execute-authorized-post-v20-host-update-with-reviewed-prebuilt'
ROLLBACK_MODE='--rollback-authorized-post-v20-host-update'
SELF_TEST_MODE='--self-test-post-v20-host-update'
EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer'
REVIEWED_PREBUILT_APP='/private/tmp/opensteamer-pairing-build.IhMOyT/output/opensteamer Host.app'
SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-post-v20-update-controller.rs"
RUSTC='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'
EXPECTED_SOURCE_SHA256='bac46ff616bf5b3f576a8b5650972f83029225d398169d5478e7133fa0c0e9e5'
EXPECTED_BINARY_SHA256='3922c22cab661e851caa856b3169446370186c3d525bc36e949e30c228b68d03'
BUILD_PARENT='/Users/ahmed/Library/Application Support/opensteamer'

usage() {
    echo "usage: $0 {$PREFLIGHT_MODE|$EXECUTE_MODE|$ROLLBACK_MODE} $EXPECTED_REPO" >&2
    echo "       $0 $PREBUILT_EXECUTE_MODE $EXPECTED_REPO '$REVIEWED_PREBUILT_APP'" >&2
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
    "$PREBUILT_EXECUTE_MODE")
        [ "$#" -eq 3 ] && [ "$2" = "$EXPECTED_REPO" ] \
            && [ "$3" = "$REVIEWED_PREBUILT_APP" ] || usage
        ;;
    *) usage ;;
esac

[ "$(/usr/bin/id -u)" = 501 ] || {
    echo 'post-v20 updater must run as Ahmed without sudo' >&2
    exit 1
}
[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] \
    && [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$SOURCE")" = '501:1:644' ] || {
    echo 'reviewed post-v20 controller source has unsafe metadata' >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_SOURCE_SHA256" ] || {
    echo 'post-v20 controller source differs from the reviewed bytes' >&2
    exit 1
}
[ -f "$RUSTC" ] && [ ! -L "$RUSTC" ] && [ -x "$RUSTC" ] \
    && [ "$(/usr/bin/shasum -a 256 "$RUSTC" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_SHA256" ] \
    && [ "$($RUSTC --version)" = "$EXPECTED_RUSTC_VERSION" ] || {
    echo 'reviewed Rust compiler is unavailable or changed' >&2
    exit 1
}
[ -f "$RUSTC_DRIVER" ] && [ ! -L "$RUSTC_DRIVER" ] \
    && [ "$(/usr/bin/shasum -a 256 "$RUSTC_DRIVER" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_DRIVER_SHA256" ] \
    && [ "$($RUSTC --print sysroot)" = "$RUSTC_SYSROOT" ] || {
    echo 'reviewed Rust compiler driver or sysroot changed' >&2
    exit 1
}
[ -d "$BUILD_PARENT" ] && [ ! -L "$BUILD_PARENT" ] \
    && [ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_PARENT")" = '501:700' ] || {
    echo 'private opensteamer application-support directory is unsafe' >&2
    exit 1
}

BUILD_DIR=$(/usr/bin/mktemp -d "$BUILD_PARENT/.post-v20-controller-build.XXXXXX") || exit 1
cleanup() {
    /bin/chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
    /bin/rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
/bin/chmod 700 "$BUILD_DIR"
[ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_DIR")" = '501:700' ] || exit 1

CONTROLLER="$BUILD_DIR/controller"
FIRST="$BUILD_DIR/controller.first"
compile_controller() {
    "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
        --sysroot "$RUSTC_SYSROOT" \
        --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-post-v20" \
        --remap-path-prefix "$BUILD_DIR=/reviewed/opensteamer-post-v20-build" \
        "$SOURCE" -o "$CONTROLLER"
    /bin/chmod 500 "$CONTROLLER"
}

compile_controller
/bin/mv "$CONTROLLER" "$FIRST"
compile_controller
/usr/bin/cmp -s "$FIRST" "$CONTROLLER" || {
    echo 'two reviewed-controller compilations were not byte-identical' >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$CONTROLLER" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_BINARY_SHA256" ] || {
    echo 'compiled post-v20 controller differs from the reviewed binary hash' >&2
    exit 1
}
/bin/chmod u+w "$FIRST"
/bin/rm -f "$FIRST"
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$CONTROLLER")" = '501:1:500' ] || exit 1

case "$MODE" in
    "$SELF_TEST_MODE") "$CONTROLLER" "$MODE" ;;
    "$PREBUILT_EXECUTE_MODE")
        "$CONTROLLER" "$MODE" "$EXPECTED_REPO" "$REVIEWED_PREBUILT_APP"
        ;;
    *) "$CONTROLLER" "$MODE" "$EXPECTED_REPO" ;;
esac
