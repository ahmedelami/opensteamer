# Agent Guidelines

## AudioStreamer Product Contract

AudioStreamer's production remote path must connect a Mac and iPhone on unrelated
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
- Run the persistent Mac service from the signed `AudioStreamer Host.app` bundle with
  identifier `org.example.AudioStreamer.CaptureServer`. Keep that privacy-visible name
  unique and stable: an older `MacCaptureHost.app` or a naked executable can bind
  Screen Recording or Accessibility permission to the wrong macOS code identity.
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
  generation so a later restart fails closed. Synchronously mute both sender and
  receiver at every transport uncertainty boundary. A fresh current-generation
  peer/ICE/control proof is required before either side re-enables audio. Show/Hide
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
- The iPhone must use one custom output-only RemoteIO device, a `.playback` audio
  session in `.default` mode with no category options, and the Background Audio capability so a
  user-started stream can continue across Home/lock. Do not synthesize silent audio
  as a keepalive, open a microphone input bus, instantiate VoiceProcessingIO, use a
  call-oriented audio-session category/mode, or add a second renderer/ring. Pull
  decoded stereo directly from WebRTC in the RemoteIO render callback. Do not use
  `.moviePlayback`: Apple documents route-dependent output enhancement for that mode,
  which violates the general Mac-audio fidelity contract. Backgrounding
  hides video and revokes input but retains healthy
  audio; interruption, private-route loss, uncertainty, and disconnect mute the
  native remote track itself. Never auto-resume when iOS omits `shouldResume`, and
  never promise playback after the user force-quits the app.
- Physical audio release validation must observe the output-only RemoteIO render-input PCM, not
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
  signaling, screen viewing, or remote control. Gate manual WebRTC playback before
  signaling; never fall back from `.playback` / `.default` / no options to a movie,
  chat, record, mixing, or call-oriented configuration. Observe only CallKit's aggregate
  non-ended-call count—never call identities or handles. If an iPhone call already exists at
  startup or begins later, synchronously close both the decoded-track gate and WebRTC's native
  audio gate while leaving the peer, screen, and control alive. Rotate a dedicated audio-policy
  generation at both call boundaries so cancelled or non-cooperative pre-call reads cannot
  publish stale proof after a fast start/end transition. After the final call ends, rebuild audio
  and require a new advancing RemoteIO proof window before claiming playback; never claim crisp
  media audio during an active iPhone call. Calls running on the Mac remain supported. Own at
  most one balanced native activation lease, recover only from explicit lifecycle/route events
  or user action, and keep audio diagnostics separate from terminal session errors.
- Worldwide Show/Hide must use monotonic request IDs and host acknowledgements.
  The iPhone must not claim the screen is live until Mac capture actually starts.
  Screen capture must fail closed on peer/control uncertainty and require a fresh
  acknowledged Show after recovery. Physical release evidence must separately require decoded
  frame cadence and decoded pixel-change cadence; a high frame counter over 1–2 pixel updates per
  second is a slideshow, not a live screen.
- Worldwide remote input is a separate, host-authorized capability and is off by
  default. It may be enabled only by launching the host with both `--worldwide` and
  `--allow-remote-control`; the trusted-LAN viewer remains view-only. Input uses the
  same direct-preferred WebRTC connection and TURN fallback as the worldwide screen.
  Every input request must be bound to the exact acknowledged Show request and a
  fresh host-issued input-session UUID; Hide, disconnect, recovery, capture failure,
  or permission loss revokes that session synchronously. Viewer disappearance and
  app inactive/background transitions must revoke the local gate and clear queued
  input before scheduling asynchronous Hide work, even when Hide later fails. An
  initially inactive viewer must never send Show, and a late Active acknowledgement
  from a superseded Show must never reinstall input authorization. Local teardown
  state must not make a still-required network Hide collapse into a no-op. Rotate a
  visibility-operation generation before every actor-reentrant Show/Hide send so a
  superseded call or recovery boundary cannot install a stale continuation. Hide is
  successful only after an explicit Inactive acknowledgement; a failed send, timeout,
  or Active-for-Hide acknowledgement closes the peer fail closed. Do not render even
  retained remote frames unless the scene is active and the current Show is confirmed.
- Only atomic primary taps, atomic primary drags, bounded committed text, Backspace,
  and Return belong in the first input protocol. Primary drag is an explicitly
  advertised optional capability: the iPhone sends one bounded start/end action only
  after a long-press drag finishes, and the Mac constructs down/dragged/up before
  posting any of them inside one authorization window. No mouse-down state may persist
  across requests. Drag origins must be inside the aspect-fit image; completed endpoints
  may clamp to its edge. The Mac must revalidate Accessibility focus identity and
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
The current worktree and deployment prove public WSS/STUN coordination plus a
local rendezvous/Simulator media-and-input slice. Do not claim remote input is
physically validated until an interactive physical-device pass succeeds, and do not
claim "works anywhere" until TURN is active and unrelated-network plus forced-TURN
physical-device tests pass.

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
