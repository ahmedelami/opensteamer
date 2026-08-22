#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 022

script_dir="${0:A:h}"
verifier="$script_dir/verify-driver-bundle.sh"
builder="$script_dir/build-driver.sh"
bundle_name="OpensteamerVirtualMicrophone.driver"
identifier="com.elamin.opensteamer.VirtualMicrophoneDriver"

if (( $# > 1 )); then
    print -u2 "usage: $0 [/absolute/path/OpensteamerVirtualMicrophone.driver]"
    exit 64
fi

test_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-driver-verifier-tests.XXXXXX)"
test_root="${test_root:A}"
case "$test_root" in
    /private/tmp/opensteamer-driver-verifier-tests.*)
        ;;
    *)
        print -u2 "unexpected verifier test root: $test_root"
        exit 73
        ;;
esac
cleanup() {
    if [[ -d "$test_root" ]] && [[ ! -L "$test_root" ]]; then
        /bin/rm -rf -- "$test_root"
    fi
}
trap cleanup EXIT INT TERM HUP

baseline="$test_root/baseline/$bundle_name"
/bin/mkdir -p "${baseline:h}"
if (( $# == 1 )); then
    source_bundle="$1"
    if [[ "$source_bundle" != /* ]] || \
       [[ "${source_bundle:t}" != "$bundle_name" ]] || \
       [[ ! -d "$source_bundle" ]] || [[ -L "$source_bundle" ]]; then
        print -u2 "expected an absolute, non-symlink $bundle_name bundle"
        exit 66
    fi
    /usr/bin/ditto "$source_bundle" "$baseline"
else
    "$builder" "$baseline" >/dev/null
fi

"$verifier" "$baseline" >/dev/null
print "PASS baseline"

resign() {
    local mutant="$1"
    shift
    /usr/bin/codesign --force --sign - --timestamp=none \
        --identifier "$identifier" "$@" "$mutant" >/dev/null 2>&1
}

expect_rejected() {
    local name="$1"
    local expected_diagnostic="$2"
    local mutant_root="$test_root/$name"
    local mutant="$mutant_root/$bundle_name"
    local log="$mutant_root/verifier.log"

    /bin/mkdir -p "$mutant_root"
    /usr/bin/ditto "$baseline" "$mutant"

    case "$name" in
        executable-mode-0644)
            /bin/chmod 0644 "$mutant/Contents/MacOS/OpensteamerVirtualMicrophone"
            ;;
        extra-empty-directory)
            /bin/mkdir "$mutant/Contents/UnexpectedEmptyDirectory"
            ;;
        extra-file)
            /usr/bin/touch "$mutant/Contents/UnexpectedFile"
            ;;
        extra-symlink)
            /bin/ln -s Info.plist "$mutant/Contents/UnexpectedSymlink"
            ;;
        extended-attribute)
            /usr/bin/xattr -w com.elamin.opensteamer.verifier-mutation present \
                "$mutant/Contents/Info.plist"
            ;;
        plist-extra-factory)
            /usr/libexec/PlistBuddy -c \
                "Add :CFPlugInFactories:00000000-0000-0000-0000-000000000001 string UnexpectedFactory" \
                "$mutant/Contents/Info.plist"
            resign "$mutant"
            ;;
        plist-extra-type)
            /usr/libexec/PlistBuddy -c \
                "Add :CFPlugInTypes:00000000-0000-0000-0000-000000000002 array" \
                "$mutant/Contents/Info.plist"
            /usr/libexec/PlistBuddy -c \
                "Add :CFPlugInTypes:00000000-0000-0000-0000-000000000002:0 string 81CE9D28-D187-499B-84EE-F6AC6159C800" \
                "$mutant/Contents/Info.plist"
            resign "$mutant"
            ;;
        plist-extra-root-key)
            /usr/libexec/PlistBuddy -c \
                "Add :UnexpectedVerifierMutation string present" \
                "$mutant/Contents/Info.plist"
            resign "$mutant"
            ;;
        entitlement)
            local entitlement_plist="$mutant_root/entitlements.plist"
            /usr/bin/plutil -create xml1 "$entitlement_plist"
            /usr/libexec/PlistBuddy -c \
                "Add :com.apple.security.get-task-allow bool true" \
                "$entitlement_plist"
            resign "$mutant" --entitlements "$entitlement_plist" \
                --generate-entitlement-der --force-library-entitlements
            ;;
        *)
            print -u2 "unknown verifier mutation: $name"
            exit 70
            ;;
    esac

    if "$verifier" "$mutant" >"$log" 2>&1; then
        print -u2 "verifier accepted mutation: $name"
        exit 1
    fi
    if ! /usr/bin/grep -Fq -- "$expected_diagnostic" "$log"; then
        print -u2 "mutation $name failed for an unexpected reason"
        /bin/cat "$log" >&2
        exit 1
    fi
    print "PASS reject $name"
}

expect_rejected executable-mode-0644 \
    "driver bundle lstat manifest is not exact"
expect_rejected extra-empty-directory \
    "driver bundle lstat manifest is not exact"
expect_rejected extra-file \
    "driver bundle lstat manifest is not exact"
expect_rejected extra-symlink \
    "driver bundle lstat manifest is not exact"
expect_rejected extended-attribute \
    "driver bundle must not contain extended attributes"
expect_rejected plist-extra-factory \
    "driver Info.plist contract is not exact"
expect_rejected plist-extra-type \
    "driver Info.plist contract is not exact"
expect_rejected plist-extra-root-key \
    "driver Info.plist contract is not exact"
expect_rejected entitlement \
    "driver slice must not contain entitlements"

print "ALL_DRIVER_BUNDLE_VERIFIER_MUTATIONS_REJECTED"
