# Beluga Release Oracles

Passing code-path assertions is not release evidence. Each production claim needs an
independent observable outcome from the artifact that actually ran, plus a negative mutation
that demonstrates the oracle fails when that outcome is broken. This document distinguishes
implemented gates from the remaining release boundaries; it is not a feature-completeness claim.

## Critical Guarantees

| Guarantee | Implemented primary oracle | Representative mutation that fails |
| --- | --- | --- |
| Exact product identity | `check-product-identity.sh` parses the Swift package, XcodeGen source, generated project and schemes, iOS/macOS plists, preserved bundle IDs, LaunchAgent paths and logs, npm manifests/lockfiles, and Worker configuration. It resolves PBX target, product-file, build-configuration, and scheme blueprint object IDs instead of trusting display comments. A hosted iOS test also inspects the built app bundle. The public-release gate runs these checks alongside the path-specific former-brand audit. | Change Beluga display casing, rename one project/target, redirect a target or scheme to the wrong PBX object, alter the real product path or configuration name, change a preserved upgrade bundle ID, drift the host/LaunchAgent path, or change one npm/Worker name. Each mutation is exercised independently. |
| Correct Mac host | Freshly build the signed app, verify its actual plist and designated requirements, then require the installed app and live launchd PID to use the same executable and CDHashes. The live process must map the verified installed LiveKitWebRTC framework vnode, and the loaded launchd job must match the checked-in program arguments, environment, `RunAtLoad`, and `KeepAlive` policy. | Run a legacy app, naked SwiftPM binary, wrong Team ID, renamed bundle, symlink, stale installed build or mapped framework, changed launch arguments, or endpoint/auth/DYLD environment override. |
| Durable paired reconnect | The physical driver keeps one non-secret pair fingerprint across three distinct host PIDs and an iPhone cold launch, while requiring a freshly authenticated live media route after every reconnect. | Retain the UI label but delete the Keychain record, reuse a reconnect sequence, or reconnect signaling without advancing inbound/native media. |
| Full-quality audio through the app-observable boundary | The deterministic native loopback evaluates the full aligned 800 ms decoded stereo waveform—including independent 4–15 kHz pilots—for completeness, silence runs, clipping, gain, channel separation, correlation, bandwidth, and both edges. Separate conversion tests exercise source formats. On iPhone, the physical gate drives a coded 500 ms challenge alternating 997/1499 Hz at high level with 8003/11003 Hz at low level. It requires inbound RTP energy plus output-only RemoteIO render-input PCM/callback/frame density, per-channel high/low-band zero-crossing rates, bounded envelope and cumulative per-callback waveform-shape rates, cumulative cross-callback continuity, no near-silence, no recovery rebuild, no callback gap over 25 ms, and the playback/default 48 kHz stereo route. This is pre-system-output evidence, not proof of the later iOS mixer, route processing, DAC, speaker, or acoustic result. | Telephone-band low-pass, first/last or periodic silence, dropped/repeated samples, frozen callbacks, repeated phase-reset 10 ms blocks, rapid 10 ms gain pumping, clipped or flattened/square PCM followed by one healthy callback, mono folding, half-stereo delivery, swapped or impossible band rates, VoiceProcessingIO, callbacks that consume no PCM, recurring 30/40 ms native callback gaps, a late one-shot increment, or counters too sparse for elapsed time. |
| iPhone microphone forwarding into the product virtual microphone | A connection-level lease registers the exact default-input listener before writing, saves and freshly resolves the prior UID, requires bounded listener/readback proof, is fenced by the atomic product endpoint pair plus peer/connection generations, and conditionally restores only while it still owns the visible input-only endpoint. Session-lifetime output/system-output listeners synchronously close the writer gate; all current and retired virtual-microphone UIDs are forbidden output defaults and process-tap clocks. The forwarding AudioQueue targets only the hidden output-only UID, proves the exact UID and AudioDeviceID before and after start, consumes native mono playout, and requires one successful post-start pull plus two advancing progress snapshots. Physical evidence binds the visible selection and hidden-writer marker to the same PID/peer/pair generation and restores the original input. | Conflate the visible and hidden UIDs, omit either queue/ID readback, accept a partial/wrong-role/stale pair, delay selection until track or PCM, restore the wrong or hidden UID, overwrite a newer external input choice, permit any product/retired endpoint as output/system output or aggregate clock, remove listeners after one poll, reopen from a stale sequence, pull/enqueue after gate close, count priming as progress, or replace UID-pinned capture with forwarding counters. |
| Product virtual-microphone compatibility | The production writer keeps PCM admission closed through silent priming and startup until exact 48 kHz packed Int16 mono queue/device/converter readbacks and two advancing device sample/host observations pass. It preserves at least 60 seconds beneath the observed FaceTime signed-32 projection and closes both PCM and route gates before reporting runtime clock failure. The installed no-call oracle must open the exact hidden 0-in/1-out writer and visible 1-in/0-out input, bit-compare a mono nonce, require exact packed Float32 mono native formats, exact model/clock domain, unity/unmuted controls, both complete start orders, unchanged defaults, and drained teardown. A separate bounded public VoiceProcessingIO probe must prove actual 48 kHz mono processed-microphone capture, exact 48 kHz stereo playout-client readback with a bounded two-buffer silence callback, advancing timestamps/callbacks, zero render error, and strong nonce correlation. | Negotiate 44.1 kHz, stereo processed-microphone capture, mono or malformed VPIO playout, wrong role topology, wrong clock domain, extra ASBD flags, converter error, non-unity gain/mute, frozen/regressed/aged device time, insufficient signed-32 reserve, altered/dropped/duplicated PCM, one-order-only lifecycle, default mutation, silence/noise-only capture, or leaked queue/listener/callback/endpoint. |
| Replacement virtual-driver timeline | The clean-room C17 core and direct production-wrapper tests increment a nonzero zero-timestamp seed only when the shared clock moves from zero clients to its first client, preserve it when the sibling endpoint joins, bind ring frames to exact epoch/session/absolute-frame tags, and repeat both start orders and 1,000 complete restarts without stale PCM. Concurrent lifecycle/I/O/timestamp tests run under ThreadSanitizer; ASan/UBSan, malformed-bundle mutations, two byte-identical universal builds, and loading the actual built bundle cover the artifact seam. The user reports the current side-by-side product path works bidirectionally; provenance-bound installed public-API validation remains required for independent artifact proof. | Keep a constant seed across reset, change it on a join, publish a new seed with an old anchor, retain stale ring state, expose lifecycle retry as a callback error, omit a loadable Mach-O UUID, test only one order, or infer the seed from public AudioQueue time. |
| Active iPhone call isolation | A signed lifecycle suite samples aggregate CallKit state before ordinary activation. Ringing-only startup keeps ordinary best-effort playout while microphone ownership stays closed. Connected-call startup remains globally closed until an exact startup-origin authorization is bound to the first healthy peer, synchronously armed by the quiescent native ADM with zero session side effects, and then proved by fresh inbound/native evidence. A later bare CallKit transition closes only microphone ownership; a genuine interruption replaces any startup authorization with a fresh interruption-origin authorization. Call end revokes hosted ownership and requires a fresh ordinary rebuild plus a newly advancing proof window. | Activate before the startup call sample, open the manual gate before native startup arm, accept an unspecified or wrong origin, bind a startup authorization to a replacement peer, let foreground/route callbacks rebuild after hosted failure, retain startup ownership across a real interruption or call end, accept a suspended pre-call stats read, disconnect the peer, or report Playing before fresh callbacks and frames advance. |
| Background audio | The built-app test inspects `UIBackgroundModes=audio`. The physical gate presses Home for 35 seconds, returns to the app, and requires the original session generation to have accumulated real-time inbound duration/energy and output-only RemoteIO render-input PCM with the coded high/low-band and envelope signatures over the entire interval, without a callback gap, near-silence callback, or audio-unit rebuild. | Remove the capability, stop or mute the track on Home, freeze/replay one callback, suspend RemoteIO, stall for most of the interval, catch counters up only after foregrounding, or reconnect on foreground. |
| Screen Show/Hide | The driver places a nonsecret changing pattern on every Mac display. The physical gate binds an authenticated Show/Active acknowledgement to a stable sequence of at least 12 decoded frames/sec whose independently sampled salted pixel digest changes at least 3 times/sec, then requires a newer authenticated Hide/Inactive acknowledgement and proves audio continues in the same media session. | Acknowledge Show without advancing decoded frames, reuse a stale acknowledgement/renderer, emit one late frame, report 60 fps while pixels change only 1–2 times/sec, advance timestamps over frozen pixels, stop the deterministic visual challenge, or Hide by reconnecting the media session. |

