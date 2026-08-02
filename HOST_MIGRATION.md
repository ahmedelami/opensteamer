# Guarded side-by-side Mac host migration

The user authorized this **Mac-only** migration on July 30/31, 2026 and
explicitly authorized guarded version-15, version-16, version-17, and version-18
retries on August 2, 2026. All four retries fully rolled back. The version-18
authorization was consumed.
The legacy app and legacy LaunchAgent plist remain
byte-for-byte at their existing paths as rollback sources. The authorization
does not extend to a physical iPhone, TestFlight, pairing reset, or cleanup of
recovery/evidence artifacts. Version 19 is a reviewed, read-only-preflight
design; a further cutover attempt has not been authorized.

## Transaction model

`macOS/scripts/migrate-opensteamer-host.sh` resolves only
`/opt/homebrew/bin/rustc` to the reviewed canonical Homebrew compiler
`/opt/homebrew/Cellar/rust/1.97.1/bin/rustc`, requires its embedded SHA-256 and
strictly parses the compiler's single `CandidateCDHashFull sha256=<64 lower-hex>`
record together with the agreeing 40-hex candidate/CDHash records, compiles the
checked-in Rust controller twice
into a fresh owner-only temporary directory with warnings denied, publishes the
byte-identical private executable without replacement, and runs only that exact
binary. No `PATH`, user cache, or pre-existing controller executable is trusted. One controller-owned advisory
lock covers provenance verification, immutable export, Release build, staging,
persistent legacy disable, legacy shutdown, lock handoff, side-by-side
installation, bootstrap, readiness proof, commit, rollback, and crash recovery. Exactly one top-level controller decides process exit;
rollback-reachable helpers return errors.

The current controller owns the version-19 active-pointer and journal namespace.
The retained version-9 through version-18 pointers are never moved, replaced, or
deleted. If separately authorized, version 19 can proceed only when version 9 is
byte-for-byte the reviewed `rolled-back-before-stop` outcome from the August 1
`/bin/chflags` path failure,
version 10 is byte-for-byte the reviewed full-restore rollback described below,
version 11 is byte-for-byte the reviewed post-readiness-timeout full rollback,
version 12 is byte-for-byte the reviewed pre-stop disk-headroom rollback, version
13 is byte-for-byte the reviewed deployment-verifier rollback described below,
14 is byte-for-byte the reviewed tool-path-verifier rollback described below,
version 15 is byte-for-byte the reviewed fast-marker-checkpoint rollback below,
version 16 is byte-for-byte the reviewed installed-MACL-verifier rollback below,
version 17 is byte-for-byte the reviewed status-141 rollback below,
version 18 is byte-for-byte the reviewed process-start-padding rollback below,
all older pointer residues and hidden cutover paths are absent, and the exact
untouched legacy service is re-proved live. The corrected controller invokes the
existing system tools at their actual absolute paths, including
`/usr/bin/chflags`, `/usr/bin/cmp`, and `/bin/dd`. Before the legacy-stop
boundary, it runs the exact embedded deployment-verifier bytes in an isolated
zsh self-test that checks the complete declared command-path set for regular,
non-symlink, executable files. Any different historical state or unavailable or
redirected command fails closed for manual inspection.

The first version-10 cutover reached the legacy-stop boundary and then rejected
this Mac's standard `/Applications` directory because it is `root:admin` mode
`0775`. The new app was not published or launched, but the same validation also
prevented rollback from clearing destinations, temporarily leaving both hosts
offline. The exact gated recovery completed, re-enabled and bootstrapped the
untouched legacy service, proved it was the sole host and lock holder, archived
the unlaunched install hold, and retained both tombstones. The controller permits
group write only for the exact canonical `/Applications`
path with UID `0`, GID `80`, and mode `0775`; that policy remains attached to
the pinned directory across every reopen and rename. Recovery from
`CRITICAL_FAILURE` is enabled only for the exact retained version-10 evidence
path, active-pointer bytes/hash, journal hash and history, provenance
commit/tree, failure text, hidden-install layout, untouched legacy snapshot,
disabled/absent legacy service, absent new service/destinations/processes, and
acquirable shared lock. Version 19 treats any new `CRITICAL_FAILURE` as
fail-closed rather than reusing that historical recovery exception.

