# Worldwide remote-access architecture

## Scope

Worldwide mode connects a Mac host and iPhone viewer through outbound-only WSS coordination,
then carries audio, screen video, and optional control over WebRTC. Direct ICE is preferred;
TURN relays DTLS-SRTP ciphertext when a direct path cannot cross the networks. Legacy TCP ports
9000 and 9001 are trusted-LAN diagnostics and are disabled by default in worldwide mode.

The Mac must be awake and already running the host. A pairing code authenticates a short-lived
invitation; it cannot traverse NAT or replace rendezvous, STUN, or TURN infrastructure.

The `audiostreamer.pairing.v1` and `audiostreamer.availability.v1` subprotocol names below are
deployed v1 compatibility ABI. They intentionally retain the former product name so renamed
clients continue to interoperate with existing hosts and Workers.

## Trust boundaries

- The rendezvous Worker sees connection timing, roles, bounded routing capabilities, and opaque
  encrypted envelopes. It does not receive the invitation secret or plaintext signaling/media.
- A TURN service sees endpoint addresses, timing, and traffic volume while relaying encrypted
  DTLS-SRTP packets. It cannot decrypt WebRTC media.
- Device identities and pair-root material remain in this-device-only Keychain items on the Mac
  and iPhone. Every media connection derives fresh keys.
- The invitation is a one-use capability with a five-minute default lifetime, not a reusable
  bearer password. Admission is checked before occupancy, consumption, or TURN issuance.
- Remote input is a separate Mac-side capability, disabled unless the host starts with
  `--allow-remote-control` and macOS grants Accessibility permission.

## Pairing lifecycle

1. The Mac generates a cryptographically random invitation and uses its stable signing identity.
2. Both peers join `/v1/rendezvous` with separate host/viewer admission proofs. Pairing clients
   negotiate the `audiostreamer.pairing.v1` subprotocol.
3. The invitation-authenticated exchange performs ephemeral key agreement and signed transcript
   validation. Signaling envelopes are end-to-end encrypted and sequence-bound.
4. A crash-recoverable commit completes before either endpoint treats the durable pair as active.
5. The Worker tombstones the consumed invitation. Both devices retain independent persistent
   identities and the authenticated pair record, not a reusable copy of the invitation.

Interrupted pairing can resume only within its authenticated state boundary. A code that has
expired, been consumed, or failed admission cannot be made valid by local persistence.

## Paired reconnect lifecycle

1. Host and viewer derive disjoint role capabilities and join `/v2/availability` using the
   `audiostreamer.availability.v1` subprotocol.
2. The Worker creates a fresh exchange identifier. Capability possession coordinates availability;
   endpoint signatures still authenticate the devices.
3. The peers exchange bounded, encrypted reconnect messages and create a new one-use media
   rendezvous.
4. WebRTC negotiates fresh DTLS-SRTP keys. Old candidates, exchanges, and signaling sequences are
   rejected rather than guessed across recovery generations.

Availability and media rendezvous are deliberately distinct. Losing the active signaling socket
is terminal for that media connection until the reviewed reconnect protocol creates a fresh one.

## Media and control

### Audio

The Mac captures system audio with ScreenCaptureKit, converts complete source callbacks to 48 kHz
interleaved Int16 stereo, and feeds a custom input-only WebRTC device. Opus is negotiated for stereo
with a 192 kbps sender ceiling.

iOS pulls decoded stereo directly from one custom RemoteIO device. The default
policy is output-only `AVAudioSession` playback/default. For production sessions
handed off by authenticated pairing or reconnect, the first current-generation
healthy peer/ICE/control boundary automatically establishes microphone intent and,
while the app is active, requests permission once for that media session. The manual
toggle remains an override; denial or a manual turn-off does not loop or auto-resume
in that session. Granted permission, current session authorization, and healthy
peer/ICE/control state can rebuild the same device as playAndRecord/default, enable
input bus 1, and send a separate 48 kHz mono Opus track with stable ID
`iphone-microphone`. VoiceProcessingIO and voice/chat modes are not used.

