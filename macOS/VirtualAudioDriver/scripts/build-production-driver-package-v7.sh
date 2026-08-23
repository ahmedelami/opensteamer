#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077

fail() {
    print -u2 -- "$1"
    exit 65
}

if (( $# != 8 )); then
    print -u2 "usage: $0 reviewed-candidate output-root app-cert-sha1 installer-leaf-sha256 bundle-tree-sha256 executable-sha256 package-sha256 expected-candidate-manifest-sha256"
    exit 64
fi

candidate="$1"
output_root="$2"
app_certificate_sha1="$3"
installer_leaf_sha256="$4"
tree_sha256="$5"
executable_sha256="$6"
package_sha256="$7"
candidate_manifest_sha256="$8"

[[ "$candidate" == /* ]] && [[ -d "$candidate" ]] && [[ ! -L "$candidate" ]] || \
    fail "reviewed production candidate root is unavailable"
[[ "$output_root" == /* ]] && [[ "${output_root:t}" == "production-driver-v7" ]] \
    && [[ ! -e "$output_root" ]] && [[ ! -L "$output_root" ]] || \
    fail "strict output root must be absent and end in production-driver-v7"
[[ "$candidate_manifest_sha256" =~ '^[0-9a-f]{64}$' ]] || \
    fail "candidate manifest SHA-256 pin is malformed"

script_dir="${0:A:h}"
verifier="$script_dir/verify-production-driver-package-v7.sh"
candidate_bundle="$candidate/OpensteamerVirtualMicrophone.driver"
candidate_package="$candidate/OpensteamerVirtualMicrophone-v7.pkg"
candidate_manifest="$candidate/candidate-manifest.txt"
[[ "$(/usr/bin/shasum -a 256 "$candidate_manifest" | /usr/bin/awk '{print $1}')" \
    == "$candidate_manifest_sha256" ]] || \
    fail "reviewed production candidate manifest changed"

"$verifier" \
    "$candidate_bundle" "$candidate_package" \
    "$app_certificate_sha1" "$installer_leaf_sha256" \
    "$tree_sha256" "$executable_sha256" "$package_sha256" \
    >/dev/null

/bin/mkdir -m 0700 "$output_root"
output_bundle="$output_root/OpensteamerVirtualMicrophone.driver"
output_package="$output_root/OpensteamerVirtualMicrophone-v7.pkg"
/usr/bin/ditto --noqtn "$candidate_bundle" "$output_bundle"
/usr/bin/install -m 0600 "$candidate_package" "$output_package"
/usr/bin/install -m 0400 "$candidate_manifest" "$output_root/candidate-manifest.txt"
"$verifier" \
    "$output_bundle" "$output_package" \
    "$app_certificate_sha1" "$installer_leaf_sha256" \
    "$tree_sha256" "$executable_sha256" "$package_sha256" \
    >"$output_root/verification.txt"
/bin/chmod 0400 "$output_root/verification.txt"

print "$output_root"