Version 11 built, signed, installed, and bootstrapped the new host, then reached
`NEW_PID_OBSERVED`. Its unchanged 44-sample stable deployment oracle exceeded
the default 60-second ordinary child-command budget because those samples perform
thousands of independent static and live checks. The controller did not commit:
it stopped and archived the new destinations, re-enabled and bootstrapped the
exact legacy service, proved it was again the sole process and lock holder,
released the rollback reserve, and durably recorded `ROLLED_BACK`. Version 12
kept the default 60-second ordinary-command limit and the existing 30-minute
build limit, while giving the complete deployment oracle a bounded 180-second
monotonic budget.

Version 12 then stopped before disabling or stopping the legacy host because
the invocation reported less than the required 1 GiB of post-build disk
headroom. Its retained journal independently proves only pre-stop states and a
`BeforeLegacyStop` rollback through `LEGACY_RECOVERED` and `ROLLED_BACK`; it does
not retain the console-only primary error. The exact legacy host remained the
sole process and lock holder, and no new destination or service remains.
Version 13 accepts only that complete byte-for-byte v12 tombstone, requires at
least 2 GiB free before creating its evidence tree, and keeps the existing 1 GiB
post-build cutover gate and 8 MiB rollback reserve unchanged.

Version 13 built, installed, and bootstrapped the new host and reached
`NEW_PID_OBSERVED`, but the deployment oracle exited before its first stability
sample because it assigned the launchctl exit code to zsh's read-only `status`
parameter. The controller stopped and archived the new destinations, restored
the exact legacy service as sole process and kernel lock holder, released the
reserve, and recorded `ROLLED_BACK`. Version 14 accepted only that complete raw
journal/result/provenance set, the exact empty deployment stdout and exact zsh
error stderr, every retained build record, both staged/archived app manifests,
symlink targets, and their separately anchored xattrs. The verifier now uses a
non-special exit-code local, avoids zsh's tied `path` parameter, and runs an
isolated embedded-byte zsh regression test before the legacy stop boundary.

Version 14 built, installed, and bootstrapped the new host and reached
`NEW_PID_OBSERVED`, but its exact embedded deployment verifier then invoked the
nonexistent `/bin/cmp`. Postmortem review also found a latent `/usr/bin/dd`
reference that the failed run had not yet reached. The controller performed a
complete rollback: it stopped and archived the new host, cleared the new live
destinations, re-enabled and bootstrapped the untouched legacy service, proved
that legacy was again the sole host and canonical lock holder, released the
reserve, and recorded `ROLLED_BACK`. All version-9 through version-14 pointers
and evidence remain retained.

The version-15 design accepted only the exact complete version-14 active pointer,
journal, result, provenance, build and deployment output records, source/export
records, legacy snapshot, rollback-reserve record, staged and failed app/plist
manifests, symlink targets, and separately anchored xattrs, together with the
unchanged version-9 through version-13 tombstones and a fresh proof of the exact
sole live legacy host. It replaces the two invalid verifier paths with
`/usr/bin/cmp` and `/bin/dd` and makes the isolated command-path self-test part
of the pre-stop verifier gate. That guarded retry crossed the cutover boundary,
installed and bootstrapped the new host, and reached `NEW_PID_OBSERVED`. The host
emitted its online marker quickly, before the controller captured its generation
log checkpoint at byte offset `1364`. The checkpoint therefore excluded the
already-valid marker and the post-checkpoint suffix remained empty. The bounded
marker wait expired; a deadline-edge output-drain diagnostic surfaced as `child
stdout exceeded its shared monotonic deadline`. The deployment verifier was
never started, so `records/deployment.stdout` and
`records/deployment.stderr` are absent rather than empty files.

