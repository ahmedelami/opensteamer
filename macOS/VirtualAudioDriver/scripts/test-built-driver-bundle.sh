#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 022

if (( $# > 1 )); then
    print -u2 "usage: $0 [/absolute/path/OpensteamerVirtualMicrophone.driver]"
    exit 64
fi

script_dir="${0:A:h}"
driver_root="${script_dir:h}"
builder="$script_dir/build-driver.sh"
verifier="$script_dir/verify-driver-bundle.sh"
loader_source="$driver_root/tests/OpensteamerVirtualMicrophoneBundleLoadTests.c"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"

test_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-driver-load-test.XXXXXX)"
test_root="${test_root:A}"
case "$test_root" in
    /private/tmp/opensteamer-driver-load-test.*)
        ;;
    *)
        print -u2 "unexpected driver load-test root: $test_root"
        exit 73
        ;;
esac
cleanup() {
    if [[ -d "$test_root" ]] && [[ ! -L "$test_root" ]]; then
        /bin/rm -rf -- "$test_root"
    fi
}
trap cleanup EXIT INT TERM HUP

if (( $# == 1 )); then
    bundle="$1"
    if [[ "$bundle" != /* ]] || \
       [[ "${bundle:t}" != "OpensteamerVirtualMicrophone.driver" ]] || \
       [[ ! -d "$bundle" ]] || [[ -L "$bundle" ]]; then
        print -u2 "expected an absolute, non-symlink OpensteamerVirtualMicrophone.driver"
        exit 66
    fi
else
    bundle="$test_root/OpensteamerVirtualMicrophone.driver"
    "$builder" "$bundle" >/dev/null
fi

"$verifier" "$bundle" >/dev/null
if [[ ! -d "$developer_dir" ]] || [[ ! -x /usr/bin/xcrun ]]; then
    print -u2 "pinned Xcode is unavailable: $developer_dir"
    exit 69
fi

loader="$test_root/OpensteamerVirtualMicrophoneBundleLoadTests"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx clang \
    -std=c17 -Wall -Wextra -Werror -Wpedantic \
    "$loader_source" \
    -framework CoreAudio -framework CoreFoundation \
    -o "$loader"
"$loader" "$bundle"
print "VERIFIED_BUILT_DRIVER_BUNDLE_LOAD"
