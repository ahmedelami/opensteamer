#!/bin/sh
# Deterministically compile and invoke the one-shot diagnostic-driver updater.
# The launcher itself has no privileged mutation path. Live modes require the exact
# reviewed source/binary postimages and the controller's clean pushed provenance proof.
set -eu
umask 077

PREFLIGHT_MODE='--verify-diagnostic-driver-v17-update-preflight'
EXECUTE_MODE='--execute-authorized-diagnostic-driver-v17-update'
ROLLBACK_MODE='--rollback-authorized-diagnostic-driver-v17-update'
SELF_TEST_MODE='--self-test-diagnostic-driver-v17-update'
EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer-diagnostic-v3'
USER_UPDATE_ROOT='/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v17'
USER_ACTIVE_POINTER='/Users/ahmed/Library/Application Support/opensteamer/active-diagnostic-driver-update-v17'
ROOT_SUPPORT='/Library/Application Support/opensteamer'
ROOT_CONTROLLER_PARENT='/Library/Application Support/opensteamer/diagnostic-driver-controllers-v17'
ROOT_RECOVERY_CONTROLLER="$ROOT_CONTROLLER_PARENT/recovery-controller"
ROOT_RECOVERY_CONTROLLER_PIN="$ROOT_CONTROLLER_PARENT/recovery-controller.sha256"
ROOT_ACTIVE_POINTER='/Library/Application Support/opensteamer/active-diagnostic-driver-update-v17'
ROOT_BOOTSTRAP_LOCATOR='/Library/Application Support/opensteamer/diagnostic-driver-bootstrap-v17.txt'
DIAGNOSTIC_READER_SHA256='6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded'
SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-diagnostic-driver-v17-update-controller.rs"
RUSTC='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'
EXPECTED_MACOSX_DEPLOYMENT_TARGET='26.0'
RELEASE_PIN_STATUS='PINNED_FINAL_REVIEW'
EXPECTED_SOURCE_SHA256='a4c94222b4cdc639b06afab896d47aac2ac2dceef745e0a4df3f3fa79e31da00'
EXPECTED_BINARY_SHA256='eb09c42daa039f99e3751d1ec96e813c4ca8f08be81d3b7d543650070e968f21'
BUILD_PARENT='/Volumes/t7/opensteamer-diagnostic-driver-v17-controller-builds'