The current Screen gate proves that decoded pixel changes overlap a live deterministic host
challenge at the production renderer boundary, but the decoded pixels do not yet carry a
cryptographic nonce that identifies that exact challenge. It therefore does **not** independently
prove source identity, GPU presentation, or host capture-process quiescence after Hide. The
current remote-input check proves only that a fresh authenticated capability is present;
it does **not** yet drive a disposable Mac target and observe real AX/model mutations. Those claims
remain release-incomplete and must not be inferred from acknowledgements or screenshots.

The retained historical BlackHole 2ch v0.7.1 is release-incompatible for worldwide routing. Its local
timeline counter resets without a new zero-timestamp seed, and a no-call run still
observed public device time whose 24 kHz projection exceeded the signed-32 FaceTime
boundary after both endpoints had been stopped. The same run did not prove exact
hidden-to-visible PCM. Production code must therefore fail closed on this generation;
stopping the endpoints is not reset or recovery evidence.

As of August 23, 2026, the user reports that the current side-by-side opensteamer
deployment works with simultaneous iPhone-microphone uplink and Mac-audio downlink.
That observation applies to the installed pre-cleanup build; it is not provenance-bound
driver evidence and does not certify a later build from this source cleanup.

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
- RemoteIO callback PCM is before iOS's final system mixer and hardware output. A claim that the
  speaker or headphones sound crisp requires a separate wired or external recording with a
  source-correlated waveform oracle; app-internal counters alone cannot make that claim.
