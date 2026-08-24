#!/bin/sh
# Deterministically build the UID501-only resume stager plus the exact original
# V2 root controller. The stager may publish only the already sealed request's
# root-owned controller artifacts; it is never itself executed with sudo.
set -eu
umask 077
export LC_ALL=C

PREFLIGHT_MODE='--verify-diagnostic-driver-v2-resume-preflight'
EXECUTE_MODE='--execute-authorized-diagnostic-driver-v2-resume'
SELF_TEST_MODE='--self-test-diagnostic-driver-v2-resume'
EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer'
STAGER_SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-diagnostic-driver-v2-resume-stager.rs"
ORIGINAL_SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-diagnostic-driver-v2-update-controller.rs"
ORIGINAL_SOURCE_SHA256='4df37ebcb2634ea1fed78165cc530ea8cb739fe1e9b59744010e2b64b922c98b'
ORIGINAL_BINARY_SHA256='da55bc73f7143ffe6f09516c84c70532c18d37af53da0e12c00fb79924926201'
RUSTC='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'
RELEASE_PIN_STATUS='PINNED_FINAL_REVIEW'
EXPECTED_STAGER_SOURCE_SHA256='dd13167a6aec87f48af5eaacd0317c37df01ffadfb838ddcbfb6962b47904c4d'
EXPECTED_STAGER_BINARY_SHA256='feb269285215bbc85f5c324a732b059f5cb7cfec602c5bece53744ad5e17298f'
BUILD_PARENT='/Users/ahmed/Library/Caches/opensteamer-diagnostic-driver-v2-resume-builds'
BUILD_ANCESTOR='/Users/ahmed/Library/Caches'
SEALED_STAGER_PARENT='/Library/Application Support/opensteamer/diagnostic-driver-resume-stagers-v2'
SEALED_STAGER_PREFIX='resume-stager-'
ROOT_SUPPORT='/Library/Application Support/opensteamer'

usage() {
    echo "usage: $0 $PREFLIGHT_MODE $EXPECTED_REPO" >&2
    echo "       $0 $EXECUTE_MODE $EXPECTED_REPO <authorized-resume-release-commit> <authorized-resume-release-tree>" >&2
    echo "       $0 $SELF_TEST_MODE" >&2
    exit 64
}

[ "$#" -ge 1 ] || usage
MODE=$1
case "$MODE" in
    "$SELF_TEST_MODE") [ "$#" -eq 1 ] || usage ;;
    "$PREFLIGHT_MODE") [ "$#" -eq 2 ] && [ "$2" = "$EXPECTED_REPO" ] || usage ;;
    "$EXECUTE_MODE") [ "$#" -eq 4 ] && [ "$2" = "$EXPECTED_REPO" ] || usage ;;
    *) usage ;;
esac

[ "$(/usr/bin/id -u)" = 501 ] || {
    echo 'diagnostic-driver resume stager must run as UID 501' >&2
    exit 1
}
[ -f "$STAGER_SOURCE" ] && [ ! -L "$STAGER_SOURCE" ] \
    && [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$STAGER_SOURCE")" = '501:1:644' ] || {
    echo 'resume-stager source has unsafe metadata' >&2
    exit 1
}
[ -f "$ORIGINAL_SOURCE" ] && [ ! -L "$ORIGINAL_SOURCE" ] \
    && [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$ORIGINAL_SOURCE")" = '501:1:644' ] \
    && [ "$(/usr/bin/shasum -a 256 "$ORIGINAL_SOURCE" | /usr/bin/awk '{print $1}')" = \
      "$ORIGINAL_SOURCE_SHA256" ] || {
    echo 'original reviewed V2 controller source is unavailable or changed' >&2
    exit 1
}

[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ] || {
    echo 'diagnostic-driver resume is intentionally unrunnable until final review' >&2
    exit 78
}
for reviewed_pin in "$EXPECTED_STAGER_SOURCE_SHA256" "$EXPECTED_STAGER_BINARY_SHA256"; do
    case "$reviewed_pin" in ''|*[!0-9a-f]*) exit 78 ;; esac
    [ "${#reviewed_pin}" -eq 64 ] || exit 78