Version 15 then completed the exact full rollback: `ROLLBACK_STARTED`,
`NEW_STOPPED`, `NEW_DESTINATIONS_CLEARED`, `LEGACY_REENABLED`,
`LEGACY_BOOTSTRAPPED`, `LEGACY_RECOVERED`, and `ROLLED_BACK`. It stopped and
archived the new host, cleared the new live destinations, re-enabled and
bootstrapped the untouched legacy service, proved legacy was again the sole host
and canonical lock holder, released the exact rollback reserve, and retained
`active-migration-v15` plus every evidence artifact. Every version-9 through
version-15 evidence tree and pointer is immutable and retained indefinitely.

The version-16 design added an exact seventh historical guard for that complete
version-15 outcome, including the exact active pointer, journal, result,
provenance, source/export and build records, legacy snapshot, rollback-reserve
identity, staged and failed app/plist manifests, symlink targets, separately
anchored xattrs, and the required absence of both deployment-output records. It
captured the readiness-log checkpoint immediately before bootstrap while the new
runtime was still proved absent. Its command runner drained stdout and stderr in
fair bounded batches and emitted one canonical timeout diagnostic.

The authorized version-16 transaction used source commit
`625941d4fc1f2f4d6254df57ee897c71c88f399d` and tree
`3507c97c3b5be7e11a9ffab6c686d615f5a96506`. It built, installed, and
bootstrapped the new host and reached `NEW_PID_OBSERVED` with PID `17632`, runs
`1`, prelaunch log offset `1364`, and nonce
`88445fa1c01ac2168e9b0e58994f43e44393da7d4a955e82c02df16e7390cd6f`.
The deployment verifier validated the staged bundle, then rejected the installed
runtime with the exact final diagnostic
`verify-mac-host-bundle: app bundle contains extended attributes: /Applications/opensteamer Host.app: com.apple.macl:`.
macOS had attached only `com.apple.macl` to the canonical installed bundle root.
Read-only postmortem inspection proved its value was exactly 72 NUL bytes, the
staged app remained xattr-free, and the installed app's signed bytes and
signatures were intact. The untouched legacy app and prior launched archives
have the same canonical root MACL shape.

Version 16 completed full rollback through `ROLLBACK_STARTED` in `FullRestore`
mode, `NEW_STOPPED`, `NEW_DESTINATIONS_CLEARED`, `LEGACY_REENABLED`,
`LEGACY_BOOTSTRAPPED`, `LEGACY_RECOVERED`, and `ROLLED_BACK`. It removed the new
live destinations, restored the untouched legacy host, and retained
`active-migration-v16` plus the complete deterministic evidence directory
`migration-v16-after-v15-1785637636-18044`. Independent live proof found the
legacy host running as PID `19053` with its exact arguments, hashes, signature,
enabled label, and canonical shared-lock ownership; the new app, plist, and
service were absent. The retained pointer SHA-256 is
`aaf2d32335687c997d8f623324c1dbb5a00855464ff2f110a2f94eb8bb97c15b`.
The 6,194-byte, 20-line journal SHA-256 is
`a95a7c0a23f8bc50a0a7270d616e75dac0b72aee2ab4676fa8d3b4be6288fbfb`;
deployment stdout is exactly empty with SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
and the 2,218-byte deployment stderr SHA-256 is
`b71cb31d6ff97ce941f65798ee357fcff8c9af922589b1a30d74dbe0071102c0`.
No iPhone was touched.

The version-17 design added an exact eighth historical guard for the complete
version-16 outcome. Its installed-runtime verifier retained strict staged
verification while permitting only a root-only, 72-NUL-byte `com.apple.macl`
on the exact canonical `/Applications/opensteamer Host.app`. It also added
inspection-only pointer preflight, generation-and-nonce-bound readiness,
byte-bounded log reads, one shared 180-second readiness deadline, and final sole
lock-holder revalidation.

The authorized version-17 transaction used source commit
`bd23d6b7bf9328a383f1d6c8da152754b915eeb5` and tree
`6b536450d997f14b356680c080328cbdced77e67`. It built, installed, and
bootstrapped the new host and reached `NEW_PID_OBSERVED` with PID `93486`,
runs `1`, prelaunch log offset `1705`, and nonce
`f69ef6518ac1c0fd57652c02fcc3284fc7a700708b9754a48f256dbb17f12450`.
Both staged and installed bundle verifiers succeeded.

