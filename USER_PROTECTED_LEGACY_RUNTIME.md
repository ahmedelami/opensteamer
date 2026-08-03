# User-protected legacy AudioStreamer runtime

Status: **VERSION 20 COMMITTED; NEW HOST ACTIVE; LEGACY ROLLBACK SOURCES AND IPHONE REMAIN PROTECTED**\
Original preservation direction: **2026-07-25**\
Mac-only migration authorization recorded: **2026-07-30/31**\
Version-15 retry authorization recorded: **2026-08-02**\
Version-16 retry authorization recorded and consumed: **2026-08-02**\
Version-17 retry authorization recorded and consumed: **2026-08-02**\
Version-18 retry authorization recorded and consumed: **2026-08-02**\
Version-19 retry authorization recorded and consumed: **2026-08-02**\
Version-20 retry authorization recorded and consumed: **2026-08-02**\
Post-v20 new-host pairing-isolation authorization recorded: **2026-08-03**

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

The source update is not deployment evidence. Until a newly signed host is
verified and launched, the installed version-20 binary remains the active
postimage and still addresses the protected legacy pairing service. Never run
its `--reset-worldwide-pairing` option.

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
The active host is therefore still committed v20, now PID `6308` at the time of
this record, with executable SHA-256
`2d420326dab660e0eee8b0c839aa5fa4da4a792d8d279a682d94eccdc6fee443`.
No post-version-20 replacement is installed. A future guarded retry requires a
new one-time code; never reuse either expired code from these attempts.

## Protected iPhone client

The production iOS app and the development Release target both use bundle
identifier `com.elamin.AudioStreamer`. The physical iPhone was unavailable while
this migration was prepared.

A separate archive-only `TestFlight` configuration now uses bundle identifier
`com.elamin.opensteamer`, build `37`, and the production rendezvous endpoint.
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
