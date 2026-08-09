# User-protected legacy AudioStreamer runtime

Status: **PAIRING-PRESERVING HOST UPDATE V5 COMMITTED; TELEMETRY HOST READY FOR THE NEXT PHYSICAL CALL; TESTFLIGHT BUILD 44 UPLOADED TO APPLE; PHYSICAL VALIDATION NOT CLAIMED; LEGACY ROLLBACK SOURCES AND IPHONE REMAIN PROTECTED**\
Original preservation direction: **2026-07-25**\
Mac-only migration authorization recorded: **2026-07-30/31**\
Version-15 retry authorization recorded: **2026-08-02**\
Version-16 retry authorization recorded and consumed: **2026-08-02**\
Version-17 retry authorization recorded and consumed: **2026-08-02**\
Version-18 retry authorization recorded and consumed: **2026-08-02**\
Version-19 retry authorization recorded and consumed: **2026-08-02**\
Version-20 retry authorization recorded and consumed: **2026-08-02**\
Post-v20 new-host pairing-isolation authorization recorded: **2026-08-03**
Pairing-preserving new-host update authorization recorded and consumed: **2026-08-05**
Pairing-preserving new-host update v3 authorization recorded and consumed: **2026-08-06**
Pairing-preserving new-host update v4 authorization recorded and consumed: **2026-08-09**
Pairing-preserving new-host update v5 authorization recorded and consumed: **2026-08-09**

The user authorized guarded Mac-only cutovers from the running legacy host to
the validated opensteamer host. Versions 15, 16, 17, 18, and 19 all fully
rolled back to the untouched legacy host. The user explicitly authorized the
guarded version-19 Mac-only retry on August 2, 2026; that authorization was
consumed by the version-19 attempt described below. On August 2, 2026, the user
explicitly authorized exactly one guarded version-20 Mac-only cutover. That
attempt committed successfully, consuming the single-use authorization. It did
**not** permit moving, renaming,
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

The committed version-20 migration preserved the complete designated requirement,
bundle/signature identifier,
`com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1` Keychain service,
and `com.elamin.AudioStreamer.CaptureServer.runtime` process-lock namespace. On
2026-08-03, after the side-by-side TestFlight app could not inherit that pairing,
the user authorized a scoped update of only the new host to an isolated pairing
service. That update must never read, migrate, replace, reset, or delete the
protected legacy service. The shared bundle/signature identity and process-lock
namespace remain unchanged.

## New side-by-side Mac host

- App: `/Applications/opensteamer Host.app`
- LaunchAgent label: `org.example.opensteamer.worldwide`
- LaunchAgent plist:
  `/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist`
- Pairing service after the authorized update:
  `com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1`

Source changes alone are not deployment evidence. The guarded post-version-20
transaction recorded below is the authority for the installed host. It proved
that the installed binary addresses only the isolated new-host pairing service
and does not contain the protected legacy pairing service. Never run either
host's `--reset-worldwide-pairing` option outside a separately authorized,
guarded recovery.

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

Controller version 16 permitted exactly one deterministic fresh transaction
only after byte-validating that complete v15 rollback in addition to every
version-9 through version-14 tombstone. Its exact v15 guard covered the active
pointer, journal, result, provenance, source/export and build records, legacy
snapshot, rollback-reserve identity, staged and failed app/plist manifests,
symlink targets, separately anchored xattrs, and the required absence of both
deployment-output records. It captured the readiness-log checkpoint immediately
before bootstrap while the new runtime was still proved absent, and its child
runner used fair bounded pipe drains and canonical timeout classification.

The authorized version-16 transaction used source commit
`625941d4fc1f2f4d6254df57ee897c71c88f399d` and tree
`3507c97c3b5be7e11a9ffab6c686d615f5a96506`. It built, installed, and
bootstrapped the new host and reached `NEW_PID_OBSERVED` with PID `17632`,
launchd runs `1`, log offset `1364`, and generation nonce
`88445fa1c01ac2168e9b0e58994f43e44393da7d4a955e82c02df16e7390cd6f`.
The deployment verifier then rejected the canonical installed app because macOS
had attached `com.apple.macl` to the root of
`/Applications/opensteamer Host.app`. Its exact final diagnostic was
`verify-mac-host-bundle: app bundle contains extended attributes: /Applications/opensteamer Host.app: com.apple.macl:`.
The staged bundle had no extended attributes. Read-only postmortem inspection
proved that the failed installed/archive app had only that root attribute, with
an exact 72-byte all-NUL value; its signed bytes and signatures were unchanged.
The untouched legacy app and earlier launched archives exhibit the same
canonical root MACL shape. No broader xattr exception is authorized.

Version 16 then completed the exact full rollback. Its journal records
`ROLLBACK_STARTED` in `FullRestore` mode, `NEW_STOPPED`,
`NEW_DESTINATIONS_CLEARED`, `LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`,
`LEGACY_RECOVERED`, and `ROLLED_BACK`; its result is `rolled-back`. The new app,
plist, and service are absent. Independent live proof found the untouched legacy
host running as PID `19053` with its exact arguments, hashes, signature, enabled
label, and canonical shared-lock ownership. The version-16 pointer and evidence
are retained permanently at
`/Users/ahmed/Library/Application Support/opensteamer/active-migration-v16` and
`/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v16-after-v15-1785637636-18044`.
The pointer SHA-256 is
`aaf2d32335687c997d8f623324c1dbb5a00855464ff2f110a2f94eb8bb97c15b`.
The 6,194-byte, 20-line journal SHA-256 is
`a95a7c0a23f8bc50a0a7270d616e75dac0b72aee2ab4676fa8d3b4be6288fbfb`;
deployment stdout is exactly empty with SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
and the 2,218-byte deployment stderr SHA-256 is
`b71cb31d6ff97ce941f65798ee357fcff8c9af922589b1a30d74dbe0071102c0`.
No physical-iPhone operation occurred.

