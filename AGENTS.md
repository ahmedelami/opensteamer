# USER-DIRECTED LEGACY RUNTIME PRESERVATION — 2026-07-25

The user explicitly requires the working legacy AudioStreamer Mac host and iPhone
client to remain usable while opensteamer development continues. Before any host
install, migration, cleanup, pairing reset, TestFlight/Release install, or process
launch, read [USER_PROTECTED_LEGACY_RUNTIME.md](USER_PROTECTED_LEGACY_RUNTIME.md).
That preservation instruction overrides conflicting cleanup/migration guidance.
Do not delete, replace, move, or concurrently run against the protected legacy
runtime without the user's explicit approval.

# Agent Guidelines

## opensteamer Product Contract

opensteamer's production remote path must connect a Mac and iPhone on unrelated
Internet-connected Wi-Fi networks from anywhere in the world. The intended user
experience is to enter one secure pairing code on the iPhone; it must not require
manual IP addresses, router configuration, or public TCP ports.

- Prefer a direct WebRTC ICE path for audio, screen video, and control traffic.
- Fall back to TURN when NAT or firewall policy prevents a direct path. TURN is an
  unavoidable reliability dependency, not the preferred media route; media must
  remain end-to-end encrypted with DTLS-SRTP while relayed.
- Use H.264 video and Opus audio on the production WebRTC path. Preserve the
  existing Bonjour/TCP/PCM implementation as a LAN and diagnostic fallback.
- Never expose the legacy audio or screen TCP listeners (ports 9000/9001) to the
  public Internet or describe them as the worldwide transport.
- Worldwide host mode must leave those legacy listeners and legacy audio capture
  disabled by default. Coexistence requires an explicit trusted-LAN opt-in.
- Treat the human-entered code as a short-lived, one-use pairing bootstrap. It
  must not become a reusable bearer token. Bind successful pairing to persistent
  device identities in Keychain and support per-device revocation/reset. The iOS
  app may retain the currently entered, still-unconsumed invitation only in
  this-device-only Keychain storage so an in-place update cannot erase it; delete
  that copy immediately after the connection accepts it or the user explicitly
  clears it.
- A code authenticates and locates an invitation; it cannot traverse NAT by
  itself. Production operation therefore depends on reachable rendezvous,
  STUN, and TURN services.
- Both apps connect outbound over authenticated TLS/WSS; the user must never
  need inbound router configuration or an exposed public listener.
- Keep one-use invitation and fresh media-session rendezvous on exactly
  `/v1/rendezvous`. Persistent paired-device availability uses the distinct
  `/v2/availability` upgrade route so an old Worker cannot silently interpret a
  new availability join as an invitation. Put the derived channel, role, and
  role-specific 32-byte admission proofs only in bounded `X-AudioStreamer-*`
  upgrade headers. The availability route must positively negotiate and echo
  `Sec-WebSocket-Protocol: audiostreamer.availability.v1`. The durable-pairing
  bootstrap on v1 must likewise negotiate `audiostreamer.pairing.v1` and use a
  namespace disjoint from legacy invitation/media rendezvous. Reject missing or
  unknown subprotocols where required, redirects, query-based joins, role-swapped
  proofs, and availability headers on the v1 route.
- Treat the `X-AudioStreamer-*`, `audiostreamer.pairing.v1`, and
  `audiostreamer.availability.v1` spellings above as the deployed v1 compatibility ABI.
  They intentionally retain the former product name; a visible-product rebrand must not
  silently change them or strand already deployed clients.
- Treat HTTP 101 and WebSocket ping/pong as transport evidence, not proof that the
  availability Durable Object still routes application messages. After the first
  valid waiting/ready state, the Mac host must send bounded host-only nonce probes.
  Only the current capability-authorized host socket may receive an acknowledgement;
  a missing acknowledgement closes that exact client and enters normal backoff.
  Probes must not alter exchange identifiers or encrypted signaling sequence state.
- Check admission before viewer occupancy, invitation consumption, or TURN
  issuance. Do not log plaintext invitations, signaling payloads, ICE candidates,
  or TURN credentials. Apart from the bounded iOS Keychain exception above, do not
  persist them outside their bounded session state.
