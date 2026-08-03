//! Guarded post-v20 updater for the already-active `opensteamer Host.app`.
//!
//! This controller is intentionally separate from the consumed v20 migration controller.
//! It never starts, stops, installs, copies, or mutates the protected legacy app, plist,
//! Keychain service, or migration evidence. The exact committed v20 opensteamer app is the
//! rollback target. The replacement is paired interactively through a pipe so its one-time
//! invitation never enters the persistent LaunchAgent stdout log.

use std::env;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, ControllerError>;

const PREFLIGHT_MODE: &str = "--verify-post-v20-host-update-preflight";
const EXECUTE_MODE: &str = "--execute-authorized-post-v20-host-update";
const PREBUILT_EXECUTE_MODE: &str =
    "--execute-authorized-post-v20-host-update-with-reviewed-prebuilt";
const ROLLBACK_MODE: &str = "--rollback-authorized-post-v20-host-update";
const SELF_TEST_MODE: &str = "--self-test-post-v20-host-update";
const PROBE_LOCK_MODE: &str = "--probe-lock";

const USER_ID: u32 = 501;
const USER_HOME: &str = "/Users/ahmed";
const NEW_APP: &str = "/Applications/opensteamer Host.app";
const NEW_EXECUTABLE: &str = "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer";
const NEW_LABEL: &str = "org.example.opensteamer.worldwide";
const NEW_PLIST: &str = "/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist";
const LEGACY_APP: &str = "/Applications/AudioStreamer Host.app";
const LEGACY_EXECUTABLE: &str = "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer";
const LEGACY_PLIST: &str =
    "/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist";
const LEGACY_LABEL: &str = "com.elamin.audiostreamer.worldwide";
const LOCK_DIRECTORY: &str =
    "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime";
const LOCK_FILE: &str = "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock";
const PRIVATE_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer";
const UPDATE_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates";
const ACTIVE_UPDATE: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/active-post-v20-host-update-v1";
const UPDATE_LOCK: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/post-v20-host-update.lock";
const V20_ACTIVE_POINTER: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/active-migration-v20";
const V20_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044";
const V20_STAGED_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044/staged/opensteamer Host.app";
const OFFLINE_LEGACY_REFERENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044/legacy-snapshot/CaptureServer";
const ONLINE_LOG: &str = "/var/tmp/opensteamer-worldwide-host.log";
const REVIEWED_PREBUILT_APP: &str =
    "/private/tmp/opensteamer-pairing-build.IhMOyT/output/opensteamer Host.app";

const EXPECTED_TEAM_ID: &str = "MSMG8CJLB3";
const EXPECTED_IDENTIFIER: &str = "com.elamin.AudioStreamer.CaptureServer";
const EXPECTED_SIGNING_IDENTITY_SHA1: &str = "483C08B6517EBC1CFCCAB1A88BBEE8028750AA13";
const ISOLATED_PAIRING_SERVICE: &str = "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1";
const PROTECTED_PAIRING_SERVICE: &str =
    "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1";

const LEGACY_EXECUTABLE_SHA256: &str =
    "1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc";
const LEGACY_PLIST_SHA256: &str =
    "419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730";
const V20_EXECUTABLE_SHA256: &str =
    "2d420326dab660e0eee8b0c839aa5fa4da4a792d8d279a682d94eccdc6fee443";
const NEW_PLIST_SHA256: &str = "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";
const V20_APP_CDHASH: &str = "72383d6ccb1d0fc21ba6716bc163fcfb6b69bf19";
const V20_ACTIVE_POINTER_SHA256: &str =
    "30d9ac5e0e0c425c0c819001fee81f80e380148e3ebeeda6ec1c9369df76dc35";
const V20_JOURNAL_SHA256: &str = "41218e48d72dc72f581dcbf5141b008ac575725936d34677d0559e39db58ec66";
const V20_RESULT_SHA256: &str = "00aca5b826c34c30e771ab23a3500733db98eef6953f27f5e658e21dad461fab";
const V20_PROVENANCE_SHA256: &str =
    "8a2eef7d374d6ac0e66906848e96766319c00c8fba6e691f99a14df1f98f1f33";
const V20_STAGED_HASHES_SHA256: &str =
    "fd00f90f30aae7dfc269236cf0b5d5e6452110797bcd99d67eebc7c0bd9b9074";
const REVIEWED_PREBUILT_EXECUTABLE_SHA256: &str =
    "ae7638a512440bb567d5e07f1067d8e5035bb59951e38c0559a74e4afa1d2e52";

const JOURNAL_HEADER: &str = "OPENSTEAMER_POST_V20_HOST_UPDATE_V1";
const HOST_ARGUMENTS: [&str; 7] = [
    "--worldwide",
    "--allow-remote-control",
    "--duration",
    "0",
    "--verbose",
    "--rendezvous-url",
    "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev",
];

const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;
const O_NOFOLLOW: i32 = 0x0000_0100;
const RENAME_EXCL: u32 = 0x0000_0004;
const AT_FDCWD: i32 = -2;
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;

#[link(name = "System")]
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
    fn renameatx_np(
        olddirfd: i32,
        old: *const std::os::raw::c_char,
        newdirfd: i32,
        new: *const std::os::raw::c_char,
        flags: u32,
    ) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
}

#[derive(Debug, Clone)]
struct ControllerError(String);

impl std::fmt::Display for ControllerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ControllerError {}

impl From<std::io::Error> for ControllerError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum UpdateState {
    Begun,
    SourceExported,
    BuildVerified,
    StopInitiated,
    InstallHoldVerified,
    V20Stopped,
    InteractiveReady,
    PairingCommitted,
    InteractiveStopped,
    V20Held,
    NewPublished,
    PersistentBootstrapped,
    ReadyVerified,
    Committed,
    RollbackStarted,
    FailedNewArchived,
    V20Restored,
    V20Bootstrapped,
    RolledBack,
    CriticalFailure,
}

impl UpdateState {
    fn token(self) -> &'static str {
        match self {
            Self::Begun => "BEGUN",
            Self::SourceExported => "SOURCE_EXPORTED",
            Self::BuildVerified => "BUILD_VERIFIED",
            Self::InstallHoldVerified => "INSTALL_HOLD_VERIFIED",
            Self::StopInitiated => "STOP_INITIATED",
            Self::V20Stopped => "V20_STOPPED",
            Self::InteractiveReady => "INTERACTIVE_READY",
            Self::PairingCommitted => "PAIRING_COMMITTED",
            Self::InteractiveStopped => "INTERACTIVE_STOPPED",
            Self::V20Held => "V20_HELD",
            Self::NewPublished => "NEW_PUBLISHED",
            Self::PersistentBootstrapped => "PERSISTENT_BOOTSTRAPPED",
            Self::ReadyVerified => "READY_VERIFIED",
            Self::Committed => "COMMITTED",
            Self::RollbackStarted => "ROLLBACK_STARTED",
            Self::FailedNewArchived => "FAILED_NEW_ARCHIVED",
            Self::V20Restored => "V20_RESTORED",
            Self::V20Bootstrapped => "V20_BOOTSTRAPPED",
            Self::RolledBack => "ROLLED_BACK",
            Self::CriticalFailure => "CRITICAL_FAILURE",
        }
    }

    fn parse(token: &str) -> Option<Self> {
        Some(match token {
            "BEGUN" => Self::Begun,
            "SOURCE_EXPORTED" => Self::SourceExported,
            "BUILD_VERIFIED" => Self::BuildVerified,
            "INSTALL_HOLD_VERIFIED" => Self::InstallHoldVerified,
            "STOP_INITIATED" => Self::StopInitiated,
            "V20_STOPPED" => Self::V20Stopped,
            "INTERACTIVE_READY" => Self::InteractiveReady,
            "PAIRING_COMMITTED" => Self::PairingCommitted,
            "INTERACTIVE_STOPPED" => Self::InteractiveStopped,
            "V20_HELD" => Self::V20Held,
            "NEW_PUBLISHED" => Self::NewPublished,
            "PERSISTENT_BOOTSTRAPPED" => Self::PersistentBootstrapped,
            "READY_VERIFIED" => Self::ReadyVerified,
            "COMMITTED" => Self::Committed,
            "ROLLBACK_STARTED" => Self::RollbackStarted,
            "FAILED_NEW_ARCHIVED" => Self::FailedNewArchived,
            "V20_RESTORED" => Self::V20Restored,
            "V20_BOOTSTRAPPED" => Self::V20Bootstrapped,
            "ROLLED_BACK" => Self::RolledBack,
            "CRITICAL_FAILURE" => Self::CriticalFailure,
            _ => return None,
        })
    }
}

struct Journal {
    path: PathBuf,
    file: File,
    state: UpdateState,
    healthy: bool,
}

impl Journal {
    fn create(path: &Path) -> Result<Self> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .read(true)
            .mode(0o600)
            .custom_flags(O_NOFOLLOW | 0x0100_0000)
            .open(path)
            .map_err(|error| ControllerError(format!("cannot create journal: {error}")))?;
        validate_open_journal_file(path, &file)?;
        writeln!(file, "{JOURNAL_HEADER}")?;
        file.sync_all()?;
        fsync_parent(path)?;
        let mut journal = Self {
            path: path.to_path_buf(),
            file,
            state: UpdateState::Begun,
            healthy: true,
        };
        journal.record(UpdateState::Begun, &[])?;
        Ok(journal)
    }

    fn open(path: &Path) -> Result<Self> {
        require_regular(path, 0o600)?;
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(O_NOFOLLOW | 0x0100_0000)
            .open(path)?;
        validate_open_journal_file(path, &file)?;
        let bytes = read_open_journal_bytes(&mut file)?;
        let complete_length = bytes
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map_or(0, |index| index + 1);
        let complete_text = std::str::from_utf8(&bytes[..complete_length])
            .map_err(|_| ControllerError("update journal is not UTF-8".to_owned()))?;
        let state = parse_journal(complete_text)?;
        if complete_length != bytes.len() {
            if !is_plausible_torn_journal_tail(&bytes[complete_length..], state) {
                return Err(ControllerError(
                    "update journal has an implausible incomplete final record".to_owned(),
                ));
            }
            validate_open_journal_file(path, &file)?;
            file.set_len(complete_length as u64)?;
            file.sync_all()?;
        }
        file.seek(SeekFrom::End(0))?;
        Ok(Self {
            path: path.to_path_buf(),
            file,
            state,
            healthy: true,
        })
    }

    fn record(&mut self, state: UpdateState, fields: &[(&str, String)]) -> Result<()> {
        self.require_healthy()?;
        validate_transition(self.state, state)?;
        validate_journal_record_fields(state, fields)?;
        let mut record = Vec::new();
        write!(record, "STATE {}", state.token())?;
        for (key, value) in fields {
            write!(record, " {key}={value}")?;
        }
        record.push(b'\n');

        let prior_length = self.file.seek(SeekFrom::End(0))?;
        self.healthy = false;
        if let Err(error) = self
            .file
            .write_all(&record)
            .and_then(|_| self.file.sync_all())
        {
            let recovery = self.restore_after_failed_append(prior_length);
            return match recovery {
                Ok(()) => Err(ControllerError(format!(
                    "cannot durably append update journal record: {error}"
                ))),
                Err(recovery_error) => Err(ControllerError(format!(
                    "cannot durably append update journal record ({error}) or restore its prior length ({recovery_error})"
                ))),
            };
        }
        if let Err(error) = validate_open_journal_file(&self.path, &self.file) {
            return Err(ControllerError(format!(
                "journal path changed after a durable append: {error}"
            )));
        }
        self.state = state;
        self.healthy = true;
        Ok(())
    }

    fn require_healthy(&mut self) -> Result<()> {
        if !self.healthy {
            return Err(ControllerError(
                "update journal is poisoned after an unrecovered append failure".to_owned(),
            ));
        }
        if let Err(error) = validate_open_journal_file(&self.path, &self.file) {
            self.healthy = false;
            return Err(error);
        }
        Ok(())
    }

    fn restore_after_failed_append(&mut self, prior_length: u64) -> Result<()> {
        self.file.set_len(prior_length)?;
        self.file.sync_all()?;
        validate_open_journal_file(&self.path, &self.file)?;
        let bytes = read_open_journal_bytes(&mut self.file)?;
        if bytes.len() as u64 != prior_length || !bytes.ends_with(b"\n") {
            return Err(ControllerError(
                "journal append recovery did not restore the prior durable length".to_owned(),
            ));
        }
        let text = std::str::from_utf8(&bytes)
            .map_err(|_| ControllerError("recovered update journal is not UTF-8".to_owned()))?;
        if parse_journal(text)? != self.state {
            return Err(ControllerError(
                "journal append recovery did not restore the prior state".to_owned(),
            ));
        }
        self.file.seek(SeekFrom::End(0))?;
        self.healthy = true;
        Ok(())
    }
}

fn validate_open_journal_file(path: &Path, file: &File) -> Result<()> {
    let descriptor = file.metadata()?;
    let entry = fs::symlink_metadata(path)?;
    if !descriptor.file_type().is_file()
        || !entry.file_type().is_file()
        || entry.file_type().is_symlink()
        || descriptor.dev() != entry.dev()
        || descriptor.ino() != entry.ino()
        || descriptor.uid() != USER_ID
        || entry.uid() != USER_ID
        || descriptor.nlink() != 1
        || entry.nlink() != 1
        || descriptor.permissions().mode() & 0o777 != 0o600
        || entry.permissions().mode() & 0o777 != 0o600
    {
        return Err(ControllerError(
            "update journal has unsafe or substituted metadata".to_owned(),
        ));
    }
    Ok(())
}

fn read_open_journal_bytes(file: &mut File) -> Result<Vec<u8>> {
    let metadata = file.metadata()?;
    if metadata.len() > 1_048_576 {
        return Err(ControllerError(
            "update journal exceeds bounded read limit".to_owned(),
        ));
    }
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    (&mut *file).take(1_048_577).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > 1_048_576 {
        return Err(ControllerError(
            "update journal grew beyond bounded read limit".to_owned(),
        ));
    }
    Ok(bytes)
}

struct Layout {
    repo: PathBuf,
    evidence: PathBuf,
    source_tar: PathBuf,
    source_export: PathBuf,
    stage_output: PathBuf,
    staged_app: PathBuf,
    scratch: PathBuf,
    rollback_dir: PathBuf,
    rollback_app: PathBuf,
    failed_dir: PathBuf,
    failed_app: PathBuf,
    rollback_reserve: PathBuf,
    install_hold_root: PathBuf,
    install_hold: PathBuf,
    journal: PathBuf,
    result: PathBuf,
}

impl Layout {
    fn new(repo: PathBuf, evidence: PathBuf, nonce: &str) -> Self {
        let stage_output = evidence.join("staged-output");
        let install_hold_root = PathBuf::from(format!(
            "/Applications/.opensteamer-post-v20-install-{nonce}"
        ));
        Self {
            repo,
            source_tar: evidence.join("source.tar"),
            source_export: evidence.join("source-export"),
            staged_app: stage_output.join("opensteamer Host.app"),
            stage_output,
            scratch: evidence.join("swiftpm-scratch"),
            rollback_dir: evidence.join("rollback-v20"),
            rollback_app: evidence.join("rollback-v20/opensteamer Host.app"),
            failed_dir: evidence.join("failed-new"),
            failed_app: evidence.join("failed-new/opensteamer Host.app"),
            rollback_reserve: evidence.join("rollback-reserve.bin"),
            install_hold: install_hold_root.join("opensteamer Host.app"),
            install_hold_root,
            journal: evidence.join("journal.log"),
            result: evidence.join("result.txt"),
            evidence,
        }
    }
}

struct Provenance {
    commit: String,
    tree: String,
    upstream: String,
    remote: String,
}

#[derive(Clone, Debug)]
enum BuildInput {
    Fresh,
    ReviewedPrebuilt(PathBuf),
}

struct LockGuard {
    file: File,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        // SAFETY: `file` owns a live descriptor until after this Drop body.
        unsafe {
            flock(self.file.as_raw_fd(), LOCK_UN);
        }
    }
}

struct UpdateTransactionLock {
    file: File,
}

impl Drop for UpdateTransactionLock {
    fn drop(&mut self) {
        // SAFETY: `file` owns a live descriptor until after this Drop body.
        unsafe {
            flock(self.file.as_raw_fd(), LOCK_UN);
        }
    }
}

