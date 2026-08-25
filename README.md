# opensteamer

opensteamer pairs an iPhone with an awake Mac and streams Mac system audio,
optional screen video, narrowly scoped remote input, and an automatically enabled
iPhone-microphone uplink over WebRTC for the authenticated paired Mac. It prefers a direct
ICE route and can fall back to TURN. An outbound WSS rendezvous service coordinates pairing and
end-to-end-encrypted signaling; it does not carry plaintext media.

This repository is an advanced prototype, not a hosted service. Its checked-in iOS Release
configuration records the maintainer's App Store/TestFlight identity and production rendezvous
origin so release metadata is reproducible. It contains no Apple account credentials, signing
private keys, provisioning profiles, Worker or TURN secrets, invitation codes, or other deployable
credentials. Forks and independent deployments must supply their own stable identities and
infrastructure before using worldwide mode. Do not claim that a build "works anywhere" until it
passes the unrelated-network and forced-TURN gates described in
[TESTING_ORACLES.md](TESTING_ORACLES.md).

## Capabilities

- Mac system-audio capture with ScreenCaptureKit and 48 kHz stereo Opus transport.
- H.264 screen video with Show/Hide independent from audio playback.
- An opt-in adjustable portrait display for a headless Mac. It replaces the sole Apple headless
  placeholder with the same desktop plus verified iPhone-resolution choices; screen video uses
  the active framebuffer while system-audio selection remains independent.
- Optional, explicitly enabled tap, atomic drag, committed text, Backspace, and Return input.
- One-use invitation bootstrap followed by durable, Keychain-backed device pairing.
- Fresh signaling and WebRTC keys for every paired-device media connection.
- Output-only iOS playback while the media route is being established. Once the
  authenticated WebRTC peer, ICE route, and control channel are healthy, the app
  automatically requests the user's microphone permission and enables a 48 kHz mono
  uplink through the same conditional-duplex RemoteIO device. The user can still turn
  the microphone off for the current session.
- A repo-owned, true-mono Core Audio virtual-microphone design with a visible
  input-only endpoint for FaceTime and a separate hidden output-only writer.
  The host writes decoded iPhone PCM only to the hidden endpoint while the
  visible endpoint is the default input. When the authenticated
  WebRTC peer, ICE route, and control channel are all healthy, opensteamer
  automatically selects the product virtual microphone as the Mac default input before starting
  system audio. It conditionally restores the prior input after disconnect. For
  authenticated worldwide duplex audio, neither product endpoint nor either retired
  BlackHole endpoint is permitted to remain an output: worldwide mode moves only a
  forbidden virtual-output selector to a validated real output, while healthy output
  selections remain unchanged. Exact
  session-lifetime output listeners close a lock-free writer gate on every delivered
  selector change; only a fresh fenced admission can reopen it.
- Legacy Bonjour/TCP/PCM tools retained only for trusted-LAN diagnostics.

Automatic input restoration is an in-memory graceful-lifecycle guarantee; a crash,
`SIGKILL`, or power loss can prevent restoration.

The installed BlackHole 2ch v0.7.1 remains release-incompatible and is retained only
as historical failure evidence and for the separate trusted-LAN path. As of August 23,
2026, the user reports that the current side-by-side opensteamer deployment works with
simultaneous iPhone-microphone uplink and Mac-audio downlink to the iPhone. That report
describes the installed pre-cleanup build; source cleanup and future builds remain
unproven until their documented host, driver, and physical-device gates pass.

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
During an active iPhone call, opensteamer keeps authenticated streamed playback alive in
output-only mode, temporarily mutes the iPhone microphone uplink, and automatically restores
the microphone after the call ends and the exact built-in-microphone route is healthy again.

## Configure before building

1. For a fork or self-hosted deployment, deploy the backend from `services/RendezvousWorker` and
   configure TURN as described in its [deployment guide](services/RendezvousWorker/README.md).
   Use the WSS origin only; clients append `/v1/rendezvous` and `/v2/availability`. Existing
   deployments must follow the guide's same-origin/staggered-rollout rule before renaming a Worker.
