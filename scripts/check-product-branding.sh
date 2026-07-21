#!/bin/zsh
# Rejects former product branding in the current tracked tree while allowing only the exact
# persistence and protocol identifiers that shipped before the opensteamer rename. The allowlist
# is deliberately path- and token-specific: compatibility bytes may remain, but they cannot be
# copied into new user-facing text or unversioned identifiers unnoticed.
set -eu

REPOSITORY=${1:-.}
cd "$REPOSITORY"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

# Split former spellings so this enforcement script does not match its own search expression.
FORMER_CAMEL='Audio''Streamer'
FORMER_ENV='AUDIO''STREAMER'
FORMER_LOWER='audio''streamer'
FORMER_SLUG='audio''-streamer'
FORMER_SCOPE='@audio''stream'
FORMER_HOST_CAMEL='Mac''CaptureHost'
FORMER_HOST_SLUG='mac''-capture-host'
FORMER_PACKAGE='Mac''CaptureVerifier'
FORMER_BUILD_ENV='MAC''_CAPTURE'
TOKEN_PATTERN="(${FORMER_SCOPE}/[A-Za-z0-9._-]+|${FORMER_SLUG}[A-Za-z0-9._-]*|${FORMER_ENV}_[A-Z0-9_]+|${FORMER_CAMEL}[A-Za-z0-9._-]*|${FORMER_LOWER}[A-Za-z0-9._@-]*|${FORMER_HOST_CAMEL}[A-Za-z0-9._-]*|${FORMER_HOST_SLUG}[A-Za-z0-9._-]*|${FORMER_PACKAGE}[A-Za-z0-9._-]*|${FORMER_BUILD_ENV}_[A-Z0-9_]+)"

is_wire_token() {
  case "$1" in
    "$FORMER_CAMEL-"|"$FORMER_CAMEL-Channel"|"$FORMER_CAMEL-Role"|\
      "$FORMER_CAMEL-Admission"|"$FORMER_CAMEL-Viewer-Admission"|"$FORMER_CAMEL-Mode"|\
      "$FORMER_LOWER-channel"|"$FORMER_LOWER-role"|"$FORMER_LOWER-admission"|\
      "$FORMER_LOWER.pairing.v1"|"$FORMER_LOWER.pairing.v2"|\
      "$FORMER_LOWER.availability.v1"|"$FORMER_LOWER.availability.v2"|\
      "$FORMER_LOWER.control"|"$FORMER_LOWER.control.v2") return 0 ;;
    *) return 1 ;;
  esac
}

is_crypto_token() {
  case "$1" in
    "$FORMER_CAMEL."|\
      "$FORMER_CAMEL.Availability.Admission.Host.v2"|\
      "$FORMER_CAMEL.Availability.Admission.Viewer.v2"|\
      "$FORMER_CAMEL.Availability.Channel.v1"|\
      "$FORMER_CAMEL.Availability.Channel.v2"|\
      "$FORMER_CAMEL.Availability.Envelope.AAD.v1"|\
      "$FORMER_CAMEL.Availability.Exchange.Salt.v1"|\
      "$FORMER_CAMEL.Availability.Exchange.Signaling.HostToViewer.v1"|\
      "$FORMER_CAMEL.Availability.Exchange.Signaling.ViewerToHost.v1"|\
      "$FORMER_CAMEL.Availability.ExchangeSeed.Salt.v1"|\
      "$FORMER_CAMEL.Availability.ExchangeSeed.v1"|\
      "$FORMER_CAMEL.Availability.Route.Salt.v1"|\
      "$FORMER_CAMEL.Availability.Route.v1"|\
      "$FORMER_CAMEL.DurableRendezvous."|\
      "$FORMER_CAMEL.DurableRendezvous.Salt.v1"|\
      "$FORMER_CAMEL.Pairing.Commit."|\
      "$FORMER_CAMEL.Pairing.Commit.MAC.v1"|\
      "$FORMER_CAMEL.Pairing.Commit.Signature.v1"|\
      "$FORMER_CAMEL.Pairing.CommitID.v1"|\
      "$FORMER_CAMEL.Pairing.Confirmation."|\
      "$FORMER_CAMEL.Pairing.Confirmation.MAC.v1"|\
      "$FORMER_CAMEL.Pairing.Confirmation.Signature.v1"|\
      "$FORMER_CAMEL.Pairing.Hello.PSK.v1"|\
      "$FORMER_CAMEL.Pairing.Hello.Signature.v1"|\
      "$FORMER_CAMEL.Pairing.ID.v1"|\
      "$FORMER_CAMEL.Pairing.Root.v1"|\
      "$FORMER_CAMEL.Pairing.Transcript.v1"|\
      "$FORMER_CAMEL.Reconnect.Request.Signature.v1"|\
      "$FORMER_CAMEL.Reconnect.Response.Signature.v1"|\
      "$FORMER_CAMEL.Reconnect.SessionRoot.v1"|\
      "$FORMER_CAMEL.Reconnect.Transcript.v1"|\
      "$FORMER_CAMEL.RemoteInvitation.Checksum.v1"|\
      "$FORMER_CAMEL.RemoteSession.HKDF-SHA256.v1"|\
      "$FORMER_CAMEL.Signaling.Envelope.AAD.v1"|\
      "$FORMER_CAMEL.WorldwideInvitation.Admitted.v1") return 0 ;;
    *) return 1 ;;
  esac
}

