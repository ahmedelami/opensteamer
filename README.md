# opensteamer

opensteamer pairs an iPhone with an awake Mac and streams Mac system audio, optional
screen video, and narrowly scoped remote input over WebRTC. It prefers a direct ICE route
and can fall back to TURN. An outbound WSS rendezvous service coordinates pairing and
end-to-end-encrypted signaling; it does not carry plaintext media.

This repository is an advanced prototype, not a hosted service. It contains no maintainer
endpoint, cloud credential, Apple signing team, or production bundle identifier. Configure
and deploy your own infrastructure before using worldwide mode. Do not claim that a build
"works anywhere" until it passes the unrelated-network and forced-TURN gates described in
[TESTING_ORACLES.md](TESTING_ORACLES.md).

## Capabilities

- Mac system-audio capture with ScreenCaptureKit and 48 kHz stereo Opus transport.
- H.264 screen video with Show/Hide independent from audio playback.
- Optional, explicitly enabled tap, atomic drag, committed text, Backspace, and Return input.
- One-use invitation bootstrap followed by durable, Keychain-backed device pairing.
- Fresh signaling and WebRTC keys for every paired-device media connection.
- Output-only iOS audio with background-audio support; no microphone or call-oriented mode.
- Legacy Bonjour/TCP/PCM tools retained only for trusted-LAN diagnostics.

```text
Mac Host ── outbound authenticated WSS ──┐
                                         ├─ Rendezvous Worker
iPhone  ── outbound authenticated WSS ───┘   opaque encrypted signaling only

Mac Host ═══════ WebRTC DTLS-SRTP ═══════ iPhone
             direct ICE preferred
             TURN relay when required
```

The rendezvous service is still required for discovery and signaling across unrelated
networks. TURN is required for dependable connectivity through restrictive NAT, CGNAT, and
firewalls; it relays encrypted DTLS-SRTP media rather than plaintext audio or video.

## Requirements

- macOS 14 or newer and iOS 17 or newer.
- An Apple toolchain capable of Swift 6.1 and XcodeGen 2.45.0 or newer.
- Node.js 20 or newer for either rendezvous implementation.
- A stable Apple signing identity for device installation, Keychain continuity, and macOS
  Screen Recording/Accessibility permission continuity.
- A deployed WSS rendezvous origin. The Cloudflare Worker is the complete included backend
  for one-use pairing and durable `/v2/availability` reconnects.
- TURN credentials for reliable operation between arbitrary networks.

The Mac must remain powered on, awake, and running the signed host. The project does not
provide arbitrary Internet wake-up. Force-quitting the iOS app stops background playback.
During an active iPhone call, opensteamer closes its audio gates rather than accepting
telephone-quality processing; an authenticated screen/control session may remain connected.

## Configure before building

1. Deploy your own backend from `services/RendezvousWorker` and configure TURN as described
   in its [deployment guide](services/RendezvousWorker/README.md). Use the WSS origin only;
   clients append `/v1/rendezvous` and `/v2/availability` themselves. Existing deployments must
   follow the guide's same-origin/staggered-rollout rule before changing a Worker name.
2. Replace the `org.example.*` identifiers with unique reverse-DNS values before first
   distribution. This includes iOS bundle IDs, Keychain service IDs, the macOS host bundle ID,
   LaunchAgent label, telemetry subsystem, and process-lock namespace. Keep them stable after
   release or existing Keychain and macOS privacy grants may no longer belong to the app.
3. Supply an Apple development team locally in Xcode or on the `xcodebuild` command line.
   Signing teams, provisioning profiles, and export credentials are intentionally untracked.
4. Supply `OPENSTEAMER_RENDEZVOUS_URL=wss://your-origin.example` to the Mac host. For iOS,
   override the Xcode build setting of the same name. An empty setting makes worldwide mode
   unavailable rather than contacting someone else's infrastructure. During migration, the Mac
   host also accepts legacy `AUDIOSTREAMER_RENDEZVOUS_URL`; when both are set, the opensteamer
   setting wins.
