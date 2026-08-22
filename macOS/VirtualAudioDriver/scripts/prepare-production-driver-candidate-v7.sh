#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077

fail() {
    print -u2 -- "$1"
    exit 65
}

usage() {
    print -u2 "usage: $0 output-root app-cert-sha1 installer-cert-sha1 notary-profile"
    exit 64
}

(( $# == 4 )) || usage
output_root="$1"
app_certificate_sha1="${2:u}"
installer_certificate_sha1="${3:u}"
notary_profile="$4"

[[ "$output_root" == /* ]] && [[ "${output_root:t}" == "production-driver-v7" ]] || \
    fail "output root must be an absolute path ending in production-driver-v7"
[[ ! -e "$output_root" ]] && [[ ! -L "$output_root" ]] || \
    fail "refusing to overwrite production driver output root"
[[ "$app_certificate_sha1" =~ '^[0-9A-F]{40}$' ]] || \
    fail "Developer ID Application SHA-1 is malformed"
[[ "$installer_certificate_sha1" =~ '^[0-9A-F]{40}$' ]] || \
    fail "Developer ID Installer SHA-1 is malformed"
[[ "$notary_profile" =~ '^[A-Za-z0-9._-]{1,128}$' ]] || \
    fail "notary keychain profile name is malformed"

script_dir="${0:A:h}"
driver_root="${script_dir:h}"
repo="${driver_root:h:h}"
[[ "$repo" == "/Users/ahmed/Documents/Codex/opensteamer" ]] || \
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
production_verifier="$script_dir/verify-production-driver-package-v7.sh"
installer_signature_parser="$script_dir/parse-installer-signature-v7.sh"
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

build_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-production-driver-v7.XXXXXX)"
case "$build_root" in
    /private/tmp/opensteamer-production-driver-v7.*) ;;
    *) fail "unsafe production driver build root" ;;
esac
cleanup() {
    if [[ -d "$build_root" ]] && [[ ! -L "$build_root" ]]; then
        /bin/rm -rf -- "$build_root"
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

unsigned_package="$build_root/OpensteamerVirtualMicrophone-v7.unsigned.pkg"
signed_package="$build_root/OpensteamerVirtualMicrophone-v7.pkg"
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

/bin/mkdir -m 0700 "$output_root"
final_bundle="$output_root/OpensteamerVirtualMicrophone.driver"
final_package="$output_root/OpensteamerVirtualMicrophone-v7.pkg"
final_notary_record="$output_root/notary-result.json"
/usr/bin/ditto --noqtn "$production_bundle" "$final_bundle"
/usr/bin/install -m 0600 "$signed_package" "$final_package"
/usr/bin/install -m 0600 "$notary_record" "$final_notary_record"

expected_regular_files=(
    "Contents/Info.plist"
    "Contents/MacOS/OpensteamerVirtualMicrophone"
    "Contents/Resources/APPLE_SAMPLE_LICENSE.txt"
    "Contents/Resources/en.lproj/Localizable.strings"
    "Contents/_CodeSignature/CodeResources"
)
actual_tree_sha256="$(
    {
        while IFS= read -r -d '' relative; do
            if [[ "$relative" == "." ]]; then
                display="."
                absolute="$final_bundle"
            else
                display="${relative#./}"
                absolute="$final_bundle/$display"
            fi
            /usr/bin/printf '%s|%s\0' \
                "$(/usr/bin/stat -f '%HT|%Lp' "$absolute")" "$display"
        done < <(cd "$final_bundle" && /usr/bin/find -s . -print0)
        for relative in "${expected_regular_files[@]}"; do
            digest="$(/usr/bin/shasum -a 256 "$final_bundle/$relative" | /usr/bin/awk '{print $1}')"
            /usr/bin/printf '%s\0%s\0' "$relative" "$digest"
        done
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)"
actual_executable_sha256="$(/usr/bin/shasum -a 256 "$final_bundle/Contents/MacOS/OpensteamerVirtualMicrophone" | /usr/bin/awk '{print $1}')"
actual_package_sha256="$(/usr/bin/shasum -a 256 "$final_package" | /usr/bin/awk '{print $1}')"

package_signature_path="$build_root/package-signature.txt"
/usr/sbin/pkgutil --check-signature "$final_package" >"$package_signature_path" 2>&1 || \
    fail "unable to inspect candidate installer signature"
installer_leaf_sha256="$($installer_signature_parser "$package_signature_path" MSMG8CJLB3)"
[[ "$installer_leaf_sha256" =~ '^[0-9A-F]{64}$' ]] || \
    fail "candidate installer leaf SHA-256 could not be extracted"

"$production_verifier" \
    "$final_bundle" \
    "$final_package" \
    "$app_certificate_sha1" \
    "$installer_leaf_sha256" \
    "$actual_tree_sha256" \
    "$actual_executable_sha256" \
    "$actual_package_sha256" \
    >"$output_root/verification.txt"
/bin/chmod 0600 "$output_root/verification.txt"

notary_submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["id"])' "$final_notary_record")"
manifest="$output_root/candidate-manifest.txt"
{
    print -r -- "schema=opensteamer.production-driver-candidate.v7"
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
/bin/chmod 0400 "$manifest" "$final_notary_record" "$output_root/verification.txt"
/bin/chmod 0500 "$output_root"

print "$output_root"