Controller version 17 created one deterministic transaction only after
byte-validating the complete version-16 rollback and every version-9 through
version-15 tombstone. It used source commit
`bd23d6b7bf9328a383f1d6c8da152754b915eeb5` and tree
`6b536450d997f14b356680c080328cbdced77e67`, built and installed the new host,
and reached `NEW_PID_OBSERVED` with PID `93486`, runs `1`, log offset `1705`,
and nonce
`f69ef6518ac1c0fd57652c02fcc3284fc7a700708b9754a48f256dbb17f12450`.
Both staged and canonical installed-runtime bundle checks passed, including the
narrow root-MACL policy.

The deployment verifier then exited with status `141` before `READY_VERIFIED`.
The exact cause was its `code_hash` pipeline under `set -euo pipefail`:
`codesign -dv --verbose=4 ... 2>&1 | awk -F= '$1 == "CDHash" {print
tolower($2); exit}'`. The successful early `awk` exit closed its input while
`codesign` still had metadata to write, so `codesign` received `SIGPIPE`
(signal 13) and zsh reported `128 + 13 = 141`. Read-only reproduction against
the exact retained staged app produced pipeline statuses `141 0`. The eight
immediately preceding `diff` directory-loop diagnostics were noise: the exact
retained staged/failed tree comparison itself returned zero.

Version 17 then completed the exact full rollback through `ROLLBACK_STARTED` in
`FullRestore` mode, `NEW_STOPPED`, `NEW_DESTINATIONS_CLEARED`,
`LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`, `LEGACY_RECOVERED`, and
`ROLLED_BACK`. The new app, plist, and service are absent. The exact untouched
legacy host is again the sole host and canonical shared-lock owner as PID
`95038`, with its reviewed arguments, hashes, signature, and enabled label. The
consumed version-17 authorization grants no further attempt. Its pointer and
evidence are retained permanently at
`/Users/ahmed/Library/Application Support/opensteamer/active-migration-v17` and
`/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v17-after-v16-1785637636-18044`.
The 105-byte pointer SHA-256 is
`c67386bd19193e913f7116cc179ec44e1768ef077103f51a897e0774324f765a`;
the 7,075-byte, 20-line journal SHA-256 is
`9f66fbd1aff49313ce1528d25290dbb032f720fc79c2e04c509ae230704151d1`;
deployment stdout is exactly empty, and the 4,546-byte deployment stderr
SHA-256 is
`11a704463fb667082b2e50bf5877a24d728c0ee7e3b0a48d7686224091262254`.
No physical-iPhone operation occurred.

Controller version 18 created one deterministic transaction only after
byte-validating the complete version-17 rollback and every version-9 through
version-16 tombstone. The fresh version-18 authorization was consumed on August
2, 2026. It used source commit
`ff02ca6ba192b27fd1cd22e807c8d42900084f74` and tree
`fb56a78b685453901ec0ff8af2fccd446d63ea18`, built and installed the new host,
and reached `NEW_PID_OBSERVED` with PID `53809`, runs `1`, prelaunch log offset
`2127`, and generation nonce
`511ac5970b1235bd964bfffb97cf5dd66d975cdfccbfbd8992eb7d76ec5f7aad`.
The exact generation-bound online marker, signatures, installed-app policy, and
canonical shared-lock proof passed.

The deployment verifier then rejected the same live generation before
`READY_VERIFIED` with
`process start identity differs from the controller-observed generation`. The
controller's Rust `str::trim` had removed the four trailing padding spaces from
the fixed-width `/bin/ps -o lstart=` record, while zsh command substitution
preserved those spaces. The timestamp itself was unchanged; the verifier was
comparing two different edge-whitespace representations. Internal calendar
padding, including the double space before a single-digit day in
`Sun Aug  2 16:35:42 2026`, is semantically significant and must remain intact.

Version 18 then completed the exact full rollback through `ROLLBACK_STARTED` in
`FullRestore` mode, `NEW_STOPPED`, `NEW_DESTINATIONS_CLEARED`,
`LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`, `LEGACY_RECOVERED`, and
`ROLLED_BACK`. The new app, plist, and service are absent. The exact untouched
legacy host is again the sole host and canonical shared-lock owner as PID
`55688`, with its reviewed arguments, hashes, signature, and enabled label. The
consumed version-18 authorization grants no further attempt. Its retained
pointer and evidence are
`/Users/ahmed/Library/Application Support/opensteamer/active-migration-v18` and
`/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v18-after-v17-1785637636-18044`.
The 105-byte pointer SHA-256 is
`3fd6a39f84d620a203fd75f306184356bdbfe9546d6fa45d6d19f91cb4976144`;
the 7,956-byte, 20-line journal SHA-256 is
`bd28126eaae9112af24eccc75f8c18fcb5b43da2e0a4eda3f40169bbed12e55d`;
the 93-byte result SHA-256 is
`434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301`;
and the 375-byte provenance SHA-256 is
`b727f2a085d15722096c999d2e169ae966eb63db6eeef14a7a290808d390f261`.
The 6,778,880-byte source archive SHA-256 is
`ea8ec3d76daa2effb4e6a955240adcc0acd9b5c24b083365218657ebb4a09a13`.
Deployment stdout is exactly empty with SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
the 4,884-byte deployment stderr SHA-256 is
`59a06b517d0adb1223bd725fa323ab837d52e2dcd925e6b282941ff9d1f8acf1`.
No physical-iPhone or TestFlight operation occurred.

