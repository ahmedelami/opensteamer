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

TEMPORARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/opensteamer-public-audit-tests.XXXXXX")
trap 'rm -rf "$TEMPORARY_ROOT"' EXIT

function initialize_fixture_repository() {
  local repository=$1
  mkdir -p \
    "$repository/scripts" \
    "$repository/services/Worker" \
    "$repository/iOS/opensteamer/Sources/App" \
    "$repository/iOS/opensteamer/Sources/Support" \
    "$repository/iOS/opensteamer/Sources/Views" \
    "$repository/iOS/opensteamer/TestFlightScheme" \
    "$repository/iOS/opensteamer/scripts" \
    "$repository/macOS/OpensteamerHost" \
    "$repository/macOS/Sources/CaptureServer" \
    "$repository/macOS/scripts" \
    "$repository/macOS/RelayBridge" \
    "$repository/services/Rendezvous" \
    "$repository/services/RendezvousWorker"
  cp "$ROOT_DIR/scripts/audit-public-release.sh" "$repository/scripts/"
  cp "$ROOT_DIR/scripts/check-product-branding.sh" "$repository/scripts/"
  cp "$ROOT_DIR/scripts/check-product-identity.sh" "$repository/scripts/"
  cp "$ROOT_DIR/.gitleaks.toml" "$repository/"
  cp "$ROOT_DIR/Package.swift" "$ROOT_DIR/README.md" "$repository/"
  cp "$ROOT_DIR/iOS/opensteamer/project.yml" "$repository/iOS/opensteamer/"
  cp \
    "$ROOT_DIR/iOS/opensteamer/TestFlightExportOptions.plist" \
    "$repository/iOS/opensteamer/"
  cp \
    "$ROOT_DIR/iOS/opensteamer/TestFlightScheme/opensteamerTestFlight.xcscheme" \
    "$repository/iOS/opensteamer/TestFlightScheme/"
  cp \
    "$ROOT_DIR/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
    "$ROOT_DIR/iOS/opensteamer/scripts/restore-archive-only-testflight-scheme.sh" \
    "$repository/iOS/opensteamer/scripts/"
  cp -R \
    "$ROOT_DIR/iOS/opensteamer/opensteamer.xcodeproj" \
    "$repository/iOS/opensteamer/"
  cp \
    "$ROOT_DIR/iOS/opensteamer/Sources/App/BackgroundPlaybackCoordinator.swift" \
    "$repository/iOS/opensteamer/Sources/App/"
  cp \
    "$ROOT_DIR/iOS/opensteamer/Sources/Support/Info.plist" \
    "$repository/iOS/opensteamer/Sources/Support/"
  cp \
    "$ROOT_DIR/iOS/opensteamer/Sources/Views/BrowserView.swift" \
    "$repository/iOS/opensteamer/Sources/Views/"
  cp "$ROOT_DIR/macOS/OpensteamerHost/Info.plist" "$repository/macOS/OpensteamerHost/"
  cp \
    "$ROOT_DIR/macOS/Sources/CaptureServer/Info.plist" \
    "$repository/macOS/Sources/CaptureServer/"
  print -r -- 'static let opensteamerPairingService =
    "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"' \
    >"$repository/macOS/Sources/CaptureServer/WorldwidePairingStore.swift"
  print -r -- 'let store = WorldwidePairingStore(
    dataStore: WorldwideKeychainDataStore()
)
fflush(stdout)' >"$repository/macOS/Sources/CaptureServer/CaptureServerMain.swift"
  print -r -- 'static let legacyRuntimeDirectoryName =
    "com.elamin.AudioStreamer.CaptureServer.runtime"' \
    >"$repository/macOS/Sources/CaptureServer/WorldwideHostProcessLock.swift"
  print -r -- 'codesign --identifier com.elamin.AudioStreamer.CaptureServer executable' \
    >"$repository/macOS/scripts/build-opensteamer-host-app.sh"
  print -r -- 'EXPECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"' \
    >"$repository/macOS/scripts/verify-mac-host-bundle.sh"
  print -r -- 'verify-live "com.elamin.AudioStreamer.CaptureServer"' \
    >"$repository/macOS/scripts/verify-mac-host-deployment.sh"
  cp -R "$ROOT_DIR/macOS/LaunchAgents" "$repository/macOS/"
  cp \
    "$ROOT_DIR/macOS/RelayBridge/package.json" \
    "$ROOT_DIR/macOS/RelayBridge/package-lock.json" \
    "$repository/macOS/RelayBridge/"
  cp \
    "$ROOT_DIR/services/Rendezvous/package.json" \
    "$ROOT_DIR/services/Rendezvous/package-lock.json" \
    "$repository/services/Rendezvous/"
  cp \
    "$ROOT_DIR/services/RendezvousWorker/package.json" \
    "$ROOT_DIR/services/RendezvousWorker/package-lock.json" \
    "$ROOT_DIR/services/RendezvousWorker/wrangler.toml" \
    "$ROOT_DIR/services/RendezvousWorker/wrangler.test.toml" \
    "$repository/services/RendezvousWorker/"
  git -C "$repository" init -q -b main
  git -C "$repository" config user.name "opensteamer contributors"
  git -C "$repository" config user.email "opensteamer@users.noreply.github.com"
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
mkdir -p \
  "$SAFE_REPOSITORY/services/Rendezvous/src" \
  "$SAFE_REPOSITORY/iOS/opensteamer/Sources/Security" \
  "$SAFE_REPOSITORY/iOS/opensteamer/Sources/Support" \
  "$SAFE_REPOSITORY/macOS/Sources/CaptureServer" \
  "$SAFE_REPOSITORY/shared/Sources/RemoteSessionCore"
