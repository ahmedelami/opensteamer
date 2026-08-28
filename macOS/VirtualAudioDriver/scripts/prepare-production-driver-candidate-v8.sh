#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077
script_path="${0:A}"

fail() {
    print -u2 -- "$1"
    exit 65
}

usage() {
    print -u2 "usage: $0 output-root app-cert-sha1 installer-cert-sha1 notary-profile"
    print -u2 "       $0 --self-test-candidate-publication-v8"
    exit 64
}

atomic_publish_candidate() {
    (( $# == 5 )) || return 64
    /usr/bin/python3 - "$@" <<'PY'
import ctypes
import os
import stat
import sys

parent, staging_leaf, output_leaf, expected_parent, expected_staging = sys.argv[1:]
if "/" in staging_leaf or "/" in output_leaf:
    raise SystemExit("candidate publication leaf is malformed")

parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    parent_stat = os.fstat(parent_fd)
    observed_parent = (
        f"{parent_stat.st_dev}:{parent_stat.st_ino}:"
        f"{parent_stat.st_uid}:{stat.S_IMODE(parent_stat.st_mode):o}"
    )
    if observed_parent != expected_parent:
        raise SystemExit("candidate output parent identity changed")
    staging_stat = os.stat(staging_leaf, dir_fd=parent_fd, follow_symlinks=False)
    observed_staging = (
        f"{staging_stat.st_dev}:{staging_stat.st_ino}:"
        f"{staging_stat.st_uid}:{stat.S_IMODE(staging_stat.st_mode):o}"
    )
    if observed_staging != expected_staging or not stat.S_ISDIR(staging_stat.st_mode):
        raise SystemExit("candidate staging identity changed")

    staging_path = os.path.join(parent, staging_leaf)
    directories = []
    for current, names, files in os.walk(staging_path, topdown=False, followlinks=False):
        directories.append(current)
        for name in names:
            child = os.path.join(current, name)
            if not stat.S_ISDIR(os.lstat(child).st_mode):
                raise SystemExit("candidate staging tree contains a non-directory child")
        for name in files:
            child = os.path.join(current, name)
            if not stat.S_ISREG(os.lstat(child).st_mode):
                raise SystemExit("candidate staging tree contains a non-regular file")
            child_fd = os.open(child, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(child_fd)
            finally:
                os.close(child_fd)
    for directory in directories:
        directory_fd = os.open(
            directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        )
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    os.fsync(parent_fd)

    libc = ctypes.CDLL(None, use_errno=True)
    renameatx_np = libc.renameatx_np
    renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx_np.restype = ctypes.c_int
    rename_excl = 0x00000004
    result = renameatx_np(
        parent_fd,
        os.fsencode(staging_leaf),
        parent_fd,
        os.fsencode(output_leaf),
        rename_excl,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), output_leaf)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

publication_self_test_root=""
cleanup_publication_self_test() {
    [[ -n "$publication_self_test_root" ]] || return 0
    case "$publication_self_test_root" in
        /private/tmp/opensteamer-candidate-publication-v8.*) ;;
        *) return 73 ;;
    esac
    if [[ -d "$publication_self_test_root" ]] && [[ ! -L "$publication_self_test_root" ]]; then
        /usr/bin/find "$publication_self_test_root" -type d -exec /bin/chmod 0700 {} +
        /bin/rm -rf -- "$publication_self_test_root"
    fi
}

verify_publication_source_contract() {
    /usr/bin/python3 - "$script_path" <<'PY'
import sys

text = open(sys.argv[1], "r", encoding="utf-8").read()
marker = '\n(( $# == 4 )) || usage\n'
if text.count(marker) != 1:
    raise SystemExit("candidate preparer main marker is not unique")
main = text.split(marker, 1)[1]
ordered = [
    '[[ ! -e "$output_root" ]] && [[ ! -L "$output_root" ]]',
    'prepublication_verification="$build_root/verification.txt"',
    'manifest="$build_root/candidate-manifest.txt"',
    'staging_root="$(/usr/bin/mktemp -d "$output_parent/.production-driver-v8.stage.XXXXXX")"',
    'final_verification="$staging_root/verification.txt"',
    '>"$final_verification"',
    'expected_top_level="$(',
    '/bin/chmod 0500 "$staging_root"',
    'atomic_publish_candidate',
    'staging_root=""',
    'published production driver candidate identity is not exact',
]
position = -1
for token in ordered:
    found = main.find(token, position + 1)
    if found < 0:
        raise SystemExit(f"candidate preparer publication contract is missing: {token}")
    position = found
for forbidden in [
    '/bin/mkdir -m 0700 "$output_root"',
    '/usr/bin/ditto --noqtn "$production_bundle" "$output_root',
    '/bin/mv "$staging_root" "$output_root"',
]:
    if forbidden in main:
        raise SystemExit(f"candidate preparer exposes a partial or clobbering publication: {forbidden}")
if main.count("atomic_publish_candidate") != 1:
    raise SystemExit("candidate preparer atomic publication call is not unique")
PY
}

publication_self_test() {
    local test_root parent canonical staging parent_identity staging_identity
    local collision_parent collision_staging collision_identity collision_marker
    local symlink_parent symlink_staging symlink_identity identity_parent identity_staging
    test_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-candidate-publication-v8.XXXXXX)"
    case "$test_root" in
        /private/tmp/opensteamer-candidate-publication-v8.*) ;;
        *) fail "unsafe candidate publication self-test root" ;;
    esac
    publication_self_test_root="$test_root"
    trap cleanup_publication_self_test EXIT INT TERM HUP
    verify_publication_source_contract || \
        fail "candidate publication source integration contract failed"

    parent="$test_root/success"
    /bin/mkdir -m 0700 "$parent"
    canonical="$parent/production-driver-v8"
    staging="$parent/.production-driver-v8.stage.success"
    /bin/mkdir -m 0700 "$staging"
    /bin/mkdir -m 0755 "$staging/bundle"
    print -rn -- "candidate-bytes" >"$staging/bundle/payload" || \
        fail "unable to write candidate publication success fixture"
    /bin/chmod 0400 "$staging/bundle/payload"
    /bin/chmod 0500 "$staging"
    [[ ! -e "$canonical" ]] && [[ ! -L "$canonical" ]] || \
        fail "candidate publication self-test canonical unexpectedly exists"
    parent_identity="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$parent")"
    staging_identity="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$staging")"
    atomic_publish_candidate \
        "$parent" "${staging:t}" "${canonical:t}" "$parent_identity" "$staging_identity" || \
        fail "candidate publication self-test rejected a complete staging root"
    [[ ! -e "$staging" ]] && [[ ! -L "$staging" ]] && \
        [[ "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$canonical")" == "$staging_identity" ]] && \
        [[ "$(/usr/bin/stat -f '%HT:%Lp' "$canonical/bundle/payload")" == "Regular File:400" ]] && \
        [[ "$(<"$canonical/bundle/payload")" == "candidate-bytes" ]] || \
        fail "candidate publication self-test changed the complete staged tree"

    collision_parent="$test_root/collision"
    /bin/mkdir -m 0700 "$collision_parent"
    /bin/mkdir -m 0700 "$collision_parent/production-driver-v8"
    collision_marker="$collision_parent/production-driver-v8/existing"
    print -rn -- "existing-destination" >"$collision_marker" || \
        fail "unable to write candidate publication collision fixture"
    /bin/chmod 0400 "$collision_marker"
    collision_staging="$collision_parent/.production-driver-v8.stage.collision"
    /bin/mkdir -m 0700 "$collision_staging"
    collision_identity="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$collision_staging")"
    if atomic_publish_candidate \
        "$collision_parent" "${collision_staging:t}" "production-driver-v8" \
        "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$collision_parent")" "$collision_identity" \
        >/dev/null 2>&1; then
        fail "candidate publication self-test overwrote a preexisting destination"
    fi
    [[ -d "$collision_staging" ]] && \
        [[ "$(<"$collision_marker")" == "existing-destination" ]] || \
        fail "candidate publication self-test changed a preexisting destination"

    symlink_parent="$test_root/symlink"
    /bin/mkdir -m 0700 "$symlink_parent"
    symlink_staging="$symlink_parent/.production-driver-v8.stage.symlink"
    /bin/mkdir -m 0700 "$symlink_staging"
    /bin/ln -s /private/tmp "$symlink_staging/redirect"
    /bin/chmod 0500 "$symlink_staging"
    symlink_identity="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$symlink_staging")"
    if atomic_publish_candidate \
        "$symlink_parent" "${symlink_staging:t}" "production-driver-v8" \
        "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$symlink_parent")" "$symlink_identity" \
        >/dev/null 2>&1; then
        fail "candidate publication self-test accepted a staged symlink"
    fi
    [[ ! -e "$symlink_parent/production-driver-v8" ]] && \
        [[ ! -L "$symlink_parent/production-driver-v8" ]] || \
        fail "candidate publication self-test published the staged symlink mutant"

    identity_parent="$test_root/identity"
    /bin/mkdir -m 0700 "$identity_parent"
    identity_staging="$identity_parent/.production-driver-v8.stage.identity"
    /bin/mkdir -m 0700 "$identity_staging"
    if atomic_publish_candidate \
        "$identity_parent" "${identity_staging:t}" "production-driver-v8" \
        "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$identity_parent")" \
        "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$identity_staging")-mutant" \
        >/dev/null 2>&1; then
        fail "candidate publication self-test accepted a changed staging identity"
    fi
    [[ ! -e "$identity_parent/production-driver-v8" ]] && \
        [[ ! -L "$identity_parent/production-driver-v8" ]] || \
        fail "candidate publication self-test published the identity mutant"

    print "PASS atomic no-clobber candidate publication rejected collision, symlink, and identity mutants"
    cleanup_publication_self_test
    publication_self_test_root=""
    trap - EXIT INT TERM HUP
}