Controller version 19 created one deterministic transaction only after
byte-validating the complete version-18 rollback and every version-9 through
version-17 tombstone. The fresh version-19 authorization was consumed on August
2, 2026. It used source commit
`ad8fc9550aafc8f396f0ed2763cf6bf2ead2065d` and tree
`2c54cd942f402ba329d4da56a8e44ff474ebecce`, built and installed the new host,
and bootstrapped the actual new-host process as PID `15883`. That generation
wrote nonce
`116ec64216f66dfff9e8fff655bedf2335ae8c615698297ae5baca8e33bcf014`
to canonical lock device/inode `16777230:10835208`, but the controller failed
before journaling `NEW_PID_OBSERVED`.

During the second lock-contention probe, Spotlight's transient `mdworker` PID
`15928` read-opened the canonical lock file. Version 19's PID-only `lsof`
parser conflated that read-only metadata opener with an advisory-lock owner.
The exact console-only failure was
`shared lock openers changed after the second contention probe: {15883, 15928, 61825}, expected host 15883 and controller 61825`.
That string is postmortem console evidence; it is not anchored in the immutable
version-19 evidence tree.

Version 19 then completed exact `FullRestore` rollback through
`ROLLBACK_STARTED`, `NEW_STOPPED`, `NEW_DESTINATIONS_CLEARED`,
`LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`, `LEGACY_RECOVERED`, and
`ROLLED_BACK`. The new app, plist, and service are absent. The exact untouched
legacy host is again the sole host and canonical advisory-lock owner as PID
`16249`, with its reviewed arguments, hashes, signature, and enabled label. The
consumed version-19 authorization grants no further attempt.

Its pointer and evidence are retained permanently at
`/Users/ahmed/Library/Application Support/opensteamer/active-migration-v19` and
`/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v19-after-v18-1785637636-18044`.
The 105-byte pointer SHA-256 is
`9cdfaec20cc9d021e740a01eab6d23b4a3b6d594b86b94ea38bfaf27ee0895a5`;
the 8,577-byte, 19-line journal SHA-256 is
`76bfe35484cce970e33fe4dbfcfeab7cebf6f0877b38608805b5daaabbff1248`;
the 93-byte result SHA-256 is
`434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301`;
and the 375-byte provenance SHA-256 is
`9eca722ba0af8832de0eb154745447669865799d95546a5c7f8b2313be37e96a`.
The 6,860,800-byte source archive SHA-256 is
`be65913f6ece9d3823be85458507e4dcc0d07885a78d3f62228b474e3058a57d`.
The 884-byte build stdout SHA-256 is
`df0cc65f41aca53e3cf44309c9b2eb405cabaae49ce70fcc1b2a67101082023d`;
the 3,557-byte build stderr SHA-256 is
`1099f10440ea8fb91a78cdc204bcd83bea9b53ee45aa0fcfc015ea0803273789`.
Both deployment-output records are absent because the deployment verifier never
ran. No physical-iPhone or TestFlight operation occurred.

Controller version 20 committed successfully. Its exact
eleventh historical guard pins that complete version-19 rollback while
preserving and revalidating every version-9 through version-18 guard. Its lock
proof strictly and completely parses the PID and file-descriptor access mode of
every `lsof` record instead of treating every opener as a lock holder. A
transient read-only opener invalidates the sample and may trigger only a bounded
restart of the complete lock-path, opener-topology, and two-probe contention
proof within the existing absolute deadline. A successful sample never ignores
or accepts extra openers: it requires exactly the expected host, plus the
controller only while the controller's contention descriptor is open.
Generation-bound acceptance brackets generation-record revalidation with two
successful full lock proofs. Malformed records, unexpected write-capable or
persistent openers, or retry exhaustion fail closed.

Before execution, the read-only preflight inspected pointer state, validated
all version-9 through version-19 tombstones and the sole live legacy host, and
proved the deterministic version-20 evidence path absent. It reported exactly
`PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14=v15=v16=v17=v18=v19 legacy=sole-ready v20=absent`.

The authorized transaction used source commit
`7b8a019fb7b480a2429af759e0d2d78b82cf77ed` and tree
`e93a8a8462573a0751efcdf7480b680b283514c0`. It installed and bootstrapped
the new host as PID `73151`, runs `1`, with generation nonce
`bc4c7e83ba4735a3fb61962bd6b9b39f055a072c68c582be7599d982f867b14a`
and canonical lock device/inode `16777230:10835208`. The exact deployment
oracle passed, and the journal durably records `READY_VERIFIED` followed by
`COMMITTED`.