The Mac offers that second audio transceiver as recvOnly and accepts only the
`iphone-microphone` track. Its decoded PCM is written only to the installed hidden
BlackHole mirror `BlackHole2ch_2_UID`; the output AudioQueue must read back that
exact current-device UID before and after start. The design leaves the distinct
visible `BlackHole2ch_UID` input for FaceTime and other Mac clients; only a fresh
physical call can prove that the target client adopted and transmitted that route.

Independently of remote-track arrival, the first current-generation authenticated
peer/ICE/control healthy boundary acquires a connection-level default-input lease.
Before `WorldwideScreenService` awaits system-audio startup, that lease selects the
canonical installed `BlackHole2ch_UID` endpoint as the macOS default input. It does
not wait for an `iphone-microphone` callback, RTP, decoded PCM, successful pulls,
forwarding readiness, iOS microphone permission, the manual microphone switch, or
iPhone call state. Already-safe default output and system-output devices are
preserved; if either selector points at a visible or hidden BlackHole endpoint,
the safe-output invariant repairs it to an eligible physical output before the
input lease is acquired.

The two output-selector listeners remain installed for that entire routing
session. Their callback closes a lock-free hidden-writer gate before scheduling
actor work. Queue startup, PCM pull, and enqueue all fail closed on that gate; a
fresh listener-sequence admission commit is the only path that reopens it. A queued
callback whose sequence was already incorporated into that commit cannot later
revoke the replacement admission. Before repairing an unsafe output, the host also
requires proven release of the visible-input lease. Healthy statistics still perform
an additional readback, but they are not the primary notification path. Core Audio
notifications and AudioQueue enqueue are separate public APIs, so one buffer already
in flight at the HAL boundary cannot be retracted; the gate closes the earliest
observable subsequent work without claiming atomic selector/enqueue behavior.

BlackHole discovery is read-only. The host registers a Core Audio device-list
listener before its initial inventory read, resolves the hidden endpoint by exact UID,
and publishes an epoch plus a monotonic atomic-pair generation. It requires distinct
visible/hidden identities, the expected shared model UID, alive and visibility flags,
2-in/2-out topology, and 48 kHz; healthy media boundaries reconcile the pair even when
the hidden endpoint is absent from normal enumeration. The connection-level input
coordinator supports both orderings:
an available snapshot may precede connection health, or the healthy connection may
wait for the first current snapshot that makes BlackHole available. Each output
attempt remains separately bound to its exact monitor snapshot, peer generation,
transport-authorization epoch, and remote-track generation.

Before its first owned input write, the lease saves the prior default-input stable
UID. It can target only the visible endpoint. It installs the exact default-input listener before writing and requires
bounded notification plus stable-UID readback proof. On transport uncertainty,
disconnect, peer replacement, device removal, startup failure, or graceful
shutdown, restoration is initiated synchronously. The prior UID is resolved fresh
and restored only if the same generation still owns the lease and the current
input remains BlackHole; a newer user or application choice is not overwritten.
Stale generations cannot restore over a replacement connection. A missing device,
failed write, or failed proof degrades this convenience without ending worldwide
signaling, system audio, screen video, or control. Because the lease is in memory,
restoration cannot be guaranteed after a crash, `SIGKILL`, or power loss.

Device removal, transport uncertainty, or a runtime AudioQueue failure still
synchronously mutes the exact current remote track and retires only its owning
output. A later device or transport generation can retry once without allowing
stale completions to affect a replacement.

AudioQueue startup alone is not considered ready. A forwarding snapshot reports the
policy, phase, visible-input/hidden-writer availability, writer-selection proof,
device and transport generations, exact admission state, and lock-free
post-start callback progress. Readiness requires a successful decoded pull; continuing
health requires two bounded observations with advancing callback and successful-frame
counts. These counters prove forwarding activity, not nonzero acoustic content.

When trusted-LAN services coexist with worldwide mode, iPhone-microphone forwarding
and its automatic default-input lease are suppressed for both BlackHole-input and
ScreenCaptureKit LAN capture. This prevents a local capture/forwarding loop without
stopping worldwide signaling, system audio, screen viewing, control, remote input,
or either LAN listener.