done
[ "$(/usr/bin/shasum -a 256 "$STAGER_SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_STAGER_SOURCE_SHA256" ] || {
    echo 'resume-stager source differs from reviewed bytes' >&2
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
[ -d "$BUILD_ANCESTOR" ] && [ ! -L "$BUILD_ANCESTOR" ] \
    && [ "$(/usr/bin/stat -f '%u:%g:%Lp:%f:%HT' "$BUILD_ANCESTOR")" = \
      '501:20:700:0:Directory' ] || exit 1
if [ ! -d "$BUILD_PARENT" ]; then
    /bin/mkdir -m 700 "$BUILD_PARENT"
fi
[ -d "$BUILD_PARENT" ] && [ ! -L "$BUILD_PARENT" ] \
    && [ "$(/usr/bin/stat -f '%u:%g:%Lp:%f:%HT' "$BUILD_PARENT")" = \
      '501:20:700:0:Directory' ] || exit 1

BUILD_ROOT_A=$(/usr/bin/mktemp -d "$BUILD_PARENT/.resume-a.XXXXXX") || exit 1
BUILD_ROOT_B=$(/usr/bin/mktemp -d "$BUILD_PARENT/.resume-b.XXXXXX") || exit 1
cleanup() {
    case "$BUILD_ROOT_A:$BUILD_ROOT_B" in
        "$BUILD_PARENT"/.resume-a.*:"$BUILD_PARENT"/.resume-b.*)
            /bin/chmod -R u+w "$BUILD_ROOT_A" "$BUILD_ROOT_B" 2>/dev/null || true
            /bin/rm -rf "$BUILD_ROOT_A" "$BUILD_ROOT_B" 2>/dev/null || true
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

compile_stager() {
    build_root=$1
    "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
        --sysroot "$RUSTC_SYSROOT" \
        --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-diagnostic-driver-v2-resume" \
        --remap-path-prefix "$build_root=/reviewed/opensteamer-diagnostic-driver-v2-resume-build" \
        "$STAGER_SOURCE" -o "$build_root/resume-stager"
    /bin/chmod 500 "$build_root/resume-stager"
}

compile_original() {
    build_root=$1
    "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
        --sysroot "$RUSTC_SYSROOT" \
        --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-diagnostic-driver-v2" \
        --remap-path-prefix "$build_root=/reviewed/opensteamer-diagnostic-driver-v2-build" \
        "$ORIGINAL_SOURCE" -o "$build_root/controller"
    /bin/chmod 500 "$build_root/controller"
    /bin/mv "$build_root/controller" "$build_root/original-controller"
}

sudo_constant() {
    /usr/bin/sudo -n -- "$@" || {
        echo 'fresh sudo authorization is required for sealed resume-stager publication' >&2
        exit 1
    }
}

require_root_node_without_acl_or_xattrs() {
    root_node=$1
    ROOT_NODE_ACL=$(sudo_constant /bin/ls -led "$root_node")
    [ "$(/usr/bin/printf '%s\n' "$ROOT_NODE_ACL" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] || {
        echo 'sealed resume-stager node has an ACL' >&2
        exit 1
    }
    case "${ROOT_NODE_ACL%% *}" in *+*)
        echo 'sealed resume-stager node has an ACL marker' >&2
        exit 1
        ;;
    esac
    ROOT_NODE_XATTRS=$(sudo_constant /usr/bin/xattr "$root_node")
    [ -z "$ROOT_NODE_XATTRS" ] || {
        echo 'sealed resume-stager node has extended attributes' >&2
        exit 1
    }
}