The retained 105-byte `active-migration-v20` pointer SHA-256 is
`30d9ac5e0e0c425c0c819001fee81f80e380148e3ebeeda6ec1c9369df76dc35`.
The 9,907-byte, 15-line journal SHA-256 is
`41218e48d72dc72f581dcbf5141b008ac575725936d34677d0559e39db58ec66`;
the 246-byte success result SHA-256 is
`00aca5b826c34c30e771ab23a3500733db98eef6953f27f5e658e21dad461fab`;
and the 6,922,240-byte source archive SHA-256 is
`a5a94f4a1e3aa21163c7bc51328199a9cf9a85aba1049f7efb38c3a673c1ee4f`.
The protected legacy executable and plist retain their reviewed hashes, the
legacy launchd label is disabled and absent, and the new host is the sole
`CaptureServer` process. No physical-iPhone operation occurred or is claimed.
The version-20 authorization is consumed.

## Post-version-20 isolated-pairing update attempts

On August 3, 2026, the guarded post-version-20 updater first reached secure
pairing with the separate `com.elamin.opensteamer` TestFlight app. The retained
evidence is
`/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785751613-90853-adcc3537-1df2-4725-9fe7-41f2f2e35835`.
Its journal records `INTERACTIVE_READY`, `PAIRING_COMMITTED`,
`INTERACTIVE_STOPPED`, `V20_HELD`, `NEW_PUBLISHED`, and
`PERSISTENT_BOOTSTRAPPED`. Final deployment verification then rejected the
interactively launched staged app because macOS had attached one root
`com.apple.macl`. Read-only postmortem inspection proved that attribute was
exactly 72 NUL bytes and that the staged executable still had reviewed SHA-256
`ae7638a512440bb567d5e07f1067d8e5035bb59951e38c0559a74e4afa1d2e52`.
The initial automatic rollback encountered asynchronous launchd teardown and
failed closed. A subsequent invocation of the updater's exact guarded rollback
path archived the failed new app, restored the byte-identical committed v20 app,
bootstrapped it, verified it as the sole ready host, and retired the active
post-v20 pointer. The protected legacy app, plist, and Keychain service were not
modified.

Source commit `4919107` added a second never-launched, strict-xattr deployment
reference and one generation-bound 30-second launchd/process drain for rollback.
Its Rust self-test, Swift migration contract, installed-MACL contract, and two
independent safety audits passed. A guarded retry using that commit created
evidence at
`/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785753577-2449-71a9da03-8850-49ab-a0e4-8389b84527ab`,
but its one-time invitation expired before pairing committed. The strengthened
automatic rollback restored and reverified exact v20 without manual recovery.
The next guarded retry paired successfully and committed the isolated host. Its
retained evidence is
`/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10`.
It used source commit `3ca45ac1e83165c0800b10ce1d72d70e091eeb9a`, tree
`da9b343b72a522d3599b7a64465a4afeacb72caf`, and source-archive SHA-256
`7f0fc3bc8efb16958c8c424e159188e2b9fc2b1ee8747f25a0a2261ee7091b9f`.
The journal records the complete ordered path through pairing, publication,
persistent bootstrap, `READY_VERIFIED`, and `COMMITTED`. Its 1,007-byte journal
SHA-256 is
`1c6051a9538901c0002b126b373c9476b93aa48c220127358e7e08e2b58d5ff5`;
the success-result SHA-256 is
`22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77`.
The retained 136-byte `active-post-v20-host-update-v1` pointer SHA-256 is
`f6e76a7d67e424fe319f12ef505d94b6826cc5c36f0415644832c853e9788cdf`.

At the time of this record, the committed isolated host is the sole
`CaptureServer` as PID `33447`, launchd runs `1`, with executable SHA-256
`ae7638a512440bb567d5e07f1067d8e5035bb59951e38c0559a74e4afa1d2e52`
and LaunchAgent plist SHA-256
`7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550`.
The exact committed version-20 host remains retained as the verified rollback
postimage with executable SHA-256
`2d420326dab660e0eee8b0c839aa5fa4da4a792d8d279a682d94eccdc6fee443`.
The protected legacy executable and plist still match their reviewed hashes;
their label is disabled and absent. No pairing code is reusable.

### Pairing-preserving host update v2

On August 5, 2026, the user authorized one guarded update of only the active
side-by-side new host. The updater first proved that PID `33447` was the sole
ready host, the committed v1 pointer and evidence were immutable, both isolated
pairing records were present, and no v2 transaction existed. It then built only
from clean pushed source commit
`e35dd4d54b91fca1d7501b57a585e254f9a55795`, tree
`145b6f656c3e273e92d0e4eec03280068c0a7257`, and committed the replacement as
the sole host without resetting or re-pairing. The new generation is PID
`29630`, launchd runs `1`, with nonce
`750dafd33be35a258a82bfe778528f8a2fe1971198f3e93826cbc06052f8a87d`.
The exact generation log records that the paired-device availability service is
online.

The installed executable SHA-256 is
`7cc60fc9a1677ff10e17f4a6e09647e502a92b5492db46170567bed98c09f3bc`,
its CDHash is `e503fb26b65b3550404cf5eaff3307fe68ba1e38`, and the unchanged
LaunchAgent plist SHA-256 is
`7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550`.
The prior isolated-host executable with SHA-256
`ae7638a512440bb567d5e07f1067d8e5035bb59951e38c0559a74e4afa1d2e52`
is retained as the exact rollback source. Both
`worldwide-host-identity-v1` and `worldwide-paired-viewer-v1` remain present in
the isolated `com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1`
Keychain service.