- Preserve existing features while adding the remote path. Screen viewing must
  remain independently showable/hideable without disconnecting audio.
- Debug/XCTest iOS builds must use a bundle identifier distinct from the production
  TestFlight app so physical validation cannot replace the user's release container
  or masquerade as a TestFlight-to-TestFlight update.
- Run the persistent Mac service from the signed `opensteamer Host.app` bundle with
  the intentionally preserved identifier `com.elamin.AudioStreamer.CaptureServer`.
  That pre-rebrand identifier is compatibility data: changing it would detach existing
  Screen Recording, Accessibility, and Keychain grants. Keep the signed identity stable;
  an obsolete host bundle or a naked executable can bind
  Screen Recording or Accessibility permission to the wrong macOS code identity.
- Persist the new host's identity and durable iPhone binding only in
  `com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1`. It must never read,
  migrate, replace, or delete items in the protected legacy
  `com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1` service. The bundle
  identity and shared runtime-lock namespace remain preserved compatibility data;
  the pairing service is deliberately isolated so the side-by-side TestFlight app
  can pair without revoking the legacy iPhone's rollback pairing.
- Worldwide Mac system audio is an independent, send-only Opus track on the same
  peer connection. The production fidelity contract is 48 kHz interleaved Int16
  stereo from ScreenCaptureKit through a custom input-only WebRTC audio device,
  `stereo=1;sprop-stereo=1`, and a 192 kbps sender ceiling. Deliver each complete
  source callback directly and synchronously from one serialized source-clock path;
  never add a second 10 ms timer, ring, prebuffer, clock PLL, partial-buffer padding,
  synthetic silence, or an unbounded dispatch backlog. WebRTC's FineAudioBuffer owns
  its internal 10 ms accumulation/splitting. Keep PCM blocked until the sender track
  is active and the live factory state proves AEC, NS, AGC, HPF, and platform voice
  processing are all off; bind that approval to the exact native StartRecording
  generation so a later restart fails closed. Synchronously stop the system-audio
  sender and the `iphone-microphone` receiver/sink at every transport uncertainty
  boundary. A fresh current-generation peer/ICE/control proof is required before
  either side re-enables audio. Show/Hide
  affects video and remote input only. Keep source-PTS and RTP concealment diagnostics
  observable, and exclude iPhone Mirroring audio dynamically so a process relaunch
  cannot create a capture/playback feedback loop.
- LiveKitWebRTC `144.7559.11` has a pinned stereo input-bridge quirk: its prefilled
  `AudioBufferList` branch forwards `frameCount` Int16 elements even though interleaved
  stereo contains `frameCount * 2`. Feed Mac PCM through the synchronous nil-input
  `renderBlock` branch, which allocates and forwards the complete channel-multiplied
  buffer. Keep a regression test for arbitrary callback sizes; do not switch back to
  the direct prefilled-buffer branch or compensate by falsifying the frame count. A
  native `noErr` is not delivery proof because an inactive ADM returns success without
  invoking the block: accept a callback only after exactly one validated render copy of
  `frameCount * 2` elements. A serial dispatch queue may change pthreads, so synchronously
  notify the delegate of input interruption before delivering on a different thread.
- The iPhone must use one custom RemoteIO device. With microphone intent off, it is
  output-only and owns a `.playback` / `.default` audio session with no category
  options. For a production session handed off by authenticated pairing or reconnect,
  the first current-generation peer/ICE/control healthy boundary automatically
  establishes microphone intent and, while the app is active, requests permission
  once for that media session. The manual toggle remains an override; denial or a
  manual turn-off must not loop or auto-resume in the same session. Granted microphone
  permission, current session authorization, and healthy transport proof deliberately
  rebuild that same RemoteIO as `.playAndRecord` / `.default`, enable input bus 1, and
  deliver 48 kHz mono Int16 PCM synchronously to WebRTC as the `iphone-microphone`
  track. Turning
  the microphone off, beginning an iPhone call, losing transport health, or tearing
  down the session must synchronously revoke authorization, stop input delivery, and
  restore the output-only policy. Do not instantiate VoiceProcessingIO, synthesize
  silent keepalive audio, add a second renderer/ring, or request a voice/chat mode.
  Pull decoded Mac stereo directly from WebRTC in the RemoteIO render callback. Do
  not use `.moviePlayback`: route-dependent enhancement violates the general
  Mac-audio fidelity contract. Backgrounding hides video and revokes remote input but
  retains healthy audio; an actual interruption, private-route loss, uncertainty, or
  disconnect still mutes the native remote track. Never auto-resume when iOS omits
  `shouldResume`, and never promise playback after force-quit.