#[derive(Clone, Debug)]
struct LaunchGeneration {
    pid: u32,
    runs: u64,
    process_start: String,
    nonce: String,
    lock_device: u64,
    lock_inode: u64,
}

#[derive(Clone, Debug)]
struct LogCheckpoint {
    offset: u64,
    device: u64,
    inode: u64,
}

fn main() {
    if let Err(error) = real_main() {
        eprintln!("opensteamer post-v20 update controller: {error}");
        std::process::exit(1);
    }
}

fn real_main() -> Result<()> {
    let arguments: Vec<String> = env::args().collect();
    match arguments.as_slice() {
        [_, mode, repo] if mode == PREFLIGHT_MODE => {
            let repo = canonical_repo(repo)?;
            verify_machine_contract()?;
            let _update_lock = acquire_update_transaction_lock()?;
            verify_pristine_v20_evidence()?;
            let generation = verify_v20_runtime()?;
            verify_git_provenance(&repo, false)?;
            require_path_absent(Path::new(ACTIVE_UPDATE), "active post-v20 update pointer")?;
            println!(
                "POST_V20_UPDATE_PREFLIGHT_OK pid={} runs={} v20=sole-ready legacy=protected update=absent",
                generation.pid, generation.runs
            );
            Ok(())
        }
        [_, mode, repo] if mode == EXECUTE_MODE => {
            let repo = canonical_repo(repo)?;
            execute_update(repo, BuildInput::Fresh)
        }
        [_, mode, repo, prebuilt] if mode == PREBUILT_EXECUTE_MODE => {
            let repo = canonical_repo(repo)?;
            if prebuilt != REVIEWED_PREBUILT_APP {
                return Err(ControllerError(format!(
                    "reviewed prebuilt path must be exactly {REVIEWED_PREBUILT_APP}"
                )));
            }
            execute_update(repo, BuildInput::ReviewedPrebuilt(PathBuf::from(prebuilt)))
        }
        [_, mode, repo] if mode == ROLLBACK_MODE => {
            let repo = canonical_repo(repo)?;
            rollback_existing_update(repo)
        }
        [_, mode] if mode == SELF_TEST_MODE => self_test(),
        [_, mode, runtime, lock, pid] if mode == PROBE_LOCK_MODE => {
            if runtime != LOCK_DIRECTORY || lock != LOCK_FILE {
                return Err(ControllerError(
                    "lock probe paths differ from the canonical shared lock".to_owned(),
                ));
            }
            let pid = parse_positive_u32(pid, "lock-holder PID")?;
            prove_lock_holder(pid, Duration::from_secs(4))?;
            println!("lock_holder={pid}");
            Ok(())
        }
        _ => Err(ControllerError(format!(
            "usage: {} {{{PREFLIGHT_MODE}|{EXECUTE_MODE}|{ROLLBACK_MODE}}} <canonical-repo>\n       {} {PREBUILT_EXECUTE_MODE} <canonical-repo> {REVIEWED_PREBUILT_APP}\n       {} {SELF_TEST_MODE}\n       {} {PROBE_LOCK_MODE} <runtime-dir> <lock-file> <pid>",
            arguments.first().map_or("controller", String::as_str),
            arguments.first().map_or("controller", String::as_str),
            arguments.first().map_or("controller", String::as_str),
            arguments.first().map_or("controller", String::as_str)
        ))),
    }
}

fn execute_update(repo: PathBuf, build_input: BuildInput) -> Result<()> {
    verify_machine_contract()?;
    let update_lock = acquire_update_transaction_lock()?;
    verify_pristine_v20_evidence()?;
    let initial_generation = verify_v20_runtime()?;
    let provenance = verify_git_provenance(&repo, true)?;
    require_path_absent(Path::new(ACTIVE_UPDATE), "active post-v20 update pointer")?;
    match &build_input {
        BuildInput::Fresh => require_available_bytes(
            Path::new(PRIVATE_ROOT),
            2 * 1_024 * 1_024 * 1_024,
            "before creating fresh-build post-v20 update evidence",
        )?,
        BuildInput::ReviewedPrebuilt(app) => {
            verify_reviewed_prebuilt_source(&repo, app)?;
            require_available_bytes(
                Path::new(PRIVATE_ROOT),
                768 * 1_024 * 1_024,
                "before creating reviewed-prebuilt post-v20 update evidence",
            )?;
        }
    }

    let nonce = new_nonce()?;
    let evidence = PathBuf::from(UPDATE_ROOT).join(format!(
        "post-v20-update-{}-{}-{}",
        unix_seconds()?,
        std::process::id(),
        nonce
    ));
    create_private_directory(Path::new(UPDATE_ROOT))?;
    create_private_directory(&evidence)?;
    let layout = Layout::new(repo, evidence, &nonce);
    create_private_directory(&layout.rollback_dir)?;
    create_private_directory(&layout.failed_dir)?;
    let mut journal = Journal::create(&layout.journal)?;
    record_install_hold_name(&layout)?;

    let result = perform_update(
        &layout,
        &mut journal,
        &provenance,
        &initial_generation,
        &build_input,
    );
    match result {
        Ok(()) => Ok(()),
        Err(primary) => {
            if journal.state == UpdateState::Committed {
                let _ = write_result(
                    &layout.result,
                    "success-with-warning",
                    Some(&primary.to_string()),
                );
                eprintln!(
                    "warning: post-v20 update is durably committed but final reporting failed: {primary}"
                );
                return Ok(());
            }
            let pointer_absent_before_stop = journal.state == UpdateState::StopInitiated
                && matches!(
                    fs::symlink_metadata(ACTIVE_UPDATE),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound
                );
            let crossed_stop = journal.state >= UpdateState::StopInitiated
                && journal.state < UpdateState::Committed
                && !pointer_absent_before_stop;
            if !crossed_stop {
                if layout.rollback_reserve.exists() {
                    let _ = release_rollback_reserve(&layout.rollback_reserve);
                }
                let _ = archive_install_hold_if_present(&layout);
                let _ = write_result(
                    &layout.result,
                    "failed-before-stop",
                    Some(&primary.to_string()),
                );
                return Err(primary);
            }
            verify_active_update_pointer(&layout.evidence)?;
            match rollback_to_v20(&layout, &mut journal, &update_lock) {
                Ok(()) => {
                    write_result(&layout.result, "rolled-back", Some(&primary.to_string()))?;
                    retire_active_update_pointer(&layout)?;
                    Err(ControllerError(format!(
                        "update failed and exact v20 was restored; evidence={}: {primary}",
                        layout.evidence.display()
                    )))
                }
                Err(rollback) => {
                    let _ = journal.record(
                        UpdateState::CriticalFailure,
                        &[("phase", "rollback".to_owned())],
                    );
                    let _ = write_result(
                        &layout.result,
                        "critical-failure",
                        Some(&format!("primary={primary}; rollback={rollback}")),
                    );
                    Err(ControllerError(format!(
                        "CRITICAL: update and rollback both failed; keep the host offline; evidence={}: primary={primary}; rollback={rollback}",
                        layout.evidence.display()
                    )))
                }
            }
        }
    }
}

fn perform_update(
    layout: &Layout,
    journal: &mut Journal,
    provenance: &Provenance,
    initial_generation: &LaunchGeneration,
    build_input: &BuildInput,
) -> Result<()> {
    export_source(layout, provenance)?;
    journal.record(
        UpdateState::SourceExported,
        &[
            ("commit", provenance.commit.clone()),
            ("tree", provenance.tree.clone()),
            ("initial_pid", initial_generation.pid.to_string()),
        ],
    )?;

    match build_input {
        BuildInput::Fresh => build_and_verify_staged_app(layout)?,
        BuildInput::ReviewedPrebuilt(app) => import_and_verify_prebuilt(layout, app)?,
    }
    journal.record(
        UpdateState::BuildVerified,
        &[(
            "executable_sha256",
            sha256(&layout.staged_app.join("Contents/MacOS/CaptureServer"))?,
        )],
    )?;

    let minimum_pre_stop = match build_input {
        BuildInput::Fresh => 1_024 * 1_024 * 1_024,
        BuildInput::ReviewedPrebuilt(_) => 768 * 1_024 * 1_024,
    };
    require_available_bytes(
        Path::new(PRIVATE_ROOT),
        minimum_pre_stop,
        "after staging and immediately before stopping v20",
    )?;

    // Reprove every live precondition immediately before stopping the only active host.
    let revalidated = verify_v20_runtime()?;
    if revalidated.pid != initial_generation.pid
        || revalidated.process_start != initial_generation.process_start
        || revalidated.nonce != initial_generation.nonce
    {
        return Err(ControllerError(
            "committed v20 launch generation changed during the build".to_owned(),
        ));
    }

    let reserve = allocate_rollback_reserve(&layout.rollback_reserve, 8 * 1_024 * 1_024)?;
    journal.record(
        UpdateState::StopInitiated,
        &[
            ("reserve_device", reserve.0.to_string()),
            ("reserve_inode", reserve.1.to_string()),
            ("reserve_bytes", reserve.2.to_string()),
        ],
    )?;
    publish_active_pointer(&layout.evidence)?;
    prepare_install_hold(layout)?;
    journal.record(UpdateState::InstallHoldVerified, &[])?;
    verify_active_update_pointer(&layout.evidence)?;
    bootout_exact_new_job()?;
    wait_for_no_capture_servers(Duration::from_secs(30))?;
    require_service_absent(NEW_LABEL)?;
    require_legacy_disabled_and_absent()?;
    let lock = acquire_unowned_shared_lock()?;
    journal.record(UpdateState::V20Stopped, &[])?;
    drop(lock);

    // The canonical committed v20 app and plist remain byte-for-byte in place throughout
    // interactive pairing. Only the separately signed staged executable runs here.
    let mut child = InteractiveChildGuard::new(spawn_interactive_host(layout)?);
    let interactive = match wait_for_interactive_pairing(child.child_mut()?, layout, journal) {
        Ok(value) => value,
        Err(error) => {
            let _ = child.terminate();
            return Err(error);
        }
    };
    journal.record(
        UpdateState::PairingCommitted,
        &[
            ("pid", interactive.pid.to_string()),
            (
                "process_start",
                journal_process_start(&interactive.process_start),
            ),
            ("nonce", interactive.nonce),
            ("lock_device", interactive.lock_device.to_string()),
            ("lock_inode", interactive.lock_inode.to_string()),
        ],
    )?;
    child.terminate()?;
    wait_for_no_capture_servers(Duration::from_secs(20))?;
    let lock = acquire_unowned_shared_lock()?;
    journal.record(UpdateState::InteractiveStopped, &[])?;

    // Pairing is now durably committed in the isolated namespace and no host owns the shared
    // lock. Only at this boundary may the controller move v20 into retained rollback storage.
    verify_exact_v20_app_at(Path::new(NEW_APP))?;
    rename_exclusive(Path::new(NEW_APP), &layout.rollback_app)?;
    fsync_parent(Path::new(NEW_APP))?;
    fsync_parent(&layout.rollback_app)?;
    verify_exact_v20_app_at(&layout.rollback_app)?;
    journal.record(UpdateState::V20Held, &[])?;

    rename_exclusive(&layout.install_hold, Path::new(NEW_APP))?;
    fsync_parent(&layout.install_hold)?;
    fsync_parent(Path::new(NEW_APP))?;
    fs::remove_dir(&layout.install_hold_root).map_err(|error| {
        ControllerError(format!(
            "cannot remove emptied hidden install-hold root {}: {error}",
            layout.install_hold_root.display()
        ))
    })?;
    fsync_parent(&layout.install_hold_root)?;
    verify_installed_matches_stage(layout)?;
    journal.record(UpdateState::NewPublished, &[])?;
    drop(lock);

    let checkpoint = capture_log_checkpoint()?;
    bootstrap_exact_new_job()?;
    journal.record(UpdateState::PersistentBootstrapped, &[])?;
    let generation = wait_for_launch_generation(Duration::from_secs(45))?;
    verify_deployment(
        &layout.source_export,
        &layout.staged_app,
        &checkpoint,
        &generation,
    )?;
    journal.record(
        UpdateState::ReadyVerified,
        &[
            ("pid", generation.pid.to_string()),
            ("runs", generation.runs.to_string()),
            ("nonce", generation.nonce.clone()),
        ],
    )?;
    verify_pristine_v20_evidence()?;
    verify_legacy_sources()?;
    require_legacy_disabled_and_absent()?;
    release_rollback_reserve(&layout.rollback_reserve)?;
    journal.record(UpdateState::Committed, &[])?;
    if let Err(error) = write_result(&layout.result, "success", None) {
        eprintln!(
            "warning: post-v20 update is durably committed but result recording failed: {error}"
        );
    }
    println!(
        "POST_V20_HOST_UPDATE_COMMITTED evidence={} pid={} rollback=v20-retained",
        layout.evidence.display(),
        generation.pid
    );
    Ok(())
}

#[derive(Debug, Eq, PartialEq)]
struct InteractiveGeneration {
    pid: u32,
    process_start: String,
    nonce: String,
    lock_device: u64,
    lock_inode: u64,
}

struct InteractiveChildGuard {
    child: Option<Child>,
}

impl InteractiveChildGuard {
    fn new(child: Child) -> Self {
        Self { child: Some(child) }
    }

    fn child_mut(&mut self) -> Result<&mut Child> {
        self.child
            .as_mut()
            .ok_or_else(|| ControllerError("interactive child guard is empty".to_owned()))
    }

    fn terminate(&mut self) -> Result<()> {
        if let Some(child) = self.child.as_mut() {
            terminate_child(child)?;
            self.child.take();
        }
        Ok(())
    }
}

impl Drop for InteractiveChildGuard {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if child.try_wait().ok().flatten().is_none() {
                if let Ok(pid) = i32::try_from(child.id()) {
                    // SAFETY: this PID belongs to the exact child retained by the guard.
                    if unsafe { kill(pid, SIGKILL) } == 0 {
                        let deadline = Instant::now() + Duration::from_secs(2);
                        while Instant::now() < deadline {
                            if child.try_wait().ok().flatten().is_some() {
                                break;
                            }
                            thread::sleep(Duration::from_millis(20));
                        }
                    }
                }
            }
        }
    }
}

fn wait_for_interactive_pairing(
    child: &mut Child,
    layout: &Layout,
    journal: &mut Journal,
) -> Result<InteractiveGeneration> {
    let pid = child.id();
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ControllerError("interactive host stdout pipe is unavailable".to_owned()))?;
    let (sender, receiver) = mpsc::channel::<std::io::Result<String>>();
    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            let terminal = line.is_err();
            if sender.send(line).is_err() || terminal {
                break;
            }
        }
    });

    let code_deadline = Instant::now() + Duration::from_secs(75);
    let pairing_deadline = Instant::now() + Duration::from_secs(12 * 60);
    let mut invitation_seen = false;
    let mut committed = false;
    let mut marker_stage = 0u8;
    let mut interactive_generation: Option<InteractiveGeneration> = None;

    while !committed {
        if let Some(status) = child.try_wait()? {
            return Err(ControllerError(format!(
                "interactive host exited before pairing committed: {status}"
            )));
        }
        if !invitation_seen && Instant::now() >= code_deadline {
            return Err(ControllerError(
                "interactive host did not present an invitation within 75 seconds".to_owned(),
            ));
        }
        if Instant::now() >= pairing_deadline {
            return Err(ControllerError(
                "interactive pairing did not commit before its bounded deadline".to_owned(),
            ));
        }

        match receiver.recv_timeout(Duration::from_millis(250)) {
            Ok(Ok(line)) => {
                if line == "Worldwide one-time pairing code" {
                    marker_stage = 1;
                    continue;
                }
                if marker_stage == 1 && line == "-------------------------------" {
                    marker_stage = 2;
                    continue;
                }
                if marker_stage == 2 {
                    if !is_valid_invitation_code(&line) {
                        return Err(ControllerError(
                            "interactive host emitted a malformed invitation".to_owned(),
                        ));
                    }
                    if invitation_seen {
                        return Err(ControllerError(
                            "interactive host emitted more than one invitation".to_owned(),
                        ));
                    }
                    let generation = verify_interactive_generation(pid, layout)?;
                    println!("OPENSTEAMER_ONE_TIME_PAIRING_CODE {line}");
                    println!("Enter this code in the separate opensteamer TestFlight app now; the updater will finish after secure pairing commits.");
                    std::io::stdout().flush()?;
                    journal.record(
                        UpdateState::InteractiveReady,
                        &[
                            ("pid", generation.pid.to_string()),
                            (
                                "process_start",
                                journal_process_start(&generation.process_start),
                            ),
                            ("nonce", generation.nonce.clone()),
                            ("lock_device", generation.lock_device.to_string()),
                            ("lock_inode", generation.lock_inode.to_string()),
                        ],
                    )?;
                    interactive_generation = Some(generation);
                    invitation_seen = true;
                    marker_stage = 3;
                    continue;
                }
                if line.contains(
                    "Worldwide pairing committed; the Mac will now accept secure reconnects",
                ) {
                    if !invitation_seen {
                        return Err(ControllerError(
                            "pairing commit appeared before a validated invitation".to_owned(),
                        ));
                    }
                    committed = true;
                    continue;
                }
                // Forward non-secret host status to the invoking terminal only. It is never
                // copied into the transaction journal or persistent LaunchAgent log.
                if !line.is_empty() {
                    eprintln!("interactive-host: {line}");
                }
            }
            Ok(Err(error)) => {
                return Err(ControllerError(format!(
                    "could not read interactive host output: {error}"
                )));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(ControllerError(
                    "interactive host output ended before pairing committed".to_owned(),
                ));
            }
        }
    }

    let generation = interactive_generation.ok_or_else(|| {
        ControllerError("pairing committed without an accepted interactive generation".to_owned())
    })?;
    let committed_generation = verify_interactive_generation(pid, layout)?;
    if committed_generation != generation {
        return Err(ControllerError(
            "interactive host generation changed between invitation and pairing commit".to_owned(),
        ));
    }
    Ok(generation)
}