usage() {
    echo "usage: $0 $PREFLIGHT_MODE $EXPECTED_REPO" >&2
    echo "       $0 $EXECUTE_MODE $EXPECTED_REPO <authorized-updater-release-commit> <authorized-updater-release-tree>" >&2
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

[ "$(/usr/bin/id -u)" = 501 ] || {
    echo 'diagnostic-driver updater must run as UID 501' >&2
    exit 1
}

# Power-loss recovery deliberately runs before source, Git, compiler, or external-volume checks.
# It invokes only the constant sealed root-owned controller as UID501. That controller holds all
# retained user tombstone locks while it sudo-dispatches the private root recovery entrypoint.
if [ "$MODE" = "$ROLLBACK_MODE" ]; then
    # The locator is the first root artifact. If no canonical pointer exists,
    # any safely owned staging-mode/partial fixed entrypoint is pre-stop only.
    # Classify it without executing or deleting the partial bytes.
    if [ ! -e "$ROOT_ACTIVE_POINTER" ] && [ ! -L "$ROOT_ACTIVE_POINTER" ] \
        && { [ -e "$ROOT_BOOTSTRAP_LOCATOR" ] || [ -L "$ROOT_BOOTSTRAP_LOCATOR" ] \
            || [ -e "$ROOT_CONTROLLER_PARENT" ] || [ -L "$ROOT_CONTROLLER_PARENT" ]; }; then
        FIXED_READY=0
        LOCATOR_READY=0
        if [ -f "$ROOT_BOOTSTRAP_LOCATOR" ] && [ ! -L "$ROOT_BOOTSTRAP_LOCATOR" ] \
            && [ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$ROOT_BOOTSTRAP_LOCATOR")" = '0:0:1:444' ] \
            && [ "$(/usr/bin/wc -l < "$ROOT_BOOTSTRAP_LOCATOR" | /usr/bin/tr -d ' ')" = 11 ] \
            && [ "$(/usr/bin/sed -n '1p' "$ROOT_BOOTSTRAP_LOCATOR")" = 'OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_REQUEST_V17' ]; then
            LOCATOR_NONCE=$(/usr/bin/sed -n '2s/^nonce=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_EVIDENCE=$(/usr/bin/sed -n '3s/^evidence=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_DIGEST=$(/usr/bin/sed -n '4s/^controller_sha256=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_CONTROLLER=$(/usr/bin/sed -n '5s/^root_controller=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_READER=$(/usr/bin/sed -n '6s/^reader_sha256=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_COMMIT=$(/usr/bin/sed -n '7s/^authorized_commit=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_TREE=$(/usr/bin/sed -n '8s/^authorized_tree=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_DISPLAY_IDENTITY=$(/usr/bin/sed -n '9s/^display_identity=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_DISPLAY_SELECTED=$(/usr/bin/sed -n '10s/^display_selected=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            LOCATOR_DISPLAY_CAPABILITIES=$(/usr/bin/sed -n '11s/^display_capabilities=//p' "$ROOT_BOOTSTRAP_LOCATOR")
            case "$LOCATOR_NONCE:$LOCATOR_DIGEST:$LOCATOR_COMMIT:$LOCATOR_TREE" in
                *[!0-9a-f:]*) ;;
                *)
                    if [ "${#LOCATOR_NONCE}" -eq 32 ] \
                        && [ "${#LOCATOR_DIGEST}" -eq 64 ] \
                        && [ "${#LOCATOR_COMMIT}" -eq 40 ] \
                        && [ "${#LOCATOR_TREE}" -eq 40 ] \
                        && [ "$LOCATOR_CONTROLLER" = "$ROOT_CONTROLLER_PARENT/controller-$LOCATOR_NONCE/controller" ] \
                        && [ "$LOCATOR_READER" = "$DIAGNOSTIC_READER_SHA256" ] \
                        && [ "$LOCATOR_DISPLAY_IDENTITY" = '28531:5912:1' ] \
                        && [ "$LOCATOR_DISPLAY_CAPABILITIES" = '1080:1920:1080:1920:60000,603:1311:1206:2622:60000,540:1170:1080:2340:60000,540:960:1080:1920:60000,414:896:828:1792:60000,750:1334:750:1334:60000' ]; then
                        case "$LOCATOR_DISPLAY_SELECTED" in
                            1080:1920:1080:1920:60000|603:1311:1206:2622:60000|540:1170:1080:2340:60000|540:960:1080:1920:60000|414:896:828:1792:60000|750:1334:750:1334:60000|720:1280:720:1280:60000)
                                case "$LOCATOR_EVIDENCE" in
                                    "$USER_UPDATE_ROOT"/diagnostic-driver-v17-*"$LOCATOR_NONCE") LOCATOR_READY=1 ;;
                                esac
                                ;;
                        esac
                    fi
                    ;;
            esac
        fi
        if [ -f "$ROOT_RECOVERY_CONTROLLER" ] && [ ! -L "$ROOT_RECOVERY_CONTROLLER" ] \
            && [ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$ROOT_RECOVERY_CONTROLLER")" = '0:0:1:555' ] \
            && [ "$(/usr/bin/stat -f '%z' "$ROOT_RECOVERY_CONTROLLER")" -gt 0 ] \
            && [ -f "$ROOT_RECOVERY_CONTROLLER_PIN" ] && [ ! -L "$ROOT_RECOVERY_CONTROLLER_PIN" ] \
            && [ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$ROOT_RECOVERY_CONTROLLER_PIN")" = '0:0:1:444' ] \
            && [ "$LOCATOR_READY" -eq 1 ]; then
            EARLY_DIGEST=$(/bin/cat "$ROOT_RECOVERY_CONTROLLER_PIN")
            case "$EARLY_DIGEST" in
                ''|*[!0-9a-f]*) ;;
                *)
                    if [ "${#EARLY_DIGEST}" -eq 64 ] \
                        && [ "$(/usr/bin/wc -l < "$ROOT_RECOVERY_CONTROLLER_PIN" | /usr/bin/tr -d ' ')" = 1 ] \
                        && [ "$(/usr/bin/shasum -a 256 "$ROOT_RECOVERY_CONTROLLER" | /usr/bin/awk '{print $1}')" = "$EARLY_DIGEST" ]; then
                        FIXED_READY=1
                    fi
                    ;;
            esac
        fi
        if [ "$FIXED_READY" -eq 0 ]; then
            [ -d "$ROOT_SUPPORT" ] && [ ! -L "$ROOT_SUPPORT" ] \
                && [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$ROOT_SUPPORT")" = '0:0:755' ] || exit 1
            if [ -e "$ROOT_CONTROLLER_PARENT" ] || [ -L "$ROOT_CONTROLLER_PARENT" ]; then
                [ -d "$ROOT_CONTROLLER_PARENT" ] && [ ! -L "$ROOT_CONTROLLER_PARENT" ] \
                    && [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$ROOT_CONTROLLER_PARENT")" = '0:0:711' ] || exit 1
            fi
            for PARTIAL_DIRECTORY in "$ROOT_SUPPORT" "$ROOT_CONTROLLER_PARENT"; do
                [ -e "$PARTIAL_DIRECTORY" ] || continue
                PARTIAL_DIRECTORY_MODE=$(/bin/ls -lde@ "$PARTIAL_DIRECTORY" | /usr/bin/awk 'NR==1{mode=$1} END{if(NR==1)print mode;else exit 1}') || exit 1
                case "$PARTIAL_DIRECTORY_MODE" in *+|*@) exit 1 ;; esac
                PARTIAL_DIRECTORY_XATTRS=$(/usr/bin/sudo -n -- /usr/bin/xattr "$PARTIAL_DIRECTORY") || exit 1
                [ -z "$PARTIAL_DIRECTORY_XATTRS" ] || exit 1
            done
            for PARTIAL_NODE in "$ROOT_BOOTSTRAP_LOCATOR" "$ROOT_RECOVERY_CONTROLLER" "$ROOT_RECOVERY_CONTROLLER_PIN"; do
                if [ ! -e "$PARTIAL_NODE" ] && [ ! -L "$PARTIAL_NODE" ]; then
                    continue
                fi
                [ -f "$PARTIAL_NODE" ] && [ ! -L "$PARTIAL_NODE" ] || exit 1
                PARTIAL_META=$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$PARTIAL_NODE")
                case "$PARTIAL_NODE:$PARTIAL_META" in
                    "$ROOT_BOOTSTRAP_LOCATOR":0:0:1:400|"$ROOT_BOOTSTRAP_LOCATOR":0:0:1:444) ;;
                    "$ROOT_RECOVERY_CONTROLLER":0:0:1:500|"$ROOT_RECOVERY_CONTROLLER":0:0:1:555) ;;
                    "$ROOT_RECOVERY_CONTROLLER_PIN":0:0:1:400|"$ROOT_RECOVERY_CONTROLLER_PIN":0:0:1:444) ;;
                    *) exit 1 ;;
                esac
                PARTIAL_MODE=$(/bin/ls -lde@ "$PARTIAL_NODE" | /usr/bin/awk 'NR==1{mode=$1} END{if(NR==1)print mode;else exit 1}') || exit 1
                case "$PARTIAL_MODE" in *+|*@) exit 1 ;; esac
                PARTIAL_NODE_XATTRS=$(/usr/bin/sudo -n -- /usr/bin/xattr "$PARTIAL_NODE") || exit 1
                [ -z "$PARTIAL_NODE_XATTRS" ] || exit 1
            done
            echo 'DIAGNOSTIC_DRIVER_V17_BOOTSTRAP_INCOMPLETE_HOST_PRESERVED root_pointer=absent' >&2
            exit 75
        fi
    fi
    [ -d "$ROOT_SUPPORT" ] && [ ! -L "$ROOT_SUPPORT" ] \
        && [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$ROOT_SUPPORT")" = '0:0:755' ] \
        && [ -d "$ROOT_CONTROLLER_PARENT" ] && [ ! -L "$ROOT_CONTROLLER_PARENT" ] \
        && [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$ROOT_CONTROLLER_PARENT")" = '0:0:711' ] \
        && [ -f "$ROOT_RECOVERY_CONTROLLER" ] && [ ! -L "$ROOT_RECOVERY_CONTROLLER" ] \
        && [ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$ROOT_RECOVERY_CONTROLLER")" = '0:0:1:555' ] \
        && [ -f "$ROOT_RECOVERY_CONTROLLER_PIN" ] && [ ! -L "$ROOT_RECOVERY_CONTROLLER_PIN" ] \
        && [ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$ROOT_RECOVERY_CONTROLLER_PIN")" = '0:0:1:444' ] || {
        echo 'fixed sealed recovery entrypoint has unsafe metadata' >&2
        exit 1
    }
    for SEALED_NODE in "$ROOT_SUPPORT" "$ROOT_CONTROLLER_PARENT" "$ROOT_RECOVERY_CONTROLLER" "$ROOT_RECOVERY_CONTROLLER_PIN"; do
        SEALED_MODE=$(/bin/ls -lde@ "$SEALED_NODE" | /usr/bin/awk 'NR==1{mode=$1} END{if(NR==1)print mode;else exit 1}') || {
            echo 'fixed sealed recovery entrypoint ACL probe failed' >&2
            exit 1
        }
        case "$SEALED_MODE" in
            *+|*@)
                echo 'fixed sealed recovery entrypoint has an ACL or extended metadata' >&2
                exit 1
                ;;
        esac
        SEALED_NODE_XATTRS=$(/usr/bin/sudo -n -- /usr/bin/xattr "$SEALED_NODE") || {
            echo 'fixed sealed recovery entrypoint xattr probe failed' >&2
            exit 1
        }
        [ -z "$SEALED_NODE_XATTRS" ] || {
            echo 'fixed sealed recovery entrypoint has extended attributes' >&2
            exit 1
        }
    done
    RECOVERY_DIGEST=$(/bin/cat "$ROOT_RECOVERY_CONTROLLER_PIN")
    case "$RECOVERY_DIGEST" in
        ''|*[!0-9a-f]*)
            echo 'fixed sealed recovery digest is malformed' >&2
            exit 1
            ;;
    esac
    [ "${#RECOVERY_DIGEST}" -eq 64 ] \
        && [ "$(/usr/bin/wc -l < "$ROOT_RECOVERY_CONTROLLER_PIN" | /usr/bin/tr -d ' ')" = 1 ] \
        && [ "$(/usr/bin/shasum -a 256 "$ROOT_RECOVERY_CONTROLLER" | /usr/bin/awk '{print $1}')" = "$RECOVERY_DIGEST" ] \
        && [ "$(/usr/bin/shasum -a 256 "$ROOT_RECOVERY_CONTROLLER" | /usr/bin/awk '{print $1}')" = "$RECOVERY_DIGEST" ] || {
        echo 'fixed sealed recovery entrypoint differs from its root pin' >&2
        exit 1
    }
    RECOVERY_OUTPUT=$("$ROOT_RECOVERY_CONTROLLER" "$ROLLBACK_MODE" "$EXPECTED_REPO")
    case "$RECOVERY_OUTPUT" in
        DIAGNOSTIC_DRIVER_V17_RECOVERY_COMPLETE\ outcome=committed\ *) RECOVERY_OUTCOME='committed' ;;
        DIAGNOSTIC_DRIVER_V17_RECOVERY_COMPLETE\ outcome=rolled-back\ *) RECOVERY_OUTCOME='rolled-back' ;;
        DIAGNOSTIC_DRIVER_V17_RECOVERY_COMPLETE\ outcome=prestop-aborted\ *) RECOVERY_OUTCOME='prestop-aborted' ;;
        *)
            echo 'fixed UID501 recovery controller returned an unknown success marker' >&2
            exit 1
            ;;
    esac
    # User evidence is advisory and touched only after root has restored/verified service.
    # Missing or hostile UID501 evidence cannot turn a completed system recovery into failure.
    if [ -f "$USER_ACTIVE_POINTER" ] && [ ! -L "$USER_ACTIVE_POINTER" ] \
        && [ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$USER_ACTIVE_POINTER")" = '501:20:1:600' ]; then
        RECOVERY_EVIDENCE=$(/bin/cat "$USER_ACTIVE_POINTER")
        case "$RECOVERY_EVIDENCE" in
            "$USER_UPDATE_ROOT"/diagnostic-driver-v17-*)
                if [ -d "$RECOVERY_EVIDENCE" ] && [ ! -L "$RECOVERY_EVIDENCE" ] \
                    && [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$RECOVERY_EVIDENCE")" = '501:20:700' ]; then
                    RECOVERY_RESULT="$RECOVERY_EVIDENCE/recovery-result.txt"
                    if [ ! -e "$RECOVERY_RESULT" ] && [ ! -L "$RECOVERY_RESULT" ]; then
                        (
                            set -C
                            umask 077
                            /usr/bin/printf 'OPENSTEAMER_DIAGNOSTIC_DRIVER_RECOVERY_RESULT_V17\noutcome=%s\ndetail=fixed-root-recovery-complete\n' "$RECOVERY_OUTCOME" > "$RECOVERY_RESULT"
                            /bin/chmod 600 "$RECOVERY_RESULT"
                        ) 2>/dev/null || true
                    fi
                fi
                ;;
        esac
    fi
    /usr/bin/printf '%s\n' "$RECOVERY_OUTPUT"
    exit 0