- The Mac microphone uplink targets the repo-owned
  `OpensteamerVirtualMicrophone.driver` endpoint pair. The visible endpoint is
  `com.elamin.opensteamer.virtual-microphone.input`, exactly input-only/mono,
  and is the only endpoint the host may select as default input. Decoded
  `iphone-microphone` playout is mono and may be written only to the hidden,
  exactly output-only endpoint
  `com.elamin.opensteamer.virtual-microphone.writer`. Require exact AudioQueue
  current-device UID and AudioDeviceID proof before and after start. At the
  first current-generation authenticated peer/ICE/control healthy boundary,
  before awaiting system-audio startup, select the visible product endpoint. This
  connection-level selection must not wait for the remote microphone track, RTP,
  decoded PCM, successful pulls, forwarding readiness, iOS microphone permission,
  manual microphone state, or call state. During authenticated worldwide duplex,
  the visible product endpoint may be the default input, but neither product
  endpoint nor either retired BlackHole endpoint may be the default output or
  default system output; the hidden product endpoint must never be any default.
  Before acquiring the input lease, preserve every healthy real-output selector,
  prefer the other current usable real output when replacing a forbidden virtual
  endpoint, and otherwise use the validated built-in speaker. The system-audio
  process-tap clock policy must also explicitly reject all four current/retired
  virtual-microphone UIDs, including the new output-only writer. Core Audio
  provides no atomic compare-and-set for these selectors;
  use the narrowest immediate comparison plus listener-sequence and readback fencing
  to reject observable overlap, without claiming an impossible never-overwrite
  guarantee. This invariant must not run during LAN coexistence and must never
  address the protected legacy runtime. Keep the exact default-output and
  system-output listeners installed for the complete microphone-routing session,
  from before the first ownership attempt until after the writer gate is closed and
  default-input release completes. A delivered selector notification must first close
  one lock-free writer gate synchronously, before queuing actor reconciliation; the
  AudioQueue must check that gate before startup, before pulling PCM, and immediately
  before enqueue. Reopen only inside the same listener-sequence admission commit, and
  reject queued callbacks already superseded by that exact authorization sequence.
  Keep a separate internal PCM admission closed through priming and start. Open it
  only after the requested and read-back queue format proves 48 kHz packed, signed,
  interleaved Int16 mono, device readbacks prove 48 kHz/one-channel output with no
  converter error, and two advancing
  device sample/host-time observations prove the public 48 kHz timeline projects into
  FaceTime's observed 24 kHz domain with at least 60 seconds remaining below
  `Int32.max`. Recheck the clock while running and synchronously close writer
  authorization before reporting any clock violation. Re-prove the complete format
  contract on every fresh queue startup; do not describe that startup proof as a
  continuous runtime format poll.
  Continue supplementary fenced verification on healthy transport statistics. If the
  route becomes unsafe or cannot be proven, revoke microphone forwarding and prove
  default-input ownership released before any repair write; an unproved release leaves
  the gate closed and forbids repair.
  Retry mutations with capped backoff; a newly observed route or endpoint-pair
  generation may reset that bounded retry episode. Read-only verification failures
  must not exhaust the mutation budget. After a cap, permit only a long bounded
  cooldown probe so unchanged UIDs can recover when their target becomes usable.
  The output-device callback must pull into caller-owned
  memory without allocation, logging, sleeping, network work, or a contended mutex;
  missing PCM becomes silence. Core Audio selector notification is asynchronous and
  AudioQueue enqueue has no conditional transaction, so describe the gate as the
  earliest public-API fail-close boundary; never claim it can retract an already
  in-flight HAL buffer. A missing product endpoint pair degrades only automatic
  default-input selection and microphone forwarding.