The immutable transaction evidence is
`/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v2/paired-v2-update-1785977369-24182-475e6219-114a-4bd9-b9df-c934579faf75`.
Its 147-byte active-pointer SHA-256 is
`e83a072333d5976e64bc4905b0d03cb685de4837fe0cb523d9524e88318099dc`;
the journal SHA-256 is
`9859ef5c7ca5f65a386d5dca580c2d5b2cd40f44cf759cf15b8a8ffd8d3a57b4`,
the success-result SHA-256 is
`22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77`,
the provenance SHA-256 is
`539c8de1abdf41285b567ab5d3da53df4bf999a026cced58c69567a4406a4fad`,
and the source-archive SHA-256 is
`b5a60d25f146a78217a7d354cdf195a5a51c385fe375b5254fd143da81448cfe`.
The journal durably ends in `READY_VERIFIED` and `COMMITTED`.

The original v1 active pointer remains byte-identical with SHA-256
`f6e76a7d67e424fe319f12ef505d94b6826cc5c36f0415644832c853e9788cdf`.
The protected legacy executable and plist remain byte-identical with SHA-256
`1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc`
and `419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730`;
their launchd job remains absent. No protected legacy artifact or pairing
service was modified, and no physical-iPhone operation was performed by this
Mac-host transaction.

### Pairing-preserving host update v3

On August 6, 2026, the user authorized exactly one guarded replacement of only
the active side-by-side new host. The preflight proved that PID `29630` was the
sole ready host, the committed v1 and v2 evidence was immutable, both isolated
pairing records were present, the protected legacy job was absent, the source
tree was clean and pushed, and no v3 attempt existed. It bound the authorization
to source commit `759dc9285528b778cc434df807cb26b234201bba` and tree
`f8c12c3c014fbcc523b0e6a2082b6cccd41b8474`.

The one-shot v3 transaction built, verified, stopped, retained, replaced, and
bootstrapped only `/Applications/opensteamer Host.app`. Its journal records the
complete ordered path through `BUILD_VERIFIED`, `STOP_INITIATED`,
`CURRENT_STOPPED`, `CURRENT_HELD`, `NEW_PUBLISHED`,
`PERSISTENT_BOOTSTRAPPED`, `READY_VERIFIED`, and `COMMITTED`. The committed
generation is PID `28433`, launchd runs `1`, with nonce
`2cbad83e5c14a69681975e8b7a051dc7643a9777625c59016deaed59b1d3fec6`.
Its executable SHA-256 is
`3ae931ddc06cb9bf303201143c8e1868fad45c0d0db2cb76e6eb9eca55d16181`,
CDHash `60311a91a4be4fb80c4c0414f134c2289c05240b`, Team ID `MSMG8CJLB3`,
and identifier `com.elamin.AudioStreamer.CaptureServer`. The unchanged
LaunchAgent plist SHA-256 is
`7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550`.

The immutable v3 evidence is
`/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v3/paired-v3-update-1786018665-19633-6cf5e703-22ae-4268-b3d8-75f35c37589b`.
The active-pointer SHA-256 is
`598039b1200c04e828650b780b4745a94a1d3b77cba9dca8525a846f026c9d38`;
the journal SHA-256 is
`c836304aba4515a5e81c542a40586cde91d4474a35073206ab2315650c8e7629`,
the success-result SHA-256 is
`22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77`,
the provenance SHA-256 is
`9ad6a3bd4cc9c286fe628e8c189191652c2d5136111411cbc30055c231e49cbd`,
and the source-archive SHA-256 is
`f25157d09eb91e1124b403d03f48546c0347cb70bea18f1dd17d6ae84fb17c5f`.
The build stdout and stderr SHA-256 values are
`46ab32af32490416df5d9aba72e4bb060a208994f23f894b8e9d37778fed3605`
and `ff5ab234191bb5b4b2d56e976af25086059f5b351134b9edc10d6e4a7c51db9e`.

The exact committed v2 executable with SHA-256
`7cc60fc9a1677ff10e17f4a6e09647e502a92b5492db46170567bed98c09f3bc`
is retained inside the v3 evidence as the rollback source. Both isolated
pairing accounts remain present without secret retrieval, reset, deletion, or
re-pairing. The protected legacy executable and plist still match SHA-256
`1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc`
and `419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730`;
their job remains absent. No protected legacy, physical-iPhone, or TestFlight
operation occurred.

### Pairing-preserving host update v4

On August 9, 2026, the user authorized exactly one guarded replacement of only
the active side-by-side new host with the FaceTime microphone patch. The v4
preflight proved the exact committed v3 pointer and evidence immutable, the v3
deployment reference valid as the baseline oracle, both isolated pairing
accounts present by metadata-only lookup, the protected legacy job absent, the
source clean and pushed, and the fresh v4 namespace absent. The authorization
was bound to pushed source commit
`e0fd02808ed8863819902dce854d974db8895d3c`, tree
`0c0934443a73d7808d3ede612638804148411ea6`, and required FaceTime patch
commit `dde641b0813a3a67a47663f9390dc44fe8c78479`.

