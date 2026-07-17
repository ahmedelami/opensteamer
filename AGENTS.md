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
- The public rendezvous URL is exactly `/v1/rendezvous`. Put the derived
  channel, role, and separate 32-byte admission proof only in bounded
  `X-AudioStreamer-*` upgrade headers; reject redirects and query-based joins.
- Check admission before viewer occupancy, invitation consumption, or TURN
  issuance. Do not log plaintext invitations, signaling payloads, ICE candidates,
  or TURN credentials. Apart from the bounded iOS Keychain exception above, do not
  persist them outside their bounded session state.
- Preserve existing features while adding the remote path. Screen viewing must
  remain independently showable/hideable without disconnecting audio.
- Debug/XCTest iOS builds must use a bundle identifier distinct from the production
  TestFlight app so physical validation cannot replace the user's release container
  or masquerade as a TestFlight-to-TestFlight update.
- Worldwide Mac system audio is an independent, send-only Opus track on the same
  peer connection. With the pinned WebRTC build it is truthfully 48 kHz mono:
  enter manual ADM rendering before track creation, disable microphone/voice
  processing, bound injection latency, and synchronously mute/flush both sender
  and receiver at every transport uncertainty boundary. A fresh current-generation
  peer/ICE/control proof is required before either side re-enables audio. Show/Hide
  must affect video and remote input only.
- The iPhone must use genuine playback plus the Background Audio capability so a
  user-started stream can continue across Home/lock. Do not synthesize silent audio
  as a keepalive. Backgrounding hides video and revokes input but retains healthy
  audio; interruption, private-route loss, uncertainty, and disconnect mute the
  native remote track itself. Never auto-resume when iOS omits `shouldResume`, and
  never promise playback after the user force-quits the app.
- An iPhone audio-session conflict must degrade audio without aborting worldwide
  signaling, screen viewing, or remote control. Gate manual WebRTC playback before
  signaling; retry `.moviePlayback` as `.default` only for configuration-stage
  `NSOSStatusErrorDomain` `badParam`, never for activation failure. Own at most one
  balanced native activation lease, recover only from explicit lifecycle/route
  events or user action, and keep audio diagnostics separate from terminal session
  errors.
- Worldwide Show/Hide must use monotonic request IDs and host acknowledgements.
  The iPhone must not claim the screen is live until Mac capture actually starts.
  Screen capture must fail closed on peer/control uncertainty and require a fresh
  acknowledged Show after recovery.
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