- Discover and validate the complete product endpoint pair through a read-only
  Core Audio monitor. Register the exact global/main
  `kAudioHardwarePropertyDevices` listener before the initial inventory read, resolve
  the hidden endpoint by exact UID because it is absent from normal enumeration, and
  reconcile both endpoint identities and topology on healthy media boundaries. Require
  distinct device identities, exact model UID
  `com.elamin.opensteamer.virtual-microphone.model`, visible/hidden flags, alive
  state, exact role topology (visible 1-in/0-out; hidden 0-in/1-out), native
  packed interleaved Float32 mono at 48 kHz,
  and the same exact nonzero clock domain `0x6F73564D`. Bind every forwarding attempt
  and default-input lease to the atomic pair generation. A partial or stale pair is
  unavailable. Select only the hidden monitored UID on the output AudioQueue; a
  separate generation-keyed default-input lease consumes only the visible UID.
  It must register the exact default-input listener before writing, resolve devices
  by stable UID, save the prior default-input UID before its first owned write, and
  require bounded listener plus readback proof rather than treating `noErr` as
  success. Worldwide microphone forwarding and default-input selection must never
  call the legacy route-preparation, all-default mutation, or all-default monitoring
  path.
- Retain the installed BlackHole experiment only as historical failure evidence and
  for the separate legacy LAN path; worldwide routing must never fall back to it.
  BlackHole 2ch v0.7.1 resets its local timeline counter without changing the
  zero-timestamp seed, and its observed public device time exceeded FaceTime's
  signed-32-compatible projection even after both endpoints stopped. Do not treat
  quiescence as recovery evidence for that driver.
- Before the final physical call, require a bounded public VoiceProcessingIO
  compatibility probe with exact 48 kHz mono processed-microphone capture and
  exact 48 kHz stereo playout-client readback. The playout callback must prove
  two-buffer bounded silence progress so the probe exercises the public asymmetric
  microphone/playout boundary without producing test audio. This is not FaceTime
  simulation or local/far-end acoustic proof.
- Keep the visible product microphone selected for the healthy media connection. On
  transport uncertainty, disconnect, peer replacement, endpoint removal, service startup
  failure, or graceful shutdown, synchronously initiate conditional restoration of
  the saved input UID. Resolve that UID fresh and restore only while the exact
  current generation still owns the lease and the current input is still its
  product target; never overwrite a newer user or application choice. A product or
  retired hidden-writer UID is never an admissible restoration baseline. An
  in-memory lease cannot guarantee restoration after `SIGKILL`, a crash, or power
  loss.
- Suppress iPhone-microphone forwarding whenever worldwide mode coexists with either
  legacy LAN capture mode. Suppress the associated automatic default-input lease as
  well, while worldwide signaling, system audio, screen video, control, remote input,
  and both LAN services remain supervised normally.
- An AudioQueue start is not forwarding-readiness evidence. Readiness requires the
  exact current peer, transport-authorization epoch, track generation, device
  generation, admitted track, a running queue, and successful post-start decoded pulls.
  Continuing health requires two bounded lock-free progress snapshots whose callback
  and successful-frame counts both advance.
- Worldwide-only release evidence must record the original default-input UID, prove
  the visible product microphone is the default input at the authenticated peer/ICE/control
  boundary before track or PCM proof, prove the safe-output invariant completes
  before the input lease, then require a current host-PID, peer-generation, and
  atomic-pair-generation marker proving the hidden writer passed both AudioQueue
  current-device readbacks. Prove default output and system output never change,
  and that the hidden endpoint never becomes any default,
  and prove the original input is restored after disconnect. Expected input
  transition notifications are evidence, not failures; any later output or
  system-output mutation remains a failure. Unit progress counters do not prove
  that host
  applications can read the forwarded microphone; use a separate physical probe
  that opens the visible product input by stable UID and recognizes a known remote
  challenge. The probe must not capture from the hidden writer endpoint.
- Before another FaceTime acceptance call, a no-call oracle must open the hidden output
  and visible input by their exact UIDs, bit-compare a mono nonce challenge, prove
  exact queue/native formats, unity/unmuted controls, the shared clock and
  signed-32 headroom, repeat complete quiescent lifecycles in both visible-first
  and writer-first orders, preserve all default-device selectors, and record
  teardown and quiescence. The
  supervising release runner must impose its own process deadline because synchronous
  Core Audio teardown has no in-process timeout guarantee. A failure blocks release and
  further call trials. A pass still does not prove FaceTime adoption, far-end uplink,
  or local FaceTime downlink; one final bidirectional FaceTime acceptance is required
  afterward. That call must prove the far end hears intelligible local speech and the
  local reviewed real output reproduces intelligible far-end speech while output and
  system-output selectors remain unchanged. The oracle must not
  launch, stop, replace, or otherwise address the protected legacy runtime.