- AudioQueue priming, queue-running state, callback clocks, hidden-writer selection, and forwarding-readiness counters do
  not prove that another Mac application can consume the visible product input. The physical oracle must
  independently open the visible device by stable UID and recognize a source-correlated remote
  microphone challenge. Hidden-writer selection is nevertheless a required semantic gate: bind
  its pre/post-start UID readback marker to the current host PID, peer generation, and atomic pair
  generation before arming that capture.
- Run the no-call hidden-output-to-visible-input oracle against the freshly resolved
  installed endpoint pair before another FaceTime trial. It must pass exact PCM, format,
  clock/headroom, unchanged-default, and teardown checks. A passing no-call result
  removes those deterministic blockers but does not prove FaceTime adopted or sent the
  input, nor that its private downlink is intelligible; one final bidirectional FaceTime
  acceptance call remains necessary. Bind any claim
  about an exact driver build to separate signed-bundle provenance until the oracle
  itself records that provenance. The historical public probe is
  decisive blocking evidence for the aged installed BlackHole pair, but it is not a
  substitute for the implemented direct seed/restart and both-order tests or the still-
  required installed validation of the repo-owned replacement driver.
- For worldwide-only microphone forwarding, capture the original input plus the
  output and system-output UIDs before connection. Require the visible product endpoint as the input at
  the authenticated peer/ICE/control boundary before remote-track or PCM proof,
  exact output and system-output equality throughout, prove the hidden endpoint never becomes
  a default, and require restoration of the
  original input after disconnect. Input notifications caused by the expected
  selection and restoration are allowed and should corroborate ordering; any output
  or system-output notification is a failure.
- Graceful teardown can prove conditional restoration. An in-memory lease cannot
  prove restoration after `SIGKILL`, process crash, kernel failure, or power loss;
  release claims must state that limitation rather than inferring crash recovery.

