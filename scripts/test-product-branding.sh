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

PRODUCTION_HOST='audiostreamer-rendezvous.elaminahmed03.workers.dev'
PRODUCTION_URL="wss://${PRODUCTION_HOST}"
PRODUCTION_BUNDLE_ID='com.elamin.AudioStreamer'
DEBUG_BUNDLE_ID='org.example.AudioStreamer.dev'

write_current_automatic_signing_fixture() {
  local repository=$1

  mkdir -p "$repository/iOS/opensteamer/opensteamer.xcodeproj"

  cat >"$repository/iOS/opensteamer/project.yml" <<EOF
name: opensteamer
targets:
  opensteamer:
    type: application
    attributes:
      ProvisioningStyle: Automatic
    settings:
      base:
        MARKETING_VERSION: 0.1.0
        CURRENT_PROJECT_VERSION: 1
        OPENSTEAMER_RENDEZVOUS_URL: ""
        AUDIOSTREAMER_RENDEZVOUS_URL: ""
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: ${DEBUG_BUNDLE_ID}
          CODE_SIGN_STYLE: Automatic
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: ${PRODUCTION_BUNDLE_ID}
          DEVELOPMENT_TEAM: MSMG8CJLB3
          CURRENT_PROJECT_VERSION: 33
          CODE_SIGN_STYLE: Automatic
          OPENSTEAMER_RENDEZVOUS_URL: "${PRODUCTION_URL}"
          AUDIOSTREAMER_RENDEZVOUS_URL: "${PRODUCTION_URL}"
EOF

  cat >"$repository/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" <<EOF
// opensteamer automatic-signing fixture
{
	objects = {
		0240299FE56B5D6503940318 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				AUDIOSTREAMER_RENDEZVOUS_URL = "";
				CODE_SIGN_STYLE = Automatic;
				OPENSTEAMER_RENDEZVOUS_URL = "";
				PRODUCT_BUNDLE_IDENTIFIER = ${DEBUG_BUNDLE_ID};
			};
			name = Debug;
		};
		5ADF15167753B5B287DCA772 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				AUDIOSTREAMER_RENDEZVOUS_URL = "${PRODUCTION_URL}";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 33;
				DEVELOPMENT_TEAM = MSMG8CJLB3;
				MARKETING_VERSION = 0.1.0;
				OPENSTEAMER_RENDEZVOUS_URL = "${PRODUCTION_URL}";
				PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCTION_BUNDLE_ID};
			};
			name = Release;
		};
	};
}
EOF

  cat >"$repository/iOS/opensteamer/ExportOptions.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>MSMG8CJLB3</string>
  <key>testFlightInternalTestingOnly</key>
  <true/>
</dict>
</plist>
EOF

  cat >"$repository/README.md" <<EOF
# opensteamer

| Configuration field | Checked-in value |
| --- | --- |
| Production bundle | <code>${PRODUCTION_BUNDLE_ID}</code> |
| Debug bundle | <code>${DEBUG_BUNDLE_ID}</code> |
EOF
}

write_project_scope_fixture() {
  local repository=$1
  local target=$2
  local configuration=$3
  local setting=$4
  local url=$5

  cat >"$repository/iOS/opensteamer/project.yml" <<EOF
targets:
  ${target}:
    settings:
      configs:
        ${configuration}:
          ${setting}: "${url}"
EOF
}

write_pbxproj_scope_fixture() {
  local repository=$1
  local configuration=$2
  local bundle_identifier=$3
  local setting=$4
  local url=$5

  cat >"$repository/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" <<EOF
// opensteamer branding mutation fixture
{
	objects = {
		AAAAAAAAAAAAAAAAAAAAAAAA /* ${configuration} */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				${setting} = "${url}";
				PRODUCT_BUNDLE_IDENTIFIER = ${bundle_identifier};
			};
			name = ${configuration};
		};
	};
}
EOF
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

AUTOMATIC_SIGNING="$TEMPORARY_ROOT/automatic-signing"
initialize_repository "$AUTOMATIC_SIGNING"
write_current_automatic_signing_fixture "$AUTOMATIC_SIGNING"
commit_all "$AUTOMATIC_SIGNING"
"$AUTOMATIC_SIGNING/scripts/check-product-branding.sh" "$AUTOMATIC_SIGNING" >/dev/null

RENDEZVOUS_WRONG_PATH="$TEMPORARY_ROOT/rendezvous-wrong-path"
initialize_repository "$RENDEZVOUS_WRONG_PATH"
write_current_automatic_signing_fixture "$RENDEZVOUS_WRONG_PATH"
print -r -- "$PRODUCTION_URL" >"$RENDEZVOUS_WRONG_PATH/README.md"
commit_all "$RENDEZVOUS_WRONG_PATH"
require_failure "$RENDEZVOUS_WRONG_PATH" \
  "README.md:1:${PRODUCTION_HOST}"