- The driver-local C17 tests are the authoritative seed oracle: every global
  zero-client-to-first-client transition must establish sample frame zero with a
  fresh anchor and increment a nonzero seed; a sibling join must preserve that
  seed; repeated both-order restarts must expose no stale PCM. Direct wrapper tests,
  concurrent lifecycle/I/O/timestamp stress under ThreadSanitizer, sanitizers,
  malformed-bundle mutations, and loading the actual universal built bundle are
  mandatory. Installed public-API validation must repeat both lifecycle orders;
  public AudioQueue device time can reject an aged timeline but cannot expose the
  seed itself.
- Before the final FaceTime call, run the bounded public VoiceProcessingIO
  compatibility probe with the exact product topology. It must keep the writer
  silent until the visible input is ready, prove actual 48 kHz mono VPIO input,
  advancing callbacks/timestamps, zero LastRenderError, strong nonce correlation,
  unchanged safe outputs, exact input restoration, and drained teardown. This is a
  deterministic check of Apple's public voice-processing boundary, not a FaceTime
  simulation and not proof of private FaceTime adoption, network transmission,
  local downlink acoustics, or far-end audibility.
- Physical audio release validation must observe the RemoteIO render-input PCM, not
  merely RTP statistics or callback clocks. This is the last app-observable pre-system-output
  boundary; it does not prove what the later iOS mixer, route processing, DAC, or speaker emits.
  A claim about final acoustic output requires independent wired or external capture. Drive a
  time-varying stereo challenge containing both ordinary and >8 kHz
  content, require its bounded envelope-transition and per-channel band signatures across
  foreground, Home, and Screen Show/Hide intervals, and reject callback gaps over 25 ms,
  near-silence, clipping, audio-unit rebuilds, frozen callbacks, rapid gain pumping, cumulative
  non-sinusoidal callback shape, and cross-callback phase discontinuities. A healthy final callback
  must never erase bad callbacks earlier in the measured interval. Keep telephone-band low-pass,
  flattened/square PCM, and repeated 10 ms phase-reset mutants so call-quality or audible-click
  regressions cannot pass as full fidelity.
- An iPhone audio-session conflict must degrade audio without aborting worldwide
  signaling, screen viewing, or remote control. Observe only CallKit's aggregate
  non-ended-call count—never call identities or handles. A bare CallKit transition
  must synchronously revoke the iPhone-microphone authorization and prevent RemoteIO
  input from opening, but must not close the decoded Mac-audio track or WebRTC's
  process-wide audio gate. If iOS leaves the current playback route uninterrupted,
  continue incoming Mac audio best-effort and report that fidelity may be degraded.
  An actual AVAudioSession interruption, private-route loss, transport uncertainty,
  or native failure remains a fail-closed playout boundary and requires the existing
  safe recovery proof or explicit user action. Never claim that the app can use the
  iPhone microphone while a system call owns it, and never promise crisp stereo or
  full-band output during a call. Calls running on the Mac remain supported. Own at
  most one balanced native activation lease and keep audio diagnostics separate from
  terminal session errors.
- Mac-hosted FaceTime microphone admission must prospectively arm the exact current peer while
  iPhone CallKit is inactive, using a privacy-random next-call epoch and a strict authoritative
  known-empty Mac process baseline. Preserve that exact challenge only across the first inactive
  to active CallKit membership edge; never enable the microphone while CallKit remains inactive.
  Only the dedicated preflight-armed evidence state acknowledges that baseline; an inactive
  poison/revocation state must rotate and continue preflight rather than being treated as an ack.
  An active Mac observation received while a synchronous live CallKit read is still inactive
  contaminates that epoch and requires a fresh preflight. Active/unknown first Mac scans remain
  poisoned and silent, and peer, transport, interruption, call replacement, or teardown boundaries
  retire the prospective epoch. Continue observing aggregate call counts and revisions only—never
  call identities, handles, participants, or contacts.