Backgrounding hides video and revokes remote input while retaining healthy
audio. A bare CallKit transition revokes microphone capture but does not
deliberately mute incoming Mac audio. An actual interruption, private-route
loss, native failure, or transport uncertainty still closes the affected native
gates and requires fresh recovery evidence.

### Video

ScreenCaptureKit frames are encoded as H.264. The viewer sends a monotonic Show request, and the
Mac reports Active only after capture starts. Hide must stop capture before an Inactive
acknowledgement. Audio remains independent of screen visibility.

### Remote input

The data-channel protocol permits primary taps, one atomic primary drag, bounded committed text,
Backspace, and Return. It does not expose arbitrary key codes, modifiers, shortcuts, clipboard
contents, or accessibility values. Each action is bound to the currently acknowledged screen and
a fresh host-issued input session. Hide, disconnect, backgrounding, recovery, permission loss, or
capture failure revokes that authorization synchronously.

## ICE and TURN

STUN-only connectivity may work across permissive NATs but is not globally reliable. Configure TURN
for restrictive NAT, CGNAT, enterprise firewalls, and UDP-blocked networks. `--force-relay` exists
to prove the relay path during acceptance testing; it is not the normal low-latency preference.

The Worker supports Cloudflare Realtime TURN credential provisioning through server-side secrets:

- `CLOUDFLARE_TURN_KEY_ID`
- `CLOUDFLARE_TURN_API_TOKEN`
- `TURN_CREDENTIAL_TTL_SECONDS`
- `TURN_FETCH_TIMEOUT_MS`

Both provider secrets are required together and stay server-side. Clients receive only short-lived
ICE credentials. Direct-only deployments may configure `STUN_URLS`, but must not describe that as
dependable worldwide access. Provider pricing, quotas, and availability are external operational
dependencies.

## Failure behavior

- Any peer, ICE, control, or capture uncertainty synchronously revokes affected media/input gates.
- A failed or incorrectly acknowledged Hide closes the peer fail-closed.
- Availability application probes supplement WebSocket ping/pong; missing acknowledgements force
  the host to reconnect rather than trusting a ghost socket.
- iOS call/interruption policy can disable audio without aborting an otherwise authenticated
  screen/control session.
- When iOS does not authorize automatic resume, the user must explicitly resume.
- Invitations, admission proofs, signaling payloads, ICE candidates, TURN credentials, and input
  text must not appear in logs or telemetry.

## Validation status

| Boundary | Status |
| --- | --- |
| Protocol, crypto, replay, lifecycle, and mutation suites | Implemented as automated tests |
| Signed Simulator lifecycle and artifact gates | Available; require local signing |
| WSS/STUN and TURN provisioning code | Implemented; deployment-specific runtime proof required |
| Unrelated-network direct connection | Physical acceptance pass required per deployment |
| Forced-TURN connection | Physical acceptance pass required before “works anywhere” |
| Remote-input native target mutation | Physical target-state oracle still required |
| Final speaker/headphone fidelity | External source-correlated acoustic capture still required |
| Cryptographic screen-source/GPU presentation proof | Still required |

Worldwide-only BlackHole acceptance must record the original default input before
connection, prove BlackHole is the default input at the authenticated
peer/ICE/control boundary before remote-track or PCM proof, prove the default output
and system-output UIDs remain unchanged, prove neither BlackHole endpoint becomes an
output default, require a current PID/peer/pair-generation hidden-writer readback marker,
and prove the original input is restored
after disconnect. Expected default-input notifications around selection and
restoration must not fail the oracle. It must also open BlackHole's input side by
stable UID, drive a known time-varying remote microphone challenge, and independently
require advancing frames and pattern recognition. A forwarding snapshot or successful
AudioQueue start is not host-visible PCM proof.

App-observable RemoteIO PCM is the final boundary the app can inspect, not proof of the later iOS
mixer, route processing, DAC, speaker, or headphones. See [TESTING_ORACLES.md](TESTING_ORACLES.md)
for the exact evidence and negative mutations required for release claims.
