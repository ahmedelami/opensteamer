# Microphone clock recovery

## Failure addressed

An input consumer can retain a started virtual-microphone lease after audible
capture stops. Reconnecting the hidden writer does not start a fresh timeline
while that lease remains. At 48 kHz, an old timeline eventually exceeds the
host's reserved signed-32 headroom in FaceTime's observed 24 kHz domain. The
host deliberately blocks microphone forwarding at that point; the screen and
other WebRTC tracks can remain connected.

The September 4 investigation observed a retained MicDbMenu input lease with no
advancing I/O callbacks. Both public Core Audio running properties reported
false while the driver diagnostic snapshot still reported one started client
and an active, aged timeline. Public idle alone is therefore not sufficient
evidence for recovery on this driver. This observation does not establish a
headphone problem or which microphone a separate calling app selected.

## Patch boundaries

- The host uses system-wide `DeviceIsRunningSomewhere`, not process-local
  `DeviceIsRunning`, and also requires coherent, idle driver lifecycle snapshots
  before attempting fresh-epoch readmission. Missing or incompatible diagnostic
  data denies that recovery attempt; it does not change ordinary startup.
- Exact peer, track, transport, device-pair, parking-lease and post-start clock
  checks remain in force. Readmission failures report each admission predicate
  and the actual forwarding phase/failure category.
- The companion `Tools/MicDbMenu` utility releases its capture on route changes
  and does not start capture on virtual, aggregate, unknown or unavailable
  devices. Physical capture is pinned to the validated device, not a moving
  default. Virtual input shows an explicit unavailable level instead of stale
  dBFS. Its existing AppKit status item and overlay are retained.

The patch does not reset the driver beneath a live consumer, terminate calling
apps, modify audio defaults from the meter, change pairing, or bypass the
signed-32 guard. Another application that holds the virtual input continuously
can still prevent a safe clock reset. The host's existing bounded recovery
episode is unchanged: after exhaustion, a later reconnect is needed once the
input has actually been released. This is not seamless indefinite-call support.

## Verification and application

Source checks:

```sh
swift test --filter 'WorldwideSharedClockEpochRecoveryTests|WorldwideVirtualMicrophoneDriverIdleTests|BlackHoleMicrophoneOutputTests|WorldwideIPhoneMicrophoneForwardingDriverTests'
swift test --package-path macOS/Tools/MicDbMenu
git diff --check
```

Patch validation on September 4, 2026: 116 host tests and 14 meter tests passed.
The final meter Release bundle built and passed signature/plist verification
without being launched. A separate read-only executable using the production
driver diagnostic reader classified both installed endpoints as non-idle with
the retained seed, despite the public HAL flags being zero. These checks did
not install either patch or prove physical microphone delivery.

Host tests must cover public-idle/driver-active disagreement, malformed or
unavailable diagnostics, changed lifecycle identities, stale observations,
active endpoints, and the exact readmission fence. Native fixtures generated
from the driver's C header independently exercise the Swift decoder's ABI.
Meter tests must cover physical-to-virtual-to-physical transitions, rejected
device identity, stale and duplicate restart callbacks, and disposal without
virtual capture. These are source tests, not installed or acoustic proof.

Application is Mac-only: the guarded host updater and the separate meter
installation are distinct steps. No iOS source or TestFlight build is required
for this patch. Preserve the signed host identity, pairing and all protected
runtime evidence according to `AGENTS.md`; do not launch a naked replacement
host. Keep a rollback copy when replacing the separately installed meter.

After application, verify the actual signed artifacts and live PIDs. With the
writer stopped, the running meter must not own a virtual input lease. A fresh
connection must establish a new safe driver epoch, exact hidden-writer
admission and advancing nonzero microphone PCM. A physical input consumer must
then independently capture the remote speech. Transport or meter labels alone
do not prove audibility, Cisco input selection or far-end call audio.