publish_sealed_stager() {
    SEALED_STAGER_PATH="$SEALED_STAGER_PARENT/$SEALED_STAGER_PREFIX$STAGER_BINARY_SHA256"
    [ "$SEALED_STAGER_PATH" = \
      "/Library/Application Support/opensteamer/diagnostic-driver-resume-stagers-v2/resume-stager-$EXPECTED_STAGER_BINARY_SHA256" ] || exit 1

    [ ! -L "$ROOT_SUPPORT" ] \
        && [ "$(sudo_constant /usr/bin/stat -f '%u:%g:%Lp:%f:%HT' "$ROOT_SUPPORT")" = \
          '0:0:755:0:Directory' ] || {
        echo 'root support identity is unsafe for sealed resume-stager publication' >&2
        exit 1
    }
    require_root_node_without_acl_or_xattrs "$ROOT_SUPPORT"

    if [ ! -e "$SEALED_STAGER_PARENT" ] && [ ! -L "$SEALED_STAGER_PARENT" ]; then
        sudo_constant /usr/bin/install -d -o root -g wheel -m 0755 "$SEALED_STAGER_PARENT"
        /bin/sync
    fi
    [ ! -L "$SEALED_STAGER_PARENT" ] \
        && [ "$(sudo_constant /usr/bin/stat -f '%u:%g:%Lp:%f:%HT' "$SEALED_STAGER_PARENT")" = \
      '0:0:755:0:Directory' ] || {
        echo 'sealed resume-stager parent identity is unsafe' >&2
        exit 1
    }
    require_root_node_without_acl_or_xattrs "$SEALED_STAGER_PARENT"

    SEALED_CHILDREN=$(sudo_constant /bin/ls -1A "$SEALED_STAGER_PARENT")
    case "$SEALED_CHILDREN" in
        ''|"$SEALED_STAGER_PREFIX$STAGER_BINARY_SHA256") ;;
        *) echo 'sealed resume-stager parent has unexpected children' >&2; exit 1 ;;
    esac

    SEALED_METADATA=''
    if [ -e "$SEALED_STAGER_PATH" ] || [ -L "$SEALED_STAGER_PATH" ]; then
        [ ! -L "$SEALED_STAGER_PATH" ] || {
            echo 'sealed resume-stager path is a symlink' >&2
            exit 1
        }
        SEALED_METADATA=$(sudo_constant /usr/bin/stat -f '%u:%g:%Lp:%l:%z:%f:%HT' "$SEALED_STAGER_PATH")
        case "$SEALED_METADATA" in
            "0:0:400:1:"*':0:Regular File'|"0:0:555:1:"*':0:Regular File') ;;
            *) echo 'sealed resume-stager file identity is unsafe' >&2; exit 1 ;;
        esac
        require_root_node_without_acl_or_xattrs "$SEALED_STAGER_PATH"
    fi

    case "$SEALED_METADATA" in
        "0:0:555:1:$STAGER_BINARY_SIZE:0:Regular File") ;;
        ''|"0:0:400:1:"*':0:Regular File')
            sudo_constant /usr/bin/install -o root -g wheel -m 0400 \
                "$BUILD_ROOT_B/resume-stager" "$SEALED_STAGER_PATH"
            /bin/sync
            [ "$(sudo_constant /usr/bin/stat -f '%u:%g:%Lp:%l:%z:%f:%HT' "$SEALED_STAGER_PATH")" = \
              "0:0:400:1:$STAGER_BINARY_SIZE:0:Regular File" ] || exit 1
            require_root_node_without_acl_or_xattrs "$SEALED_STAGER_PATH"
            [ "$(sudo_constant /usr/bin/shasum -a 256 "$SEALED_STAGER_PATH" | /usr/bin/awk '{print $1}')" = \
              "$EXPECTED_STAGER_BINARY_SHA256" ] || {
                echo 'root-owned resume-stager copy differs from reviewed bytes' >&2
                exit 1
            }
            sudo_constant /bin/chmod 0555 "$SEALED_STAGER_PATH"
            /bin/sync
            ;;
        *) echo 'sealed resume-stager is not an exact recoverable publication prefix' >&2; exit 1 ;;
    esac

    [ "$(sudo_constant /usr/bin/stat -f '%u:%g:%Lp:%l:%z:%f:%HT' "$SEALED_STAGER_PATH")" = \
      "0:0:555:1:$STAGER_BINARY_SIZE:0:Regular File" ] || exit 1
    require_root_node_without_acl_or_xattrs "$SEALED_STAGER_PATH"
    [ "$(sudo_constant /usr/bin/shasum -a 256 "$SEALED_STAGER_PATH" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_STAGER_BINARY_SHA256" ] || exit 1
    [ "$(sudo_constant /bin/ls -1A "$SEALED_STAGER_PARENT")" = \
      "$SEALED_STAGER_PREFIX$STAGER_BINARY_SHA256" ] || exit 1
}