fn verify_interactive_generation(pid: u32, layout: &Layout) -> Result<InteractiveGeneration> {
    let staged_executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
    require_service_absent(NEW_LABEL)?;
    require_legacy_disabled_and_absent()?;
    require_solo_capture_server(&staged_executable, pid)?;
    verify_live_process(&layout.source_export, pid, &layout.staged_app)?;
    let process_start_identity = process_start(pid)?;
    let (lock_device, lock_inode, nonce) = read_generation_lock(pid)?;
    prove_lock_holder(pid, Duration::from_secs(4))?;
    thread::sleep(Duration::from_secs(2));
    require_solo_capture_server(&staged_executable, pid)?;
    verify_live_process(&layout.source_export, pid, &layout.staged_app)?;
    let process_start_after = process_start(pid)?;
    let (lock_device_after, lock_inode_after, nonce_after) = read_generation_lock(pid)?;
    if process_start_after != process_start_identity
        || lock_device_after != lock_device
        || lock_inode_after != lock_inode
        || nonce_after != nonce
    {
        return Err(ControllerError(
            "interactive host generation changed during readiness proof".to_owned(),
        ));
    }
    prove_lock_holder(pid, Duration::from_secs(4))?;
    Ok(InteractiveGeneration {
        pid,
        process_start: process_start_identity,
        nonce,
        lock_device,
        lock_inode,
    })
}

fn journal_process_start(value: &str) -> String {
    value.replace(' ', "_")
}

fn rollback_existing_update(repo: PathBuf) -> Result<()> {
    verify_machine_contract()?;
    let update_lock = acquire_update_transaction_lock()?;
    verify_pristine_v20_evidence()?;
    let evidence = read_active_update_pointer()?;
    let layout = layout_from_existing(repo, evidence)?;
    let mut journal = Journal::open(&layout.journal)?;
    if journal.state == UpdateState::RolledBack {
        verify_v20_runtime()?;
        ensure_rolled_back_result(&layout.result)?;
        retire_active_update_pointer(&layout)?;
        println!("POST_V20_HOST_UPDATE_ALREADY_ROLLED_BACK");
        return Ok(());
    }
    rollback_to_v20(&layout, &mut journal, &update_lock)?;
    write_result(&layout.result, "rolled-back-by-explicit-request", None)?;
    retire_active_update_pointer(&layout)?;
    println!(
        "POST_V20_HOST_UPDATE_ROLLED_BACK evidence={}",
        layout.evidence.display()
    );
    Ok(())
}

fn rollback_to_v20(
    layout: &Layout,
    journal: &mut Journal,
    _update_lock: &UpdateTransactionLock,
) -> Result<()> {
    journal.require_healthy()?;
    verify_active_update_pointer(&layout.evidence)?;
    if journal.state == UpdateState::RolledBack {
        verify_v20_runtime()?;
        return Ok(());
    }
    let already_rolling_back = matches!(
        journal.state,
        UpdateState::RollbackStarted
            | UpdateState::FailedNewArchived
            | UpdateState::V20Restored
            | UpdateState::V20Bootstrapped
    );
    if !already_rolling_back {
        journal.record(UpdateState::RollbackStarted, &[])?;
    }
    if layout.rollback_reserve.exists() {
        release_rollback_reserve(&layout.rollback_reserve)?;
    }
    bootout_new_job_if_loaded(layout)?;
    terminate_staged_host_if_present(layout)?;
    wait_for_no_capture_servers(Duration::from_secs(30))?;
    require_service_absent(NEW_LABEL)?;
    require_legacy_disabled_and_absent()?;
    let lock = acquire_unowned_shared_lock()?;

    if journal.state == UpdateState::RollbackStarted {
        archive_install_hold_if_present(layout)?;
        if layout.rollback_app.exists() {
            verify_exact_v20_app_at(&layout.rollback_app)?;
            if Path::new(NEW_APP).exists() {
                require_path_absent(&layout.failed_app, "failed-new archive")?;
                rename_exclusive(Path::new(NEW_APP), &layout.failed_app)?;
                fsync_parent(Path::new(NEW_APP))?;
                fsync_parent(&layout.failed_app)?;
                journal.record(UpdateState::FailedNewArchived, &[])?;
            } else if layout.failed_app.exists() {
                journal.record(UpdateState::FailedNewArchived, &[])?;
            }
        } else {
            verify_exact_v20_app_at(Path::new(NEW_APP))?;
            journal.record(UpdateState::V20Restored, &[])?;
        }
    }

    if journal.state == UpdateState::FailedNewArchived {
        if layout.rollback_app.exists() {
            verify_exact_v20_app_at(&layout.rollback_app)?;
            require_path_absent(Path::new(NEW_APP), "canonical app before v20 restore")?;
            rename_exclusive(&layout.rollback_app, Path::new(NEW_APP))?;
            fsync_parent(Path::new(NEW_APP))?;
            fsync_parent(&layout.rollback_app)?;
        } else {
            // A crash may occur after the exclusive restore rename but before its journal fsync.
            verify_exact_v20_app_at(Path::new(NEW_APP))?;
        }
        journal.record(UpdateState::V20Restored, &[])?;
    } else if journal.state == UpdateState::RollbackStarted && layout.rollback_app.exists() {
        verify_exact_v20_app_at(&layout.rollback_app)?;
        require_path_absent(Path::new(NEW_APP), "canonical app before v20 restore")?;
        rename_exclusive(&layout.rollback_app, Path::new(NEW_APP))?;
        fsync_parent(Path::new(NEW_APP))?;
        fsync_parent(&layout.rollback_app)?;
        journal.record(UpdateState::V20Restored, &[])?;
    }
    if journal.state != UpdateState::V20Restored && journal.state != UpdateState::V20Bootstrapped {
        return Err(ControllerError(format!(
            "rollback journal/app topology is not resumable from {}",
            journal.state.token()
        )));
    }
    drop(lock);

    verify_exact_v20_app_at(Path::new(NEW_APP))?;
    let checkpoint = capture_log_checkpoint()?;
    bootstrap_exact_new_job()?;
    if journal.state == UpdateState::V20Restored {
        journal.record(UpdateState::V20Bootstrapped, &[])?;
    }
    let generation = wait_for_launch_generation(Duration::from_secs(45))?;
    verify_deployment(
        &layout.source_export,
        Path::new(V20_STAGED_APP),
        &checkpoint,
        &generation,
    )?;
    verify_pristine_v20_evidence()?;
    journal.record(UpdateState::RolledBack, &[])?;
    verify_v20_runtime()?;
    Ok(())
}

fn layout_from_existing(repo: PathBuf, evidence: PathBuf) -> Result<Layout> {
    require_descendant(Path::new(UPDATE_ROOT), &evidence)?;
    require_directory(&evidence, 0o700)?;
    let install_hold_name = read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?;
    let install_hold_root = PathBuf::from(install_hold_name.trim_end());
    let install_hold = install_hold_root.join("opensteamer Host.app");
    require_install_hold_layout(&install_hold_root, &install_hold)?;
    let stage_output = evidence.join("staged-output");
    Ok(Layout {
        repo,
        source_tar: evidence.join("source.tar"),
        source_export: evidence.join("source-export"),
        staged_app: stage_output.join("opensteamer Host.app"),
        stage_output,
        scratch: evidence.join("swiftpm-scratch"),
        rollback_dir: evidence.join("rollback-v20"),
        rollback_app: evidence.join("rollback-v20/opensteamer Host.app"),
        failed_dir: evidence.join("failed-new"),
        failed_app: evidence.join("failed-new/opensteamer Host.app"),
        rollback_reserve: evidence.join("rollback-reserve.bin"),
        install_hold_root,
        install_hold,
        journal: evidence.join("journal.log"),
        result: evidence.join("result.txt"),
        evidence,
    })
}

fn export_source(layout: &Layout, provenance: &Provenance) -> Result<()> {
    require_path_absent(&layout.source_tar, "source archive")?;
    require_path_absent(&layout.source_export, "source export")?;
    create_private_directory(&layout.source_export)?;
    let archive = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&layout.source_tar)?;
    let status = Command::new("/usr/bin/git")
        .args(["archive", "--format=tar", &provenance.commit])
        .current_dir(&layout.repo)
        .stdout(Stdio::from(archive))
        .stderr(Stdio::piped())
        .status()?;
    require_success(status, "git archive")?;
    require_regular(&layout.source_tar, 0o600)?;
    let output = command_output(
        "/usr/bin/tar",
        &[
            "-xf",
            path_text(&layout.source_tar)?,
            "-C",
            path_text(&layout.source_export)?,
        ],
        None,
    )?;
    require_output_success(&output, "extract source archive")?;
    require_regular(
        &layout
            .source_export
            .join("macOS/scripts/build-opensteamer-host-app.sh"),
        0o755,
    )?;
    let mut record = create_new_private(&layout.evidence.join("provenance.txt"))?;
    writeln!(record, "commit={}", provenance.commit)?;
    writeln!(record, "tree={}", provenance.tree)?;
    writeln!(record, "upstream={}", provenance.upstream)?;
    writeln!(record, "remote={}", provenance.remote)?;
    writeln!(
        record,
        "source_archive_sha256={}",
        sha256(&layout.source_tar)?
    )?;
    record.sync_all()?;
    Ok(())
}

fn build_and_verify_staged_app(layout: &Layout) -> Result<()> {
    require_path_absent(&layout.stage_output, "staged output")?;
    require_path_absent(&layout.scratch, "SwiftPM scratch")?;
    let stdout = create_new_private(&layout.evidence.join("build.stdout"))?;
    let stderr = create_new_private(&layout.evidence.join("build.stderr"))?;
    let build_script = layout
        .source_export
        .join("macOS/scripts/build-opensteamer-host-app.sh");
    let status = Command::new(&build_script)
        .current_dir(&layout.source_export)
        .env_clear()
        .env("HOME", USER_HOME)
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
        .env("OPENSTEAMER_HOST_APP_OUTPUT_DIR", &layout.stage_output)
        .env("OPENSTEAMER_HOST_SCRATCH_PATH", &layout.scratch)
        .env("OPENSTEAMER_REQUIRE_FRESH_RELEASE", "1")
        .env("OPENSTEAMER_EXPECTED_TEAM_ID", EXPECTED_TEAM_ID)
        .env(
            "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1",
            EXPECTED_SIGNING_IDENTITY_SHA1,
        )
        .env(
            "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE",
            OFFLINE_LEGACY_REFERENCE,
        )
        .env("OPENSTEAMER_EXPECTED_ARCHITECTURES", "arm64")
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .status()?;
    require_success(status, "fresh signed host build")?;
    verify_staged_app_contract(&layout.source_export, &layout.staged_app)
}

fn verify_reviewed_prebuilt_source(repo: &Path, app: &Path) -> Result<()> {
    if app != Path::new(REVIEWED_PREBUILT_APP) {
        return Err(ControllerError(
            "prebuilt source escaped the exact reviewed path".to_owned(),
        ));
    }
    verify_staged_app_contract(repo, app)?;
    let executable = app.join("Contents/MacOS/CaptureServer");
    if sha256(&executable)? != REVIEWED_PREBUILT_EXECUTABLE_SHA256 {
        return Err(ControllerError(
            "reviewed prebuilt executable hash changed".to_owned(),
        ));
    }
    Ok(())
}

fn import_and_verify_prebuilt(layout: &Layout, source: &Path) -> Result<()> {
    verify_reviewed_prebuilt_source(&layout.source_export, source)?;
    require_path_absent(&layout.stage_output, "staged output")?;
    create_private_directory(&layout.stage_output)?;
    let output = command_output(
        "/usr/bin/ditto",
        &[
            "--noqtn",
            path_text(source)?,
            path_text(&layout.staged_app)?,
        ],
        None,
    )?;
    require_output_success(&output, "copy reviewed prebuilt app into evidence")?;
    require_tree_equal(source, &layout.staged_app)?;
    verify_staged_app_contract(&layout.source_export, &layout.staged_app)?;
    if sha256(&layout.staged_app.join("Contents/MacOS/CaptureServer"))?
        != REVIEWED_PREBUILT_EXECUTABLE_SHA256
    {
        return Err(ControllerError(
            "evidence copy of reviewed prebuilt executable changed".to_owned(),
        ));
    }
    Ok(())
}

fn verify_staged_app_contract(repo: &Path, staged_app: &Path) -> Result<()> {
    verify_bundle(repo, staged_app, false)?;

    let staged_executable = staged_app.join("Contents/MacOS/CaptureServer");
    let staged_hash = sha256(&staged_executable)?;
    if staged_hash == V20_EXECUTABLE_SHA256 {
        return Err(ControllerError(
            "staged executable is byte-identical to v20 and lacks the reviewed update".to_owned(),
        ));
    }
    let strings = command_output("/usr/bin/strings", &[path_text(&staged_executable)?], None)?;
    require_output_success(&strings, "inspect staged pairing namespace")?;
    let text = decode_utf8(&strings.stdout, "strings output")?;
    let isolated_count = text
        .lines()
        .filter(|line| *line == ISOLATED_PAIRING_SERVICE)
        .count();
    let protected_count = text
        .lines()
        .filter(|line| *line == PROTECTED_PAIRING_SERVICE)
        .count();
    if isolated_count != 1 || protected_count != 0 {
        return Err(ControllerError(format!(
            "staged pairing namespace is not isolated: isolated_count={isolated_count} protected_count={protected_count}"
        )));
    }
    let architectures = command_line(
        "/usr/bin/lipo",
        &["-archs", path_text(&staged_executable)?],
        None,
    )?;
    if architectures != "arm64" {
        return Err(ControllerError(format!(
            "staged host architecture differs from exact arm64: {architectures}"
        )));
    }
    Ok(())
}

fn prepare_install_hold(layout: &Layout) -> Result<()> {
    require_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
    require_path_absent(&layout.install_hold_root, "hidden install-hold root")?;
    create_private_directory(&layout.install_hold_root)?;
    let output = command_output(
        "/usr/bin/ditto",
        &[
            "--noqtn",
            path_text(&layout.staged_app)?,
            path_text(&layout.install_hold)?,
        ],
        None,
    )?;
    require_output_success(&output, "copy staged app to hidden install hold")?;
    verify_bundle(&layout.source_export, &layout.install_hold, false)?;
    require_tree_equal(&layout.staged_app, &layout.install_hold)?;
    Ok(())
}

fn record_install_hold_name(layout: &Layout) -> Result<()> {
    require_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
    let mut record = create_new_private(&layout.evidence.join("install-hold-name.txt"))?;
    writeln!(record, "{}", layout.install_hold_root.display())?;
    record.sync_all()?;
    fsync_parent(&layout.evidence.join("install-hold-name.txt"))
}