# Exact compatibility literals remain valid only in their established protocol/persistence paths.
print -r -- 'export const CHANNEL_HEADER = "x-audiostreamer-channel";' \
  >"$SAFE_REPOSITORY/services/Rendezvous/src/protocol.mjs"
print -r -- 'let service = "org.example.AudioStreamer"' \
  >"$SAFE_REPOSITORY/iOS/opensteamer/Sources/Security/KeychainStore.swift"
print -r -- 'let legacy = environment["AUDIOSTREAMER_RENDEZVOUS_URL"]' \
  >"$SAFE_REPOSITORY/macOS/Sources/CaptureServer/CaptureServerOptions.swift"
print -r -- 'let salt = "AudioStreamer.RemoteSession.HKDF-SHA256.v1"' \
  >"$SAFE_REPOSITORY/shared/Sources/RemoteSessionCore/RemoteSignalingCrypto.swift"
print -r -- "HOST=127.0.0.1" >"$SAFE_REPOSITORY/.env.example"
print -r -- "PLACEHOLDER=replace-me" >"$SAFE_REPOSITORY/services/Worker/.dev.vars.example"
print -r -- "registry=https://registry.npmjs.org/" >"$SAFE_REPOSITORY/.npmrc.example"
commit_fixture "$SAFE_REPOSITORY" "Add safe example configuration"
# A normal fresh clone carries a remote-tracking mirror of its checked-out branch and may carry a
# symbolic origin/HEAD. Neither creates additional reachable history, so both must pass the gate.
git -C "$SAFE_REPOSITORY" update-ref \
  refs/remotes/origin/main "$(git -C "$SAFE_REPOSITORY" rev-parse HEAD)"
git -C "$SAFE_REPOSITORY" symbolic-ref \
  refs/remotes/origin/HEAD refs/remotes/origin/main
GITLEAKS_BIN="$GITLEAKS" \
  "$SAFE_REPOSITORY/scripts/audit-public-release.sh" "$SAFE_REPOSITORY" >/dev/null

# An extra remote/backup root is different: it can retain artifacts outside the release branch.
git -C "$SAFE_REPOSITORY" update-ref \
  refs/remotes/archive/backup "$(git -C "$SAFE_REPOSITORY" rev-parse HEAD)"
require_rejection \
  "unexpected refs are reachable" \
  env GITLEAKS_BIN="$GITLEAKS" \
  "$SAFE_REPOSITORY/scripts/audit-public-release.sh" "$SAFE_REPOSITORY"
git -C "$SAFE_REPOSITORY" update-ref -d refs/remotes/archive/backup

DELETED_SENSITIVE_REPOSITORY="$TEMPORARY_ROOT/deleted-sensitive-filename"
initialize_fixture_repository "$DELETED_SENSITIVE_REPOSITORY"
print -r -- '{"fixture":"synthetic and non-authorizing"}' \
  >"$DELETED_SENSITIVE_REPOSITORY/credentials.json"
commit_fixture "$DELETED_SENSITIVE_REPOSITORY" "Add synthetic sensitive-filename fixture"
rm "$DELETED_SENSITIVE_REPOSITORY/credentials.json"
commit_fixture "$DELETED_SENSITIVE_REPOSITORY" "Remove synthetic sensitive-filename fixture"
require_rejection \
  "credential or signing-artifact filenames remain in reachable history" \
  env GITLEAKS_BIN="$GITLEAKS" \
  "$DELETED_SENSITIVE_REPOSITORY/scripts/audit-public-release.sh" \
  "$DELETED_SENSITIVE_REPOSITORY"

BRANDING_REPOSITORY="$TEMPORARY_ROOT/branding"
initialize_fixture_repository "$BRANDING_REPOSITORY"
print -r -- "# AudioStreamer" >"$BRANDING_REPOSITORY/README.md"
commit_fixture "$BRANDING_REPOSITORY" "Add stale product branding fixture"
require_rejection \
  "former product branding remains outside the compatibility allowlist" \
  env GITLEAKS_BIN="$GITLEAKS" \
  "$BRANDING_REPOSITORY/scripts/audit-public-release.sh" "$BRANDING_REPOSITORY"

PATH_REPOSITORY="$TEMPORARY_ROOT/branding-path"
initialize_fixture_repository "$PATH_REPOSITORY"
print -r -- "stale path fixture" >"$PATH_REPOSITORY/AudioStreamer-notes.md"
commit_fixture "$PATH_REPOSITORY" "Add stale branded path fixture"
require_rejection \
  "former product branding remains outside the compatibility allowlist" \
  env GITLEAKS_BIN="$GITLEAKS" \
  "$PATH_REPOSITORY/scripts/audit-public-release.sh" "$PATH_REPOSITORY"

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
