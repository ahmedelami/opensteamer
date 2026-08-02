# User-protected legacy AudioStreamer runtime

Status: **MAC-ONLY SIDE-BY-SIDE CUTOVER AUTHORIZED; LEGACY AND IPHONE REMAIN PROTECTED**\
Original preservation direction: **2026-07-25**\
Mac-only migration authorization recorded: **2026-07-30/31**

The user authorized one guarded Mac-only cutover from the running legacy host to
the validated opensteamer host. The authorization does **not** permit moving,
renaming, deleting, replacing, modifying, re-signing, quarantining, or installing
over the legacy Mac app or plist. It also does not authorize any physical-iPhone
operation.

## Untouched legacy Mac rollback source

- App: `/Applications/AudioStreamer Host.app`
- Executable: `/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer`
- Bundle/signature identifier: `com.elamin.AudioStreamer.CaptureServer`
- LaunchAgent label: `com.elamin.audiostreamer.worldwide`
- LaunchAgent plist:
  `/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist`
- Exact arguments:
  `--worldwide --allow-remote-control --duration 0 --verbose`
- Executable SHA-256:
  `1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc`
- LaunchAgent plist SHA-256:
  `419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730`
- Team ID: `MSMG8CJLB3`
- Apple Development identity SHA-1:
  `483C08B6517EBC1CFCCAB1A88BBEE8028750AA13`

The app and plist above remain at their original paths throughout cutover and
rollback. The controller may durably disable the legacy launchd label and boot
the job out, but it must verify the app, plist, full code identity, exact bytes,
and shared lock before stopping it. Successful cutover leaves the label disabled
across login/reboot; rollback re-enables it before bootstrapping the untouched
plist. The controller must never mutate either rollback source.

The migration preserves the complete designated requirement, bundle/signature
identifier, `com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1`
Keychain service, and
`com.elamin.AudioStreamer.CaptureServer.runtime` process-lock namespace.

## New side-by-side Mac host

- App: `/Applications/opensteamer Host.app`
- LaunchAgent label: `org.example.opensteamer.worldwide`
- LaunchAgent plist:
  `/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist`

Legacy and new hosts must never overlap. Before starting the new host, the
controller must prove that the legacy job and every legacy `CaptureServer`
process are absent and that the exact shared advisory lock is acquirable. Before
rollback bootstraps the untouched legacy plist, it must prove that the new job,
new process, and shared lock are absent. After bootstrap it waits boundedly for
the exact legacy job/process/arguments/hash/lock state while continuously
reproving new-host absence; timeout, wrong identity, or new-host reappearance
fails closed. An operational error is not proof of absence.

## Protected recovery and evidence

The pre-existing recovery app below is outside the migration transaction and
must never be read, moved, copied, renamed, modified, signed, launched, deleted,
or used as a migration input:

`/Applications/.audiostreamer-failed-20260720-102747-44276/AudioStreamer Host.app`

Each attempt creates a unique owner-only evidence directory under
`/Users/ahmed/Library/Application Support/opensteamer/migrations`. Readiness is
bound to one launch generation by PID, process-start identity, launchd run
count, a random nonce durably written into the held canonical lock inode, and
that inode's device/number; an older generation's log marker is never reusable.
Its journal,
provenance record, offline legacy snapshot, staged artifacts, verification
records, and final outcome are retained indefinitely. Failed-new evidence must
not leave a second launchable app in an application-search path.

The first guarded attempt on August 1, 2026 stopped before the legacy cutover
boundary because controller version 9 referenced the nonexistent
`/bin/chflags`. It durably recorded `ROLLED_BACK`, verified that the exact legacy
host remained the sole running host, and retained
`active-migration-v9` plus its evidence. Controller version 10 retried only
after byte-validating that exact pre-stop outcome and independently reproving
the live legacy hashes, launch state, process set, and shared lock. It preserved
the version-9 pointer and evidence permanently.

The first version-10 attempt later stopped the exact legacy service but failed
before publishing the new app because the controller rejected the canonical
`root:admin` mode-`0775` `/Applications` directory. Its initial rollback hit the
same guard, so both hosts were deliberately left offline under the retained
`active-migration-v10` tombstone. Recovery resumed only after that pointer,
critical journal hash and history, provenance, offline snapshot, legacy/new
service topology, shared lock, and hidden install hold exactly matched the
reviewed failed attempt. The directory exception is limited to canonical
`/Applications` with UID `0`, GID `80`, and mode `0775`, and is preserved across
pinned-directory revalidation. Recovery restored and proved the untouched
legacy service before archiving the unlaunched new-app hold.

Controller version 11 created one fresh transaction only after pinning and
revalidating both historical tombstones and independently reproving the restored
legacy service. It retains the exact `/Applications` and LaunchAgents directory
descriptors across shutdown and publication, journals their device/inode
identities for rollback, rejects all transaction-specific hidden-path collisions
before disable and bootout, pins the reviewed `ditto` tool, and revalidates both
historical guards immediately before crossing the stop boundary. Neither older
pointer or evidence tree may be modified or removed.

Version 11 also kept a physically allocated, journal-identified rollback
reserve until recovery or verified commit, executes only controller-embedded and
inode-pinned verifier bytes, and repeats the no-overlap process/lock proof
immediately before either host is bootstrapped.

The version-11 transaction built, installed, and launched the new host but did
not reach `READY_VERIFIED` or `COMMITTED`: the complete 44-sample deployment
oracle exceeded its generic 60-second child-command budget. Version 11 then
stopped and archived the new destinations, restored the exact legacy service as
the sole process and shared-lock holder, released its rollback reserve, recorded
`ROLLED_BACK`, and retained `active-migration-v11` plus all evidence.

Controller version 12 may create exactly one deterministic fresh transaction
only after byte-validating the complete version-11 rollback in addition to the
version-9 and version-10 tombstones, reproving the live legacy service, and
proving every version-11 hidden cutover path absent. It preserves the default
60-second ordinary-command bound and existing 30-minute build bound while
allowing the unchanged full deployment oracle a bounded 180-second monotonic
deadline. All three older evidence trees and pointers remain immutable.

## Protected iPhone client

The production iOS app and the development Release target both use bundle
identifier `com.elamin.AudioStreamer`. The physical iPhone was unavailable while
this migration was prepared.

- Do not install, replace, migrate, launch, reset, re-pair, or modify the
  production app on a physical iPhone.
- Do not install a development Release or TestFlight build on that iPhone.
- Use only the simulator or the separate development Debug bundle
  `org.example.AudioStreamer.dev`.
- Do not claim physical-iPhone audio, microphone forwarding, call behavior,
  pairing continuity, or end-to-end validation until the phone reconnects and
  the applicable physical oracle passes.

Never add `--reset-worldwide-pairing` to a persistent LaunchAgent. Fresh legacy
pairing codes, if rollback genuinely requires one, must come only from the
restored and reverified legacy host.