## Native media controls release boundary

Thumbnail decoration must remain independent of command delivery. Cover legacy/malformed
optional artwork decoding, current-source reference binding, immediate metadata/controls while
loading stalls, and owner/context/negotiation replacement rejecting late results. The actual
network loader must reject a streamed oversized body before EOF and cancel superseded requests;
a post-download size assertion alone is insufficient. Reject untrusted redirects and oversized
decoded dimensions. A matching iPhone build must separately prove native artwork presentation;
unit dictionaries and a successful image fetch are not Lock Screen evidence.

Native artwork must also be requested from a non-main executor through the actual
published MPMediaItemArtwork, without a prior main-thread image request. Require
returned dimensions and pixels plus unchanged metadata/controls. Artwork and native
command handlers must remain explicitly Sendable: Objective-C may invoke them outside
the main actor. Restoring the inferred MainActor artwork callback must fail this
background test with the executor assertion, not merely a missing-image assertion.
Run `ruby scripts/test-native-media-callback-isolation.rb EMPTY_PRIVATE_OUTPUT_DIRECTORY
DEVELOPER_DIRECTORY` with the selected canonical Xcode developer directory. This bounded
compiler oracle extracts both production callbacks and checks their isolation in SILGen
and optimized Swift 6, with independent annotation-removal mutants. It complements the
signed artwork runtime test; it does not execute a native remote command or prove a
physical iPhone crash has the same cause.

Before shipping a change to Now Playing controls, require deterministic coverage of
negotiation with legacy peers, the 4 KiB wire bound, exact current-source command
admission, at-most-once Next/Previous execution, and fresh state after startup and
same-peer ICE recovery. Queue-delay mutations must demonstrate that a command or
acknowledgement admitted before recovery cannot acquire a new generation's authority.
Backpressure must not replay a relative command or permanently disable controls for an
unchanged paused item. Native metadata tests must cover owner replacement, source clear,
unsupported controls, and preservation of local interruption/headphone privacy policy.

Native Chrome integration additionally requires exact-production-script behavior
tests for document/item identity in Chrome's page execution context, video replacement, navigation
unavailability, same-URL ABA/reload/BFCache, bounded metadata and command ledgers,
renderer-side deadlines, duplicate relative commands, and late promise completion.
Native Apple Event tests must bind PID/launch identity and stable window/tab IDs,
reject changed targets, enforce final host authorization/deadlines, verify actual
command readback, and fail closed on ambiguous or indeterminate player discovery.
Mutation oracles must reject removal of final renderer/native admission and expiry
checks and relative-command duplicate interception. Permission-only helper IPC must
work without an extension or connected peer, reject media-state injection, tolerate
ordinary consent latency, recover from a transient listener failure, and retire on
stop/disconnect. Ordinary polling must never prompt or activate Chrome.

The retained optional extension path additionally requires the production browser worker,
isolated bridge, and MAIN adapter behavior tests; native framed-socket tests; Music
Apple Event identity/readback tests; and composite source/item ABA revocation tests.
Exercise expired queued commands, wrong peers, malformed/replayed revisions,
disconnect during permission requests, source replacement, and indeterminate reads.
Mutation oracles must reject removal of final command authorization and deadline
checks, not merely match source text. Verify the signed helper, exact native origin,
host Automation entitlement and old-bundle rollback compatibility independently.
Normal signed-host Automation consent and real native Chrome/Music operations remain
live integration gates; fake descriptors and VM DOM tests do not prove them. A real
installed extension is required only for claims about the optional extension path,
not for the native Apple Events path. Preserve the old signed bundle's rollback
verifier separately when changing the reviewed Automation usage description.

A physical release claim additionally requires the deployed host and intended iPhone
build: observe the system Lock Screen/Control Center metadata, change between two real
Mac media sources, and verify Play/Pause/Next/Previous affect only the active source.
Repeat while paused, through a connection recovery, and with local audio muted by its
privacy policy. A successful command acknowledgement or metadata dictionary alone does
not prove native iOS presentation or the Mac player's observable response. Keep this
physical evidence separate from compile, simulator, upload, and deployment results.

