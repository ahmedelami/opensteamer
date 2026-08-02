#!/bin/sh
# Freshly compiles the checked-in Rust controller with the exact reviewed Homebrew compiler,
# publishes the private executable without replacement, runs that exact binary, and removes it.
set -eu
umask 077

AUTHORIZED_MODE='--execute-authorized-mac-only-migration'
SELF_TEST_BUILD_MODE='--self-test-reviewed-controller-build'
PRIOR_RETRY_PREFLIGHT_MODE='--verify-reviewed-prior-retry-state'
TRUSTED_RUSTC_LINK='/opt/homebrew/bin/rustc'
TRUSTED_RUSTC_CANONICAL='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
TRUSTED_RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
TRUSTED_RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
REVIEWED_BUILD_PREFIX='/reviewed/opensteamer-controller'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_CDHASH_FULL='d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e'
EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'
EXPECTED_RUSTC_DRIVER_CDHASH_FULL='d304c582680e8f4f226b05865358468995b0f8a337339621968dfe64879d9d4c'
EXPECTED_CONTROLLER_SOURCE_SHA256='40da9389806d23f25a7d3e51ce4d668b0e8bd752e99d43e113e21dbb42ad2e34'
EXPECTED_CONTROLLER_BINARY_SHA256='ce4622b1792957b23d69681d2af5c190ca73e1343f62d476dd33872c314efc2e'
EXPECTED_BUILD_SCRIPT_SHA256='bda01b7ec76e5112a127fd97427fbff4a23c5d352232bed64d3cc93cf44e9619'
EXPECTED_BUNDLE_VERIFIER_SHA256='b667df23e06d55140a61e8b8e7c1de3a6aa5ebd6f4c4f063c805ddf98b5edc27'
EXPECTED_LAUNCH_VERIFIER_SHA256='27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9'
EXPECTED_DEPLOYMENT_VERIFIER_SHA256='1a972c52ad5be2dc10547d1f8666946f6031386e4cfa7daf4b35e2720316576a'
EXPECTED_LIVE_PROCESS_VERIFIER_SHA256='0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41'

usage() {
    echo "usage: $0 {$AUTHORIZED_MODE|$SELF_TEST_BUILD_MODE|$PRIOR_RETRY_PREFLIGHT_MODE} <absolute-canonical-repository-root>" >&2
    exit 64
}