fi

[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] \
    && [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$SOURCE")" = '501:1:644' ] || {
    echo 'diagnostic-driver controller source has unsafe metadata' >&2
    exit 1
}

[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ] || {
    echo 'diagnostic-driver updater is intentionally unrunnable until final review' >&2
    exit 78
}
for reviewed_pin in "$EXPECTED_SOURCE_SHA256" "$EXPECTED_BINARY_SHA256"; do
    case "$reviewed_pin" in
        ''|*[!0-9a-f]*)
            echo 'diagnostic-driver source/binary pin is not lowercase hexadecimal' >&2
            exit 78
            ;;
    esac
    [ "${#reviewed_pin}" -eq 64 ] || {
        echo 'diagnostic-driver source/binary pin is not exactly 64 characters' >&2
        exit 78
    }
done
[ "$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_SOURCE_SHA256" ] || {
    echo 'diagnostic-driver controller source differs from reviewed bytes' >&2
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
[ -d /Volumes/t7 ] && [ ! -L /Volumes/t7 ] || {
    echo 'the reviewed external build volume /Volumes/t7 is unavailable' >&2
    exit 1
}
if [ ! -d "$BUILD_PARENT" ]; then
    /bin/mkdir -m 700 "$BUILD_PARENT"
fi
[ -d "$BUILD_PARENT" ] && [ ! -L "$BUILD_PARENT" ] \
    && [ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_PARENT")" = '501:700' ] || {
    echo 'external diagnostic-driver build parent is unsafe' >&2
    exit 1
}

BUILD_ROOT_A=$(/usr/bin/mktemp -d "$BUILD_PARENT/.controller-a.XXXXXX") || exit 1
BUILD_ROOT_B=$(/usr/bin/mktemp -d "$BUILD_PARENT/.controller-b.XXXXXX") || {
    /bin/rmdir "$BUILD_ROOT_A" 2>/dev/null || true
    exit 1
}
cleanup() {
    case "$BUILD_ROOT_A:$BUILD_ROOT_B" in
        "$BUILD_PARENT"/.controller-a.*:"$BUILD_PARENT"/.controller-b.*)
            /bin/chmod -R u+w "$BUILD_ROOT_A" "$BUILD_ROOT_B" 2>/dev/null || true
            /bin/rm -rf "$BUILD_ROOT_A" "$BUILD_ROOT_B" 2>/dev/null || true
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

compile_controller() {
    build_root=$1
    controller="$build_root/controller"
    MACOSX_DEPLOYMENT_TARGET="$EXPECTED_MACOSX_DEPLOYMENT_TARGET" \
    "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
        --sysroot "$RUSTC_SYSROOT" \
        --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-diagnostic-driver-v17" \
        --remap-path-prefix "$build_root=/reviewed/opensteamer-diagnostic-driver-v17-build" \
        "$SOURCE" -o "$controller"
    /bin/chmod 500 "$controller"
    [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$controller")" = '501:1:500' ] || exit 1
}

compile_controller "$BUILD_ROOT_A"
compile_controller "$BUILD_ROOT_B"
CONTROLLER_A="$BUILD_ROOT_A/controller"
CONTROLLER_B="$BUILD_ROOT_B/controller"
/usr/bin/cmp -s "$CONTROLLER_A" "$CONTROLLER_B" || {
    echo 'two diagnostic-driver controller compilations were not byte-identical' >&2
    exit 1
}
CONTROLLER_BINARY_SHA256=$(/usr/bin/shasum -a 256 "$CONTROLLER_B" | /usr/bin/awk '{print $1}')
[ "$CONTROLLER_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ] || {
    echo 'compiled diagnostic-driver controller differs from reviewed binary hash' >&2
    exit 1
}

[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$CONTROLLER_B")" = '501:1:500' ] \
    && [ "$(/usr/bin/shasum -a 256 "$CONTROLLER_B" | /usr/bin/awk '{print $1}')" = \
      "$CONTROLLER_BINARY_SHA256" ] || {
    echo 'diagnostic-driver controller changed after deterministic compilation' >&2
    exit 1
}
"$CONTROLLER_B" "$@"