The one-shot transaction built, verified, stopped, retained, replaced, and
bootstrapped only `/Applications/opensteamer Host.app`. Its journal records the
complete ordered path through `BUILD_VERIFIED`, `STOP_INITIATED`,
`CURRENT_STOPPED`, `CURRENT_HELD`, `NEW_PUBLISHED`,
`PERSISTENT_BOOTSTRAPPED`, `READY_VERIFIED`, and `COMMITTED`. The committed
generation is PID `42400`, launchd runs `1`, with nonce
`78f8eb0f385ee181bbf258ea6fe0b59fbb1c68f298955f6807430625d96611ed`.
Its executable SHA-256 is
`ce0c1347aa6ddf7ecd290729d8351c65dc1bc43d99416f6a4c17141db7371a4b`,
CDHash `47ff9ae616f6b0b14880e7e419b00ec6a88193d7`, Team ID `MSMG8CJLB3`,
and identifier `com.elamin.AudioStreamer.CaptureServer`. The unchanged
LaunchAgent plist SHA-256 is
`7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550`.

The immutable v4 evidence is
`/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v4/paired-v4-update-1786291257-27621-6a237b6f-a9cc-4adb-a48a-129d364f8073`.
The active-pointer SHA-256 is
`6c54a9561602a3b7c1a3308792dbc3146644311cab318c89c136e77b0ee27e1b`;
the journal SHA-256 is
`4be780a2ee74d0de1ed8ab82eb520fd0216ec6056ff19120f462b26a15950da1`,
the success-result SHA-256 is
`22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77`,
the provenance SHA-256 is
`ff6af9dafbbfc7a579fe8f451d1d095e06d1b7942fbe5ddc2d2efd68517f79bf`,
and the source-archive SHA-256 is
`55cc9f4672a3bc7588f1e05ba2899e905853c5e82cde3e4dcd9cc0bd4fd30a27`.
The build stdout and stderr SHA-256 values are
`272a0ad16858c224aa26d6a265258c6dd66cb5292a2b742fd645c07f007ed3f1`
and `771296873efbcb817e1adf937f4b3f2eccd3f871f3fca5e5a0ebac4dee797cc0`.

Both isolated pairing accounts remain present without secret retrieval, reset,
deletion, or re-pairing. The protected legacy executable and plist retain their
reviewed hashes, and their launchd job remains absent and disabled. The v4
authorization is consumed; any retry would require a fresh versioned updater
and new user authorization. No protected legacy or physical-iPhone operation
occurred. The exact v3 app retained at
`rollback-current/opensteamer Host.app` inside the v4 evidence is the rollback
source; its executable SHA-256 is
`3ae931ddc06cb9bf303201143c8e1868fad45c0d0db2cb76e6eb9eca55d16181`.

### Pairing-preserving host update v5

On August 9, 2026, the user explicitly authorized exactly one fresh guarded
replacement of only the active side-by-side new Mac host so the privacy-safe
FaceTime microphone telemetry pushed through commit
`77cfe939813b9b719ca328b6cb0e69196ce3cf2d` could run in the physical call path.
The v5 preflight proved the exact committed v4 pointer and evidence immutable,
both isolated pairing accounts present by metadata-only lookup, the protected
legacy job absent, the source clean and pushed, and the fresh v5 namespace
absent. It bound the authorization to source commit
`aad4633320734727e05afd1624b06c93bf96ae6f` and tree
`ebf42a023e9790b9eb58becd8a473a7b124b1e07`.

The one-shot transaction built, verified, stopped, retained, replaced, and
bootstrapped only `/Applications/opensteamer Host.app`. Its journal records the
complete ordered path through `BUILD_VERIFIED`, `STOP_INITIATED`,
`INSTALL_HOLD_VERIFIED`, `CURRENT_STOPPED`, `CURRENT_HELD`, `NEW_PUBLISHED`,
`PERSISTENT_BOOTSTRAPPED`, `READY_VERIFIED`, and `COMMITTED`. The committed
generation is PID `35203`, launchd runs `1`, with nonce
`45005cc79c023b6e067e24945d2fc4a5f283a7bbe972dfe04eb74a3f57bd555f`.
Its executable SHA-256 is
`2cb98599725f1a8c658b9a8afc38b50fabe252168292e27505af88cbecf2d205`,
CDHash `92ad981f78d75d63d7a857c677bc73fdfc004da6`, Team ID `MSMG8CJLB3`,
and identifier `com.elamin.AudioStreamer.CaptureServer`. The unchanged
LaunchAgent plist SHA-256 is
`7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550`.

The immutable v5 evidence is
`/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v5/paired-v5-update-1786316959-19979-3f7de8a9-473f-4abf-b15d-9790c827765e`.
The active-pointer SHA-256 is
`291c5a5f6a1fcf71cd32e5c15f95da212a73d59d8d030c46ece930cde5e4c7a8`;
the journal SHA-256 is
`aa356a3696c632e1690fce95ace8ed6d55f1ae80567d47b2737e03468b186ff7`,
the success-result SHA-256 is
`22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77`,
the provenance SHA-256 is
`60dfee1584d102ae668f417878352a8658ab55bc26a090b7aff03d49d4df0600`,
and the source-archive SHA-256 is
`9a5fe00fdb786225b6dd505586c0fbc5643d1acaca802b8ee93c3d3052660fbe`.
The install-hold record, build stdout, and build stderr SHA-256 values are
`4232410939ddd5182ee305f34eb547bdf6ddb0f4353e8c6857b0e3eda2e3e9f4`,
`910cf1081d9a5ca9adfa9169a9f22746e3c2ccf09e9c315490487316c2ac11c0`,
and `3c182eb1dac054dbf2a8ed05252c5cbd7d890777022929d46a995389ee072468`.