is_identity_token() {
  case "$1" in
    "$FORMER_CAMEL"|"$FORMER_CAMEL.dev"|"$FORMER_CAMEL"Tests|\
      "$FORMER_CAMEL"UITests|"$FORMER_CAMEL.CaptureServer"|\
      "$FORMER_CAMEL.CaptureServer.runtime"|\
      "$FORMER_CAMEL.CaptureServer.WorldwidePairing.v1") return 0 ;;
    *) return 1 ;;
  esac
}

is_rendezvous_fallback_token() {
  case "$1" in
    "$FORMER_CAMEL"RendezvousURL|"${FORMER_ENV}_RENDEZVOUS_URL") return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed_legacy_token() {
  local path=$1
  local token=$2

  case "$path" in
    BRANDING.md)
      [[ "$token" == "$FORMER_CAMEL" ]] || is_wire_token "$token" || \
        is_crypto_token "$token" || is_identity_token "$token"
      ;;
    AGENTS.md)
      is_wire_token "$token" || is_crypto_token "$token" || is_identity_token "$token"
      ;;
    WORLDWIDE_REMOTE_ACCESS.md|services/Rendezvous/README.md|\
      services/RendezvousWorker/README.md)
      is_wire_token "$token" || is_crypto_token "$token"
      ;;
    HOST_MIGRATION.md)
      [[ "$token" == "$FORMER_CAMEL" \
        || "$token" == "$FORMER_LOWER.worldwide" \
        || "$token" == "$FORMER_LOWER.worldwide.plist" ]]
      ;;
    services/Rendezvous/src/protocol.mjs|services/Rendezvous/test/server.test.mjs|\
      services/RendezvousWorker/src/protocol.js|services/RendezvousWorker/test/protocol.test.js|\
      services/RendezvousWorker/test/worker.test.js|\
      shared/Sources/RemoteSessionCore/RendezvousSignalingClient.swift|\
      shared/Sources/RemoteSessionCore/PairedAvailabilitySignalingClient.swift|\
      shared/Tests/RemoteSessionCoreTests/RendezvousSignalingClientTests.swift|\
      shared/Sources/WebRTCTransport/WebRTCDelegateProxy.swift)
      is_wire_token "$token" || is_crypto_token "$token"
      ;;
    services/RendezvousWorker/scripts/smoke-public.mjs)
      is_wire_token "$token" || is_rendezvous_fallback_token "$token"
      ;;
    shared/Sources/RemoteSessionCore/RemoteInvitationCode.swift|\
      shared/Sources/RemoteSessionCore/RemotePairedDevice.swift|\
      shared/Sources/RemoteSessionCore/RemotePairing.swift|\
      shared/Sources/RemoteSessionCore/RemoteSignalingCrypto.swift|\
      shared/Tests/RemoteSessionCoreTests/DurableSignalingClientTests.swift|\
      shared/Tests/RemoteSessionCoreTests/RemotePairingTests.swift)
      is_crypto_token "$token"
      ;;
      iOS/opensteamer/Sources/Security/KeychainStore.swift|\
      iOS/opensteamer/Tests/AppArtifactContractTests.swift|\
      iOS/opensteamer/Tests/KeychainStoreTests.swift|\
      iOS/opensteamer/UITests/PairedReconnectPhysicalUITests.swift|\
      iOS/opensteamer/project.yml|\
      iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj|\
      iOS/opensteamer/scripts/validate-physical-update-keychain.sh|\
      iOS/opensteamer/scripts/validate-release-pair-baseline.sh|\
      iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh)
      is_identity_token "$token" || is_rendezvous_fallback_token "$token"
      ;;
    iOS/opensteamer/Sources/Support/Info.plist|\
      iOS/opensteamer/Sources/ViewModels/WorldwideSessionViewModel.swift|\
      iOS/opensteamer/Tests/WorldwidePresentationTests.swift)
      is_rendezvous_fallback_token "$token"
      ;;
    iOS/opensteamer/Sources/Security/ViewerPairingStore.swift)
      is_crypto_token "$token"
      ;;
    macOS/OpensteamerHost/Info.plist|macOS/Sources/CaptureServer/Info.plist|\
      macOS/Sources/CaptureServer/WorldwideHostProcessLock.swift|\
      macOS/Sources/CaptureServer/WorldwidePairingStore.swift|\
      macOS/scripts/build-opensteamer-host-app.sh|\
      macOS/scripts/verify-mac-host-bundle.sh|\
      macOS/scripts/verify-mac-host-deployment.sh|\
      macOS/Tests/CaptureServerTests/MacHostBundleIdentityTests.swift|\
      macOS/Tests/CaptureServerTests/WorldwideHostProcessLockTests.swift|\
      macOS/Tests/CaptureServerTests/WorldwidePairingStoreTests.swift)
      is_identity_token "$token"
      ;;
    macOS/Tests/CaptureServerTests/MacHostDeploymentContractTests.swift)
      is_identity_token "$token" || is_rendezvous_fallback_token "$token"
      ;;
    README.md|macOS/Sources/CaptureServer/CaptureServerOptions.swift|\
      macOS/scripts/verify-mac-host-launch-state.sh|\
      macOS/Tests/CaptureServerTests/CaptureServerOptionsTests.swift)
      is_rendezvous_fallback_token "$token"
      ;;
    *) return 1 ;;
  esac
}

