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
# Keep the former project noreply address accepted because it is part of the already-published,
# sanitized commit metadata; new fixtures and commits use the opensteamer identity.
ALLOWED_EMAIL_REGEX=${PUBLIC_RELEASE_ALLOWED_EMAIL_REGEX:-'^(opensteamer@users\.noreply\.github\.com|audiostreamer@users\.noreply\.github\.com|[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com)$'}
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
[[ -x scripts/check-product-branding.sh ]] || fail "the product-branding audit is missing"
[[ -x scripts/check-product-identity.sh ]] || fail "the product-identity audit is missing"
scripts/check-product-branding.sh "$ROOT" \
    || fail "former product branding remains outside the compatibility allowlist"
scripts/check-product-identity.sh "$ROOT" \
    || fail "the exact opensteamer product identity is inconsistent"

# Public history must contain only intentional branch/tag refs. A fresh clone also has a
# remote-tracking mirror of its checked-out branch (and sometimes a symbolic origin/HEAD); those
# point at already-audited branch history and are not extra roots. Jujutsu keep refs, backup refs,
# and additional remote branches can retain unrelated archives, so reject every other namespace.
CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD || true)
ORIGIN_HEAD_TARGET=$(git symbolic-ref --quiet refs/remotes/origin/HEAD || true)
UNEXPECTED_REFS=""
while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if [[ "$ref" == refs/heads/* || "$ref" == refs/tags/* ]]; then
        continue
    fi
    if [[ -n "$CURRENT_BRANCH" \
        && "$ref" == "refs/remotes/origin/$CURRENT_BRANCH" ]]; then
        continue
    fi
    if [[ -n "$CURRENT_BRANCH" \
        && "$ref" == "refs/remotes/origin/HEAD" \
        && "$ORIGIN_HEAD_TARGET" == "refs/remotes/origin/$CURRENT_BRANCH" ]]; then
        continue
    fi
    UNEXPECTED_REFS+="$ref"$'\n'
done < <(git for-each-ref --format='%(refname)')
[[ -z "$UNEXPECTED_REFS" ]] || fail "unexpected refs are reachable"

SENSITIVE_FILENAME_PATTERN='(^|/)(\.env($|\.)|\.dev\.vars($|\.)|\.npmrc$|\.netrc$|credentials\.json$|secrets\.(json|ya?ml)$|id_(rsa|ed25519)($|\.)|[^/]*Secrets\.xcconfig$|[^/]*\.xcconfig\.local$)|\.(p8|p12|pfx|pem|key|cer|crt|der|csr|jks|keystore|mobileprovision|provisionprofile|xcarchive)(/|$)'
SAFE_EXAMPLE_FILENAME_PATTERN='(^|/)(\.env|\.dev\.vars|\.npmrc)\.example$'
SENSITIVE_TRACKED_FILES=$(git ls-files | grep -Ei "$SENSITIVE_FILENAME_PATTERN" \
    | grep -Ev "$SAFE_EXAMPLE_FILENAME_PATTERN" \
    || true)
[[ -z "$SENSITIVE_TRACKED_FILES" ]] || fail "credential or signing-artifact filenames are tracked"

# A deleted credential artifact is still downloadable from public history. Scan every path named
# by every reachable commit in addition to the final index; Gitleaks content matching is a second,
# independent gate and is not expected to recognize every binary/provisioning file format.
SENSITIVE_HISTORY_FILES=$(git log --all --name-only --format= \
    | sed '/^$/d' \
    | LC_ALL=C sort -u \
    | grep -Ei "$SENSITIVE_FILENAME_PATTERN" \
    | grep -Ev "$SAFE_EXAMPLE_FILENAME_PATTERN" \
    || true)
[[ -z "$SENSITIVE_HISTORY_FILES" ]] \
    || fail "credential or signing-artifact filenames remain in reachable history"

LARGE_BLOBS=$(git rev-list --objects --all \
    | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' \
    | awk '$2 == "blob" && $3 > 5242880 { print $1 }')
[[ -z "$LARGE_BLOBS" ]] || fail "a reachable tracked blob exceeds the 5 MiB source limit"

UNEXPECTED_BINARIES=$(git ls-files -z \
    | xargs -0 file --mime-type \
    | grep -E ': (application/octet-stream|application/x-mach-binary|application/zip)$' \
    | grep -Ev 'iOS/opensteamer/Sources/Assets\.xcassets/.+\.png:' || true)
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
if git log --all -G '/Users/[^/[:space:]]+' --format='%H' \
    -- . ':!scripts/audit-public-release.sh' | grep -q .; then
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