- Worldwide Show/Hide must use monotonic request IDs and host acknowledgements.
  The iPhone must not claim the screen is live until Mac capture actually starts.
  Screen capture must fail closed on peer/control uncertainty and require a fresh
  acknowledged Show after recovery. Physical release evidence must separately require decoded
  frame cadence and decoded pixel-change cadence; a high frame counter over 1–2 pixel updates per
  second is a slideshow, not a live screen.
- Network adaptation must never replace an acknowledged visible screen with an opaque automatic
  bandwidth pause. Degrade through the encoding tiers to the audio-priority 1 fps video floor and
  keep that floor visible even during genuine bitrate, RTT, or send-queue pressure. Only an explicit
  Hide, authorization loss, or transport/control uncertainty may stop capture and cover the screen.
  Treat an available-outgoing-bitrate estimate at or above the current video sender ceiling as
  application-limited, not as standalone congestion proof, and use bounded higher-tier probes to
  recover quality. Retain failed-probe evidence until capacity rises, a later probe succeeds, or the
  route/peer resets; it may constrain quality but must not authorize an adaptation-driven blackout.
- Worldwide remote input is a separate, host-authorized capability and is off by
  default. It may be enabled only by launching the host with both `--worldwide` and
  `--allow-remote-control`; the trusted-LAN viewer remains view-only. Input uses the
  same direct-preferred WebRTC connection and TURN fallback as the worldwide screen.
  Every input request must be bound to the exact acknowledged Show request and a
  fresh host-issued input-session UUID; Hide, disconnect, recovery, capture failure,
  or permission loss revokes that session synchronously. Viewer disappearance and
  app inactive/background transitions must revoke the local gate and clear queued
  input synchronously. A transient inactive scene must keep the acknowledged Show
  lease and renderer mounted behind a native privacy cover so returning active can
  reveal the already-presented frame without a capture restart; entering background
  must then schedule asynchronous Hide work, even when Hide later fails. An
  initially inactive viewer must never send Show, and a late Active acknowledgement
  from a superseded Show must never reinstall input authorization. Local teardown
  state must not make a still-required network Hide collapse into a no-op. Rotate a
  visibility-operation generation before every actor-reentrant Show/Hide send so a
  superseded call or recovery boundary cannot install a stale continuation. Hide is
  successful only after an explicit Inactive acknowledgement; a failed send, timeout,
  or Active-for-Hide acknowledgement closes the peer fail closed. Do not expose even
  retained remote frames unless the scene is active and the current Show is confirmed.
- Only atomic primary taps, atomic primary drags, bounded incremental scroll deltas,
  focused-window target/selection/resize commits, bounded committed text, Backspace,
  and Return belong in the input protocol. Primary drag, scroll, and focused-window
  resize are explicitly advertised optional capabilities. Focused-window resize uses
  a separate one-shot, session-bound target generation and mandatory viewer-frame
  geometry; it never reuses primary drag or editable-focus authorization. For primary drag,
  the iPhone sends one bounded start/end action only
  after a long-press drag finishes, and the Mac constructs down/dragged/up before
  posting any of them inside one authorization window. No mouse-down state may persist
  across requests. Drag origins must be inside the aspect-fit image; completed endpoints
  may clamp to its edge. One native iOS gesture coordinator must arbitrate tap,
  immediate pan, and hold-then-drag so one touch produces only one remote intent.
  Scroll packets must carry the initial normalized anchor, the exact viewer frame size,
  and bounded incremental pixel deltas coalesced before the input queue. Each packet is
  stateless: the Mac maps the anchor under the current frame-geometry fence and posts
  one pixel-unit scroll-wheel event without persisting a remote gesture or mouse-button
  state. Scroll needs its own rate limit, and any input-session, presentation, scene,
  track, or rendered-size transition discards pending deltas. The Mac must revalidate
  focused standard-window AX identity, settable position/size, original frame, permissions,
  stable capture geometry, and target generation immediately before a direct resize. Keep
  the opposite corner anchored across application-constrained size readback, roll back a
  partial transaction when possible, and revoke the target/session when restoration is
  uncertain. Resize-mode selection may focus only a safe top-level window without clicking
  its controls. Its iPhone preview and host commit must share the same midpoint and drag-delta
  geometry, and resize-only transitions must not dismiss an exactly preserved editable focus.
  The Mac must revalidate Accessibility focus identity and
  a host-issued focus generation before every keyboard event. Secure AX text fields
  stay local and must never receive a remote focus generation; AppKit private-use
  function-key scalars are commands rather than text and must be rejected. Never transmit or log
  field contents, arbitrary key codes, modifiers, shortcuts, clipboard data, or AX
  values, including typed text. Keep committed text only in the bounded pre-send and
  native-delivery window; feedback correlation and duplicate histories must retain
  binding metadata, never the action payload. Synthesizing input needs Accessibility
  and Post Event permission, not Input Monitoring; do not request permissions the
  feature does not use.
