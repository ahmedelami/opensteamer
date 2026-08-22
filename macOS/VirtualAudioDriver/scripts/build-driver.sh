#!/bin/zsh
set -euo pipefail

umask 022

if (( $# != 1 )); then
    print -u2 "usage: $0 /absolute/output/OpensteamerVirtualMicrophone.driver"
    exit 64
fi

requested_output="$1"
if [[ "$requested_output" != /* ]] || \
   [[ "${requested_output:t}" != "OpensteamerVirtualMicrophone.driver" ]]; then
    print -u2 "output must be an absolute path ending in OpensteamerVirtualMicrophone.driver"
    exit 64
fi
if [[ -e "$requested_output" || -L "$requested_output" ]]; then
    print -u2 "refusing to overwrite existing output: $requested_output"
    exit 73
fi

script_dir="${0:A:h}"
driver_root="${script_dir:h}"
output_parent="${requested_output:h}"
if [[ ! -d "$output_parent" ]] || [[ -L "$output_parent" ]]; then
    print -u2 "output parent must be an existing non-symlink directory"
    exit 73
fi

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
if [[ ! -d "$developer_dir" ]] || [[ ! -x /usr/bin/xcrun ]]; then
    print -u2 "pinned Xcode is unavailable: $developer_dir"
    exit 69
fi
sdk_path="$(DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

build_root="$(mktemp -d /private/tmp/opensteamer-virtual-audio-build.XXXXXX)"
cleanup() {
    /bin/rm -rf "$build_root"
}
trap cleanup EXIT INT TERM HUP

sources=(
    "$driver_root/Driver/OpensteamerVirtualMicrophone.c"
    "$driver_root/src/OpensteamerVirtualAudioCore.c"
)
for source in "${sources[@]}"; do
    if [[ ! -f "$source" ]] || [[ -L "$source" ]]; then
        print -u2 "required source is unavailable: $source"
        exit 66
    fi
done

for arch in arm64 x86_64; do
    DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx clang \
        -arch "$arch" \
        -isysroot "$sdk_path" \
        -mmacosx-version-min=14.0 \
        -std=c17 \
        -fblocks \
        -fvisibility=hidden \
        -fno-ident \
        -O2 \
        -DNDEBUG=1 \
        -Wall -Wextra -Werror -Wpedantic \
        -I "$driver_root/include" \
        "${sources[@]}" \
        -bundle \
        -framework CoreAudio \
        -framework CoreFoundation \
        -Wl,-exported_symbols_list,"$driver_root/Driver/OpensteamerVirtualMicrophone.exports" \
        -o "$build_root/OpensteamerVirtualMicrophone.$arch"
done

DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun lipo -create \
    "$build_root/OpensteamerVirtualMicrophone.arm64" \
    "$build_root/OpensteamerVirtualMicrophone.x86_64" \
    -output "$build_root/OpensteamerVirtualMicrophone"

bundle="$build_root/OpensteamerVirtualMicrophone.driver"
/bin/mkdir -p \
    "$bundle/Contents/MacOS" \
    "$bundle/Contents/Resources/en.lproj"
/usr/bin/install -m 0644 "$driver_root/Driver/Info.plist" \
    "$bundle/Contents/Info.plist"
/usr/bin/install -m 0755 "$build_root/OpensteamerVirtualMicrophone" \
    "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone"
/usr/bin/install -m 0644 "$driver_root/Resources/en.lproj/Localizable.strings" \
    "$bundle/Contents/Resources/en.lproj/Localizable.strings"
/usr/bin/install -m 0644 "$driver_root/APPLE_SAMPLE_LICENSE.txt" \
    "$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt"

/usr/bin/plutil -lint "$bundle/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none \
    --identifier com.elamin.opensteamer.VirtualMicrophoneDriver \
    "$bundle"
/bin/mv "$bundle" "$requested_output"
trap - EXIT INT TERM HUP
/bin/rm -rf "$build_root"

print "$requested_output"
