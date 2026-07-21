# Security Policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository. Do not place
exploit details, device identifiers, pairing material, credentials, or private
network information in a public issue. If private reporting is unavailable,
open a minimal issue asking the maintainer to establish a private channel; omit
all sensitive details from that issue.

## Sensitive values

Never commit or paste a real invitation, activation code, `MCAP_TOKEN`, TURN
credential, Cloudflare API token, signing key, provisioning profile, device
identifier, or captured signaling/media payload. Tests must derive deterministic
fixtures locally and must make it evident that those fixtures cannot authorize a
deployed service.

The production rendezvous URL, WebSocket paths, protocol versions, Apple bundle
identifiers, and public signing certificates are identifiers rather than
credentials. Authentication depends on one-use invitation proofs, mutually
authenticated durable device identities, and fresh per-session signaling/media
keys—not on keeping those public identifiers secret.

## Runtime boundary

The worldwide path uses authenticated WSS for coordination and WebRTC
DTLS-SRTP for media. The rendezvous service never receives plaintext media.
Legacy TCP audio and video are trusted-LAN diagnostics and must never be exposed
through port forwarding or a public listener.

## If a credential reaches history

Treat the value as compromised immediately: revoke or rotate it first, replace
it with a synthetic fixture, rewrite every affected ref, and re-scan the complete
publishable history. Deleting the value only from the newest commit is not a
complete remediation.

Before changing repository visibility, run `scripts/audit-public-release.sh` in
a fresh candidate clone. Supply an out-of-repository
`PUBLIC_RELEASE_BLOCKLIST_FILE` for project-specific revoked capabilities and a
verified Gitleaks executable through `GITLEAKS_BIN`; the gate checks both the
current tree and every reachable branch/tag.