5. Never commit Worker/TURN credentials, invitation or activation codes, provisioning files,
   device identifiers, or captured signaling/media. See [SECURITY.md](SECURITY.md).

Production worldwide mode requires `wss://`. Plaintext `ws://` is accepted only for loopback
testing. The checked-in Node rendezvous implements the one-use `/v1` protocol, but not durable
`/v2/availability`; use the Worker for the complete current client contract.

## Build and test

Run the shared Swift and macOS regression suite from the repository root:

```sh
swift test
```

Generate and open the iOS project:

```sh
cd iOS/opensteamer
xcodegen generate
open opensteamer.xcodeproj
```

`project.yml` is authoritative. Choose your local signing team and set
`OPENSTEAMER_RENDEZVOUS_URL` before a device or distribution build. Debug and distribution
bundle IDs are deliberately distinct so physical tests cannot replace a release container.

Build the signed Mac host from the repository root:

```sh
OPENSTEAMER_HOST_CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
  macOS/scripts/build-opensteamer-host-app.sh
```

Use the signed `opensteamer Host.app` for pairing and macOS privacy permissions. A naked
SwiftPM executable is useful for deterministic tests but is not a substitute for the signed
host identity.

Test the complete Worker contract:

```sh
cd services/RendezvousWorker
npm ci
npm test
npm run check
```

Test the local/self-hosted `/v1` rendezvous separately:

```sh
cd services/Rendezvous
npm ci
npm test
```

## Pairing and unattended hosting

Run the signed host interactively for initial pairing so the short-lived invitation is not
written to a persistent LaunchAgent log:

```sh
OPENSTEAMER_RENDEZVOUS_URL='wss://your-origin.example' \
  '/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer' \
  --worldwide --duration 0
```

Enter the invitation in the iOS app. The default invitation lifetime is five minutes. A
successful authenticated commit stores durable pair records on both devices; the invitation
does not become a reusable password. Use `--reset-worldwide-pairing` to forget the viewer on
the Mac, or **Forget Paired Mac** on iOS to remove the phone-side binding.

Only after pairing should you customize and load
`macOS/LaunchAgents/org.example.opensteamer.worldwide.plist`. Make a local configured copy and add
`--rendezvous-url` plus your WSS origin to its `ProgramArguments`; do not place endpoint overrides
in launchd environment sections. Pass that configured copy through
`OPENSTEAMER_HOST_LAUNCH_AGENT_TEMPLATE` when running the deployment verifier. Remote input is off
in the template; add
`--allow-remote-control` only when you intentionally want it and have granted Accessibility
permission. Screen viewing needs Screen Recording permission.

If this Mac previously ran the pre-rebrand persistent host, follow
[HOST_MIGRATION.md](HOST_MIGRATION.md) before loading the renamed LaunchAgent. The one-time
bootout prevents two KeepAlive jobs from competing while preserving pairing and privacy grants.

## Repository layout

- `shared/` — pairing, encrypted signaling, transport, audio, video, and protocol libraries.
- `macOS/` — system capture, host coordination, packaging, verification, and LAN diagnostics.
- `iOS/opensteamer/` — SwiftUI viewer, Keychain state, lifecycle policy, and physical oracles.
- `services/RendezvousWorker/` — complete Cloudflare Worker control plane.
- `services/Rendezvous/` — single-process `/v1` rendezvous for local or self-hosted experiments.
- [WORLDWIDE_REMOTE_ACCESS.md](WORLDWIDE_REMOTE_ACCESS.md) — protocol and trust boundaries.
- [TESTING_ORACLES.md](TESTING_ORACLES.md) — claims, independent evidence, and mutation gates.
- [BRANDING.md](BRANDING.md) — lowercase naming rules and immutable compatibility identifiers.
- [HOST_MIGRATION.md](HOST_MIGRATION.md) — one-time upgrade for an existing persistent Mac host.
- [CONTRIBUTING.md](CONTRIBUTING.md) — documentation, testing, and secret-hygiene standards.

opensteamer is licensed under the [MIT License](LICENSE). Third-party components remain under
their own terms, reproduced in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