The deployment oracle then exited with status `141` before `READY_VERIFIED`.
Its `code_hash` helper ran `codesign -dv --verbose=4 ... 2>&1` into an
`awk` action that printed the first `CDHash` and immediately exited. Under
zsh `set -euo pipefail`, that successful early consumer close delivered
`SIGPIPE` to `codesign`, and zsh surfaced `128 + 13 = 141`. Read-only
reproduction on the exact retained staged app returned pipeline statuses
`141 0`. The eight preceding recursive-`diff` directory-loop diagnostics did
not cause the failure; that exact retained comparison returned zero.

Version 17 completed exact `FullRestore` rollback through `NEW_STOPPED`,
`NEW_DESTINATIONS_CLEARED`, `LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`,
`LEGACY_RECOVERED`, and `ROLLED_BACK`. The new app, plist, and service are
absent. The untouched legacy host is again sole host and canonical lock holder
as PID `95038`, with exact arguments, hashes, signature, and enabled label.
The consumed authorization grants no retry. The retained
`active-migration-v17` pointer is 105 bytes with SHA-256
`c67386bd19193e913f7116cc179ec44e1768ef077103f51a897e0774324f765a`.
The evidence directory is
`migration-v17-after-v16-1785637636-18044`; its 7,075-byte, 20-line journal
SHA-256 is
`9f66fbd1aff49313ce1528d25290dbb032f720fc79c2e04c509ae230704151d1`.
Deployment stdout is exactly empty, and the 4,546-byte deployment stderr
SHA-256 is
`11a704463fb667082b2e50bf5877a24d728c0ee7e3b0a48d7686224091262254`.
No iPhone was touched.

The version-18 design added an exact ninth historical guard for that complete
version-17 outcome while preserving every earlier guard. It pinned the v17
active pointer, journal, result, provenance, source archive/export, build and
deployment records, legacy snapshot, rollback-reserve inode, staged and failed
app/plist manifests, symlink targets, and separately anchored xattrs. It also
repaired the status-141 path by consuming the complete `codesign` metadata
stream before emitting one validated CDHash.

The authorized version-18 transaction used source commit
`ff02ca6ba192b27fd1cd22e807c8d42900084f74` and tree
`fb56a78b685453901ec0ff8af2fccd446d63ea18`. It built, installed, and
bootstrapped the new host and reached `NEW_PID_OBSERVED` with PID `53809`, runs
`1`, prelaunch log offset `2127`, and nonce
`511ac5970b1235bd964bfffb97cf5dd66d975cdfccbfbd8992eb7d76ec5f7aad`.
The exact generation-bound online marker, staged and installed signatures,
installed-app policy, and canonical shared-lock proof passed.

The deployment verifier then failed before `READY_VERIFIED` with
`process start identity differs from the controller-observed generation`.
Rust's `str::trim` had removed four trailing padding spaces from the fixed-width
`/bin/ps -o lstart=` output, while zsh command substitution retained those
spaces. The timestamp was the same, but the two sides compared different
edge-whitespace representations. Internal calendar padding such as the double
space before the day in `Sun Aug  2 16:35:42 2026` must remain preserved.

Version 18 completed exact `FullRestore` rollback through `NEW_STOPPED`,
`NEW_DESTINATIONS_CLEARED`, `LEGACY_REENABLED`, `LEGACY_BOOTSTRAPPED`,
`LEGACY_RECOVERED`, and `ROLLED_BACK`. The new app, plist, and service are
absent. The untouched legacy host is again the sole host and canonical lock
holder as PID `55688`, with exact arguments, hashes, signature, and enabled
label. The consumed authorization grants no retry. The retained 105-byte
`active-migration-v18` pointer SHA-256 is
`3fd6a39f84d620a203fd75f306184356bdbfe9546d6fa45d6d19f91cb4976144`.
The evidence directory is
`migration-v18-after-v17-1785637636-18044`; its 7,956-byte, 20-line journal
SHA-256 is
`bd28126eaae9112af24eccc75f8c18fcb5b43da2e0a4eda3f40169bbed12e55d`.
The 93-byte result SHA-256 is
`434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301`,
the 375-byte provenance SHA-256 is
`b727f2a085d15722096c999d2e169ae966eb63db6eeef14a7a290808d390f261`,
and the 6,778,880-byte source archive SHA-256 is
`ea8ec3d76daa2effb4e6a955240adcc0acd9b5c24b083365218657ebb4a09a13`.
Deployment stdout is exactly empty; the 4,884-byte deployment stderr SHA-256 is
`59a06b517d0adb1223bd725fa323ab837d52e2dcd925e6b282941ff9d1f8acf1`.
No iPhone or TestFlight action occurred.