The exact v4 executable is retained inside the v5 evidence at
`rollback-current/opensteamer Host.app` with SHA-256
`ce0c1347aa6ddf7ecd290729d8351c65dc1bc43d99416f6a4c17141db7371a4b`.
The v4 active pointer remains byte-identical with SHA-256
`6c54a9561602a3b7c1a3308792dbc3146644311cab318c89c136e77b0ee27e1b`.
Both isolated pairing accounts remain present without secret retrieval, reset,
deletion, or re-pairing. The protected legacy executable and plist retain
SHA-256 `1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc`
and `419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730`;
their job remains absent and disabled.

The installed v5 binary contains the bounded decoded and pre-enqueue scalar
telemetry needed for the next FaceTime trial. It logs no raw PCM and no audio
fingerprint value. This Mac-host transaction did not upload another TestFlight
build or operate the physical iPhone; build `44` remains the intended
side-by-side client. Physical FaceTime microphone behavior remains unvalidated
until the next call, and the consumed v5 authorization grants no retry.

## Protected iPhone client

The production iOS app and the development Release target both use bundle
identifier `com.elamin.AudioStreamer`. The physical iPhone was unavailable while
this migration was prepared.

A separate archive-only `TestFlight` configuration now uses bundle identifier
`com.elamin.opensteamer`, build `44`, and the production rendezvous endpoint.
Its guarded upload path rejects the protected bundle identifier and validates
the completed archive identity before any upload. This side-by-side app has a
separate container and Keychain scope, so it requires fresh pairing with the new
Mac host and cannot inherit the protected app's pairing state. At upload time no
physical-iPhone validation had occurred; the later post-version-20 attempt above
proved only secure pairing, not audio, microphone, call, or full end-to-end
behavior.

The maintainer reported the Apple Developer Program membership renewed on
2026-08-02, and renewal propagation was confirmed active on 2026-08-03. An
explicit App ID for `com.elamin.opensteamer` and the isolated App Store Connect
app `opensteamer` (Apple ID `6797410161`) were created without selecting or
modifying the protected app record. A development-signed build-37 archive passed
the exact bundle, build, production-endpoint, Team ID, and signature guards and
was uploaded successfully to App Store Connect at 2026-08-03 02:18 EDT. The
retained upload evidence is under
`/private/tmp/opensteamer-testflight-output.0DYPAA`, including
`upload-renewed.log`; Xcode reported `Upload succeeded` and
`** EXPORT SUCCEEDED **`. Apple also reported a non-blocking missing-dSYM warning
for `LiveKitWebRTC.framework`.

App Store Connect finished processing version `0.1.0`, build `37`, and showed it
in `Testing` state with a 90-day expiry. The automatically distributing internal
group `opensteamer Internal` was created with that build, and account holder
`elaminahmed03@gmail.com` was added as its sole invited tester. TestFlight
availability and invitation alone do not establish physical-iPhone behavior.
The later guarded pairing commit establishes that the separate client reached
the isolated host once, but the host update rolled back before physical audio,
microphone, call, or full end-to-end behavior was validated.

After the isolated host committed, the maintainer physically paired build `37`
and observed the microphone status rapidly cycle among `Starting`,
`Paused — waiting for audio policy`, and `Unavailable`. That observation is a
failure report, not microphone validation. The Mac host remained the sole
process and its direct WebRTC route continued carrying system audio.

Build `38` changes microphone admission so a native failure is latched once for
explicit retry, a transport race waits for a newer healthy-transport proof and
then retries automatically, and output-only cleanup gates both automatic and
manual retry. Raw-processing convergence now has a two-second production safety
deadline instead of the earlier 200-millisecond attempt window. The focused
macOS WebRTC loopback regression and two focused iOS lifecycle regressions
passed. The guarded archive verified exact bundle `com.elamin.opensteamer`,
build `38`, production endpoints, Team ID, and signature, then uploaded
successfully at 2026-08-03 08:11 EDT. Xcode reported `Upload succeeded` and
`** EXPORT SUCCEEDED **`; retained evidence is under
`/private/tmp/opensteamer-testflight-output.nZPlNR`. App Store Connect processing
and a fresh physical-iPhone oracle are still required before claiming the fix
works end to end. The non-blocking LiveKitWebRTC missing-dSYM warning remains.

Build `39` added exact native audio-session admission diagnostics. A physical
iPhone report then proved the failure was not a signaling guess: the preferred
mono-input request returned OSStatus `-50` while the observed route was inactive,
output-only A2DP with zero maximum input channels. Build `40` moves channel
preference requests after activation, selects the built-in microphone only after
activation, and serializes the complete owned AVAudioSession transaction through
exact route and channel convergence. Route notifications are admitted only when
their generation, ownership, policy, and route-fingerprint evidence match; all
other mutations fail closed. Focused native, lifecycle, physical-oracle, and
WebRTC loopback suites passed, with only the hardware-only simulator tests
skipped. An independent post-refactor audit reported no actionable P0-P2 finding.

The first build-40 archive attempt failed locally before export because the
production classifier's disposition enum was mistakenly DEBUG-only; no package
was uploaded. The type was moved into the production header, and the guarded
retry verified exact bundle `com.elamin.opensteamer`, build `40`, production
endpoints, Team ID, and signed identifier before upload. App Store Connect
accepted the package at 2026-08-03 10:22 EDT and reported `Upload succeeded` and
`** EXPORT SUCCEEDED **`; retained evidence is under
`/private/tmp/opensteamer-testflight-output.O7lBK3`. App Store Connect completed
processing at 10:24 EDT, and TestFlight reported build `40` ready to test at
10:25 EDT. The non-blocking LiveKitWebRTC missing-dSYM warning remains. A fresh
physical iPhone call and raw-microphone oracle is still required before claiming
the fix works end to end.