2. The maintainer Release configuration is intentionally checked in. Forks must replace its
   production bundle identifier, Apple team, and rendezvous origin, plus the `org.example.*`
   development and compatibility identifiers, before first distribution. Keep identities stable
   after release or existing Keychain state, app containers, and macOS privacy grants may no
   longer belong to the app.
3. Keep iOS Release signing automatic. Change the team in `project.yml` for a fork, then let
   XcodeGen regenerate the project. Do not add a pinned provisioning profile,
   `PROVISIONING_PROFILE_SPECIFIER`, `CODE_SIGN_IDENTITY`, or an ExportOptions profile map.
   Apple account sessions, certificate private keys, and provisioning profiles remain local to
   the signing machine.
4. The maintainer iOS Release target already has its rendezvous build setting populated; the
   Debug target leaves it empty. For a fork, replace the Release value with the intended WSS
   origin. The Mac host receives
   `OPENSTEAMER_RENDEZVOUS_URL=wss://your-origin.example` locally.
5. Never commit Worker/TURN credentials, Apple signing credentials, invitation or activation
   codes, provisioning files, device identifiers, or captured signaling/media. See
   [SECURITY.md](SECURITY.md).

Production worldwide mode requires `wss://`. Plaintext `ws://` is accepted only for loopback
testing. The checked-in Node rendezvous implements the one-use `/v1` protocol, but not durable
`/v2/availability`; use the Worker for the complete current client contract.

### Checked-in iOS configuration

The authoritative values for the maintainer build are:

| Configuration field | Checked-in value |
| --- | --- |
| Protected legacy Release bundle | <code>com.elamin.AudioStreamer</code>, build `36` |
| Side-by-side TestFlight bundle | <code>com.elamin.opensteamer</code>, build `48` |
| Development team | `MSMG8CJLB3` |
| Marketing version | `0.1.0` |
| Release rendezvous | `OPENSTEAMER_RENDEZVOUS_URL` uses the production WSS Worker origin declared in [`project.yml`](iOS/opensteamer/project.yml) |
| Debug bundle | <code>org.example.AudioStreamer.dev</code> |
| Debug rendezvous | The endpoint setting is empty unless explicitly overridden locally |

Clients append `/v1/rendezvous` and `/v2/availability` to the configured origin.

`iOS/opensteamer/project.yml` is authoritative, and the generated
`opensteamer.xcodeproj/project.pbxproj` must remain XcodeGen-equivalent. The Release target
declares `ProvisioningStyle = Automatic` and `CODE_SIGN_STYLE = Automatic`. The authoritative
Release configuration does not pin `CODE_SIGN_IDENTITY` or `PROVISIONING_PROFILE_SPECIFIER`.
The separate `TestFlight` configuration and `TestFlightExportOptions.plist` use automatic
signing for `com.elamin.opensteamer`, contain no provisioning-profile map, disable automatic
build-number management, and limit the upload to internal TestFlight testing.

XcodeGen 2.45 synthesizes runnable actions for top-level schemes even when only archive was
declared. The checked-in post-generation helper therefore restores the reviewed archive-only
`opensteamerTestFlight` scheme after every project regeneration. Identity checks fail if the
generated scheme and reviewed source differ.

Historical protected-Release evidence: build 36 previously archived without
`-allowProvisioningUpdates`; Xcode development-signed that archive and its automatic App Store
export selected the current distribution assets and re-signed the IPA with Apple Distribution.
That evidence does not validate the separate `com.elamin.opensteamer` TestFlight path. Do not copy
the observed profile UUID or name into the repository.

From `iOS/opensteamer`, the guarded side-by-side operator flow is:

```sh
xcodegen generate
scripts/archive-upload-side-by-side-testflight.sh --verify-config-only
scripts/archive-upload-side-by-side-testflight.sh --verify-api-key-config-only
scripts/archive-upload-side-by-side-testflight.sh --upload-authorized-side-by-side-testflight-with-api-key
```