The version-19 design adds an exact tenth historical guard for that complete
version-18 rollback while preserving every earlier guard. It pins and
revalidates the v18 pointer, complete evidence, and forbidden residues around
active-pointer publication and every stop/bootstrap boundary. Its
process-start repair feeds every `ps -o lstart=` read through one canonical,
full-consuming parser. That parser trims only edge whitespace and preserves the internal double space
used to pad a single-digit day while rejecting missing,
duplicate, empty-only, or malformed records.

Version 19 remains review and inspection-only-preflight code. Its preflight
acquires only the inspection transaction lock, validates all ten historical
tombstones and the sole live legacy host, and proves the deterministic v19
evidence path absent without recovering or mutating pointer state. It reports
exactly
`PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14=v15=v16=v17=v18 legacy=sole-ready v19=absent`.
No version-19 cutover is authorized. Ordinary legacy-readiness paths retain the
bounded 60-second command budget, and the deployment proof retains one absolute
180-second deadline.
Every durable state transition is appended to and fsynced in a per-attempt
journal. A fixed fsynced active-transaction record points to the attempt. A
later invocation holding the transaction lock deterministically resumes
post-commit verification or rolls back an uncommitted attempt. It never treats a
stale lock file, journal, staged app, or partially installed destination as a
reason to abandon recovery.

The pinned launcher also exposes a read-only v19 preflight that compiles and
attests the exact reviewed controller, acquires an inspection-only transaction
lock without rewriting it, verifies all ten historical tombstones and the sole
live legacy host, validates the embedded
deployment verifier's absolute command-path set, and proves the deterministic
v19 evidence path is absent. Active-pointer inspection never invokes recovery or
changes a pointer pathname, inode, bytes, or mode:

```sh
macOS/scripts/migrate-opensteamer-host.sh --verify-reviewed-prior-retry-state /absolute/path/to/opensteamer
```

The controller requires:

- a clean pushed commit whose local `HEAD`, upstream ref, and `git ls-remote`
  object agree;
- recorded commit, tree, remote, `Package.resolved`, and immutable source-archive
  hashes;
- a clean export of that pushed commit, not the mutable checkout or prior build
  products;
- a fresh Release build with Swift and Clang warnings treated as errors;
- signing identity SHA-1
  `483C08B6517EBC1CFCCAB1A88BBEE8028750AA13`, Team ID `MSMG8CJLB3`, and complete
  designated-requirement equality to an offline per-attempt snapshot of the
  live legacy executable;
- exact bundle-tree, required framework-alias set, type, mode, xattr,
  deployment-target, dependency, install-ID, entitlement, nested-signature, and
  code-identity verification, including only the pinned LiveKit 144.7559.11
  `Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy` nested spine;
- a host architecture set containing only `arm64`/`x86_64`, with every host
  slice present in the embedded framework and no unsupported framework slice;
  and
- the host executable's sole `LC_RPATH` value
  `@executable_path/../Frameworks`, with development, toolchain, temporary,
  `@loader_path`, `/usr/lib/swift`, and unexpected relative **rpaths** rejected.
  Normal signed system load commands under `/usr/lib/swift/*.dylib` remain
  narrowly allowed as dependencies, not search paths.

## Untouched legacy rollback source