## Focused-window resize boundary

Exercise the actual controller against position-dependent size clamping and rejection,
including right-flush left expansion, partial room, negative display origins, all four
corners, mixed-axis directions, and application minimum/maximum constraints. Observe
actual intermediate and final mock window frames, bounded writes, opposite-corner
anchoring, and successor authority; accepting an unchanged frame is not resize success.
Independently remove prepositioning and the no-op rejection to prove those regressions
fail. Preserve exact editable/secure focus and existing stale-target/session tests.

Each forward and rollback write must recheck authorization, window eligibility, focus,
geometry, and the previously observed owned frame. Test failures between phases and
external frame drift after readback. Unknown readback or lost authority must not cause
blind rollback or replay. These deterministic fixtures model synchronous AX behavior;
they do not establish how a real application settles delayed Accessibility changes.
A physical resize claim still requires the matching installed host and a disposable
real window, with before/after AX bounds and pixels plus uninterrupted keyboard focus.

## Focused-window move boundary

Move requires a distinct advertised capability, mode-bound target generation and feedback.
Exercise an explicit safe selection, hold-and-drag originating outside the selected window,
exactly one commit, no normal click/scroll/primary-drag leakage, and pending/cancelled gestures.
Exercise the separately advertised scale-rebinding capability with an idle selected Move target:
a decoded-size change must block input until that exact size is presented, then preserve the same
generation only for exact integer aspect equality while the host capture transform is unchanged.
Prove exact-aspect decoded rebinding succeeds without a host-geometry update, and rounded aspect,
any host capture/framebuffer transition, unadvertised peers, and focused-window Resize all remain
fail-closed. Mutants that remove the new capability gate, use tolerant floating-point aspect
matching, accept a changed host transform, or retire the safe target during the bounded client
presentation gap must fail.
The production controller must write only position, preserve size and exact secure/editable
focus, observe actual readback, and issue a fresh successor. Legacy Move remains fully display
contained. Recoverable offscreen Move requires a separate advertised capability and an explicit
viewer commit opt-in; retain a visible top/title-bar band and horizontal grip, and return both a
legacy unit-contained visible intersection and the bounded full frame. Prove an already-recoverable
partial target can move inward, while Resize, an old viewer, and an old host keep strict containment.
Both Move feedback rectangles are normalized to the encoded frame. A capture-content inset beyond
the half-pixel framework-rounding allowance must suppress both until format renegotiation completes;
the wire does not carry enough transform metadata to interpret meaningful letterboxing safely.
Cover wrong-mode/stale target, changed frame/focus/geometry/permission, constrained or failed
position writes, and lost authorization. Accept same-size application-constrained readback only
when it progresses monotonically toward the requested origin without overshoot, opposite motion,
or untouched-axis drift and remains recoverable. Unknown state must not authorize blind rollback.
An outward drag already clamped at its negotiated edge is a no-op: perform no AX writes,
revalidate ownership and issue a fresh target so the next inward drag remains usable. Do not
confuse that with a setter ignoring a genuinely changed proposal, which must fail. Mutants that
remove the opt-in gate, reuse the clipped frame as the next preview origin, accept a lost grip/top
band, or relax generic normalized rectangles and Resize must fail.
Behavioral mutations must reject a forbidden size write and acceptance of stale authority.
Signed iOS lifecycle tests must retire selection/commit feedback across mode, scene, track,
frame, Show and input-session replacement without dismissing preserved keyboard focus.
These deterministic proofs are not a physical move claim: that still requires the matching
deployed host and iPhone build, a disposable real window, before/after bounds and pixels,
and uninterrupted typing.

## Screen startup quality boundary

Replay promotion-cap contraction and the recorded adverse queue, RTT, and bandwidth
samples independently. A temporary promotion ceiling must use fresh measured capacity,
never exceed the active probe/configured ceiling, expire without statistics, and be
revoked by stale ownership or genuine congestion. Mutants must reject removing this
continuity or substituting the doubled probe budget for measured capacity.