On August 5, 2026, archive-only TestFlight build `42` (`0.1.0`) was produced
from the FaceTime duplex-audio patch and verified as bundle
`com.elamin.opensteamer`, Team ID `MSMG8CJLB3`, before upload. The retained
archive is
`/private/tmp/opensteamer-testflight-output.CT3TYy/archive-destination.UQ1Ouh/opensteamerTestFlight.xcarchive`.
Xcode Organizer uploaded it using `TestFlight Internal Only`, reported the
submission as `Uploaded to Apple`, and showed build number `42`. Apple's only
reported warning was the existing non-blocking missing dSYM for
`LiveKitWebRTC.framework`. Upload acceptance does not establish TestFlight
processing, installation, or physical FaceTime/audio behavior; those still
require a fresh physical-iPhone test.

On August 9, 2026, the first guarded build-44 attempt archived version `0.1.0` and
verified bundle `com.elamin.opensteamer`, Team ID `MSMG8CJLB3`, arm64, build
`44`, and signed CDHash `d131156ea30af867599635524b94f80008daa723`. The
retained archive is
`/private/tmp/opensteamer-testflight-output.xEqGvK/archive-destination.sXX7sU/opensteamerTestFlight.xcarchive`.
The 486,927-byte archive log ends `** ARCHIVE SUCCEEDED **` and has SHA-256
`86b24b17675e114c38d0c70053f201519dfc5b4f9bc0faf7dd92f27d91195b9c`.
Xcode then failed before any upload because it could not find an account with
App Store Connect access for Team `MSMG8CJLB3`; the 334-byte upload log ends
`Failed to Use Accounts` and `** EXPORT FAILED **` and has SHA-256
`cdf3764f2253fa44c05e0f2d6b55d79216acb9e2ce16fa1f31b60fead83ee962`.
That archive contains no successful `Distributions` record. The pre-upload
account failure left build `44` reusable and performed no protected-app or
physical-iPhone operation.

A later guarded attempt produced and verified the exact build-44 archive at
`/private/tmp/opensteamer-testflight-output.t9a6ld/archive-destination.Vr8yid/opensteamerTestFlight.xcarchive`.
It is version `0.1.0`, bundle `com.elamin.opensteamer`, Team ID `MSMG8CJLB3`,
arm64, build `44`, and signed CDHash
`7d7aa8f498f4f3607eb0fd2bad13aa4b571e714c`. Its 486,910-byte archive log
ends `** ARCHIVE SUCCEEDED **` and has SHA-256
`bac0f65e81046562ff44488922fb5332401c9198697e2e76cf5256ccfdae366f`.
The command-line export again stopped at the account gate; its 334-byte failure
log has SHA-256
`df5e9e013cbf02ecee8b8dc59474d4b1cfb105b5e60dafe7fc64d236f241f848`.
After the account was authenticated in pinned Xcode 26.6, Organizer imported
the same archive to
`/Users/ahmed/Library/Developer/Xcode/Archives/2026-08-09/opensteamerTestFlight.xcarchive`;
the source and imported app payloads compared byte-for-byte equal, including
executable SHA-256
`e3223133f429cf014d7feb92cbca137ed4390990b0dfdb24a028f61163eeb915`.

Xcode Organizer then used `TestFlight Internal Only` and recorded `Upload
succeeded` and `Uploaded to Apple` at 2026-08-09 17:58:57 UTC. The imported
archive's single successful `Distributions` record names Adam ID `6797410161`,
destination `upload` / `App Store`, Team ID `MSMG8CJLB3`, uploaded build `44`,
successful preparation and upload events with zero errors, and distribution
certificate SHA-1 `CEB61B792A7A5848E9E797BB2E44EA2642611A6F`. Its
2,389-byte `Info.plist` has SHA-256
`3a4727ef1b4c5ece5c097a23bf8eaac513d1c93595fb7ea7c840c744d9d5aa6b`;
the 53,167-byte Organizer standard log has SHA-256
`dbb70de82ed8c796984614083dae6227ae67c28a9374336bf2ca29aa8d832c51`.
Apple's only reported warning was the existing non-blocking missing dSYM for
`LiveKitWebRTC.framework`. Upload acceptance does not establish App Store
Connect processing, TestFlight availability, installation, or physical
FaceTime/microphone behavior. No protected-app or physical-iPhone operation
occurred.

- Do not install, replace, migrate, launch, reset, re-pair, or modify the
  production app on a physical iPhone.
- Do not install a development Release build or any TestFlight build carrying
  `com.elamin.AudioStreamer` on that iPhone.
- A future TestFlight install is permitted only when its archive and installed
  identity are both exactly `com.elamin.opensteamer`; it must remain side by side
  with the protected app.
- Use only the simulator or the separate development Debug bundle
  `org.example.AudioStreamer.dev`.
- Do not claim physical-iPhone audio, microphone forwarding, call behavior,
  pairing continuity, or end-to-end validation until the phone reconnects and
  the applicable physical oracle passes.

Never add `--reset-worldwide-pairing` to a persistent LaunchAgent. Fresh legacy
pairing codes, if rollback genuinely requires one, must come only from the
restored and reverified legacy host.
