# User-protected legacy AudioStreamer runtime

Status: **VERSION 15 FULLY ROLLED BACK; VERSION 16 REVIEW/PREFLIGHT ONLY; LEGACY AND IPHONE REMAIN PROTECTED**\
Original preservation direction: **2026-07-25**\
Mac-only migration authorization recorded: **2026-07-30/31**\
Version-15 retry authorization recorded: **2026-08-02**

The user authorized one guarded Mac-only cutover from the running legacy host to
the validated opensteamer host. Version 15 fully rolled back to the untouched
legacy host. The user explicitly authorized one guarded version-15 Mac-only
retry on August 2, 2026; that authorization was consumed. Version 16 is a review
and read-only-preflight design only. A second cutover attempt has not been
authorized. The authorization does **not** permit moving, renaming,
deleting, replacing, modifying, re-signing, quarantining, or installing over the
legacy Mac app or plist. It also does not authorize any physical-iPhone operation.

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

Controller version 12 created exactly one deterministic fresh transaction
only after byte-validating the complete version-11 rollback in addition to the
version-9 and version-10 tombstones, reproving the live legacy service, and
proving every version-11 hidden cutover path absent. It preserves the default
60-second ordinary-command bound and existing 30-minute build bound while
allowing the unchanged full deployment oracle a bounded 180-second monotonic
deadline. All three older evidence trees and pointers remain immutable.

The version-12 transaction built and staged the new host but stopped before
disabling or stopping the legacy host because the invocation reported less than
the required 1 GiB of post-build disk headroom. Its retained journal proves a
`BeforeLegacyStop` rollback through `LEGACY_RECOVERED` and `ROLLED_BACK`; the
console-only disk-space error is not itself retained in the journal. The exact
legacy host remains the sole process and shared-lock holder, and the new app,
plist, and service are absent.

Controller version 13 created exactly one deterministic fresh transaction only
after byte-validating the complete version-12 pre-stop rollback in addition to
the version-9 through version-11 tombstones, reproving the live legacy service,
and proving every historical hidden cutover path absent. It required at least
2 GiB free before creating evidence and preserved the 1 GiB post-build gate,
8 MiB rollback reserve, and 180-second deployment-oracle deadline.

The version-13 transaction built, installed, and bootstrapped the new host and
reached `NEW_PID_OBSERVED`, but its embedded zsh deployment verifier failed
before `READY_VERIFIED` because it assigned the absent-service exit code to
zsh's read-only `status` parameter. The controller stopped and archived the new
destinations, restored and reverified the untouched legacy host as sole process
and canonical kernel-lock holder, released the reserve, recorded `ROLLED_BACK`,
and retained `active-migration-v13` plus its evidence.

Controller version 14 created exactly one deterministic fresh transaction only
after byte-validating the complete version-13 full rollback in addition to the
version-9 through version-12 tombstones. Its exact gate included the v13
deployment stderr, all recorded hashes, both staged and archived app manifests,
symlink targets, separately anchored xattrs, historical residues, and the live
legacy proof. The verifier uses no zsh `status` or tied `path` locals and runs an
isolated embedded-byte zsh regression before the stop boundary. Version 14 kept
the 2 GiB pre-attempt gate, 1 GiB post-build gate, 8 MiB reserve, and 180-second
deployment deadline.

The version-14 transaction built, installed, and bootstrapped the new host and
reached `NEW_PID_OBSERVED`, but its exact embedded deployment verifier invoked
the nonexistent `/bin/cmp`. Postmortem review also identified a latent
`/usr/bin/dd` reference that execution had not yet reached. The controller then
completed full rollback: it stopped and archived the new host, cleared the new
live destinations, re-enabled and bootstrapped the exact untouched legacy
service, proved legacy was again the sole process and canonical kernel-lock
holder, released the reserve, recorded `ROLLED_BACK`, and retained
`active-migration-v14` plus all evidence. Every version-9 through version-14
evidence tree and pointer remains immutable and retained indefinitely.

Controller version 15 permitted exactly one deterministic fresh
transaction only after byte-validating the complete version-14 full rollback in
addition to every version-9 through version-13 tombstone. Its exact guard covers
the v14 active pointer, journal, result, provenance, source/export and build
records, deployment stdout/stderr, legacy snapshot, rollback-reserve record,
staged and failed app/plist manifests, symlink targets, separately anchored
xattrs, historical residues, and a new proof of the exact sole live legacy host.
The corrected verifier uses `/usr/bin/cmp` and `/bin/dd`; before the legacy-stop
boundary, its isolated embedded-byte zsh self-test verifies the complete declared
absolute command-path set is present as regular, non-symlink, executable files.
Version 15 preserves the 2 GiB pre-attempt gate, 1 GiB post-build gate, 8 MiB
reserve, and 180-second deployment deadline. A cold deep-signature verification
on this Mac was measured at 20.35 seconds, so every legacy-readiness path now
uses the bounded 60-second ordinary-command budget rather than the insufficient
15-second budget.

Version 15 crossed the cutover boundary, installed and bootstrapped the new host,
and reached `NEW_PID_OBSERVED`. The app emitted the online readiness marker
before the controller captured the post-launch log checkpoint at byte
offset `1364`. The post-checkpoint suffix was therefore empty even though the
current generation had already produced the marker. The bounded marker wait
expired, and a deadline-edge output drain surfaced the generic console error
`child stdout exceeded its shared monotonic deadline`. The deployment verifier
never ran, so neither `records/deployment.stdout` nor
`records/deployment.stderr` exists in the v15 evidence tree.

The version-15 transaction then performed the exact full rollback. Its journal
records `ROLLBACK_STARTED`, `NEW_STOPPED`, `NEW_DESTINATIONS_CLEARED`,
`LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`, `LEGACY_RECOVERED`, and
`ROLLED_BACK`. The controller stopped and archived the new host, removed both
new live destinations, re-enabled and bootstrapped the untouched legacy service,
proved legacy was again the sole process and canonical kernel-lock holder,
released the exact rollback reserve, and retained `active-migration-v15` plus
all evidence. Every version-9 through version-15 evidence tree and pointer is
immutable and retained indefinitely.

Controller version 16 is designed to permit exactly one deterministic fresh
transaction only after byte-validating that complete v15 rollback in addition
to every version-9 through version-14 tombstone. Its exact v15 guard covers the
active pointer, journal, result, provenance, source/export and build records,
legacy snapshot, rollback-reserve identity, staged and failed app/plist
manifests, symlink targets, separately anchored xattrs, and the required absence
of both deployment-output records. It captures the log checkpoint immediately
before bootstrap while the new runtime is still proved absent, after all final
verifier/destination/absence/lock checks and with no intervening hook or external
command, preventing a fast valid marker from preceding the checkpoint. The child-command runner
drains stdout and stderr fairly in bounded batches, only the outer runner
classifies deadline expiry, and all command-runner expiry paths use one canonical
diagnostic.
The first generation check, complete deployment verifier, output collection,
and final generation/marker checks share one absolute 180-second monotonic
deadline rather than receiving resettable per-step budgets. Version 16
preserves the 2 GiB pre-attempt gate, 1 GiB post-build gate, and 8 MiB reserve.
Version 16 is review and read-only-preflight only; a second cutover is not
authorized.

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