- Treat ICE recovery and signaling recovery as separate protocols. The current
  bounded ICE-restart path may run only while the authenticated WSS session is
  alive; a lost rendezvous socket is terminal until a separately reviewed resume
  protocol exists.
- Never overlap an unanswered ICE-restart offer. Offer/answer messages are not
  generation-tagged, so rolling back and sending a newer offer could apply a late
  answer to the wrong negotiation.
- Bind every trickled candidate to the effective SDP `ice-ufrag` for its exact
  `sdpMid`/m-line section, canonicalize a missing locator from that section, and
  reject locator disagreement. Buffer at most 256 pre-description candidates and
  fail the transport closed on overflow. After the initial negotiation, discard an
  untagged or mismatched candidate rather than guessing its generation.
- A native connected callback alone is not restart proof. The Mac must first apply
  the matching restart answer, then atomically verify stable peer/ICE/control state
  before its ordered Hide/Inactive acknowledgement. Active capture acknowledgement
  must use a synchronously revocable authorization so recovery cannot race exposure.
- Keep IPv6 and continual candidate gathering enabled. Do not advertise synthetic
  PCP/NAT-PMP/UPnP candidates through the current LiveKit wrapper: it exposes no
  supported local-candidate injection or port-allocator integration.

The honest operating assumptions are that the Mac is powered on and awake, its
host service is running, Screen Recording permission is granted, and both devices
have working Internet access. Do not promise arbitrary Internet wake-up.
The implementation and automated tests cover WSS/STUN coordination plus a local
rendezvous/Simulator media-and-input slice. Do not claim a public deployment or remote
input is physically validated until the matching live-service and interactive-device
passes succeed, and do not claim "works anywhere" until TURN is active and
unrelated-network plus forced-TURN physical-device tests pass.

Every pairing-preserving installed-host update must use a fresh one-shot version
namespace and pin the exact committed predecessor pointer, evidence, rollback app,
and verification tools. Build only from a clean pushed commit/tree, prove pairing
through metadata without retrieving secrets, and never reset or re-pair. Once an
attempt leaves retained evidence, do not reuse that version for a retry.

## Efficient Internal Releases

Routine internal releases run on Ahmed's single trusted Mac from one clean,
pushed commit. Optimize that path for this actual threat model; do not repeatedly
audit immutable local dependencies as though each release ran on an untrusted CI
worker.

- The TestFlight controller must not recursively hash, stat, or deep-verify the
  complete Xcode bundle during a routine release. At every Xcode boundary, retain
  the pinned alias and filesystem identities, external-volume identity, version
  plist hashes, exact `xcodebuild` hash and signing identity, scrubbed environment,
  exact action arguments, sandbox, and destination proofs.
- Run a full `codesign --verify --deep --strict` audit only when Xcode is installed,
  replaced, moved, or its reviewed pins change. A routine release uses the pinned
  evidence recorded in source; a fresh shell process does not make the same Xcode
  installation a new trust decision.
