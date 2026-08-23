# Repository maintenance map

This document classifies repository areas by change policy. It describes source
ownership and maintenance boundaries, not the current installed or deployment
state.

## Read first

- `CONTRIBUTING.md` defines branch names, documentation, secret hygiene, and
  validation order.
- `AGENTS.md` is the normative product and safety contract.
- `BRANDING.md` lists compatibility identifiers that must not be renamed.
- `WORLDWIDE_REMOTE_ACCESS.md` describes architecture and trust boundaries.
- `TESTING_ORACLES.md` defines the evidence required for release claims.
- `USER_PROTECTED_LEGACY_RUNTIME.md` defines the user-authorized external-runtime
  boundary.
- `HOST_MIGRATION.md` records the consumed migration design and retained history.

## Actively maintained product source

| Area | Source of truth |
| --- | --- |
| iPhone app | `iOS/opensteamer/Sources`, configured by `iOS/opensteamer/project.yml` |
| Mac production host | `macOS/Sources/CaptureServer`, `macOS/Sources/CaptureCore`, and `macOS/OpensteamerHost/Info.plist` |
| Shared protocol, session, and media libraries | `shared/Sources`; target boundaries are declared in `Package.swift` |
| Virtual microphone | `macOS/VirtualAudioDriver/Driver`, `src`, `include`, and `Resources` |
| Public rendezvous Worker | `services/RendezvousWorker/src`, `wrangler.toml`, and its package manifest |
| Standalone rendezvous implementation | `services/Rendezvous/src` |
| Deployment configuration | `macOS/LaunchAgents/org.example.opensteamer.worldwide.plist` |

`macOS/Sources/CaptureCLI`, `PCMClient`, `PCMPlayer`, and `Server`, along with
`macOS/RelayBridge` and `macOS/Tools`, are maintained LAN or diagnostic tooling.
They are not the production worldwide transport.

## Compatibility-sensitive active source

Former-brand bundle identifiers, Keychain services, lock names, WebSocket
headers, subprotocols, data-channel names, and cryptographic domains are deployed
ABI, not obsolete naming. Follow `BRANDING.md`; never perform a global rename.

Prefer files that match one state owner or protocol concern. Move independent
top-level policies and models into the same SwiftPM target without widening
access. Keep actor state machines, private real-time callback state, and C or
Objective-C translation-unit internals together until a new owned abstraction can
replace their private coupling. Do not scatter one owner across extensions merely
to shorten a file.

## Reusable verification

- Swift tests live in `iOS/opensteamer/Tests`, `iOS/opensteamer/UITests`,
  `macOS/Tests`, and `shared/Tests`.
- Repository identity and release checks live under root `scripts/`.
- Generic host build and read-only verification use
  `macOS/scripts/build-opensteamer-host-app.sh` and
  `macOS/scripts/verify-*.sh`.
- Generic driver verification uses `macOS/VirtualAudioDriver/tests`,
  `macOS/VirtualAudioDriver/scripts/build-driver.sh`,
  `verify-driver-bundle.sh`, and their test scripts.
- Physical and release drivers live in `iOS/opensteamer/OracleTestSupport` and
  `iOS/opensteamer/scripts`.

Use `TESTING_ORACLES.md` to select evidence. Source tests alone do not establish
deployment or physical behavior.

## Generated and local artifacts

- `iOS/opensteamer/project.yml` is the Xcode project source of truth.
  `iOS/opensteamer/opensteamer.xcodeproj` is generated but intentionally tracked.
- `iOS/opensteamer/TestFlightScheme/opensteamerTestFlight.xcscheme` is the
  reviewed archive-only source copied into the generated project by
  `iOS/opensteamer/scripts/restore-archive-only-testflight-scheme.sh`.
- `Package.resolved` and npm `package-lock.json` files are generated dependency
  locks but intentionally tracked. Update them through their package managers.
- `.build`, `build`, `DerivedData`, `.xcresult`, `.xcarchive`, `.ipa`,
  `node_modules`, and `.wrangler` output are local or generated and ignored.
- Never reuse an old result bundle or evidence directory as fresh release proof.

## Frozen release and recovery capsules

Do not refactor, rename, deduplicate, reformat, or update hashes in consumed,
versioned transaction code:

- `macOS/scripts/migrate-opensteamer-host.sh` and
  `opensteamer-host-migration-controller.rs`.
- `update-opensteamer-host-post-v20.sh` and its controller.
- Every matching `update-opensteamer-host-paired-v2.sh` through `v8.sh` and
  `opensteamer-host-paired-v2-update-controller.rs` through `v8`.
- The local-mono-trial launcher, controller, and exact rescue script.
- Versioned v7 driver packaging, verification, parser, and route-guardian files.

These files preserve exact reviewed bytes and SHA-256 relationships. New
deployment logic must receive a new versioned capsule; historical pins must not
be rewritten to accept new bytes.

The generic host verifier files are also pinned companions of the consumed v20
capsule. If reusable verification must evolve, add a new versioned verifier or
snapshot the historical bytes first. Do not silently retarget the old capsule.

## External protected state

Never clean, migrate, launch, replace, or inspect protected external artifacts
outside an explicitly authorized guarded workflow. The authority is
`USER_PROTECTED_LEGACY_RUNTIME.md`, including:

- `/Applications/AudioStreamer Host.app`
- `/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist`
- the protected legacy Keychain and process-lock namespaces
- the protected recovery app
- active migration or update pointers and evidence beneath
  `/Users/ahmed/Library/Application Support/opensteamer`

Legacy and new hosts must never run concurrently.
