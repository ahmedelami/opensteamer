# AudioStreamer Release Oracles

Passing code-path assertions is not release evidence. Each production claim needs an
independent observable outcome from the artifact that actually ran, plus a negative mutation
that demonstrates the oracle fails when that outcome is broken. This document distinguishes
implemented gates from the remaining release boundaries; it is not a feature-completeness claim.

## Critical Guarantees

| Guarantee | Implemented primary oracle | Representative mutation that fails |
| --- | --- | --- |
| Correct Mac host | Freshly build the signed app, verify its actual plist and designated requirements, then require the installed app and live launchd PID to use the same executable and CDHashes. The live process must map the verified installed LiveKitWebRTC framework vnode, and the loaded launchd job must match the checked-in program arguments, environment, `RunAtLoad`, and `KeepAlive` policy. | Run a legacy app, naked SwiftPM binary, wrong Team ID, renamed bundle, symlink, stale installed build or mapped framework, changed launch arguments, or endpoint/auth/DYLD environment override. |
| Durable paired reconnect | The physical driver keeps one non-secret pair fingerprint across three distinct host PIDs and an iPhone cold launch, while requiring a freshly authenticated live media route after every reconnect. | Retain the UI label but delete the Keychain record, reuse a reconnect sequence, or reconnect signaling without advancing inbound/native media. |
| Full-quality audio | The deterministic native loopback evaluates the full aligned 800 ms decoded stereo waveform—including independent 4–15 kHz pilots—for completeness, silence runs, clipping, gain, channel separation, correlation, bandwidth, and both edges. Separate conversion tests exercise source formats. On iPhone, the physical gate drives a coded 500 ms challenge alternating 997/1499 Hz at high level with 8003/11003 Hz at low level. It requires inbound RTP energy plus final RemoteIO PCM/callback/frame density, per-channel high/low-band zero-crossing rates, bounded envelope and cumulative per-callback waveform-shape rates, cumulative cross-callback continuity, no near-silence, no recovery rebuild, no callback gap over 25 ms, and the playback/default 48 kHz stereo route. | Telephone-band low-pass, first/last or periodic silence, dropped/repeated samples, frozen callbacks, repeated phase-reset 10 ms blocks, rapid 10 ms gain pumping, clipped or flattened/square PCM followed by one healthy callback, mono folding, half-stereo delivery, swapped or impossible band rates, VoiceProcessingIO, callbacks that consume no PCM, recurring 30/40 ms native callback gaps, a late one-shot increment, or counters too sparse for elapsed time. |
| Background audio | The built-app test inspects `UIBackgroundModes=audio`. The physical gate presses Home for 35 seconds, returns to the app, and requires the original session generation to have accumulated real-time inbound duration/energy and final native rendered PCM with the coded high/low-band and envelope signatures over the entire interval, without a callback gap, near-silence callback, or audio-unit rebuild. | Remove the capability, stop or mute the track on Home, freeze/replay one callback, suspend RemoteIO, stall for most of the interval, catch counters up only after foregrounding, or reconnect on foreground. |
| Screen Show/Hide | The driver places a nonsecret changing pattern on every Mac display. The physical gate binds an authenticated Show/Active acknowledgement to a stable sequence of at least 12 decoded frames/sec whose independently sampled salted pixel digest changes at least 3 times/sec, then requires a newer authenticated Hide/Inactive acknowledgement and proves audio continues in the same media session. | Acknowledge Show without advancing decoded frames, reuse a stale acknowledgement/renderer, emit one late frame, report 60 fps while pixels change only 1–2 times/sec, advance timestamps over frozen pixels, stop the deterministic visual challenge, or Hide by reconnecting the media session. |

The current Screen gate proves that decoded pixel changes overlap a live deterministic host
challenge at the production renderer boundary, but the decoded pixels do not yet carry a
cryptographic nonce that identifies that exact challenge. It therefore does **not** independently
prove source identity, GPU presentation, or host capture-process quiescence after Hide. The
current remote-input check proves only that a fresh authenticated capability is present;
it does **not** yet drive a disposable Mac target and observe real AX/model mutations. Those claims
remain release-incomplete and must not be inferred from acknowledgements or screenshots.

## Gate Rules

- Prove provenance first: device, app build, code identity, executable path, PID, and fresh
  artifact directory.
- Prefer counters, decoded content, native target state, and exact before/after deltas over labels
  that merely restate internal state.
- Cross-check at least two independent layers for physical media tests, such as host source/RTP
  evidence and iPhone decoded/native-render evidence.
- Require a positive baseline and one-field-at-a-time negative mutants. A test that has never
  been seen rejecting its target defect is not a regression guard yet.
- Never reuse an existing `.xcresult`, log suffix, screenshot, or summary. Bind evidence to the
  current device, PID, build, and run.
- Use bounded ratios for network loss, concealment, and jitter. Reserve exact zero assertions for
  deterministic in-process tests where zero is truly invariant.
- Keep manual sensory checks as exploratory evidence. They do not replace a repeatable waveform,
  pixel/nonce, counter, or target-state oracle.

## Execution and Claim Boundary

- `swift test` covers the deterministic protocol, security, transport waveform, mutation, Mac
  artifact, and validation-driver contracts.
- A **signed** Simulator `xcodebuild test` run covers iOS lifecycle, Keychain, accessibility
  serialization, native PCM publication, and evaluator mutations. An unsigned run is not a
  substitute because it cannot exercise the production Keychain access group.
- A generic-device UI `build-for-testing` proves the physical test source compiles; it does not
  execute a physical oracle.
- The production-bundle physical driver binds evidence to a fresh artifact directory, physical
  device identity, installed bundle/build number, signed Mac host, changing host PIDs, session
  identity, and current `.xcresult`. `devicectl` cannot independently prove that the installed
  bytes arrived through TestFlight, so App Store Connect/TestFlight remains the authority for that
  distribution fact.
- The driver binds every retained attachment's name and metadata to its exact XCTActivity. Current
  `xcresulttool` activity JSON does not expose attachment bytes, so attachment contents are
  supplemental audit material; the executing XCTest assertions and pass/fail result—not the
  attachment name—remain the release oracle.
- The waveform gate uses the production Opus/WebRTC path at its 48 kHz stereo target format. It
  does not by itself prove ScreenCaptureKit's source-format conversion; those conversion cases are
  covered separately.
- A newly instrumented physical claim is release-complete only after the matching app build runs
  the non-skipping physical gate and produces a fresh passing result. Build-only evidence, an older
  TestFlight build, a screenshot, or a prior manual pass must not be reported as that result.
