#!/bin/zsh
# Audits a candidate public clone, including every reachable ref, before repository visibility is
# changed. Run this only from the sanitized clone: an operational/private clone can intentionally
# retain deployment identifiers and private backup refs that this gate rejects.
#
# Usage: `scripts/audit-public-release.sh [repository]`
#
# Environment:
# - PUBLIC_RELEASE_BLOCKLIST_FILE: optional newline-delimited literal values known to be private.
#   The file must live outside the repository. Matches are reported without printing the value.
# - PUBLIC_RELEASE_ALLOWED_EMAIL_REGEX: allowed author/committer email pattern. The default accepts
#   only non-identifying project and GitHub noreply addresses.
# - GITLEAKS_BIN: optional path to the Gitleaks executable; otherwise it is resolved from `PATH`.
set -eu

REPOSITORY=${1:-.}
ALLOWED_EMAIL_REGEX=${PUBLIC_RELEASE_ALLOWED_EMAIL_REGEX:-'^(audiostreamer@users\.noreply\.github\.com|[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com)$'}
GITLEAKS=${GITLEAKS_BIN:-$(command -v gitleaks || true)}

cd "$REPOSITORY"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

fail() {
    print -u2 -- "public-release audit failed: $1"
    exit 1
}

[[ -z $(git status --porcelain) ]] || fail "the candidate worktree is not clean"
[[ -n "$GITLEAKS" && -x "$GITLEAKS" ]] || fail "Gitleaks is required for the release gate"

# Public history must contain only intentional branch/tag refs. In particular, Jujutsu keep refs
# can retain archives and device-validation artifacts that are unrelated to the release history.
UNEXPECTED_REFS=$(git for-each-ref --format='%(refname)' \
    | grep -Ev '^refs/(heads|tags)/' || true)
[[ -z "$UNEXPECTED_REFS" ]] || fail "unexpected refs are reachable"

SENSITIVE_TRACKED_FILES=$(git ls-files | grep -Ei \
    '(^|/)(\.env($|\.)|\.dev\.vars($|\.)|\.npmrc$|\.netrc$|credentials\.json$|secrets\.(json|ya?ml)$|id_(rsa|ed25519)($|\.)|[^/]*Secrets\.xcconfig$|[^/]*\.xcconfig\.local$)|\.(p8|p12|pfx|pem|key|cer|crt|der|csr|jks|keystore|mobileprovision|provisionprofile|xcarchive)(/|$)' \
    || true)
[[ -z "$SENSITIVE_TRACKED_FILES" ]] || fail "credential or signing-artifact filenames are tracked"

LARGE_BLOBS=$(git rev-list --objects --all \
    | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' \
    | awk '$2 == "blob" && $3 > 5242880 { print $1 }')
[[ -z "$LARGE_BLOBS" ]] || fail "a reachable tracked blob exceeds the 5 MiB source limit"

UNEXPECTED_BINARIES=$(git ls-files -z \
    | xargs -0 file --mime-type \
    | grep -E ': (application/octet-stream|application/x-mach-binary|application/zip)$' \
    | grep -Ev 'iOS/AudioStreamer/Sources/Assets\.xcassets/.+\.png:' || true)
[[ -z "$UNEXPECTED_BINARIES" ]] || fail "an unexpected binary artifact is tracked"

# Absolute home paths disclose local account names and usually make scripts non-portable.
if git grep -I -n -E '/Users/[^/$({<]+' -- ':!scripts/audit-public-release.sh' >/dev/null; then
    fail "an absolute macOS home path remains in the candidate tree"
fi

BAD_EMAILS=$(git log --all --format='%ae%n%ce' | sort -u \
    | grep -Ev "$ALLOWED_EMAIL_REGEX" || true)
[[ -z "$BAD_EMAILS" ]] || fail "identifying or unapproved commit email metadata remains"

if [[ -n "${PUBLIC_RELEASE_BLOCKLIST_FILE:-}" ]]; then
    [[ -f "$PUBLIC_RELEASE_BLOCKLIST_FILE" ]] \
        || fail "PUBLIC_RELEASE_BLOCKLIST_FILE is not a readable file"
    while IFS= read -r forbidden || [[ -n "$forbidden" ]]; do
        [[ -z "$forbidden" ]] && continue
        if git grep -I -F -q -- "$forbidden"; then
            fail "a blocklisted literal remains in the candidate tree"
        fi
        if git log --all -S "$forbidden" --format='%H' --all -- . | grep -q .; then
            fail "a blocklisted literal remains in reachable history"
        fi
    done < "$PUBLIC_RELEASE_BLOCKLIST_FILE"
fi

# Search commit patches as well as the current tree for local home paths. `-G` catches a value that
# was introduced and later removed, which a tip-only scanner cannot see.
if git log --all -G '/Users/[^/[:space:]]+' --format='%H' -- . | grep -q .; then
    fail "an absolute macOS home path remains in reachable history"
fi

# Gitleaks supplies the broad credential-pattern oracle; the external blocklist above covers
# project-specific capabilities that do not resemble a vendor API key.
"$GITLEAKS" dir --no-banner --redact --config .gitleaks.toml . >/dev/null \
    || fail "Gitleaks found a credential pattern in the candidate tree"
"$GITLEAKS" git --no-banner --redact --config .gitleaks.toml . >/dev/null \
    || fail "Gitleaks found a credential pattern in reachable history"

FSCK_OUTPUT=$(git fsck --full --no-reflogs --unreachable 2>&1) \
    || fail "Git object verification failed"
[[ -z "$FSCK_OUTPUT" ]] || fail "unreachable Git objects remain in the candidate clone"
print -- "public-release audit passed for every reachable branch and tag"