- Reuse the enrolled, AES-256 encrypted TestFlight build-cache image across routine
  releases. Keep its key and nonblocking process lock in the private release-credentials
  directory, mount it at the fixed reviewed path, and detach it without deleting or
  resetting it. Enrollment is an explicit one-time action; missing, partial, mismatched,
  or contended cache state fails closed instead of silently falling back to a cold build.
  Provision an absent hash-keyed checkout workspace only as a lock-owned transaction:
  recover only an exact safe subset of empty private children in its deterministic sibling
  staging directory, fill the fixed `run-tmp`, `DerivedData`, `Products`, and
  `Intermediates` layout, sync, and publish it by a same-volume exclusive rename. Pin and
  verify the immutable cache contract and image before the transaction and prove the same
  contract, parent, lock, and staged inode afterward. This is normal workspace creation,
  not cache enrollment. The sole legacy-layout migration is creation of the exact empty
  mode-700 `run-tmp` parent beneath an already identity-pinned workspace. Existing
  malformed, replaced, linked, public, missing-required-child, or unexpected cache nodes
  are never repaired.
- Treat cache enrollment as a transaction. Publish its exact contract atomically and
  last, and publish a durable private pending-enrollment marker before creating its key
  or cache root. If enrollment fails or the process/host dies, the next initialization
  must use that marker under the same lock to detach an exact idle attachment and remove
  only the constrained partial key, image, and cache root before retrying. The private
  lock file may persist.
  After a killed routine run, recover only an exact idle image-to-mount association
  while holding that lock. A busy, malformed, unrelated, or ambiguous attachment still
  fails closed.
- Share package and module caches across releases, but key DerivedData by the canonical
  checkout path. Do not bind the cache to a Git commit or build number. Every release
  still creates a fresh archive destination and independently verifies its signature,
  entitlements, profile, nested code, metadata, and complete filesystem manifest.
- Treat package hashes stored in the immutable cache contract as enrollment provenance,
  independently pinned from the current release package hashes. A source-manifest change
  must not invalidate the enrolled cache; validate the current manifest and resolved graph
  before every release, and require both pin sets to agree before a fresh enrollment.
- Give each release a fresh mode-700 TMPDIR inside the encrypted cache and remove only
  that identity-pinned run directory during cleanup; never reuse a killed run's scratch
  directory or delete the shared package/module cache.
- Preserve release-stage timing output for cache attach, package resolution, effective
  settings, archive, artifact verification, upload, and post-upload verification. A
  regression that recreates/deletes the build cache, repeats whole-Xcode traversal, or
  adds redundant full-archive scans must be rejected by the product-identity mutation
  suite before it becomes the routine path.
- In App Store Connect API-key mode, bind Apple's delivery UUID to the uploaded archive,
  wait for the exact build to become VALID and INTERNAL_ONLY, and retain the parsed JSON
  status as release evidence. Detach the encrypted cache and release its process lock
  before waiting on Apple; run that wait from an independent private TMPDIR with a
  script-level deadline so a stalled network cannot block the next release. Legacy
  Xcode-account mode must say explicitly that this end-to-end processing wait was skipped.
- Reuse gates already proven for the same immutable commit and invocation. Do not
  rerun unchanged test suites, source audits, account checks, or artifact checks
  unless their bound identity changed or the previous check failed.
- Run independent work concurrently. Archive/upload, App Store Connect processing
  observation, and read-only host preparation need not wait on one another.
- Report only meaningful stage changes, failures, required user action, and final
  proof. Prefer targeted queries and log suffixes to broad repeated reads.
- Keep routine release orchestration separate from exceptional recovery. A changed
  identity, failed preflight, consumed one-shot namespace, or ambiguous live state
  still requires the complete guarded recovery path.

## Commits

Release validation must follow [TESTING_ORACLES.md](TESTING_ORACLES.md). A source string, mocked
state transition, UI label, or stale artifact is not sufficient proof of a production behavior;
use the independent artifact/runtime oracle and mutation described there.

Every commit message should include a concise `Why:` section and a concise `What:` section.

- `Why:` explains the reason for the change: the problem, requirement, or tradeoff.
- `What:` summarizes the implementation at a level where a reviewer can understand the shape of the change.
- Keep both sections short by default. Add detail only when it is needed to understand the change.
- Keep commits focused on one concern. Split unrelated app, server, tooling, documentation, and verification changes.
- Prefer commits that can be reviewed independently and preserve useful checkpoints.

## Code Comments

Prefer self-documenting names and structure over comments.

- Add comments only when local context, a non-obvious constraint, or a platform/API quirk would otherwise be easy to miss.
- Keep comments short and factual.
- Do not narrate code that is already clear from names and types.