Parse native probe diagnostics from the actual pinned SDK, not only synthetic log
fixtures; retain only bounded numeric/enum events. Native callbacks are process-scoped
and must not acquire a current peer's identity merely because that peer drains them.
A cluster-created event or accepted sender parameter is not probe-feedback or frame
presentation evidence. Bind live timing to the installed host and one acknowledged
Show request, distinguish host-receipt timing from actual display timing, and retain
intermediate reversals. Full-resolution reports do not alone prove perceived clarity.

Retain native estimator send/receive intervals as checked signed microseconds or
explicit positive/negative infinity, never coerced zero or unbounded native text.
Exercise unit conversion, zero/negative values, the one-second boundary, overflow,
malformed inputs, and both collector-copy fields. An actual pinned-SDK callback
must preserve successful finite intervals in a fresh native process. Keep legacy
observer compatibility while accepting the complete new field pair; partial,
duplicate or unknown fields must fail closed. A missing-field-copy mutation must
fail the behavioral collector/native oracle. These process-scoped intervals explain
native feedback rejection; they do not identify a peer or prove receiver display time.

Mac native probing must not wait indefinitely for a large media packet when a
low-detail screencast produces only small RTP packets. Exercise the actual
production peer initializer in a fresh process, with continuous tiny frames,
unchanged encoded geometry and a bounded total-cap increase. Require native
feedback, advancing sender-scoped measured BWE, and receiver frame progress
before the original deadline; a created cluster or accepted cap is insufficient.
Removing the startup configuration must make the recovery oracle fail. A
factory field trial is process-wide configuration, not a per-Show permission;
never toggle it during capture or reconnect. Preserve PCM/device policy and
verify same-peer Show/Hide/Show with decoded-frame cessation after drain and
continued independent audio. Padding packets while hidden are not new screen
frames, and a configured probe target is not a hard instantaneous wire-rate cap.
Synthetic local recovery remains separate from installed-host and real-iPhone
clarity timing.

During active startup discovery, successively improving ordinary reports must expose
the best tier qualified by both reports, without treating the latest higher tier as
confirmed or ending discovery merely to show the intermediate picture. Native
qualification requires advancing report identity, measured low packet delay, healthy
RTT evidence, and 500–1500 ms separation. A fresh no-packet report may hold the original
witness only while its tier remains supported and its original lease is valid; it
must not increment the count or renew any timestamp. Missing/reset queue, invalid
identity, unsupported capacity, or unhealthy RTT breaks pending qualification.
Geometry changes reset queue permission, so fast growth waits for a new ordinary
low-queue measurement. Preserve the original probe origin, deadline, accepted budget
and bandwidth high-water mark across intermediate geometry. Silence or expiry removes
speculative capacity without erasing previously applied quality; fresh adverse
capacity must protect that quality's sustainable requirement in both statistics lanes.
Hide/Show and route boundaries retire pending and confirmed discovery state. Rejected
native application must never copy positive geometry confirmation. Exercise rising
capacity, plateau completion, no-packet cadence, expiry, adverse capacity, ownership
and failed-apply outcomes; mutations must reject disabled intermediate presentation,
selection of the better single-witness tier, and removal of freshness/lease guards.
This policy improvement does not establish recovery from invalid native feedback;
installed-host and real-iPhone startup timing remain separate requirements.

Selected ICE-pair RTT is cached between native ping responses. A new statistics request
or collection sequence is not a new RTT measurement. Consume a privacy-reduced pair
identity plus advancing cumulative total RTT/response counters once for RTT-only
pressure and baseline learning; piggyback acknowledgements may advance only the total.
Reject missing/malformed native metadata and reordered reports. Keep retained unhealthy
or expired evidence from authorizing upgrades, while preserving independent fresh
queue/bandwidth protection and clock-bounded probe expiry. Cover pair ABA/reset,
Hide/route/lane changes, legacy snapshot decoding, and both native snapshot-copy paths.
Mutants must fail when duplicate watermarks regain pressure, unknown RTT becomes healthy,
the sequence fence disappears, or either copy drops the observation. A provisional
initial reference must not add two native ping intervals to cold startup; document
that it has less initial outlier filtering than a three-distinct-measurement baseline.