resolve_link() {
    path=$1
    count=0
    while [ -L "$path" ]; do
        count=$((count + 1))
        [ "$count" -le 16 ] || return 1
        target=$(/usr/bin/readlink "$path") || return 1
        case "$target" in
            /*) path=$target ;;
            *) path=$(/usr/bin/dirname "$path")/$target ;;
        esac
        parent=$(CDPATH= cd -P "$(/usr/bin/dirname "$path")" 2>/dev/null && pwd -P) || return 1
        path=$parent/$(/usr/bin/basename "$path")
    done
    printf '%s\n' "$path"
}

lower_hex_64() {
    case "$1" in
        ????????????????????????????????????????????????????????????????) ;;
        *) return 1 ;;
    esac
    case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

verify_companion_script() {
    companion_path=$1
    companion_sha=$2
    [ -f "$companion_path" ] && [ ! -L "$companion_path" ] || return 1
    [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$companion_path")" = \
      "$(/usr/bin/id -u):1:755" ] || return 1
    [ "$(/usr/bin/shasum -a 256 "$companion_path" | /usr/bin/awk '{print $1}')" = \
      "$companion_sha" ]
}

copy_companion_script() {
    companion_source=$1
    companion_sha=$2
    companion_copy="$BUILD_DIR/$(/usr/bin/basename "$companion_source")"
    /bin/cp "$companion_source" "$companion_copy" || return 1
    /bin/chmod 400 "$companion_copy" || return 1
    [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$companion_copy")" = \
      "$(/usr/bin/id -u):1:400" ] || return 1
    /usr/bin/cmp -s "$companion_source" "$companion_copy" || return 1
    [ "$(/usr/bin/shasum -a 256 "$companion_copy" | /usr/bin/awk '{print $1}')" = \
      "$companion_sha" ]
}

verify_private_companion_script() {
    companion_source=$1
    companion_sha=$2
    companion_copy="$BUILD_DIR/$(/usr/bin/basename "$companion_source")"
    [ -f "$companion_copy" ] && [ ! -L "$companion_copy" ] || return 1
    [ "$(/usr/bin/stat -f '%u:%l:%Lp' "$companion_copy")" = \
      "$(/usr/bin/id -u):1:400" ] || return 1
    /usr/bin/cmp -s "$companion_source" "$companion_copy" || return 1
    [ "$(/usr/bin/shasum -a 256 "$companion_copy" | /usr/bin/awk '{print $1}')" = \
      "$companion_sha" ]
}

parse_rustc_cdhash_metadata() {
    /usr/bin/awk '''
        function valid_hex(value, expected_length) {
            return length(value) == expected_length && value !~ /[^0-9A-Fa-f]/
        }
        /^CandidateCDHashFull([[:space:]]|$)/ {
            full_lines += 1
            if (NF != 2 || index($2, "=") == 0) { malformed = 1; next }
            split($2, pair, "=")
            if (pair[1] != "sha256" || !valid_hex(pair[2], 64)) { malformed = 1; next }
            full = tolower(pair[2]); full_valid += 1; next
        }
        /^CandidateCDHash([[:space:]]|$)/ {
            short_lines += 1
            if (NF != 2 || index($2, "=") == 0) { malformed = 1; next }
            split($2, pair, "=")
            if (pair[1] != "sha256" || !valid_hex(pair[2], 40)) { malformed = 1; next }
            candidate = tolower(pair[2]); candidate_valid += 1; next
        }
        /^CDHash=/ {
            cdhash_lines += 1
            if (NF != 1) { malformed = 1; next }
            value = substr($0, length("CDHash=") + 1)
            if (!valid_hex(value, 40)) { malformed = 1; next }
            cdhash = tolower(value); cdhash_valid += 1; next
        }
        END {
            if (malformed || full_lines != 1 || full_valid != 1 ||
                short_lines != 1 || candidate_valid != 1 ||
                cdhash_lines != 1 || cdhash_valid != 1 ||
                substr(full, 1, 40) != candidate || candidate != cdhash) {
                exit 2
            }
            print full
        }
    '''
}

self_test_cdhash_parser() {
    real_fixture='''Identifier=rustc-55554944b4edcd2f1ff83ea2acffea81b92319c7
CandidateCDHash sha256=d57b3f82fa576b65e91de0fb90358f766425c35e
CandidateCDHashFull sha256=d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e
CDHash=d57b3f82fa576b65e91de0fb90358f766425c35e
TeamIdentifier=not set'''
    parsed=$(printf '''%s\n''' "$real_fixture" | parse_rustc_cdhash_metadata) || return 1
    [ "$parsed" = "$EXPECTED_RUSTC_CDHASH_FULL" ] || return 1

    duplicate="$real_fixture
CandidateCDHashFull sha256=$EXPECTED_RUSTC_CDHASH_FULL"
    wrong_short_algorithm='''CandidateCDHash sha1=d57b3f82fa576b65e91de0fb90358f766425c35e
CandidateCDHashFull sha256=d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e
CDHash=d57b3f82fa576b65e91de0fb90358f766425c35e'''
    wrong_full_algorithm='''CandidateCDHash sha256=d57b3f82fa576b65e91de0fb90358f766425c35e
CandidateCDHashFull sha384=d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e
CDHash=d57b3f82fa576b65e91de0fb90358f766425c35e'''
    short_full='''CandidateCDHash sha256=d57b3f82fa576b65e91de0fb90358f766425c35e
CandidateCDHashFull sha256=d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008
CDHash=d57b3f82fa576b65e91de0fb90358f766425c35e'''
    mismatch='''CandidateCDHash sha256=057b3f82fa576b65e91de0fb90358f766425c35e
CandidateCDHashFull sha256=d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e
CDHash=d57b3f82fa576b65e91de0fb90358f766425c35e'''
    for invalid in "$duplicate" "$wrong_short_algorithm" "$wrong_full_algorithm" "$short_full" "$mismatch"
    do
        if printf '''%s\n''' "$invalid" | parse_rustc_cdhash_metadata >/dev/null 2>&1; then
            return 1
        fi
    done
    printf '''%s\n''' '''SELF_TEST_OK rustc-cdhash-parser'''
}

if [ "$#" -eq 1 ] && [ "$1" = "--self-test-cdhash-parser" ]; then
    self_test_cdhash_parser
    exit $?
fi

[ "$#" -eq 2 ] || usage
[ "$1" = "$AUTHORIZED_MODE" ] || [ "$1" = "$SELF_TEST_BUILD_MODE" ] \
    || [ "$1" = "$PRIOR_RETRY_PREFLIGHT_MODE" ] || usage
REQUESTED_MODE=$1
case "$2" in /*) ;; *) echo "repository root must be absolute" >&2; exit 1 ;; esac
ROOT=$(CDPATH= cd "$2" 2>/dev/null && pwd -P) || {
    echo "could not resolve repository root" >&2
    exit 1
}
[ "$ROOT" = "$2" ] || {
    echo "repository root must be canonical: $ROOT" >&2
    exit 1
}
[ ! -L "$ROOT" ] || {
    echo "repository root must not be a symbolic link" >&2
    exit 1
}
ROOT_MODE=$(/usr/bin/stat -f '%Lp' "$ROOT") || exit 1
[ $((0$ROOT_MODE & 022)) -eq 0 ] || {
    echo "repository root must not be group/world writable" >&2
    exit 1
}

SOURCE="$ROOT/macOS/scripts/opensteamer-host-migration-controller.rs"
BUILD_SCRIPT="$ROOT/macOS/scripts/build-opensteamer-host-app.sh"
BUNDLE_VERIFIER="$ROOT/macOS/scripts/verify-mac-host-bundle.sh"
LAUNCH_VERIFIER="$ROOT/macOS/scripts/verify-mac-host-launch-state.sh"
DEPLOYMENT_VERIFIER="$ROOT/macOS/scripts/verify-mac-host-deployment.sh"
LIVE_PROCESS_VERIFIER="$ROOT/macOS/scripts/verify-live-mac-host-process.sh"
[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] || {
    echo "migration controller source is missing or unsafe: $SOURCE" >&2
    exit 1
}
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$SOURCE")" = "$(/usr/bin/id -u):1:644" ] || {
    echo "migration controller source owner/link-count/mode is unsafe" >&2
    exit 1
}
SOURCE_SHA=$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}') || exit 1
lower_hex_64 "$SOURCE_SHA" || {
    echo "controller source hash is malformed" >&2
    exit 1
}
[ "$SOURCE_SHA" = "$EXPECTED_CONTROLLER_SOURCE_SHA256" ] || {
    echo "controller source hash differs from the reviewed v15 postimage" >&2
    exit 1
}
verify_companion_script "$BUILD_SCRIPT" "$EXPECTED_BUILD_SCRIPT_SHA256" \
    && verify_companion_script "$BUNDLE_VERIFIER" "$EXPECTED_BUNDLE_VERIFIER_SHA256" \
    && verify_companion_script "$LAUNCH_VERIFIER" "$EXPECTED_LAUNCH_VERIFIER_SHA256" \
    && verify_companion_script "$DEPLOYMENT_VERIFIER" "$EXPECTED_DEPLOYMENT_VERIFIER_SHA256" \
    && verify_companion_script "$LIVE_PROCESS_VERIFIER" "$EXPECTED_LIVE_PROCESS_VERIFIER_SHA256" || {
    echo "one or more controller companion scripts differ from the reviewed v15 postimage" >&2
    exit 1
}

[ -e "$TRUSTED_RUSTC_LINK" ] || {
    echo "reviewed Rust compiler command path is missing: $TRUSTED_RUSTC_LINK" >&2
    exit 1
}
RUSTC=$(resolve_link "$TRUSTED_RUSTC_LINK") || {
    echo "reviewed Rust compiler path could not be resolved: $TRUSTED_RUSTC_LINK" >&2
    exit 1
}
[ "$RUSTC" = "$TRUSTED_RUSTC_CANONICAL" ] || {
    echo "reviewed Rust compiler resolved to '$RUSTC', expected '$TRUSTED_RUSTC_CANONICAL'" >&2
    exit 1
}
[ -f "$RUSTC" ] && [ ! -L "$RUSTC" ] && [ -x "$RUSTC" ] || {
    echo "reviewed Rust compiler is not a real executable: $RUSTC" >&2
    exit 1
}
[ "$(/usr/bin/stat -f '%Su:%Sg:%l:%Lp' "$RUSTC")" = "ahmed:admin:1:555" ] || {
    echo "reviewed Rust compiler owner/group/link-count/mode is unsafe" >&2
    exit 1
}
RUSTC_SHA=$(/usr/bin/shasum -a 256 "$RUSTC" | /usr/bin/awk '{print $1}') || exit 1
lower_hex_64 "$RUSTC_SHA" || {
    echo "reviewed Rust compiler hash is malformed" >&2
    exit 1
}
[ "$RUSTC_SHA" = "$EXPECTED_RUSTC_SHA256" ] || {
    echo "reviewed Rust compiler SHA-256 differs from the embedded trust anchor" >&2
    exit 1
}
RUSTC_CODE_METADATA=$(/usr/bin/codesign -dv --verbose=4 "$RUSTC" 2>&1) || {
    echo "could not inspect reviewed Rust compiler code signature" >&2
    exit 1
}
RUSTC_CDHASH_FULL=$(printf '%s
' "$RUSTC_CODE_METADATA" \
    | parse_rustc_cdhash_metadata) || {
    echo "reviewed Rust compiler code-signature CDHash metadata is missing, ambiguous, or malformed" >&2
    exit 1
}
[ "$RUSTC_CDHASH_FULL" = "$EXPECTED_RUSTC_CDHASH_FULL" ] || {
    echo "reviewed Rust compiler full SHA-256 candidate CDHash differs from the embedded trust anchor" >&2
    exit 1
}
printf '%s\n' "$RUSTC_CODE_METADATA" | /usr/bin/grep -Fxq 'Signature=adhoc' || {
    echo "reviewed Rust compiler is not the expected ad-hoc-signed code object" >&2
    exit 1
}
[ -f "$TRUSTED_RUSTC_DRIVER" ] && [ ! -L "$TRUSTED_RUSTC_DRIVER" ] \
    && [ "$(/usr/bin/stat -f '%Su:%Sg:%l:%Lp' "$TRUSTED_RUSTC_DRIVER")" = \
      "ahmed:admin:1:444" ] \
    && [ "$(/usr/bin/shasum -a 256 "$TRUSTED_RUSTC_DRIVER" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_DRIVER_SHA256" ] || {
    echo "reviewed Rust compiler driver bytes or metadata differ" >&2
    exit 1
}
RUSTC_DRIVER_CODE_METADATA=$(/usr/bin/codesign -dv --verbose=4 "$TRUSTED_RUSTC_DRIVER" 2>&1) || {
    echo "could not inspect reviewed Rust compiler driver signature" >&2
    exit 1
}
RUSTC_DRIVER_CDHASH_FULL=$(printf '%s\n' "$RUSTC_DRIVER_CODE_METADATA" \
    | parse_rustc_cdhash_metadata) || {
    echo "reviewed Rust compiler driver has malformed CDHash metadata" >&2
    exit 1
}
[ "$RUSTC_DRIVER_CDHASH_FULL" = "$EXPECTED_RUSTC_DRIVER_CDHASH_FULL" ] \
    && printf '%s\n' "$RUSTC_DRIVER_CODE_METADATA" \
        | /usr/bin/grep -Fxq 'Signature=adhoc' || {
    echo "reviewed Rust compiler driver differs from the expected code signature" >&2
    exit 1
}

BUILD_PARENT='/Users/ahmed/Library/Application Support/opensteamer'
[ -d '/Users/ahmed/Library/Application Support' ] \
    && [ ! -L '/Users/ahmed/Library/Application Support' ] || {
    echo "Application Support parent is missing or unsafe" >&2
    exit 1
}
if [ -e "$BUILD_PARENT" ] || [ -L "$BUILD_PARENT" ]; then
    [ -d "$BUILD_PARENT" ] && [ ! -L "$BUILD_PARENT" ] || {
        echo "private opensteamer application-support directory is unsafe" >&2
        exit 1
    }
else
    /bin/mkdir "$BUILD_PARENT" || exit 1
fi
/bin/chmod 700 "$BUILD_PARENT" || exit 1
[ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_PARENT")" = "$(/usr/bin/id -u):700" ] || {
    echo "private opensteamer application-support directory owner/mode is unsafe" >&2
    exit 1
}

BUILD_DIR=$(/usr/bin/mktemp -d "$BUILD_PARENT/.controller-build-v15.XXXXXX") || {
    echo "could not create private controller build directory" >&2
    exit 1
}
cleanup() {
    /bin/chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
    /bin/rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
/bin/chmod 700 "$BUILD_DIR" || exit 1
[ "$(/usr/bin/stat -f '%u:%Lp' "$BUILD_DIR")" = "$(/usr/bin/id -u):700" ] || {
    echo "private controller build directory owner/mode is unsafe" >&2
    exit 1
}

PINNED_RUSTC="$BUILD_DIR/rustc"
/bin/cp "$RUSTC" "$PINNED_RUSTC" || exit 1
/bin/chmod 500 "$PINNED_RUSTC" || exit 1
[ "$([ -f "$PINNED_RUSTC" ] && /usr/bin/stat -f '%u:%l:%Lp' "$PINNED_RUSTC")" = \
  "$(/usr/bin/id -u):1:500" ] || {
    echo "private Rust compiler copy owner/link-count/mode is unsafe" >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$PINNED_RUSTC" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_RUSTC_SHA256" ] || {
    echo "private Rust compiler copy differs from the reviewed compiler" >&2
    exit 1
}
PINNED_RUSTC_LIB="$BUILD_DIR/lib"
/bin/mkdir "$PINNED_RUSTC_LIB" || exit 1
/bin/chmod 700 "$PINNED_RUSTC_LIB" || exit 1
PINNED_RUSTC_DRIVER="$PINNED_RUSTC_LIB/$(/usr/bin/basename "$TRUSTED_RUSTC_DRIVER")"
/bin/cp "$TRUSTED_RUSTC_DRIVER" "$PINNED_RUSTC_DRIVER" || exit 1
/bin/chmod 400 "$PINNED_RUSTC_DRIVER" || exit 1
[ "$([ -f "$PINNED_RUSTC_DRIVER" ] \
    && /usr/bin/stat -f '%u:%l:%Lp' "$PINNED_RUSTC_DRIVER")" = \
  "$(/usr/bin/id -u):1:400" ] \
    && [ "$(/usr/bin/shasum -a 256 "$PINNED_RUSTC_DRIVER" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_DRIVER_SHA256" ] || {
    echo "private Rust compiler driver copy differs from the reviewed driver" >&2
    exit 1
}
PINNED_DRIVER_CODE_METADATA=$(/usr/bin/codesign -dv --verbose=4 "$PINNED_RUSTC_DRIVER" 2>&1) || {
    echo "could not inspect private Rust compiler driver signature" >&2
    exit 1
}
PINNED_DRIVER_CDHASH_FULL=$(printf '%s\n' "$PINNED_DRIVER_CODE_METADATA" \
    | parse_rustc_cdhash_metadata) || {
    echo "private Rust compiler driver has malformed CDHash metadata" >&2
    exit 1
}
[ "$PINNED_DRIVER_CDHASH_FULL" = "$EXPECTED_RUSTC_DRIVER_CDHASH_FULL" ] \
    && printf '%s\n' "$PINNED_DRIVER_CODE_METADATA" \
        | /usr/bin/grep -Fxq 'Signature=adhoc' || {
    echo "private Rust compiler driver differs from the reviewed code signature" >&2
    exit 1
}
PINNED_RUSTC_CODE_METADATA=$(/usr/bin/codesign -dv --verbose=4 "$PINNED_RUSTC" 2>&1) || {
    echo "could not inspect private Rust compiler copy signature" >&2
    exit 1
}
PINNED_RUSTC_CDHASH_FULL=$(printf '%s\n' "$PINNED_RUSTC_CODE_METADATA" \
    | parse_rustc_cdhash_metadata) || {
    echo "private Rust compiler copy has malformed CDHash metadata" >&2
    exit 1
}
[ "$PINNED_RUSTC_CDHASH_FULL" = "$EXPECTED_RUSTC_CDHASH_FULL" ] \
    && printf '%s\n' "$PINNED_RUSTC_CODE_METADATA" \
        | /usr/bin/grep -Fxq 'Signature=adhoc' || {
    echo "private Rust compiler copy differs from the reviewed code signature" >&2
    exit 1
}
RUSTC_VERSION=$(DYLD_LIBRARY_PATH="$PINNED_RUSTC_LIB" "$PINNED_RUSTC" --version) || exit 1
[ "$RUSTC_VERSION" = "$EXPECTED_RUSTC_VERSION" ] || {
    echo "reviewed Rust compiler version is '$RUSTC_VERSION', expected '$EXPECTED_RUSTC_VERSION'" >&2
    exit 1
}
RUSTC_SYSROOT=$("$RUSTC" --print sysroot) || exit 1
[ "$RUSTC_SYSROOT" = "$TRUSTED_RUSTC_SYSROOT" ] \
    && [ -d "$TRUSTED_RUSTC_SYSROOT/lib/rustlib" ] \
    && [ ! -L "$TRUSTED_RUSTC_SYSROOT" ] \
    && [ ! -L "$TRUSTED_RUSTC_SYSROOT/lib" ] \
    && [ ! -L "$TRUSTED_RUSTC_SYSROOT/lib/rustlib" ] || {
    echo "reviewed Rust compiler sysroot is missing, redirected, or unexpected" >&2
    exit 1
}

SOURCE_COPY="$BUILD_DIR/opensteamer-host-migration-controller.rs"
/bin/cp "$SOURCE" "$SOURCE_COPY" || exit 1
/bin/chmod 400 "$SOURCE_COPY" || exit 1
[ "$([ -f "$SOURCE_COPY" ] && /usr/bin/stat -f '%u:%l:%Lp' "$SOURCE_COPY")" = \
  "$(/usr/bin/id -u):1:400" ] || {
    echo "private controller source copy owner/link-count/mode is unsafe" >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$SOURCE_COPY" | /usr/bin/awk '{print $1}')" = "$SOURCE_SHA" ] || {
    echo "private controller source copy differs from the reviewed source" >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')" = "$SOURCE_SHA" ] || {
    echo "controller source changed while being copied" >&2
    exit 1
}
copy_companion_script "$BUILD_SCRIPT" "$EXPECTED_BUILD_SCRIPT_SHA256" \
    && copy_companion_script "$BUNDLE_VERIFIER" "$EXPECTED_BUNDLE_VERIFIER_SHA256" \
    && copy_companion_script "$LAUNCH_VERIFIER" "$EXPECTED_LAUNCH_VERIFIER_SHA256" \
    && copy_companion_script "$DEPLOYMENT_VERIFIER" "$EXPECTED_DEPLOYMENT_VERIFIER_SHA256" \
    && copy_companion_script "$LIVE_PROCESS_VERIFIER" "$EXPECTED_LIVE_PROCESS_VERIFIER_SHA256" || {
    echo "could not create exact private controller companion-script copies" >&2
    exit 1
}

BINARY_BUILD="$BUILD_DIR/.opensteamer-host-migration-controller.build"
BINARY_FIRST="$BUILD_DIR/.opensteamer-host-migration-controller.first"
BINARY="$BUILD_DIR/opensteamer-host-migration-controller"
[ ! -e "$BINARY_BUILD" ] && [ ! -L "$BINARY_BUILD" ] \
    && [ ! -e "$BINARY_FIRST" ] && [ ! -L "$BINARY_FIRST" ] \
    && [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] || {
    echo "private controller publication names are unexpectedly occupied" >&2
    exit 1
}

DYLD_LIBRARY_PATH="$PINNED_RUSTC_LIB" \
    "$PINNED_RUSTC" --edition=2021 -D warnings -C opt-level=2 \
    --sysroot "$TRUSTED_RUSTC_SYSROOT" \
    --remap-path-prefix "$BUILD_DIR=$REVIEWED_BUILD_PREFIX" \
    "$SOURCE_COPY" -o "$BINARY_BUILD" || exit 1
/bin/chmod 500 "$BINARY_BUILD" || exit 1
/bin/ln "$BINARY_BUILD" "$BINARY_FIRST" || {
    echo "could not exclusively preserve the first controller compilation" >&2
    exit 1
}
/bin/rm "$BINARY_BUILD" || exit 1
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$BINARY_FIRST")" = "$(/usr/bin/id -u):1:500" ] || {
    echo "first controller compilation owner/link-count/mode is unsafe" >&2
    exit 1
}

[ "$(/usr/bin/shasum -a 256 "$PINNED_RUSTC" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_RUSTC_SHA256" ] || {
    echo "private Rust compiler copy changed after first compilation" >&2
    exit 1
}
DYLD_LIBRARY_PATH="$PINNED_RUSTC_LIB" \
    "$PINNED_RUSTC" --edition=2021 -D warnings -C opt-level=2 \
    --sysroot "$TRUSTED_RUSTC_SYSROOT" \
    --remap-path-prefix "$BUILD_DIR=$REVIEWED_BUILD_PREFIX" \
    "$SOURCE_COPY" -o "$BINARY_BUILD" || exit 1
/bin/chmod 500 "$BINARY_BUILD" || exit 1
/usr/bin/cmp -s "$BINARY_FIRST" "$BINARY_BUILD" || {
    echo "two fresh same-output-path controller compilations were not byte-identical" >&2
    exit 1
}
/bin/ln "$BINARY_BUILD" "$BINARY" || {
    echo "could not exclusively publish the fresh controller executable" >&2
    exit 1
}
/bin/rm "$BINARY_BUILD" "$BINARY_FIRST" || exit 1

[ "$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')" = "$SOURCE_SHA" ] || {
    echo "controller source changed during compilation" >&2
    exit 1
}
[ "$([ -f "$SOURCE_COPY" ] && /usr/bin/stat -f '%u:%l:%Lp' "$SOURCE_COPY")" = \
  "$(/usr/bin/id -u):1:400" ] \
    && [ "$(/usr/bin/shasum -a 256 "$SOURCE_COPY" | /usr/bin/awk '{print $1}')" = \
      "$SOURCE_SHA" ] || {
    echo "private controller source copy changed during compilation" >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$RUSTC" | /usr/bin/awk '{print $1}')" = "$EXPECTED_RUSTC_SHA256" ] || {
    echo "reviewed Rust compiler changed during compilation" >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$PINNED_RUSTC" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_RUSTC_SHA256" ] || {
    echo "private Rust compiler copy changed during compilation" >&2
    exit 1
}
[ "$(/usr/bin/shasum -a 256 "$TRUSTED_RUSTC_DRIVER" | /usr/bin/awk '{print $1}')" = \
  "$EXPECTED_RUSTC_DRIVER_SHA256" ] \
    && [ "$(/usr/bin/shasum -a 256 "$PINNED_RUSTC_DRIVER" | /usr/bin/awk '{print $1}')" = \
      "$EXPECTED_RUSTC_DRIVER_SHA256" ] || {
    echo "Rust compiler driver changed during compilation" >&2
    exit 1
}
verify_companion_script "$BUILD_SCRIPT" "$EXPECTED_BUILD_SCRIPT_SHA256" \
    && verify_companion_script "$BUNDLE_VERIFIER" "$EXPECTED_BUNDLE_VERIFIER_SHA256" \
    && verify_companion_script "$LAUNCH_VERIFIER" "$EXPECTED_LAUNCH_VERIFIER_SHA256" \
    && verify_companion_script "$DEPLOYMENT_VERIFIER" "$EXPECTED_DEPLOYMENT_VERIFIER_SHA256" \
    && verify_companion_script "$LIVE_PROCESS_VERIFIER" "$EXPECTED_LIVE_PROCESS_VERIFIER_SHA256" || {
    echo "controller companion scripts changed during compilation" >&2
    exit 1
}
verify_private_companion_script "$BUILD_SCRIPT" "$EXPECTED_BUILD_SCRIPT_SHA256" \
    && verify_private_companion_script "$BUNDLE_VERIFIER" "$EXPECTED_BUNDLE_VERIFIER_SHA256" \
    && verify_private_companion_script "$LAUNCH_VERIFIER" "$EXPECTED_LAUNCH_VERIFIER_SHA256" \
    && verify_private_companion_script "$DEPLOYMENT_VERIFIER" "$EXPECTED_DEPLOYMENT_VERIFIER_SHA256" \
    && verify_private_companion_script "$LIVE_PROCESS_VERIFIER" "$EXPECTED_LIVE_PROCESS_VERIFIER_SHA256" || {
    echo "private controller companion-script copies changed during compilation" >&2
    exit 1
}
[ -f "$BINARY" ] && [ ! -L "$BINARY" ] && [ -x "$BINARY" ] || exit 1
[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$BINARY")" = "$(/usr/bin/id -u):1:500" ] || {
    echo "fresh controller binary owner/link-count/mode is unsafe" >&2
    exit 1
}
BINARY_SHA=$(/usr/bin/shasum -a 256 "$BINARY" | /usr/bin/awk '{print $1}') || exit 1
lower_hex_64 "$BINARY_SHA" || {
    echo "fresh controller binary hash is malformed" >&2
    exit 1
}
[ "$BINARY_SHA" = "$EXPECTED_CONTROLLER_BINARY_SHA256" ] || {
    echo "fresh controller binary differs from the reviewed reproducible postimage" >&2
    exit 1
}

if [ "$REQUESTED_MODE" = "$SELF_TEST_BUILD_MODE" ]; then
    "$BINARY" --self-test all
    exit $?
fi

if [ "$REQUESTED_MODE" = "$PRIOR_RETRY_PREFLIGHT_MODE" ]; then
    "$BINARY" "$PRIOR_RETRY_PREFLIGHT_MODE"
    exit $?
fi

OPENSTEAMER_MIGRATION_CONTROLLER_BINARY="$BINARY" \
OPENSTEAMER_MIGRATION_CONTROLLER_BINARY_SHA256="$BINARY_SHA" \
OPENSTEAMER_MIGRATION_CONTROLLER_SOURCE_SHA256="$SOURCE_SHA" \
OPENSTEAMER_MIGRATION_RUSTC_SHA256="$EXPECTED_RUSTC_SHA256" \
OPENSTEAMER_MIGRATION_RUSTC_CDHASH_FULL="$EXPECTED_RUSTC_CDHASH_FULL" \
    "$BINARY" "$AUTHORIZED_MODE" "$ROOT"
