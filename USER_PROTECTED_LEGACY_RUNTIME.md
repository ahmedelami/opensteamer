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
`active-migration-v9` plus its evidence. Controller version 10 may retry only
after byte-validating that exact pre-stop outcome and independently reproving
the live legacy hashes, launch state, process set, and shared lock. It preserves
the version-9 pointer and evidence permanently.

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