fn verify_installed_matches_stage(layout: &Layout) -> Result<()> {
    verify_bundle(&layout.source_export, Path::new(NEW_APP), true)?;
    require_tree_equal(&layout.staged_app, Path::new(NEW_APP))?;
    verify_legacy_sources()?;
    require_legacy_disabled_and_absent()?;
    Ok(())
}

fn verify_bundle(repo: &Path, app: &Path, installed: bool) -> Result<()> {
    let verifier = repo.join("macOS/scripts/verify-mac-host-bundle.sh");
    require_regular(&verifier, 0o755)?;
    let mut arguments = Vec::new();
    if installed {
        arguments.push("--installed-runtime".to_owned());
    }
    arguments.push(path_text(app)?.to_owned());
    arguments.push(EXPECTED_TEAM_ID.to_owned());
    arguments.push(OFFLINE_LEGACY_REFERENCE.to_owned());
    let references: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let output = command_output(path_text(&verifier)?, &references, Some(repo))?;
    require_output_success(&output, "verify signed host bundle")
}

fn verify_live_process(repo: &Path, pid: u32, staged_app: &Path) -> Result<()> {
    let verifier = repo.join("macOS/scripts/verify-live-mac-host-process.sh");
    require_regular(&verifier, 0o755)?;
    let staged_executable = staged_app.join("Contents/MacOS/CaptureServer");
    let staged_framework =
        staged_app.join("Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC");
    let cdhash = code_hash(&staged_executable)?;
    let output = command_output(
        path_text(&verifier)?,
        &[
            &pid.to_string(),
            path_text(&staged_executable)?,
            &cdhash,
            EXPECTED_IDENTIFIER,
            EXPECTED_TEAM_ID,
            path_text(&staged_framework)?,
        ],
        Some(repo),
    )?;
    require_output_success(&output, "verify interactive host mapped code")
}

fn verify_deployment(
    repo: &Path,
    staged_app: &Path,
    checkpoint: &LogCheckpoint,
    generation: &LaunchGeneration,
) -> Result<()> {
    let verifier = repo.join("macOS/scripts/verify-mac-host-deployment.sh");
    require_regular(&verifier, 0o755)?;
    let current_binary = env::current_exe()?.canonicalize()?;
    let output = Command::new(&verifier)
        .current_dir(repo)
        .env_clear()
        .env("HOME", USER_HOME)
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("UID", USER_ID.to_string())
        .env("OPENSTEAMER_MIGRATION_CONTROLLER_BINARY", &current_binary)
        .args([
            path_text(staged_app)?,
            OFFLINE_LEGACY_REFERENCE,
            path_text(&repo.join("macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"))?,
            &checkpoint.offset.to_string(),
            &checkpoint.device.to_string(),
            &checkpoint.inode.to_string(),
            &generation.pid.to_string(),
            &generation.runs.to_string(),
            &generation.process_start,
            &generation.nonce,
            &generation.lock_device.to_string(),
            &generation.lock_inode.to_string(),
        ])
        .output()?;
    require_output_success(&output, "generation-bound deployment verification")
}

fn verify_machine_contract() -> Result<()> {
    if unsafe { libc_geteuid() } != USER_ID {
        return Err(ControllerError(format!(
            "controller must run as uid {USER_ID} without sudo"
        )));
    }
    require_directory(Path::new("/Applications"), 0o775)?;
    let applications = fs::metadata("/Applications")?;
    if applications.uid() != 0 || applications.gid() != 80 {
        return Err(ControllerError(
            "canonical /Applications ownership differs from root:admin".to_owned(),
        ));
    }
    require_directory(Path::new(PRIVATE_ROOT), 0o700)?;
    require_regular(Path::new(NEW_PLIST), 0o600)?;
    Ok(())
}

unsafe fn libc_geteuid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    // SAFETY: `geteuid` takes no arguments and has no memory preconditions.
    unsafe { geteuid() }
}

fn verify_pristine_v20_evidence() -> Result<()> {
    require_regular(Path::new(V20_ACTIVE_POINTER), 0o600)?;
    if sha256(Path::new(V20_ACTIVE_POINTER))? != V20_ACTIVE_POINTER_SHA256 {
        return Err(ControllerError(
            "v20 active pointer hash changed".to_owned(),
        ));
    }
    let pointer = read_bounded_utf8(Path::new(V20_ACTIVE_POINTER), 512)?;
    if pointer != format!("{V20_EVIDENCE}\n") {
        return Err(ControllerError(
            "v20 active pointer bytes changed".to_owned(),
        ));
    }
    let evidence = Path::new(V20_EVIDENCE);
    require_directory(evidence, 0o700)?;
    for (relative, expected) in [
        ("journal.log", V20_JOURNAL_SHA256),
        ("records/result.txt", V20_RESULT_SHA256),
        ("records/provenance.txt", V20_PROVENANCE_SHA256),
        ("records/staged-hashes.txt", V20_STAGED_HASHES_SHA256),
    ] {
        let path = evidence.join(relative);
        require_regular(&path, 0o600)?;
        if sha256(&path)? != expected {
            return Err(ControllerError(format!(
                "v20 evidence changed: {}",
                path.display()
            )));
        }
    }
    require_directory(Path::new(V20_STAGED_APP), 0o755)?;
    require_regular(Path::new(OFFLINE_LEGACY_REFERENCE), 0o755)?;
    if sha256(Path::new(OFFLINE_LEGACY_REFERENCE))? != LEGACY_EXECUTABLE_SHA256 {
        return Err(ControllerError(
            "v20 offline legacy reference hash changed".to_owned(),
        ));
    }
    Ok(())
}

fn verify_v20_runtime() -> Result<LaunchGeneration> {
    verify_legacy_sources()?;
    require_legacy_disabled_and_absent()?;
    verify_exact_v20_app_at(Path::new(NEW_APP))?;
    if sha256(Path::new(NEW_PLIST))? != NEW_PLIST_SHA256 {
        return Err(ControllerError(
            "new LaunchAgent plist bytes changed".to_owned(),
        ));
    }
    let launch = read_loaded_launch_state()?;
    require_solo_capture_server(Path::new(NEW_EXECUTABLE), launch.pid)?;
    let (lock_device, lock_inode, nonce) = read_generation_lock(launch.pid)?;
    prove_lock_holder(launch.pid, Duration::from_secs(4))?;
    let initial_process_start = process_start(launch.pid)?;
    let generation = LaunchGeneration {
        pid: launch.pid,
        runs: launch.runs,
        process_start: initial_process_start,
        nonce,
        lock_device,
        lock_inode,
    };
    thread::sleep(Duration::from_millis(500));
    let second = read_loaded_launch_state()?;
    if second.pid != generation.pid || second.runs != generation.runs {
        return Err(ControllerError(
            "v20 launch generation changed during preflight".to_owned(),
        ));
    }
    let (_, _, second_nonce) = read_generation_lock(generation.pid)?;
    if second_nonce != generation.nonce
        || process_start(generation.pid)? != generation.process_start
    {
        return Err(ControllerError(
            "v20 process generation changed during preflight".to_owned(),
        ));
    }
    prove_lock_holder(generation.pid, Duration::from_secs(4))?;
    Ok(generation)
}

fn verify_exact_v20_app_at(app: &Path) -> Result<()> {
    require_directory(app, 0o755)?;
    let executable = app.join("Contents/MacOS/CaptureServer");
    require_regular(&executable, 0o755)?;
    if sha256(&executable)? != V20_EXECUTABLE_SHA256 {
        return Err(ControllerError(format!(
            "v20 executable bytes changed at {}",
            executable.display()
        )));
    }
    if code_hash(app)? != V20_APP_CDHASH {
        return Err(ControllerError(format!(
            "v20 app CDHash changed at {}",
            app.display()
        )));
    }
    require_code_identity(app)?;
    require_tree_equal(Path::new(V20_STAGED_APP), app)
}

fn verify_legacy_sources() -> Result<()> {
    require_directory(Path::new(LEGACY_APP), 0o755)?;
    require_regular(Path::new(LEGACY_EXECUTABLE), 0o755)?;
    require_regular(Path::new(LEGACY_PLIST), 0o600)?;
    if sha256(Path::new(LEGACY_EXECUTABLE))? != LEGACY_EXECUTABLE_SHA256 {
        return Err(ControllerError(
            "protected legacy executable bytes changed".to_owned(),
        ));
    }
    if sha256(Path::new(LEGACY_PLIST))? != LEGACY_PLIST_SHA256 {
        return Err(ControllerError(
            "protected legacy LaunchAgent plist bytes changed".to_owned(),
        ));
    }
    Ok(())
}

fn require_code_identity(path: &Path) -> Result<()> {
    let verify = command_output(
        "/usr/bin/codesign",
        &[
            "--verify",
            "--deep",
            "--strict",
            "--verbose=2",
            path_text(path)?,
        ],
        None,
    )?;
    require_output_success(&verify, "verify code signature")?;
    let metadata = code_metadata(path)?;
    if metadata.identifier.as_deref() != Some(EXPECTED_IDENTIFIER)
        || metadata.team.as_deref() != Some(EXPECTED_TEAM_ID)
    {
        return Err(ControllerError(format!(
            "code identity mismatch for {}",
            path.display()
        )));
    }
    Ok(())
}

struct CodeMetadata {
    identifier: Option<String>,
    team: Option<String>,
    cdhash: Option<String>,
}

fn code_metadata(path: &Path) -> Result<CodeMetadata> {
    let output = command_output(
        "/usr/bin/codesign",
        &["-dv", "--verbose=4", path_text(path)?],
        None,
    )?;
    if !output.status.success() {
        return Err(command_failure("read code-signature metadata", &output));
    }
    let text = decode_utf8(&output.stderr, "codesign metadata")?;
    let mut identifier = None;
    let mut team = None;
    let mut cdhash = None;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("Identifier=") {
            set_once(&mut identifier, value, "Identifier")?;
        } else if let Some(value) = line.strip_prefix("TeamIdentifier=") {
            set_once(&mut team, value, "TeamIdentifier")?;
        } else if let Some(value) = line.strip_prefix("CDHash=") {
            set_once(&mut cdhash, &value.to_ascii_lowercase(), "CDHash")?;
        }
    }
    Ok(CodeMetadata {
        identifier,
        team,
        cdhash,
    })
}

fn code_hash(path: &Path) -> Result<String> {
    let metadata = code_metadata(path)?;
    let value = metadata
        .cdhash
        .ok_or_else(|| ControllerError("codesign metadata has no CDHash".to_owned()))?;
    if value.len() != 40 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ControllerError("codesign CDHash is malformed".to_owned()));
    }
    Ok(value)
}

fn set_once(slot: &mut Option<String>, value: &str, name: &str) -> Result<()> {
    if slot.is_some() || value.is_empty() {
        return Err(ControllerError(format!(
            "codesign metadata has malformed or duplicate {name}"
        )));
    }
    *slot = Some(value.to_owned());
    Ok(())
}

fn verify_git_provenance(repo: &Path, require_remote: bool) -> Result<Provenance> {
    let status = command_output(
        "/usr/bin/git",
        &["status", "--porcelain=v1", "--untracked-files=all"],
        Some(repo),
    )?;
    require_output_success(&status, "inspect git worktree")?;
    if !status.stdout.is_empty() {
        return Err(ControllerError(
            "repository must be completely clean before a host update".to_owned(),
        ));
    }
    let commit = command_line("/usr/bin/git", &["rev-parse", "HEAD"], Some(repo))?;
    let tree = command_line("/usr/bin/git", &["rev-parse", "HEAD^{tree}"], Some(repo))?;
    let upstream = command_line(
        "/usr/bin/git",
        &["rev-parse", "--abbrev-ref", "@{u}"],
        Some(repo),
    )?;
    let upstream_commit = command_line("/usr/bin/git", &["rev-parse", "@{u}"], Some(repo))?;
    if upstream_commit != commit {
        return Err(ControllerError(
            "local HEAD differs from its configured upstream".to_owned(),
        ));
    }
    let remote = command_line(
        "/usr/bin/git",
        &["config", "--get", "remote.origin.url"],
        Some(repo),
    )?;
    if require_remote {
        let branch = upstream
            .strip_prefix("origin/")
            .ok_or_else(|| ControllerError("upstream is not an origin branch".to_owned()))?;
        let output = command_output(
            "/usr/bin/git",
            &[
                "ls-remote",
                "--heads",
                "origin",
                &format!("refs/heads/{branch}"),
            ],
            Some(repo),
        )?;
        require_output_success(&output, "verify pushed source commit")?;
        let text = decode_utf8(&output.stdout, "git ls-remote output")?;
        let mut records = text.lines();
        let record = records
            .next()
            .ok_or_else(|| ControllerError("upstream branch is absent on origin".to_owned()))?;
        if records.next().is_some() {
            return Err(ControllerError(
                "git ls-remote returned multiple upstream records".to_owned(),
            ));
        }
        let mut fields = record.split('\t');
        let remote_commit = fields.next().unwrap_or_default();
        let remote_ref = fields.next().unwrap_or_default();
        if fields.next().is_some()
            || remote_commit != commit
            || remote_ref != format!("refs/heads/{branch}")
        {
            return Err(ControllerError(
                "origin branch does not resolve to the local HEAD".to_owned(),
            ));
        }
    }
    Ok(Provenance {
        commit,
        tree,
        upstream,
        remote,
    })
}

#[derive(Debug)]
struct LaunchState {
    pid: u32,
    runs: u64,
}

#[derive(Debug)]
struct LoadedLaunchJob {
    state: String,
    pid: Option<u32>,
    runs: Option<u64>,
}

fn read_loaded_launch_state() -> Result<LaunchState> {
    let output = command_output(
        "/bin/launchctl",
        &["print", &format!("gui/{USER_ID}/{NEW_LABEL}")],
        None,
    )?;
    require_output_success(&output, "read new LaunchAgent state")?;
    parse_launch_state(decode_utf8(&output.stdout, "launchctl state")?)
}

fn parse_launch_state(text: &str) -> Result<LaunchState> {
    let loaded = parse_loaded_launch_job(text)?;
    if loaded.state != "running" {
        return Err(ControllerError(
            "new LaunchAgent is not in the running state".to_owned(),
        ));
    }
    let runs = loaded
        .runs
        .ok_or_else(|| ControllerError("launch state has no run count".to_owned()))?;
    if runs == 0 {
        return Err(ControllerError(
            "running launch state has a zero run count".to_owned(),
        ));
    }
    Ok(LaunchState {
        pid: loaded
            .pid
            .ok_or_else(|| ControllerError("launch state has no PID".to_owned()))?,
        runs,
    })
}

fn parse_loaded_launch_job(text: &str) -> Result<LoadedLaunchJob> {
    let expected_first = format!("gui/{USER_ID}/{NEW_LABEL} = {{");
    let mut lines = text.lines();
    if lines.next() != Some(expected_first.as_str()) {
        return Err(ControllerError(
            "launchctl state header is malformed".to_owned(),
        ));
    }
    let mut depth = 1i32;
    let mut block = "";
    let mut path = None;
    let mut job_type = None;
    let mut state = None;
    let mut program = None;
    let mut pid = None;
    let mut runs = None;
    let mut arguments = Vec::new();
    for raw in lines {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if line == "}" {
            depth -= 1;
            if depth == 0 {
                block = "closed";
                continue;
            }
            if depth == 1 {
                block = "";
            }
            continue;
        }
        if block == "closed" {
            return Err(ControllerError(
                "launchctl state contains trailing records".to_owned(),
            ));
        }
        if line.ends_with(" = {") {
            if depth == 1 && line == "arguments = {" {
                block = "arguments";
            } else if depth == 1 {
                block = "other";
            }
            depth += 1;
            continue;
        }
        if depth == 1 {
            if let Some(value) = line.strip_prefix("path = ") {
                set_once(&mut path, value, "launch plist path")?;
            } else if let Some(value) = line.strip_prefix("type = ") {
                set_once(&mut job_type, value, "launch job type")?;
            } else if let Some(value) = line.strip_prefix("state = ") {
                set_once(&mut state, value, "launch state")?;
            } else if let Some(value) = line.strip_prefix("program = ") {
                set_once(&mut program, value, "launch program")?;
            } else if let Some(value) = line.strip_prefix("pid = ") {
                if pid
                    .replace(parse_positive_u32(value, "launch PID")?)
                    .is_some()
                {
                    return Err(ControllerError("duplicate launch PID".to_owned()));
                }
            } else if let Some(value) = line.strip_prefix("runs = ") {
                if runs.replace(parse_u64(value, "launch runs")?).is_some() {
                    return Err(ControllerError("duplicate launch runs".to_owned()));
                }
            }
        } else if depth == 2 && block == "arguments" {
            arguments.push(line.to_owned());
        }
    }
    if depth != 0
        || path.as_deref() != Some(NEW_PLIST)
        || job_type.as_deref() != Some("LaunchAgent")
        || program.as_deref() != Some(NEW_EXECUTABLE)
    {
        return Err(ControllerError(
            "loaded new LaunchAgent identity differs from the reviewed contract".to_owned(),
        ));
    }
    let state = state.ok_or_else(|| ControllerError("launch state is absent".to_owned()))?;
    if state.is_empty()
        || state.len() > 64
        || !state
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte == b' ' || byte == b'-')
    {
        return Err(ControllerError("launch state is malformed".to_owned()));
    }
    let mut expected_arguments = vec![NEW_EXECUTABLE.to_owned()];
    expected_arguments.extend(HOST_ARGUMENTS.iter().map(|value| (*value).to_owned()));
    if arguments != expected_arguments {
        return Err(ControllerError(
            "new LaunchAgent arguments differ from the reviewed contract".to_owned(),
        ));
    }
    Ok(LoadedLaunchJob { state, pid, runs })
}

