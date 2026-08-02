# Guarded side-by-side Mac host migration

The user authorized this **Mac-only** migration on July 30/31, 2026. The legacy
app and legacy LaunchAgent plist remain byte-for-byte at their existing paths as
rollback sources. The authorization does not extend to a physical iPhone,
TestFlight, pairing reset, or cleanup of recovery/evidence artifacts.

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

The current controller owns the version-14 active-pointer and journal namespace.
The retained version-9 through version-13 pointers are never moved, replaced, or
deleted. Version 14 proceeds only when version 9 is byte-for-byte the reviewed
`rolled-back-before-stop` outcome from the August 1 `/bin/chflags` path failure,
version 10 is byte-for-byte the reviewed full-restore rollback described below,
version 11 is byte-for-byte the reviewed post-readiness-timeout full rollback,
version 12 is byte-for-byte the reviewed pre-stop disk-headroom rollback, version
13 is byte-for-byte the reviewed deployment-verifier rollback described below,
all older pointer residues and hidden cutover paths are absent, and the exact
untouched legacy service is re-proved live. The corrected controller invokes the
existing system tool only at `/usr/bin/chflags`. Any different historical state
fails closed for manual inspection.

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
acquirable shared lock. Version 14 treats any new `CRITICAL_FAILURE` as
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
reserve, and recorded `ROLLED_BACK`. Version 14 accepts only that complete raw
journal/result/provenance set, the exact empty deployment stdout and exact zsh
error stderr, every retained build record, both staged/archived app manifests,
symlink targets, and their separately anchored xattrs. The verifier now uses a
non-special exit-code local, avoids zsh's tied `path` parameter, and runs an
isolated embedded-byte zsh regression test before the legacy stop boundary.

Every durable state transition is appended to and fsynced in a per-attempt
journal. A fixed fsynced active-transaction record points to the attempt. A
later invocation holding the transaction lock deterministically resumes
post-commit verification or rolls back an uncommitted attempt. It never treats a
stale lock file, journal, staged app, or partially installed destination as a
reason to abandon recovery.

The pinned launcher also exposes a read-only v14 preflight that compiles and
attests the exact reviewed controller, acquires the migration lock, verifies all
five historical tombstones and the sole live legacy host, and proves the
deterministic v14 evidence path is absent:

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

After bootstrap, the controller first observes one launchd generation, then
binds a fresh log checkpoint to the tuple `(PID, process start identity, launchd
runs, random per-process lock nonce, lock device, lock inode)`. A marker written
before that checkpoint or by another KeepAlive generation cannot satisfy
readiness. Commit requires the legacy label to remain durably disabled and,
across more than the ten-second launchd throttle interval:

- unchanged generation tuple, including PID, start identity, launch count,
  nonce, and lock inode;
- exact mapped installed executable and LiveKit framework;
- sole ownership of the canonical shared advisory lock, with an independent
  nonblocking lock attempt proving contention;
- legacy job/process absence and no other `CaptureServer` process; and
- a fresh log record after the generation-bound checkpoint containing
  `Worldwide paired-device availability is online`.

The exact same tuple and marker proof is revalidated immediately before the
journal's durable `COMMIT` record. A restart during marker acquisition, the
stability window, or the final commit check fails the attempt rather than
reusing evidence from an earlier generation.

A successful Mac cutover does not claim physical-iPhone, microphone, call-audio,
or end-to-end device validation.

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
fresh-attempt exception is the narrowly encoded version-14 retry gate for the
exact reviewed version-9 through version-13 failures described above. It
exclusively creates one deterministic version-14 evidence path and never
reuses or mutates any historical transaction.

Before legacy can be disabled, version 14 physically preallocates and fsyncs an
8 MiB owner-only rollback reserve, records its device/inode, and revalidates a
minimum 1 GiB of free space. Rollback releases that exact reserve inode before
its first journal append, including after a crash, so an out-of-space failure
cannot prevent restoration from starting. The reserve is truncated only after
rollback or after a durable commit and retained-pointer proof.

The controller binary embeds reviewed hashes and exact bytes for all five build
and deployment scripts. It pins the matching immutable-export inodes and runs
their captured bytes through `/bin/zsh -c` with a sanitized environment; nested
deployment helpers are passed as pinned script text rather than reopened by
path. Legacy/new process absence and the shared lock are re-proved immediately
before every forward, rollback, or committed-recovery bootstrap.

The launcher compiles twice with the reviewed compiler, driver, explicit
sysroot, and a fixed source-path remap. Both outputs must be byte-identical and
must match the reviewed controller-binary SHA-256 before the private executable
is allowed to run. A build-only mode exercises that exact launcher path and the
complete controller self-test matrix without entering live migration.

Controller self-tests retain the deterministic fake backend and additionally
exercise the production journal, pinned-directory, app/plist hold, exclusive
publication, log-checkpoint, command-classification, rollback, and committed
recovery primitives through a guarded disposable real-filesystem adapter. The
adapter rejects `/`, `/Applications`, live LaunchAgents, the live migration
state, and the production lock namespace before it can run any test command.

## Invocation

After source review and disposable validation, the repository operator may run:

```sh
/bin/sh macOS/scripts/migrate-opensteamer-host.sh \
  --execute-authorized-mac-only-migration \
  "$(pwd -P)"
```

Do not copy individual cutover commands out of the controller or substitute a
shared staged app. The script performs no iPhone operation.