STAGER_SOURCE_BEFORE_SHA256=$(/usr/bin/shasum -a 256 "$STAGER_SOURCE" | /usr/bin/awk '{print $1}')
[ "$STAGER_SOURCE_BEFORE_SHA256" = "$EXPECTED_STAGER_SOURCE_SHA256" ] || {
    echo 'reviewed resume-stager source changed before rebuild' >&2
    exit 1
}
compile_stager "$BUILD_ROOT_A"
compile_stager "$BUILD_ROOT_B"
ORIGINAL_SOURCE_BEFORE_SHA256=$(/usr/bin/shasum -a 256 "$ORIGINAL_SOURCE" | /usr/bin/awk '{print $1}')
[ "$ORIGINAL_SOURCE_BEFORE_SHA256" = "$ORIGINAL_SOURCE_SHA256" ] || {
    echo 'original reviewed V2 controller source changed before rebuild' >&2
    exit 1
}
compile_original "$BUILD_ROOT_A"
compile_original "$BUILD_ROOT_B"
/usr/bin/cmp -s "$BUILD_ROOT_A/resume-stager" "$BUILD_ROOT_B/resume-stager" || exit 1
/usr/bin/cmp -s "$BUILD_ROOT_A/original-controller" "$BUILD_ROOT_B/original-controller" || exit 1
STAGER_SOURCE_AFTER_SHA256=$(/usr/bin/shasum -a 256 "$STAGER_SOURCE" | /usr/bin/awk '{print $1}')
[ "$STAGER_SOURCE_AFTER_SHA256" = "$STAGER_SOURCE_BEFORE_SHA256" ] \
    && [ "$STAGER_SOURCE_AFTER_SHA256" = "$EXPECTED_STAGER_SOURCE_SHA256" ] || {
    echo 'reviewed resume-stager source changed during rebuild' >&2
    exit 1
}
STAGER_BINARY_SHA256=$(/usr/bin/shasum -a 256 "$BUILD_ROOT_B/resume-stager" | /usr/bin/awk '{print $1}')
STAGER_BINARY_SIZE=$(/usr/bin/stat -f '%z' "$BUILD_ROOT_B/resume-stager")
ORIGINAL_BINARY_ACTUAL=$(/usr/bin/shasum -a 256 "$BUILD_ROOT_B/original-controller" | /usr/bin/awk '{print $1}')
ORIGINAL_SOURCE_AFTER_SHA256=$(/usr/bin/shasum -a 256 "$ORIGINAL_SOURCE" | /usr/bin/awk '{print $1}')
[ "$ORIGINAL_SOURCE_AFTER_SHA256" = "$ORIGINAL_SOURCE_BEFORE_SHA256" ] \
    && [ "$ORIGINAL_SOURCE_AFTER_SHA256" = "$ORIGINAL_SOURCE_SHA256" ] || {
    echo 'original reviewed V2 controller source changed during rebuild' >&2
    exit 1
}
[ "$ORIGINAL_BINARY_ACTUAL" = "$ORIGINAL_BINARY_SHA256" ] || {
    echo 'rebuilt original V2 root controller differs from its reviewed binary' >&2
    exit 1
}
[ "$STAGER_BINARY_SHA256" = "$EXPECTED_STAGER_BINARY_SHA256" ] || exit 1
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$BUILD_ROOT_B/resume-stager")" = '501:1:500' ] || exit 1
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$BUILD_ROOT_B/original-controller")" = '501:1:500' ] || exit 1

case "$MODE" in
    "$SELF_TEST_MODE")
        /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            "$BUILD_ROOT_B/resume-stager" "$SELF_TEST_MODE"
        ;;
    "$PREFLIGHT_MODE")
        publish_sealed_stager
        /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            OPENSTEAMER_RESUME_STAGER_SEALED_PATH="$SEALED_STAGER_PATH" \
            "$SEALED_STAGER_PATH" "$PREFLIGHT_MODE" "$2" "$BUILD_ROOT_B/original-controller"
        ;;
    "$EXECUTE_MODE")
        publish_sealed_stager
        /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            OPENSTEAMER_RESUME_STAGER_SEALED_PATH="$SEALED_STAGER_PATH" \
            "$SEALED_STAGER_PATH" "$EXECUTE_MODE" "$2" "$3" "$4" "$BUILD_ROOT_B/original-controller"
        ;;
esac