fn require_legacy_disabled_and_absent() -> Result<()> {
    require_service_absent(LEGACY_LABEL)?;
    let output = command_output(
        "/bin/launchctl",
        &["print-disabled", &format!("gui/{USER_ID}")],
        None,
    )?;
    require_output_success(&output, "read legacy disabled override")?;
    let text = decode_utf8(&output.stdout, "launchctl disabled state")?;
    let expected = format!("\"{LEGACY_LABEL}\" => disabled");
    let matches = text.lines().filter(|line| line.trim() == expected).count();
    if matches != 1 {
        return Err(ControllerError(
            "legacy launchd label is not unambiguously disabled".to_owned(),
        ));
    }
    Ok(())
}

fn require_service_absent(label: &str) -> Result<()> {
    let output = command_output(
        "/bin/launchctl",
        &["print", &format!("gui/{USER_ID}/{label}")],
        None,
    )?;
    if output.status.success() {
        return Err(ControllerError(format!(
            "launchd service remains loaded: {label}"
        )));
    }
    let code = output.status.code();
    let stdout = decode_utf8(&output.stdout, "launchctl absence stdout")?;
    let stderr = decode_utf8(&output.stderr, "launchctl absence stderr")?;
    let expected = format!(
        "Bad request.\nCould not find service \"{label}\" in domain for user gui: {USER_ID}\n"
    );
    if code != Some(113) || !stdout.is_empty() || stderr != expected {
        return Err(ControllerError(format!(
            "launchctl did not prove service absence for {label}: status={code:?} diagnostic={stderr:?}"
        )));
    }
    Ok(())
}

fn bootout_exact_new_job() -> Result<()> {
    read_loaded_launch_state()?;
    let output = command_output(
        "/bin/launchctl",
        &["bootout", &format!("gui/{USER_ID}/{NEW_LABEL}")],
        None,
    )?;
    require_output_success(&output, "boot out exact new LaunchAgent")
}

fn bootout_new_job_if_loaded(layout: &Layout) -> Result<()> {
    let state = command_output(
        "/bin/launchctl",
        &["print", &format!("gui/{USER_ID}/{NEW_LABEL}")],
        None,
    )?;
    if state.status.success() {
        let loaded =
            parse_loaded_launch_job(decode_utf8(&state.stdout, "rollback launchctl state")?)?;
        let observed_process = if let Some(pid) = loaded.pid {
            require_solo_capture_server(Path::new(NEW_EXECUTABLE), pid)?;
            verify_live_process(&layout.source_export, pid, Path::new(NEW_APP))?;
            Some((pid, process_start(pid)?))
        } else {
            require_no_capture_servers()?;
            None
        };
        let output = command_output(
            "/bin/launchctl",
            &["bootout", &format!("gui/{USER_ID}/{NEW_LABEL}")],
            None,
        )?;
        require_output_success(&output, "boot out new LaunchAgent during rollback")?;
        require_service_absent(NEW_LABEL)?;
        if let Some((pid, start)) = observed_process {
            wait_for_observed_canonical_process_exit(pid, &start, Duration::from_secs(30))?;
        } else {
            require_no_capture_servers()?;
        }
    } else {
        require_service_absent(NEW_LABEL)?;
    }
    Ok(())
}

fn wait_for_observed_canonical_process_exit(
    pid: u32,
    expected_start: &str,
    timeout: Duration,
) -> Result<()> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let processes = capture_server_processes()?;
        if processes.is_empty() {
            return Ok(());
        }
        if processes.len() != 1
            || processes[0].0 != pid
            || processes[0].1 != Path::new(NEW_EXECUTABLE)
        {
            return Err(ControllerError(format!(
                "rollback observed an unexpected CaptureServer while canonical host was exiting: {processes:?}"
            )));
        }
        if process_start(pid)? != expected_start {
            return Err(ControllerError(
                "canonical host PID was reused while rollback waited for bootout".to_owned(),
            ));
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(ControllerError(format!(
        "canonical host PID {pid} did not exit within the bounded rollback bootout interval"
    )))
}

fn bootstrap_exact_new_job() -> Result<()> {
    require_service_absent(NEW_LABEL)?;
    require_legacy_disabled_and_absent()?;
    require_no_capture_servers()?;
    let lock = acquire_unowned_shared_lock()?;
    if sha256(Path::new(NEW_PLIST))? != NEW_PLIST_SHA256 {
        return Err(ControllerError(
            "installed new LaunchAgent plist changed before bootstrap".to_owned(),
        ));
    }
    drop(lock);
    let output = command_output(
        "/bin/launchctl",
        &["bootstrap", &format!("gui/{USER_ID}"), NEW_PLIST],
        None,
    )?;
    require_output_success(&output, "bootstrap exact new LaunchAgent")
}

fn spawn_interactive_host(layout: &Layout) -> Result<Child> {
    require_service_absent(NEW_LABEL)?;
    require_legacy_disabled_and_absent()?;
    require_no_capture_servers()?;
    let lock = acquire_unowned_shared_lock()?;
    verify_bundle(&layout.source_export, &layout.staged_app, false)?;
    let staged_executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
    drop(lock);
    let child = Command::new(&staged_executable)
        .args(HOST_ARGUMENTS)
        .arg("--reset-worldwide-pairing")
        .env_clear()
        .env("HOME", USER_HOME)
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("OSLogRateLimit", "64")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| ControllerError(format!("cannot start interactive host: {error}")))?;
    Ok(child)
}

fn terminate_child(child: &mut Child) -> Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    let pid = i32::try_from(child.id())
        .map_err(|_| ControllerError("interactive host PID overflow".to_owned()))?;
    // SAFETY: signal delivery targets only the exact child PID returned by spawn.
    if unsafe { kill(pid, SIGTERM) } != 0 {
        return Err(ControllerError(format!(
            "cannot terminate interactive host: {}",
            std::io::Error::last_os_error()
        )));
    }
    let deadline = Instant::now() + Duration::from_secs(12);
    while Instant::now() < deadline {
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    // SAFETY: the exact child is still alive after a bounded graceful-shutdown interval.
    if unsafe { kill(pid, SIGKILL) } != 0 {
        return Err(ControllerError(format!(
            "cannot kill unresponsive interactive host: {}",
            std::io::Error::last_os_error()
        )));
    }
    child.wait()?;
    Ok(())
}