if (( $# == 1 )) && [[ "$1" == "--self-test-candidate-publication-v8" ]]; then
    publication_self_test
    exit 0
fi

(( $# == 4 )) || usage
output_root="$1"
app_certificate_sha1="${2:u}"
installer_certificate_sha1="${3:u}"
notary_profile="$4"

[[ "$output_root" == /* ]] && [[ "${output_root:t}" == "production-driver-v8" ]] || \
    fail "output root must be an absolute path ending in production-driver-v8"
[[ ! -e "$output_root" ]] && [[ ! -L "$output_root" ]] || \
    fail "refusing to overwrite production driver output root"
output_parent="${output_root:h}"
[[ -d "$output_parent" ]] && [[ ! -L "$output_parent" ]] || \
    fail "production driver output parent must be an existing non-symlink directory"
[[ "${output_parent:A}" == "$output_parent" ]] || \
    fail "production driver output parent must be canonical"
output_parent_owner_mode="$(/usr/bin/stat -f '%u:%Lp' "$output_parent")" || \
    fail "unable to inspect production driver output parent"
[[ "$output_parent_owner_mode" == "$(/usr/bin/id -u):700" ]] || \
    fail "production driver output parent must be current-user-owned mode 0700"
output_parent_identity="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$output_parent")" || \
    fail "unable to bind production driver output parent"
[[ "$app_certificate_sha1" =~ '^[0-9A-F]{40}$' ]] || \
    fail "Developer ID Application SHA-1 is malformed"
[[ "$installer_certificate_sha1" =~ '^[0-9A-F]{40}$' ]] || \
    fail "Developer ID Installer SHA-1 is malformed"
[[ "$notary_profile" =~ '^[A-Za-z0-9._-]{1,128}$' ]] || \
    fail "notary keychain profile name is malformed"

script_dir="${0:A:h}"
driver_root="${script_dir:h}"
repo="${driver_root:h:h}"
[[ "$repo" == "/Users/ahmed/Documents/Codex/opensteamer-diagnostic-v3" ]] || \
    fail "candidate preparation must run from the canonical repository"
git_status="$(/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all)" || \
    fail "unable to inspect candidate source worktree"
[[ -z "$git_status" ]] || fail "candidate source worktree must be completely clean"
source_commit="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
source_tree="$(/usr/bin/git -C "$repo" rev-parse 'HEAD^{tree}')"
source_branch="$(/usr/bin/git -C "$repo" symbolic-ref --quiet --short HEAD)" || \
    fail "candidate source must be on a named branch"
remote_url="$(/usr/bin/git -C "$repo" config --get remote.origin.url)"
[[ "$remote_url" == "https://github.com/ahmedelami/opensteamer.git" ]] || \
    fail "candidate source remote is not exact"
remote_commit="$(/usr/bin/git -C "$repo" ls-remote --exit-code origin "refs/heads/$source_branch" | /usr/bin/awk 'NF == 2 { print $1 }')" || \
    fail "unable to prove candidate source pushed"
[[ "$remote_commit" == "$source_commit" ]] || \
    fail "candidate source commit is not the exact pushed branch tip"

local_builder="$script_dir/build-driver.sh"
local_verifier="$script_dir/verify-driver-bundle.sh"
production_verifier="$script_dir/verify-production-driver-package-v8.sh"
installer_signature_parser="$script_dir/parse-installer-signature-v8.sh"
for tool in "$local_builder" "$local_verifier" "$production_verifier" \
    "$installer_signature_parser"; do
    [[ -f "$tool" ]] && [[ ! -L "$tool" ]] && [[ -x "$tool" ]] || \
        fail "required driver tool is unavailable: $tool"
done

identity_output="$(/usr/bin/security find-identity -v 2>/dev/null)" || \
    fail "unable to enumerate signing identities"
app_matches="$(/usr/bin/awk -v hash="$app_certificate_sha1" '
    index($0, hash) && index($0, "Developer ID Application:") && index($0, "(MSMG8CJLB3)") { count++ }
    END { print count + 0 }
' <<< "$identity_output")"
installer_matches="$(/usr/bin/awk -v hash="$installer_certificate_sha1" '
    index($0, hash) && index($0, "Developer ID Installer:") && index($0, "(MSMG8CJLB3)") { count++ }
    END { print count + 0 }
' <<< "$identity_output")"
[[ "$app_matches" == "1" ]] || fail "exact Developer ID Application identity is unavailable"
[[ "$installer_matches" == "1" ]] || fail "exact Developer ID Installer identity is unavailable"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
[[ -d "$developer_dir" ]] && [[ ! -L "$developer_dir" ]] || \
    fail "pinned Xcode developer directory is unavailable"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun notarytool history \
    --keychain-profile "$notary_profile" --output-format json >/dev/null || \
    fail "notarytool keychain profile is unavailable or unauthorized"

build_root=""
staging_root=""
build_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-production-driver-v8.XXXXXX)"
case "$build_root" in
    /private/tmp/opensteamer-production-driver-v8.*) ;;
    *) fail "unsafe production driver build root" ;;
esac
cleanup() {
    if [[ -d "$build_root" ]] && [[ ! -L "$build_root" ]]; then
        /bin/rm -rf -- "$build_root"
    fi
    if [[ -n "$staging_root" ]] && [[ -d "$staging_root" ]] && [[ ! -L "$staging_root" ]]; then
        case "$staging_root" in
            "$output_parent"/.production-driver-v8.stage.*)
                /bin/chmod 0700 "$staging_root"
                /bin/rm -rf -- "$staging_root"
                ;;
            *)
                print -u2 "refusing to clean unrecognized production driver staging root"
                ;;
        esac
    fi
}
trap cleanup EXIT INT TERM HUP

local_output="$build_root/local"
/bin/mkdir -m 0755 "$local_output"
local_bundle="$($local_builder "$local_output/OpensteamerVirtualMicrophone.driver")"
[[ "$local_bundle" == "$local_output/OpensteamerVirtualMicrophone.driver" ]] || \
    fail "local driver builder returned an unexpected path"
"$local_verifier" "$local_bundle" >"$build_root/local-verification.txt"

production_bundle="$build_root/OpensteamerVirtualMicrophone.driver"
/usr/bin/ditto --noqtn "$local_bundle" "$production_bundle"
/usr/bin/codesign --force \
    --sign "$app_certificate_sha1" \
    --identifier com.elamin.opensteamer.VirtualMicrophoneDriver \
    --options runtime \
    --timestamp \
    "$production_bundle" >/dev/null

payload_root="$build_root/payload-root"
payload_driver="$payload_root/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver"
/bin/mkdir -p "${payload_driver:h}"
/usr/bin/ditto --noqtn "$production_bundle" "$payload_driver"

unsigned_package="$build_root/OpensteamerVirtualMicrophone-v8.unsigned.pkg"
signed_package="$build_root/OpensteamerVirtualMicrophone-v8.pkg"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun pkgbuild \
    --root "$payload_root" \
    --install-location / \
    --identifier com.elamin.opensteamer.VirtualMicrophoneDriver.pkg \
    --version 0.1.0 \
    --ownership recommended \
    "$unsigned_package" >/dev/null
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun productsign \
    --sign "$installer_certificate_sha1" \
    --timestamp \
    "$unsigned_package" "$signed_package" >/dev/null

notary_record="$build_root/notary-result.json"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun notarytool submit "$signed_package" \
    --keychain-profile "$notary_profile" \
    --wait --output-format json >"$notary_record"
/usr/bin/python3 - "$notary_record" <<'PY' || fail "notary service did not accept the production driver package"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
if value.get("status") != "Accepted":
    raise SystemExit("notarization status is not Accepted")
submission_id = value.get("id")
if not isinstance(submission_id, str) or len(submission_id) != 36:
    raise SystemExit("notarization submission identifier is malformed")
PY
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun stapler staple -v "$signed_package" >/dev/null
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun stapler validate -v "$signed_package" >/dev/null

expected_regular_files=(
    "Contents/Info.plist"
    "Contents/MacOS/OpensteamerVirtualMicrophone"
    "Contents/Resources/APPLE_SAMPLE_LICENSE.txt"
    "Contents/Resources/en.lproj/Localizable.strings"
    "Contents/_CodeSignature/CodeResources"
)
bundle_tree_sha256() {
    local bundle="$1"
    {
        while IFS= read -r -d '' relative; do
            if [[ "$relative" == "." ]]; then
                display="."
                absolute="$bundle"
            else
                display="${relative#./}"
                absolute="$bundle/$display"
            fi
            /usr/bin/printf '%s|%s\0' \
                "$(/usr/bin/stat -f '%HT|%Lp' "$absolute")" "$display"
        done < <(cd "$bundle" && /usr/bin/find -s . -print0)
        for relative in "${expected_regular_files[@]}"; do
            digest="$(/usr/bin/shasum -a 256 "$bundle/$relative" | /usr/bin/awk '{print $1}')"
            /usr/bin/printf '%s\0%s\0' "$relative" "$digest"
        done
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

actual_tree_sha256="$(bundle_tree_sha256 "$production_bundle")"
actual_executable_sha256="$(/usr/bin/shasum -a 256 "$production_bundle/Contents/MacOS/OpensteamerVirtualMicrophone" | /usr/bin/awk '{print $1}')"
actual_package_sha256="$(/usr/bin/shasum -a 256 "$signed_package" | /usr/bin/awk '{print $1}')"

package_signature_path="$build_root/package-signature.txt"
/usr/sbin/pkgutil --check-signature "$signed_package" >"$package_signature_path" 2>&1 || \
    fail "unable to inspect candidate installer signature"
installer_leaf_sha256="$($installer_signature_parser "$package_signature_path" MSMG8CJLB3)"
[[ "$installer_leaf_sha256" =~ '^[0-9A-F]{64}$' ]] || \
    fail "candidate installer leaf SHA-256 could not be extracted"

prepublication_verification="$build_root/verification.txt"
"$production_verifier" \
    "$production_bundle" \
    "$signed_package" \
    "$app_certificate_sha1" \
    "$installer_leaf_sha256" \
    "$actual_tree_sha256" \
    "$actual_executable_sha256" \
    "$actual_package_sha256" \
    >"$prepublication_verification"
[[ -s "$prepublication_verification" ]] && [[ ! -L "$prepublication_verification" ]] || \
    fail "production driver verifier did not emit exact evidence"

notary_submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["id"])' "$notary_record")"
[[ "$notary_submission_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] || \
    fail "notary submission identifier is not exact"
manifest="$build_root/candidate-manifest.txt"
{
    print -r -- "schema=opensteamer.production-driver-candidate.v8"
    print -r -- "source_commit=$source_commit"
    print -r -- "source_tree=$source_tree"
    print -r -- "source_branch=$source_branch"
    print -r -- "remote=$remote_url"
    print -r -- "developer_id_application_sha1=$app_certificate_sha1"
    print -r -- "developer_id_installer_identity_sha1=$installer_certificate_sha1"
    print -r -- "developer_id_installer_leaf_sha256=$installer_leaf_sha256"
    print -r -- "bundle_tree_sha256=$actual_tree_sha256"
    print -r -- "executable_sha256=$actual_executable_sha256"
    print -r -- "package_sha256=$actual_package_sha256"
    print -r -- "notary_submission_id=$notary_submission_id"
} >"$manifest"

staging_root="$(/usr/bin/mktemp -d "$output_parent/.production-driver-v8.stage.XXXXXX")" || \
    fail "unable to create same-filesystem production driver staging root"
case "$staging_root" in
    "$output_parent"/.production-driver-v8.stage.*) ;;
    *) fail "unsafe production driver staging root" ;;
esac
[[ -d "$staging_root" ]] && [[ ! -L "$staging_root" ]] && \
    [[ "$(/usr/bin/stat -f '%u:%Lp' "$staging_root")" == "$(/usr/bin/id -u):700" ]] || \
    fail "production driver staging root identity is not exact"
[[ "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$output_parent")" == "$output_parent_identity" ]] || \
    fail "production driver output parent changed before staging"

final_bundle="$staging_root/OpensteamerVirtualMicrophone.driver"
final_package="$staging_root/OpensteamerVirtualMicrophone-v8.pkg"
final_notary_record="$staging_root/notary-result.json"
final_manifest="$staging_root/candidate-manifest.txt"
final_verification="$staging_root/verification.txt"
/usr/bin/ditto --noqtn "$production_bundle" "$final_bundle"
/usr/bin/install -m 0600 "$signed_package" "$final_package"
/usr/bin/install -m 0400 "$notary_record" "$final_notary_record"
/usr/bin/install -m 0400 "$manifest" "$final_manifest"

[[ "$(bundle_tree_sha256 "$final_bundle")" == "$actual_tree_sha256" ]] || \
    fail "staged production driver tree differs from its verified source"
[[ "$(/usr/bin/shasum -a 256 "$final_bundle/Contents/MacOS/OpensteamerVirtualMicrophone" | /usr/bin/awk '{print $1}')" == "$actual_executable_sha256" ]] || \
    fail "staged production driver executable differs from its verified source"
[[ "$(/usr/bin/shasum -a 256 "$final_package" | /usr/bin/awk '{print $1}')" == "$actual_package_sha256" ]] || \
    fail "staged production driver package differs from its verified source"
/usr/bin/cmp -s "$notary_record" "$final_notary_record" || \
    fail "staged notary record differs from its accepted source"
/usr/bin/cmp -s "$manifest" "$final_manifest" || \
    fail "staged candidate manifest differs from its validated source"

"$production_verifier" \
    "$final_bundle" \
    "$final_package" \
    "$app_certificate_sha1" \
    "$installer_leaf_sha256" \
    "$actual_tree_sha256" \
    "$actual_executable_sha256" \
    "$actual_package_sha256" \
    >"$final_verification"
/usr/bin/cmp -s "$prepublication_verification" "$final_verification" || \
    fail "staged production driver verification evidence is not reproducible"
/bin/chmod 0400 "$final_verification"

expected_top_level="$(
    print -r -l -- \
        "./OpensteamerVirtualMicrophone.driver" \
        "./OpensteamerVirtualMicrophone-v8.pkg" \
        "./candidate-manifest.txt" \
        "./notary-result.json" \
        "./verification.txt" | /usr/bin/sort
)"
actual_top_level="$(cd "$staging_root" && /usr/bin/find -s . -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)"
[[ "$actual_top_level" == "$expected_top_level" ]] || \
    fail "production driver staging root contains unexpected top-level nodes"
/bin/chmod 0500 "$staging_root"

staging_identity="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$staging_root")" || \
    fail "unable to bind complete production driver staging root"
staging_leaf="${staging_root:t}"
output_leaf="${output_root:t}"
atomic_publish_candidate \
    "$output_parent" \
    "$staging_leaf" \
    "$output_leaf" \
    "$output_parent_identity" \
    "$staging_identity" || fail "atomic no-clobber production driver publication failed"
staging_root=""
[[ -d "$output_root" ]] && [[ ! -L "$output_root" ]] && \
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$output_root")" == "$staging_identity" ]] || \
    fail "published production driver candidate identity is not exact"

print "$output_root"
