#!/bin/sh
# Freshly compiles the checked-in Rust controller with the exact reviewed Homebrew compiler,
# publishes the private executable without replacement, runs that exact binary, and removes it.
set -eu
umask 077

AUTHORIZED_MODE='--execute-authorized-mac-only-migration'
TRUSTED_RUSTC_LINK='/opt/homebrew/bin/rustc'
TRUSTED_RUSTC_CANONICAL='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
EXPECTED_RUSTC_CDHASH_FULL='d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e'
EXPECTED_CONTROLLER_SOURCE_SHA256='5927df6ccf5482f9b07942360e99ac84e5ee9445278f8362c6504de90c728100'

usage() {
    echo "usage: $0 $AUTHORIZED_MODE <absolute-canonical-repository-root>" >&2
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
[ "$1" = "$AUTHORIZED_MODE" ] || usage
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
    echo "controller source hash differs from the reviewed v10 postimage" >&2
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
RUSTC_VERSION=$("$RUSTC" --version) || exit 1
[ "$RUSTC_VERSION" = "$EXPECTED_RUSTC_VERSION" ] || {
    echo "reviewed Rust compiler version is '$RUSTC_VERSION', expected '$EXPECTED_RUSTC_VERSION'" >&2
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

BUILD_DIR=$(/usr/bin/mktemp -d "$BUILD_PARENT/.controller-build-v10.XXXXXX") || {
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

BINARY_BUILD="$BUILD_DIR/.opensteamer-host-migration-controller.build"
BINARY_FIRST="$BUILD_DIR/.opensteamer-host-migration-controller.first"
BINARY="$BUILD_DIR/opensteamer-host-migration-controller"
[ ! -e "$BINARY_BUILD" ] && [ ! -L "$BINARY_BUILD" ] \
    && [ ! -e "$BINARY_FIRST" ] && [ ! -L "$BINARY_FIRST" ] \
    && [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] || {
    echo "private controller publication names are unexpectedly occupied" >&2
    exit 1
}

"$RUSTC" --edition=2021 -D warnings -C opt-level=2 "$SOURCE_COPY" -o "$BINARY_BUILD" || exit 1
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

"$RUSTC" --edition=2021 -D warnings -C opt-level=2 "$SOURCE_COPY" -o "$BINARY_BUILD" || exit 1
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
[ "$(/usr/bin/shasum -a 256 "$RUSTC" | /usr/bin/awk '{print $1}')" = "$EXPECTED_RUSTC_SHA256" ] || {
    echo "reviewed Rust compiler changed during compilation" >&2
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

OPENSTEAMER_MIGRATION_CONTROLLER_BINARY="$BINARY" \
OPENSTEAMER_MIGRATION_CONTROLLER_BINARY_SHA256="$BINARY_SHA" \
OPENSTEAMER_MIGRATION_CONTROLLER_SOURCE_SHA256="$SOURCE_SHA" \
OPENSTEAMER_MIGRATION_RUSTC_SHA256="$EXPECTED_RUSTC_SHA256" \
OPENSTEAMER_MIGRATION_RUSTC_CDHASH_FULL="$EXPECTED_RUSTC_CDHASH_FULL" \
    "$BINARY" "$AUTHORIZED_MODE" "$ROOT"
