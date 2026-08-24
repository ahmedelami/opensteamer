#!/bin/zsh
set -euo pipefail

umask 022

if (( $# != 1 )); then
    print -u2 "usage: $0 /absolute/output/opensteamer-diagnostic-snapshot-reader"
    exit 64
fi

requested_output="$1"
if [[ "$requested_output" != /* ]] || \
   [[ "${requested_output:t}" != "opensteamer-diagnostic-snapshot-reader" ]]; then
    print -u2 "output must be an absolute path ending in opensteamer-diagnostic-snapshot-reader"
    exit 64
fi
if [[ -e "$requested_output" || -L "$requested_output" ]]; then
    print -u2 "refusing to overwrite existing output: $requested_output"
    exit 73
fi

output_parent="${requested_output:h}"
if [[ ! -d "$output_parent" ]] || [[ -L "$output_parent" ]]; then
    print -u2 "output parent must be an existing non-symlink directory"
    exit 73
fi

script_dir="${0:A:h}"
driver_root="${script_dir:h}"
source="$driver_root/Probes/DiagnosticSnapshotReader.c"
header="$driver_root/include/OpensteamerVirtualMicrophoneDriver.h"
for input in "$source" "$header"; do
    if [[ ! -f "$input" ]] || [[ -L "$input" ]]; then
        print -u2 "required diagnostic-reader input is unavailable: $input"
        exit 66
    fi
done

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
if [[ ! -d "$developer_dir" ]] || [[ ! -x /usr/bin/xcrun ]]; then
    print -u2 "pinned Xcode is unavailable: $developer_dir"
    exit 69
fi
sdk_path="$(DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

build_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-diagnostic-reader-build.XXXXXX)"
build_root="${build_root:A}"
case "$build_root" in
    /private/tmp/opensteamer-diagnostic-reader-build.*)
        ;;
    *)
        print -u2 "unexpected diagnostic-reader build root: $build_root"
        exit 73
        ;;
esac
cleanup() {
    if [[ -d "$build_root" ]] && [[ ! -L "$build_root" ]]; then
        /bin/rm -rf -- "$build_root"
    fi
}
trap cleanup EXIT INT TERM HUP

for arch in arm64 x86_64; do
    DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx clang \
        -arch "$arch" \
        -isysroot "$sdk_path" \
        -mmacosx-version-min=14.0 \
        -std=c17 \
        -O2 \
        -DNDEBUG=1 \
        -fno-ident \
        -Wall -Wextra -Werror -Wpedantic \
        -Wconversion -Wsign-conversion -Wshadow \
        -Wstrict-prototypes -Wmissing-prototypes \
        -I "$driver_root/include" \
        "$source" \
        -framework CoreAudio \
        -framework CoreFoundation \
        -o "$build_root/opensteamer-diagnostic-snapshot-reader.$arch"
done

DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun lipo -create \
    "$build_root/opensteamer-diagnostic-snapshot-reader.arm64" \
    "$build_root/opensteamer-diagnostic-snapshot-reader.x86_64" \
    -output "$build_root/opensteamer-diagnostic-snapshot-reader"
/usr/bin/codesign --force --sign - --timestamp=none \
    --identifier com.elamin.opensteamer.DiagnosticSnapshotReader \
    "$build_root/opensteamer-diagnostic-snapshot-reader" >/dev/null 2>&1
/usr/bin/install -m 0755 \
    "$build_root/opensteamer-diagnostic-snapshot-reader" "$requested_output"

archs="$(/usr/bin/lipo -archs "$requested_output")"
if [[ " $archs " != *" arm64 "* ]] || \
   [[ " $archs " != *" x86_64 "* ]] || \
   (( ${#${(z)archs}} != 2 )); then
    print -u2 "diagnostic reader does not contain the exact universal architecture set"
    exit 65
fi
/usr/bin/codesign --verify --strict --all-architectures "$requested_output"

for arch in arm64 x86_64; do
    build_version="$(/usr/bin/vtool -arch "$arch" -show-build "$requested_output")"
    summary="$(/usr/bin/awk '
        $1 == "platform" && $2 == "MACOS" { platform++ }
        $1 == "minos" && $2 == "14.0" { minos++ }
        END { print (platform + 0) ":" (minos + 0) }
    ' <<< "$build_version")"
    if [[ "$summary" != "1:1" ]]; then
        print -u2 "$arch diagnostic-reader slice does not have exact macOS minOS 14.0"
        exit 65
    fi
    entitlements="$(/usr/bin/codesign -d -a "$arch" --entitlements :- \
        "$requested_output" 2>/dev/null)"
    if [[ -n "$entitlements" ]]; then
        print -u2 "$arch diagnostic-reader slice unexpectedly contains entitlements"
        exit 65
    fi
done

load_commands="$(/usr/bin/otool -l "$requested_output")"
if /usr/bin/awk '$1 == "cmd" && $2 == "LC_RPATH" {
        found = 1
    } END { exit found ? 0 : 1 }' <<< "$load_commands"; then
    print -u2 "diagnostic reader contains a forbidden LC_RPATH"
    exit 65
fi

trap - EXIT INT TERM HUP
/bin/rm -rf -- "$build_root"
print "$requested_output"