The controller may durably disable and boot out only
`com.elamin.audiostreamer.worldwide`. The launchd disabled override prevents the
preserved legacy plist from being reloaded at logout, login, or reboot after a
successful cutover. Rollback re-enables the exact label before bootstrapping the
untouched plist. The controller never moves, renames, replaces, modifies,
re-signs, quarantines, or deletes either:

- `/Applications/AudioStreamer Host.app`
- `/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist`

Immediately before stopping the legacy job, it revalidates the exact app, plist,
hashes, arguments, designated requirement, PID, launch state, and canonical
shared-lock inode. It then proves the legacy service and process absent, proves
all `CaptureServer` processes absent, and proves the exact shared advisory lock
is acquirable. Command failure or malformed output is an operational error, not
absence.

## Reviewed new LaunchAgent

`macOS/LaunchAgents/org.example.opensteamer.worldwide.plist` is the complete
production configuration. Its `ProgramArguments` are exactly:

1. `/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer`
2. `--worldwide`
3. `--allow-remote-control`
4. `--duration`
5. `0`
6. `--verbose`
7. `--rendezvous-url`
8. `wss://audiostreamer-rendezvous.elaminahmed03.workers.dev`

`RunAtLoad` and `KeepAlive` are Boolean `true`; `ThrottleInterval` is integer
`10`; `EnvironmentVariables` contains only string `OSLogRateLimit=64`; and logs
are `/var/tmp/opensteamer-worldwide-host.log` and
`/var/tmp/opensteamer-worldwide-host.err.log`. Structural verification rejects
string lookalikes, duplicate endpoints, pairing reset, LAN/test arguments,
endpoint environment overrides, and `DYLD_*` overrides.

## Readiness and commit

The new app installs side-by-side as `/Applications/opensteamer Host.app` and
the new plist installs under the distinct new label. The controller safely
opens or creates the `/var/tmp` logs without following symlinks or accepting
hard links, records the log inode and pre-start offset, and starts only
`org.example.opensteamer.worldwide`.

The controller structurally parses only the top-level launchd job block.
Nested resource and jetsam coalitions may repeat fields such as `type`, `state`,
`pid`, `program`, and `arguments`; those nested values never participate in the
job proof.

Immediately before bootstrap, while the new service and process are still
proved absent, the controller captures a fresh log checkpoint. After bootstrap,
it observes one launchd generation and binds readiness to the tuple `(PID,
process start identity, launchd runs, random per-process lock nonce, lock device,
lock inode)`. Only an exact line after the prelaunch checkpoint containing both
the observed PID and nonce can satisfy readiness, and every byte-bounded marker
check is bracketed by exact generation revalidation. A generic, partial, or
substring marker, or a correctly formatted line from an earlier KeepAlive
generation, cannot satisfy readiness. Commit
requires the legacy label to remain durably disabled and,
across more than the ten-second launchd throttle interval:

- unchanged generation tuple, including PID, start identity, launch count,
  nonce, and lock inode;
- exact mapped installed executable and LiveKit framework;
- sole ownership of the canonical shared advisory lock, with an independent
  nonblocking lock attempt proving contention;
- legacy job/process absence and no other `CaptureServer` process; and
- a fresh exact log record after the prelaunch checkpoint containing
  `Worldwide paired-device availability is online`, the current PID, and the
  current random generation nonce.

The exact same tuple and marker proof is revalidated immediately before the
journal's durable `COMMIT` record. A restart during marker acquisition, the
stability window, or the final commit check fails the attempt rather than
reusing evidence from an earlier generation.

A successful Mac cutover does not claim physical-iPhone, microphone, call-audio,
or end-to-end device validation.

One absolute 180-second monotonic deadline begins before marker observation in
each forward or committed-recovery `READY` proof. The marker wait may retain a
shorter fail-fast sublimit, but it cannot extend that shared deadline. Generation
checks, bounded log reads, pinned-verifier revalidation and execution, output
publication, and final acceptance checks all receive the same absolute
`Instant`; no wrapper or nested helper creates a replacement budget.
Final generation acceptance also re-proves that the expected PID still solely
holds the canonical advisory lock. The read-only retry preflight validates the
absolute deployment-verifier command paths and their root-owned regular-file
metadata before any version-19 evidence can be created.

