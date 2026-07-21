#!/bin/zsh
# Exercises the public-release gate in disposable repositories. The positive fixture proves that
# documented example configuration remains publishable; negative fixtures prove a tracked runtime
# environment and a deleted-but-reachable project capability both fail the gate.
#
# Usage: `GITLEAKS_BIN=/path/to/gitleaks scripts/test-audit-public-release.sh`
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GITLEAKS=${GITLEAKS_BIN:-$(command -v gitleaks || true)}
[[ -n "$GITLEAKS" && -x "$GITLEAKS" ]] || {
  print -u2 -- "GITLEAKS_BIN or a gitleaks executable on PATH is required"
  exit 2
}

TEMPORARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/audiostreamer-public-audit-tests.XXXXXX")
trap 'rm -rf "$TEMPORARY_ROOT"' EXIT

function initialize_fixture_repository() {
  local repository=$1
  mkdir -p "$repository/scripts" "$repository/services/Worker"
  cp "$ROOT_DIR/scripts/audit-public-release.sh" "$repository/scripts/"
  cp "$ROOT_DIR/.gitleaks.toml" "$repository/"
  git -C "$repository" init -q -b main
  git -C "$repository" config user.name "AudioStreamer Contributors"
  git -C "$repository" config user.email "audiostreamer@users.noreply.github.com"
}

function commit_fixture() {
  local repository=$1
  local message=$2
  git -C "$repository" add -A
  git -C "$repository" commit -q -m "$message"
}

function require_rejection() {
  local expected_message=$1
  shift
  local output_file="$TEMPORARY_ROOT/rejection-$RANDOM.log"
  if "$@" >"$output_file" 2>&1; then
    print -u2 -- "expected public-release audit rejection: $expected_message"
    exit 1
  fi
  grep -Fq -- "$expected_message" "$output_file" || {
    print -u2 -- "audit failed for the wrong reason; expected: $expected_message"
    exit 1
  }
}

SAFE_REPOSITORY="$TEMPORARY_ROOT/safe"
initialize_fixture_repository "$SAFE_REPOSITORY"
print -r -- "HOST=127.0.0.1" >"$SAFE_REPOSITORY/.env.example"
print -r -- "PLACEHOLDER=replace-me" >"$SAFE_REPOSITORY/services/Worker/.dev.vars.example"
print -r -- "registry=https://registry.npmjs.org/" >"$SAFE_REPOSITORY/.npmrc.example"
commit_fixture "$SAFE_REPOSITORY" "Add safe example configuration"
GITLEAKS_BIN="$GITLEAKS" \
  "$SAFE_REPOSITORY/scripts/audit-public-release.sh" "$SAFE_REPOSITORY" >/dev/null

print -r -- "RUNTIME_VALUE=must-not-be-tracked" >"$SAFE_REPOSITORY/.env"
commit_fixture "$SAFE_REPOSITORY" "Add forbidden runtime environment"
require_rejection \
  "credential or signing-artifact filenames are tracked" \
  env GITLEAKS_BIN="$GITLEAKS" \
  "$SAFE_REPOSITORY/scripts/audit-public-release.sh" "$SAFE_REPOSITORY"

HISTORY_REPOSITORY="$TEMPORARY_ROOT/history"
initialize_fixture_repository "$HISTORY_REPOSITORY"
BLOCKLIST="$TEMPORARY_ROOT/history-blocklist"
CANARY="test-only-history-capability-000000000000"
print -r -- "$CANARY" >"$HISTORY_REPOSITORY/fixture.txt"
commit_fixture "$HISTORY_REPOSITORY" "Add synthetic historical fixture"
rm "$HISTORY_REPOSITORY/fixture.txt"
commit_fixture "$HISTORY_REPOSITORY" "Remove synthetic historical fixture"
print -r -- "$CANARY" >"$BLOCKLIST"
chmod 600 "$BLOCKLIST"
require_rejection \
  "a blocklisted literal remains in reachable history" \
  env GITLEAKS_BIN="$GITLEAKS" PUBLIC_RELEASE_BLOCKLIST_FILE="$BLOCKLIST" \
  "$HISTORY_REPOSITORY/scripts/audit-public-release.sh" "$HISTORY_REPOSITORY"

print -- "public-release audit regression tests passed"
