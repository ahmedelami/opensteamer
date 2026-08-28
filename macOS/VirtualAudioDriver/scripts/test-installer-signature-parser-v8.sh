#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077

script_dir="${0:A:h}"
parser="$script_dir/parse-installer-signature-v8.sh"
test_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-installer-parser-v8.XXXXXX)"
case "$test_root" in
    /private/tmp/opensteamer-installer-parser-v8.*) ;;
    *) exit 73 ;;
esac
trap '/bin/rm -rf -- "$test_root"' EXIT INT TERM HUP

fingerprint="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
write_fixture() {
    local path="$1"
    local status_text="$2"
    local identity="$3"
    local label="$4"
    local value="$5"
    {
        print -r -- "Package fixture:"
        print -r -- "   Status: $status_text"
        print -r -- "   Certificate Chain:"
        print -r -- "    1. $identity"
        print -r -- "       $label"
        print -r -- "           $value"
        print -r -- "    2. Developer ID Certification Authority"
    } >"$path"
}

healthy="$test_root/healthy.txt"
write_fixture "$healthy" \
    "signed by a developer certificate issued by Apple for distribution" \
    "Developer ID Installer: Example (MSMG8CJLB3)" \
    "SHA256 Fingerprint:" \
    "${fingerprint[1,32]} ${fingerprint[33,64]}"
[[ "$($parser "$healthy" MSMG8CJLB3)" == "$fingerprint" ]] || exit 1

mutants=(
    wrong-status
    legacy-status
    status-suffix
    duplicate-status
    wrong-team
    wrong-identity
    missing-label
    short-hash
    duplicate-leaf
)
for mutant in "${mutants[@]}"; do
    fixture="$test_root/$mutant.txt"
    case "$mutant" in
        wrong-status)
            write_fixture "$fixture" "unsigned" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "$fingerprint"
            ;;
        legacy-status)
            write_fixture "$fixture" "signed by a certificate trusted by Mac OS X" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "$fingerprint"
            ;;
        status-suffix)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution (trusted)" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "$fingerprint"
            ;;
        duplicate-status)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "$fingerprint"
            print -r -- "   Status: signed by a developer certificate issued by Apple for distribution" >>"$fixture"
            ;;
        wrong-team)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution" "Developer ID Installer: Example (AAAAAAAAAA)" "SHA256 Fingerprint:" "$fingerprint"
            ;;
        wrong-identity)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution" "Developer ID Application: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "$fingerprint"
            ;;
        missing-label)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA1 Fingerprint:" "$fingerprint"
            ;;
        short-hash)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "01234567"
            ;;
        duplicate-leaf)
            write_fixture "$fixture" "signed by a developer certificate issued by Apple for distribution" "Developer ID Installer: Example (MSMG8CJLB3)" "SHA256 Fingerprint:" "$fingerprint"
            print -r -- "    1. Developer ID Installer: Duplicate (MSMG8CJLB3)" >>"$fixture"
            ;;
    esac
    if "$parser" "$fixture" MSMG8CJLB3 >/dev/null 2>&1; then
        print -u2 "installer signature parser accepted mutant: $mutant"
        exit 1
    fi
done

print "PASS installer leaf SHA-256 parser rejected ${#mutants} mutants"