OLD_PATHS="$(git ls-files -co --exclude-standard \
  | while IFS= read -r path; do
      [[ -e "$path" ]] || continue
      print -r -- "$path"
    done \
  | grep -E "(${FORMER_CAMEL}|${FORMER_ENV}|${FORMER_LOWER}|${FORMER_SLUG}|${FORMER_SCOPE}|${FORMER_HOST_CAMEL}|${FORMER_HOST_SLUG}|${FORMER_PACKAGE}|${FORMER_BUILD_ENV})" \
  || true)"
if [[ -n "$OLD_PATHS" ]]; then
  print -u2 -- "former product branding remains in a tracked path:"
  print -u2 -- "$OLD_PATHS"
  exit 1
fi

# The audit and its regression fixture necessarily construct former-brand search/test values;
# their behavior is tested separately. All other tracked text is checked token by token.
MATCHES="$(git grep -I -n -o -E "$TOKEN_PATTERN" -- . \
  ':!scripts/audit-public-release.sh' \
  ':!scripts/check-product-branding.sh' \
  ':!scripts/check-product-identity.sh' \
  ':!scripts/test-audit-public-release.sh' \
  ':!scripts/test-product-branding.sh' \
  ':!scripts/test-product-identity.sh' \
  || true)"
UNAPPROVED=""
while IFS=: read -r path line token; do
  [[ -n "$path" ]] || continue
  if ! is_allowed_legacy_token "$path" "$token"; then
    UNAPPROVED+="${path}:${line}:${token}"$'\n'
  fi
done <<< "$MATCHES"

if [[ -n "$UNAPPROVED" ]]; then
  print -u2 -- "former product branding remains outside the compatibility allowlist:"
  print -u2 -- "${UNAPPROVED%$'\n'}"
  exit 1
fi

print -- "opensteamer branding audit passed"