The API-key verification command is offline only: it proves the exact external key file,
permissions, byte digest, and Xcode argument vector, but not that Apple still accepts the key or
its role. The API-key upload flag is the explicit live release action and supplies the same pinned
authentication triplet to both archive and export. The helper accepts no caller-controlled
identity, scheme, configuration, credential, or output path, and verifies the completed archive
before export. Never use the protected `Release` configuration for this side-by-side TestFlight
deployment.

The signing machine must already have the exact external team API key and local signing assets.
The private key is stored outside the repository and must never be copied into source or retained
upload evidence.

## Build and test

### Experimental adjustable phone display

The directly distributed Mac host accepts `--virtual-phone-display`. The flag is off by default,
conflicts with `--display-id`, and currently requires the sole Apple headless placeholder display.
It intentionally rejects physical or multi-display workspaces until OpenSteamer has explicit
window-placement UX for a second desktop.

The host preserves the starting desktop mapping and verifies every required resolution before it
advertises availability. macOS Display Settings then shows `opensteamer Display`, including the
iPhone 17 Pro Retina mapping of 603x1311 logical points to 1206x2622 framebuffer pixels. On the
supported macOS host, the smallest compatibility choice is the native 750x1334 framebuffer because
WindowServer does not publish its 375x667 HiDPI counterpart. A resolution selected before
**Show** is used for the initial stream. Changing it while the screen is already visible now
automatically closes the old delivery generation and rebuilds capture at the new framebuffer size.
Valid inset geometry is also suppressed during that handoff, so the iPhone does not need a manual
Hide/Show cycle.

This compatibility path uses the exported but private macOS `CGVirtualDisplay` classes because
Apple provides no public host virtual-display or DriverKit display family. It needs no root,
driver installation, or reboot, but it is unsupported across macOS updates and is not suitable for
Mac App Store distribution. Classes and selectors are resolved dynamically, and the signed
host-app builder rejects loader-time private-class imports. The compatibility code remains
macOS-only and is never included in the iOS/TestFlight app.

The display disappears when the owning host exits. The checked-in LaunchAgent does not enable
this experimental flag.

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

Regeneration should leave the checked-in project unchanged, including restoration of the reviewed
archive-only TestFlight scheme. The endpoint-free Debug bundle is for development and simulator
tests. Use the guarded side-by-side flow above for TestFlight, and do not override its automatic
signing contract with manual signing flags.

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
bootout prevents two KeepAlive jobs from competing while preserving privacy grants and the shared
runtime exclusion boundary. The protected legacy pairing remains untouched; the new host uses its
own Keychain service and therefore presents a fresh one-time code for the side-by-side client.

## Repository layout

- `shared/` — pairing, encrypted signaling, transport, audio, video, and protocol libraries.
- `macOS/` — system capture, host coordination, packaging, verification, and LAN diagnostics.
- `iOS/opensteamer/` — SwiftUI viewer, Keychain state, lifecycle policy, and physical oracles.
- `services/RendezvousWorker/` — complete Cloudflare Worker control plane.
- `services/Rendezvous/` — single-process `/v1` rendezvous for local or self-hosted experiments.
- [MAINTENANCE.md](MAINTENANCE.md) — source ownership, generated files, and frozen evidence boundaries.
- [WORLDWIDE_REMOTE_ACCESS.md](WORLDWIDE_REMOTE_ACCESS.md) — protocol and trust boundaries.
- [TESTING_ORACLES.md](TESTING_ORACLES.md) — claims, independent evidence, and mutation gates.
- [BRANDING.md](BRANDING.md) — lowercase naming rules and immutable compatibility identifiers.
- [HOST_MIGRATION.md](HOST_MIGRATION.md) — one-time upgrade for an existing persistent Mac host.
- [CONTRIBUTING.md](CONTRIBUTING.md) — documentation, testing, and secret-hygiene standards.

opensteamer is licensed under the [GNU General Public License v2.0 only](LICENSE)
(`GPL-2.0-only`). Third-party components remain under their own terms, reproduced in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