fn terminate_staged_host_if_present(layout: &Layout) -> Result<()> {
    let processes = capture_server_processes()?;
    if processes.is_empty() {
        return Ok(());
    }
    let staged_executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
    if processes.len() != 1 || processes[0].1 != staged_executable {
        return Err(ControllerError(format!(
            "rollback found an unexpected CaptureServer process set: {processes:?}"
        )));
    }
    let pid = processes[0].0;
    verify_live_process(&layout.source_export, pid, &layout.staged_app)?;
    let expected_start = process_start(pid)?;
    if !exact_staged_process_is_present(layout, pid, &expected_start)? {
        return Ok(());
    }
    let raw_pid =
        i32::try_from(pid).map_err(|_| ControllerError("staged host PID overflowed".to_owned()))?;
    // SAFETY: PID, process start, and mapped executable were just verified against the retained
    // signed stage.
    if unsafe { kill(raw_pid, SIGTERM) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(3)
            && !exact_staged_process_is_present(layout, pid, &expected_start)?
        {
            return Ok(());
        }
        return Err(ControllerError(format!(
            "could not terminate retained staged host: {error}"
        )));
    }
    let deadline = Instant::now() + Duration::from_secs(12);
    while Instant::now() < deadline {
        if !exact_staged_process_is_present(layout, pid, &expected_start)? {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    if !exact_staged_process_is_present(layout, pid, &expected_start)? {
        return Ok(());
    }
    // SAFETY: the exact sole staged PID/path/start generation was re-proven immediately before
    // this bounded escalation.
    if unsafe { kill(raw_pid, SIGKILL) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(3)
            && !exact_staged_process_is_present(layout, pid, &expected_start)?
        {
            return Ok(());
        }
        return Err(ControllerError(format!(
            "could not kill retained staged host: {error}"
        )));
    }
    let kill_deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < kill_deadline {
        if !exact_staged_process_is_present(layout, pid, &expected_start)? {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(ControllerError(
        "exact retained staged host survived bounded SIGKILL wait".to_owned(),
    ))
}

fn exact_staged_process_is_present(
    layout: &Layout,
    expected_pid: u32,
    expected_start: &str,
) -> Result<bool> {
    let processes = capture_server_processes()?;
    let staged_executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
    if !validate_exact_staged_process_sample(&processes, expected_pid, &staged_executable)? {
        return Ok(false);
    }
    match process_start(expected_pid) {
        Ok(observed) if observed == expected_start => Ok(true),
        Ok(_) => Err(ControllerError(
            "staged host PID was reused during rollback termination".to_owned(),
        )),
        Err(error) => {
            let after = capture_server_processes()?;
            if after.is_empty() {
                Ok(false)
            } else {
                Err(ControllerError(format!(
                    "could not revalidate staged host process start during rollback: {error}; processes={after:?}"
                )))
            }
        }
    }
}

fn validate_exact_staged_process_sample(
    processes: &[(u32, PathBuf)],
    expected_pid: u32,
    expected_executable: &Path,
) -> Result<bool> {
    if processes.is_empty() {
        return Ok(false);
    }
    if processes.len() != 1
        || processes[0].0 != expected_pid
        || processes[0].1 != expected_executable
    {
        return Err(ControllerError(format!(
            "staged host topology changed during rollback termination: {processes:?}"
        )));
    }
    Ok(true)
}

fn capture_log_checkpoint() -> Result<LogCheckpoint> {
    require_regular(Path::new(ONLINE_LOG), 0o600)?;
    let metadata = fs::metadata(ONLINE_LOG)?;
    if metadata.nlink() != 1 || metadata.uid() != USER_ID {
        return Err(ControllerError(
            "persistent host log has unsafe ownership or link count".to_owned(),
        ));
    }
    Ok(LogCheckpoint {
        offset: metadata.len(),
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn wait_for_launch_generation(timeout: Duration) -> Result<LaunchGeneration> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    while Instant::now() < deadline {
        match read_loaded_launch_state().and_then(|launch| {
            require_solo_capture_server(Path::new(NEW_EXECUTABLE), launch.pid)?;
            let (lock_device, lock_inode, nonce) = read_generation_lock(launch.pid)?;
            prove_lock_holder(launch.pid, Duration::from_secs(2))?;
            Ok(LaunchGeneration {
                pid: launch.pid,
                runs: launch.runs,
                process_start: process_start(launch.pid)?,
                nonce,
                lock_device,
                lock_inode,
            })
        }) {
            Ok(generation) => return Ok(generation),
            Err(error) => last_error = Some(error),
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err(ControllerError(format!(
        "new LaunchAgent did not reach a valid generation: {}",
        last_error
            .map(|error| error.to_string())
            .unwrap_or_else(|| "no observation".to_owned())
    )))
}

fn process_start(pid: u32) -> Result<String> {
    let output = command_output("/bin/ps", &["-p", &pid.to_string(), "-o", "lstart="], None)?;
    require_output_success(&output, "read process start identity")?;
    let text = decode_utf8(&output.stdout, "process start identity")?;
    let records: Vec<&str> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    if records.len() != 1 {
        return Err(ControllerError(
            "process start identity is missing or ambiguous".to_owned(),
        ));
    }
    let value = records[0].trim().to_owned();
    if value.len() < 20 || value.contains('\n') || value.contains('\r') {
        return Err(ControllerError(
            "process start identity is malformed".to_owned(),
        ));
    }
    Ok(value)
}

fn read_generation_lock(expected_pid: u32) -> Result<(u64, u64, String)> {
    require_directory(Path::new(LOCK_DIRECTORY), 0o700)?;
    require_regular(Path::new(LOCK_FILE), 0o600)?;
    let before = fs::metadata(LOCK_FILE)?;
    if before.nlink() != 1 || before.uid() != USER_ID || before.len() > 512 {
        return Err(ControllerError(
            "shared generation lock metadata is unsafe".to_owned(),
        ));
    }
    let text = read_bounded_utf8(Path::new(LOCK_FILE), 512)?;
    let after = fs::metadata(LOCK_FILE)?;
    if before.dev() != after.dev() || before.ino() != after.ino() {
        return Err(ControllerError(
            "shared generation lock changed while being read".to_owned(),
        ));
    }
    let mut lines = text.lines();
    if lines.next() != Some("OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1") {
        return Err(ControllerError(
            "shared generation record header is malformed".to_owned(),
        ));
    }
    let pid = lines
        .next()
        .and_then(|line| line.strip_prefix("pid="))
        .ok_or_else(|| ControllerError("generation record has no PID".to_owned()))?;
    let nonce = lines
        .next()
        .and_then(|line| line.strip_prefix("nonce="))
        .ok_or_else(|| ControllerError("generation record has no nonce".to_owned()))?;
    if lines.next().is_some()
        || parse_positive_u32(pid, "generation PID")? != expected_pid
        || nonce.len() != 64
        || !nonce
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(ControllerError(
            "shared generation record is malformed or belongs to another PID".to_owned(),
        ));
    }
    Ok((before.dev(), before.ino(), nonce.to_owned()))
}

fn acquire_unowned_shared_lock() -> Result<LockGuard> {
    require_directory(Path::new(LOCK_DIRECTORY), 0o700)?;
    require_regular(Path::new(LOCK_FILE), 0o600)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(0x0000_0100 | 0x0100_0000)
        .open(LOCK_FILE)?;
    // SAFETY: `file` owns the descriptor; flock does not dereference userspace pointers.
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(ControllerError(format!(
            "canonical shared lock is still owned: {}",
            std::io::Error::last_os_error()
        )));
    }
    let descriptor = file.metadata()?;
    let entry = fs::metadata(LOCK_FILE)?;
    if descriptor.dev() != entry.dev()
        || descriptor.ino() != entry.ino()
        || entry.nlink() != 1
        || entry.uid() != USER_ID
        || entry.permissions().mode() & 0o777 != 0o600
    {
        return Err(ControllerError(
            "canonical shared lock changed while being acquired".to_owned(),
        ));
    }
    Ok(LockGuard { file })
}

fn acquire_update_transaction_lock() -> Result<UpdateTransactionLock> {
    acquire_update_transaction_lock_at(Path::new(UPDATE_LOCK))
}

fn acquire_update_transaction_lock_at(lock_path: &Path) -> Result<UpdateTransactionLock> {
    let parent = lock_path
        .parent()
        .ok_or_else(|| ControllerError("post-v20 update lock has no parent".to_owned()))?;
    require_directory(parent, 0o700)?;
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW | 0x0100_0000)
        .open(lock_path)
    {
        Ok(file) => {
            file.sync_all()?;
            fsync_parent(lock_path)?;
            file
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(O_NOFOLLOW | 0x0100_0000)
            .open(lock_path)?,
        Err(error) => {
            return Err(ControllerError(format!(
                "cannot create post-v20 update lock: {error}"
            )))
        }
    };
    let descriptor = file.metadata()?;
    let entry = fs::symlink_metadata(lock_path)?;
    if !descriptor.file_type().is_file()
        || !entry.file_type().is_file()
        || entry.file_type().is_symlink()
        || descriptor.dev() != entry.dev()
        || descriptor.ino() != entry.ino()
        || descriptor.nlink() != 1
        || entry.nlink() != 1
        || descriptor.uid() != USER_ID
        || entry.uid() != USER_ID
        || descriptor.permissions().mode() & 0o777 != 0o600
        || entry.permissions().mode() & 0o777 != 0o600
    {
        return Err(ControllerError(
            "post-v20 update lock has unsafe metadata".to_owned(),
        ));
    }
    // SAFETY: `file` owns the descriptor; flock does not dereference userspace pointers.
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(ControllerError(format!(
            "another post-v20 update or rollback is already running: {}",
            std::io::Error::last_os_error()
        )));
    }
    let locked_entry = fs::symlink_metadata(lock_path)?;
    if !locked_entry.file_type().is_file()
        || locked_entry.file_type().is_symlink()
        || descriptor.dev() != locked_entry.dev()
        || descriptor.ino() != locked_entry.ino()
        || locked_entry.nlink() != 1
        || locked_entry.uid() != USER_ID
        || locked_entry.permissions().mode() & 0o777 != 0o600
    {
        return Err(ControllerError(
            "post-v20 update lock changed while being acquired".to_owned(),
        ));
    }
    Ok(UpdateTransactionLock { file })
}

fn prove_lock_holder(expected_pid: u32, timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    let mut last = "no sample".to_owned();
    while Instant::now() < deadline {
        match sample_lock_holder(expected_pid) {
            Ok(()) => return Ok(()),
            Err(error) => last = error.to_string(),
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(ControllerError(format!(
        "could not prove sole shared-lock ownership by PID {expected_pid}: {last}"
    )))
}

fn sample_lock_holder(expected_pid: u32) -> Result<()> {
    let output = command_output("/usr/sbin/lsof", &["-n", "-Fpcufa", "--", LOCK_FILE], None)?;
    require_output_success(&output, "attribute shared lock openers")?;
    let text = decode_utf8(&output.stdout, "lsof lock output")?;
    let mut current_pid = None;
    let mut current_fd = false;
    let mut write_capable = Vec::new();
    let mut read_only_extra = false;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix('p') {
            current_pid = Some(parse_positive_u32(value, "lsof PID")?);
            current_fd = false;
        } else if line.starts_with('f') {
            if current_pid.is_none() {
                return Err(ControllerError("lsof FD preceded its PID".to_owned()));
            }
            current_fd = true;
        } else if let Some(access) = line.strip_prefix('a') {
            let pid = current_pid
                .ok_or_else(|| ControllerError("lsof access preceded its PID".to_owned()))?;
            if !current_fd || !matches!(access, "r" | "w" | "u") {
                return Err(ControllerError(
                    "lsof access record is malformed".to_owned(),
                ));
            }
            if access == "r" {
                if pid != expected_pid {
                    read_only_extra = true;
                }
            } else {
                write_capable.push(pid);
            }
            current_fd = false;
        }
    }
    write_capable.sort_unstable();
    write_capable.dedup();
    if write_capable != [expected_pid] || read_only_extra {
        return Err(ControllerError(format!(
            "lock opener topology is transient or unexpected: write={write_capable:?} read_only_extra={read_only_extra}"
        )));
    }
    let file = OpenOptions::new().read(true).write(true).open(LOCK_FILE)?;
    // SAFETY: `file` owns the descriptor; a successful acquisition would be released below.
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        unsafe {
            flock(file.as_raw_fd(), LOCK_UN);
        }
        return Err(ControllerError(
            "shared lock was acquirable despite attributed owner".to_owned(),
        ));
    }
    let raw = std::io::Error::last_os_error().raw_os_error();
    if raw != Some(11) && raw != Some(35) {
        return Err(ControllerError(format!(
            "shared lock contention probe failed operationally: {:?}",
            std::io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn require_solo_capture_server(expected: &Path, expected_pid: u32) -> Result<()> {
    let processes = capture_server_processes()?;
    if processes.len() != 1 || processes[0].0 != expected_pid || processes[0].1 != expected {
        return Err(ControllerError(format!(
            "CaptureServer process set differs from sole expected PID {expected_pid}: {processes:?}"
        )));
    }
    Ok(())
}

fn require_no_capture_servers() -> Result<()> {
    let processes = capture_server_processes()?;
    if !processes.is_empty() {
        return Err(ControllerError(format!(
            "CaptureServer processes remain: {processes:?}"
        )));
    }
    Ok(())
}

fn wait_for_no_capture_servers(timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    let mut last = Vec::new();
    while Instant::now() < deadline {
        last = capture_server_processes()?;
        if last.is_empty() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(ControllerError(format!(
        "CaptureServer processes did not stop: {last:?}"
    )))
}

fn capture_server_processes() -> Result<Vec<(u32, PathBuf)>> {
    let output = command_output("/bin/ps", &["-ww", "-axo", "pid=,comm="], None)?;
    require_output_success(&output, "enumerate processes")?;
    let text = decode_utf8(&output.stdout, "ps process output")?;
    let mut found = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            continue;
        }
        let split = trimmed
            .find(char::is_whitespace)
            .ok_or_else(|| ControllerError("ps process record is malformed".to_owned()))?;
        let pid = parse_positive_u32(&trimmed[..split], "process PID")?;
        let command = trimmed[split..].trim_start();
        if command.ends_with("/CaptureServer") {
            found.push((pid, PathBuf::from(command)));
        }
    }
    Ok(found)
}

fn archive_install_hold_if_present(layout: &Layout) -> Result<()> {
    if !layout.install_hold_root.exists() {
        return Ok(());
    }
    require_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
    require_directory(&layout.install_hold_root, 0o700)?;
    let destination = layout.failed_dir.join("unpublished-install-hold");
    require_path_absent(&destination, "unpublished install-hold archive")?;
    rename_exclusive(&layout.install_hold_root, &destination)?;
    fsync_parent(&layout.install_hold_root)?;
    fsync_parent(&destination)
}

fn rename_exclusive(source: &Path, destination: &Path) -> Result<()> {
    if !source.exists() {
        return Err(ControllerError(format!(
            "rename source is absent: {}",
            source.display()
        )));
    }
    require_path_absent(destination, "exclusive rename destination")?;
    let old = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| ControllerError("rename source contains NUL".to_owned()))?;
    let new = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| ControllerError("rename destination contains NUL".to_owned()))?;
    // SAFETY: both C strings are live and NUL-terminated; AT_FDCWD addresses canonical absolute
    // paths, and RENAME_EXCL prevents replacement of any raced destination.
    let result =
        unsafe { renameatx_np(AT_FDCWD, old.as_ptr(), AT_FDCWD, new.as_ptr(), RENAME_EXCL) };
    if result != 0 {
        return Err(ControllerError(format!(
            "exclusive rename {} -> {} failed: {}",
            source.display(),
            destination.display(),
            std::io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn rename_replacing(source: &Path, destination: &Path) -> Result<()> {
    require_regular(source, 0o600)?;
    if source.parent().is_none() || source.parent() != destination.parent() {
        return Err(ControllerError(
            "atomic replacement paths are not in one directory".to_owned(),
        ));
    }
    let old = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| ControllerError("replacement source contains NUL".to_owned()))?;
    let new = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| ControllerError("replacement destination contains NUL".to_owned()))?;
    // SAFETY: both C strings are live and NUL-terminated. A zero flag is ordinary atomic rename
    // semantics on Darwin, replacing only the already-validated same-directory result pathname.
    let result = unsafe { renameatx_np(AT_FDCWD, old.as_ptr(), AT_FDCWD, new.as_ptr(), 0) };
    if result != 0 {
        return Err(ControllerError(format!(
            "atomic replacement {} -> {} failed: {}",
            source.display(),
            destination.display(),
            std::io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn publish_active_pointer(evidence: &Path) -> Result<()> {
    require_descendant(Path::new(UPDATE_ROOT), evidence)?;
    let pending = PathBuf::from(format!("{ACTIVE_UPDATE}.pending-{}", std::process::id()));
    require_path_absent(&pending, "pending update pointer")?;
    require_path_absent(Path::new(ACTIVE_UPDATE), "active update pointer")?;
    let mut file = create_new_private(&pending)?;
    writeln!(file, "{}", evidence.display())?;
    file.sync_all()?;
    rename_exclusive(&pending, Path::new(ACTIVE_UPDATE))?;
    fsync_parent(Path::new(ACTIVE_UPDATE))
}

fn read_active_update_pointer() -> Result<PathBuf> {
    read_update_pointer_at(Path::new(ACTIVE_UPDATE), Path::new(UPDATE_ROOT))
}

fn read_update_pointer_at(pointer: &Path, update_root: &Path) -> Result<PathBuf> {
    require_regular(pointer, 0o600)?;
    let text = read_bounded_utf8(pointer, 1_024)?;
    if !text.ends_with('\n') || text[..text.len() - 1].contains('\n') {
        return Err(ControllerError("update pointer is malformed".to_owned()));
    }
    let path = PathBuf::from(text.trim_end_matches('\n'));
    require_descendant(update_root, &path)?;
    Ok(path)
}

fn verify_active_update_pointer(expected_evidence: &Path) -> Result<()> {
    verify_update_pointer_at(
        Path::new(ACTIVE_UPDATE),
        expected_evidence,
        Path::new(UPDATE_ROOT),
    )
}

fn verify_update_pointer_at(
    pointer: &Path,
    expected_evidence: &Path,
    update_root: &Path,
) -> Result<()> {
    require_regular(pointer, 0o600)?;
    let before = fs::metadata(pointer)?;
    let observed = read_update_pointer_at(pointer, update_root)?;
    let after = fs::metadata(pointer)?;
    if observed != expected_evidence
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.nlink() != 1
        || after.nlink() != 1
        || before.uid() != USER_ID
        || after.uid() != USER_ID
    {
        return Err(ControllerError(
            "active update pointer changed or does not name this transaction".to_owned(),
        ));
    }
    File::open(pointer)?.sync_all()?;
    fsync_parent(pointer)
}

fn retire_active_update_pointer(layout: &Layout) -> Result<()> {
    retire_update_pointer_at(
        Path::new(ACTIVE_UPDATE),
        &layout.evidence,
        Path::new(UPDATE_ROOT),
    )
}

fn retire_update_pointer_at(
    active_pointer: &Path,
    evidence: &Path,
    update_root: &Path,
) -> Result<()> {
    require_descendant(update_root, evidence)?;
    require_directory(evidence, 0o700)?;
    let retired_pointer = evidence.join("retired-active-pointer.txt");
    match (
        fs::symlink_metadata(active_pointer),
        fs::symlink_metadata(&retired_pointer),
    ) {
        (Ok(_), Ok(_)) => {
            return Err(ControllerError(
                "active and retired update pointers both exist".to_owned(),
            ))
        }
        (Ok(_), Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            verify_update_pointer_at(active_pointer, evidence, update_root)?;
            rename_exclusive(active_pointer, &retired_pointer)?;
            fsync_parent(active_pointer)?;
            fsync_parent(&retired_pointer)?;
        }
        (Err(error), Ok(_)) if error.kind() == std::io::ErrorKind::NotFound => {}
        (Err(active_error), Err(retired_error)) => {
            return Err(ControllerError(format!(
                "cannot locate exact active or retired update pointer: active={active_error}; retired={retired_error}"
            )))
        }
        (Ok(_), Err(error)) => return Err(error.into()),
        (Err(error), Ok(_)) => return Err(error.into()),
    }
    verify_update_pointer_at(&retired_pointer, evidence, update_root)?;
    require_path_absent(active_pointer, "retired active update pointer")
}

fn write_result(path: &Path, result: &str, diagnostic: Option<&str>) -> Result<()> {
    if !matches!(
        result,
        "success"
            | "success-with-warning"
            | "failed-before-stop"
            | "rolled-back"
            | "critical-failure"
            | "rolled-back-by-explicit-request"
            | "rolled-back-recovered"
    ) {
        return Err(ControllerError("result token is not reviewed".to_owned()));
    }
    let parent = path
        .parent()
        .ok_or_else(|| ControllerError("result path has no parent".to_owned()))?;
    require_directory(parent, 0o700)?;
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| ControllerError("result filename is not UTF-8".to_owned()))?;
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
        .as_nanos();
    let pending = parent.join(format!(
        ".{file_name}.pending-{}-{unique}",
        std::process::id()
    ));
    require_path_absent(&pending, "pending result record")?;
    let mut file = create_new_private(&pending)?;
    let mut record = Vec::new();
    writeln!(record, "result={result}")?;
    if let Some(diagnostic) = diagnostic {
        let mut sanitized = String::new();
        for character in diagnostic.chars().map(|character| {
            if character == '\n' || character == '\r' {
                ' '
            } else {
                character
            }
        }) {
            if sanitized.len() + character.len_utf8() > 4_096 {
                break;
            }
            sanitized.push(character);
        }
        writeln!(record, "diagnostic={sanitized}")?;
    }
    file.write_all(&record)?;
    file.sync_all()?;
    drop(file);
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.file_type().is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.nlink() == 1
                && metadata.permissions().mode() & 0o777 == 0o600 => {}
        Ok(_) => return Err(ControllerError("result path is unsafe".to_owned())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(ControllerError(format!(
                "cannot inspect result replacement destination: {error}"
            )))
        }
    }
    rename_replacing(&pending, path)?;
    require_regular(path, 0o600)?;
    fsync_parent(path)?;
    if read_bounded_utf8(path, 8_192)?.as_bytes() != record {
        return Err(ControllerError(
            "atomic result replacement bytes differ from the durable record".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_rolled_back_result(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return write_result(path, "rolled-back-recovered", None)
        }
        Err(error) => return Err(error.into()),
        Ok(_) => require_regular(path, 0o600)?,
    }
    let text = read_bounded_utf8(path, 8_192)?;
    if !text.ends_with('\n') {
        return Err(ControllerError(
            "rolled-back result is not newline-terminated".to_owned(),
        ));
    }
    let mut lines = text.lines();
    let first = lines.next().unwrap_or_default();
    let already_rolled_back = matches!(
        first,
        "result=rolled-back"
            | "result=rolled-back-by-explicit-request"
            | "result=rolled-back-recovered"
    );
    let replace_prior_result = matches!(
        first,
        "result=success"
            | "result=success-with-warning"
            | "result=critical-failure"
            | "result=failed-before-stop"
    );
    if !already_rolled_back && !replace_prior_result {
        return Err(ControllerError(
            "rolled-back journal has an inconsistent result record".to_owned(),
        ));
    }
    if let Some(diagnostic) = lines.next() {
        if !diagnostic.starts_with("diagnostic=") || diagnostic.len() > 4_107 {
            return Err(ControllerError(
                "rolled-back result diagnostic is malformed".to_owned(),
            ));
        }
    }
    if lines.next().is_some() {
        return Err(ControllerError(
            "rolled-back result has extra records".to_owned(),
        ));
    }
    if replace_prior_result {
        write_result(path, "rolled-back-recovered", None)
    } else {
        Ok(())
    }
}

fn parse_journal(text: &str) -> Result<UpdateState> {
    let mut lines = text.lines();
    if lines.next() != Some(JOURNAL_HEADER) {
        return Err(ControllerError(
            "update journal header is malformed".to_owned(),
        ));
    }
    let mut state = None;
    for line in lines {
        let mut fields = line.split(' ');
        if fields.next() != Some("STATE") {
            return Err(ControllerError(
                "update journal record is malformed".to_owned(),
            ));
        }
        let next = fields
            .next()
            .and_then(UpdateState::parse)
            .ok_or_else(|| ControllerError("update journal state is unknown".to_owned()))?;
        if let Some(previous) = state {
            validate_transition(previous, next)?;
        } else if next != UpdateState::Begun {
            return Err(ControllerError(
                "update journal does not begin at BEGUN".to_owned(),
            ));
        }
        let fields: Vec<&str> = fields.collect();
        let expected_fields = journal_field_schema(next);
        if fields.len() != expected_fields.len() {
            return Err(ControllerError(
                "update journal field count is invalid".to_owned(),
            ));
        }
        for (field, expected_key) in fields.into_iter().zip(expected_fields) {
            let (key, value) = field
                .split_once('=')
                .ok_or_else(|| ControllerError("update journal field is malformed".to_owned()))?;
            if key != *expected_key || !is_safe_journal_value(value) {
                return Err(ControllerError("update journal field is unsafe".to_owned()));
            }
        }
        state = Some(next);
    }
    state.ok_or_else(|| ControllerError("update journal has no state".to_owned()))
}

fn journal_field_schema(state: UpdateState) -> &'static [&'static str] {
    match state {
        UpdateState::Begun
        | UpdateState::InstallHoldVerified
        | UpdateState::V20Stopped
        | UpdateState::InteractiveStopped
        | UpdateState::V20Held
        | UpdateState::NewPublished
        | UpdateState::PersistentBootstrapped
        | UpdateState::Committed
        | UpdateState::RollbackStarted
        | UpdateState::FailedNewArchived
        | UpdateState::V20Restored
        | UpdateState::V20Bootstrapped
        | UpdateState::RolledBack => &[],
        UpdateState::SourceExported => &["commit", "tree", "initial_pid"],
        UpdateState::BuildVerified => &["executable_sha256"],
        UpdateState::StopInitiated => &["reserve_device", "reserve_inode", "reserve_bytes"],
        UpdateState::InteractiveReady | UpdateState::PairingCommitted => {
            &["pid", "process_start", "nonce", "lock_device", "lock_inode"]
        }
        UpdateState::ReadyVerified => &["pid", "runs", "nonce"],
        UpdateState::CriticalFailure => &["phase"],
    }
}

fn validate_journal_record_fields(state: UpdateState, fields: &[(&str, String)]) -> Result<()> {
    let expected = journal_field_schema(state);
    if fields.len() != expected.len() {
        return Err(ControllerError(
            "update journal record has the wrong field count".to_owned(),
        ));
    }
    for ((key, value), expected_key) in fields.iter().zip(expected) {
        if *key != *expected_key || !is_safe_journal_value(value) {
            return Err(ControllerError("unsafe journal field".to_owned()));
        }
    }
    Ok(())
}

fn is_safe_journal_value(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'/')
        })
}

const ALL_UPDATE_STATES: [UpdateState; 20] = [
    UpdateState::Begun,
    UpdateState::SourceExported,
    UpdateState::BuildVerified,
    UpdateState::StopInitiated,
    UpdateState::InstallHoldVerified,
    UpdateState::V20Stopped,
    UpdateState::InteractiveReady,
    UpdateState::PairingCommitted,
    UpdateState::InteractiveStopped,
    UpdateState::V20Held,
    UpdateState::NewPublished,
    UpdateState::PersistentBootstrapped,
    UpdateState::ReadyVerified,
    UpdateState::Committed,
    UpdateState::RollbackStarted,
    UpdateState::FailedNewArchived,
    UpdateState::V20Restored,
    UpdateState::V20Bootstrapped,
    UpdateState::RolledBack,
    UpdateState::CriticalFailure,
];

fn is_plausible_torn_journal_tail(tail: &[u8], previous: UpdateState) -> bool {
    if tail.is_empty() || tail.len() > 4_096 || tail.contains(&b'\n') || tail.contains(&b'\r') {
        return false;
    }
    let Ok(tail) = std::str::from_utf8(tail) else {
        return false;
    };
    ALL_UPDATE_STATES
        .iter()
        .copied()
        .filter(|next| validate_transition(previous, *next).is_ok())
        .any(|next| is_plausible_journal_record_prefix(tail, next))
}

fn is_plausible_journal_record_prefix(tail: &str, state: UpdateState) -> bool {
    let state_prefix = format!("STATE {}", state.token());
    if tail.len() <= state_prefix.len() {
        return state_prefix.starts_with(tail);
    }
    if !tail.starts_with(&state_prefix) {
        return false;
    }
    let remainder = &tail[state_prefix.len()..];
    if remainder.is_empty() {
        return true;
    }
    let Some(fields_text) = remainder.strip_prefix(' ') else {
        return false;
    };
    let expected_fields = journal_field_schema(state);
    if expected_fields.is_empty() {
        return false;
    }
    let fields: Vec<&str> = fields_text.split(' ').collect();
    if fields.len() > expected_fields.len() {
        return false;
    }
    for (index, (field, expected_key)) in fields.iter().zip(expected_fields).enumerate() {
        let expected_prefix = format!("{expected_key}=");
        let is_last = index + 1 == fields.len();
        if field.len() <= expected_prefix.len() {
            return is_last && expected_prefix.starts_with(field);
        }
        let Some(value) = field.strip_prefix(&expected_prefix) else {
            return false;
        };
        if !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'/')
        }) || (value.is_empty() && !is_last)
        {
            return false;
        }
    }
    true
}

fn validate_transition(previous: UpdateState, next: UpdateState) -> Result<()> {
    if previous == next && next == UpdateState::Begun {
        return Ok(());
    }
    let forward = matches!(
        (previous, next),
        (UpdateState::Begun, UpdateState::SourceExported)
            | (UpdateState::SourceExported, UpdateState::BuildVerified)
            | (UpdateState::BuildVerified, UpdateState::StopInitiated)
            | (UpdateState::StopInitiated, UpdateState::InstallHoldVerified)
            | (UpdateState::InstallHoldVerified, UpdateState::V20Stopped)
            | (UpdateState::V20Stopped, UpdateState::InteractiveReady)
            | (UpdateState::InteractiveReady, UpdateState::PairingCommitted)
            | (
                UpdateState::PairingCommitted,
                UpdateState::InteractiveStopped
            )
            | (UpdateState::InteractiveStopped, UpdateState::V20Held)
            | (UpdateState::V20Held, UpdateState::NewPublished)
            | (
                UpdateState::NewPublished,
                UpdateState::PersistentBootstrapped
            )
            | (
                UpdateState::PersistentBootstrapped,
                UpdateState::ReadyVerified
            )
            | (UpdateState::ReadyVerified, UpdateState::Committed)
    );
    let rollback_entry = next == UpdateState::RollbackStarted
        && ((previous >= UpdateState::StopInitiated && previous <= UpdateState::Committed)
            || previous == UpdateState::CriticalFailure)
        && previous != UpdateState::RollbackStarted;
    let rollback = matches!(
        (previous, next),
        (UpdateState::RollbackStarted, UpdateState::FailedNewArchived)
            | (UpdateState::RollbackStarted, UpdateState::V20Restored)
            | (UpdateState::FailedNewArchived, UpdateState::V20Restored)
            | (UpdateState::V20Restored, UpdateState::V20Bootstrapped)
            | (UpdateState::V20Bootstrapped, UpdateState::RolledBack)
    );
    let critical = next == UpdateState::CriticalFailure
        && previous >= UpdateState::RollbackStarted
        && previous < UpdateState::RolledBack;
    if forward || rollback_entry || rollback || critical {
        Ok(())
    } else {
        Err(ControllerError(format!(
            "invalid update journal transition: {} -> {}",
            previous.token(),
            next.token()
        )))
    }
}

fn is_valid_invitation_code(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 8
        && groups.iter().all(|group| {
            group.len() == 5
                && group.bytes().all(|byte| {
                    matches!(byte, b'0'..=b'9' | b'A'..=b'H' | b'J'..=b'N' | b'P'..=b'T' | b'V'..=b'Z')
                })
        })
}

fn self_test() -> Result<()> {
    if !is_valid_invitation_code("04002-0G30G-2GC1R-81450-P30D1-R7H04-8J2EZ-G8AG3")
        || is_valid_invitation_code("04002-0G30G-2GC1R-81450-P30D1-R7H04-8J2EZ-G8AGI")
        || is_valid_invitation_code("04002-0G30G")
    {
        return Err(ControllerError(
            "invitation parser self-test failed".to_owned(),
        ));
    }
    let spaced_path = "/private/tmp/opensteamer Host.app/Contents/MacOS/CaptureServer";
    let digest = "a".repeat(64);
    if parse_shasum_output(&format!("{digest}  {spaced_path}\n"), spaced_path)? != digest
        || parse_shasum_output(&format!("{digest} *{spaced_path}\n"), spaced_path)? != digest
        || parse_shasum_output(
            &format!("{digest}  /private/tmp/opensteamer\n"),
            spaced_path,
        )
        .is_ok()
        || parse_shasum_output(&format!("{digest}  {spaced_path}\nextra\n"), spaced_path).is_ok()
    {
        return Err(ControllerError(
            "filename-aware shasum parser self-test failed".to_owned(),
        ));
    }
    let valid = format!(
        "{JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE INSTALL_HOLD_VERIFIED\nSTATE V20_STOPPED\nSTATE INTERACTIVE_READY pid=42 process_start=Mon_Aug_3 nonce={} lock_device=1 lock_inode=2\nSTATE PAIRING_COMMITTED pid=42 process_start=Mon_Aug_3 nonce={} lock_device=1 lock_inode=2\nSTATE INTERACTIVE_STOPPED\nSTATE V20_HELD\nSTATE NEW_PUBLISHED\nSTATE PERSISTENT_BOOTSTRAPPED\nSTATE READY_VERIFIED pid=43 runs=1 nonce={}\nSTATE COMMITTED\n",
        "a".repeat(40),
        "e".repeat(40),
        "b".repeat(64),
        "c".repeat(64),
        "c".repeat(64),
        "d".repeat(64),
    );
    if parse_journal(&valid)? != UpdateState::Committed {
        return Err(ControllerError(
            "journal parser self-test failed".to_owned(),
        ));
    }
    let invalid = format!("{JOURNAL_HEADER}\nSTATE BEGUN\nSTATE V20_STOPPED\nSTATE COMMITTED\n");
    if parse_journal(&invalid).is_ok() {
        return Err(ControllerError(
            "journal parser accepted a skipped transition".to_owned(),
        ));
    }
    let rollback_before_move = format!(
        "{JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE ROLLBACK_STARTED\nSTATE V20_RESTORED\nSTATE V20_BOOTSTRAPPED\nSTATE ROLLED_BACK\n",
        "a".repeat(40),
        "e".repeat(40),
        "b".repeat(64),
    );
    if parse_journal(&rollback_before_move)? != UpdateState::RolledBack {
        return Err(ControllerError(
            "pre-move rollback journal self-test failed".to_owned(),
        ));
    }
    let rollback_after_publish = format!(
        "{JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE INSTALL_HOLD_VERIFIED\nSTATE V20_STOPPED\nSTATE INTERACTIVE_READY pid=42 process_start=Mon_Aug_3 nonce={} lock_device=1 lock_inode=2\nSTATE PAIRING_COMMITTED pid=42 process_start=Mon_Aug_3 nonce={} lock_device=1 lock_inode=2\nSTATE INTERACTIVE_STOPPED\nSTATE V20_HELD\nSTATE NEW_PUBLISHED\nSTATE ROLLBACK_STARTED\nSTATE FAILED_NEW_ARCHIVED\nSTATE V20_RESTORED\nSTATE V20_BOOTSTRAPPED\nSTATE ROLLED_BACK\n",
        "a".repeat(40),
        "e".repeat(40),
        "b".repeat(64),
        "c".repeat(64),
        "c".repeat(64),
    );
    if parse_journal(&rollback_after_publish)? != UpdateState::RolledBack {
        return Err(ControllerError(
            "post-publish rollback journal self-test failed".to_owned(),
        ));
    }
    self_test_journal_recovery()?;
    let hold_root = Path::new("/Applications/.opensteamer-post-v20-install-selftest");
    let hold_app = hold_root.join("opensteamer Host.app");
    require_install_hold_layout(hold_root, &hold_app)?;
    if require_install_hold_layout(Path::new("/Applications/opensteamer Host.app"), &hold_app)
        .is_ok()
        || require_install_hold_layout(hold_root, &hold_root.join("not-opensteamer Host.app"))
            .is_ok()
        || require_install_hold_layout(hold_root, Path::new("/Applications/opensteamer Host.app"))
            .is_ok()
    {
        return Err(ControllerError(
            "install-hold layout self-test failed".to_owned(),
        ));
    }
    let launch_fixture = format!(
        "gui/{USER_ID}/{NEW_LABEL} = {{\n\tpath = {NEW_PLIST}\n\ttype = LaunchAgent\n\tstate = running\n\tprogram = {NEW_EXECUTABLE}\n\targuments = {{\n\t\t{NEW_EXECUTABLE}\n\t\t{}\n\t}}\n\truns = 4\n\tpid = 4242\n}}\n",
        HOST_ARGUMENTS.join("\n\t\t")
    );
    let launch = parse_launch_state(&launch_fixture)?;
    if launch.pid != 4242 || launch.runs != 4 {
        return Err(ControllerError("launch parser self-test failed".to_owned()));
    }
    let waiting_fixture = format!(
        "gui/{USER_ID}/{NEW_LABEL} = {{\n\tpath = {NEW_PLIST}\n\ttype = LaunchAgent\n\tstate = waiting\n\tprogram = {NEW_EXECUTABLE}\n\targuments = {{\n\t\t{NEW_EXECUTABLE}\n\t\t{}\n\t}}\n\truns = 0\n}}\n",
        HOST_ARGUMENTS.join("\n\t\t")
    );
    let waiting = parse_loaded_launch_job(&waiting_fixture)?;
    if waiting.state != "waiting" || waiting.pid.is_some() || waiting.runs != Some(0) {
        return Err(ControllerError(
            "rollback launch parser self-test failed".to_owned(),
        ));
    }
    if parse_launch_state(&waiting_fixture).is_ok()
        || parse_loaded_launch_job(&waiting_fixture.replace(NEW_PLIST, "/tmp/unreviewed.plist"))
            .is_ok()
    {
        return Err(ControllerError(
            "rollback launch parser accepted an invalid identity".to_owned(),
        ));
    }
    let staged_fixture = Path::new("/private/tmp/opensteamer-selftest/CaptureServer");
    if validate_exact_staged_process_sample(&[], 42, staged_fixture)?
        || !validate_exact_staged_process_sample(
            &[(42, staged_fixture.to_path_buf())],
            42,
            staged_fixture,
        )?
        || validate_exact_staged_process_sample(
            &[(43, staged_fixture.to_path_buf())],
            42,
            staged_fixture,
        )
        .is_ok()
        || validate_exact_staged_process_sample(
            &[(42, PathBuf::from("/private/tmp/other/CaptureServer"))],
            42,
            staged_fixture,
        )
        .is_ok()
    {
        return Err(ControllerError(
            "staged rollback process topology self-test failed".to_owned(),
        ));
    }
    println!("SELF_TEST_OK post-v20-host-update-controller");
    Ok(())
}

fn self_test_journal_recovery() -> Result<()> {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
        .as_nanos();
    let directory = PathBuf::from(format!(
        "/private/tmp/opensteamer-post-v20-journal-selftest-{}-{unique}",
        std::process::id()
    ));
    fs::create_dir(&directory)?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;

    let test_result = (|| {
        let recoverable = directory.join("recoverable.log");
        let mut journal = Journal::create(&recoverable)?;
        journal.record(
            UpdateState::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "e".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        let length_before_rejected_record = fs::metadata(&recoverable)?.len();
        if journal
            .record(
                UpdateState::BuildVerified,
                &[("executable_sha256", "unsafe value".to_owned())],
            )
            .is_ok()
            || fs::metadata(&recoverable)?.len() != length_before_rejected_record
        {
            return Err(ControllerError(
                "journal validation failure changed durable bytes".to_owned(),
            ));
        }
        drop(journal);

        let mut partial = OpenOptions::new().append(true).open(&recoverable)?;
        partial.write_all(
            format!("STATE BUILD_VERIFIED executable_sha256={}", "b".repeat(64)).as_bytes(),
        )?;
        partial.sync_all()?;
        drop(partial);

        let mut reopened = Journal::open(&recoverable)?;
        if reopened.state != UpdateState::SourceExported {
            return Err(ControllerError(
                "journal recovery accepted an incomplete final record".to_owned(),
            ));
        }
        reopened.record(
            UpdateState::BuildVerified,
            &[("executable_sha256", "b".repeat(64))],
        )?;
        drop(reopened);
        if parse_journal(&read_bounded_utf8(&recoverable, 1_048_576)?)?
            != UpdateState::BuildVerified
        {
            return Err(ControllerError(
                "journal did not continue after truncation recovery".to_owned(),
            ));
        }

        let corrupt = directory.join("corrupt.log");
        let mut journal = Journal::create(&corrupt)?;
        journal.record(
            UpdateState::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "e".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        drop(journal);
        let mut complete_corruption = OpenOptions::new().append(true).open(&corrupt)?;
        complete_corruption.write_all(b"STATE V20_STOPPED\n")?;
        complete_corruption.sync_all()?;
        drop(complete_corruption);
        if Journal::open(&corrupt).is_ok() {
            return Err(ControllerError(
                "journal recovery accepted a malformed complete record".to_owned(),
            ));
        }

        for (index, tail) in [
            b"STATE V20_STOPPED".as_slice(),
            b"STATE BUILD_VERIFIED unexpected".as_slice(),
        ]
        .into_iter()
        .enumerate()
        {
            let path = directory.join(format!("implausible-{index}.log"));
            let mut journal = Journal::create(&path)?;
            journal.record(
                UpdateState::SourceExported,
                &[
                    ("commit", "a".repeat(40)),
                    ("tree", "e".repeat(40)),
                    ("initial_pid", "41".to_owned()),
                ],
            )?;
            drop(journal);
            let mut append = OpenOptions::new().append(true).open(&path)?;
            append.write_all(tail)?;
            append.sync_all()?;
            drop(append);
            let length_before_open = fs::metadata(&path)?.len();
            if Journal::open(&path).is_ok() || fs::metadata(&path)?.len() != length_before_open {
                return Err(ControllerError(
                    "journal recovery accepted or truncated implausible tail bytes".to_owned(),
                ));
            }
        }

        let poisoned_path = directory.join("poisoned.log");
        let mut poisoned = Journal::create(&poisoned_path)?;
        let poisoned_length = fs::metadata(&poisoned_path)?.len();
        poisoned.healthy = false;
        if poisoned
            .record(
                UpdateState::SourceExported,
                &[
                    ("commit", "a".repeat(40)),
                    ("tree", "e".repeat(40)),
                    ("initial_pid", "41".to_owned()),
                ],
            )
            .is_ok()
            || fs::metadata(&poisoned_path)?.len() != poisoned_length
        {
            return Err(ControllerError(
                "poisoned journal allowed a later mutation".to_owned(),
            ));
        }
        drop(poisoned);

        let transaction_lock_path = directory.join("transaction.lock");
        let first_lock = acquire_update_transaction_lock_at(&transaction_lock_path)?;
        if acquire_update_transaction_lock_at(&transaction_lock_path).is_ok() {
            return Err(ControllerError(
                "post-v20 transaction lock allowed concurrent ownership".to_owned(),
            ));
        }
        drop(first_lock);
        let second_lock = acquire_update_transaction_lock_at(&transaction_lock_path)?;
        drop(second_lock);

        let update_root = directory.join("updates");
        let rolled_back_evidence = update_root.join("rolled-back-attempt");
        create_private_directory(&update_root)?;
        create_private_directory(&rolled_back_evidence)?;
        let active_pointer = directory.join("active-pointer");
        let mut pointer = create_new_private(&active_pointer)?;
        writeln!(pointer, "{}", rolled_back_evidence.display())?;
        pointer.sync_all()?;
        drop(pointer);
        verify_update_pointer_at(&active_pointer, &rolled_back_evidence, &update_root)?;
        let recovered_result = rolled_back_evidence.join("result.txt");
        write_result(&recovered_result, "success", None)?;
        let torn_pending_result = rolled_back_evidence.join(".result.txt.pending-crash-fixture");
        let mut torn_pending = create_new_private(&torn_pending_result)?;
        torn_pending.write_all(b"result=rolled")?;
        torn_pending.sync_all()?;
        drop(torn_pending);
        ensure_rolled_back_result(&recovered_result)?;
        ensure_rolled_back_result(&recovered_result)?;
        if read_bounded_utf8(&recovered_result, 8_192)? != "result=rolled-back-recovered\n" {
            return Err(ControllerError(
                "rolled-back result recovery did not atomically replace prior success".to_owned(),
            ));
        }
        let absent_result = rolled_back_evidence.join("absent-result.txt");
        let mut absent_pending = create_new_private(
            &rolled_back_evidence.join(".absent-result.txt.pending-crash-fixture"),
        )?;
        absent_pending.write_all(b"result=rolled")?;
        absent_pending.sync_all()?;
        drop(absent_pending);
        ensure_rolled_back_result(&absent_result)?;
        let unicode_result = rolled_back_evidence.join("unicode-result.txt");
        write_result(
            &unicode_result,
            "rolled-back",
            Some(&"\u{1f642}".repeat(4_096)),
        )?;
        ensure_rolled_back_result(&unicode_result)?;
        retire_update_pointer_at(&active_pointer, &rolled_back_evidence, &update_root)?;
        retire_update_pointer_at(&active_pointer, &rolled_back_evidence, &update_root)?;
        if active_pointer.exists()
            || !rolled_back_evidence
                .join("retired-active-pointer.txt")
                .exists()
        {
            return Err(ControllerError(
                "rolled-back update pointer retirement was not durable".to_owned(),
            ));
        }
        let retry_evidence = update_root.join("retry-attempt");
        create_private_directory(&retry_evidence)?;
        let mut retry_pointer = create_new_private(&active_pointer)?;
        writeln!(retry_pointer, "{}", retry_evidence.display())?;
        retry_pointer.sync_all()?;
        drop(retry_pointer);
        verify_update_pointer_at(&active_pointer, &retry_evidence, &update_root)?;
        Ok(())
    })();

    let cleanup_result = fs::remove_dir_all(&directory);
    match (test_result, cleanup_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) => Err(error),
        (Ok(()), Err(error)) => Err(ControllerError(format!(
            "cannot remove journal self-test directory: {error}"
        ))),
        (Err(test_error), Err(cleanup_error)) => Err(ControllerError(format!(
            "{test_error}; cannot remove journal self-test directory: {cleanup_error}"
        ))),
    }
}

fn canonical_repo(value: &str) -> Result<PathBuf> {
    let requested = PathBuf::from(value);
    if !requested.is_absolute() {
        return Err(ControllerError(
            "repository path must be absolute".to_owned(),
        ));
    }
    let canonical = requested.canonicalize()?;
    if canonical != requested || canonical != Path::new("/Users/ahmed/Documents/Codex/opensteamer")
    {
        return Err(ControllerError(format!(
            "repository path must be the exact canonical opensteamer checkout: {}",
            canonical.display()
        )));
    }
    require_directory(&canonical, 0o755)?;
    Ok(canonical)
}

fn require_regular(path: &Path, expected_mode: u32) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ControllerError(format!(
            "cannot inspect required file {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != USER_ID
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o777 != expected_mode
    {
        return Err(ControllerError(format!(
            "required file has unsafe type/owner/link-count/mode: {}",
            path.display()
        )));
    }
    Ok(())
}

fn require_directory(path: &Path, expected_mode: u32) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ControllerError(format!(
            "cannot inspect required directory {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.file_type().is_dir()
        || metadata.file_type().is_symlink()
        || metadata.permissions().mode() & 0o777 != expected_mode
    {
        return Err(ControllerError(format!(
            "required directory has unsafe type/mode: {}",
            path.display()
        )));
    }
    if path != Path::new("/Applications") && metadata.uid() != USER_ID {
        return Err(ControllerError(format!(
            "required directory is not owned by uid {USER_ID}: {}",
            path.display()
        )));
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<()> {
    if path.exists() {
        return require_directory(path, 0o700);
    }
    fs::create_dir(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    require_directory(path, 0o700)?;
    fsync_parent(path)
}

fn create_new_private(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .read(true)
        .mode(0o600)
        .open(path)?;
    require_regular(path, 0o600)?;
    Ok(file)
}

fn require_path_absent(path: &Path, description: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(ControllerError(format!(
            "{description} already exists: {}",
            path.display()
        ))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ControllerError(format!(
            "cannot inspect {description} {}: {error}",
            path.display()
        ))),
    }
}

fn require_descendant(root: &Path, path: &Path) -> Result<()> {
    if !path.is_absolute() || path == root || !path.starts_with(root) {
        return Err(ControllerError(format!(
            "path escaped private update root: {}",
            path.display()
        )));
    }
    Ok(())
}

fn require_direct_hidden_application_hold_root(root: &Path) -> Result<()> {
    if root.parent() != Some(Path::new("/Applications"))
        || !root
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                name.starts_with(".opensteamer-post-v20-install-") && name.len() < 160
            })
    {
        return Err(ControllerError(format!(
            "install hold is outside the reviewed hidden Applications namespace: {}",
            root.display()
        )));
    }
    Ok(())
}

fn require_install_hold_layout(root: &Path, app: &Path) -> Result<()> {
    require_direct_hidden_application_hold_root(root)?;
    if app.parent() != Some(root)
        || app.file_name().and_then(|name| name.to_str()) != Some("opensteamer Host.app")
    {
        return Err(ControllerError(format!(
            "install-hold app is not the exact reviewed child of its hidden root: {}",
            app.display()
        )));
    }
    Ok(())
}

fn fsync_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| ControllerError("path has no parent to fsync".to_owned()))?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn require_tree_equal(expected: &Path, actual: &Path) -> Result<()> {
    let output = command_output(
        "/usr/bin/diff",
        &["-qr", path_text(expected)?, path_text(actual)?],
        None,
    )?;
    if !output.status.success() {
        return Err(command_failure("compare app trees", &output));
    }
    Ok(())
}

fn require_available_bytes(path: &Path, minimum: u64, phase: &str) -> Result<()> {
    let applications_device = fs::metadata("/Applications")?.dev();
    if fs::metadata(path)?.dev() != applications_device {
        return Err(ControllerError(
            "private evidence and /Applications are not on the same filesystem".to_owned(),
        ));
    }
    let output = command_output("/bin/df", &["-kP", path_text(path)?], None)?;
    require_output_success(&output, "read filesystem free space")?;
    let text = decode_utf8(&output.stdout, "df output")?;
    let records: Vec<&str> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    if records.len() != 2 {
        return Err(ControllerError(
            "df output is missing or ambiguous".to_owned(),
        ));
    }
    let fields: Vec<&str> = records[1].split_ascii_whitespace().collect();
    if fields.len() < 6 {
        return Err(ControllerError(
            "df filesystem record is malformed".to_owned(),
        ));
    }
    let available_kib = fields[3]
        .parse::<u64>()
        .map_err(|_| ControllerError("df available-block count is malformed".to_owned()))?;
    let available = available_kib
        .checked_mul(1_024)
        .ok_or_else(|| ControllerError("df available-byte count overflowed".to_owned()))?;
    if available < minimum {
        return Err(ControllerError(format!(
            "insufficient free space {phase}: available={available} required={minimum}"
        )));
    }
    Ok(())
}

fn allocate_rollback_reserve(path: &Path, length: u64) -> Result<(u64, u64, u64)> {
    require_path_absent(path, "rollback reserve")?;
    let mut file = create_new_private(path)?;
    let chunk = vec![0u8; 1_048_576];
    let mut written = 0u64;
    while written < length {
        let remaining = usize::try_from((length - written).min(chunk.len() as u64))
            .map_err(|_| ControllerError("rollback reserve length overflowed".to_owned()))?;
        file.write_all(&chunk[..remaining])?;
        written += remaining as u64;
    }
    file.sync_all()?;
    fsync_parent(path)?;
    let metadata = file.metadata()?;
    let allocated = metadata
        .blocks()
        .checked_mul(512)
        .ok_or_else(|| ControllerError("rollback reserve allocation overflowed".to_owned()))?;
    if metadata.len() != length || allocated < length {
        return Err(ControllerError(format!(
            "rollback reserve is not fully allocated: length={} allocated={allocated}",
            metadata.len()
        )));
    }
    Ok((metadata.dev(), metadata.ino(), length))
}

fn release_rollback_reserve(path: &Path) -> Result<()> {
    require_regular(path, 0o600)?;
    let file = OpenOptions::new().write(true).open(path)?;
    file.set_len(0)?;
    file.sync_all()?;
    fsync_parent(path)
}

fn sha256(path: &Path) -> Result<String> {
    let output = command_output("/usr/bin/shasum", &["-a", "256", path_text(path)?], None)?;
    require_output_success(&output, "compute SHA-256")?;
    let text = decode_utf8(&output.stdout, "shasum output")?;
    parse_shasum_output(text, path_text(path)?)
}

fn parse_shasum_output(text: &str, expected_path: &str) -> Result<String> {
    let line = text
        .strip_suffix('\n')
        .ok_or_else(|| ControllerError("shasum output is not newline-terminated".to_owned()))?;
    if line.contains('\n') || line.len() < 66 || !line.is_char_boundary(64) {
        return Err(ControllerError("shasum output is malformed".to_owned()));
    }
    let (hash, suffix) = line.split_at(64);
    if hash.len() != 64
        || !hash
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || (suffix != format!("  {expected_path}") && suffix != format!(" *{expected_path}"))
    {
        return Err(ControllerError("shasum output is malformed".to_owned()));
    }
    Ok(hash.to_owned())
}

fn read_bounded_utf8(path: &Path, maximum: u64) -> Result<String> {
    let metadata = fs::metadata(path)?;
    if metadata.len() > maximum {
        return Err(ControllerError(format!(
            "file exceeds bounded read limit: {}",
            path.display()
        )));
    }
    let file = File::open(path)?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(maximum + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > maximum {
        return Err(ControllerError(
            "file grew beyond bounded read limit".to_owned(),
        ));
    }
    String::from_utf8(bytes)
        .map_err(|_| ControllerError(format!("file is not UTF-8: {}", path.display())))
}

fn path_text(path: &Path) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| ControllerError(format!("path is not UTF-8: {}", path.display())))
}

fn command_output(program: &str, arguments: &[&str], cwd: Option<&Path>) -> Result<Output> {
    let mut command = Command::new(program);
    command.args(arguments).env("LC_ALL", "C");
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    command
        .output()
        .map_err(|error| ControllerError(format!("cannot execute {program}: {error}")))
}

fn command_line(program: &str, arguments: &[&str], cwd: Option<&Path>) -> Result<String> {
    let output = command_output(program, arguments, cwd)?;
    require_output_success(&output, program)?;
    let text = decode_utf8(&output.stdout, program)?;
    let records: Vec<&str> = text.lines().collect();
    if records.len() != 1 || records[0].is_empty() {
        return Err(ControllerError(format!(
            "{program} did not return exactly one nonempty line"
        )));
    }
    Ok(records[0].to_owned())
}

fn require_output_success(output: &Output, operation: &str) -> Result<()> {
    if output.status.success() {
        Ok(())
    } else {
        Err(command_failure(operation, output))
    }
}

fn require_success(status: ExitStatus, operation: &str) -> Result<()> {
    if status.success() {
        Ok(())
    } else {
        Err(ControllerError(format!(
            "{operation} failed with status {status}"
        )))
    }
}

fn command_failure(operation: &str, output: &Output) -> ControllerError {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    ControllerError(format!(
        "{operation} failed with status {}: stdout={:?} stderr={:?}",
        output.status,
        truncate(&stdout, 4_096),
        truncate(&stderr, 4_096)
    ))
}

fn truncate(value: &str, maximum: usize) -> String {
    value.chars().take(maximum).collect()
}

fn decode_utf8<'a>(bytes: &'a [u8], description: &str) -> Result<&'a str> {
    std::str::from_utf8(bytes).map_err(|_| ControllerError(format!("{description} is not UTF-8")))
}

fn parse_positive_u32(value: &str, description: &str) -> Result<u32> {
    let parsed = value
        .parse::<u32>()
        .map_err(|_| ControllerError(format!("{description} is malformed")))?;
    if parsed == 0 {
        return Err(ControllerError(format!("{description} must be positive")));
    }
    Ok(parsed)
}

fn parse_u64(value: &str, description: &str) -> Result<u64> {
    value
        .parse::<u64>()
        .map_err(|_| ControllerError(format!("{description} is malformed")))
}

fn new_nonce() -> Result<String> {
    let output = command_output("/usr/bin/uuidgen", &[], None)?;
    require_output_success(&output, "generate update nonce")?;
    let value = decode_utf8(&output.stdout, "uuidgen output")?
        .trim()
        .to_ascii_lowercase();
    if value.len() != 36
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err(ControllerError(
            "uuidgen returned malformed output".to_owned(),
        ));
    }
    Ok(value)
}

fn unix_seconds() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
        .as_secs())
}
