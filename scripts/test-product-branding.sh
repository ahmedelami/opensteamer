#!/bin/zsh
# Deterministic regression tests for the current-tree product-branding allowlist.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPORARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/opensteamer-branding-tests.XXXXXX")
trap 'rm -rf "$TEMPORARY_ROOT"' EXIT

initialize_repository() {
  local repository=$1
  mkdir -p "$repository/scripts"
  cp "$ROOT_DIR/scripts/check-product-branding.sh" "$repository/scripts/"
  git -C "$repository" init -q -b main
  git -C "$repository" config user.name "opensteamer contributors"
  git -C "$repository" config user.email "opensteamer@users.noreply.github.com"
}

commit_all() {
  local repository=$1
  git -C "$repository" add -A
  git -C "$repository" commit -q -m "branding fixture"
}

require_failure() {
  local repository=$1
  local expected=$2
  local output="$TEMPORARY_ROOT/rejection-$RANDOM.log"
  if "$repository/scripts/check-product-branding.sh" "$repository" >"$output" 2>&1; then
    print -u2 -- "branding fixture unexpectedly passed"
    exit 1
  fi
  grep -Fq -- "$expected" "$output"
}

ALLOWED="$TEMPORARY_ROOT/allowed"
initialize_repository "$ALLOWED"
mkdir -p \
  "$ALLOWED/services/Rendezvous/src" \
  "$ALLOWED/iOS/opensteamer/Sources/Security" \
  "$ALLOWED/iOS/opensteamer/Sources/Support" \
  "$ALLOWED/iOS/opensteamer/Tests" \
  "$ALLOWED/macOS/Sources/CaptureServer" \
  "$ALLOWED/shared/Sources/RemoteSessionCore"
print -r -- "# opensteamer" >"$ALLOWED/README.md"
print -r -- 'export const CHANNEL_HEADER = "x-audiostreamer-channel";' \
  >"$ALLOWED/services/Rendezvous/src/protocol.mjs"
print -r -- 'let service = "org.example.AudioStreamer"' \
  >"$ALLOWED/iOS/opensteamer/Sources/Security/KeychainStore.swift"
print -r -- '<key>AudioStreamerRendezvousURL</key>' \
  >"$ALLOWED/iOS/opensteamer/Sources/Support/Info.plist"
print -r -- 'XCTAssertEqual(Bundle.main.bundleIdentifier, "org.example.AudioStreamer.dev")' \
  >"$ALLOWED/iOS/opensteamer/Tests/AppArtifactContractTests.swift"
print -r -- 'let legacy = environment["AUDIOSTREAMER_RENDEZVOUS_URL"]' \
  >"$ALLOWED/macOS/Sources/CaptureServer/CaptureServerOptions.swift"
print -r -- 'let salt = "AudioStreamer.RemoteSession.HKDF-SHA256.v1"' \
  >"$ALLOWED/shared/Sources/RemoteSessionCore/RemoteSignalingCrypto.swift"
commit_all "$ALLOWED"
"$ALLOWED/scripts/check-product-branding.sh" "$ALLOWED" >/dev/null

STALE_CONTENT="$TEMPORARY_ROOT/stale-content"
initialize_repository "$STALE_CONTENT"
print -r -- "# AudioStreamer" >"$STALE_CONTENT/README.md"
commit_all "$STALE_CONTENT"
require_failure "$STALE_CONTENT" \
  "former product branding remains outside the compatibility allowlist"

STALE_COMPONENT="$TEMPORARY_ROOT/stale-component"
initialize_repository "$STALE_COMPONENT"
print -r -- "obsolete MacCaptureHost.app" >"$STALE_COMPONENT/README.md"
commit_all "$STALE_COMPONENT"
require_failure "$STALE_COMPONENT" \
  "former product branding remains outside the compatibility allowlist"

STALE_BUILD_ENV="$TEMPORARY_ROOT/stale-build-environment"
initialize_repository "$STALE_BUILD_ENV"
print -r -- 'MAC_CAPTURE_CODESIGN_IDENTITY="-"' >"$STALE_BUILD_ENV/build.sh"
commit_all "$STALE_BUILD_ENV"
require_failure "$STALE_BUILD_ENV" \
  "former product branding remains outside the compatibility allowlist"

MUTATED_CRYPTO="$TEMPORARY_ROOT/mutated-crypto"
initialize_repository "$MUTATED_CRYPTO"
mkdir -p "$MUTATED_CRYPTO/shared/Sources/RemoteSessionCore"
print -r -- 'let salt = "AudioStreamer.RemoteSession.HKDF-SHA256.v2"' \
  >"$MUTATED_CRYPTO/shared/Sources/RemoteSessionCore/RemoteSignalingCrypto.swift"
commit_all "$MUTATED_CRYPTO"
require_failure "$MUTATED_CRYPTO" \
  "former product branding remains outside the compatibility allowlist"

STALE_PATH="$TEMPORARY_ROOT/stale-path"
initialize_repository "$STALE_PATH"
print -r -- "stale path" >"$STALE_PATH/AudioStreamer-notes.md"
commit_all "$STALE_PATH"
require_failure "$STALE_PATH" "former product branding remains in a tracked path"

print -- "opensteamer branding regression tests passed"