## Rollback and recovery

Any uncommitted post-stop failure enters controller-owned rollback. It boots out
the new job, proves the new service and process absent, proves the exact shared
lock acquirable, and removes the new live destinations before bootstrapping the
**untouched existing** legacy plist. Failed-new evidence is copied into the
private attempt directory only when that does not delay service restoration.
Availability-first rollback gives restoration priority over duplicate evidence.
It then waits boundedly for the exact restored legacy launch state, executable,
arguments, hash, PID, and canonical lock holder while continuously proving the
new job, new process, new destination, and new lock holder absent. A delayed
legitimate startup may succeed within the bound; timeout, wrong process, or
new-host reappearance fails closed and preserves the journal evidence.

If new-host absence cannot be proved, rollback fails closed and does not overlap
the hosts. The journal remains as evidence and the Mac must remain offline for
manual inspection.

The durable `COMMIT` journal record is the sole commit point. Its exact active
pointer remains permanently as a recovery tombstone: the controller publishes
no finalizing or linearized marker and unlinks no active-pointer pathname.
After a machine, login-session, or KeepAlive restart, committed recovery treats
historical PID and log-marker fields as evidence only, establishes a fresh
generation-bound readiness proof, and then revalidates the same exact tombstone
without removing it. A generation change after that proof is an ordinary
committed lifecycle event. Pre-journal, failed, and rolled-back tombstones are
also retained, and automatic reruns fail closed for manual inspection. The sole
fresh-attempt exception is the narrowly encoded version-19 retry gate for the
exact reviewed version-9 through version-18 failures described above. If
separately authorized, it can create one deterministic version-19 evidence path
and never reuses or mutates any historical transaction.

Before legacy can be disabled, version 19 physically preallocates and fsyncs an
8 MiB owner-only rollback reserve, records its device/inode, and revalidates a
minimum 1 GiB of free space after requiring at least 2 GiB before creating the
fresh evidence tree. One absolute 180-second monotonic deadline bounds the whole
deployment proof, including its initial/final generation checks and output
collection. Rollback releases that exact reserve inode before its first
journal append, including after a crash, so an out-of-space failure cannot
prevent restoration from starting. The reserve is truncated only after rollback
or after a durable commit and retained-pointer proof.

The controller binary embeds reviewed hashes and exact bytes for all five build
and deployment scripts. It pins the matching immutable-export inodes and runs
their captured bytes through `/bin/zsh -c` with a sanitized environment; nested
deployment helpers are passed as pinned script text rather than reopened by
path. Legacy/new process absence and the shared lock are re-proved immediately
before every forward, rollback, or committed-recovery bootstrap.

Recursive xattr inspection includes symbolic-link objects. Installed-runtime
verification pins the canonical app root device/inode and repeats the complete
xattr policy after signature and designated-requirement verification, rejecting
root replacement or metadata drift.

The launcher compiles twice with the reviewed compiler, driver, explicit
sysroot, and a fixed source-path remap. Both outputs must be byte-identical and
must match the reviewed controller-binary SHA-256 before the private executable
is allowed to run. A build-only mode exercises that exact launcher path and the
complete controller self-test matrix without entering live migration.

Controller self-tests retain the deterministic fake backend and additionally
exercise the production journal, pinned-directory, app/plist hold, exclusive
publication, log-checkpoint, command-classification, rollback, and committed
recovery primitives through a guarded disposable real-filesystem adapter. The
regression matrix includes `fast-marker`, crashed-generation marker reuse,
read-only pointer-residue inspection, bounded-log overflow, `deadline-edge`,
`output-flood`, `inherited-pipe`, and end-to-end
`total-deployment-deadline` models. The
adapter rejects `/`, `/Applications`, live LaunchAgents, the live migration
state, and the production lock namespace before it can run any test command.

## Invocation

No version-19 execution is authorized. Only the read-only preflight form above
may be used during review. Do not pass the live execution flag, copy individual
cutover commands out of the controller, or substitute a shared staged app. The
script performs no iPhone operation.