Intermediate startup-capacity observations must use the same single-flight collector,
retain 500 ms quality/pressure windows, and leave the original probe deadline intact.
Require advancing native report identity and increasing measured BWE before raising
the bounded ceiling. A native UTC timestamp is identity, not an elapsed-time clock.
Cached requests cannot compound capacity or renew primary RTT/queue leases. Preserve
negative RTT identity across fast/ordinary lanes, including pair ABA and malformed
metadata followed by a repaired cached tuple. Neutral queue bursts and small bandwidth
declines withhold growth rather than becoming extra congestion samples. Keep a
cap-dependent feedback oracle for first-full timing, plus disabled-growth, cached-report,
deadline, cadence, and negative-invalidation mutants. Fence requests to their original
Show/capture before interpreting callbacks. Full host compilation and new installed-host
and iPhone evidence remain required; synthetic feedback timing is not a network prediction.

Probe-collapse thresholds must use calibrated codec demand, not the configured sender
ceiling. Exercise high and balanced origins at 50 Mbps in both ordinary and capacity-only
lanes, stable/rising estimates below the full probe ceiling, calibrated collapse boundaries,
and genuine 200 ms queue pressure. Independently restore the configured-ceiling comparison
in each lane and require its recovery tests to fail. Fast decision diagnostics must report
their own packet/delay delta, not the ordinary queue window; keep proposed budgets separate
from native apply results. Numeric/enum diagnostics must reject malformed values without
logging media, peer addresses, or raw connection identities, and must not change policy state.

Below-reserve floor recovery must require two advancing native ordinary reports with
measured low packet delay, healthy RTT, capacity at least the first witness's value,
and at least 500 ms separation
within a 1.5 s evidence lease. Fast/no-packet/cached reports must not supply admission
witnesses. Keep the visible floor unchanged while testing bounded capacity, use the
trial's seed-relative collapse threshold, preserve real congestion and the original
hard deadline, and consume at most one attempt per acknowledged Show. Reserve ownership
before asynchronous Show work and activate only for its exact successful capture/ACK;
failed or superseded native application cannot refund the allowance or transfer positive
health to another Show. Cover expiry, disproof, cooldown, stale identities, and seed
retirement. Independently disable admission, restore the ordinary collapse threshold,
and remove failed-apply attempt consumption; their behavioral regressions must fail.
Cold-first-Show fixtures must also admit a constant below-reserve estimate without
fabricated prior congestion or per-poll RTT advancement. An intervening estimate below
the first witness invalidates that pending window, including early/no-packet reports.
Equality permits initial bounded discovery only, never repeated capacity growth or
visible promotion. Retain exact-value trend and admission-reason diagnostics as
proposal evidence separate from native acceptance and client presentation.

## Execution and Claim Boundary

- `swift test` covers the deterministic protocol, security, transport waveform, mutation, Mac
  artifact, and validation-driver contracts.
- A **signed** Simulator `xcodebuild test` run covers iOS lifecycle, Keychain, accessibility
  serialization, native PCM publication, and evaluator mutations. An unsigned run is not a
  substitute because it cannot exercise the production Keychain access group.
- A generic-device UI `build-for-testing` proves the physical test source compiles; it does not
  execute a physical oracle.
- Injected CallKit tests prove fail-closed microphone policy, explicit hosted-origin ownership,
  and asynchronous race fencing, not that a real device reports every transition. A signed
  physical-device pass must cold-launch during a real connected iPhone call, prove
  `origin=startup-connected-call`, keep microphone input closed while fresh decoded/native playout
  evidence advances, replace that ownership with `origin=interruption` after a genuine interruption,
  begin that interruption-origin window only after interruption-ended supplies a resume hint, then
  end the final call and require a fresh ordinary audio-policy generation plus new advancing
  render evidence before claiming recovery.
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
