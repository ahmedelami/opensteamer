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
with a 192 kbps sender ceiling. iOS pulls decoded stereo directly from one output-only RemoteIO
device using an `AVAudioSession` playback/default configuration. It does not open the microphone,
use VoiceProcessingIO, or select a call-oriented mode.

Backgrounding hides video and revokes input while retaining healthy audio. Calls, interruptions,
private-route loss, and transport uncertainty close the native audio gates. Recovery requires new
advancing output evidence; it never claims crisp media audio during an active iPhone call.

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

App-observable RemoteIO PCM is the final boundary the app can inspect, not proof of the later iOS
mixer, route processing, DAC, speaker, or headphones. See [TESTING_ORACLES.md](TESTING_ORACLES.md)
for the exact evidence and negative mutations required for release claims.