MUTATED_PRODUCTION_HOST='audiostreamer-rendezvous.elaminahmed04.workers.dev'
RENDEZVOUS_WRONG_TOKEN="$TEMPORARY_ROOT/rendezvous-wrong-token"
initialize_repository "$RENDEZVOUS_WRONG_TOKEN"
write_current_automatic_signing_fixture "$RENDEZVOUS_WRONG_TOKEN"
write_project_scope_fixture "$RENDEZVOUS_WRONG_TOKEN" \
  opensteamer Release OPENSTEAMER_RENDEZVOUS_URL \
  "wss://${MUTATED_PRODUCTION_HOST}"
commit_all "$RENDEZVOUS_WRONG_TOKEN"
require_failure "$RENDEZVOUS_WRONG_TOKEN" \
  "iOS/opensteamer/project.yml:6:${MUTATED_PRODUCTION_HOST}"

RENDEZVOUS_WRONG_CONFIGURATION="$TEMPORARY_ROOT/rendezvous-wrong-configuration"
initialize_repository "$RENDEZVOUS_WRONG_CONFIGURATION"
write_current_automatic_signing_fixture "$RENDEZVOUS_WRONG_CONFIGURATION"
write_project_scope_fixture "$RENDEZVOUS_WRONG_CONFIGURATION" \
  opensteamer Debug OPENSTEAMER_RENDEZVOUS_URL "$PRODUCTION_URL"
commit_all "$RENDEZVOUS_WRONG_CONFIGURATION"
require_failure "$RENDEZVOUS_WRONG_CONFIGURATION" \
  "iOS/opensteamer/project.yml:6:${PRODUCTION_HOST}"

RENDEZVOUS_WRONG_SETTING="$TEMPORARY_ROOT/rendezvous-wrong-setting"
initialize_repository "$RENDEZVOUS_WRONG_SETTING"
write_current_automatic_signing_fixture "$RENDEZVOUS_WRONG_SETTING"
write_project_scope_fixture "$RENDEZVOUS_WRONG_SETTING" \
  opensteamer Release RENDEZVOUS_URL "$PRODUCTION_URL"
commit_all "$RENDEZVOUS_WRONG_SETTING"
require_failure "$RENDEZVOUS_WRONG_SETTING" \
  "iOS/opensteamer/project.yml:6:${PRODUCTION_HOST}"

RENDEZVOUS_WRONG_TARGET="$TEMPORARY_ROOT/rendezvous-wrong-target"
initialize_repository "$RENDEZVOUS_WRONG_TARGET"
write_current_automatic_signing_fixture "$RENDEZVOUS_WRONG_TARGET"
write_project_scope_fixture "$RENDEZVOUS_WRONG_TARGET" \
  opensteamerTests Release OPENSTEAMER_RENDEZVOUS_URL "$PRODUCTION_URL"
commit_all "$RENDEZVOUS_WRONG_TARGET"
require_failure "$RENDEZVOUS_WRONG_TARGET" \
  "iOS/opensteamer/project.yml:6:${PRODUCTION_HOST}"

PBX_RENDEZVOUS_WRONG_CONFIGURATION="$TEMPORARY_ROOT/pbx-rendezvous-wrong-configuration"
initialize_repository "$PBX_RENDEZVOUS_WRONG_CONFIGURATION"
write_current_automatic_signing_fixture "$PBX_RENDEZVOUS_WRONG_CONFIGURATION"
write_pbxproj_scope_fixture "$PBX_RENDEZVOUS_WRONG_CONFIGURATION" \
  Debug "$PRODUCTION_BUNDLE_ID" OPENSTEAMER_RENDEZVOUS_URL "$PRODUCTION_URL"
commit_all "$PBX_RENDEZVOUS_WRONG_CONFIGURATION"
require_failure "$PBX_RENDEZVOUS_WRONG_CONFIGURATION" \
  "iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj:8:${PRODUCTION_HOST}"

PBX_RENDEZVOUS_WRONG_BUNDLE="$TEMPORARY_ROOT/pbx-rendezvous-wrong-bundle"
initialize_repository "$PBX_RENDEZVOUS_WRONG_BUNDLE"
write_current_automatic_signing_fixture "$PBX_RENDEZVOUS_WRONG_BUNDLE"
write_pbxproj_scope_fixture "$PBX_RENDEZVOUS_WRONG_BUNDLE" \
  Release "$DEBUG_BUNDLE_ID" OPENSTEAMER_RENDEZVOUS_URL "$PRODUCTION_URL"
commit_all "$PBX_RENDEZVOUS_WRONG_BUNDLE"
require_failure "$PBX_RENDEZVOUS_WRONG_BUNDLE" \
  "iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj:8:${PRODUCTION_HOST}"

PBX_RENDEZVOUS_WRONG_SETTING="$TEMPORARY_ROOT/pbx-rendezvous-wrong-setting"
initialize_repository "$PBX_RENDEZVOUS_WRONG_SETTING"
write_current_automatic_signing_fixture "$PBX_RENDEZVOUS_WRONG_SETTING"
write_pbxproj_scope_fixture "$PBX_RENDEZVOUS_WRONG_SETTING" \
  Release "$PRODUCTION_BUNDLE_ID" RENDEZVOUS_URL "$PRODUCTION_URL"
commit_all "$PBX_RENDEZVOUS_WRONG_SETTING"
require_failure "$PBX_RENDEZVOUS_WRONG_SETTING" \
  "iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj:8:${PRODUCTION_HOST}"

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
