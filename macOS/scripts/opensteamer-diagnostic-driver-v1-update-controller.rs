//! One-shot, driver-only deployment of the reviewed diagnostic virtual-microphone bundle.
//!
//! The transaction keeps the exact committed v8 host bytes and isolated pairing metadata,
//! stops that host before touching the HAL plug-in, retains the installed v7 driver by inode,
//! reloads one exact system `coreaudiod` generation, validates the two product endpoints and
//! passive `osDS` snapshot, and then restarts the byte-identical v8 host. Every post-stop failure
//! restores the retained driver and reloads Core Audio before attempting to restart the host.
//! It never invokes Installer, changes a default route, addresses BlackHole, reads pairing
//! secrets, resets pairing, or operates an iPhone.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt as UnixCommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitCode, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, ControllerError>;

#[derive(Debug)]
struct ControllerError(String);

impl std::fmt::Display for ControllerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl From<std::io::Error> for ControllerError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

const USER_ID: u32 = 501;
const USER_GROUP: u32 = 20;
const ROOT_ID: u32 = 0;
const O_NOFOLLOW: i32 = 0x0000_0100;
const O_CLOEXEC: i32 = 0x0100_0000;
const O_DIRECTORY: i32 = 0x0010_0000;
const O_SYMLINK: i32 = 0x0020_0000;
const O_RDONLY: i32 = 0;
const O_RDWR: i32 = 2;
const APPLICATIONS_DEVICE: u64 = 16_777_229;
const APPLICATIONS_INODE: u64 = 4_982_341;
const APPLICATIONS_NLINK: u64 = 26;
const APPLICATIONS_FLAGS: u32 = 1_048_576;
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;
const SIGTERM: i32 = 15;
const RENAME_EXCL: u32 = 0x0000_0004;
const AT_FDCWD: i32 = -2;
const MAX_OUTPUT_BYTES: usize = 8 * 1_048_576;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const COREAUDIO_TIMEOUT: Duration = Duration::from_secs(120);
const HOST_TIMEOUT: Duration = Duration::from_secs(120);
const MINIMUM_PRESTOP_AVAILABLE_BYTES: u64 = 1_073_741_824;
const ROLLBACK_RESERVE_BYTES: u64 = 8 * 1_048_576;

unsafe extern "C" {
    fn getuid() -> u32;
    fn geteuid() -> u32;
    fn kill(pid: i32, signal: i32) -> i32;
    fn flock(file_descriptor: i32, operation: i32) -> i32;
    fn renameatx_np(from_fd: i32, from: *const i8, to_fd: i32, to: *const i8, flags: u32) -> i32;
    fn openat(directory_fd: i32, path: *const i8, flags: i32, mode: u32) -> i32;
    fn fchown(file_descriptor: i32, owner: u32, group: u32) -> i32;
    fn fchmod(file_descriptor: i32, mode: u32) -> i32;
    fn fchdir(file_descriptor: i32) -> i32;
    fn setgroups(count: i32, groups: *const u32) -> i32;
    fn setgid(group: u32) -> i32;
    fn setuid(user: u32) -> i32;
    fn umask(mask: u32) -> u32;
    fn dup(file_descriptor: i32) -> i32;
    fn lseek(file_descriptor: i32, offset: i64, whence: i32) -> i64;
    fn fdopendir(file_descriptor: i32) -> *mut std::ffi::c_void;
    fn readdir(directory: *mut std::ffi::c_void) -> *mut DarwinDirent;
    fn closedir(directory: *mut std::ffi::c_void) -> i32;
    fn readlinkat(directory_fd: i32, path: *const i8, buffer: *mut i8, buffer_size: usize)
        -> isize;
    fn __error() -> *mut i32;
    fn flistxattr(file_descriptor: i32, names: *mut i8, size: usize, options: i32) -> isize;
    fn fgetxattr(
        file_descriptor: i32,
        name: *const i8,
        value: *mut std::ffi::c_void,
        size: usize,
        position: u32,
        options: i32,
    ) -> isize;
}

#[repr(C)]
struct DarwinDirent {
    inode: u64,
    seek_offset: u64,
    record_length: u16,
    name_length: u16,
    entry_type: u8,
    name: [i8; 1024],
}

const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v1-update-preflight";
const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v1-update";
const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v1-update";
const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v1-update";
const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v1-update";
const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v1-update";
const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v1-update";
const LOCK_PROBE_MODE: &str = "--probe-diagnostic-driver-v1-host-lock";
const LOCK_FREE_PROBE_MODE: &str = "--probe-diagnostic-driver-v1-host-lock-free";
const LOCK_RECORD_PROBE_MODE: &str = "--read-diagnostic-driver-v1-host-lock-record";
const UID501_PINNED_READ_MODE: &str = "--uid501-openat-read-pinned-file";
const UID501_GENERATED_READ_MODE: &str = "--uid501-openat-read-generated-file";
const UID501_HOST_MANIFEST_MODE: &str = "--uid501-openat-host-bundle-manifest";

const EXPECTED_REPO: &str = "/Users/ahmed/Documents/Codex/opensteamer";
const EXPECTED_SOURCE_COMMIT: &str = "fe05e4f8f1e80b143af5a4b0e366160e52a1e14e";
const EXPECTED_SOURCE_TREE: &str = "cafe008bf0b645014aaabefe4c50246595aa2378";
const EXPECTED_REMOTE: &str = "https://github.com/ahmedelami/opensteamer.git";

const USER_SUPPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer";
const USER_UPDATE_ROOT: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1";
const USER_ACTIVE_POINTER: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1";
const USER_UPDATE_LOCK: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-update-v1.lock";
const ROOT_SUPPORT: &str = "/Library/Application Support/opensteamer";
const ROOT_UPDATE_ROOT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-updates-v1";
const ROOT_ACTIVE_POINTER: &str =
    "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1";
const ROOT_ACTIVE_POINTER_PENDING: &str =
    "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1.pending";
const ROOT_UPDATE_LOCK: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-update-v1.lock";
const ROOT_CONTROLLER_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1";
const ROOT_RECOVERY_CONTROLLER: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1/recovery-controller";
const ROOT_RECOVERY_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1/recovery-controller.sha256";
const ROOT_BOOTSTRAP_LOCATOR: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-bootstrap-v1.txt";
const ROOT_PROBE_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-probes-v1";
const ROOT_PRIVATE_MODE: u32 = 0o700;
const ROOT_SEALED_TRAVERSE_MODE: u32 = 0o711;
const ROOT_SEALED_EXECUTABLE_MODE: u32 = 0o555;
const ROOT_SEALED_RECORD_MODE: u32 = 0o444;
const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V1";
const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V1";

const HOST_APP: &str = "/Applications/opensteamer Host.app";
const HOST_EXECUTABLE: &str = "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer";
const HOST_PLIST: &str =
    "/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist";
const HOST_LABEL: &str = "org.example.opensteamer.worldwide";
const HOST_EXECUTABLE_SHA256: &str =
    "10ce8ca0e798215b593400095e80c931ca9c1fa055e79551ad6c940beb0bcba2";
const HOST_EXECUTABLE_SIZE: u64 = 6_089_040;
const HOST_INFO_PLIST_SHA256: &str =
    "3c017d9cf034cbc864fc19103a0919f296930f0752f8ecfedcb1c93fbbc9694d";
const HOST_INFO_PLIST_SIZE: u64 = 1_477;
const HOST_BUNDLE_MANIFEST_SHA256: &str =
    "96a5dfcf07b0ef5fdedbac6fe9d559aa76e6bd8a14743d93845192f4e1d89686";
const HOST_PLIST_SHA256: &str = "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";
const HOST_PLIST_SIZE: u64 = 1_137;
const HOST_CDHASH: &str = "28120d626fd265cfea12397ad1d124a6aa17dc10";
const HOST_IDENTIFIER: &str = "com.elamin.AudioStreamer.CaptureServer";
const TEAM_ID: &str = "MSMG8CJLB3";
const HOST_RENDEZVOUS_URL: &str = "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev";
const HOST_ARGUMENTS: [&str; 7] = [
    "--worldwide",
    "--allow-remote-control",
    "--duration",
    "0",
    "--verbose",
    "--rendezvous-url",
    HOST_RENDEZVOUS_URL,
];
const HOST_LOCK: &str = "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock";
const LSOF_SHA256: &str = "28c36d6b6dfcce1f544717b0d1961aa03441ee0a736fee3e1eaeb215c0fbff4c";
const LSOF_SIZE: u64 = 307_600;
const LSOF_FLAGS: u32 = 524_320;

const V8_POINTER: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v8";
const V8_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v8/paired-v8-update-1787440868-72401-446ca31d-a524-4c6f-a19c-f207e96d6eb9";
const V8_POINTER_SHA256: &str = "955c73ee07ee71b666c2200b273a5f285da493538aaa37062575c4510790dc3e";
const V8_POINTER_INODE: u64 = 28_002_132;
const V8_EVIDENCE_INODE: u64 = 27_998_097;
const V8_JOURNAL_SHA256: &str = "56354cb2ff7c02f33fdaa552965ee7eee916152a86f353f718834aae6a80b5af";
const V8_RESULT_SHA256: &str = "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
const V8_PROVENANCE_SHA256: &str =
    "c7aafb63c0f34ca2920dd277190bbb3d9f687fc9918e31cbf79077797d3cec0f";
const V8_SOURCE_TAR_SHA256: &str =
    "9a2450b240f6cfbd69287525a4a5f384eb0cd087aaf9d08ed5e2ad277781b4df";
const V8_BUILD_STDOUT_SHA256: &str =
    "008e6c805ad04b80bb3c7420004ecec02a732abeaa34393259947358970bfdbc";
const V8_BUILD_STDERR_SHA256: &str =
    "dde05711598492e58c2d4a0680657773a682c81e1ac72f47eae85f57b6b07477";
const V8_INSTALL_HOLD_NAME_SHA256: &str =
    "ff6032f897db0c43e16dabf368fff2a3cc9643d13d2fb2f2ca069c0b2fa17542";
const V8_ROLLBACK_RESERVE_INODE: u64 = 28_002_131;

const LEGACY_EXECUTABLE: &str = "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer";
const LEGACY_PLIST: &str =
    "/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist";
const LEGACY_LABEL: &str = "com.elamin.audiostreamer.worldwide";
const LEGACY_EXECUTABLE_SHA256: &str =
    "1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc";
const LEGACY_EXECUTABLE_SIZE: u64 = 4_531_808;
const LEGACY_EXECUTABLE_GROUP: u32 = 80;
const LEGACY_PLIST_SHA256: &str =
    "419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730";
const LEGACY_PLIST_SIZE: u64 = 933;

const PAIRING_SERVICE: &str = "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1";
const PAIRING_ACCOUNTS: [&str; 2] = ["worldwide-host-identity-v1", "worldwide-paired-viewer-v1"];

const PRODUCT_DRIVER: &str = "/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver";
const DRIVER_IDENTIFIER: &str = "com.elamin.opensteamer.VirtualMicrophoneDriver";
const INSTALLED_DRIVER_TREE_SHA256: &str =
    "f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49";
const INSTALLED_DRIVER_EXECUTABLE_SHA256: &str =
    "ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866";
const INSTALLED_DRIVER_DEVICE: u64 = 16_777_229;
const INSTALLED_DRIVER_INODE: u64 = 27_877_539;

const CANDIDATE_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v9/production-driver-v7";
const CANDIDATE_DRIVER: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v9/production-driver-v7/OpensteamerVirtualMicrophone.driver";
const CANDIDATE_PACKAGE: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v9/production-driver-v7/OpensteamerVirtualMicrophone-v7.pkg";
const CANDIDATE_MANIFEST: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v9/production-driver-v7/candidate-manifest.txt";
const CANDIDATE_MANIFEST_SHA256: &str =
    "c37c82d8d4e62e387aadc556d0073fad80c752d96040bc2215e6088d8620c93a";
const CANDIDATE_DRIVER_TREE_SHA256: &str =
    "84bfc68a9bf808936e60c80dbd8a02f601f54fe248c3f1f8de0b095142401dba";
const CANDIDATE_DRIVER_EXECUTABLE_SHA256: &str =
    "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d";
const CANDIDATE_PACKAGE_SHA256: &str =
    "9f801306c944d2ea021fd1e65650714dd3c0c788e3b521dc927875dd9c3f004d";
const CANDIDATE_CODE_RESOURCES_SHA256: &str =
    "92c1b53f174dd64d1835fa9b2ecbddd84eac815ad43bbe231090d214b1cc9731";
const CANDIDATE_INFO_PLIST_SHA256: &str =
    "6e2fa0980cd27498ffe1075bcd439e61fcb0b6d38827ca2dadc3a7d6872e84e1";
const CANDIDATE_LICENSE_SHA256: &str =
    "63202ae6ab294069b6f77114f0cce8f35531bbb75355f1d96c8db68f949acdc5";
const CANDIDATE_LOCALIZABLE_SHA256: &str =
    "4798181065dbb851f0de518be396d6d4f8a465158923adf16bbf91bcb826a166";

const DIAGNOSTIC_READER_SHA256: &str =
    "6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded";
const PREBUILT_DIAGNOSTIC_READER: &str =
    "/Volumes/t7/opensteamer-diagnostic-driver-v1-build/opensteamer-diagnostic-snapshot-reader";
const DIAGNOSTIC_READER_BUILDER_RELATIVE: &str =
    "macOS/VirtualAudioDriver/scripts/build-diagnostic-snapshot-reader.sh";
const DIAGNOSTIC_READER_BUILDER_SHA256: &str =
    "c3618cd5b7a90fcdb33f615bd06b8092dd2aff519d1546066a2689e4a779b868";
const DIAGNOSTIC_READER_SOURCE_RELATIVE: &str =
    "macOS/VirtualAudioDriver/Probes/DiagnosticSnapshotReader.c";
const DIAGNOSTIC_READER_SOURCE_SHA256: &str =
    "7ac0469c8494f723bcac39f77126639f5ddc8122525029a9ed4a4af79d65f9c1";
const DIAGNOSTIC_DRIVER_HEADER_RELATIVE: &str =
    "macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h";
const DIAGNOSTIC_DRIVER_HEADER_SHA256: &str =
    "3009e32be6f72614ab79ce51af10d42e1e89955ece1532298d4dbb16c177f0e5";
const DIAGNOSTIC_CORE_HEADER_RELATIVE: &str =
    "macOS/VirtualAudioDriver/include/OpensteamerVirtualAudioCore.h";
const DIAGNOSTIC_CORE_HEADER_SHA256: &str =
    "b294aa19086794b11bf4c1cf1e65062c88eed7788274e637e8de5a67e5d7203b";
const BOTH_ORDER_PROBE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-4-1787410812-36567-22c759df-9572-48b8-99f9-49cd96467e1f/probes/physical-virtual-microphone-probe";
const BOTH_ORDER_PROBE_SHA256: &str =
    "b344eb24cde4ab1881b065e2ef0aa208aef12dbdd31fea7259eabc5ad5b6abaf";
const DIAGNOSTIC_READER_SIZE: u64 = 118_832;
const BOTH_ORDER_PROBE_SIZE: u64 = 1_096_944;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum UpdateState {
    Begun,
    Authenticated,
    PrestopAborted,
    HostStopInitiated,
    HostStopped,
    PriorDriverRetained,
    CandidatePublished,
    CoreAudioReloaded,
    DriverValidated,
    HostBootstrapped,
    ReadyVerified,
    Committed,
    RollbackStarted,
    FailedDriverArchived,
    PriorDriverRestored,
    RollbackCoreAudioReloadInitiated,
    RollbackCoreAudioReloaded,
    HostRebootstrapped,
    RolledBack,
    CriticalFailure,
}

impl UpdateState {
    fn token(self) -> &'static str {
        match self {
            Self::Begun => "BEGUN",
            Self::Authenticated => "AUTHENTICATED",
            Self::PrestopAborted => "PRESTOP_ABORTED",
            Self::HostStopInitiated => "HOST_STOP_INITIATED",
            Self::HostStopped => "HOST_STOPPED",
            Self::PriorDriverRetained => "PRIOR_DRIVER_RETAINED",
            Self::CandidatePublished => "CANDIDATE_PUBLISHED",
            Self::CoreAudioReloaded => "COREAUDIO_RELOADED",
            Self::DriverValidated => "DRIVER_VALIDATED",
            Self::HostBootstrapped => "HOST_BOOTSTRAPPED",
            Self::ReadyVerified => "READY_VERIFIED",
            Self::Committed => "COMMITTED",
            Self::RollbackStarted => "ROLLBACK_STARTED",
            Self::FailedDriverArchived => "FAILED_DRIVER_ARCHIVED",
            Self::PriorDriverRestored => "PRIOR_DRIVER_RESTORED",
            Self::RollbackCoreAudioReloadInitiated => "ROLLBACK_COREAUDIO_RELOAD_INITIATED",
            Self::RollbackCoreAudioReloaded => "ROLLBACK_COREAUDIO_RELOADED",
            Self::HostRebootstrapped => "HOST_REBOOTSTRAPPED",
            Self::RolledBack => "ROLLED_BACK",
            Self::CriticalFailure => "CRITICAL_FAILURE",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "BEGUN" => Self::Begun,
            "AUTHENTICATED" => Self::Authenticated,
            "PRESTOP_ABORTED" => Self::PrestopAborted,
            "HOST_STOP_INITIATED" => Self::HostStopInitiated,
            "HOST_STOPPED" => Self::HostStopped,
            "PRIOR_DRIVER_RETAINED" => Self::PriorDriverRetained,
            "CANDIDATE_PUBLISHED" => Self::CandidatePublished,
            "COREAUDIO_RELOADED" => Self::CoreAudioReloaded,
            "DRIVER_VALIDATED" => Self::DriverValidated,
            "HOST_BOOTSTRAPPED" => Self::HostBootstrapped,
            "READY_VERIFIED" => Self::ReadyVerified,
            "COMMITTED" => Self::Committed,
            "ROLLBACK_STARTED" => Self::RollbackStarted,
            "FAILED_DRIVER_ARCHIVED" => Self::FailedDriverArchived,
            "PRIOR_DRIVER_RESTORED" => Self::PriorDriverRestored,
            "ROLLBACK_COREAUDIO_RELOAD_INITIATED" => Self::RollbackCoreAudioReloadInitiated,
            "ROLLBACK_COREAUDIO_RELOADED" => Self::RollbackCoreAudioReloaded,
            "HOST_REBOOTSTRAPPED" => Self::HostRebootstrapped,
            "ROLLED_BACK" => Self::RolledBack,
            "CRITICAL_FAILURE" => Self::CriticalFailure,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HostGeneration {
    pid: u32,
    runs: u64,
    process_start: String,
    nonce: String,
    lock_device: u64,
    lock_inode: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CoreAudioGeneration {
    pid: u32,
    runs: u64,
    process_start: String,
}

#[derive(Clone, Debug)]
struct UserLayout {
    evidence: PathBuf,
    journal: PathBuf,
    result: PathBuf,
    request: PathBuf,
    reader: PathBuf,
}

#[derive(Clone, Debug)]
struct RootLayout {
    root: PathBuf,
    journal: PathBuf,
    result: PathBuf,
    prior_driver: PathBuf,
    candidate_stage: PathBuf,
    failed_driver: PathBuf,
    rollback_reserve: PathBuf,
    state: PathBuf,
    recovery_request: PathBuf,
    recovery_result: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RollbackReserve {
    device: u64,
    inode: u64,
    released: bool,
}

fn rollback_reserve_released(length: u64, allocated: u64) -> Result<bool> {
    if length == 0 {
        if allocated == 0 {
            Ok(true)
        } else {
            Err(ControllerError(
                "zero-length rollback reserve still owns allocated blocks".to_owned(),
            ))
        }
    } else if length == ROLLBACK_RESERVE_BYTES && allocated >= ROLLBACK_RESERVE_BYTES {
        Ok(false)
    } else {
        Err(ControllerError(
            "rollback reserve is partial or sparse".to_owned(),
        ))
    }
}

fn prestop_headroom_is_sufficient(available: u64, reserve_allocated: bool) -> bool {
    let required = if reserve_allocated {
        MINIMUM_PRESTOP_AVAILABLE_BYTES
    } else {
        MINIMUM_PRESTOP_AVAILABLE_BYTES.saturating_add(ROLLBACK_RESERVE_BYTES)
    };
    available >= required
}

#[derive(Clone, Debug)]
struct RootRequest {
    nonce: String,
    evidence: PathBuf,
    controller_sha256: String,
    root_controller: PathBuf,
    reader_sha256: String,
    authorized_commit: String,
    authorized_tree: String,
}

fn main() -> ExitCode {
    match real_main() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("opensteamer diagnostic-driver updater: {error}");
            ExitCode::from(1)
        }
    }
}

fn real_main() -> Result<()> {
    // Every child and create-new publication inherits the same restrictive
    // mask even when sudo policy supplies a different target-user umask.
    unsafe { umask(0o077) };
    let arguments = env::args().collect::<Vec<_>>();
    match arguments.as_slice() {
        [_, mode] if mode == SELF_TEST_MODE => self_test(),
        [_, mode, repo] if mode == PREFLIGHT_MODE => preflight(Path::new(repo)),
        [_, mode, repo, commit, tree] if mode == EXECUTE_MODE => {
            execute_authorized_update(Path::new(repo), commit, tree)
        }
        [_, mode, repo] if mode == ROLLBACK_MODE => {
            rollback_authorized_update(Path::new(repo))
        }
        [_, mode, request] if mode == ROOT_MODE => {
            root_authorized_update(Path::new(request))
        }
        [_, mode, request] if mode == ROOT_ROLLBACK_MODE => {
            root_rollback_authorized_update(Path::new(request))
        }
        [_, mode] if mode == ROOT_SEALED_ROLLBACK_MODE => {
            root_sealed_rollback_authorized_update()
        }
        [_, mode, pid, device, inode] if mode == LOCK_PROBE_MODE => {
            let pid = parse_positive_u32(pid, "host lock PID")?;
            require_canonical_positive_decimal(device, "host lock device")?;
            require_canonical_positive_decimal(inode, "host lock inode")?;
            prove_lock_held_by_local(pid, device.parse().unwrap(), inode.parse().unwrap())?;
            println!("lock_holder={pid}");
            Ok(())
        }
        [_, mode, device, inode] if mode == LOCK_FREE_PROBE_MODE => {
            require_canonical_positive_decimal(device, "host lock device")?;
            require_canonical_positive_decimal(inode, "host lock inode")?;
            prove_lock_free_local(device.parse().unwrap(), inode.parse().unwrap())?;
            println!("lock_free={device}:{inode}");
            Ok(())
        }
        [_, mode, pid] if mode == LOCK_RECORD_PROBE_MODE => {
            let pid = parse_positive_u32(pid, "host lock PID")?;
            let (device, inode, nonce) = read_generation_lock_local(pid)?;
            println!("generation_lock={device}:{inode}:{nonce}");
            Ok(())
        }
        [_, mode, path, file_mode, group, size, digest] if mode == UID501_PINNED_READ_MODE => {
            let file_mode = file_mode
                .parse::<u32>()
                .map_err(|_| ControllerError("UID501 helper mode is malformed".to_owned()))?;
            let group = group
                .parse::<u32>()
                .map_err(|_| ControllerError("UID501 helper group is malformed".to_owned()))?;
            let size = size
                .parse::<u64>()
                .map_err(|_| ControllerError("UID501 helper size is malformed".to_owned()))?;
            uid501_openat_read_helper(Path::new(path), file_mode, group, size, Some(digest))
        }
        [_, mode, path, file_mode, group, maximum] if mode == UID501_GENERATED_READ_MODE => {
            let file_mode = file_mode
                .parse::<u32>()
                .map_err(|_| ControllerError("UID501 helper mode is malformed".to_owned()))?;
            let group = group
                .parse::<u32>()
                .map_err(|_| ControllerError("UID501 helper group is malformed".to_owned()))?;
            let maximum = maximum
                .parse::<u64>()
                .map_err(|_| ControllerError("UID501 helper bound is malformed".to_owned()))?;
            uid501_openat_read_helper(Path::new(path), file_mode, group, maximum, None)
        }
        [_, mode] if mode == UID501_HOST_MANIFEST_MODE => uid501_host_bundle_manifest_helper(),
        _ => Err(ControllerError(format!(
            "usage: controller {PREFLIGHT_MODE} {EXPECTED_REPO} | {EXECUTE_MODE} {EXPECTED_REPO} <commit> <tree> | {ROLLBACK_MODE} {EXPECTED_REPO} | {SELF_TEST_MODE}"
        ))),
    }
}

fn parse_positive_u32(value: &str, label: &str) -> Result<u32> {
    let parsed = value
        .parse::<u32>()
        .map_err(|_| ControllerError(format!("{label} is not an unsigned integer")))?;
    if parsed == 0 || parsed.to_string() != value {
        return Err(ControllerError(format!(
            "{label} is not canonical and positive"
        )));
    }
    Ok(parsed)
}

fn require_lower_hex(value: &str, length: usize, label: &str) -> Result<()> {
    if value.len() != length
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(ControllerError(format!(
            "{label} is not canonical lowercase hex"
        )));
    }
    Ok(())
}

fn path_text(path: &Path) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| ControllerError(format!("path is not UTF-8: {}", path.display())))
}

fn read_pipe_bounded(mut pipe: impl Read, maximum: usize) -> std::io::Result<(Vec<u8>, bool)> {
    let mut bytes = Vec::new();
    let mut exceeded = false;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = pipe.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        if bytes.len().saturating_add(count) <= maximum {
            bytes.extend_from_slice(&buffer[..count]);
        } else {
            exceeded = true;
        }
    }
    Ok((bytes, exceeded))
}

fn bounded_output(
    program: &str,
    arguments: &[&str],
    timeout: Duration,
    run_as_user: bool,
) -> Result<Output> {
    bounded_output_in_directory(program, arguments, timeout, run_as_user, Path::new("/"))
}

fn bounded_output_in_directory(
    program: &str,
    arguments: &[&str],
    timeout: Duration,
    run_as_user: bool,
    current_directory: &Path,
) -> Result<Output> {
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut held_directory = None;
    if run_as_user && unsafe { geteuid() } == ROOT_ID {
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            .open(current_directory)?;
        let directory_descriptor = directory.as_raw_fd();
        unsafe {
            command.pre_exec(move || {
                let groups = [USER_GROUP];
                if fchdir(directory_descriptor) != 0
                    || setgroups(1, groups.as_ptr()) != 0
                    || setgid(USER_GROUP) != 0
                    || setuid(USER_ID) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        held_directory = Some(directory);
    } else {
        command.current_dir(current_directory);
    }
    let mut child = command
        .spawn()
        .map_err(|error| ControllerError(format!("cannot execute {program}: {error}")))?;
    drop(held_directory);
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ControllerError(format!("{program} stdout pipe is unavailable")))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| ControllerError(format!("{program} stderr pipe is unavailable")))?;
    let stdout_reader = thread::spawn(move || read_pipe_bounded(stdout, MAX_OUTPUT_BYTES));
    let stderr_reader = thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES));
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| ControllerError("child deadline overflowed".to_owned()))?;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(ControllerError(format!(
                "{program} exceeded its bounded deadline"
            )));
        }
        thread::sleep(Duration::from_millis(20));
    };
    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| ControllerError(format!("{program} stdout reader panicked")))??;
    let (stderr, stderr_exceeded) = stderr_reader
        .join()
        .map_err(|_| ControllerError(format!("{program} stderr reader panicked")))??;
    if stdout_exceeded || stderr_exceeded {
        return Err(ControllerError(format!(
            "{program} output exceeded its bound"
        )));
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn bounded_null_status(
    program: &str,
    arguments: &[&str],
    timeout: Duration,
    run_as_user: bool,
) -> Result<std::process::ExitStatus> {
    let mut command = Command::new(program);
    command
        .args(arguments)
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if run_as_user && unsafe { geteuid() } == ROOT_ID {
        unsafe {
            command.pre_exec(|| {
                let groups = [USER_GROUP];
                if setgroups(1, groups.as_ptr()) != 0
                    || setgid(USER_GROUP) != 0
                    || setuid(USER_ID) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    let mut child = command.spawn()?;
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| ControllerError("null child deadline overflowed".to_owned()))?;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ControllerError(format!(
                "{program} exceeded its bounded deadline"
            )));
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn require_success(output: &Output, label: &str) -> Result<()> {
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(ControllerError(format!(
            "{label} failed with {:?}: {}",
            output.status.code(),
            stderr.trim_end()
        )));
    }
    Ok(())
}

fn command_line(program: &str, arguments: &[&str], label: &str) -> Result<String> {
    let output = bounded_output(program, arguments, COMMAND_TIMEOUT, false)?;
    require_success(&output, label)?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(format!("{label} wrote unexpected stderr")));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError(format!("{label} output is not UTF-8")))?;
    Ok(text.trim_end_matches(['\r', '\n']).to_owned())
}

fn sha256(path: &Path) -> Result<String> {
    let output = bounded_output(
        "/usr/bin/shasum",
        &["-a", "256", path_text(path)?],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "SHA-256")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError("shasum wrote unexpected stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("shasum output is not UTF-8".to_owned()))?;
    let digest = text
        .split_ascii_whitespace()
        .next()
        .ok_or_else(|| ControllerError("shasum output is empty".to_owned()))?;
    require_lower_hex(digest, 64, "SHA-256")?;
    Ok(digest.to_owned())
}

fn require_regular(path: &Path, uid: u32, gid: u32, mode: u32) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != uid
        || metadata.gid() != gid
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o7777 != mode
        || metadata.st_flags() != 0
    {
        return Err(ControllerError(format!(
            "regular-file metadata is unsafe: {}",
            path.display()
        )));
    }
    Ok(metadata)
}

fn require_directory(path: &Path, uid: u32, gid: u32, mode: u32) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != uid
        || metadata.gid() != gid
        || metadata.permissions().mode() & 0o7777 != mode
        || metadata.st_flags() != 0
    {
        return Err(ControllerError(format!(
            "directory metadata is unsafe: {}",
            path.display()
        )));
    }
    Ok(metadata)
}

fn ls_mode_has_forbidden_extended_metadata(mode: &str) -> bool {
    mode.ends_with('+') || mode.ends_with('@')
}

fn require_no_acl_or_xattrs(path: &Path) -> Result<()> {
    // POSIX_ACL_FORBIDDEN: every sealed or published node must have neither an ACL nor xattrs.
    let output = bounded_output(
        "/bin/ls",
        &["-lde@", path_text(path)?],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "inspect ACL/extended metadata")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "ACL/extended-metadata probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("ACL/extended-metadata output is not UTF-8".to_owned()))?;
    let lines = text.lines().collect::<Vec<_>>();
    let mode = lines
        .first()
        .and_then(|line| line.split_ascii_whitespace().next())
        .ok_or_else(|| ControllerError("ACL/extended-metadata output is empty".to_owned()))?;
    if lines.len() != 1 || ls_mode_has_forbidden_extended_metadata(mode) {
        return Err(ControllerError(format!(
            "ACL or extended metadata is forbidden: {}",
            path.display()
        )));
    }
    let xattrs = bounded_output(
        "/usr/bin/xattr",
        &[path_text(path)?],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&xattrs, "inspect node xattrs")?;
    if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
        return Err(ControllerError(format!(
            "node has forbidden extended attributes: {}",
            path.display()
        )));
    }
    Ok(())
}

fn require_sealed_regular(path: &Path, mode: u32) -> Result<fs::Metadata> {
    let metadata = require_regular(path, ROOT_ID, ROOT_ID, mode)?;
    require_no_acl_or_xattrs(path)?;
    Ok(metadata)
}

fn require_sealed_directory(path: &Path, mode: u32) -> Result<fs::Metadata> {
    let metadata = require_directory(path, ROOT_ID, ROOT_ID, mode)?;
    require_no_acl_or_xattrs(path)?;
    Ok(metadata)
}

// ROOT_ANCESTRY_ACL_XATTR_SEAL: every root-owned ancestor is immutable by
// identity and carries neither an inherited ACL nor an extended attribute.
#[derive(Clone, Debug, Eq, PartialEq)]
struct RootDirectoryIdentity {
    device: u64,
    inode: u64,
    uid: u32,
    gid: u32,
    mode: u32,
    flags: u32,
}

fn root_directory_identity(path: &Path, mode: u32) -> Result<RootDirectoryIdentity> {
    let metadata = require_sealed_directory(path, mode)?;
    Ok(RootDirectoryIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        uid: metadata.uid(),
        gid: metadata.gid(),
        mode: metadata.permissions().mode() & 0o7777,
        flags: metadata.st_flags(),
    })
}

fn require_root_directory_identity(
    path: &Path,
    mode: u32,
    expected: &RootDirectoryIdentity,
) -> Result<()> {
    if &root_directory_identity(path, mode)? != expected {
        return Err(ControllerError(format!(
            "sealed root directory identity changed: {}",
            path.display()
        )));
    }
    Ok(())
}

fn capture_root_transaction_ancestry(
    layout: &RootLayout,
    request: &RootRequest,
    probe_directory: Option<&Path>,
) -> Result<Vec<(PathBuf, u32, RootDirectoryIdentity)>> {
    let controller_support = request.root_controller.parent().ok_or_else(|| {
        ControllerError("root controller has no sealed support directory".to_owned())
    })?;
    let mut paths = vec![
        (PathBuf::from(ROOT_SUPPORT), 0o755),
        (
            PathBuf::from(ROOT_CONTROLLER_PARENT),
            ROOT_SEALED_TRAVERSE_MODE,
        ),
        (controller_support.to_path_buf(), ROOT_SEALED_TRAVERSE_MODE),
        (PathBuf::from(ROOT_UPDATE_ROOT), ROOT_PRIVATE_MODE),
        (layout.root.clone(), ROOT_PRIVATE_MODE),
        (
            layout.prior_driver.parent().unwrap().to_path_buf(),
            ROOT_PRIVATE_MODE,
        ),
        (
            layout.candidate_stage.parent().unwrap().to_path_buf(),
            ROOT_PRIVATE_MODE,
        ),
        (
            layout.failed_driver.parent().unwrap().to_path_buf(),
            ROOT_PRIVATE_MODE,
        ),
        (layout.root.join("probes"), ROOT_PRIVATE_MODE),
    ];
    if Path::new(ROOT_PROBE_PARENT).exists() {
        paths.push((PathBuf::from(ROOT_PROBE_PARENT), ROOT_SEALED_TRAVERSE_MODE));
    }
    if let Some(probe_directory) = probe_directory {
        paths.push((probe_directory.to_path_buf(), ROOT_SEALED_TRAVERSE_MODE));
    }
    let support_device = root_directory_identity(Path::new(ROOT_SUPPORT), 0o755)?.device;
    let mut captured = Vec::with_capacity(paths.len());
    for (path, mode) in paths {
        let identity = root_directory_identity(&path, mode)?;
        if identity.device != support_device {
            return Err(ControllerError(format!(
                "sealed root directory escaped the support filesystem: {}",
                path.display()
            )));
        }
        captured.push((path, mode, identity));
    }
    Ok(captured)
}

fn revalidate_root_transaction_ancestry(
    captured: &[(PathBuf, u32, RootDirectoryIdentity)],
) -> Result<()> {
    for (path, mode, identity) in captured {
        require_root_directory_identity(path, *mode, identity)?;
    }
    Ok(())
}

fn require_absent(path: &Path, label: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
        Ok(_) => Err(ControllerError(format!(
            "{label} already exists: {}",
            path.display()
        ))),
    }
}

fn exact_child_names(path: &Path) -> Result<Vec<String>> {
    let mut children = fs::read_dir(path)?
        .map(|entry| {
            entry.and_then(|entry| {
                entry.file_name().into_string().map_err(|_| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, "non-UTF-8 child")
                })
            })
        })
        .collect::<std::io::Result<Vec<_>>>()?;
    children.sort();
    Ok(children)
}

fn require_exact_child_names(path: &Path, expected: &[&str], label: &str) -> Result<()> {
    let mut expected = expected
        .iter()
        .map(|value| (*value).to_owned())
        .collect::<Vec<_>>();
    expected.sort();
    if exact_child_names(path)? != expected {
        return Err(ControllerError(format!("{label} child set is not exact")));
    }
    Ok(())
}

fn fsync_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| ControllerError(format!("path has no parent: {}", path.display())))?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn read_bounded(path: &Path, maximum: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > maximum
    {
        return Err(ControllerError(format!(
            "bounded read refused {}",
            path.display()
        )));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)?;
    let before = file.metadata()?;
    let mut bytes = Vec::with_capacity(before.len() as usize);
    Read::by_ref(&mut file)
        .take(maximum + 1)
        .read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    let named = fs::symlink_metadata(path)?;
    if bytes.len() as u64 != before.len()
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.dev() != named.dev()
        || before.ino() != named.ino()
        || before.len() != named.len()
    {
        return Err(ControllerError(format!(
            "file changed during read: {}",
            path.display()
        )));
    }
    Ok(bytes)
}

fn read_bounded_utf8(path: &Path, maximum: u64) -> Result<String> {
    String::from_utf8(read_bounded(path, maximum)?)
        .map_err(|_| ControllerError(format!("file is not UTF-8: {}", path.display())))
}

fn create_private_file(path: &Path, uid: u32, gid: u32, mode: u32) -> Result<File> {
    let file = OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .mode(mode)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if metadata.uid() != uid
        || metadata.gid() != gid
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o7777 != mode
    {
        return Err(ControllerError(format!(
            "created file is unsafe: {}",
            path.display()
        )));
    }
    Ok(file)
}

fn write_new_private(path: &Path, bytes: &[u8], uid: u32, gid: u32, mode: u32) -> Result<()> {
    let mut file = create_private_file(path, uid, gid, mode)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fsync_parent(path)
}

fn random_nonce() -> Result<String> {
    let mut bytes = [0_u8; 16];
    OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open("/dev/urandom")?
        .read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn validate_nonce(nonce: &str) -> Result<()> {
    require_lower_hex(nonce, 32, "transaction nonce")
}

fn sha256_bytes(bytes: &[u8]) -> Result<String> {
    let mut child = Command::new("/usr/bin/shasum")
        .args(["-a", "256"])
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| ControllerError("shasum stdin is unavailable".to_owned()))?
        .write_all(bytes)?;
    let output = child.wait_with_output()?;
    require_success(&output, "hash bounded manifest")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError("manifest shasum wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("manifest shasum output is not UTF-8".to_owned()))?;
    let digest = text
        .split_ascii_whitespace()
        .next()
        .ok_or_else(|| ControllerError("manifest shasum output is empty".to_owned()))?;
    require_lower_hex(digest, 64, "manifest SHA-256")?;
    Ok(digest.to_owned())
}

fn verify_driver_bundle(
    bundle: &Path,
    expected_uid: u32,
    expected_gid: u32,
    expected_tree: &str,
    expected_executable: &str,
) -> Result<()> {
    let expected = [
        (".", "directory", 0o755),
        ("Contents", "directory", 0o755),
        ("Contents/Info.plist", "file", 0o644),
        ("Contents/MacOS", "directory", 0o755),
        ("Contents/MacOS/OpensteamerVirtualMicrophone", "file", 0o755),
        ("Contents/Resources", "directory", 0o755),
        ("Contents/Resources/APPLE_SAMPLE_LICENSE.txt", "file", 0o644),
        ("Contents/Resources/en.lproj", "directory", 0o755),
        (
            "Contents/Resources/en.lproj/Localizable.strings",
            "file",
            0o644,
        ),
        ("Contents/_CodeSignature", "directory", 0o755),
        ("Contents/_CodeSignature/CodeResources", "file", 0o644),
    ];
    fn walk(
        root: &Path,
        relative: &Path,
        uid: u32,
        gid: u32,
        output: &mut Vec<(String, String, u32)>,
    ) -> Result<()> {
        let absolute = if relative.as_os_str().is_empty() {
            root.to_path_buf()
        } else {
            root.join(relative)
        };
        let metadata = fs::symlink_metadata(&absolute)?;
        if metadata.file_type().is_symlink()
            || metadata.uid() != uid
            || metadata.gid() != gid
            || metadata.st_flags() != 0
            || (metadata.file_type().is_file() && metadata.nlink() != 1)
        {
            return Err(ControllerError(format!(
                "driver node ownership/link contract changed: {}",
                absolute.display()
            )));
        }
        require_no_acl_or_xattrs(&absolute)?;
        let kind = if metadata.file_type().is_dir() {
            "directory"
        } else if metadata.file_type().is_file() {
            "file"
        } else {
            "unexpected"
        };
        let display = if relative.as_os_str().is_empty() {
            ".".to_owned()
        } else {
            path_text(relative)?.to_owned()
        };
        output.push((
            display,
            kind.to_owned(),
            metadata.permissions().mode() & 0o777,
        ));
        if metadata.file_type().is_dir() {
            let mut children = fs::read_dir(&absolute)?
                .map(|entry| entry.map(|entry| entry.file_name()))
                .collect::<std::io::Result<Vec<_>>>()?;
            children.sort();
            for child in children {
                walk(root, &relative.join(child), uid, gid, output)?;
            }
        }
        Ok(())
    }
    let mut actual = Vec::new();
    walk(
        bundle,
        Path::new(""),
        expected_uid,
        expected_gid,
        &mut actual,
    )?;
    let expected = expected
        .iter()
        .map(|(path, kind, mode)| (path.to_string(), kind.to_string(), *mode))
        .collect::<Vec<_>>();
    if actual != expected {
        return Err(ControllerError(
            "driver lstat manifest is not exact".to_owned(),
        ));
    }
    let mut manifest = Vec::new();
    for (path, kind, mode) in &actual {
        let type_name = if kind == "directory" {
            "Directory"
        } else {
            "Regular File"
        };
        write!(manifest, "{type_name}|{:o}|{path}\0", mode)?;
    }
    for relative in [
        "Contents/Info.plist",
        "Contents/MacOS/OpensteamerVirtualMicrophone",
        "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
        "Contents/Resources/en.lproj/Localizable.strings",
        "Contents/_CodeSignature/CodeResources",
    ] {
        write!(
            manifest,
            "{relative}\0{}\0",
            sha256(&bundle.join(relative))?
        )?;
    }
    if sha256_bytes(&manifest)? != expected_tree {
        return Err(ControllerError(
            "driver tree hash differs from its pin".to_owned(),
        ));
    }
    let executable = bundle.join("Contents/MacOS/OpensteamerVirtualMicrophone");
    if sha256(&executable)? != expected_executable {
        return Err(ControllerError(
            "driver executable differs from its pin".to_owned(),
        ));
    }
    let xattrs = bounded_output(
        "/usr/bin/xattr",
        &["-lr", path_text(bundle)?],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&xattrs, "inspect driver xattrs")?;
    if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
        return Err(ControllerError(
            "driver contains extended attributes".to_owned(),
        ));
    }
    let architectures = command_line(
        "/usr/bin/lipo",
        &["-archs", path_text(&executable)?],
        "inspect driver architectures",
    )?;
    let mut architectures = architectures.split_ascii_whitespace().collect::<Vec<_>>();
    architectures.sort_unstable();
    if architectures != ["arm64", "x86_64"] {
        return Err(ControllerError(
            "driver architecture set is not exact".to_owned(),
        ));
    }
    let signature = bounded_output(
        "/usr/bin/codesign",
        &[
            "--verify",
            "--strict",
            "--all-architectures",
            path_text(bundle)?,
        ],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&signature, "verify driver signature")?;
    for architecture in ["arm64", "x86_64"] {
        let details = bounded_output(
            "/usr/bin/codesign",
            &["-d", "-a", architecture, "--verbose=4", path_text(bundle)?],
            COMMAND_TIMEOUT,
            false,
        )?;
        require_success(&details, "inspect driver signature")?;
        let text = String::from_utf8(details.stderr)
            .map_err(|_| ControllerError("driver codesign output is not UTF-8".to_owned()))?;
        if !text.contains(&format!("Identifier={DRIVER_IDENTIFIER}\n"))
            || !text.contains(&format!("TeamIdentifier={TEAM_ID}\n"))
            || !text.contains("Authority=Developer ID Application:")
            || !text.contains("flags=0x10000(runtime)")
            || !text.contains("Timestamp=")
            || text.contains("Timestamp=none")
        {
            return Err(ControllerError(format!(
                "{architecture} driver signing contract is not exact"
            )));
        }
    }
    Ok(())
}

fn verify_candidate() -> Result<()> {
    require_directory(Path::new(CANDIDATE_ROOT), USER_ID, USER_GROUP, 0o500)?;
    require_regular(Path::new(CANDIDATE_MANIFEST), USER_ID, USER_GROUP, 0o400)?;
    require_regular(Path::new(CANDIDATE_PACKAGE), USER_ID, USER_GROUP, 0o600)?;
    if sha256(Path::new(CANDIDATE_MANIFEST))? != CANDIDATE_MANIFEST_SHA256
        || sha256(Path::new(CANDIDATE_PACKAGE))? != CANDIDATE_PACKAGE_SHA256
    {
        return Err(ControllerError(
            "reviewed candidate manifest/package changed".to_owned(),
        ));
    }
    let manifest = read_bounded_utf8(Path::new(CANDIDATE_MANIFEST), 4_096)?;
    let expected_lines = vec![
        "schema=opensteamer.production-driver-candidate.v7".to_owned(),
        format!("source_commit={EXPECTED_SOURCE_COMMIT}"),
        format!("source_tree={EXPECTED_SOURCE_TREE}"),
        "source_branch=main".to_owned(),
        format!("remote={EXPECTED_REMOTE}"),
        format!("bundle_tree_sha256={CANDIDATE_DRIVER_TREE_SHA256}"),
        format!("executable_sha256={CANDIDATE_DRIVER_EXECUTABLE_SHA256}"),
        format!("package_sha256={CANDIDATE_PACKAGE_SHA256}"),
    ];
    for expected in expected_lines {
        if manifest.lines().filter(|line| *line == expected).count() != 1 {
            return Err(ControllerError(format!(
                "candidate manifest lost exact record: {expected}"
            )));
        }
    }
    verify_driver_bundle(
        Path::new(CANDIDATE_DRIVER),
        USER_ID,
        USER_GROUP,
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )
}

fn verify_installed_v7_driver() -> Result<()> {
    verify_driver_bundle(
        Path::new(PRODUCT_DRIVER),
        ROOT_ID,
        ROOT_ID,
        INSTALLED_DRIVER_TREE_SHA256,
        INSTALLED_DRIVER_EXECUTABLE_SHA256,
    )?;
    let metadata = fs::symlink_metadata(PRODUCT_DRIVER)?;
    if metadata.dev() != INSTALLED_DRIVER_DEVICE || metadata.ino() != INSTALLED_DRIVER_INODE {
        return Err(ControllerError(
            "installed v7 driver outer inode changed".to_owned(),
        ));
    }
    Ok(())
}

fn compare_tree_metadata(left: &Path, right: &Path) -> Result<()> {
    fn walk(
        root: &Path,
        relative: &Path,
        output: &mut Vec<(Vec<u8>, u32, u32, u64, u32, u32, u64, u32, Vec<u8>)>,
    ) -> Result<()> {
        let path = if relative.as_os_str().is_empty() {
            root.to_path_buf()
        } else {
            root.join(relative)
        };
        let metadata = fs::symlink_metadata(&path)?;
        let kind = if metadata.file_type().is_dir() {
            1
        } else if metadata.file_type().is_file() {
            2
        } else if metadata.file_type().is_symlink() {
            3
        } else {
            return Err(ControllerError(format!(
                "unexpected app node: {}",
                path.display()
            )));
        };
        let link_target = if kind == 3 {
            fs::read_link(&path)?.as_os_str().as_bytes().to_vec()
        } else {
            Vec::new()
        };
        output.push((
            relative.as_os_str().as_bytes().to_vec(),
            kind,
            metadata.permissions().mode() & 0o7777,
            metadata.len(),
            metadata.uid(),
            metadata.gid(),
            metadata.nlink(),
            metadata.st_flags(),
            link_target,
        ));
        if kind == 1 {
            let mut children = fs::read_dir(&path)?
                .map(|entry| entry.map(|entry| entry.file_name()))
                .collect::<std::io::Result<Vec<_>>>()?;
            children.sort();
            for child in children {
                walk(root, &relative.join(child), output)?;
            }
        }
        Ok(())
    }
    let mut left_nodes = Vec::new();
    let mut right_nodes = Vec::new();
    walk(left, Path::new(""), &mut left_nodes)?;
    walk(right, Path::new(""), &mut right_nodes)?;
    if left_nodes != right_nodes {
        return Err(ControllerError(
            "v8 host tree metadata differs from reference".to_owned(),
        ));
    }
    for node in &left_nodes {
        if node.1 != 2 {
            continue;
        }
        let relative = Path::new(OsStr::from_bytes(&node.0));
        let left_file = left.join(relative);
        let right_file = right.join(relative);
        let comparison = bounded_output(
            "/usr/bin/cmp",
            &["-s", path_text(&left_file)?, path_text(&right_file)?],
            COMMAND_TIMEOUT,
            false,
        )?;
        require_success(&comparison, "compare exact v8 host file")?;
        if !comparison.stdout.is_empty() || !comparison.stderr.is_empty() {
            return Err(ControllerError(
                "v8 host file comparison emitted output".to_owned(),
            ));
        }
    }
    Ok(())
}

fn code_hash(bundle: &Path) -> Result<String> {
    let output = bounded_output(
        "/usr/bin/codesign",
        &["-d", "--verbose=4", path_text(bundle)?],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "inspect host code hash")?;
    let text = String::from_utf8(output.stderr)
        .map_err(|_| ControllerError("host codesign output is not UTF-8".to_owned()))?;
    if !text.contains(&format!("Identifier={HOST_IDENTIFIER}\n"))
        || !text.contains(&format!("TeamIdentifier={TEAM_ID}\n"))
    {
        return Err(ControllerError(
            "host codesign identifier/team changed".to_owned(),
        ));
    }
    let values = text
        .lines()
        .filter_map(|line| line.strip_prefix("CDHash="))
        .collect::<Vec<_>>();
    if values.len() != 1 {
        return Err(ControllerError(
            "host CDHash is missing or ambiguous".to_owned(),
        ));
    }
    let value = values[0].to_ascii_lowercase();
    require_lower_hex(&value, 40, "host CDHash")?;
    Ok(value)
}

fn verify_installed_v8_runtime_bytes() -> Result<()> {
    // The manifest is generated entirely through a dropped-UID, descriptor-bound
    // openat walk. It covers every bundle node, file hash, framework Mach-O,
    // signature/resource byte, symlink target, mode, size, inode, and xattr.
    verify_uid501_host_bundle_manifest()?;
    for (path, mode, size, digest) in [
        (
            PathBuf::from(HOST_EXECUTABLE),
            0o755,
            HOST_EXECUTABLE_SIZE,
            HOST_EXECUTABLE_SHA256,
        ),
        (
            Path::new(HOST_APP).join("Contents/Info.plist"),
            0o644,
            HOST_INFO_PLIST_SIZE,
            HOST_INFO_PLIST_SHA256,
        ),
        (
            PathBuf::from(HOST_PLIST),
            0o600,
            HOST_PLIST_SIZE,
            HOST_PLIST_SHA256,
        ),
    ] {
        let _bytes = read_uid501_openat_bytes(&path, mode, USER_GROUP, size, Some(digest))?;
    }
    Ok(())
}

fn verify_v8_evidence_and_host_bytes() -> Result<()> {
    if unsafe { getuid() } != USER_ID || unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "v8 user evidence verification requires exact UID501".to_owned(),
        ));
    }
    let pointer = require_regular(Path::new(V8_POINTER), USER_ID, USER_GROUP, 0o600)?;
    if pointer.ino() != V8_POINTER_INODE
        || sha256(Path::new(V8_POINTER))? != V8_POINTER_SHA256
        || read_bounded_utf8(Path::new(V8_POINTER), 512)? != format!("{V8_EVIDENCE}\n")
    {
        return Err(ControllerError("v8 active pointer changed".to_owned()));
    }
    let evidence = require_directory(Path::new(V8_EVIDENCE), USER_ID, USER_GROUP, 0o700)?;
    if evidence.ino() != V8_EVIDENCE_INODE {
        return Err(ControllerError("v8 evidence inode changed".to_owned()));
    }
    require_exact_child_names(
        Path::new(V8_EVIDENCE),
        &[
            "build.stderr",
            "build.stdout",
            "deployment-reference",
            "failed-new",
            "install-hold-name.txt",
            "journal.log",
            "provenance.txt",
            "result.txt",
            "rollback-current",
            "rollback-reserve.bin",
            "source-export",
            "source.tar",
            "staged-output",
            "swiftpm-scratch",
        ],
        "v8 evidence",
    )?;
    for (name, hash) in [
        ("journal.log", V8_JOURNAL_SHA256),
        ("result.txt", V8_RESULT_SHA256),
        ("provenance.txt", V8_PROVENANCE_SHA256),
        ("source.tar", V8_SOURCE_TAR_SHA256),
        ("build.stdout", V8_BUILD_STDOUT_SHA256),
        ("build.stderr", V8_BUILD_STDERR_SHA256),
        ("install-hold-name.txt", V8_INSTALL_HOLD_NAME_SHA256),
    ] {
        let path = Path::new(V8_EVIDENCE).join(name);
        require_regular(&path, USER_ID, USER_GROUP, 0o600)?;
        if sha256(&path)? != hash {
            return Err(ControllerError(format!("v8 evidence changed: {name}")));
        }
    }
    if read_bounded_utf8(&Path::new(V8_EVIDENCE).join("result.txt"), 128)? != "result=success\n" {
        return Err(ControllerError("v8 result is not exact success".to_owned()));
    }
    let reserve = require_regular(
        &Path::new(V8_EVIDENCE).join("rollback-reserve.bin"),
        USER_ID,
        USER_GROUP,
        0o600,
    )?;
    if reserve.ino() != V8_ROLLBACK_RESERVE_INODE || reserve.len() != 0 || reserve.blocks() != 0 {
        return Err(ControllerError(
            "v8 released rollback reserve changed".to_owned(),
        ));
    }
    require_regular(Path::new(HOST_EXECUTABLE), USER_ID, USER_GROUP, 0o755)?;
    require_regular(Path::new(HOST_PLIST), USER_ID, USER_GROUP, 0o600)?;
    if sha256(Path::new(HOST_EXECUTABLE))? != HOST_EXECUTABLE_SHA256
        || sha256(&Path::new(HOST_APP).join("Contents/Info.plist"))? != HOST_INFO_PLIST_SHA256
        || sha256(Path::new(HOST_PLIST))? != HOST_PLIST_SHA256
        || code_hash(Path::new(HOST_APP))? != HOST_CDHASH
    {
        return Err(ControllerError(
            "installed v8 host bytes or identity changed".to_owned(),
        ));
    }
    let signature = bounded_output(
        "/usr/bin/codesign",
        &[
            "--verify",
            "--deep",
            "--strict",
            path_text(Path::new(HOST_APP))?,
        ],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&signature, "verify installed v8 host signature")?;
    compare_tree_metadata(
        Path::new(HOST_APP),
        &Path::new(V8_EVIDENCE).join("deployment-reference/opensteamer Host.app"),
    )
}

fn launchctl_print(target: &str) -> Result<Output> {
    bounded_output("/bin/launchctl", &["print", target], COMMAND_TIMEOUT, false)
}

fn require_service_absent(label: &str) -> Result<()> {
    let target = format!("gui/{USER_ID}/{label}");
    let output = launchctl_print(&target)?;
    if output.status.code() != Some(113) || !output.stdout.is_empty() {
        return Err(ControllerError(format!(
            "launchd did not prove service absent: {label}"
        )));
    }
    let stderr = String::from_utf8(output.stderr)
        .map_err(|_| ControllerError("launchctl absence diagnostic is not UTF-8".to_owned()))?;
    let expected = format!(
        "Bad request.\nCould not find service \"{label}\" in domain for user gui: {USER_ID}\n"
    );
    if stderr != expected {
        return Err(ControllerError(format!(
            "launchctl absence diagnostic changed for {label}"
        )));
    }
    Ok(())
}

fn require_legacy_disabled_and_absent() -> Result<()> {
    let _legacy_executable = read_uid501_openat_bytes(
        Path::new(LEGACY_EXECUTABLE),
        0o755,
        LEGACY_EXECUTABLE_GROUP,
        LEGACY_EXECUTABLE_SIZE,
        Some(LEGACY_EXECUTABLE_SHA256),
    )?;
    let _legacy_plist = read_uid501_openat_bytes(
        Path::new(LEGACY_PLIST),
        0o600,
        USER_GROUP,
        LEGACY_PLIST_SIZE,
        Some(LEGACY_PLIST_SHA256),
    )?;
    require_service_absent(LEGACY_LABEL)?;
    let disabled = bounded_output(
        "/bin/launchctl",
        &["print-disabled", &format!("gui/{USER_ID}")],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&disabled, "inspect disabled launchd overrides")?;
    let text = String::from_utf8(disabled.stdout)
        .map_err(|_| ControllerError("launchctl disabled map is not UTF-8".to_owned()))?;
    let matching = text
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with(&format!("\"{LEGACY_LABEL}\" => ")))
        .collect::<Vec<_>>();
    if matching.len() != 1 || !(matching[0].ends_with("disabled") || matching[0].ends_with("true"))
    {
        return Err(ControllerError(
            "protected legacy launchd override is not exact disabled".to_owned(),
        ));
    }
    Ok(())
}

fn verify_pairing_metadata_only() -> Result<()> {
    for account in PAIRING_ACCOUNTS {
        let status = bounded_null_status(
            "/usr/bin/security",
            &[
                "find-generic-password",
                "-s",
                PAIRING_SERVICE,
                "-a",
                account,
            ],
            COMMAND_TIMEOUT,
            true,
        )?;
        if !status.success() {
            return Err(ControllerError(format!(
                "isolated pairing metadata is unavailable: {account}"
            )));
        }
    }
    Ok(())
}

fn process_start(pid: u32) -> Result<String> {
    let pid = pid.to_string();
    let output = bounded_output(
        "/bin/ps",
        &["-p", &pid, "-o", "lstart="],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "inspect process start")?;
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("process start is not UTF-8".to_owned()))?;
    let normalized = text.split_ascii_whitespace().collect::<Vec<_>>().join(" ");
    validate_process_start_identity(&normalized)?;
    Ok(normalized)
}

fn validate_process_start_identity(value: &str) -> Result<()> {
    let fields = value.split_ascii_whitespace().collect::<Vec<_>>();
    if fields.len() != 5 || fields.join(" ") != value {
        return Err(ControllerError(
            "process start identity is not exactly five normalized fields".to_owned(),
        ));
    }
    if !["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].contains(&fields[0])
        || ![
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        .contains(&fields[1])
    {
        return Err(ControllerError(
            "process start weekday/month is invalid".to_owned(),
        ));
    }
    let day = fields[2]
        .parse::<u8>()
        .map_err(|_| ControllerError("process start day is invalid".to_owned()))?;
    if !(1..=31).contains(&day) || day.to_string() != fields[2] {
        return Err(ControllerError(
            "process start day is not canonical".to_owned(),
        ));
    }
    let time = fields[3].split(':').collect::<Vec<_>>();
    if time.len() != 3
        || time
            .iter()
            .any(|field| field.len() != 2 || !field.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return Err(ControllerError("process start time is invalid".to_owned()));
    }
    let hour = time[0].parse::<u8>().unwrap_or(u8::MAX);
    let minute = time[1].parse::<u8>().unwrap_or(u8::MAX);
    let second = time[2].parse::<u8>().unwrap_or(u8::MAX);
    if hour > 23 || minute > 59 || second > 60 {
        return Err(ControllerError(
            "process start time is outside its canonical range".to_owned(),
        ));
    }
    let year = fields[4]
        .parse::<u16>()
        .map_err(|_| ControllerError("process start year is invalid".to_owned()))?;
    if fields[4].len() != 4 || !(2020..=9999).contains(&year) {
        return Err(ControllerError(
            "process start year is outside its reviewed range".to_owned(),
        ));
    }
    Ok(())
}

fn set_once(slot: &mut Option<String>, value: &str, label: &str) -> Result<()> {
    if value.is_empty() || slot.replace(value.to_owned()).is_some() {
        return Err(ControllerError(format!("{label} is empty or duplicated")));
    }
    Ok(())
}

fn parse_host_launch_state(text: &str) -> Result<(u32, u64)> {
    let expected_first = format!("gui/{USER_ID}/{HOST_LABEL} = {{");
    let mut lines = text.lines();
    if lines.next() != Some(expected_first.as_str()) || !text.ends_with('\n') {
        return Err(ControllerError(
            "v8 host launch state header/termination is malformed".to_owned(),
        ));
    }
    let mut depth = 1_i32;
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
            if depth < 0 {
                return Err(ControllerError(
                    "v8 host launch state braces are malformed".to_owned(),
                ));
            }
            if depth == 0 {
                block = "closed";
            } else if depth == 1 {
                block = "";
            }
            continue;
        }
        if block == "closed" {
            return Err(ControllerError(
                "v8 host launch state has trailing records".to_owned(),
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
                set_once(&mut path, value, "host launch plist path")?;
            } else if let Some(value) = line.strip_prefix("type = ") {
                set_once(&mut job_type, value, "host launch job type")?;
            } else if let Some(value) = line.strip_prefix("state = ") {
                set_once(&mut state, value, "host launch state")?;
            } else if let Some(value) = line.strip_prefix("program = ") {
                set_once(&mut program, value, "host launch program")?;
            } else if let Some(value) = line.strip_prefix("pid = ") {
                if pid
                    .replace(parse_positive_u32(value, "host launch PID")?)
                    .is_some()
                {
                    return Err(ControllerError("duplicate host launch PID".to_owned()));
                }
            } else if let Some(value) = line.strip_prefix("runs = ") {
                require_canonical_positive_decimal(value, "host launch runs")?;
                if runs
                    .replace(
                        value.parse::<u64>().map_err(|_| {
                            ControllerError("host launch runs overflowed".to_owned())
                        })?,
                    )
                    .is_some()
                {
                    return Err(ControllerError("duplicate host launch runs".to_owned()));
                }
            }
        } else if depth == 2 && block == "arguments" {
            arguments.push(line.to_owned());
        }
    }
    let mut expected_arguments = vec![HOST_EXECUTABLE.to_owned()];
    expected_arguments.extend(HOST_ARGUMENTS.iter().map(|value| (*value).to_owned()));
    if depth != 0
        || path.as_deref() != Some(HOST_PLIST)
        || job_type.as_deref() != Some("LaunchAgent")
        || state.as_deref() != Some("running")
        || program.as_deref() != Some(HOST_EXECUTABLE)
        || arguments != expected_arguments
    {
        return Err(ControllerError(
            "v8 host launchd identity/arguments differ from the exact contract".to_owned(),
        ));
    }
    Ok((
        pid.ok_or_else(|| ControllerError("host launch PID is absent".to_owned()))?,
        runs.ok_or_else(|| ControllerError("host launch runs is absent".to_owned()))?,
    ))
}

fn read_host_launch_state() -> Result<(u32, u64)> {
    let target = format!("gui/{USER_ID}/{HOST_LABEL}");
    let output = launchctl_print(&target)?;
    require_success(&output, "inspect v8 host launch state")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "v8 host launch state probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("host launch state is not UTF-8".to_owned()))?;
    parse_host_launch_state(&text)
}

fn capture_server_processes() -> Result<Vec<(u32, u32, String)>> {
    let output = bounded_output(
        "/bin/ps",
        &["-ww", "-axo", "pid=,uid=,comm="],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "enumerate CaptureServer processes")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "CaptureServer enumeration wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("process snapshot is not UTF-8".to_owned()))?;
    let mut result = Vec::new();
    for line in text.lines() {
        if !line.contains("CaptureServer") {
            continue;
        }
        let fields = line.split_ascii_whitespace().collect::<Vec<_>>();
        if fields.len() < 3 {
            return Err(ControllerError(
                "CaptureServer process record is short".to_owned(),
            ));
        }
        let pid_text = fields[0];
        let remainder = fields[1];
        let command = fields[2..].join(" ");
        let pid = parse_positive_u32(pid_text, "CaptureServer PID")?;
        let uid = remainder
            .parse::<u32>()
            .map_err(|_| ControllerError("CaptureServer UID is malformed".to_owned()))?;
        result.push((pid, uid, command));
    }
    result.sort();
    Ok(result)
}

fn require_solo_v8_host(pid: u32) -> Result<()> {
    let processes = capture_server_processes()?;
    if processes.len() != 1
        || processes[0].0 != pid
        || processes[0].1 != USER_ID
        || processes[0].2 != HOST_EXECUTABLE
    {
        return Err(ControllerError(
            "v8 host is not the sole exact CaptureServer process".to_owned(),
        ));
    }
    let pid_text = pid.to_string();
    let output = bounded_output(
        "/bin/ps",
        &[
            "-ww", "-p", &pid_text, "-o", "pid=", "-o", "ppid=", "-o", "uid=", "-o", "gid=", "-o",
            "command=",
        ],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "prove exact v8 host process arguments")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "v8 host process identity probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("v8 host process identity is not UTF-8".to_owned()))?;
    let records = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>();
    if records.len() != 1 {
        return Err(ControllerError(
            "v8 host process identity is missing or ambiguous".to_owned(),
        ));
    }
    let fields = records[0].split_ascii_whitespace().collect::<Vec<_>>();
    let expected_command = format!("{HOST_EXECUTABLE} {}", HOST_ARGUMENTS.join(" "));
    if fields.len() < 6
        || fields[0] != pid_text
        || fields[1] != "1"
        || fields[2] != USER_ID.to_string()
        || fields[3] != USER_GROUP.to_string()
        || fields[4..].join(" ") != expected_command
    {
        return Err(ControllerError(
            "v8 host PID/PPID/UID/GID/arguments are not exact".to_owned(),
        ));
    }
    Ok(())
}

fn read_generation_lock_local(pid: u32) -> Result<(u64, u64, String)> {
    if unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "host generation record must be read after dropping to UID501".to_owned(),
        ));
    }
    let path = Path::new(HOST_LOCK);
    let (mut file, ancestry_before) = openat_component_walk(path)?;
    let opened_before = file.metadata()?;
    if opened_before.uid() != USER_ID
        || opened_before.gid() != USER_GROUP
        || opened_before.permissions().mode() & 0o7777 != 0o600
        || opened_before.nlink() != 1
    {
        return Err(ControllerError(
            "host generation lock named/opened identity differs".to_owned(),
        ));
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(1_025)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1_024 {
        return Err(ControllerError(
            "host generation lock record exceeds its bound".to_owned(),
        ));
    }
    let text = String::from_utf8(bytes)
        .map_err(|_| ControllerError("host generation lock record is not UTF-8".to_owned()))?;
    let mut lines = text.lines();
    if lines.next() != Some("OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1")
        || lines.next() != Some(&format!("pid={pid}"))
    {
        return Err(ControllerError(
            "host generation lock record changed".to_owned(),
        ));
    }
    let nonce = lines
        .next()
        .and_then(|line| line.strip_prefix("nonce="))
        .ok_or_else(|| ControllerError("host generation nonce is absent".to_owned()))?
        .to_owned();
    require_lower_hex(&nonce, 64, "host generation nonce")?;
    if lines.next().is_some() || !text.ends_with('\n') {
        return Err(ControllerError(
            "host generation record has extra data".to_owned(),
        ));
    }
    let opened_after = file.metadata()?;
    let (named_after, ancestry_after) = openat_component_walk(path)?;
    let named_after = named_after.metadata()?;
    if opened_after.dev() != opened_before.dev()
        || opened_after.ino() != opened_before.ino()
        || named_after.dev() != opened_before.dev()
        || named_after.ino() != opened_before.ino()
        || opened_after.len() != opened_before.len()
        || named_after.len() != opened_before.len()
        || ancestry_before != ancestry_after
    {
        return Err(ControllerError(
            "host generation lock changed during record proof".to_owned(),
        ));
    }
    Ok((opened_before.dev(), opened_before.ino(), nonce))
}

fn read_generation_lock(pid: u32) -> Result<(u64, u64, String)> {
    if unsafe { geteuid() } == USER_ID {
        return read_generation_lock_local(pid);
    }
    let executable = env::current_exe()?;
    let pid_text = pid.to_string();
    let output = bounded_output(
        path_text(&executable)?,
        &[LOCK_RECORD_PROBE_MODE, &pid_text],
        COMMAND_TIMEOUT,
        true,
    )?;
    require_success(&output, "read exact host generation record as UID501")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "UID501 generation-record helper wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("generation-record helper output is not UTF-8".to_owned()))?;
    let value = text
        .strip_prefix("generation_lock=")
        .and_then(|value| value.strip_suffix('\n'))
        .ok_or_else(|| ControllerError("generation-record helper marker changed".to_owned()))?;
    if value.contains('\n') {
        return Err(ControllerError(
            "generation-record helper emitted multiple records".to_owned(),
        ));
    }
    let fields = value.split(':').collect::<Vec<_>>();
    if fields.len() != 3 {
        return Err(ControllerError(
            "generation-record helper fields are malformed".to_owned(),
        ));
    }
    require_canonical_positive_decimal(fields[0], "host lock device")?;
    require_canonical_positive_decimal(fields[1], "host lock inode")?;
    require_lower_hex(fields[2], 64, "host generation nonce")?;
    Ok((
        fields[0].parse().unwrap(),
        fields[1].parse().unwrap(),
        fields[2].to_owned(),
    ))
}

fn require_pinned_lsof_metadata(path: &Path) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != ROOT_ID
        || metadata.gid() != ROOT_ID
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o7777 != 0o755
        || metadata.len() != LSOF_SIZE
        || metadata.st_flags() != LSOF_FLAGS
    {
        return Err(ControllerError(
            "lsof metadata differs from the reviewed sealed-system file".to_owned(),
        ));
    }
    Ok(metadata)
}

fn require_pinned_lsof() -> Result<()> {
    let path = Path::new("/usr/sbin/lsof");
    let before = require_pinned_lsof_metadata(path)?;
    if sha256(path)? != LSOF_SHA256 {
        return Err(ControllerError(
            "lsof differs from its exact reviewed hash".to_owned(),
        ));
    }
    let after = require_pinned_lsof_metadata(path)?;
    if before.dev() != after.dev() || before.ino() != after.ino() || before.len() != after.len() {
        return Err(ControllerError(
            "lsof identity changed during hash proof".to_owned(),
        ));
    }
    Ok(())
}

fn lock_openers() -> Result<Vec<(u32, String, u32, String)>> {
    require_pinned_lsof()?;
    let output = bounded_output(
        "/usr/sbin/lsof",
        &["-n", "-Fpcufa", "--", HOST_LOCK],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "attribute host generation lock openers")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "host lock opener attribution wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("host lock opener output is not UTF-8".to_owned()))?;
    let mut current_pid = None;
    let mut current_command = None;
    let mut current_uid = None;
    let mut current_fd = false;
    let mut openers = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix('p') {
            current_pid = Some(parse_positive_u32(value, "lsof PID")?);
            current_command = None;
            current_uid = None;
            current_fd = false;
        } else if let Some(value) = line.strip_prefix('c') {
            if current_pid.is_none()
                || value.is_empty()
                || current_command.replace(value.to_owned()).is_some()
            {
                return Err(ControllerError(
                    "lsof command record is missing, empty, or duplicated".to_owned(),
                ));
            }
        } else if let Some(value) = line.strip_prefix('u') {
            if current_pid.is_none()
                || value.parse::<u32>().ok().map(|uid| uid.to_string()) != Some(value.to_owned())
                || current_uid.replace(value.parse::<u32>().unwrap()).is_some()
            {
                return Err(ControllerError(
                    "lsof UID record is missing, noncanonical, or duplicated".to_owned(),
                ));
            }
        } else if line.starts_with('f') {
            if current_pid.is_none() || current_fd {
                return Err(ControllerError(
                    "lsof file-descriptor record is out of order".to_owned(),
                ));
            }
            current_fd = true;
        } else if let Some(access) = line.strip_prefix('a') {
            if !current_fd || !matches!(access, "r" | "w" | "u") {
                return Err(ControllerError(
                    "lsof access record is malformed".to_owned(),
                ));
            }
            openers.push((
                current_pid.ok_or_else(|| ControllerError("lsof access has no PID".to_owned()))?,
                current_command
                    .clone()
                    .ok_or_else(|| ControllerError("lsof access has no command".to_owned()))?,
                current_uid.ok_or_else(|| ControllerError("lsof access has no UID".to_owned()))?,
                access.to_owned(),
            ));
            current_fd = false;
        } else {
            return Err(ControllerError(
                "lsof opener output contains an unknown record".to_owned(),
            ));
        }
    }
    if current_fd || openers.is_empty() {
        return Err(ControllerError(
            "lsof opener output is incomplete or empty".to_owned(),
        ));
    }
    Ok(openers)
}

fn open_exact_host_lock(expected_device: u64, expected_inode: u64) -> Result<File> {
    let path = Path::new(HOST_LOCK);
    let (named_before, ancestry_before) = openat_component_walk(path)?;
    let named_before = named_before.metadata()?;
    if named_before.dev() != expected_device || named_before.ino() != expected_inode {
        return Err(ControllerError(
            "named host lock differs from its authorized device/inode".to_owned(),
        ));
    }
    let (file, opened_ancestry) = openat_component_walk_with_final_flags(path, O_RDWR)?;
    let opened = file.metadata()?;
    let (named_after, ancestry_after) = openat_component_walk(path)?;
    let named_after = named_after.metadata()?;
    if opened.dev() != expected_device
        || opened.ino() != expected_inode
        || opened.nlink() != 1
        || named_after.dev() != expected_device
        || named_after.ino() != expected_inode
        || ancestry_before != opened_ancestry
        || ancestry_before != ancestry_after
    {
        return Err(ControllerError(
            "host lock device/inode changed while opening it".to_owned(),
        ));
    }
    Ok(file)
}

fn prove_lock_held_by_local(pid: u32, expected_device: u64, expected_inode: u64) -> Result<()> {
    if unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "host lock owner proof must run after dropping to UID501".to_owned(),
        ));
    }
    let (record_device, record_inode, _) = read_generation_lock_local(pid)?;
    if record_device != expected_device || record_inode != expected_inode {
        return Err(ControllerError(
            "host generation record moved before ownership proof".to_owned(),
        ));
    }
    let initial_openers = lock_openers()?;
    if initial_openers
        .iter()
        .any(|(opener_pid, command, uid, access)| {
            *opener_pid != pid
                || command != "CaptureServer"
                || *uid != USER_ID
                || !matches!(access.as_str(), "r" | "w" | "u")
        })
        || !initial_openers.iter().any(|(opener_pid, _, _, access)| {
            *opener_pid == pid && matches!(access.as_str(), "w" | "u")
        })
    {
        return Err(ControllerError(format!(
            "host lock opener topology is not solely owned by exact PID {pid}: {initial_openers:?}"
        )));
    }
    let file = open_exact_host_lock(expected_device, expected_inode)?;
    require_expected_lock_contention(&file)?;
    let (named_mid, _) = openat_component_walk(Path::new(HOST_LOCK))?;
    let named_mid = named_mid.metadata()?;
    if named_mid.dev() != expected_device || named_mid.ino() != expected_inode {
        return Err(ControllerError(
            "host lock inode changed after first contention proof".to_owned(),
        ));
    }
    let controller_pid = std::process::id();
    let controller_uid = unsafe { geteuid() };
    let bracketed_openers = lock_openers()?;
    if bracketed_openers
        .iter()
        .any(|(opener_pid, command, uid, access)| {
            let exact_host = *opener_pid == pid && command == "CaptureServer" && *uid == USER_ID;
            let exact_controller =
                *opener_pid == controller_pid && command == "controller" && *uid == controller_uid;
            !(exact_host || exact_controller) || !matches!(access.as_str(), "r" | "w" | "u")
        })
        || !bracketed_openers.iter().any(|(opener_pid, _, _, access)| {
            *opener_pid == pid && matches!(access.as_str(), "w" | "u")
        })
        || !bracketed_openers.iter().any(|(opener_pid, _, _, access)| {
            *opener_pid == controller_pid && matches!(access.as_str(), "w" | "u")
        })
    {
        return Err(ControllerError(format!(
            "bracketed host/controller lock opener topology is not exact: {bracketed_openers:?}"
        )));
    }
    require_expected_lock_contention(&file)?;
    let (final_device, final_inode, _) = read_generation_lock_local(pid)?;
    if final_device != expected_device || final_inode != expected_inode {
        return Err(ControllerError(
            "host generation record changed after lock ownership bracket".to_owned(),
        ));
    }
    Ok(())
}

fn prove_lock_held_by(pid: u32, expected_device: u64, expected_inode: u64) -> Result<()> {
    if unsafe { geteuid() } == USER_ID {
        return prove_lock_held_by_local(pid, expected_device, expected_inode);
    }
    let executable = env::current_exe()?;
    let pid_text = pid.to_string();
    let device_text = expected_device.to_string();
    let inode_text = expected_inode.to_string();
    let output = bounded_output(
        path_text(&executable)?,
        &[LOCK_PROBE_MODE, &pid_text, &device_text, &inode_text],
        COMMAND_TIMEOUT,
        true,
    )?;
    require_success(&output, "prove exact host lock owner as UID501")?;
    if !output.stderr.is_empty()
        || String::from_utf8(output.stdout).ok().as_deref()
            != Some(format!("lock_holder={pid}\n").as_str())
    {
        return Err(ControllerError(
            "UID501 host lock owner proof marker changed".to_owned(),
        ));
    }
    Ok(())
}

fn require_expected_lock_contention(file: &File) -> Result<()> {
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        let _ = unsafe { flock(file.as_raw_fd(), LOCK_UN) };
        return Err(ControllerError(
            "host generation lock is unexpectedly acquirable".to_owned(),
        ));
    }
    if !matches!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(11 | 35)
    ) {
        return Err(ControllerError(
            "host lock contention proof failed for an operational reason".to_owned(),
        ));
    }
    Ok(())
}

fn prove_lock_free_local(expected_device: u64, expected_inode: u64) -> Result<()> {
    if unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "host lock free proof must run after dropping to UID501".to_owned(),
        ));
    }
    require_pinned_lsof()?;
    let output = bounded_output(
        "/usr/sbin/lsof",
        &["-n", "-Fpcufa", "--", HOST_LOCK],
        COMMAND_TIMEOUT,
        false,
    )?;
    if output.status.code() != Some(1) || !output.stdout.is_empty() || !output.stderr.is_empty() {
        return Err(ControllerError(
            "host lock still has an opener or lsof failed operationally".to_owned(),
        ));
    }
    let file = open_exact_host_lock(expected_device, expected_inode)?;
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(ControllerError("shared host lock remains held".to_owned()));
    }
    if unsafe { flock(file.as_raw_fd(), LOCK_UN) } != 0 {
        return Err(ControllerError(
            "cannot release shared-host proof lock".to_owned(),
        ));
    }
    let (named_after, _) = openat_component_walk(Path::new(HOST_LOCK))?;
    let named_after = named_after.metadata()?;
    if named_after.dev() != expected_device || named_after.ino() != expected_inode {
        return Err(ControllerError(
            "host lock device/inode changed during free proof".to_owned(),
        ));
    }
    Ok(())
}

fn prove_lock_free(expected_device: u64, expected_inode: u64) -> Result<()> {
    if unsafe { geteuid() } == USER_ID {
        return prove_lock_free_local(expected_device, expected_inode);
    }
    let executable = env::current_exe()?;
    let device_text = expected_device.to_string();
    let inode_text = expected_inode.to_string();
    let output = bounded_output(
        path_text(&executable)?,
        &[LOCK_FREE_PROBE_MODE, &device_text, &inode_text],
        COMMAND_TIMEOUT,
        true,
    )?;
    require_success(&output, "prove exact host lock free as UID501")?;
    let marker = format!("lock_free={expected_device}:{expected_inode}\n");
    if !output.stderr.is_empty()
        || String::from_utf8(output.stdout).ok().as_deref() != Some(&marker)
    {
        return Err(ControllerError(
            "UID501 host lock free proof marker changed".to_owned(),
        ));
    }
    Ok(())
}

fn verify_live_v8_host() -> Result<HostGeneration> {
    verify_installed_v8_runtime_bytes()?;
    require_legacy_disabled_and_absent()?;
    let (pid, runs) = read_host_launch_state()?;
    require_solo_v8_host(pid)?;
    let initial_process_start = process_start(pid)?;
    let (lock_device, lock_inode, nonce) = read_generation_lock(pid)?;
    prove_lock_held_by(pid, lock_device, lock_inode)?;
    let generation = HostGeneration {
        pid,
        runs,
        process_start: initial_process_start,
        nonce,
        lock_device,
        lock_inode,
    };
    thread::sleep(Duration::from_millis(250));
    let (second_pid, second_runs) = read_host_launch_state()?;
    let (second_device, second_inode, second_nonce) = read_generation_lock(pid)?;
    if second_pid != generation.pid
        || second_runs != generation.runs
        || process_start(pid)? != generation.process_start
        || second_device != generation.lock_device
        || second_inode != generation.lock_inode
        || second_nonce != generation.nonce
    {
        return Err(ControllerError(
            "v8 host generation changed during proof".to_owned(),
        ));
    }
    require_solo_v8_host(pid)?;
    prove_lock_held_by(pid, lock_device, lock_inode)?;
    Ok(generation)
}

#[repr(C)]
struct AudioObjectPropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectGetPropertyData(
        object_id: u32,
        address: *const AudioObjectPropertyAddress,
        qualifier_size: u32,
        qualifier_data: *const std::ffi::c_void,
        data_size: *mut u32,
        data: *mut std::ffi::c_void,
    ) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringGetCString(
        string: *const std::ffi::c_void,
        buffer: *mut i8,
        buffer_size: isize,
        encoding: u32,
    ) -> u8;
}

const AUDIO_SYSTEM_OBJECT: u32 = 1;
const SELECTOR_DEFAULT_INPUT: u32 = u32::from_be_bytes(*b"dIn ");
const SELECTOR_DEFAULT_OUTPUT: u32 = u32::from_be_bytes(*b"dOut");
const SELECTOR_DEFAULT_SYSTEM_OUTPUT: u32 = u32::from_be_bytes(*b"sOut");
const SELECTOR_DEVICE_UID: u32 = u32::from_be_bytes(*b"uid ");
const SCOPE_GLOBAL: u32 = u32::from_be_bytes(*b"glob");
const CF_STRING_UTF8: u32 = 0x0800_0100;
const VISIBLE_UID: &str = "com.elamin.opensteamer.virtual-microphone.input";
const WRITER_UID: &str = "com.elamin.opensteamer.virtual-microphone.writer";

#[derive(Clone, Debug, Eq, PartialEq)]
struct RouteSnapshot {
    input_uid: String,
    output_uid: String,
    system_output_uid: String,
}

fn audio_default_device(selector: u32) -> Result<u32> {
    let address = AudioObjectPropertyAddress {
        selector,
        scope: SCOPE_GLOBAL,
        element: 0,
    };
    let mut device = 0_u32;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            AUDIO_SYSTEM_OBJECT,
            &address,
            0,
            std::ptr::null(),
            &mut size,
            (&mut device as *mut u32).cast(),
        )
    };
    if status != 0 || size != std::mem::size_of::<u32>() as u32 || device == 0 {
        return Err(ControllerError(format!(
            "read-only default-device lookup failed: selector={selector:08x} status={status}"
        )));
    }
    Ok(device)
}

fn audio_device_uid(device: u32) -> Result<String> {
    let address = AudioObjectPropertyAddress {
        selector: SELECTOR_DEVICE_UID,
        scope: SCOPE_GLOBAL,
        element: 0,
    };
    let mut value: *const std::ffi::c_void = std::ptr::null();
    let mut size = std::mem::size_of::<*const std::ffi::c_void>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            device,
            &address,
            0,
            std::ptr::null(),
            &mut size,
            (&mut value as *mut *const std::ffi::c_void).cast(),
        )
    };
    if status != 0
        || size != std::mem::size_of::<*const std::ffi::c_void>() as u32
        || value.is_null()
    {
        return Err(ControllerError(format!(
            "read-only device UID lookup failed: device={device} status={status}"
        )));
    }
    let mut buffer = [0_i8; 1_024];
    if unsafe {
        CFStringGetCString(
            value,
            buffer.as_mut_ptr(),
            buffer.len() as isize,
            CF_STRING_UTF8,
        )
    } == 0
    {
        return Err(ControllerError(
            "device UID is not bounded UTF-8".to_owned(),
        ));
    }
    let bytes = buffer
        .iter()
        .take_while(|byte| **byte != 0)
        .map(|byte| *byte as u8)
        .collect::<Vec<_>>();
    String::from_utf8(bytes).map_err(|_| ControllerError("device UID is not UTF-8".to_owned()))
}

fn capture_route_snapshot() -> Result<RouteSnapshot> {
    let snapshot = RouteSnapshot {
        input_uid: audio_device_uid(audio_default_device(SELECTOR_DEFAULT_INPUT)?)?,
        output_uid: audio_device_uid(audio_default_device(SELECTOR_DEFAULT_OUTPUT)?)?,
        system_output_uid: audio_device_uid(audio_default_device(SELECTOR_DEFAULT_SYSTEM_OUTPUT)?)?,
    };
    if [
        snapshot.output_uid.as_str(),
        snapshot.system_output_uid.as_str(),
    ]
    .iter()
    .any(|uid| *uid == VISIBLE_UID || *uid == WRITER_UID)
        || snapshot.input_uid == WRITER_UID
    {
        return Err(ControllerError(
            "read-only route snapshot found a forbidden product endpoint role".to_owned(),
        ));
    }
    Ok(snapshot)
}

fn stable_route_snapshot() -> Result<RouteSnapshot> {
    let first = capture_route_snapshot()?;
    thread::sleep(Duration::from_millis(250));
    let second = capture_route_snapshot()?;
    if first != second {
        return Err(ControllerError(
            "default routes changed during read-only snapshot".to_owned(),
        ));
    }
    Ok(first)
}

fn parse_coreaudio_launch_state(text: &str) -> Result<(u32, u64)> {
    let mut lines = text.lines();
    if lines.next() != Some("system/com.apple.audio.coreaudiod = {") || !text.ends_with('\n') {
        return Err(ControllerError(
            "coreaudiod launch state header/termination is malformed".to_owned(),
        ));
    }
    let mut depth = 1_i32;
    let mut closed = false;
    let mut state = None;
    let mut program = None;
    let mut domain = None;
    let mut username = None;
    let mut group = None;
    let mut runs = None;
    let mut pid = None;
    for raw in lines {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if closed {
            return Err(ControllerError(
                "coreaudiod launch state contains trailing records".to_owned(),
            ));
        }
        if line == "}" {
            depth -= 1;
            if depth < 0 {
                return Err(ControllerError(
                    "coreaudiod launch state braces are malformed".to_owned(),
                ));
            }
            if depth == 0 {
                closed = true;
            }
            continue;
        }
        if line.ends_with(" = {") {
            depth += 1;
            continue;
        }
        if depth != 1 {
            continue;
        }
        if let Some(value) = line.strip_prefix("state = ") {
            set_once(&mut state, value, "coreaudiod state")?;
        } else if let Some(value) = line.strip_prefix("program = ") {
            set_once(&mut program, value, "coreaudiod program")?;
        } else if let Some(value) = line.strip_prefix("domain = ") {
            set_once(&mut domain, value, "coreaudiod domain")?;
        } else if let Some(value) = line.strip_prefix("username = ") {
            set_once(&mut username, value, "coreaudiod username")?;
        } else if let Some(value) = line.strip_prefix("group = ") {
            set_once(&mut group, value, "coreaudiod group")?;
        } else if let Some(value) = line.strip_prefix("runs = ") {
            require_canonical_positive_decimal(value, "coreaudiod launch runs")?;
            if runs.replace(value.parse::<u64>().unwrap()).is_some() {
                return Err(ControllerError(
                    "coreaudiod launch state repeats its run count".to_owned(),
                ));
            }
        } else if let Some(value) = line.strip_prefix("pid = ") {
            if pid
                .replace(parse_positive_u32(value, "coreaudiod launch PID")?)
                .is_some()
            {
                return Err(ControllerError(
                    "coreaudiod launch state repeats its PID".to_owned(),
                ));
            }
        }
    }
    if !closed
        || depth != 0
        || state.as_deref() != Some("running")
        || program.as_deref() != Some("/usr/sbin/coreaudiod")
        || domain.as_deref() != Some("system")
        || username.as_deref() != Some("_coreaudiod")
        || group.as_deref() != Some("_coreaudiod")
    {
        return Err(ControllerError(
            "coreaudiod launchd service identity is not exact and running".to_owned(),
        ));
    }
    Ok((
        pid.ok_or_else(|| ControllerError("coreaudiod PID is absent".to_owned()))?,
        runs.ok_or_else(|| ControllerError("coreaudiod run count is absent".to_owned()))?,
    ))
}

fn read_coreaudio_generation() -> Result<CoreAudioGeneration> {
    let output = launchctl_print("system/com.apple.audio.coreaudiod")?;
    require_success(&output, "inspect system coreaudiod launch state")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "coreaudiod launch state probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("coreaudiod launch state is not UTF-8".to_owned()))?;
    let (pid, runs) = parse_coreaudio_launch_state(&text)?;
    let pid_text = pid.to_string();
    let process = bounded_output(
        "/bin/ps",
        &[
            "-ww", "-p", &pid_text, "-o", "pid=", "-o", "ppid=", "-o", "uid=", "-o", "gid=", "-o",
            "comm=",
        ],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&process, "inspect coreaudiod process")?;
    if !process.stderr.is_empty() {
        return Err(ControllerError(
            "coreaudiod process identity probe wrote stderr".to_owned(),
        ));
    }
    let process_text = String::from_utf8(process.stdout)
        .map_err(|_| ControllerError("coreaudiod process record is not UTF-8".to_owned()))?;
    let records = process_text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>();
    if records.len() != 1
        || records[0].split_ascii_whitespace().collect::<Vec<_>>()
            != [pid_text.as_str(), "1", "202", "202", "/usr/sbin/coreaudiod"]
    {
        return Err(ControllerError(
            "coreaudiod process identity changed".to_owned(),
        ));
    }
    let pgrep = command_line(
        "/usr/bin/pgrep",
        &["-x", "coreaudiod"],
        "enumerate coreaudiod PIDs",
    )?;
    if pgrep != pid_text {
        return Err(ControllerError(
            "coreaudiod process set is not exact".to_owned(),
        ));
    }
    Ok(CoreAudioGeneration {
        pid,
        runs,
        process_start: process_start(pid)?,
    })
}

fn stable_coreaudio_generation() -> Result<CoreAudioGeneration> {
    let first = read_coreaudio_generation()?;
    thread::sleep(Duration::from_millis(250));
    let second = read_coreaudio_generation()?;
    if first != second {
        return Err(ControllerError(
            "coreaudiod generation changed during proof".to_owned(),
        ));
    }
    Ok(first)
}

fn coreaudio_restart_successor_is_exact(
    before: &CoreAudioGeneration,
    after: &CoreAudioGeneration,
) -> bool {
    after.pid != before.pid && after.runs == before.runs.saturating_add(1)
}

fn reload_coreaudio_exact(
    expected: &CoreAudioGeneration,
) -> Result<(CoreAudioGeneration, CoreAudioGeneration)> {
    if !capture_server_processes()?.is_empty() {
        return Err(ControllerError(
            "Core Audio reload refused while CaptureServer exists".to_owned(),
        ));
    }
    let before = stable_coreaudio_generation()?;
    if &before != expected {
        return Err(ControllerError(
            "coreaudiod changed before its authorized TERM boundary".to_owned(),
        ));
    }
    if !capture_server_processes()?.is_empty() {
        return Err(ControllerError(
            "Core Audio reload refused because CaptureServer appeared before TERM".to_owned(),
        ));
    }
    if unsafe { kill(before.pid as i32, SIGTERM) } != 0 {
        return Err(ControllerError(format!(
            "cannot TERM exact coreaudiod PID {}: {}",
            before.pid,
            std::io::Error::last_os_error()
        )));
    }
    let deadline = Instant::now()
        .checked_add(COREAUDIO_TIMEOUT)
        .ok_or_else(|| ControllerError("Core Audio deadline overflowed".to_owned()))?;
    loop {
        match read_coreaudio_generation() {
            Ok(after) if coreaudio_restart_successor_is_exact(&before, &after) => {
                thread::sleep(Duration::from_millis(250));
                if read_coreaudio_generation()? != after {
                    return Err(ControllerError(
                        "new coreaudiod generation did not remain stable".to_owned(),
                    ));
                }
                return Ok((before, after));
            }
            Ok(after) if after.runs > before.runs.saturating_add(1) => {
                return Err(ControllerError(
                    "coreaudiod restarted more than exactly once".to_owned(),
                ));
            }
            Ok(_) | Err(_) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(100));
            }
            Ok(_) | Err(_) => {
                return Err(ControllerError(
                    "new exact coreaudiod generation was not observed".to_owned(),
                ));
            }
        }
    }
}

fn canonical_repo(repo: &Path) -> Result<PathBuf> {
    if repo != Path::new(EXPECTED_REPO) || repo.is_symlink() {
        return Err(ControllerError("repository path is not exact".to_owned()));
    }
    let canonical = fs::canonicalize(repo)?;
    if canonical != Path::new(EXPECTED_REPO) {
        return Err(ControllerError(
            "repository canonical path changed".to_owned(),
        ));
    }
    Ok(canonical)
}

fn git(repo: &Path, arguments: &[&str], label: &str) -> Result<String> {
    let mut command = Command::new("/usr/bin/git");
    command
        .args(arguments)
        .current_dir(repo)
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = command.output()?;
    require_success(&output, label)?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(format!("{label} wrote stderr")));
    }
    String::from_utf8(output.stdout)
        .map(|text| text.trim_end_matches(['\r', '\n']).to_owned())
        .map_err(|_| ControllerError(format!("{label} output is not UTF-8")))
}

fn verify_git_provenance(repo: &Path) -> Result<(String, String)> {
    let status = git(
        repo,
        &["status", "--porcelain=v1", "--untracked-files=all"],
        "inspect repository status",
    )?;
    if !status.is_empty() {
        return Err(ControllerError(
            "repository must be completely clean for deployment".to_owned(),
        ));
    }
    let commit = git(repo, &["rev-parse", "HEAD"], "resolve release commit")?;
    let tree = git(repo, &["rev-parse", "HEAD^{tree}"], "resolve release tree")?;
    require_lower_hex(&commit, 40, "release commit")?;
    require_lower_hex(&tree, 40, "release tree")?;
    let candidate_tree = git(
        repo,
        &["rev-parse", &format!("{EXPECTED_SOURCE_COMMIT}^{{tree}}")],
        "resolve candidate source tree",
    )?;
    if candidate_tree != EXPECTED_SOURCE_TREE {
        return Err(ControllerError(
            "candidate source commit no longer resolves to reviewed tree".to_owned(),
        ));
    }
    if git(
        repo,
        &["config", "--get", "remote.origin.url"],
        "inspect origin",
    )? != EXPECTED_REMOTE
    {
        return Err(ControllerError("origin URL changed".to_owned()));
    }
    let branch = git(
        repo,
        &["symbolic-ref", "--short", "HEAD"],
        "resolve release branch",
    )?;
    if branch != "main" {
        return Err(ControllerError(
            "live release checkout must be exact main".to_owned(),
        ));
    }
    let remote_ref = format!("refs/heads/{branch}");
    let repo_text = path_text(repo)?;
    let remote_output = bounded_output(
        "/usr/bin/git",
        &[
            "-C",
            repo_text,
            "ls-remote",
            "--exit-code",
            "origin",
            &remote_ref,
        ],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&remote_output, "prove exact release commit pushed")?;
    if !remote_output.stderr.is_empty() {
        return Err(ControllerError("git ls-remote wrote stderr".to_owned()));
    }
    let remote = String::from_utf8(remote_output.stdout)
        .map_err(|_| ControllerError("git ls-remote output is not UTF-8".to_owned()))?
        .trim_end_matches(['\r', '\n'])
        .to_owned();
    if remote != format!("{commit}\t{remote_ref}") {
        return Err(ControllerError(
            "exact release branch is not pushed at HEAD".to_owned(),
        ));
    }
    Ok((commit, tree))
}

fn verify_reader_inputs(repo: &Path) -> Result<()> {
    for (relative, hash, mode) in [
        (
            DIAGNOSTIC_READER_BUILDER_RELATIVE,
            DIAGNOSTIC_READER_BUILDER_SHA256,
            0o755,
        ),
        (
            DIAGNOSTIC_READER_SOURCE_RELATIVE,
            DIAGNOSTIC_READER_SOURCE_SHA256,
            0o644,
        ),
        (
            DIAGNOSTIC_DRIVER_HEADER_RELATIVE,
            DIAGNOSTIC_DRIVER_HEADER_SHA256,
            0o644,
        ),
        (
            DIAGNOSTIC_CORE_HEADER_RELATIVE,
            DIAGNOSTIC_CORE_HEADER_SHA256,
            0o644,
        ),
    ] {
        let path = repo.join(relative);
        require_regular(&path, USER_ID, USER_GROUP, mode)?;
        if sha256(&path)? != hash {
            return Err(ControllerError(format!(
                "diagnostic-reader input changed: {relative}"
            )));
        }
    }
    require_regular(Path::new(BOTH_ORDER_PROBE), USER_ID, USER_GROUP, 0o755)?;
    if sha256(Path::new(BOTH_ORDER_PROBE))? != BOTH_ORDER_PROBE_SHA256 {
        return Err(ControllerError(
            "retained exact-UID both-order probe changed".to_owned(),
        ));
    }
    Ok(())
}

fn require_fresh_namespaces() -> Result<()> {
    require_absent(
        Path::new(USER_ACTIVE_POINTER),
        "user active diagnostic-driver pointer",
    )?;
    require_absent(
        Path::new(ROOT_ACTIVE_POINTER),
        "root active diagnostic-driver pointer",
    )?;
    require_absent(
        Path::new(ROOT_ACTIVE_POINTER_PENDING),
        "pending root active diagnostic-driver pointer",
    )?;
    match fs::symlink_metadata(USER_UPDATE_ROOT) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            require_directory(Path::new(USER_UPDATE_ROOT), USER_ID, USER_GROUP, 0o700)?;
            require_exact_child_names(Path::new(USER_UPDATE_ROOT), &[], "user update root")?;
        }
    }
    match fs::symlink_metadata(ROOT_UPDATE_ROOT) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            require_directory(
                Path::new(ROOT_UPDATE_ROOT),
                ROOT_ID,
                ROOT_ID,
                ROOT_PRIVATE_MODE,
            )?;
            return Err(ControllerError(
                "root update namespace already exists; preflight requires absence".to_owned(),
            ));
        }
    }
    match fs::symlink_metadata(ROOT_CONTROLLER_PARENT) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            require_directory(
                Path::new(ROOT_CONTROLLER_PARENT),
                ROOT_ID,
                ROOT_ID,
                ROOT_SEALED_TRAVERSE_MODE,
            )?;
            return Err(ControllerError(
                "sealed root controller namespace already exists".to_owned(),
            ));
        }
    }
    match fs::symlink_metadata(ROOT_PROBE_PARENT) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            require_directory(
                Path::new(ROOT_PROBE_PARENT),
                ROOT_ID,
                ROOT_ID,
                ROOT_SEALED_TRAVERSE_MODE,
            )?;
            return Err(ControllerError(
                "sealed root probe namespace already exists".to_owned(),
            ));
        }
    }
    Ok(())
}

fn verify_complete_preflight(
    repo: &Path,
    require_fresh: bool,
) -> Result<(String, String, HostGeneration)> {
    if unsafe { getuid() } != USER_ID || unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "preflight requires exact UID 501".to_owned(),
        ));
    }
    let repo = canonical_repo(repo)?;
    let provenance = verify_git_provenance(&repo)?;
    verify_candidate()?;
    verify_installed_v7_driver()?;
    verify_v8_evidence_and_host_bytes()?;
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    verify_reader_inputs(&repo)?;
    if require_fresh {
        require_fresh_namespaces()?;
    }
    Ok((provenance.0, provenance.1, host))
}

fn preflight(repo: &Path) -> Result<()> {
    let (commit, tree, host) = verify_complete_preflight(repo, true)?;
    let coreaudio = stable_coreaudio_generation()?;
    println!(
        "DIAGNOSTIC_DRIVER_V1_PREFLIGHT_OK host_pid={} host_runs={} coreaudiod_pid={} coreaudiod_runs={} installed_driver={}:{} candidate_commit={} candidate_tree={} release_commit={} release_tree={} pairing=metadata-only legacy=protected reader=passive both_order=no-default-mutation namespaces=fresh",
        host.pid,
        host.runs,
        coreaudio.pid,
        coreaudio.runs,
        INSTALLED_DRIVER_DEVICE,
        INSTALLED_DRIVER_INODE,
        EXPECTED_SOURCE_COMMIT,
        EXPECTED_SOURCE_TREE,
        commit,
        tree
    );
    Ok(())
}

fn build_diagnostic_reader(repo: &Path, nonce: &str, destination: &Path) -> Result<()> {
    validate_nonce(nonce)?;
    verify_reader_inputs(repo)?;
    let built = Path::new(PREBUILT_DIAGNOSTIC_READER);
    require_regular(built, USER_ID, USER_GROUP, 0o755)?;
    if sha256(built)? != DIAGNOSTIC_READER_SHA256 {
        return Err(ControllerError(
            "prebuilt external-volume diagnostic reader differs from reviewed hash".to_owned(),
        ));
    }
    require_absent(destination, "evidence diagnostic reader")?;
    fs::copy(built, destination)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o755))?;
    require_regular(destination, USER_ID, USER_GROUP, 0o755)?;
    if sha256(destination)? != DIAGNOSTIC_READER_SHA256 {
        return Err(ControllerError(
            "evidence diagnostic reader changed during copy".to_owned(),
        ));
    }
    fsync_parent(destination)
}

struct Journal {
    path: PathBuf,
    uid: u32,
    gid: u32,
    header: &'static str,
    state: UpdateState,
}

fn valid_transition(from: UpdateState, to: UpdateState) -> bool {
    use UpdateState::*;
    matches!(
        (from, to),
        (Begun, Authenticated)
            | (Begun, PrestopAborted)
            | (Authenticated, PrestopAborted)
            | (Authenticated, HostStopInitiated)
            | (HostStopInitiated, HostStopped)
            | (HostStopped, PriorDriverRetained)
            | (PriorDriverRetained, CandidatePublished)
            | (CandidatePublished, CoreAudioReloaded)
            | (CoreAudioReloaded, DriverValidated)
            | (DriverValidated, HostBootstrapped)
            | (HostBootstrapped, ReadyVerified)
            | (ReadyVerified, Committed)
            | (HostStopInitiated, RollbackStarted)
            | (HostStopped, RollbackStarted)
            | (PriorDriverRetained, RollbackStarted)
            | (CandidatePublished, RollbackStarted)
            | (CoreAudioReloaded, RollbackStarted)
            | (DriverValidated, RollbackStarted)
            | (HostBootstrapped, RollbackStarted)
            | (ReadyVerified, RollbackStarted)
            | (RollbackStarted, FailedDriverArchived)
            | (RollbackStarted, PriorDriverRestored)
            | (FailedDriverArchived, PriorDriverRestored)
            | (PriorDriverRestored, RollbackCoreAudioReloadInitiated)
            | (RollbackCoreAudioReloadInitiated, RollbackCoreAudioReloaded)
            | (RollbackCoreAudioReloaded, HostRebootstrapped)
            | (HostRebootstrapped, RolledBack)
            | (CriticalFailure, RollbackStarted)
            | (Authenticated, CriticalFailure)
            | (HostStopInitiated, CriticalFailure)
            | (HostStopped, CriticalFailure)
            | (PriorDriverRetained, CriticalFailure)
            | (CandidatePublished, CriticalFailure)
            | (CoreAudioReloaded, CriticalFailure)
            | (DriverValidated, CriticalFailure)
            | (HostBootstrapped, CriticalFailure)
            | (ReadyVerified, CriticalFailure)
            | (RollbackStarted, CriticalFailure)
            | (FailedDriverArchived, CriticalFailure)
            | (PriorDriverRestored, CriticalFailure)
            | (RollbackCoreAudioReloadInitiated, CriticalFailure)
            | (RollbackCoreAudioReloaded, CriticalFailure)
            | (HostRebootstrapped, CriticalFailure)
    )
}

fn require_canonical_positive_decimal(value: &str, label: &str) -> Result<()> {
    let parsed = value
        .parse::<u64>()
        .map_err(|_| ControllerError(format!("{label} is not decimal")))?;
    if parsed == 0 || parsed.to_string() != value {
        return Err(ControllerError(format!(
            "{label} is not canonical positive decimal"
        )));
    }
    Ok(())
}

fn validate_journal_fields(
    header: &str,
    state: UpdateState,
    fields: &BTreeMap<String, String>,
) -> Result<()> {
    use UpdateState::*;
    let expected: &[&str] = if header == ROOT_JOURNAL_HEADER {
        match state {
            Authenticated => &[
                "coreaudiod_pid",
                "coreaudiod_runs",
                "host_pid",
                "host_runs",
                "release_commit",
                "release_tree",
            ],
            HostStopInitiated => &[
                "available_bytes",
                "reserve_bytes",
                "reserve_device",
                "reserve_inode",
            ],
            PriorDriverRetained => &["device", "inode"],
            RollbackCoreAudioReloadInitiated => &["old_pid", "old_runs"],
            CoreAudioReloaded | RollbackCoreAudioReloaded => &["new_pid", "new_runs", "old_pid"],
            DriverValidated => &["driver_generation"],
            HostBootstrapped | HostRebootstrapped => &["nonce", "pid", "runs"],
            _ => &[],
        }
    } else if header == JOURNAL_HEADER {
        match state {
            Authenticated => &["host_pid", "nonce", "release_commit", "release_tree"],
            _ => &[],
        }
    } else {
        return Err(ControllerError(
            "journal header is not recognized".to_owned(),
        ));
    };
    let actual = fields.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected = expected.iter().copied().collect::<BTreeSet<_>>();
    if actual != expected {
        return Err(ControllerError(format!(
            "journal {} field set is not exact",
            state.token()
        )));
    }
    for (key, value) in fields {
        match key.as_str() {
            "release_commit" | "release_tree" => {
                require_lower_hex(value, 40, "journal Git object")?
            }
            "nonce" if state == Authenticated => {
                require_lower_hex(value, 32, "journal transaction nonce")?
            }
            "nonce" => require_lower_hex(value, 64, "journal host generation nonce")?,
            "host_pid" | "host_runs" | "coreaudiod_pid" | "coreaudiod_runs" | "device"
            | "inode" | "old_pid" | "new_pid" | "new_runs" | "driver_generation" | "pid"
            | "runs" | "old_runs" | "available_bytes" | "reserve_bytes" | "reserve_device"
            | "reserve_inode" => require_canonical_positive_decimal(value, "journal number")?,
            _ => {
                return Err(ControllerError(format!(
                    "journal contains unvalidated field: {key}"
                )))
            }
        }
    }
    Ok(())
}

fn parse_journal_text(text: &str, header: &'static str) -> Result<UpdateState> {
    let mut lines = text.lines();
    if lines.next() != Some(header) || !text.ends_with('\n') {
        return Err(ControllerError(
            "journal header/termination changed".to_owned(),
        ));
    }
    let mut state = None;
    for line in lines {
        let mut words = line.split_ascii_whitespace();
        if words.next() != Some("STATE") {
            return Err(ControllerError(
                "journal state line is malformed".to_owned(),
            ));
        }
        let token = words
            .next()
            .ok_or_else(|| ControllerError("journal state token is missing".to_owned()))?;
        let parsed = UpdateState::parse(token)
            .ok_or_else(|| ControllerError("journal state token is unknown".to_owned()))?;
        let mut fields = BTreeMap::new();
        for word in words {
            let (key, value) = word
                .split_once('=')
                .ok_or_else(|| ControllerError("journal field is malformed".to_owned()))?;
            if key.is_empty()
                || value.is_empty()
                || fields.insert(key.to_owned(), value.to_owned()).is_some()
            {
                return Err(ControllerError(
                    "journal field is empty or duplicated".to_owned(),
                ));
            }
        }
        validate_journal_fields(header, parsed, &fields)?;
        if let Some(previous) = state {
            if !valid_transition(previous, parsed) {
                return Err(ControllerError(
                    "journal transition history is invalid".to_owned(),
                ));
            }
        } else if parsed != UpdateState::Begun {
            return Err(ControllerError(
                "journal does not begin at BEGUN".to_owned(),
            ));
        }
        state = Some(parsed);
    }
    state.ok_or_else(|| ControllerError("journal has no state".to_owned()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PendingJournalAction {
    Discard,
    Promote(UpdateState),
}

fn classify_pending_journal_snapshot(
    canonical: &str,
    canonical_state: UpdateState,
    pending: &str,
    header: &'static str,
) -> Result<PendingJournalAction> {
    if pending == canonical {
        return Ok(PendingJournalAction::Discard);
    }
    let parsed = parse_journal_text(pending, header);
    let exact_successor = pending.starts_with(canonical)
        && pending.strip_prefix(canonical).is_some_and(|suffix| {
            suffix.ends_with('\n')
                && !suffix.is_empty()
                && !suffix[..suffix.len() - 1].contains('\n')
        });
    match (exact_successor, parsed) {
        (true, Ok(next)) if valid_transition(canonical_state, next) => {
            Ok(PendingJournalAction::Promote(next))
        }
        (_, Err(_)) => Ok(PendingJournalAction::Discard),
        _ => Err(ControllerError(
            "pending journal snapshot diverges from canonical history".to_owned(),
        )),
    }
}

impl Journal {
    fn create(path: &Path, header: &'static str, uid: u32, gid: u32) -> Result<Self> {
        let text = format!("{header}\nSTATE {}\n", UpdateState::Begun.token());
        write_new_private(path, text.as_bytes(), uid, gid, 0o600)?;
        if parse_journal_text(&read_bounded_utf8(path, 128 * 1_024)?, header)? != UpdateState::Begun
        {
            return Err(ControllerError(
                "new journal did not preserve its initial state".to_owned(),
            ));
        }
        Ok(Self {
            path: path.to_path_buf(),
            uid,
            gid,
            header,
            state: UpdateState::Begun,
        })
    }

    fn record(&mut self, state: UpdateState, fields: &[(&str, String)]) -> Result<()> {
        self.reconcile()?;
        if !valid_transition(self.state, state) {
            return Err(ControllerError(format!(
                "invalid journal transition {} -> {}",
                self.state.token(),
                state.token()
            )));
        }
        for (key, value) in fields {
            if key.is_empty()
                || !key
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
                || value.is_empty()
                || value
                    .bytes()
                    .any(|byte| byte.is_ascii_whitespace() || byte == b'=')
            {
                return Err(ControllerError("journal field is not canonical".to_owned()));
            }
        }
        let field_map = fields
            .iter()
            .map(|(key, value)| ((*key).to_owned(), value.clone()))
            .collect::<BTreeMap<_, _>>();
        if field_map.len() != fields.len() {
            return Err(ControllerError(
                "journal record contains duplicate fields".to_owned(),
            ));
        }
        validate_journal_fields(self.header, state, &field_map)?;
        require_regular(&self.path, self.uid, self.gid, 0o600)?;
        let mut snapshot = read_bounded_utf8(&self.path, 128 * 1_024)?;
        if parse_journal_text(&snapshot, self.header)? != self.state {
            return Err(ControllerError(
                "journal history changed before atomic transition".to_owned(),
            ));
        }
        let mut line = format!("STATE {}", state.token());
        for (key, value) in fields {
            line.push(' ');
            line.push_str(key);
            line.push('=');
            line.push_str(value);
        }
        line.push('\n');
        if snapshot.len().saturating_add(line.len()) > 128 * 1_024 {
            return Err(ControllerError(
                "atomic journal snapshot exceeds its bound".to_owned(),
            ));
        }
        snapshot.push_str(&line);
        if parse_journal_text(&snapshot, self.header)? != state {
            return Err(ControllerError(
                "new atomic journal snapshot is invalid".to_owned(),
            ));
        }
        let file_name = self
            .path
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| ControllerError("journal filename is not UTF-8".to_owned()))?;
        let pending = self.path.with_file_name(format!("{file_name}.pending"));
        require_absent(&pending, "atomic journal pending snapshot")?;
        write_new_private(&pending, snapshot.as_bytes(), self.uid, self.gid, 0o600)?;
        if parse_journal_text(&read_bounded_utf8(&pending, 128 * 1_024)?, self.header)? != state {
            return Err(ControllerError(
                "synced journal pending snapshot changed".to_owned(),
            ));
        }
        fs::rename(&pending, &self.path)?;
        fsync_parent(&self.path)?;
        require_regular(&self.path, self.uid, self.gid, 0o600)?;
        if parse_journal_text(&read_bounded_utf8(&self.path, 128 * 1_024)?, self.header)? != state {
            return Err(ControllerError(
                "published atomic journal snapshot changed".to_owned(),
            ));
        }
        self.state = state;
        Ok(())
    }

    fn reconcile(&mut self) -> Result<()> {
        require_regular(&self.path, self.uid, self.gid, 0o600)?;
        let mut canonical = read_bounded_utf8(&self.path, 128 * 1_024)?;
        let mut state = parse_journal_text(&canonical, self.header)?;
        let file_name = self
            .path
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| ControllerError("journal filename is not UTF-8".to_owned()))?;
        let pending = self.path.with_file_name(format!("{file_name}.pending"));
        match fs::symlink_metadata(&pending) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
            Ok(_) => {
                let metadata = require_regular(&pending, self.uid, self.gid, 0o600)?;
                if metadata.len() > 128 * 1_024 {
                    return Err(ControllerError(
                        "unpublished journal snapshot exceeds its bound".to_owned(),
                    ));
                }
                let pending_text = read_bounded_utf8(&pending, 128 * 1_024)?;
                match classify_pending_journal_snapshot(
                    &canonical,
                    state,
                    &pending_text,
                    self.header,
                )? {
                    PendingJournalAction::Discard => {
                        fs::remove_file(&pending)?;
                        fsync_parent(&pending)?;
                    }
                    PendingJournalAction::Promote(next) => {
                        fs::rename(&pending, &self.path)?;
                        fsync_parent(&self.path)?;
                        canonical = pending_text;
                        state = next;
                    }
                }
            }
        }
        require_regular(&self.path, self.uid, self.gid, 0o600)?;
        if read_bounded_utf8(&self.path, 128 * 1_024)? != canonical
            || parse_journal_text(&canonical, self.header)? != state
        {
            return Err(ControllerError(
                "journal changed during pending reconciliation".to_owned(),
            ));
        }
        self.state = state;
        Ok(())
    }

    fn effective_state_with_pending(&self) -> Result<UpdateState> {
        require_regular(&self.path, self.uid, self.gid, 0o600)?;
        let canonical = read_bounded_utf8(&self.path, 128 * 1_024)?;
        let canonical_state = parse_journal_text(&canonical, self.header)?;
        let file_name = self
            .path
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| ControllerError("journal filename is not UTF-8".to_owned()))?;
        let pending = self.path.with_file_name(format!("{file_name}.pending"));
        match fs::symlink_metadata(&pending) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(canonical_state),
            Err(error) => Err(error.into()),
            Ok(_) => {
                let metadata = require_regular(&pending, self.uid, self.gid, 0o600)?;
                if metadata.len() > 128 * 1_024 {
                    return Err(ControllerError(
                        "unpublished journal snapshot exceeds its bound".to_owned(),
                    ));
                }
                let pending_text = read_bounded_utf8(&pending, 128 * 1_024)?;
                Ok(
                    match classify_pending_journal_snapshot(
                        &canonical,
                        canonical_state,
                        &pending_text,
                        self.header,
                    )? {
                        PendingJournalAction::Discard => canonical_state,
                        PendingJournalAction::Promote(state) => state,
                    },
                )
            }
        }
    }

    fn exact_fields_for_state(&self, target: UpdateState) -> Result<BTreeMap<String, String>> {
        let text = read_bounded_utf8(&self.path, 128 * 1_024)?;
        if parse_journal_text(&text, self.header)? != self.state {
            return Err(ControllerError(
                "journal changed before field recovery".to_owned(),
            ));
        }
        let mut found = None;
        for line in text.lines().skip(1) {
            let mut words = line.split_ascii_whitespace();
            if words.next() != Some("STATE") {
                return Err(ControllerError("journal field line changed".to_owned()));
            }
            if words.next() == Some(target.token()) {
                if found.is_some() {
                    return Err(ControllerError(
                        "journal state record is duplicated".to_owned(),
                    ));
                }
                let mut fields = BTreeMap::new();
                for word in words {
                    let (key, value) = word.split_once('=').ok_or_else(|| {
                        ControllerError("journal recovered field is malformed".to_owned())
                    })?;
                    if fields.insert(key.to_owned(), value.to_owned()).is_some() {
                        return Err(ControllerError(
                            "journal recovered field is duplicated".to_owned(),
                        ));
                    }
                }
                found = Some(fields);
            }
        }
        found.ok_or_else(|| ControllerError("journal target state record is absent".to_owned()))
    }

    fn open(path: &Path, header: &'static str, uid: u32, gid: u32) -> Result<Self> {
        require_regular(path, uid, gid, 0o600)?;
        let state = parse_journal_text(&read_bounded_utf8(path, 128 * 1_024)?, header)?;
        let file_name = path
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| ControllerError("journal filename is not UTF-8".to_owned()))?;
        let pending = path.with_file_name(format!("{file_name}.pending"));
        match fs::symlink_metadata(&pending) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
            Ok(_) => {
                let metadata = require_regular(&pending, uid, gid, 0o600)?;
                if metadata.len() > 128 * 1_024 {
                    return Err(ControllerError(
                        "unpublished journal snapshot exceeds its bound".to_owned(),
                    ));
                }
            }
        }
        Ok(Self {
            path: path.to_path_buf(),
            uid,
            gid,
            header,
            state,
        })
    }
}

fn create_user_layout(nonce: &str) -> Result<UserLayout> {
    validate_nonce(nonce)?;
    require_directory(Path::new(USER_SUPPORT), USER_ID, USER_GROUP, 0o700)?;
    if !Path::new(USER_UPDATE_ROOT).exists() {
        fs::DirBuilder::new().mode(0o700).create(USER_UPDATE_ROOT)?;
        fsync_parent(Path::new(USER_UPDATE_ROOT))?;
    }
    require_directory(Path::new(USER_UPDATE_ROOT), USER_ID, USER_GROUP, 0o700)?;
    require_exact_child_names(Path::new(USER_UPDATE_ROOT), &[], "fresh user update root")?;
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
        .as_secs();
    let evidence = Path::new(USER_UPDATE_ROOT).join(format!(
        "diagnostic-driver-v1-{seconds}-{}-{nonce}",
        std::process::id()
    ));
    fs::DirBuilder::new().mode(0o700).create(&evidence)?;
    let probes = evidence.join("probes");
    fs::DirBuilder::new().mode(0o700).create(&probes)?;
    fsync_parent(&probes)?;
    Ok(UserLayout {
        journal: evidence.join("journal.log"),
        result: evidence.join("result.txt"),
        request: evidence.join("root-request.txt"),
        reader: evidence.join("opensteamer-diagnostic-snapshot-reader"),
        evidence,
    })
}

fn root_layout(nonce: &str) -> Result<RootLayout> {
    validate_nonce(nonce)?;
    let root = Path::new(ROOT_UPDATE_ROOT).join(format!("transaction-{nonce}"));
    Ok(RootLayout {
        journal: root.join("journal.log"),
        result: root.join("result.txt"),
        prior_driver: root.join("prior-driver/OpensteamerVirtualMicrophone.driver"),
        candidate_stage: root.join("candidate-stage/OpensteamerVirtualMicrophone.driver"),
        failed_driver: root.join("failed-driver/OpensteamerVirtualMicrophone.driver"),
        rollback_reserve: root.join("rollback-reserve.bin"),
        state: root.join("state.txt"),
        recovery_request: root.join("sealed-root-request.txt"),
        recovery_result: root.join("recovery-result.txt"),
        root,
    })
}

fn current_binary_identity() -> Result<(PathBuf, String, Vec<u8>)> {
    let executable = env::current_exe()?;
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(&executable)?;
    let metadata = file.metadata()?;
    let named = require_regular(&executable, USER_ID, USER_GROUP, 0o500)?;
    if metadata.dev() != named.dev()
        || metadata.ino() != named.ino()
        || metadata.len() == 0
        || metadata.len() > 16 * 1_048_576
    {
        return Err(ControllerError(
            "controller binary size is unsafe".to_owned(),
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    let named_after = require_regular(&executable, USER_ID, USER_GROUP, 0o500)?;
    if bytes.len() as u64 != metadata.len()
        || metadata.dev() != after.dev()
        || metadata.ino() != after.ino()
        || metadata.dev() != named_after.dev()
        || metadata.ino() != named_after.ino()
        || metadata.len() != named_after.len()
    {
        return Err(ControllerError(
            "controller binary changed during identity proof".to_owned(),
        ));
    }
    let digest = sha256_bytes(&bytes)?;
    Ok((executable, digest, bytes))
}

fn root_request_text(request: &RootRequest) -> Result<String> {
    Ok(format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_REQUEST_V1\nnonce={}\nevidence={}\ncontroller_sha256={}\nroot_controller={}\nreader_sha256={}\nauthorized_commit={}\nauthorized_tree={}\n",
        request.nonce,
        path_text(&request.evidence)?,
        request.controller_sha256,
        path_text(&request.root_controller)?,
        request.reader_sha256,
        request.authorized_commit,
        request.authorized_tree
    ))
}

fn parse_sealed_root_request(path: &Path) -> Result<RootRequest> {
    require_regular(path, ROOT_ID, ROOT_ID, 0o400)?;
    require_no_acl_or_xattrs(path)?;
    parse_root_request_text(&read_bounded_utf8(path, 4_096)?)
}

fn parse_bootstrap_root_request(path: &Path) -> Result<RootRequest> {
    require_sealed_regular(path, ROOT_SEALED_RECORD_MODE)?;
    if path.file_name() != Some(OsStr::new("bootstrap-request.txt")) {
        return Err(ControllerError(
            "bootstrap request filename is not exact".to_owned(),
        ));
    }
    let request = parse_root_request_text(&read_bounded_utf8(path, 4_096)?)?;
    if path.parent() != request.root_controller.parent() {
        return Err(ControllerError(
            "bootstrap request escaped its sealed controller support".to_owned(),
        ));
    }
    Ok(request)
}

fn verify_root_bootstrap_locator(request: &RootRequest) -> Result<()> {
    require_sealed_regular(Path::new(ROOT_BOOTSTRAP_LOCATOR), ROOT_SEALED_RECORD_MODE)?;
    let located = parse_root_request_text(&read_bounded_utf8(
        Path::new(ROOT_BOOTSTRAP_LOCATOR),
        4_096,
    )?)?;
    if root_request_text(&located)? != root_request_text(request)? {
        return Err(ControllerError(
            "sealed bootstrap locator differs from the transaction request".to_owned(),
        ));
    }
    Ok(())
}

fn parse_root_request_text(text: &str) -> Result<RootRequest> {
    let mut lines = text.lines();
    if lines.next() != Some("OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_REQUEST_V1") {
        return Err(ControllerError("root request header changed".to_owned()));
    }
    let mut values = BTreeMap::new();
    for line in lines {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| ControllerError("root request line is malformed".to_owned()))?;
        if values.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(ControllerError(
                "root request contains duplicate key".to_owned(),
            ));
        }
    }
    if !text.ends_with('\n')
        || values.keys().map(String::as_str).collect::<BTreeSet<_>>()
            != [
                "authorized_commit",
                "authorized_tree",
                "controller_sha256",
                "evidence",
                "nonce",
                "reader_sha256",
                "root_controller",
            ]
            .into_iter()
            .collect()
    {
        return Err(ControllerError(
            "root request key set is not exact".to_owned(),
        ));
    }
    let request = RootRequest {
        nonce: values.remove("nonce").unwrap_or_default(),
        evidence: PathBuf::from(values.remove("evidence").unwrap_or_default()),
        controller_sha256: values.remove("controller_sha256").unwrap_or_default(),
        root_controller: PathBuf::from(values.remove("root_controller").unwrap_or_default()),
        reader_sha256: values.remove("reader_sha256").unwrap_or_default(),
        authorized_commit: values.remove("authorized_commit").unwrap_or_default(),
        authorized_tree: values.remove("authorized_tree").unwrap_or_default(),
    };
    validate_nonce(&request.nonce)?;
    require_lower_hex(&request.controller_sha256, 64, "controller SHA-256")?;
    require_lower_hex(&request.reader_sha256, 64, "reader SHA-256")?;
    require_lower_hex(&request.authorized_commit, 40, "authorized commit")?;
    require_lower_hex(&request.authorized_tree, 40, "authorized tree")?;
    let expected_controller = Path::new(ROOT_CONTROLLER_PARENT)
        .join(format!("controller-{}", request.nonce))
        .join("controller");
    if request.reader_sha256 != DIAGNOSTIC_READER_SHA256
        || request.evidence.parent() != Some(Path::new(USER_UPDATE_ROOT))
        || !request
            .evidence
            .file_name()
            .and_then(OsStr::to_str)
            .is_some_and(|leaf| {
                leaf.starts_with("diagnostic-driver-v1-") && leaf.ends_with(&request.nonce)
            })
        || request.root_controller != expected_controller
    {
        return Err(ControllerError(
            "root request escaped its reviewed binding".to_owned(),
        ));
    }
    Ok(request)
}

fn acquire_user_update_lock() -> Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(USER_UPDATE_LOCK)?;
    require_regular(Path::new(USER_UPDATE_LOCK), USER_ID, USER_GROUP, 0o600)?;
    if unsafe { flock(std::os::fd::AsRawFd::as_raw_fd(&file), LOCK_EX | LOCK_NB) } != 0 {
        return Err(ControllerError(
            "another diagnostic-driver update owns the lock".to_owned(),
        ));
    }
    Ok(file)
}

fn acquire_root_update_lock() -> Result<File> {
    require_directory(Path::new(ROOT_SUPPORT), ROOT_ID, ROOT_ID, 0o755)?;
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(ROOT_UPDATE_LOCK)?;
    let opened = file.metadata()?;
    let named = require_regular(Path::new(ROOT_UPDATE_LOCK), ROOT_ID, ROOT_ID, 0o600)?;
    if opened.dev() != named.dev() || opened.ino() != named.ino() {
        return Err(ControllerError(
            "root update lock named/opened identity differs".to_owned(),
        ));
    }
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(ControllerError(
            "another root diagnostic-driver transaction is active".to_owned(),
        ));
    }
    let named_after = require_regular(Path::new(ROOT_UPDATE_LOCK), ROOT_ID, ROOT_ID, 0o600)?;
    if named_after.dev() != opened.dev() || named_after.ino() != opened.ino() {
        return Err(ControllerError(
            "root update lock changed while being acquired".to_owned(),
        ));
    }
    Ok(file)
}

fn sudo_fixed(arguments: &[&str], timeout: Duration) -> Result<Output> {
    let mut complete = vec!["-n", "--"];
    complete.extend_from_slice(arguments);
    bounded_output("/usr/bin/sudo", &complete, timeout, false)
}

fn sudo_root_sha256(path: &Path) -> Result<String> {
    let output = sudo_fixed(
        &["/usr/bin/shasum", "-a", "256", path_text(path)?],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "hash restricted root-owned staging file")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "restricted root-owned hash wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("restricted root-owned hash is not UTF-8".to_owned()))?;
    let fields = text.split_ascii_whitespace().collect::<Vec<_>>();
    if fields.len() != 2 || fields[1] != path_text(path)? {
        return Err(ControllerError(
            "restricted root-owned hash output is malformed".to_owned(),
        ));
    }
    require_lower_hex(fields[0], 64, "restricted root-owned SHA-256")?;
    Ok(fields[0].to_owned())
}

fn sudo_root_require_no_acl_or_xattrs(path: &Path) -> Result<()> {
    let listing = sudo_fixed(&["/bin/ls", "-lde@", path_text(path)?], COMMAND_TIMEOUT)?;
    require_success(&listing, "inspect restricted root artifact ACL")?;
    if !listing.stderr.is_empty() {
        return Err(ControllerError(
            "restricted root ACL probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(listing.stdout)
        .map_err(|_| ControllerError("restricted root ACL output is not UTF-8".to_owned()))?;
    let lines = text.lines().collect::<Vec<_>>();
    let mode = lines
        .first()
        .and_then(|line| line.split_ascii_whitespace().next())
        .ok_or_else(|| ControllerError("restricted root ACL output is empty".to_owned()))?;
    if lines.len() != 1 || ls_mode_has_forbidden_extended_metadata(mode) {
        return Err(ControllerError(
            "restricted root artifact has a POSIX ACL or xattr marker".to_owned(),
        ));
    }
    let xattrs = sudo_fixed(&["/usr/bin/xattr", path_text(path)?], COMMAND_TIMEOUT)?;
    require_success(&xattrs, "inspect restricted root artifact xattrs")?;
    if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
        return Err(ControllerError(
            "restricted root artifact has extended attributes".to_owned(),
        ));
    }
    Ok(())
}

fn sudo_stream_root_file(
    destination: &Path,
    bytes: &[u8],
    staging_mode: u32,
    published_mode: u32,
) -> Result<()> {
    if bytes.is_empty() || bytes.len() > 16 * 1_048_576 {
        return Err(ControllerError(
            "root byte-stream payload has an unsafe size".to_owned(),
        ));
    }
    require_absent(destination, "fresh root byte-stream destination")?;
    let staging_mode_text = format!("{staging_mode:04o}");
    let create = sudo_fixed(
        &[
            "/usr/bin/install",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            &staging_mode_text,
            "/dev/null",
            path_text(destination)?,
        ],
        COMMAND_TIMEOUT,
    )?;
    require_success(&create, "create restricted root byte-stream destination")?;
    require_regular(destination, ROOT_ID, ROOT_ID, staging_mode)?;
    sudo_root_require_no_acl_or_xattrs(destination)?;

    let mut child = Command::new("/usr/bin/sudo")
        .args(["-n", "--", "/usr/bin/tee", path_text(destination)?])
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| ControllerError("sudo tee stdin is unavailable".to_owned()))?;
    stdin.write_all(bytes)?;
    drop(stdin);
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| ControllerError("sudo tee stderr is unavailable".to_owned()))?;
    let stderr_reader = thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES));
    let deadline = Instant::now() + COMMAND_TIMEOUT;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stderr_reader.join();
            return Err(ControllerError(
                "sudo tee exceeded its bounded deadline".to_owned(),
            ));
        }
        thread::sleep(Duration::from_millis(20));
    };
    let (stderr, exceeded) = stderr_reader
        .join()
        .map_err(|_| ControllerError("sudo tee stderr reader panicked".to_owned()))??;
    if !status.success() || exceeded || !stderr.is_empty() {
        return Err(ControllerError(
            "restricted root byte-stream publication failed".to_owned(),
        ));
    }
    let expected = sha256_bytes(bytes)?;
    if sudo_root_sha256(destination)? != expected {
        return Err(ControllerError(
            "restricted root byte-stream changed before publication".to_owned(),
        ));
    }
    let published_mode_text = format!("{published_mode:04o}");
    let publish = sudo_fixed(
        &["/bin/chmod", &published_mode_text, path_text(destination)?],
        COMMAND_TIMEOUT,
    )?;
    require_success(&publish, "seal root byte-stream destination")?;
    require_sealed_regular(destination, published_mode)?;
    if sha256(destination)? != expected {
        return Err(ControllerError(
            "sealed root byte-stream changed after publication".to_owned(),
        ));
    }
    Ok(())
}

fn stage_root_owned_controller(
    controller_bytes: &[u8],
    bootstrap_request_bytes: &[u8],
    digest: &str,
    nonce: &str,
    evidence: &Path,
) -> Result<PathBuf> {
    validate_nonce(nonce)?;
    require_lower_hex(digest, 64, "controller digest")?;
    let root_support_identity = root_directory_identity(Path::new(ROOT_SUPPORT), 0o755)?;
    let support = Path::new(ROOT_CONTROLLER_PARENT).join(format!("controller-{nonce}"));
    let controller = support.join("controller");
    let pin = support.join("controller.sha256");
    let identity = support.join("controller-identity.txt");
    let bootstrap_request = support.join("bootstrap-request.txt");
    require_absent(&support, "fresh root controller support")?;
    require_absent(
        Path::new(ROOT_RECOVERY_CONTROLLER),
        "fresh fixed root recovery controller",
    )?;
    require_absent(
        Path::new(ROOT_RECOVERY_CONTROLLER_PIN),
        "fresh fixed root recovery controller pin",
    )?;
    require_absent(
        Path::new(ROOT_BOOTSTRAP_LOCATOR),
        "fresh sealed bootstrap locator",
    )?;
    if sha256_bytes(controller_bytes)? != digest {
        return Err(ControllerError(
            "descriptor-bound controller bytes differ from their pin".to_owned(),
        ));
    }
    // This singleton is the first root-owned artifact publication. It makes a
    // crash during all later namespace/controller staging discoverable while
    // the exact v8 host and installed driver are necessarily untouched.
    sudo_stream_root_file(
        Path::new(ROOT_BOOTSTRAP_LOCATOR),
        bootstrap_request_bytes,
        0o400,
        ROOT_SEALED_RECORD_MODE,
    )?;
    if !Path::new(ROOT_CONTROLLER_PARENT).exists() {
        let create_parent = sudo_fixed(
            &[
                "/usr/bin/install",
                "-d",
                "-o",
                "root",
                "-g",
                "wheel",
                "-m",
                "0711",
                ROOT_CONTROLLER_PARENT,
            ],
            COMMAND_TIMEOUT,
        )?;
        require_success(&create_parent, "create root controller parent")?;
    }
    let controller_parent_identity =
        root_directory_identity(Path::new(ROOT_CONTROLLER_PARENT), ROOT_SEALED_TRAVERSE_MODE)?;
    let support_text = path_text(&support)?;
    let create = sudo_fixed(
        &[
            "/usr/bin/install",
            "-d",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            "0711",
            support_text,
        ],
        COMMAND_TIMEOUT,
    )?;
    require_success(&create, "create root-owned controller support")?;
    let controller_support_identity = root_directory_identity(&support, ROOT_SEALED_TRAVERSE_MODE)?;
    sudo_stream_root_file(
        Path::new(ROOT_RECOVERY_CONTROLLER),
        controller_bytes,
        0o500,
        ROOT_SEALED_EXECUTABLE_MODE,
    )?;
    sudo_stream_root_file(
        Path::new(ROOT_RECOVERY_CONTROLLER_PIN),
        format!("{digest}\n").as_bytes(),
        0o400,
        ROOT_SEALED_RECORD_MODE,
    )?;
    sudo_stream_root_file(
        &controller,
        controller_bytes,
        0o500,
        ROOT_SEALED_EXECUTABLE_MODE,
    )?;
    if sha256(&controller)? != digest || sha256(&controller)? != digest {
        return Err(ControllerError(
            "root-owned controller differs from reviewed bytes".to_owned(),
        ));
    }
    let user_pin = evidence.join("controller.sha256");
    let user_identity = evidence.join("controller-identity.txt");
    write_new_private(
        &user_pin,
        format!("{digest}\n").as_bytes(),
        USER_ID,
        USER_GROUP,
        0o400,
    )?;
    let identity_text = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_CONTROLLER_IDENTITY_V1\ncontroller={}\nsha256={}\n",
        path_text(&controller)?,
        digest
    );
    write_new_private(
        &user_identity,
        identity_text.as_bytes(),
        USER_ID,
        USER_GROUP,
        0o400,
    )?;
    for (bytes, destination_record) in [
        (format!("{digest}\n").into_bytes(), pin.clone()),
        (identity_text.as_bytes().to_vec(), identity.clone()),
        (bootstrap_request_bytes.to_vec(), bootstrap_request.clone()),
    ] {
        sudo_stream_root_file(&destination_record, &bytes, 0o400, ROOT_SEALED_RECORD_MODE)?;
    }
    require_sealed_regular(&pin, ROOT_SEALED_RECORD_MODE)?;
    require_sealed_regular(&identity, ROOT_SEALED_RECORD_MODE)?;
    require_sealed_regular(&bootstrap_request, ROOT_SEALED_RECORD_MODE)?;
    require_sealed_regular(
        Path::new(ROOT_RECOVERY_CONTROLLER),
        ROOT_SEALED_EXECUTABLE_MODE,
    )?;
    require_sealed_regular(
        Path::new(ROOT_RECOVERY_CONTROLLER_PIN),
        ROOT_SEALED_RECORD_MODE,
    )?;
    require_sealed_regular(Path::new(ROOT_BOOTSTRAP_LOCATOR), ROOT_SEALED_RECORD_MODE)?;
    if read_bounded_utf8(&pin, 65)? != format!("{digest}\n")
        || read_bounded_utf8(&identity, 1_024)? != identity_text
        || read_bounded(&bootstrap_request, 4_096)? != bootstrap_request_bytes
        || read_bounded_utf8(Path::new(ROOT_RECOVERY_CONTROLLER_PIN), 65)? != format!("{digest}\n")
        || read_bounded(Path::new(ROOT_BOOTSTRAP_LOCATOR), 4_096)? != bootstrap_request_bytes
        || sha256(Path::new(ROOT_RECOVERY_CONTROLLER))? != digest
        || sha256(&controller)? != digest
    {
        return Err(ControllerError(
            "root controller identity records changed".to_owned(),
        ));
    }
    require_root_directory_identity(Path::new(ROOT_SUPPORT), 0o755, &root_support_identity)?;
    require_root_directory_identity(
        Path::new(ROOT_CONTROLLER_PARENT),
        ROOT_SEALED_TRAVERSE_MODE,
        &controller_parent_identity,
    )?;
    require_root_directory_identity(
        &support,
        ROOT_SEALED_TRAVERSE_MODE,
        &controller_support_identity,
    )?;
    Ok(controller)
}

fn verify_root_controller_identity(request: &RootRequest) -> Result<()> {
    if unsafe { geteuid() } != ROOT_ID
        || env::var("SUDO_UID").ok().as_deref() != Some("501")
        || env::var("SUDO_GID").ok().as_deref() != Some("20")
        || env::var("SUDO_USER").ok().as_deref() != Some("ahmed")
        || env::current_exe()? != request.root_controller
    {
        return Err(ControllerError(
            "root helper escaped its sudo/root-owned identity".to_owned(),
        ));
    }
    require_sealed_regular(&request.root_controller, ROOT_SEALED_EXECUTABLE_MODE)?;
    if sha256(&request.root_controller)? != request.controller_sha256 {
        return Err(ControllerError("root controller digest changed".to_owned()));
    }
    let support = request
        .root_controller
        .parent()
        .ok_or_else(|| ControllerError("root controller has no support directory".to_owned()))?;
    require_sealed_directory(support, ROOT_SEALED_TRAVERSE_MODE)?;
    let pin = support.join("controller.sha256");
    let identity = support.join("controller-identity.txt");
    require_exact_child_names(
        support,
        &[
            "bootstrap-request.txt",
            "controller",
            "controller-identity.txt",
            "controller.sha256",
        ],
        "root controller support",
    )?;
    require_sealed_regular(&pin, ROOT_SEALED_RECORD_MODE)?;
    require_sealed_regular(&identity, ROOT_SEALED_RECORD_MODE)?;
    let expected_identity = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_CONTROLLER_IDENTITY_V1\ncontroller={}\nsha256={}\n",
        path_text(&request.root_controller)?,
        request.controller_sha256
    );
    if read_bounded_utf8(&pin, 65)? != format!("{}\n", request.controller_sha256)
        || read_bounded_utf8(&identity, 1_024)? != expected_identity
    {
        return Err(ControllerError(
            "root controller sealed identity changed".to_owned(),
        ));
    }
    Ok(())
}

fn verify_fixed_root_recovery_controller() -> Result<String> {
    if unsafe { geteuid() } != ROOT_ID
        || env::var("SUDO_UID").ok().as_deref() != Some("501")
        || env::var("SUDO_GID").ok().as_deref() != Some("20")
        || env::var("SUDO_USER").ok().as_deref() != Some("ahmed")
        || env::current_exe()? != Path::new(ROOT_RECOVERY_CONTROLLER)
    {
        return Err(ControllerError(
            "fixed recovery entrypoint escaped its exact sudo identity".to_owned(),
        ));
    }
    require_sealed_directory(Path::new(ROOT_CONTROLLER_PARENT), ROOT_SEALED_TRAVERSE_MODE)?;
    require_sealed_regular(
        Path::new(ROOT_RECOVERY_CONTROLLER),
        ROOT_SEALED_EXECUTABLE_MODE,
    )?;
    require_sealed_regular(
        Path::new(ROOT_RECOVERY_CONTROLLER_PIN),
        ROOT_SEALED_RECORD_MODE,
    )?;
    let pin = read_bounded_utf8(Path::new(ROOT_RECOVERY_CONTROLLER_PIN), 65)?;
    let digest = pin
        .strip_suffix('\n')
        .ok_or_else(|| ControllerError("fixed recovery pin lacks exact newline".to_owned()))?;
    require_lower_hex(digest, 64, "fixed recovery controller digest")?;
    if sha256(Path::new(ROOT_RECOVERY_CONTROLLER))? != digest {
        return Err(ControllerError(
            "fixed recovery controller differs from its root-owned pin".to_owned(),
        ));
    }
    Ok(digest.to_owned())
}

fn run_sudo_helper(executable: &Path, mode: &str, request: Option<&Path>) -> Result<Output> {
    let executable_text = path_text(executable)?;
    let mut arguments = vec!["-n", "--", executable_text, mode];
    if let Some(request) = request {
        arguments.push(path_text(request)?);
    }
    let mut child = Command::new("/usr/bin/sudo")
        .args(arguments)
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ControllerError("sudo stdout absent".to_owned()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| ControllerError("sudo stderr absent".to_owned()))?;
    let stdout_reader = thread::spawn(move || read_pipe_bounded(stdout, MAX_OUTPUT_BYTES));
    let stderr_reader = thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES));
    let deadline = Instant::now() + Duration::from_secs(1_800);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ControllerError(
                "sudo helper exceeded its absolute deadline".to_owned(),
            ));
        }
        thread::sleep(Duration::from_millis(50));
    };
    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| ControllerError("sudo stdout reader panicked".to_owned()))??;
    let (stderr, stderr_exceeded) = stderr_reader
        .join()
        .map_err(|_| ControllerError("sudo stderr reader panicked".to_owned()))??;
    if stdout_exceeded || stderr_exceeded {
        return Err(ControllerError(
            "sudo helper output exceeded its bound".to_owned(),
        ));
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn rename_exclusive(from: &Path, to: &Path) -> Result<()> {
    let from = std::ffi::CString::new(from.as_os_str().as_bytes())
        .map_err(|_| ControllerError("rename source contains NUL".to_owned()))?;
    let to = std::ffi::CString::new(to.as_os_str().as_bytes())
        .map_err(|_| ControllerError("rename destination contains NUL".to_owned()))?;
    if unsafe { renameatx_np(AT_FDCWD, from.as_ptr(), AT_FDCWD, to.as_ptr(), RENAME_EXCL) } != 0 {
        return Err(ControllerError(format!(
            "exclusive rename failed: {}",
            std::io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn ensure_root_update_layout(nonce: &str) -> Result<RootLayout> {
    validate_nonce(nonce)?;
    let support_identity = root_directory_identity(Path::new(ROOT_SUPPORT), 0o755)?;
    if !Path::new(ROOT_UPDATE_ROOT).exists() {
        fs::DirBuilder::new().mode(0o700).create(ROOT_UPDATE_ROOT)?;
        fsync_parent(Path::new(ROOT_UPDATE_ROOT))?;
    }
    let update_root_identity =
        root_directory_identity(Path::new(ROOT_UPDATE_ROOT), ROOT_PRIVATE_MODE)?;
    require_exact_child_names(Path::new(ROOT_UPDATE_ROOT), &[], "fresh root update root")?;
    let layout = root_layout(nonce)?;
    fs::DirBuilder::new().mode(0o700).create(&layout.root)?;
    let layout_root_identity = root_directory_identity(&layout.root, ROOT_PRIVATE_MODE)?;
    let probes = layout.root.join("probes");
    for directory in [
        layout.prior_driver.parent().unwrap(),
        layout.candidate_stage.parent().unwrap(),
        layout.failed_driver.parent().unwrap(),
        probes.as_path(),
    ] {
        fs::DirBuilder::new().mode(0o700).create(directory)?;
        root_directory_identity(directory, ROOT_PRIVATE_MODE)?;
    }
    fsync_parent(&layout.root)?;
    require_root_directory_identity(
        Path::new(ROOT_UPDATE_ROOT),
        ROOT_PRIVATE_MODE,
        &update_root_identity,
    )?;
    require_root_directory_identity(&layout.root, ROOT_PRIVATE_MODE, &layout_root_identity)?;
    require_root_directory_identity(Path::new(ROOT_SUPPORT), 0o755, &support_identity)?;
    Ok(layout)
}

fn available_bytes_on_transaction_filesystem(layout: &RootLayout) -> Result<u64> {
    let root_device = require_directory(&layout.root, ROOT_ID, ROOT_ID, ROOT_PRIVATE_MODE)?.dev();
    let driver_device = fs::symlink_metadata(PRODUCT_DRIVER)?.dev();
    if root_device != driver_device {
        return Err(ControllerError(
            "rollback evidence and canonical driver are not on one filesystem".to_owned(),
        ));
    }
    let output = bounded_output(
        "/bin/df",
        &["-kP", path_text(&layout.root)?],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&output, "measure root transaction filesystem headroom")?;
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "filesystem headroom probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("filesystem headroom output is not UTF-8".to_owned()))?;
    let records = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>();
    if records.len() != 2 {
        return Err(ControllerError(
            "filesystem headroom output is missing or ambiguous".to_owned(),
        ));
    }
    let fields = records[1].split_ascii_whitespace().collect::<Vec<_>>();
    if fields.len() < 6 {
        return Err(ControllerError(
            "filesystem headroom record is malformed".to_owned(),
        ));
    }
    let available_kib = fields[3]
        .parse::<u64>()
        .map_err(|_| ControllerError("available filesystem blocks are malformed".to_owned()))?;
    available_kib
        .checked_mul(1_024)
        .ok_or_else(|| ControllerError("available filesystem bytes overflowed".to_owned()))
}

fn allocate_rollback_reserve(layout: &RootLayout) -> Result<RollbackReserve> {
    require_absent(&layout.rollback_reserve, "rollback reserve")?;
    let before = available_bytes_on_transaction_filesystem(layout)?;
    let required = MINIMUM_PRESTOP_AVAILABLE_BYTES.saturating_add(ROLLBACK_RESERVE_BYTES);
    if !prestop_headroom_is_sufficient(before, false) {
        return Err(ControllerError(format!(
            "insufficient pre-stop disk headroom: available={before} required={required}"
        )));
    }
    let mut file = create_private_file(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
    let chunk = [0_u8; 1_048_576];
    let mut written = 0_u64;
    while written < ROLLBACK_RESERVE_BYTES {
        let count = usize::try_from((ROLLBACK_RESERVE_BYTES - written).min(chunk.len() as u64))
            .map_err(|_| ControllerError("rollback reserve write length overflowed".to_owned()))?;
        file.write_all(&chunk[..count])?;
        written += count as u64;
    }
    file.sync_all()?;
    fsync_parent(&layout.rollback_reserve)?;
    let metadata = file.metadata()?;
    let named = require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
    let allocated = metadata
        .blocks()
        .checked_mul(512)
        .ok_or_else(|| ControllerError("rollback reserve allocation overflowed".to_owned()))?;
    if metadata.dev() != named.dev()
        || metadata.ino() != named.ino()
        || metadata.dev() != fs::symlink_metadata(PRODUCT_DRIVER)?.dev()
        || rollback_reserve_released(metadata.len(), allocated).unwrap_or(true)
    {
        return Err(ControllerError(format!(
            "rollback reserve is sparse, partial, foreign, or changed: length={} allocated={allocated}",
            metadata.len()
        )));
    }
    let after = available_bytes_on_transaction_filesystem(layout)?;
    if !prestop_headroom_is_sufficient(after, true) {
        return Err(ControllerError(format!(
            "insufficient disk headroom after reserve allocation: available={after} required={MINIMUM_PRESTOP_AVAILABLE_BYTES}"
        )));
    }
    Ok(RollbackReserve {
        device: metadata.dev(),
        inode: metadata.ino(),
        released: false,
    })
}

fn release_discovered_prestop_reserve(layout: &RootLayout) -> Result<Option<RollbackReserve>> {
    let named_before = match fs::symlink_metadata(&layout.rollback_reserve) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
        Ok(_) => require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?,
    };
    if named_before.dev() != fs::symlink_metadata(PRODUCT_DRIVER)?.dev()
        || named_before.len() > ROLLBACK_RESERVE_BYTES
    {
        return Err(ControllerError(
            "prestop reserve discovery found a foreign or oversized file".to_owned(),
        ));
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(&layout.rollback_reserve)?;
    let opened = file.metadata()?;
    let named_opened = require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
    if opened.dev() != named_before.dev()
        || opened.ino() != named_before.ino()
        || named_opened.dev() != named_before.dev()
        || named_opened.ino() != named_before.ino()
        || opened.len() != named_before.len()
    {
        return Err(ControllerError(
            "prestop reserve changed during exact discovery".to_owned(),
        ));
    }
    if opened.len() != 0 {
        file.set_len(0)?;
        file.sync_all()?;
        fsync_parent(&layout.rollback_reserve)?;
    }
    let after = file.metadata()?;
    let named_after = require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
    if after.dev() != named_before.dev()
        || after.ino() != named_before.ino()
        || named_after.dev() != named_before.dev()
        || named_after.ino() != named_before.ino()
        || after.len() != 0
        || after.blocks().checked_mul(512).unwrap_or(u64::MAX) != 0
    {
        return Err(ControllerError(
            "prestop reserve release did not preserve its exact inode".to_owned(),
        ));
    }
    Ok(Some(RollbackReserve {
        device: after.dev(),
        inode: after.ino(),
        released: true,
    }))
}

fn release_rollback_reserve(
    layout: &RootLayout,
    expected: &RollbackReserve,
) -> Result<RollbackReserve> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(&layout.rollback_reserve)?;
    let before = file.metadata()?;
    let named = require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
    if before.dev() != expected.device
        || before.ino() != expected.inode
        || named.dev() != expected.device
        || named.ino() != expected.inode
    {
        return Err(ControllerError(
            "rollback reserve identity differs from durable state".to_owned(),
        ));
    }
    let allocated = before
        .blocks()
        .checked_mul(512)
        .ok_or_else(|| ControllerError("rollback reserve allocation overflowed".to_owned()))?;
    if !rollback_reserve_released(before.len(), allocated)? {
        file.set_len(0)?;
        file.sync_all()?;
        fsync_parent(&layout.rollback_reserve)?;
    }
    let after = file.metadata()?;
    let named_after = require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
    if after.dev() != expected.device
        || after.ino() != expected.inode
        || named_after.dev() != expected.device
        || named_after.ino() != expected.inode
        || after.len() != 0
        || after.blocks().checked_mul(512).unwrap_or(u64::MAX) != 0
    {
        return Err(ControllerError(
            "rollback reserve was not released on its exact inode".to_owned(),
        ));
    }
    Ok(RollbackReserve {
        device: expected.device,
        inode: expected.inode,
        released: true,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootPointerImage {
    Absent,
    Partial,
    Complete,
}

fn classify_root_pointer_bytes(bytes: Option<&[u8]>, expected: &[u8]) -> Result<RootPointerImage> {
    match bytes {
        None => Ok(RootPointerImage::Absent),
        Some(bytes) if bytes == expected => Ok(RootPointerImage::Complete),
        Some(bytes) if expected.starts_with(bytes) => Ok(RootPointerImage::Partial),
        Some(_) => Err(ControllerError(
            "root active-pointer image is not an exact crash prefix".to_owned(),
        )),
    }
}

fn classify_root_pointer_image(path: &Path, expected: &[u8]) -> Result<RootPointerImage> {
    let metadata = match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return classify_root_pointer_bytes(None, expected)
        }
        Err(error) => return Err(error.into()),
        Ok(_) => {
            let metadata = require_regular(path, ROOT_ID, ROOT_ID, 0o600)?;
            require_no_acl_or_xattrs(path)?;
            metadata
        }
    };
    if metadata.len() > expected.len() as u64 {
        return Err(ControllerError(
            "root active-pointer image exceeds its exact bound".to_owned(),
        ));
    }
    let bytes = read_bounded(path, expected.len() as u64)?;
    classify_root_pointer_bytes(Some(&bytes), expected)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootPointerRecoveryAction {
    UseCanonical,
    PromotePending,
    PreserveHost,
}

fn root_pointer_recovery_action(
    canonical: RootPointerImage,
    pending: RootPointerImage,
) -> Result<RootPointerRecoveryAction> {
    match (canonical, pending) {
        (RootPointerImage::Complete, RootPointerImage::Absent) => {
            Ok(RootPointerRecoveryAction::UseCanonical)
        }
        (RootPointerImage::Absent, RootPointerImage::Complete) => {
            Ok(RootPointerRecoveryAction::PromotePending)
        }
        (RootPointerImage::Absent | RootPointerImage::Partial, _) => {
            Ok(RootPointerRecoveryAction::PreserveHost)
        }
        (RootPointerImage::Complete, _) => Err(ControllerError(
            "complete root pointer has a conflicting pending image".to_owned(),
        )),
    }
}

fn expected_root_pointer_bytes(layout: &RootLayout) -> Result<Vec<u8>> {
    Ok(format!("{}\n", path_text(&layout.root)?).into_bytes())
}

fn write_root_pointer(layout: &RootLayout) -> Result<()> {
    let canonical = Path::new(ROOT_ACTIVE_POINTER);
    let pending = Path::new(ROOT_ACTIVE_POINTER_PENDING);
    require_absent(canonical, "fresh canonical root active pointer")?;
    require_absent(pending, "fresh pending root active pointer")?;
    let bytes = expected_root_pointer_bytes(layout)?;
    write_new_private(pending, &bytes, ROOT_ID, ROOT_ID, 0o600)?;
    if classify_root_pointer_image(pending, &bytes)? != RootPointerImage::Complete {
        return Err(ControllerError(
            "synced root active-pointer pending image changed".to_owned(),
        ));
    }
    rename_exclusive(pending, canonical)?;
    fsync_parent(canonical)?;
    if classify_root_pointer_image(canonical, &bytes)? != RootPointerImage::Complete
        || classify_root_pointer_image(pending, &bytes)? != RootPointerImage::Absent
    {
        return Err(ControllerError(
            "published root active-pointer image changed".to_owned(),
        ));
    }
    Ok(())
}

fn reconcile_root_pointer_for_recovery(request: &RootRequest) -> Result<Option<RootLayout>> {
    let layout = root_layout(&request.nonce)?;
    let expected = expected_root_pointer_bytes(&layout)?;
    let canonical = Path::new(ROOT_ACTIVE_POINTER);
    let pending = Path::new(ROOT_ACTIVE_POINTER_PENDING);
    let action = root_pointer_recovery_action(
        classify_root_pointer_image(canonical, &expected)?,
        classify_root_pointer_image(pending, &expected)?,
    )?;
    match action {
        RootPointerRecoveryAction::UseCanonical => {
            let active = read_root_active_layout()?;
            if active.root != layout.root {
                return Err(ControllerError(
                    "root active pointer differs from its sealed locator".to_owned(),
                ));
            }
            Ok(Some(active))
        }
        RootPointerRecoveryAction::PromotePending => {
            rename_exclusive(pending, canonical)?;
            fsync_parent(canonical)?;
            let active = read_root_active_layout()?;
            if active.root != layout.root {
                return Err(ControllerError(
                    "promoted root pointer differs from its sealed locator".to_owned(),
                ));
            }
            Ok(Some(active))
        }
        RootPointerRecoveryAction::PreserveHost => Ok(None),
    }
}

fn write_root_state(
    layout: &RootLayout,
    state: UpdateState,
    initial_host: &HostGeneration,
    route: Option<&RouteSnapshot>,
) -> Result<()> {
    let route = route.map_or_else(
        || "route=unavailable\n".to_owned(),
        |route| {
            format!(
                "input_uid={}\noutput_uid={}\nsystem_output_uid={}\n",
                route.input_uid, route.output_uid, route.system_output_uid
            )
        },
    );
    for value in route
        .lines()
        .filter_map(|line| line.split_once('=').map(|(_, value)| value))
    {
        if value.bytes().any(|byte| byte.is_ascii_whitespace()) {
            return Err(ControllerError("route UID is not journal-safe".to_owned()));
        }
    }
    let reserve = match fs::symlink_metadata(&layout.rollback_reserve) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            "rollback_reserve=unavailable\n".to_owned()
        }
        Err(error) => return Err(error.into()),
        Ok(_) => {
            let metadata = require_regular(&layout.rollback_reserve, ROOT_ID, ROOT_ID, 0o600)?;
            let allocated = metadata.blocks().checked_mul(512).ok_or_else(|| {
                ControllerError("rollback reserve allocation overflowed".to_owned())
            })?;
            let status = if rollback_reserve_released(metadata.len(), allocated)? {
                "released"
            } else {
                "allocated"
            };
            format!(
                "rollback_reserve_status={status}\nrollback_reserve_device={}\nrollback_reserve_inode={}\nrollback_reserve_bytes={}\n",
                metadata.dev(), metadata.ino(), ROLLBACK_RESERVE_BYTES
            )
        }
    };
    let bytes = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_STATE_V1\nstate={}\ninitial_host_pid={}\ninitial_host_runs={}\ninitial_host_start={}\ninitial_host_nonce={}\ninitial_host_lock_device={}\ninitial_host_lock_inode={}\n{}{}",
        state.token(),
        initial_host.pid,
        initial_host.runs,
        initial_host.process_start,
        initial_host.nonce,
        initial_host.lock_device,
        initial_host.lock_inode,
        reserve,
        route
    );
    if layout.state.exists() {
        require_regular(&layout.state, ROOT_ID, ROOT_ID, 0o600)?;
    }
    let pending = layout
        .root
        .join(format!(".state-{}.pending", state.token()));
    match fs::symlink_metadata(&pending) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            let metadata = require_regular(&pending, ROOT_ID, ROOT_ID, 0o600)?;
            if metadata.len() > 8_192 {
                return Err(ControllerError(
                    "stale root state pending image exceeds its bound".to_owned(),
                ));
            }
            fs::remove_file(&pending)?;
            fsync_parent(&pending)?;
        }
    }
    let mut file = create_private_file(&pending, ROOT_ID, ROOT_ID, 0o600)?;
    file.write_all(bytes.as_bytes())?;
    file.sync_all()?;
    fs::rename(&pending, &layout.state)?;
    fsync_parent(&layout.state)?;
    require_regular(&layout.state, ROOT_ID, ROOT_ID, 0o600)?;
    if read_bounded_utf8(&layout.state, 8_192)? != bytes {
        return Err(ControllerError(
            "atomically published root state differs from intended bytes".to_owned(),
        ));
    }
    Ok(())
}

fn parse_root_state(
    layout: &RootLayout,
) -> Result<(
    UpdateState,
    HostGeneration,
    Option<RouteSnapshot>,
    Option<RollbackReserve>,
)> {
    require_regular(&layout.state, ROOT_ID, ROOT_ID, 0o600)?;
    let text = read_bounded_utf8(&layout.state, 8_192)?;
    parse_root_state_text(&text)
}

fn parse_optional_root_state(
    layout: &RootLayout,
) -> Result<
    Option<(
        UpdateState,
        HostGeneration,
        Option<RouteSnapshot>,
        Option<RollbackReserve>,
    )>,
> {
    match fs::symlink_metadata(&layout.state) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
        Ok(_) => parse_root_state(layout).map(Some),
    }
}

fn remove_stale_root_state_pending_files(layout: &RootLayout) -> Result<()> {
    let mut removed = false;
    for entry in fs::read_dir(&layout.root)? {
        let entry = entry?;
        let leaf = entry
            .file_name()
            .into_string()
            .map_err(|_| ControllerError("root transaction child is not UTF-8".to_owned()))?;
        let Some(token) = leaf
            .strip_prefix(".state-")
            .and_then(|value| value.strip_suffix(".pending"))
        else {
            continue;
        };
        if UpdateState::parse(token).is_none() {
            return Err(ControllerError(
                "root state pending filename has an unknown token".to_owned(),
            ));
        }
        let path = layout.root.join(&leaf);
        let metadata = require_regular(&path, ROOT_ID, ROOT_ID, 0o600)?;
        if metadata.len() > 8_192 {
            return Err(ControllerError(
                "root state pending image exceeds its bound".to_owned(),
            ));
        }
        fs::remove_file(&path)?;
        removed = true;
    }
    if removed {
        fsync_parent(&layout.state)?;
    }
    Ok(())
}

fn parse_root_state_text(
    text: &str,
) -> Result<(
    UpdateState,
    HostGeneration,
    Option<RouteSnapshot>,
    Option<RollbackReserve>,
)> {
    let mut lines = text.lines();
    if lines.next() != Some("OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_STATE_V1") || !text.ends_with('\n')
    {
        return Err(ControllerError(
            "root state header/termination changed".to_owned(),
        ));
    }
    let mut values = BTreeMap::new();
    for line in lines {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| ControllerError("root state line is malformed".to_owned()))?;
        if values.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(ControllerError(
                "root state contains duplicate key".to_owned(),
            ));
        }
    }
    let state = UpdateState::parse(values.remove("state").unwrap_or_default().as_str())
        .ok_or_else(|| ControllerError("root state token is invalid".to_owned()))?;
    let pid = parse_positive_u32(
        &values.remove("initial_host_pid").unwrap_or_default(),
        "initial host PID",
    )?;
    let runs_text = values.remove("initial_host_runs").unwrap_or_default();
    require_canonical_positive_decimal(&runs_text, "initial host runs")?;
    let runs = runs_text
        .parse::<u64>()
        .map_err(|_| ControllerError("initial host runs overflowed".to_owned()))?;
    let process_start = values.remove("initial_host_start").unwrap_or_default();
    validate_process_start_identity(&process_start)?;
    let nonce = values.remove("initial_host_nonce").unwrap_or_default();
    require_lower_hex(&nonce, 64, "initial host generation nonce")?;
    let lock_device_text = values
        .remove("initial_host_lock_device")
        .unwrap_or_default();
    require_canonical_positive_decimal(&lock_device_text, "initial host lock device")?;
    let lock_device = lock_device_text
        .parse::<u64>()
        .map_err(|_| ControllerError("initial host lock device overflowed".to_owned()))?;
    let lock_inode_text = values.remove("initial_host_lock_inode").unwrap_or_default();
    require_canonical_positive_decimal(&lock_inode_text, "initial host lock inode")?;
    let lock_inode = lock_inode_text
        .parse::<u64>()
        .map_err(|_| ControllerError("initial host lock inode overflowed".to_owned()))?;
    let reserve = match values.remove("rollback_reserve") {
        Some(value) if value == "unavailable" => {
            if values.contains_key("rollback_reserve_status")
                || values.contains_key("rollback_reserve_device")
                || values.contains_key("rollback_reserve_inode")
                || values.contains_key("rollback_reserve_bytes")
            {
                return Err(ControllerError(
                    "unavailable rollback reserve has extra identity fields".to_owned(),
                ));
            }
            None
        }
        Some(_) => {
            return Err(ControllerError(
                "root state rollback reserve marker is invalid".to_owned(),
            ));
        }
        None => {
            let status = values
                .remove("rollback_reserve_status")
                .ok_or_else(|| ControllerError("rollback reserve status is absent".to_owned()))?;
            if !matches!(status.as_str(), "allocated" | "released") {
                return Err(ControllerError(
                    "rollback reserve status is invalid".to_owned(),
                ));
            }
            let device = values
                .remove("rollback_reserve_device")
                .ok_or_else(|| ControllerError("rollback reserve device is absent".to_owned()))?;
            let inode = values
                .remove("rollback_reserve_inode")
                .ok_or_else(|| ControllerError("rollback reserve inode is absent".to_owned()))?;
            let bytes = values.remove("rollback_reserve_bytes").ok_or_else(|| {
                ControllerError("rollback reserve byte count is absent".to_owned())
            })?;
            require_canonical_positive_decimal(&device, "rollback reserve device")?;
            require_canonical_positive_decimal(&inode, "rollback reserve inode")?;
            require_canonical_positive_decimal(&bytes, "rollback reserve byte count")?;
            let bytes = bytes.parse::<u64>().map_err(|_| {
                ControllerError("rollback reserve byte count overflowed".to_owned())
            })?;
            if bytes != ROLLBACK_RESERVE_BYTES {
                return Err(ControllerError(
                    "rollback reserve byte count differs from its pin".to_owned(),
                ));
            }
            Some(RollbackReserve {
                device: device.parse::<u64>().map_err(|_| {
                    ControllerError("rollback reserve device overflowed".to_owned())
                })?,
                inode: inode
                    .parse::<u64>()
                    .map_err(|_| ControllerError("rollback reserve inode overflowed".to_owned()))?,
                released: status == "released",
            })
        }
    };
    let route = match values.remove("route") {
        Some(value) if value == "unavailable" => None,
        Some(_) => {
            return Err(ControllerError(
                "root state route marker is invalid".to_owned(),
            ))
        }
        None => {
            let input_uid = values.remove("input_uid").unwrap_or_default();
            let output_uid = values.remove("output_uid").unwrap_or_default();
            let system_output_uid = values.remove("system_output_uid").unwrap_or_default();
            if [
                input_uid.as_str(),
                output_uid.as_str(),
                system_output_uid.as_str(),
            ]
            .iter()
            .any(|value| value.is_empty() || value.bytes().any(|byte| byte.is_ascii_whitespace()))
            {
                return Err(ControllerError(
                    "root state route UID is invalid".to_owned(),
                ));
            }
            Some(RouteSnapshot {
                input_uid,
                output_uid,
                system_output_uid,
            })
        }
    };
    if !values.is_empty() {
        return Err(ControllerError(
            "root state key set is not exact".to_owned(),
        ));
    }
    Ok((
        state,
        HostGeneration {
            pid,
            runs,
            process_start,
            nonce,
            lock_device,
            lock_inode,
        },
        route,
        reserve,
    ))
}

fn journal_and_root_state_are_crash_coherent(journal: UpdateState, state: UpdateState) -> bool {
    use UpdateState::*;
    matches!(
        (journal, state),
        (Authenticated, Authenticated)
            | (PrestopAborted, PrestopAborted)
            | (Authenticated, HostStopInitiated)
            | (HostStopInitiated, HostStopInitiated)
            | (HostStopped, HostStopInitiated)
            | (HostStopped, HostStopped)
            | (PriorDriverRetained, HostStopped)
            | (CandidatePublished, HostStopped)
            | (CandidatePublished, CandidatePublished)
            | (CoreAudioReloaded, CandidatePublished)
            | (CoreAudioReloaded, CoreAudioReloaded)
            | (DriverValidated, CoreAudioReloaded)
            | (DriverValidated, DriverValidated)
            | (HostBootstrapped, DriverValidated)
            | (HostBootstrapped, HostBootstrapped)
            | (ReadyVerified, HostBootstrapped)
            | (ReadyVerified, ReadyVerified)
            | (Committed, ReadyVerified)
            | (Committed, Committed)
            | (RollbackStarted, HostStopInitiated)
            | (RollbackStarted, HostStopped)
            | (RollbackStarted, CandidatePublished)
            | (RollbackStarted, CoreAudioReloaded)
            | (RollbackStarted, DriverValidated)
            | (RollbackStarted, HostBootstrapped)
            | (RollbackStarted, ReadyVerified)
            | (RollbackStarted, CriticalFailure)
            | (RollbackStarted, RollbackStarted)
            | (FailedDriverArchived, RollbackStarted)
            | (FailedDriverArchived, FailedDriverArchived)
            | (PriorDriverRestored, RollbackStarted)
            | (PriorDriverRestored, FailedDriverArchived)
            | (PriorDriverRestored, PriorDriverRestored)
            | (RollbackCoreAudioReloadInitiated, PriorDriverRestored)
            | (
                RollbackCoreAudioReloadInitiated,
                RollbackCoreAudioReloadInitiated
            )
            | (RollbackCoreAudioReloaded, RollbackCoreAudioReloadInitiated)
            | (RollbackCoreAudioReloaded, PriorDriverRestored)
            | (RollbackCoreAudioReloaded, RollbackCoreAudioReloaded)
            | (HostRebootstrapped, RollbackCoreAudioReloaded)
            | (HostRebootstrapped, HostRebootstrapped)
            | (RolledBack, HostRebootstrapped)
            | (RolledBack, RolledBack)
            | (CriticalFailure, HostStopInitiated)
            | (CriticalFailure, HostStopped)
            | (CriticalFailure, CandidatePublished)
            | (CriticalFailure, CoreAudioReloaded)
            | (CriticalFailure, DriverValidated)
            | (CriticalFailure, HostBootstrapped)
            | (CriticalFailure, ReadyVerified)
            | (CriticalFailure, RollbackStarted)
            | (CriticalFailure, FailedDriverArchived)
            | (CriticalFailure, PriorDriverRestored)
            | (CriticalFailure, RollbackCoreAudioReloadInitiated)
            | (CriticalFailure, RollbackCoreAudioReloaded)
            | (CriticalFailure, HostRebootstrapped)
            | (CriticalFailure, CriticalFailure)
    )
}

// UID501_OPENAT_HELPER_IMPLEMENTATION
#[derive(Clone, Debug, Eq, PartialEq)]
struct OpenatIdentity {
    device: u64,
    inode: u64,
    uid: u32,
    gid: u32,
    mode: u32,
    length: u64,
    links: u64,
    flags: u32,
}

fn identity_from_metadata(metadata: &fs::Metadata) -> OpenatIdentity {
    OpenatIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        uid: metadata.uid(),
        gid: metadata.gid(),
        mode: metadata.permissions().mode() & 0o7777,
        length: metadata.len(),
        links: metadata.nlink(),
        flags: metadata.st_flags(),
    }
}

fn uid501_source_path_is_allowed(path: &Path, generated: bool) -> bool {
    if generated {
        return path
            .parent()
            .and_then(Path::parent)
            .is_some_and(|evidence| {
                evidence.parent() == Some(Path::new(USER_UPDATE_ROOT))
                    && evidence
                        .file_name()
                        .and_then(OsStr::to_str)
                        .is_some_and(|leaf| leaf.starts_with("diagnostic-driver-v1-"))
                    && path == evidence.join("probes/both-order.json")
            });
    }
    if path == Path::new(BOTH_ORDER_PROBE) {
        return true;
    }
    if matches!(
        path_text(path),
        Ok(HOST_EXECUTABLE) | Ok(HOST_PLIST) | Ok(LEGACY_EXECUTABLE) | Ok(LEGACY_PLIST)
    ) || path == Path::new(HOST_APP).join("Contents/Info.plist")
    {
        return true;
    }
    let candidate = Path::new(CANDIDATE_DRIVER);
    if path.strip_prefix(candidate).is_ok_and(|relative| {
        matches!(
            path_text(relative),
            Ok("Contents/Info.plist")
                | Ok("Contents/MacOS/OpensteamerVirtualMicrophone")
                | Ok("Contents/Resources/APPLE_SAMPLE_LICENSE.txt")
                | Ok("Contents/Resources/en.lproj/Localizable.strings")
                | Ok("Contents/_CodeSignature/CodeResources")
        )
    }) {
        return true;
    }
    path.parent().is_some_and(|evidence| {
        evidence.parent() == Some(Path::new(USER_UPDATE_ROOT))
            && evidence
                .file_name()
                .and_then(OsStr::to_str)
                .is_some_and(|leaf| leaf.starts_with("diagnostic-driver-v1-"))
            && path == evidence.join("opensteamer-diagnostic-snapshot-reader")
    })
}

fn canonical_applications_component_is_exact(
    opened_path: &Path,
    final_component: bool,
    metadata: &fs::Metadata,
) -> bool {
    canonical_applications_values_are_exact(
        opened_path,
        final_component,
        metadata.file_type().is_dir(),
        metadata.uid(),
        metadata.gid(),
        metadata.permissions().mode() & 0o7777,
        metadata.dev(),
        metadata.ino(),
        metadata.nlink(),
        metadata.st_flags(),
    )
}

#[allow(clippy::too_many_arguments)]
fn canonical_applications_values_are_exact(
    opened_path: &Path,
    final_component: bool,
    is_directory: bool,
    uid: u32,
    gid: u32,
    mode: u32,
    device: u64,
    inode: u64,
    links: u64,
    flags: u32,
) -> bool {
    !final_component
        && opened_path == Path::new("/Applications")
        && is_directory
        && uid == ROOT_ID
        && gid == LEGACY_EXECUTABLE_GROUP
        && mode == 0o775
        && device == APPLICATIONS_DEVICE
        && inode == APPLICATIONS_INODE
        && links == APPLICATIONS_NLINK
        && flags == APPLICATIONS_FLAGS
}

fn openat_component_walk_with_final_flags(
    path: &Path,
    final_flags: i32,
) -> Result<(File, Vec<OpenatIdentity>)> {
    if !path.is_absolute() {
        return Err(ControllerError(
            "UID501 openat path is not absolute".to_owned(),
        ));
    }
    let components = path.components().collect::<Vec<_>>();
    if components.len() < 2
        || components[0] != Component::RootDir
        || components[1..]
            .iter()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(ControllerError(
            "UID501 openat path has a non-canonical component".to_owned(),
        ));
    }
    let mut directory = File::open("/")?;
    let mut identities = vec![identity_from_metadata(&directory.metadata()?)];
    let mut opened_path = PathBuf::from("/");
    for (index, component) in components[1..].iter().enumerate() {
        let name = match component {
            Component::Normal(name) => name,
            _ => unreachable!(),
        };
        let name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| ControllerError("UID501 openat component contains NUL".to_owned()))?;
        let final_component = index + 2 == components.len();
        let flags = (if final_component {
            final_flags
        } else {
            O_RDONLY
        }) | O_NOFOLLOW
            | O_CLOEXEC
            | if final_component { 0 } else { O_DIRECTORY };
        let descriptor = unsafe { openat(directory.as_raw_fd(), name.as_ptr(), flags, 0) };
        if descriptor < 0 {
            return Err(ControllerError(format!(
                "UID501 openat component refused: {}",
                std::io::Error::last_os_error()
            )));
        }
        let opened = unsafe { File::from_raw_fd(descriptor) };
        let metadata = opened.metadata()?;
        opened_path.push(OsStr::from_bytes(name.to_bytes()));
        let canonical_applications =
            canonical_applications_component_is_exact(&opened_path, final_component, &metadata);
        if canonical_applications {
            require_no_acl_or_xattrs(Path::new("/Applications"))?;
        }
        // Protective ancestry flags (for example SF_RESTRICTED on /Users and
        // UF_HIDDEN on ~/Library) do not grant mutation rights. They remain
        // part of the before/after opened-FD identity; final files still
        // require the exact pinned zero-flag contract in their callers.
        if (!final_component && !metadata.file_type().is_dir())
            || (final_component
                && if final_flags & O_DIRECTORY != 0 {
                    !metadata.file_type().is_dir()
                } else {
                    !metadata.file_type().is_file()
                })
            || (!final_component
                && metadata.permissions().mode() & 0o022 != 0
                && !canonical_applications)
        {
            return Err(ControllerError(
                "UID501 openat component metadata is unsafe".to_owned(),
            ));
        }
        identities.push(identity_from_metadata(&metadata));
        directory = opened;
    }
    Ok((directory, identities))
}

fn openat_component_walk(path: &Path) -> Result<(File, Vec<OpenatIdentity>)> {
    openat_component_walk_with_final_flags(path, O_RDONLY)
}

fn uid501_openat_read_helper(
    path: &Path,
    expected_mode: u32,
    expected_group: u32,
    size_or_maximum: u64,
    expected_digest: Option<&str>,
) -> Result<()> {
    if unsafe { getuid() } != USER_ID
        || unsafe { geteuid() } != USER_ID
        || !matches!(expected_mode, 0o600 | 0o644 | 0o755)
        || !matches!(expected_group, USER_GROUP | LEGACY_EXECUTABLE_GROUP)
        || size_or_maximum == 0
        || size_or_maximum > MAX_OUTPUT_BYTES as u64
        || !uid501_source_path_is_allowed(path, expected_digest.is_none())
    {
        return Err(ControllerError(
            "UID501 openat helper arguments escaped their exact scope".to_owned(),
        ));
    }
    if let Some(digest) = expected_digest {
        require_lower_hex(digest, 64, "UID501 openat digest")?;
    }
    let (mut file, before_ancestry) = openat_component_walk(path)?;
    let before = file.metadata()?;
    let exact_size = expected_digest.is_some();
    if before.uid() != USER_ID
        || before.gid() != expected_group
        || before.nlink() != 1
        || before.permissions().mode() & 0o7777 != expected_mode
        || before.st_flags() != 0
        || (exact_size && before.len() != size_or_maximum)
        || (!exact_size && (before.len() == 0 || before.len() > size_or_maximum))
    {
        return Err(ControllerError(
            "UID501 openat final-file metadata differs from its contract".to_owned(),
        ));
    }
    let mut bytes = Vec::with_capacity(before.len() as usize);
    Read::by_ref(&mut file)
        .take(size_or_maximum.saturating_add(1))
        .read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    let (named_again, after_ancestry) = openat_component_walk(path)?;
    let named = named_again.metadata()?;
    if bytes.len() as u64 != before.len()
        || identity_from_metadata(&before) != identity_from_metadata(&after)
        || identity_from_metadata(&before) != identity_from_metadata(&named)
        || before_ancestry != after_ancestry
        || expected_digest
            .is_some_and(|digest| sha256_bytes(&bytes).ok().as_deref() != Some(digest))
    {
        return Err(ControllerError(
            "UID501 openat opened/named identity or bytes changed".to_owned(),
        ));
    }
    std::io::stdout().write_all(&bytes)?;
    Ok(())
}

fn read_uid501_openat_bytes(
    source: &Path,
    expected_mode: u32,
    expected_group: u32,
    size_or_maximum: u64,
    expected_digest: Option<&str>,
) -> Result<Vec<u8>> {
    let executable = env::current_exe()?;
    let mode = if expected_digest.is_some() {
        UID501_PINNED_READ_MODE
    } else {
        UID501_GENERATED_READ_MODE
    };
    let mode_text = expected_mode.to_string();
    let group_text = expected_group.to_string();
    let size_text = size_or_maximum.to_string();
    let mut arguments = vec![
        mode,
        path_text(source)?,
        &mode_text,
        &group_text,
        &size_text,
    ];
    if let Some(digest) = expected_digest {
        arguments.push(digest);
    }
    let output = bounded_output(path_text(&executable)?, &arguments, COMMAND_TIMEOUT, true)?;
    require_success(&output, "read UID501 source with exact openat helper")?;
    if !output.stderr.is_empty()
        || (expected_digest.is_some() && output.stdout.len() as u64 != size_or_maximum)
        || (expected_digest.is_none()
            && (output.stdout.is_empty() || output.stdout.len() as u64 > size_or_maximum))
        || expected_digest
            .is_some_and(|digest| sha256_bytes(&output.stdout).ok().as_deref() != Some(digest))
    {
        return Err(ControllerError(
            "UID501 openat helper output differs from its byte contract".to_owned(),
        ));
    }
    Ok(output.stdout)
}

fn openat_child(parent: &File, name: &[u8], flags: i32) -> Result<File> {
    let name = std::ffi::CString::new(name)
        .map_err(|_| ControllerError("host bundle child contains NUL".to_owned()))?;
    let descriptor = unsafe {
        openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags
                | O_CLOEXEC
                | if flags & O_SYMLINK != 0 {
                    0
                } else {
                    O_NOFOLLOW
                },
            0,
        )
    };
    if descriptor < 0 {
        return Err(ControllerError(format!(
            "host bundle openat child failed: {}",
            std::io::Error::last_os_error()
        )));
    }
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

fn list_directory_fd(directory: &File) -> Result<Vec<Vec<u8>>> {
    let duplicate = unsafe { dup(directory.as_raw_fd()) };
    if duplicate < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if unsafe { lseek(duplicate, 0, 0) } < 0 {
        let error = std::io::Error::last_os_error();
        unsafe {
            let _ = File::from_raw_fd(duplicate);
        }
        return Err(error.into());
    }
    let stream = unsafe { fdopendir(duplicate) };
    if stream.is_null() {
        let error = std::io::Error::last_os_error();
        unsafe {
            let _ = File::from_raw_fd(duplicate);
        }
        return Err(error.into());
    }
    let result = (|| {
        let mut names = Vec::new();
        loop {
            unsafe { *__error() = 0 };
            let entry = unsafe { readdir(stream) };
            if entry.is_null() {
                let code = unsafe { *__error() };
                if code != 0 {
                    return Err(ControllerError(format!(
                        "host bundle readdir failed: {}",
                        std::io::Error::from_raw_os_error(code)
                    )));
                }
                break;
            }
            let entry = unsafe { &*entry };
            let name_length = usize::from(entry.name_length);
            if name_length == 0
                || name_length >= entry.name.len()
                || entry.name[name_length] != 0
                || usize::from(entry.record_length) < 22_usize.saturating_add(name_length)
            {
                return Err(ControllerError(
                    "host bundle directory entry is malformed".to_owned(),
                ));
            }
            let name = entry.name[..name_length]
                .iter()
                .map(|byte| *byte as u8)
                .collect::<Vec<_>>();
            if name == b"." || name == b".." {
                continue;
            }
            if entry.inode == 0
                || name.contains(&0)
                || name.contains(&b'/')
                || std::str::from_utf8(&name).is_err()
            {
                return Err(ControllerError(
                    "host bundle directory name is unsafe".to_owned(),
                ));
            }
            names.push(name);
            if names.len() > 512 {
                return Err(ControllerError(
                    "host bundle directory exceeds its node bound".to_owned(),
                ));
            }
        }
        names.sort();
        if names.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(ControllerError(
                "host bundle directory contains duplicate names".to_owned(),
            ));
        }
        Ok(names)
    })();
    let close_result = unsafe { closedir(stream) };
    if close_result != 0 && result.is_ok() {
        return Err(std::io::Error::last_os_error().into());
    }
    result
}

fn descriptor_xattrs(file: &File) -> Result<Vec<(String, u64, String)>> {
    let count = unsafe { flistxattr(file.as_raw_fd(), std::ptr::null_mut(), 0, 0) };
    if count < 0 || count as usize > 64 * 1_024 {
        return Err(ControllerError(
            "host bundle xattr-name list is unavailable or oversized".to_owned(),
        ));
    }
    let mut names = vec![0_u8; count as usize];
    if count > 0 {
        let second = unsafe {
            flistxattr(
                file.as_raw_fd(),
                names.as_mut_ptr().cast::<i8>(),
                names.len(),
                0,
            )
        };
        if second != count {
            return Err(ControllerError(
                "host bundle xattr-name list changed".to_owned(),
            ));
        }
    }
    let mut attributes = Vec::new();
    for raw_name in names
        .split(|byte| *byte == 0)
        .filter(|name| !name.is_empty())
    {
        let name = std::str::from_utf8(raw_name)
            .map_err(|_| ControllerError("host bundle xattr name is not UTF-8".to_owned()))?;
        let c_name = std::ffi::CString::new(raw_name)
            .map_err(|_| ControllerError("host bundle xattr name contains NUL".to_owned()))?;
        let size = unsafe {
            fgetxattr(
                file.as_raw_fd(),
                c_name.as_ptr(),
                std::ptr::null_mut(),
                0,
                0,
                0,
            )
        };
        if size < 0 || size as usize > 1_048_576 {
            return Err(ControllerError(
                "host bundle xattr value is unavailable or oversized".to_owned(),
            ));
        }
        let mut value = vec![0_u8; size as usize];
        if size > 0 {
            let fetched = unsafe {
                fgetxattr(
                    file.as_raw_fd(),
                    c_name.as_ptr(),
                    value.as_mut_ptr().cast::<std::ffi::c_void>(),
                    value.len(),
                    0,
                    0,
                )
            };
            if fetched != size {
                return Err(ControllerError(
                    "host bundle xattr value changed".to_owned(),
                ));
            }
        }
        attributes.push((name.to_owned(), size as u64, sha256_bytes(&value)?));
    }
    attributes.sort();
    if attributes.windows(2).any(|pair| pair[0].0 == pair[1].0) {
        return Err(ControllerError(
            "host bundle xattr list contains duplicates".to_owned(),
        ));
    }
    Ok(attributes)
}

fn readlinkat_exact(parent: &File, name: &[u8]) -> Result<Vec<u8>> {
    let name = std::ffi::CString::new(name)
        .map_err(|_| ControllerError("host bundle symlink name contains NUL".to_owned()))?;
    let mut buffer = vec![0_u8; 4_096];
    let length = unsafe {
        readlinkat(
            parent.as_raw_fd(),
            name.as_ptr(),
            buffer.as_mut_ptr().cast::<i8>(),
            buffer.len(),
        )
    };
    if length <= 0 || length as usize >= buffer.len() {
        return Err(ControllerError(
            "host bundle symlink target is unavailable or oversized".to_owned(),
        ));
    }
    buffer.truncate(length as usize);
    let target = Path::new(OsStr::from_bytes(&buffer));
    if target.is_absolute()
        || target
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(ControllerError(
            "host bundle symlink target escapes its relative link policy".to_owned(),
        ));
    }
    Ok(buffer)
}

fn append_host_manifest_node(
    output: &mut Vec<u8>,
    kind: &str,
    relative: &str,
    metadata: &fs::Metadata,
    content: &str,
    xattrs: &[(String, u64, String)],
) -> Result<()> {
    write!(
        output,
        "{kind}\0{relative}\0{:o}\0{}\0{}\0{}\0{}\0{}\0{}\0{}\0{content}\0{}\0",
        metadata.permissions().mode() & 0o7777,
        metadata.uid(),
        metadata.gid(),
        metadata.nlink(),
        metadata.len(),
        metadata.st_flags(),
        metadata.dev(),
        metadata.ino(),
        xattrs.len(),
    )?;
    for (name, size, digest) in xattrs {
        write!(output, "{name}\0{size}\0{digest}\0")?;
    }
    Ok(())
}

fn validate_host_node_metadata(metadata: &fs::Metadata, kind: &str) -> Result<()> {
    let mode = metadata.permissions().mode() & 0o7777;
    if metadata.uid() != USER_ID
        || metadata.gid() != USER_GROUP
        || metadata.dev() != APPLICATIONS_DEVICE
        || metadata.st_flags() != 0
        || !matches!(
            (kind, mode),
            ("D", 0o755) | ("F", 0o600 | 0o644 | 0o755) | ("L", 0o755)
        )
        || (kind != "D" && metadata.nlink() != 1)
    {
        return Err(ControllerError(
            "host bundle node metadata escaped its exact safety policy".to_owned(),
        ));
    }
    Ok(())
}

fn walk_host_bundle_directory(
    directory: &File,
    relative: &str,
    depth: usize,
    nodes: &mut usize,
    output: &mut Vec<u8>,
) -> Result<()> {
    if depth > 16 || relative.len() > 4_096 || *nodes > 512 {
        return Err(ControllerError(
            "host bundle walk exceeded its structural bound".to_owned(),
        ));
    }
    let directory_before = directory.metadata()?;
    validate_host_node_metadata(&directory_before, "D")?;
    let xattrs_before = descriptor_xattrs(directory)?;
    append_host_manifest_node(
        output,
        "D",
        relative,
        &directory_before,
        "-",
        &xattrs_before,
    )?;
    *nodes += 1;
    let names_before = list_directory_fd(directory)?;
    for name in &names_before {
        let name_text = std::str::from_utf8(name)
            .map_err(|_| ControllerError("host bundle child is not UTF-8".to_owned()))?;
        let child_relative = if relative == "." {
            name_text.to_owned()
        } else {
            format!("{relative}/{name_text}")
        };
        let (mut child, kind, open_flags) = match openat_child(directory, name, O_RDONLY) {
            Ok(child) => {
                let metadata = child.metadata()?;
                if metadata.file_type().is_dir() {
                    (child, "D", O_RDONLY)
                } else if metadata.file_type().is_file() {
                    (child, "F", O_RDONLY)
                } else {
                    return Err(ControllerError(
                        "host bundle contains an unsupported node type".to_owned(),
                    ));
                }
            }
            Err(_) => {
                let child = openat_child(directory, name, O_SYMLINK)?;
                if !child.metadata()?.file_type().is_symlink() {
                    return Err(ControllerError(
                        "host bundle fallback node is not a symlink".to_owned(),
                    ));
                }
                (child, "L", O_SYMLINK)
            }
        };
        let before = child.metadata()?;
        validate_host_node_metadata(&before, kind)?;
        let child_xattrs_before = descriptor_xattrs(&child)?;
        let link_target_before = if kind == "L" {
            Some(readlinkat_exact(directory, name)?)
        } else {
            None
        };
        match kind {
            "D" => walk_host_bundle_directory(&child, &child_relative, depth + 1, nodes, output)?,
            "F" => {
                if before.len() > 64 * 1_048_576 {
                    return Err(ControllerError(
                        "host bundle regular file exceeds its bound".to_owned(),
                    ));
                }
                let mut bytes = Vec::with_capacity(before.len() as usize);
                child.seek(SeekFrom::Start(0))?;
                Read::by_ref(&mut child)
                    .take(before.len().saturating_add(1))
                    .read_to_end(&mut bytes)?;
                if bytes.len() as u64 != before.len() {
                    return Err(ControllerError(
                        "host bundle regular file changed during read".to_owned(),
                    ));
                }
                append_host_manifest_node(
                    output,
                    "F",
                    &child_relative,
                    &before,
                    &sha256_bytes(&bytes)?,
                    &child_xattrs_before,
                )?;
                *nodes += 1;
            }
            "L" => {
                let target = link_target_before.as_deref().ok_or_else(|| {
                    ControllerError("host bundle symlink target was not captured".to_owned())
                })?;
                let target = std::str::from_utf8(target).map_err(|_| {
                    ControllerError("host bundle symlink target is not UTF-8".to_owned())
                })?;
                append_host_manifest_node(
                    output,
                    "L",
                    &child_relative,
                    &before,
                    target,
                    &child_xattrs_before,
                )?;
                *nodes += 1;
            }
            _ => unreachable!(),
        }
        let after = child.metadata()?;
        let named_again = openat_child(directory, name, open_flags)?;
        let named = named_again.metadata()?;
        if identity_from_metadata(&before) != identity_from_metadata(&after)
            || identity_from_metadata(&before) != identity_from_metadata(&named)
            || descriptor_xattrs(&child)? != child_xattrs_before
            || (kind == "L"
                && link_target_before.as_deref()
                    != Some(readlinkat_exact(directory, name)?.as_slice()))
        {
            return Err(ControllerError(
                "host bundle opened/named node changed during manifest capture".to_owned(),
            ));
        }
        if *nodes > 512 || output.len() > 1_048_576 {
            return Err(ControllerError(
                "host bundle manifest exceeded its bound".to_owned(),
            ));
        }
    }
    if list_directory_fd(directory)? != names_before
        || identity_from_metadata(&directory_before)
            != identity_from_metadata(&directory.metadata()?)
        || descriptor_xattrs(directory)? != xattrs_before
    {
        return Err(ControllerError(
            "host bundle directory changed during manifest capture".to_owned(),
        ));
    }
    Ok(())
}

fn capture_uid501_host_bundle_manifest() -> Result<Vec<u8>> {
    if unsafe { getuid() } != USER_ID || unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "host bundle manifest helper requires exact UID501".to_owned(),
        ));
    }
    let (root, ancestry_before) =
        openat_component_walk_with_final_flags(Path::new(HOST_APP), O_RDONLY | O_DIRECTORY)?;
    let mut output = b"OPENSTEAMER_V8_HOST_BUNDLE_FD_MANIFEST_V1\n".to_vec();
    let mut nodes = 0;
    walk_host_bundle_directory(&root, ".", 0, &mut nodes, &mut output)?;
    let (named_again, ancestry_after) =
        openat_component_walk_with_final_flags(Path::new(HOST_APP), O_RDONLY | O_DIRECTORY)?;
    if nodes == 0
        || ancestry_before != ancestry_after
        || identity_from_metadata(&root.metadata()?)
            != identity_from_metadata(&named_again.metadata()?)
    {
        return Err(ControllerError(
            "host bundle root/ancestry changed during manifest capture".to_owned(),
        ));
    }
    write!(output, "END\0nodes={nodes}\0")?;
    Ok(output)
}

fn uid501_host_bundle_manifest_helper() -> Result<()> {
    std::io::stdout().write_all(&capture_uid501_host_bundle_manifest()?)?;
    Ok(())
}

fn verify_uid501_host_bundle_manifest() -> Result<()> {
    let executable = env::current_exe()?;
    let output = bounded_output(
        path_text(&executable)?,
        &[UID501_HOST_MANIFEST_MODE],
        Duration::from_secs(180),
        true,
    )?;
    require_success(&output, "capture exact UID501 host bundle manifest")?;
    if !output.stderr.is_empty()
        || !output
            .stdout
            .starts_with(b"OPENSTEAMER_V8_HOST_BUNDLE_FD_MANIFEST_V1\n")
        || sha256_bytes(&output.stdout)? != HOST_BUNDLE_MANIFEST_SHA256
    {
        return Err(ControllerError(
            "installed v8 host bundle manifest differs from its reviewed pin".to_owned(),
        ));
    }
    Ok(())
}

fn create_root_driver_directory(path: &Path) -> Result<()> {
    require_absent(path, "fresh normalized driver directory")?;
    fs::DirBuilder::new().mode(0o755).create(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
    require_directory(path, ROOT_ID, ROOT_ID, 0o755)?;
    require_no_acl_or_xattrs(path)
}

fn stage_normalized_candidate_driver(destination: &Path) -> Result<()> {
    let source = Path::new(CANDIDATE_DRIVER);
    for relative in [
        "",
        "Contents",
        "Contents/MacOS",
        "Contents/Resources",
        "Contents/Resources/en.lproj",
        "Contents/_CodeSignature",
    ] {
        let path = if relative.is_empty() {
            destination.to_path_buf()
        } else {
            destination.join(relative)
        };
        create_root_driver_directory(&path)?;
    }
    for (relative, mode, size, digest) in [
        (
            "Contents/Info.plist",
            0o644,
            1_165,
            CANDIDATE_INFO_PLIST_SHA256,
        ),
        (
            "Contents/MacOS/OpensteamerVirtualMicrophone",
            0o755,
            170_432,
            CANDIDATE_DRIVER_EXECUTABLE_SHA256,
        ),
        (
            "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
            0o644,
            1_053,
            CANDIDATE_LICENSE_SHA256,
        ),
        (
            "Contents/Resources/en.lproj/Localizable.strings",
            0o644,
            202,
            CANDIDATE_LOCALIZABLE_SHA256,
        ),
        (
            "Contents/_CodeSignature/CodeResources",
            0o644,
            2_841,
            CANDIDATE_CODE_RESOURCES_SHA256,
        ),
    ] {
        let bytes =
            read_uid501_openat_bytes(&source.join(relative), mode, USER_GROUP, size, Some(digest))?;
        let target = destination.join(relative);
        write_new_private(&target, &bytes, ROOT_ID, ROOT_ID, mode)?;
        require_regular(&target, ROOT_ID, ROOT_ID, mode)?;
        require_no_acl_or_xattrs(&target)?;
        if sha256(&target)? != digest {
            return Err(ControllerError(
                "normalized root candidate file changed".to_owned(),
            ));
        }
    }
    verify_driver_bundle(
        destination,
        ROOT_ID,
        ROOT_ID,
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )
}

fn stage_root_artifacts(layout: &RootLayout, request: &RootRequest) -> Result<(PathBuf, PathBuf)> {
    let root_support_identity = root_directory_identity(Path::new(ROOT_SUPPORT), 0o755)?;
    stage_normalized_candidate_driver(&layout.candidate_stage)?;
    let probe_parent = Path::new(ROOT_PROBE_PARENT);
    if !probe_parent.exists() {
        fs::DirBuilder::new()
            .mode(ROOT_SEALED_TRAVERSE_MODE)
            .create(probe_parent)?;
        fs::set_permissions(
            probe_parent,
            fs::Permissions::from_mode(ROOT_SEALED_TRAVERSE_MODE),
        )?;
        fsync_parent(probe_parent)?;
    }
    let probe_parent_identity = root_directory_identity(probe_parent, ROOT_SEALED_TRAVERSE_MODE)?;
    require_exact_child_names(probe_parent, &[], "fresh sealed probe parent")?;
    let probe_dir = probe_parent.join(format!("probes-{}", request.nonce));
    require_absent(&probe_dir, "fresh sealed probe support")?;
    fs::DirBuilder::new()
        .mode(ROOT_SEALED_TRAVERSE_MODE)
        .create(&probe_dir)?;
    fs::set_permissions(
        &probe_dir,
        fs::Permissions::from_mode(ROOT_SEALED_TRAVERSE_MODE),
    )?;
    fsync_parent(&probe_dir)?;
    let probe_directory_identity = root_directory_identity(&probe_dir, ROOT_SEALED_TRAVERSE_MODE)?;
    let reader = probe_dir.join("opensteamer-diagnostic-snapshot-reader");
    let both_order = probe_dir.join("physical-virtual-microphone-probe");
    for (source, destination, expected_size, expected) in [
        (
            request
                .evidence
                .join("opensteamer-diagnostic-snapshot-reader"),
            &reader,
            DIAGNOSTIC_READER_SIZE,
            DIAGNOSTIC_READER_SHA256,
        ),
        (
            PathBuf::from(BOTH_ORDER_PROBE),
            &both_order,
            BOTH_ORDER_PROBE_SIZE,
            BOTH_ORDER_PROBE_SHA256,
        ),
    ] {
        let bytes =
            read_uid501_openat_bytes(&source, 0o755, USER_GROUP, expected_size, Some(expected))?;
        write_new_private(destination, &bytes, ROOT_ID, ROOT_ID, 0o555)?;
        require_sealed_regular(destination, ROOT_SEALED_EXECUTABLE_MODE)?;
        if sha256(destination)? != expected {
            return Err(ControllerError(
                "root-owned validation probe changed".to_owned(),
            ));
        }
    }
    require_exact_child_names(
        &probe_dir,
        &[
            "opensteamer-diagnostic-snapshot-reader",
            "physical-virtual-microphone-probe",
        ],
        "sealed validation probe support",
    )?;
    require_root_directory_identity(Path::new(ROOT_SUPPORT), 0o755, &root_support_identity)?;
    require_root_directory_identity(
        probe_parent,
        ROOT_SEALED_TRAVERSE_MODE,
        &probe_parent_identity,
    )?;
    require_root_directory_identity(
        &probe_dir,
        ROOT_SEALED_TRAVERSE_MODE,
        &probe_directory_identity,
    )?;
    Ok((reader, both_order))
}

fn wait_host_absent(expected_device: u64, expected_inode: u64) -> Result<()> {
    let deadline = Instant::now() + HOST_TIMEOUT;
    loop {
        let service_absent = require_service_absent(HOST_LABEL).is_ok();
        let process_absent = capture_server_processes().is_ok_and(|processes| processes.is_empty());
        let lock_free = prove_lock_free(expected_device, expected_inode).is_ok();
        if service_absent && process_absent && lock_free {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(ControllerError(
                "exact v8 host did not stop and release its shared lock".to_owned(),
            ));
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn stop_exact_v8_host(initial: &HostGeneration) -> Result<()> {
    let current = verify_live_v8_host()?;
    if &current != initial {
        return Err(ControllerError(
            "v8 host changed before stop boundary".to_owned(),
        ));
    }
    let target = format!("gui/{USER_ID}/{HOST_LABEL}");
    let bootout = bounded_output(
        "/bin/launchctl",
        &["bootout", &target],
        COMMAND_TIMEOUT,
        false,
    )?;
    require_success(&bootout, "boot out exact v8 host")?;
    wait_host_absent(initial.lock_device, initial.lock_inode)
}

fn publish_candidate_driver(layout: &RootLayout, journal: &mut Journal) -> Result<()> {
    if !capture_server_processes()?.is_empty() {
        return Err(ControllerError(
            "driver publication refused while host exists".to_owned(),
        ));
    }
    verify_installed_v7_driver()?;
    require_absent(&layout.prior_driver, "retained prior driver")?;
    rename_exclusive(Path::new(PRODUCT_DRIVER), &layout.prior_driver)?;
    fsync_parent(Path::new(PRODUCT_DRIVER))?;
    fsync_parent(&layout.prior_driver)?;
    let prior = fs::symlink_metadata(&layout.prior_driver)?;
    if prior.dev() != INSTALLED_DRIVER_DEVICE || prior.ino() != INSTALLED_DRIVER_INODE {
        return Err(ControllerError(
            "retained prior driver lost exact inode".to_owned(),
        ));
    }
    verify_driver_bundle(
        &layout.prior_driver,
        ROOT_ID,
        ROOT_ID,
        INSTALLED_DRIVER_TREE_SHA256,
        INSTALLED_DRIVER_EXECUTABLE_SHA256,
    )?;
    journal.record(
        UpdateState::PriorDriverRetained,
        &[
            ("device", prior.dev().to_string()),
            ("inode", prior.ino().to_string()),
        ],
    )?;
    require_absent(Path::new(PRODUCT_DRIVER), "canonical driver after retain")?;
    rename_exclusive(&layout.candidate_stage, Path::new(PRODUCT_DRIVER))?;
    fsync_parent(Path::new(PRODUCT_DRIVER))?;
    verify_driver_bundle(
        Path::new(PRODUCT_DRIVER),
        ROOT_ID,
        ROOT_ID,
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )?;
    journal.record(UpdateState::CandidatePublished, &[])
}

// ROOT_HELD_BOTH_ORDER_RESULT: root places the child cwd inside a UID501-owned
// result directory below a non-traversable root ancestor before dropping
// privilege. The child uses one relative filename; no other UID501 process can
// name the directory. Root reseals it before openat(O_NOFOLLOW) capture.
fn run_both_order_with_root_held_result(
    both_order: &Path,
    nonce: &str,
    layout: &RootLayout,
) -> Result<Vec<u8>> {
    let drop_directory = layout.root.join("probes/both-order-result-drop");
    require_absent(&drop_directory, "fresh both-order result drop")?;
    fs::DirBuilder::new()
        .mode(ROOT_PRIVATE_MODE)
        .create(&drop_directory)?;
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        .open(&drop_directory)?;
    let original = directory.metadata()?;
    if original.uid() != ROOT_ID
        || original.gid() != ROOT_ID
        || original.permissions().mode() & 0o7777 != ROOT_PRIVATE_MODE
        || unsafe { fchown(directory.as_raw_fd(), USER_ID, USER_GROUP) } != 0
        || unsafe { fchmod(directory.as_raw_fd(), ROOT_PRIVATE_MODE) } != 0
    {
        return Err(ControllerError(format!(
            "could not prepare root-held both-order result drop: {}",
            std::io::Error::last_os_error()
        )));
    }
    let writable = require_directory(&drop_directory, USER_ID, USER_GROUP, ROOT_PRIVATE_MODE)?;
    if writable.dev() != original.dev() || writable.ino() != original.ino() {
        return Err(ControllerError(
            "both-order result-drop inode changed before probe launch".to_owned(),
        ));
    }
    require_no_acl_or_xattrs(&drop_directory)?;
    require_exact_child_names(&drop_directory, &[], "empty both-order result drop")?;

    let descriptor = directory.as_raw_fd();
    let process_result = bounded_output_in_directory(
        path_text(both_order)?,
        &[
            "mirror-loopback",
            "--nonce",
            nonce,
            "--required-headroom-seconds",
            "60",
            "--result",
            "both-order.json",
        ],
        Duration::from_secs(120),
        true,
        &drop_directory,
    );
    let reseal_owner = unsafe { fchown(descriptor, ROOT_ID, ROOT_ID) };
    let reseal_mode = unsafe { fchmod(descriptor, ROOT_PRIVATE_MODE) };
    if reseal_owner != 0 || reseal_mode != 0 {
        return Err(ControllerError(format!(
            "could not reseal both-order result drop: {}",
            std::io::Error::last_os_error()
        )));
    }
    directory.sync_all()?;
    let output = process_result?;
    require_success(&output, "run exact-UID both-order loopback")?;
    if !output.stdout.is_empty() || !output.stderr.is_empty() {
        return Err(ControllerError(
            "both-order probe wrote unexpected process output".to_owned(),
        ));
    }
    let sealed = root_directory_identity(&drop_directory, ROOT_PRIVATE_MODE)?;
    if sealed.device != original.dev() || sealed.inode != original.ino() {
        return Err(ControllerError(
            "both-order result-drop inode changed after reseal".to_owned(),
        ));
    }
    require_exact_child_names(
        &drop_directory,
        &["both-order.json"],
        "sealed both-order result drop",
    )?;
    let result_name = std::ffi::CString::new("both-order.json").unwrap();
    let result_descriptor = unsafe {
        openat(
            descriptor,
            result_name.as_ptr(),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            0,
        )
    };
    if result_descriptor < 0 {
        return Err(ControllerError(format!(
            "could not open descriptor-bound both-order result: {}",
            std::io::Error::last_os_error()
        )));
    }
    let mut result = unsafe { File::from_raw_fd(result_descriptor) };
    let produced = result.metadata()?;
    if produced.uid() != USER_ID
        || produced.gid() != USER_GROUP
        || produced.nlink() != 1
        || produced.permissions().mode() & 0o7777 != 0o600
        || produced.st_flags() != 0
        || produced.len() == 0
        || produced.len() > MAX_OUTPUT_BYTES as u64
    {
        return Err(ControllerError(
            "descriptor-bound both-order result metadata changed".to_owned(),
        ));
    }
    if unsafe { fchown(result.as_raw_fd(), ROOT_ID, ROOT_ID) } != 0
        || unsafe { fchmod(result.as_raw_fd(), 0o600) } != 0
    {
        return Err(ControllerError(format!(
            "could not seal descriptor-bound both-order result: {}",
            std::io::Error::last_os_error()
        )));
    }
    result.sync_all()?;
    let sealed_result = result.metadata()?;
    let named_again_descriptor = unsafe {
        openat(
            descriptor,
            result_name.as_ptr(),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            0,
        )
    };
    if named_again_descriptor < 0 {
        return Err(ControllerError(
            "sealed both-order result is no longer name-bound".to_owned(),
        ));
    }
    let named_again = unsafe { File::from_raw_fd(named_again_descriptor) };
    if identity_from_metadata(&sealed_result) != identity_from_metadata(&named_again.metadata()?) {
        return Err(ControllerError(
            "sealed both-order opened/named identity differs".to_owned(),
        ));
    }
    let mut bytes = Vec::with_capacity(sealed_result.len() as usize);
    Read::by_ref(&mut result)
        .take(MAX_OUTPUT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 != sealed_result.len()
        || identity_from_metadata(&sealed_result) != identity_from_metadata(&result.metadata()?)
    {
        return Err(ControllerError(
            "sealed both-order result changed while being captured".to_owned(),
        ));
    }
    require_no_acl_or_xattrs(&drop_directory.join("both-order.json"))?;
    Ok(bytes)
}

fn run_passive_driver_validation(
    reader: &Path,
    both_order: &Path,
    request: &RootRequest,
) -> Result<u64> {
    let layout = root_layout(&request.nonce)?;
    let first = read_passive_snapshot(reader, &layout.root.join("probes/osds-before-mirror.json"))?;
    let nonce = format!("diagnostic-driver-v1-{}", request.nonce);
    let result_bytes = run_both_order_with_root_held_result(both_order, &nonce, &layout)?;
    let root_result = layout.root.join("probes/both-order.json");
    write_new_private(&root_result, &result_bytes, ROOT_ID, ROOT_ID, 0o600)?;
    verify_mirror_loopback_result(&result_bytes)?;
    let second = read_passive_snapshot(reader, &layout.root.join("probes/osds-after-mirror.json"))?;
    if first != second {
        return Err(ControllerError(
            "driver instance generation changed across passive validation".to_owned(),
        ));
    }
    Ok(second)
}

// BOUNDED_NATIVE_JSON_VALIDATOR: privileged validation has no interpreter/module dependency.
#[derive(Clone, Debug, PartialEq)]
enum JsonValue {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Array(Vec<JsonValue>),
    Object(BTreeMap<String, JsonValue>),
}

struct JsonParser<'a> {
    bytes: &'a [u8],
    index: usize,
    nodes: usize,
}

impl<'a> JsonParser<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            index: 0,
            nodes: 0,
        }
    }

    fn parse(mut self) -> Result<JsonValue> {
        let value = self.value(0)?;
        self.whitespace();
        if self.index != self.bytes.len() {
            return Err(ControllerError("JSON has trailing bytes".to_owned()));
        }
        Ok(value)
    }

    fn whitespace(&mut self) {
        while self
            .bytes
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b' ' | b'\n' | b'\r' | b'\t'))
        {
            self.index += 1;
        }
    }

    fn value(&mut self, depth: usize) -> Result<JsonValue> {
        self.whitespace();
        self.nodes += 1;
        if depth > 32 || self.nodes > 16_384 {
            return Err(ControllerError("JSON depth/node bound exceeded".to_owned()));
        }
        match self.bytes.get(self.index).copied() {
            Some(b'n') => {
                self.literal(b"null")?;
                Ok(JsonValue::Null)
            }
            Some(b't') => {
                self.literal(b"true")?;
                Ok(JsonValue::Bool(true))
            }
            Some(b'f') => {
                self.literal(b"false")?;
                Ok(JsonValue::Bool(false))
            }
            Some(b'"') => self.string().map(JsonValue::String),
            Some(b'[') => self.array(depth + 1),
            Some(b'{') => self.object(depth + 1),
            Some(b'-' | b'0'..=b'9') => self.number().map(JsonValue::Number),
            _ => Err(ControllerError("JSON value token is invalid".to_owned())),
        }
    }

    fn literal(&mut self, literal: &[u8]) -> Result<()> {
        if self.bytes.get(self.index..self.index + literal.len()) != Some(literal) {
            return Err(ControllerError("JSON literal is malformed".to_owned()));
        }
        self.index += literal.len();
        Ok(())
    }

    fn string(&mut self) -> Result<String> {
        if self.bytes.get(self.index) != Some(&b'"') {
            return Err(ControllerError("JSON string opener is absent".to_owned()));
        }
        self.index += 1;
        let mut output = Vec::new();
        loop {
            let byte = *self
                .bytes
                .get(self.index)
                .ok_or_else(|| ControllerError("JSON string is truncated".to_owned()))?;
            self.index += 1;
            match byte {
                b'"' => break,
                0x00..=0x1f => {
                    return Err(ControllerError(
                        "JSON string contains a control byte".to_owned(),
                    ))
                }
                b'\\' => {
                    let escaped = *self
                        .bytes
                        .get(self.index)
                        .ok_or_else(|| ControllerError("JSON escape is truncated".to_owned()))?;
                    self.index += 1;
                    match escaped {
                        b'"' | b'\\' | b'/' => output.push(escaped),
                        b'b' => output.push(8),
                        b'f' => output.push(12),
                        b'n' => output.push(b'\n'),
                        b'r' => output.push(b'\r'),
                        b't' => output.push(b'\t'),
                        b'u' => {
                            let digits =
                                self.bytes.get(self.index..self.index + 4).ok_or_else(|| {
                                    ControllerError("JSON Unicode escape is truncated".to_owned())
                                })?;
                            let digits = std::str::from_utf8(digits).map_err(|_| {
                                ControllerError("JSON Unicode escape is not ASCII".to_owned())
                            })?;
                            let scalar = u32::from_str_radix(digits, 16).map_err(|_| {
                                ControllerError("JSON Unicode escape is malformed".to_owned())
                            })?;
                            self.index += 4;
                            let character = char::from_u32(scalar).ok_or_else(|| {
                                ControllerError(
                                    "JSON surrogate/non-scalar escape is forbidden".to_owned(),
                                )
                            })?;
                            let mut encoded = [0_u8; 4];
                            output
                                .extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
                        }
                        _ => {
                            return Err(ControllerError("JSON escape token is invalid".to_owned()))
                        }
                    }
                }
                _ => output.push(byte),
            }
            if output.len() > MAX_OUTPUT_BYTES {
                return Err(ControllerError("JSON string exceeds its bound".to_owned()));
            }
        }
        String::from_utf8(output)
            .map_err(|_| ControllerError("JSON string is not valid UTF-8".to_owned()))
    }

    fn number(&mut self) -> Result<String> {
        let start = self.index;
        if self.bytes.get(self.index) == Some(&b'-') {
            self.index += 1;
        }
        match self.bytes.get(self.index).copied() {
            Some(b'0') => self.index += 1,
            Some(b'1'..=b'9') => {
                self.index += 1;
                while self.bytes.get(self.index).is_some_and(u8::is_ascii_digit) {
                    self.index += 1;
                }
            }
            _ => {
                return Err(ControllerError(
                    "JSON number integer is malformed".to_owned(),
                ))
            }
        }
        if self.bytes.get(self.index) == Some(&b'.') {
            self.index += 1;
            let fraction = self.index;
            while self.bytes.get(self.index).is_some_and(u8::is_ascii_digit) {
                self.index += 1;
            }
            if self.index == fraction {
                return Err(ControllerError("JSON fraction is empty".to_owned()));
            }
        }
        if self
            .bytes
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b'e' | b'E'))
        {
            self.index += 1;
            if self
                .bytes
                .get(self.index)
                .is_some_and(|byte| matches!(byte, b'+' | b'-'))
            {
                self.index += 1;
            }
            let exponent = self.index;
            while self.bytes.get(self.index).is_some_and(u8::is_ascii_digit) {
                self.index += 1;
            }
            if self.index == exponent {
                return Err(ControllerError("JSON exponent is empty".to_owned()));
            }
        }
        std::str::from_utf8(&self.bytes[start..self.index])
            .map(str::to_owned)
            .map_err(|_| ControllerError("JSON number is not ASCII".to_owned()))
    }

    fn array(&mut self, depth: usize) -> Result<JsonValue> {
        self.index += 1;
        self.whitespace();
        let mut values = Vec::new();
        if self.bytes.get(self.index) == Some(&b']') {
            self.index += 1;
            return Ok(JsonValue::Array(values));
        }
        loop {
            values.push(self.value(depth)?);
            self.whitespace();
            match self.bytes.get(self.index) {
                Some(b',') => self.index += 1,
                Some(b']') => {
                    self.index += 1;
                    break;
                }
                _ => {
                    return Err(ControllerError(
                        "JSON array delimiter is invalid".to_owned(),
                    ))
                }
            }
        }
        Ok(JsonValue::Array(values))
    }

    fn object(&mut self, depth: usize) -> Result<JsonValue> {
        self.index += 1;
        self.whitespace();
        let mut values = BTreeMap::new();
        if self.bytes.get(self.index) == Some(&b'}') {
            self.index += 1;
            return Ok(JsonValue::Object(values));
        }
        loop {
            self.whitespace();
            let key = self.string()?;
            self.whitespace();
            if self.bytes.get(self.index) != Some(&b':') {
                return Err(ControllerError("JSON object colon is absent".to_owned()));
            }
            self.index += 1;
            let value = self.value(depth)?;
            if values.insert(key, value).is_some() {
                return Err(ControllerError("JSON object key is duplicated".to_owned()));
            }
            self.whitespace();
            match self.bytes.get(self.index) {
                Some(b',') => self.index += 1,
                Some(b'}') => {
                    self.index += 1;
                    break;
                }
                _ => {
                    return Err(ControllerError(
                        "JSON object delimiter is invalid".to_owned(),
                    ))
                }
            }
        }
        Ok(JsonValue::Object(values))
    }
}

fn json_object<'a>(value: &'a JsonValue, label: &str) -> Result<&'a BTreeMap<String, JsonValue>> {
    match value {
        JsonValue::Object(object) => Ok(object),
        _ => Err(ControllerError(format!("JSON {label} is not an object"))),
    }
}

fn json_field<'a>(object: &'a BTreeMap<String, JsonValue>, key: &str) -> Result<&'a JsonValue> {
    object
        .get(key)
        .ok_or_else(|| ControllerError(format!("JSON field is absent: {key}")))
}

fn json_string_is(object: &BTreeMap<String, JsonValue>, key: &str, expected: &str) -> bool {
    matches!(object.get(key), Some(JsonValue::String(value)) if value == expected)
}

fn json_bool_is(object: &BTreeMap<String, JsonValue>, key: &str, expected: bool) -> bool {
    matches!(object.get(key), Some(JsonValue::Bool(value)) if *value == expected)
}

fn json_u64(object: &BTreeMap<String, JsonValue>, key: &str) -> Result<u64> {
    match json_field(object, key)? {
        JsonValue::Number(value)
            if !value.is_empty()
                && value.bytes().all(|byte| byte.is_ascii_digit())
                && (value == "0" || !value.starts_with('0')) =>
        {
            value
                .parse::<u64>()
                .map_err(|_| ControllerError(format!("JSON integer overflowed: {key}")))
        }
        _ => Err(ControllerError(format!(
            "JSON field is not a canonical unsigned integer: {key}"
        ))),
    }
}

fn json_array<'a>(object: &'a BTreeMap<String, JsonValue>, key: &str) -> Result<&'a [JsonValue]> {
    match json_field(object, key)? {
        JsonValue::Array(values) => Ok(values),
        _ => Err(ControllerError(format!(
            "JSON field is not an array: {key}"
        ))),
    }
}

fn json_string_array_equals(
    object: &BTreeMap<String, JsonValue>,
    key: &str,
    expected: &[&str],
) -> Result<bool> {
    let values = json_array(object, key)?;
    Ok(values.len() == expected.len()
        && values.iter().zip(expected).all(
            |(value, expected)| matches!(value, JsonValue::String(value) if value == expected),
        ))
}

fn validate_passive_snapshot_json(bytes: &[u8]) -> Result<u64> {
    let value = JsonParser::new(bytes).parse()?;
    let object = json_object(&value, "passive snapshot")?;
    let generation = json_u64(object, "driverInstanceGeneration")?;
    let zero_counts = [
        "activeClientCount",
        "visibleInputActiveCount",
        "hiddenWriterActiveCount",
        "coreActiveSlotCount",
        "driverRegisteredCount",
        "driverStartedCount",
        "visibleDriverRegisteredCount",
        "hiddenDriverRegisteredCount",
        "visibleDriverStartedCount",
        "hiddenDriverStartedCount",
        "timelineSeed",
        "currentSeedGeneration",
        "anchorHostTicks",
    ];
    if json_u64(object, "readerSchema")? != 1
        || !json_string_is(object, "mode", "read-once")
        || !json_string_is(
            object,
            "claim",
            "read-only-virtual-driver-diagnostic-snapshot",
        )
        || !json_string_is(object, "visibleDeviceUID", VISIBLE_UID)
        || !json_string_is(object, "writerDeviceUID", WRITER_UID)
        || !json_bool_is(object, "endpointReadsCoherent", true)
        || json_u64(object, "snapshotSchemaVersion")? != 1
        || json_u64(object, "snapshotStructSize")? != 8_608
        || generation == 0
        || !json_bool_is(object, "allDeclaredInvariantsHold", true)
        || !json_bool_is(object, "coreInitialized", true)
        || !json_bool_is(object, "timelineActive", false)
        || zero_counts
            .iter()
            .any(|key| json_u64(object, key).ok() != Some(0))
        || !json_string_is(object, "coreActiveSlotBitmap", "0000000000000000")
        || !json_string_is(object, "driverRegisteredSlotBitmap", "0000000000000000")
        || !json_string_is(object, "driverStartedSlotBitmap", "0000000000000000")
        || !json_array(object, "driverClientSlots")?.is_empty()
        || !json_array(object, "coreClientSlots")?.is_empty()
    {
        return Err(ControllerError(
            "passive osDS JSON contract failed".to_owned(),
        ));
    }
    Ok(generation)
}

fn validate_mirror_loopback_json(bytes: &[u8]) -> Result<()> {
    let value = JsonParser::new(bytes).parse()?;
    let object = json_object(&value, "both-order result")?;
    let lifecycle = json_object(json_field(object, "lifecycle")?, "lifecycle")?;
    let defaults = json_object(json_field(object, "defaults")?, "defaults")?;
    let teardown = json_object(json_field(object, "teardown")?, "teardown")?;
    if !json_string_is(
        object,
        "schema",
        "opensteamer.virtual-microphone-mirror-loopback.v2",
    ) || !json_string_is(object, "status", "passed")
        || !json_string_is(object, "mode", "real-dual-audioqueue")
        || !json_bool_is(object, "realQueuePathImplemented", true)
        || !json_string_array_equals(
            lifecycle,
            "requiredStartOrders",
            &["visible-first", "hidden-first"],
        )?
    {
        return Err(ControllerError(
            "both-order result top-level contract failed".to_owned(),
        ));
    }
    let cycles = json_array(lifecycle, "cycles")?;
    if cycles.len() != 2 {
        return Err(ControllerError(
            "both-order lifecycle cycle count changed".to_owned(),
        ));
    }
    for (cycle, start_order) in cycles.iter().zip(["visible-first", "hidden-first"]) {
        let cycle = json_object(cycle, "lifecycle cycle")?;
        if !json_string_is(cycle, "startOrder", start_order)
            || [
                "quiescentBefore",
                "quiescentAfter",
                "nearZeroSharedClock",
                "timelinesAdvanced",
                "queuesStoppedAndDisposed",
            ]
            .iter()
            .any(|key| !json_bool_is(cycle, key, true))
        {
            return Err(ControllerError(
                "both-order lifecycle cycle contract failed".to_owned(),
            ));
        }
    }
    if [
        "inputBeforeAfterEqual",
        "outputBeforeAfterEqual",
        "systemOutputBeforeAfterEqual",
        "hiddenEndpointNeverDefault",
        "virtualEndpointsNeverOutputDefault",
    ]
    .iter()
    .any(|key| !json_bool_is(defaults, key, true))
        || json_u64(defaults, "notificationCount")? != 0
        || !json_bool_is(defaults, "mutated", false)
        || [
            "cleanupEvidenceComplete",
            "callbackGatesDrained",
            "listenersRemoved",
            "contextsReleased",
        ]
        .iter()
        .any(|key| !json_bool_is(teardown, key, true))
        || !json_string_is(object, "failureCode", "none")
        || !json_array(object, "failureReasons")?.is_empty()
    {
        return Err(ControllerError(
            "both-order result invariant contract failed".to_owned(),
        ));
    }
    Ok(())
}

fn read_passive_snapshot(reader: &Path, destination: &Path) -> Result<u64> {
    let reader_output =
        bounded_output(path_text(reader)?, &["--read-once"], COMMAND_TIMEOUT, true)?;
    require_success(&reader_output, "read passive osDS snapshot")?;
    if !reader_output.stderr.is_empty() {
        return Err(ControllerError(
            "passive osDS reader wrote stderr".to_owned(),
        ));
    }
    let reader_text = String::from_utf8(reader_output.stdout)
        .map_err(|_| ControllerError("passive osDS JSON is not UTF-8".to_owned()))?;
    if reader_text.lines().count() != 1 || !reader_text.ends_with('\n') {
        return Err(ControllerError(
            "passive osDS snapshot is not exactly one JSON line".to_owned(),
        ));
    }
    write_new_private(destination, reader_text.as_bytes(), ROOT_ID, ROOT_ID, 0o600)?;
    validate_passive_snapshot_json(reader_text.as_bytes())
}

fn verify_mirror_loopback_result(bytes: &[u8]) -> Result<()> {
    validate_mirror_loopback_json(bytes)
}

fn restart_exact_v8_host(initial: &HostGeneration) -> Result<HostGeneration> {
    require_service_absent(HOST_LABEL)?;
    if !capture_server_processes()?.is_empty() {
        return Err(ControllerError(
            "host restart refused while CaptureServer exists".to_owned(),
        ));
    }
    prove_lock_free(initial.lock_device, initial.lock_inode)?;
    verify_installed_v8_runtime_bytes()?;
    require_legacy_disabled_and_absent()?;
    verify_pairing_metadata_only()?;
    let domain = format!("gui/{USER_ID}");
    let output = bounded_output(
        "/bin/launchctl",
        &["bootstrap", &domain, HOST_PLIST],
        COMMAND_TIMEOUT,
        true,
    )?;
    require_success(&output, "bootstrap exact byte-identical v8 host")?;
    if !output.stdout.is_empty() || !output.stderr.is_empty() {
        return Err(ControllerError(
            "launchctl bootstrap wrote output".to_owned(),
        ));
    }
    let deadline = Instant::now() + HOST_TIMEOUT;
    let generation = loop {
        match verify_live_v8_host() {
            Ok(generation)
                if generation.pid != initial.pid
                    && generation.process_start != initial.process_start
                    && generation.nonce != initial.nonce
                    && generation.lock_device == initial.lock_device
                    && generation.lock_inode == initial.lock_inode
                    && generation.runs == 1 =>
            {
                break generation;
            }
            Ok(_) | Err(_) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(100));
            }
            Ok(_) | Err(_) => {
                return Err(ControllerError(
                    "single healthy replacement v8 host generation was not observed".to_owned(),
                ));
            }
        }
    };
    verify_pairing_metadata_only()?;
    thread::sleep(Duration::from_millis(500));
    if verify_live_v8_host()? != generation {
        return Err(ControllerError(
            "replacement v8 host generation did not remain stable".to_owned(),
        ));
    }
    Ok(generation)
}

fn stop_v8_host_for_rollback(initial: &HostGeneration) -> Result<()> {
    if let Ok(generation) = verify_live_v8_host() {
        if generation.lock_device != initial.lock_device
            || generation.lock_inode != initial.lock_inode
        {
            return Err(ControllerError(
                "rollback host generation uses a different shared-lock inode".to_owned(),
            ));
        }
        return stop_exact_v8_host(&generation);
    }
    if !capture_server_processes()?.is_empty() {
        return Err(ControllerError(
            "rollback found a CaptureServer it could not prove as exact v8".to_owned(),
        ));
    }
    let target = format!("gui/{USER_ID}/{HOST_LABEL}");
    let state = launchctl_print(&target)?;
    if state.status.success() {
        let output = bounded_output(
            "/bin/launchctl",
            &["bootout", &target],
            COMMAND_TIMEOUT,
            false,
        )?;
        require_success(&output, "boot out inert v8 job during rollback")?;
    } else {
        require_service_absent(HOST_LABEL)?;
    }
    wait_host_absent(initial.lock_device, initial.lock_inode)
}

fn verify_retained_v7_driver(path: &Path) -> Result<()> {
    verify_driver_bundle(
        path,
        ROOT_ID,
        ROOT_ID,
        INSTALLED_DRIVER_TREE_SHA256,
        INSTALLED_DRIVER_EXECUTABLE_SHA256,
    )?;
    let metadata = fs::symlink_metadata(path)?;
    if metadata.dev() != INSTALLED_DRIVER_DEVICE || metadata.ino() != INSTALLED_DRIVER_INODE {
        return Err(ControllerError(
            "retained v7 driver lost its exact original inode".to_owned(),
        ));
    }
    Ok(())
}

fn path_is_exact_candidate(path: &Path) -> bool {
    verify_driver_bundle(
        path,
        ROOT_ID,
        ROOT_ID,
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )
    .is_ok()
}

fn path_is_exact_v7(path: &Path) -> bool {
    verify_retained_v7_driver(path).is_ok()
}

fn journal_rollback_failure(
    layout: &RootLayout,
    journal: &mut Journal,
    initial: &HostGeneration,
    route: Option<&RouteSnapshot>,
) {
    if matches!(
        journal.state,
        UpdateState::Committed | UpdateState::RolledBack | UpdateState::PrestopAborted
    ) {
        return;
    }
    let initial_state = journal.state;
    let journal_publish_succeeded = if initial_state == UpdateState::CriticalFailure {
        true
    } else if valid_transition(initial_state, UpdateState::CriticalFailure) {
        if journal.record(UpdateState::CriticalFailure, &[]).is_err() {
            // Never publish a state image that is ahead of the durable journal.
            return;
        }
        true
    } else {
        false
    };
    if critical_failure_state_publication_is_authorized(
        initial_state,
        journal_publish_succeeded,
        journal.state,
    ) {
        let _ = write_root_state(layout, UpdateState::CriticalFailure, initial, route);
    }
}

fn critical_failure_state_publication_is_authorized(
    initial_journal: UpdateState,
    journal_publish_succeeded: bool,
    durable_journal: UpdateState,
) -> bool {
    durable_journal == UpdateState::CriticalFailure
        && (initial_journal == UpdateState::CriticalFailure || journal_publish_succeeded)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RollbackResumeAction {
    ContinueRecovery,
    FinalizePreservingHost,
    AlreadyComplete,
    Refuse,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootRecoveryPlan {
    PrestopPreserveHost,
    ResumeRollback,
    RepairCommittedState,
    ReportCommitted,
    RepairRolledBackState,
    ReportRolledBack,
    ReportPrestopAborted,
    Reject,
}

fn root_recovery_plan(
    journal: UpdateState,
    durable_state: Option<UpdateState>,
) -> RootRecoveryPlan {
    use RootRecoveryPlan::*;
    use UpdateState::*;
    match (journal, durable_state) {
        (Begun, None)
        | (Authenticated, None)
        | (Authenticated, Some(Authenticated))
        | (PrestopAborted, None)
        | (PrestopAborted, Some(Authenticated)) => PrestopPreserveHost,
        (Authenticated, Some(HostStopInitiated)) => ResumeRollback,
        (Committed, Some(ReadyVerified)) => RepairCommittedState,
        (Committed, Some(Committed)) => ReportCommitted,
        (RolledBack, Some(HostRebootstrapped)) => RepairRolledBackState,
        (RolledBack, Some(RolledBack)) => ReportRolledBack,
        (PrestopAborted, Some(PrestopAborted)) => ReportPrestopAborted,
        (_, Some(state))
            if journal_and_root_state_are_crash_coherent(journal, state)
                && rollback_resume_action(journal) != RollbackResumeAction::Refuse =>
        {
            ResumeRollback
        }
        _ => Reject,
    }
}

#[derive(Clone, Debug)]
struct RollbackOutcome {
    host: HostGeneration,
    routes_unchanged: bool,
}

fn rollback_routes_match(baseline: Option<&RouteSnapshot>) -> bool {
    baseline.is_some_and(|route| stable_route_snapshot().is_ok_and(|current| current == *route))
}

fn finalize_prestop_preserving_host(
    layout: &RootLayout,
    journal: &mut Journal,
    durable: Option<(
        UpdateState,
        HostGeneration,
        Option<RouteSnapshot>,
        Option<RollbackReserve>,
    )>,
) -> Result<RollbackOutcome> {
    verify_installed_v7_driver()?;
    require_absent(&layout.prior_driver, "prestop retained-driver destination")?;
    require_absent(&layout.failed_driver, "prestop failed-driver destination")?;
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    let (initial, baseline_route, durable_reserve) = match durable {
        Some((UpdateState::Authenticated, initial, route, reserve)) => {
            if initial != host {
                return Err(ControllerError(
                    "prestop durable host differs from the exact live v8 generation".to_owned(),
                ));
            }
            (initial, route, reserve)
        }
        None => (host.clone(), Some(stable_route_snapshot()?), None),
        Some(_) => {
            return Err(ControllerError(
                "prestop finalizer received a non-prestop durable state".to_owned(),
            ));
        }
    };
    let discovered = release_discovered_prestop_reserve(layout)?;
    if let (Some(expected), Some(actual)) = (durable_reserve.as_ref(), discovered.as_ref()) {
        if expected.device != actual.device || expected.inode != actual.inode {
            return Err(ControllerError(
                "prestop discovered reserve differs from durable identity".to_owned(),
            ));
        }
    } else if durable_reserve.is_some() && discovered.is_none() {
        return Err(ControllerError(
            "durable prestop reserve is absent".to_owned(),
        ));
    }
    journal.reconcile()?;
    if !matches!(
        journal.state,
        UpdateState::Begun | UpdateState::Authenticated | UpdateState::PrestopAborted
    ) {
        return Err(ControllerError(
            "prestop journal advanced beyond its preserving-host scope".to_owned(),
        ));
    }
    if journal.state != UpdateState::PrestopAborted {
        journal.record(UpdateState::PrestopAborted, &[])?;
    }
    write_root_state(
        layout,
        UpdateState::PrestopAborted,
        &initial,
        baseline_route.as_ref(),
    )?;
    let routes_unchanged = rollback_routes_match(baseline_route.as_ref());
    if !layout.result.exists() {
        write_root_result(
            layout,
            "rolled-back",
            &format!(
                "prestop-aborted;host=preserved;routes={}",
                if routes_unchanged {
                    "unchanged"
                } else {
                    "drifted"
                }
            ),
        )?;
    }
    Ok(RollbackOutcome {
        host,
        routes_unchanged,
    })
}

fn repair_committed_terminal_state(
    layout: &RootLayout,
    journal: &mut Journal,
    durable: (
        UpdateState,
        HostGeneration,
        Option<RouteSnapshot>,
        Option<RollbackReserve>,
    ),
) -> Result<RollbackOutcome> {
    let (state, initial, route, reserve) = durable;
    if !matches!(state, UpdateState::ReadyVerified | UpdateState::Committed) {
        return Err(ControllerError(
            "committed terminal repair received the wrong durable state".to_owned(),
        ));
    }
    let reserve = reserve.ok_or_else(|| {
        ControllerError("committed transaction has no rollback reserve identity".to_owned())
    })?;
    release_rollback_reserve(layout, &reserve)?;
    journal.reconcile()?;
    if journal.state != UpdateState::Committed {
        return Err(ControllerError(
            "committed pending journal did not reconcile to COMMITTED".to_owned(),
        ));
    }
    verify_driver_bundle(
        Path::new(PRODUCT_DRIVER),
        ROOT_ID,
        ROOT_ID,
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )?;
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    write_root_state(layout, UpdateState::Committed, &initial, route.as_ref())?;
    let routes_unchanged = rollback_routes_match(route.as_ref());
    if !layout.result.exists() {
        write_root_result(
            layout,
            "success",
            &format!(
                "committed-state-repaired;routes={}",
                if routes_unchanged {
                    "unchanged"
                } else {
                    "drifted"
                }
            ),
        )?;
    }
    Ok(RollbackOutcome {
        host,
        routes_unchanged,
    })
}

fn repair_rolled_back_terminal_state(
    layout: &RootLayout,
    journal: &mut Journal,
    durable: (
        UpdateState,
        HostGeneration,
        Option<RouteSnapshot>,
        Option<RollbackReserve>,
    ),
) -> Result<RollbackOutcome> {
    let (state, initial, route, reserve) = durable;
    if !matches!(
        state,
        UpdateState::HostRebootstrapped | UpdateState::RolledBack
    ) {
        return Err(ControllerError(
            "rolled-back terminal repair received the wrong durable state".to_owned(),
        ));
    }
    let reserve = reserve.ok_or_else(|| {
        ControllerError("rolled-back transaction has no rollback reserve identity".to_owned())
    })?;
    release_rollback_reserve(layout, &reserve)?;
    journal.reconcile()?;
    if journal.state != UpdateState::RolledBack {
        return Err(ControllerError(
            "rolled-back pending journal did not reconcile to ROLLED_BACK".to_owned(),
        ));
    }
    verify_installed_v7_driver()?;
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    write_root_state(layout, UpdateState::RolledBack, &initial, route.as_ref())?;
    let routes_unchanged = rollback_routes_match(route.as_ref());
    if !layout.result.exists() {
        write_root_result(
            layout,
            "rolled-back",
            &format!(
                "rolled-back-state-repaired;routes={}",
                if routes_unchanged {
                    "unchanged"
                } else {
                    "drifted"
                }
            ),
        )?;
    }
    Ok(RollbackOutcome {
        host,
        routes_unchanged,
    })
}

fn report_prestop_aborted_terminal(
    layout: &RootLayout,
    durable: (
        UpdateState,
        HostGeneration,
        Option<RouteSnapshot>,
        Option<RollbackReserve>,
    ),
) -> Result<RollbackOutcome> {
    let (state, initial, route, reserve) = durable;
    if state != UpdateState::PrestopAborted {
        return Err(ControllerError(
            "prestop terminal reporter received the wrong durable state".to_owned(),
        ));
    }
    if let Some(reserve) = reserve {
        release_rollback_reserve(layout, &reserve)?;
    }
    verify_installed_v7_driver()?;
    let host = verify_live_v8_host()?;
    if host != initial {
        return Err(ControllerError(
            "prestop-aborted host generation changed".to_owned(),
        ));
    }
    verify_pairing_metadata_only()?;
    let routes_unchanged = rollback_routes_match(route.as_ref());
    if !layout.result.exists() {
        write_root_result(
            layout,
            "rolled-back",
            &format!(
                "prestop-aborted;host=preserved;routes={}",
                if routes_unchanged {
                    "unchanged"
                } else {
                    "drifted"
                }
            ),
        )?;
    }
    Ok(RollbackOutcome {
        host,
        routes_unchanged,
    })
}

fn rollback_resume_action(state: UpdateState) -> RollbackResumeAction {
    match state {
        UpdateState::HostRebootstrapped => RollbackResumeAction::FinalizePreservingHost,
        UpdateState::RolledBack => RollbackResumeAction::AlreadyComplete,
        UpdateState::HostStopInitiated
        | UpdateState::HostStopped
        | UpdateState::PriorDriverRetained
        | UpdateState::CandidatePublished
        | UpdateState::CoreAudioReloaded
        | UpdateState::DriverValidated
        | UpdateState::HostBootstrapped
        | UpdateState::ReadyVerified
        | UpdateState::RollbackStarted
        | UpdateState::FailedDriverArchived
        | UpdateState::PriorDriverRestored
        | UpdateState::RollbackCoreAudioReloadInitiated
        | UpdateState::RollbackCoreAudioReloaded
        | UpdateState::CriticalFailure => RollbackResumeAction::ContinueRecovery,
        UpdateState::Begun
        | UpdateState::Authenticated
        | UpdateState::PrestopAborted
        | UpdateState::Committed => RollbackResumeAction::Refuse,
    }
}

fn rollback_root_transaction(
    layout: &RootLayout,
    journal: &mut Journal,
    initial: &HostGeneration,
    baseline_route: Option<&RouteSnapshot>,
) -> Result<RollbackOutcome> {
    let (durable_state, durable_initial, _, reserve) = parse_root_state(layout)?;
    if durable_initial != *initial {
        return Err(ControllerError(
            "durable rollback host identity differs from authorized initial host".to_owned(),
        ));
    }
    let reserve = reserve.ok_or_else(|| {
        ControllerError("recoverable transaction has no durable rollback reserve".to_owned())
    })?;
    let _released_reserve = release_rollback_reserve(layout, &reserve)?;
    journal.reconcile()?;
    if journal.state == UpdateState::Authenticated {
        if durable_state != UpdateState::HostStopInitiated {
            return Err(ControllerError(
                "authenticated journal is not paired with exact durable stop intent".to_owned(),
            ));
        }
        journal.record(UpdateState::CriticalFailure, &[])?;
        write_root_state(
            layout,
            UpdateState::CriticalFailure,
            initial,
            baseline_route,
        )?;
    }
    let result = (|| {
        let action = rollback_resume_action(journal.state);
        if action == RollbackResumeAction::Refuse {
            return Err(ControllerError(
                "transaction state is outside critical/resume rollback scope".to_owned(),
            ));
        }
        if action == RollbackResumeAction::AlreadyComplete {
            verify_installed_v7_driver()?;
            let host = verify_live_v8_host()?;
            verify_pairing_metadata_only()?;
            return Ok(RollbackOutcome {
                host,
                routes_unchanged: rollback_routes_match(baseline_route),
            });
        }
        if action == RollbackResumeAction::FinalizePreservingHost {
            verify_installed_v7_driver()?;
            let host = verify_live_v8_host()?;
            verify_pairing_metadata_only()?;
            journal.record(UpdateState::RolledBack, &[])?;
            write_root_state(layout, UpdateState::RolledBack, initial, baseline_route)?;
            return Ok(RollbackOutcome {
                host,
                routes_unchanged: rollback_routes_match(baseline_route),
            });
        }
        if !matches!(
            journal.state,
            UpdateState::RollbackStarted
                | UpdateState::FailedDriverArchived
                | UpdateState::PriorDriverRestored
                | UpdateState::RollbackCoreAudioReloadInitiated
                | UpdateState::RollbackCoreAudioReloaded
                | UpdateState::HostRebootstrapped
        ) {
            journal.record(UpdateState::RollbackStarted, &[])?;
            write_root_state(
                layout,
                UpdateState::RollbackStarted,
                initial,
                baseline_route,
            )?;
        }

        stop_v8_host_for_rollback(initial)?;

        let canonical = Path::new(PRODUCT_DRIVER);
        let canonical_candidate = path_is_exact_candidate(canonical);
        let canonical_v7 = path_is_exact_v7(canonical);
        let canonical_exists = fs::symlink_metadata(canonical).is_ok();
        let failed_candidate = path_is_exact_candidate(&layout.failed_driver);
        let prior_v7 = path_is_exact_v7(&layout.prior_driver);

        if canonical_candidate {
            if fs::symlink_metadata(&layout.failed_driver).is_ok() {
                return Err(ControllerError(
                    "rollback refuses to replace an existing failed-driver archive".to_owned(),
                ));
            }
            rename_exclusive(canonical, &layout.failed_driver)?;
            fsync_parent(canonical)?;
            fsync_parent(&layout.failed_driver)?;
            if !path_is_exact_candidate(&layout.failed_driver) {
                return Err(ControllerError(
                    "archived candidate driver differs from its pin".to_owned(),
                ));
            }
            if journal.state == UpdateState::RollbackStarted {
                journal.record(UpdateState::FailedDriverArchived, &[])?;
                write_root_state(
                    layout,
                    UpdateState::FailedDriverArchived,
                    initial,
                    baseline_route,
                )?;
            }
        } else if canonical_exists && !canonical_v7 {
            return Err(ControllerError(
                "rollback refuses an unrecognized canonical HAL bundle".to_owned(),
            ));
        } else if !canonical_exists
            && fs::symlink_metadata(&layout.failed_driver).is_ok()
            && !failed_candidate
        {
            return Err(ControllerError(
                "rollback failed-driver archive is not the exact candidate".to_owned(),
            ));
        }

        if !path_is_exact_v7(canonical) {
            if fs::symlink_metadata(canonical).is_ok() || !prior_v7 {
                return Err(ControllerError(
                    "rollback cannot prove the exact retained v7 driver".to_owned(),
                ));
            }
            rename_exclusive(&layout.prior_driver, canonical)?;
            fsync_parent(&layout.prior_driver)?;
            fsync_parent(canonical)?;
        }
        verify_installed_v7_driver()?;
        if matches!(
            journal.state,
            UpdateState::RollbackStarted | UpdateState::FailedDriverArchived
        ) {
            journal.record(UpdateState::PriorDriverRestored, &[])?;
            write_root_state(
                layout,
                UpdateState::PriorDriverRestored,
                initial,
                baseline_route,
            )?;
        }

        if journal.state == UpdateState::PriorDriverRestored {
            let rollback_coreaudio = stable_coreaudio_generation()?;
            journal.record(
                UpdateState::RollbackCoreAudioReloadInitiated,
                &[
                    ("old_pid", rollback_coreaudio.pid.to_string()),
                    ("old_runs", rollback_coreaudio.runs.to_string()),
                ],
            )?;
            write_root_state(
                layout,
                UpdateState::RollbackCoreAudioReloadInitiated,
                initial,
                baseline_route,
            )?;
        }

        if journal.state == UpdateState::RollbackCoreAudioReloadInitiated {
            let fields =
                journal.exact_fields_for_state(UpdateState::RollbackCoreAudioReloadInitiated)?;
            let old_pid = fields
                .get("old_pid")
                .ok_or_else(|| ControllerError("rollback reload old PID is absent".to_owned()))?
                .parse::<u32>()
                .map_err(|_| ControllerError("rollback reload old PID overflowed".to_owned()))?;
            let old_runs = fields
                .get("old_runs")
                .ok_or_else(|| ControllerError("rollback reload run count is absent".to_owned()))?
                .parse::<u64>()
                .map_err(|_| ControllerError("rollback reload run count overflowed".to_owned()))?;
            let current = stable_coreaudio_generation()?;
            let after = if current.pid == old_pid && current.runs == old_runs {
                reload_coreaudio_exact(&current)?.1
            } else if current.pid != old_pid && current.runs == old_runs.saturating_add(1) {
                current
            } else {
                return Err(ControllerError(
                    "rollback Core Audio generation escaped its durable restart bracket".to_owned(),
                ));
            };
            journal.record(
                UpdateState::RollbackCoreAudioReloaded,
                &[
                    ("old_pid", old_pid.to_string()),
                    ("new_pid", after.pid.to_string()),
                    ("new_runs", after.runs.to_string()),
                ],
            )?;
            write_root_state(
                layout,
                UpdateState::RollbackCoreAudioReloaded,
                initial,
                baseline_route,
            )?;
        }

        let host = if journal.state == UpdateState::RollbackCoreAudioReloaded {
            let host = restart_exact_v8_host(initial)?;
            journal.record(
                UpdateState::HostRebootstrapped,
                &[
                    ("pid", host.pid.to_string()),
                    ("runs", host.runs.to_string()),
                    ("nonce", host.nonce.clone()),
                ],
            )?;
            write_root_state(
                layout,
                UpdateState::HostRebootstrapped,
                initial,
                baseline_route,
            )?;
            host
        } else {
            verify_live_v8_host()?
        };
        verify_pairing_metadata_only()?;
        let routes_unchanged = rollback_routes_match(baseline_route);
        if journal.state == UpdateState::HostRebootstrapped {
            journal.record(UpdateState::RolledBack, &[])?;
            write_root_state(layout, UpdateState::RolledBack, initial, baseline_route)?;
        }
        Ok(RollbackOutcome {
            host,
            routes_unchanged,
        })
    })();
    if result.is_err() {
        journal_rollback_failure(layout, journal, initial, baseline_route);
    }
    result
}

fn verify_root_pointer(layout: &RootLayout) -> Result<()> {
    require_regular(Path::new(ROOT_ACTIVE_POINTER), ROOT_ID, ROOT_ID, 0o600)?;
    if read_bounded_utf8(Path::new(ROOT_ACTIVE_POINTER), 1_024)?
        != format!("{}\n", path_text(&layout.root)?)
    {
        return Err(ControllerError(
            "root active diagnostic-driver pointer changed".to_owned(),
        ));
    }
    require_absent(
        Path::new(ROOT_ACTIVE_POINTER_PENDING),
        "published root active-pointer pending image",
    )?;
    Ok(())
}

fn write_root_result(layout: &RootLayout, status: &str, detail: &str) -> Result<()> {
    if !matches!(status, "success" | "rolled-back" | "critical-failure")
        || detail.contains('\0')
        || detail.len() > 8_192
    {
        return Err(ControllerError(
            "root result arguments are unsafe".to_owned(),
        ));
    }
    let bytes =
        format!("OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_RESULT_V1\nstatus={status}\ndetail={detail}\n");
    write_new_private(&layout.result, bytes.as_bytes(), ROOT_ID, ROOT_ID, 0o600)
}

fn write_root_recovery_result(layout: &RootLayout, outcome: &str, detail: &str) -> Result<()> {
    if !matches!(outcome, "committed" | "rolled-back" | "prestop-aborted")
        || detail.contains(['\0', '\r', '\n'])
        || detail.len() > 4_096
    {
        return Err(ControllerError(
            "root recovery-result arguments are unsafe".to_owned(),
        ));
    }
    let bytes = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_RECOVERY_RESULT_V1\noutcome={outcome}\ndetail={detail}\n"
    );
    match fs::symlink_metadata(&layout.recovery_result) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => write_new_private(
            &layout.recovery_result,
            bytes.as_bytes(),
            ROOT_ID,
            ROOT_ID,
            0o600,
        ),
        Err(error) => Err(error.into()),
        Ok(_) => {
            require_regular(&layout.recovery_result, ROOT_ID, ROOT_ID, 0o600)?;
            let existing = read_bounded_utf8(&layout.recovery_result, 8_192)?;
            if !existing.starts_with("OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_RECOVERY_RESULT_V1\n")
                || !existing.ends_with('\n')
                || existing.lines().count() != 3
                || !existing
                    .lines()
                    .any(|line| line == format!("outcome={outcome}"))
            {
                return Err(ControllerError(
                    "immutable root recovery result conflicts with the final outcome".to_owned(),
                ));
            }
            Ok(())
        }
    }
}

fn perform_root_transaction(request_path: &Path) -> Result<HostGeneration> {
    let request = parse_bootstrap_root_request(request_path)?;
    verify_root_controller_identity(&request)?;
    verify_installed_v7_driver()?;
    require_legacy_disabled_and_absent()?;
    verify_pairing_metadata_only()?;
    let initial = verify_live_v8_host()?;
    let baseline_route = stable_route_snapshot()?;
    let baseline_coreaudio = stable_coreaudio_generation()?;

    let layout = ensure_root_update_layout(&request.nonce)?;
    let sealed_request = root_request_text(&request)?;
    write_new_private(
        &layout.recovery_request,
        sealed_request.as_bytes(),
        ROOT_ID,
        ROOT_ID,
        0o400,
    )?;
    require_no_acl_or_xattrs(&layout.recovery_request)?;
    if read_bounded_utf8(&layout.recovery_request, 4_096)? != sealed_request {
        return Err(ControllerError(
            "sealed root-owned recovery request changed".to_owned(),
        ));
    }
    let mut journal = Journal::create(&layout.journal, ROOT_JOURNAL_HEADER, ROOT_ID, ROOT_ID)?;
    write_root_pointer(&layout)?;
    verify_root_pointer(&layout)?;
    let (reader, both_order) = stage_root_artifacts(&layout, &request)?;
    verify_root_bootstrap_locator(&request)?;
    let root_ancestry = capture_root_transaction_ancestry(
        &layout,
        &request,
        Some(reader.parent().ok_or_else(|| {
            ControllerError("sealed reader has no probe support directory".to_owned())
        })?),
    )?;
    journal.record(
        UpdateState::Authenticated,
        &[
            ("host_pid", initial.pid.to_string()),
            ("host_runs", initial.runs.to_string()),
            ("coreaudiod_pid", baseline_coreaudio.pid.to_string()),
            ("coreaudiod_runs", baseline_coreaudio.runs.to_string()),
            ("release_commit", request.authorized_commit.clone()),
            ("release_tree", request.authorized_tree.clone()),
        ],
    )?;
    write_root_state(
        &layout,
        UpdateState::Authenticated,
        &initial,
        Some(&baseline_route),
    )?;

    if verify_live_v8_host()? != initial
        || stable_coreaudio_generation()? != baseline_coreaudio
        || stable_route_snapshot()? != baseline_route
    {
        return Err(ControllerError(
            "live generation changed before the committed stop boundary".to_owned(),
        ));
    }

    let reserve = allocate_rollback_reserve(&layout)?;
    let available_bytes = available_bytes_on_transaction_filesystem(&layout)?;
    if !prestop_headroom_is_sufficient(available_bytes, true)
        || verify_live_v8_host()? != initial
        || stable_coreaudio_generation()? != baseline_coreaudio
        || stable_route_snapshot()? != baseline_route
    {
        release_rollback_reserve(&layout, &reserve)?;
        return Err(ControllerError(
            "headroom or live generation changed before the committed stop boundary".to_owned(),
        ));
    }

    revalidate_root_transaction_ancestry(&root_ancestry)?;
    verify_root_bootstrap_locator(&request)?;

    write_root_state(
        &layout,
        UpdateState::HostStopInitiated,
        &initial,
        Some(&baseline_route),
    )?;
    journal.record(
        UpdateState::HostStopInitiated,
        &[
            ("available_bytes", available_bytes.to_string()),
            ("reserve_device", reserve.device.to_string()),
            ("reserve_inode", reserve.inode.to_string()),
            ("reserve_bytes", ROLLBACK_RESERVE_BYTES.to_string()),
        ],
    )?;

    let transaction = (|| {
        stop_exact_v8_host(&initial)?;
        journal.record(UpdateState::HostStopped, &[])?;
        write_root_state(
            &layout,
            UpdateState::HostStopped,
            &initial,
            Some(&baseline_route),
        )?;

        publish_candidate_driver(&layout, &mut journal)?;
        write_root_state(
            &layout,
            UpdateState::CandidatePublished,
            &initial,
            Some(&baseline_route),
        )?;
        let (old_coreaudio, new_coreaudio) = reload_coreaudio_exact(&baseline_coreaudio)?;
        if stable_route_snapshot()? != baseline_route {
            return Err(ControllerError(
                "default routes changed during candidate Core Audio reload".to_owned(),
            ));
        }
        journal.record(
            UpdateState::CoreAudioReloaded,
            &[
                ("old_pid", old_coreaudio.pid.to_string()),
                ("new_pid", new_coreaudio.pid.to_string()),
                ("new_runs", new_coreaudio.runs.to_string()),
            ],
        )?;
        write_root_state(
            &layout,
            UpdateState::CoreAudioReloaded,
            &initial,
            Some(&baseline_route),
        )?;

        let driver_generation = run_passive_driver_validation(&reader, &both_order, &request)?;
        if stable_route_snapshot()? != baseline_route {
            return Err(ControllerError(
                "default routes changed during passive candidate validation".to_owned(),
            ));
        }
        journal.record(
            UpdateState::DriverValidated,
            &[("driver_generation", driver_generation.to_string())],
        )?;
        write_root_state(
            &layout,
            UpdateState::DriverValidated,
            &initial,
            Some(&baseline_route),
        )?;

        let host = restart_exact_v8_host(&initial)?;
        journal.record(
            UpdateState::HostBootstrapped,
            &[
                ("pid", host.pid.to_string()),
                ("runs", host.runs.to_string()),
                ("nonce", host.nonce.clone()),
            ],
        )?;
        write_root_state(
            &layout,
            UpdateState::HostBootstrapped,
            &initial,
            Some(&baseline_route),
        )?;
        if stable_route_snapshot()? != baseline_route {
            return Err(ControllerError(
                "default routes changed after v8 host restart".to_owned(),
            ));
        }
        verify_pairing_metadata_only()?;
        journal.record(UpdateState::ReadyVerified, &[])?;
        write_root_state(
            &layout,
            UpdateState::ReadyVerified,
            &initial,
            Some(&baseline_route),
        )?;
        let _released_reserve = release_rollback_reserve(&layout, &reserve)?;
        journal.record(UpdateState::Committed, &[])?;
        write_root_state(
            &layout,
            UpdateState::Committed,
            &initial,
            Some(&baseline_route),
        )?;
        Ok(host)
    })();

    match transaction {
        Ok(host) => {
            if let Err(error) = write_root_result(&layout, "success", "candidate-committed") {
                eprintln!("warning: committed driver but could not write root result: {error}");
            }
            Ok(host)
        }
        Err(update_error) => {
            match rollback_root_transaction(&layout, &mut journal, &initial, Some(&baseline_route))
            {
                Ok(rollback) => {
                    let route_status = if rollback.routes_unchanged {
                        "unchanged"
                    } else {
                        "drifted"
                    };
                    let detail = format!(
                        "candidate-error={};routes={route_status}",
                        update_error.0.replace(['\r', '\n'], " ")
                    );
                    let _ = write_root_result(&layout, "rolled-back", &detail);
                    Err(ControllerError(format!(
                    "candidate deployment failed and exact v7 rollback completed with host pid {} routes={route_status}: {}",
                    rollback.host.pid, update_error
                )))
                }
                Err(rollback_error) => {
                    let detail = format!(
                        "candidate-error={};rollback-error={}",
                        update_error.0.replace(['\r', '\n'], " "),
                        rollback_error.0.replace(['\r', '\n'], " ")
                    );
                    let _ = write_root_result(&layout, "critical-failure", &detail);
                    Err(ControllerError(format!(
                    "candidate deployment failed and rollback requires explicit resume: update={update_error}; rollback={rollback_error}"
                )))
                }
            }
        }
    }
}

fn root_authorized_update(request_path: &Path) -> Result<()> {
    if unsafe { geteuid() } != ROOT_ID {
        return Err(ControllerError(
            "root update mode requires exact root EUID".to_owned(),
        ));
    }
    let _root_lock = acquire_root_update_lock()?;
    let host = perform_root_transaction(request_path)?;
    println!(
        "DIAGNOSTIC_DRIVER_V1_UPDATE_COMMITTED host_pid={} host_runs={} pairing=preserved routes=unchanged legacy=protected",
        host.pid, host.runs
    );
    Ok(())
}

fn write_user_result(layout: &UserLayout, status: &str, detail: &str) -> Result<()> {
    if !matches!(status, "success" | "failed" | "rolled-back")
        || detail.contains('\0')
        || detail.len() > 8_192
    {
        return Err(ControllerError(
            "user result arguments are unsafe".to_owned(),
        ));
    }
    let bytes =
        format!("OPENSTEAMER_DIAGNOSTIC_DRIVER_RESULT_V1\nstatus={status}\ndetail={detail}\n");
    write_new_private(&layout.result, bytes.as_bytes(), USER_ID, USER_GROUP, 0o600)
}

fn publish_user_pointer(layout: &UserLayout) -> Result<()> {
    write_new_private(
        Path::new(USER_ACTIVE_POINTER),
        format!("{}\n", path_text(&layout.evidence)?).as_bytes(),
        USER_ID,
        USER_GROUP,
        0o600,
    )
}

fn execute_authorized_update(
    repo: &Path,
    authorized_commit: &str,
    authorized_tree: &str,
) -> Result<()> {
    if unsafe { getuid() } != USER_ID || unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "execute mode requires exact UID 501".to_owned(),
        ));
    }
    require_lower_hex(authorized_commit, 40, "authorized release commit")?;
    require_lower_hex(authorized_tree, 40, "authorized release tree")?;
    let _lock = acquire_user_update_lock()?;
    let (commit, tree, initial) = verify_complete_preflight(repo, true)?;
    if commit != authorized_commit || tree != authorized_tree {
        return Err(ControllerError(
            "explicit authorization differs from clean pushed main HEAD/tree".to_owned(),
        ));
    }
    let credential = sudo_fixed(&["/usr/bin/true"], COMMAND_TIMEOUT)?;
    require_success(
        &credential,
        "prove cached noninteractive sudo authorization",
    )?;

    let nonce = random_nonce()?;
    let layout = create_user_layout(&nonce)?;
    build_diagnostic_reader(repo, &nonce, &layout.reader)?;
    let mut journal = Journal::create(&layout.journal, JOURNAL_HEADER, USER_ID, USER_GROUP)?;
    let (controller_source, controller_sha256, controller_bytes) = current_binary_identity()?;
    let root_controller = Path::new(ROOT_CONTROLLER_PARENT)
        .join(format!("controller-{nonce}"))
        .join("controller");
    let request = RootRequest {
        nonce: nonce.clone(),
        evidence: layout.evidence.clone(),
        controller_sha256: controller_sha256.clone(),
        root_controller: root_controller.clone(),
        reader_sha256: DIAGNOSTIC_READER_SHA256.to_owned(),
        authorized_commit: commit.clone(),
        authorized_tree: tree.clone(),
    };
    let request_text = root_request_text(&request)?;
    write_new_private(
        &layout.request,
        request_text.as_bytes(),
        USER_ID,
        USER_GROUP,
        0o400,
    )?;
    publish_user_pointer(&layout)?;
    journal.record(
        UpdateState::Authenticated,
        &[
            ("nonce", nonce.clone()),
            ("host_pid", initial.pid.to_string()),
            ("release_commit", commit.clone()),
            ("release_tree", tree.clone()),
        ],
    )?;

    let (source_again, digest_again, bytes_again) = current_binary_identity()?;
    if source_again != controller_source
        || digest_again != controller_sha256
        || bytes_again != controller_bytes
    {
        return Err(ControllerError(
            "controller changed before root-owned staging".to_owned(),
        ));
    }
    let staged = stage_root_owned_controller(
        &controller_bytes,
        request_text.as_bytes(),
        &controller_sha256,
        &nonce,
        &layout.evidence,
    )?;
    if staged != root_controller {
        return Err(ControllerError(
            "root-owned controller path differs from sealed request".to_owned(),
        ));
    }

    let (final_commit, final_tree, final_host) = verify_complete_preflight(repo, false)?;
    if final_commit != commit || final_tree != tree || final_host != initial {
        return Err(ControllerError(
            "pre-stop release/host proof changed after root controller staging".to_owned(),
        ));
    }
    let root_bootstrap_request = root_controller
        .parent()
        .ok_or_else(|| ControllerError("root controller support is absent".to_owned()))?
        .join("bootstrap-request.txt");
    let output = run_sudo_helper(&root_controller, ROOT_MODE, Some(&root_bootstrap_request))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr)
            .trim_end()
            .replace(['\r', '\n'], " ");
        let _ = write_user_result(&layout, "failed", &stderr);
        return Err(ControllerError(format!(
            "root transaction returned {:?}: {stderr}",
            output.status.code()
        )));
    }
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "successful root transaction wrote stderr".to_owned(),
        ));
    }
    let stdout = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("root transaction stdout is not UTF-8".to_owned()))?;
    if stdout.lines().count() != 1 || !stdout.starts_with("DIAGNOSTIC_DRIVER_V1_UPDATE_COMMITTED ")
    {
        return Err(ControllerError(
            "root transaction success marker is not exact".to_owned(),
        ));
    }
    verify_driver_bundle(
        Path::new(PRODUCT_DRIVER),
        ROOT_ID,
        ROOT_ID,
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )?;
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    write_user_result(
        &layout,
        "success",
        &format!("candidate-committed host-pid={}", host.pid),
    )?;
    println!(
        "DIAGNOSTIC_DRIVER_V1_UPDATE_COMPLETE evidence={} host_pid={} pairing=preserved routes=unchanged legacy=protected",
        layout.evidence.display(),
        host.pid
    );
    Ok(())
}

fn rollback_authorized_update(repo: &Path) -> Result<()> {
    if unsafe { getuid() } != USER_ID || unsafe { geteuid() } != USER_ID {
        return Err(ControllerError(
            "rollback mode requires exact UID 501".to_owned(),
        ));
    }
    if repo != Path::new(EXPECTED_REPO) {
        return Err(ControllerError(
            "rollback mode repository argument differs from its lexical pin".to_owned(),
        ));
    }
    let _lock = acquire_user_update_lock()?;
    require_regular(
        Path::new(ROOT_RECOVERY_CONTROLLER),
        ROOT_ID,
        ROOT_ID,
        ROOT_SEALED_EXECUTABLE_MODE,
    )?;
    require_regular(
        Path::new(ROOT_RECOVERY_CONTROLLER_PIN),
        ROOT_ID,
        ROOT_ID,
        ROOT_SEALED_RECORD_MODE,
    )?;
    let digest = read_bounded_utf8(Path::new(ROOT_RECOVERY_CONTROLLER_PIN), 65)?;
    let digest = digest.strip_suffix('\n').ok_or_else(|| {
        ControllerError("fixed root recovery pin lacks its exact newline".to_owned())
    })?;
    require_lower_hex(digest, 64, "fixed root recovery digest")?;
    if sha256(Path::new(ROOT_RECOVERY_CONTROLLER))? != digest {
        return Err(ControllerError(
            "fixed root-owned rollback controller differs from its pin".to_owned(),
        ));
    }
    let output = run_sudo_helper(
        Path::new(ROOT_RECOVERY_CONTROLLER),
        ROOT_SEALED_ROLLBACK_MODE,
        None,
    )?;
    if !output.status.success() {
        return Err(ControllerError(format!(
            "root rollback returned {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim_end()
        )));
    }
    if !output.stderr.is_empty() {
        return Err(ControllerError(
            "successful root rollback wrote stderr".to_owned(),
        ));
    }
    let stdout = String::from_utf8(output.stdout)
        .map_err(|_| ControllerError("root rollback stdout is not UTF-8".to_owned()))?;
    let line = stdout
        .strip_suffix('\n')
        .ok_or_else(|| ControllerError("root rollback marker has no exact newline".to_owned()))?;
    if line.contains('\n') {
        return Err(ControllerError(
            "root rollback success marker is not exact".to_owned(),
        ));
    }
    let recovery_kind = if line.starts_with("DIAGNOSTIC_DRIVER_V1_ROOT_ROLLBACK_COMPLETE ") {
        "rolled-back"
    } else if line.starts_with("DIAGNOSTIC_DRIVER_V1_ROOT_PRESTOP_ABORTED ") {
        "prestop-aborted"
    } else if line.starts_with("DIAGNOSTIC_DRIVER_V1_ROOT_RECOVERY_COMMITTED ") {
        "committed"
    } else {
        return Err(ControllerError(
            "root recovery success marker is unknown".to_owned(),
        ));
    };
    let route_status = if line
        .split_ascii_whitespace()
        .any(|field| field == "routes=unchanged")
    {
        "unchanged"
    } else if line
        .split_ascii_whitespace()
        .any(|field| field == "routes=drifted")
    {
        "drifted"
    } else {
        return Err(ControllerError(
            "root rollback marker has no canonical route status".to_owned(),
        ));
    };
    if recovery_kind == "committed" {
        verify_driver_bundle(
            Path::new(PRODUCT_DRIVER),
            ROOT_ID,
            ROOT_ID,
            CANDIDATE_DRIVER_TREE_SHA256,
            CANDIDATE_DRIVER_EXECUTABLE_SHA256,
        )?;
    } else {
        verify_installed_v7_driver()?;
    }
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    println!(
        "DIAGNOSTIC_DRIVER_V1_RECOVERY_COMPLETE outcome={recovery_kind} host_pid={} pairing=preserved routes={route_status} legacy=protected",
        host.pid
    );
    Ok(())
}

fn complete_root_recovery(_request: RootRequest, layout: RootLayout) -> Result<()> {
    require_directory(&layout.root, ROOT_ID, ROOT_ID, 0o700)?;
    verify_root_pointer(&layout)?;
    let mut journal = Journal::open(&layout.journal, ROOT_JOURNAL_HEADER, ROOT_ID, ROOT_ID)?;
    let durable = parse_optional_root_state(&layout)?;
    let effective_journal = journal.effective_state_with_pending()?;
    let plan = root_recovery_plan(effective_journal, durable.as_ref().map(|value| value.0));
    let (outcome, marker) = match plan {
        RootRecoveryPlan::PrestopPreserveHost => (
            finalize_prestop_preserving_host(&layout, &mut journal, durable)?,
            "DIAGNOSTIC_DRIVER_V1_ROOT_PRESTOP_ABORTED",
        ),
        RootRecoveryPlan::RepairCommittedState | RootRecoveryPlan::ReportCommitted => (
            repair_committed_terminal_state(
                &layout,
                &mut journal,
                durable.ok_or_else(|| {
                    ControllerError("committed recovery has no durable state".to_owned())
                })?,
            )?,
            "DIAGNOSTIC_DRIVER_V1_ROOT_RECOVERY_COMMITTED",
        ),
        RootRecoveryPlan::RepairRolledBackState | RootRecoveryPlan::ReportRolledBack => (
            repair_rolled_back_terminal_state(
                &layout,
                &mut journal,
                durable.ok_or_else(|| {
                    ControllerError("rolled-back recovery has no durable state".to_owned())
                })?,
            )?,
            "DIAGNOSTIC_DRIVER_V1_ROOT_ROLLBACK_COMPLETE",
        ),
        RootRecoveryPlan::ReportPrestopAborted => (
            report_prestop_aborted_terminal(
                &layout,
                durable.ok_or_else(|| {
                    ControllerError("prestop terminal has no durable state".to_owned())
                })?,
            )?,
            "DIAGNOSTIC_DRIVER_V1_ROOT_PRESTOP_ABORTED",
        ),
        RootRecoveryPlan::ResumeRollback => {
            let (state, initial, route, reserve) = durable.ok_or_else(|| {
                ControllerError("rollback recovery has no durable state".to_owned())
            })?;
            if !journal_and_root_state_are_crash_coherent(effective_journal, state)
                || reserve.is_none()
            {
                return Err(ControllerError(
                    "rollback journal/state/reserve relationship is impossible".to_owned(),
                ));
            }
            let outcome =
                rollback_root_transaction(&layout, &mut journal, &initial, route.as_ref())?;
            if !layout.result.exists() {
                write_root_result(
                    &layout,
                    "rolled-back",
                    &format!(
                        "explicit-resume-complete;routes={}",
                        if outcome.routes_unchanged {
                            "unchanged"
                        } else {
                            "drifted"
                        }
                    ),
                )?;
            }
            (outcome, "DIAGNOSTIC_DRIVER_V1_ROOT_ROLLBACK_COMPLETE")
        }
        RootRecoveryPlan::Reject => {
            return Err(ControllerError(
                "root journal/state pair has no authorized recovery plan".to_owned(),
            ));
        }
    };
    let route_status = if outcome.routes_unchanged {
        "unchanged"
    } else {
        "drifted"
    };
    let recovery_outcome = match marker {
        "DIAGNOSTIC_DRIVER_V1_ROOT_RECOVERY_COMMITTED" => "committed",
        "DIAGNOSTIC_DRIVER_V1_ROOT_PRESTOP_ABORTED" => "prestop-aborted",
        "DIAGNOSTIC_DRIVER_V1_ROOT_ROLLBACK_COMPLETE" => "rolled-back",
        _ => {
            return Err(ControllerError(
                "root recovery marker has no immutable outcome mapping".to_owned(),
            ))
        }
    };
    remove_stale_root_state_pending_files(&layout)?;
    write_root_recovery_result(
        &layout,
        recovery_outcome,
        &format!("host-pid={};routes={route_status}", outcome.host.pid),
    )?;
    println!(
        "{marker} host_pid={} host_runs={} pairing=preserved routes={route_status} legacy=protected",
        outcome.host.pid, outcome.host.runs
    );
    Ok(())
}

fn read_root_active_layout() -> Result<RootLayout> {
    require_regular(Path::new(ROOT_ACTIVE_POINTER), ROOT_ID, ROOT_ID, 0o600)?;
    let pointer = read_bounded_utf8(Path::new(ROOT_ACTIVE_POINTER), 1_024)?;
    let root_text = pointer
        .strip_suffix('\n')
        .ok_or_else(|| ControllerError("root active pointer lacks exact newline".to_owned()))?;
    let root = PathBuf::from(root_text);
    let leaf = root
        .file_name()
        .and_then(OsStr::to_str)
        .and_then(|value| value.strip_prefix("transaction-"))
        .ok_or_else(|| ControllerError("root active pointer leaf is malformed".to_owned()))?;
    validate_nonce(leaf)?;
    let layout = root_layout(leaf)?;
    if layout.root != root || root.parent() != Some(Path::new(ROOT_UPDATE_ROOT)) {
        return Err(ControllerError(
            "root active pointer escaped its exact transaction namespace".to_owned(),
        ));
    }
    verify_root_pointer(&layout)?;
    Ok(layout)
}

fn verify_sealed_transaction_controller(request: &RootRequest) -> Result<()> {
    require_sealed_regular(&request.root_controller, ROOT_SEALED_EXECUTABLE_MODE)?;
    if sha256(&request.root_controller)? != request.controller_sha256 {
        return Err(ControllerError(
            "sealed transaction controller differs from recovery binding".to_owned(),
        ));
    }
    let support = request
        .root_controller
        .parent()
        .ok_or_else(|| ControllerError("transaction controller support is absent".to_owned()))?;
    require_sealed_directory(support, ROOT_SEALED_TRAVERSE_MODE)?;
    let pin = support.join("controller.sha256");
    let identity = support.join("controller-identity.txt");
    require_sealed_regular(&pin, ROOT_SEALED_RECORD_MODE)?;
    require_sealed_regular(&identity, ROOT_SEALED_RECORD_MODE)?;
    if read_bounded_utf8(&pin, 65)? != format!("{}\n", request.controller_sha256)
        || read_bounded_utf8(&identity, 1_024)?
            != format!(
                "OPENSTEAMER_DIAGNOSTIC_DRIVER_CONTROLLER_IDENTITY_V1\ncontroller={}\nsha256={}\n",
                path_text(&request.root_controller)?,
                request.controller_sha256
            )
    {
        return Err(ControllerError(
            "sealed transaction controller records changed".to_owned(),
        ));
    }
    Ok(())
}

fn root_rollback_authorized_update(_request_path: &Path) -> Result<()> {
    Err(ControllerError(
        "mutable user-request rollback is retired; use the fixed sealed root recovery entrypoint"
            .to_owned(),
    ))
}

fn require_pointerless_partial_root_layout(
    layout: &RootLayout,
    request: &RootRequest,
) -> Result<()> {
    root_directory_identity(Path::new(ROOT_UPDATE_ROOT), ROOT_PRIVATE_MODE)?;
    root_directory_identity(&layout.root, ROOT_PRIVATE_MODE)?;
    let expected_root_leaf = layout
        .root
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("pointerless root leaf is not UTF-8".to_owned()))?;
    require_exact_child_names(
        Path::new(ROOT_UPDATE_ROOT),
        &[expected_root_leaf],
        "pointerless root update namespace",
    )?;
    let allowed = [
        ".state-PRESTOP_ABORTED.pending",
        "candidate-stage",
        "failed-driver",
        "journal.log",
        "journal.log.pending",
        "prestop-abort-journal.txt",
        "prior-driver",
        "probes",
        "recovery-result.txt",
        "sealed-root-request.txt",
        "state.txt",
    ]
    .into_iter()
    .collect::<BTreeSet<_>>();
    for child in exact_child_names(&layout.root)? {
        if !allowed.contains(child.as_str()) {
            return Err(ControllerError(format!(
                "pointerless root layout contains an unexpected child: {child}"
            )));
        }
    }
    let pointerless_directories = [
        layout.prior_driver.parent().unwrap().to_path_buf(),
        layout.candidate_stage.parent().unwrap().to_path_buf(),
        layout.failed_driver.parent().unwrap().to_path_buf(),
        layout.root.join("probes"),
    ];
    for directory in &pointerless_directories {
        match fs::symlink_metadata(directory) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
            Ok(_) => {
                root_directory_identity(directory, ROOT_PRIVATE_MODE)?;
                require_exact_child_names(directory, &[], "pointerless private staging directory")?;
            }
        }
    }
    require_absent(&layout.rollback_reserve, "pointerless rollback reserve")?;
    require_absent(&layout.prior_driver, "pointerless prior driver")?;
    require_absent(&layout.failed_driver, "pointerless failed driver")?;
    require_absent(&layout.candidate_stage, "pointerless candidate stage")?;
    match fs::symlink_metadata(&layout.recovery_request) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            let expected = root_request_text(request)?.into_bytes();
            let metadata = require_regular(&layout.recovery_request, ROOT_ID, ROOT_ID, 0o400)?;
            if metadata.len() > expected.len() as u64
                || !expected.starts_with(&read_bounded(
                    &layout.recovery_request,
                    expected.len() as u64,
                )?)
            {
                return Err(ControllerError(
                    "pointerless sealed request is not an exact crash prefix".to_owned(),
                ));
            }
            require_no_acl_or_xattrs(&layout.recovery_request)?;
        }
    }
    Ok(())
}

fn write_or_verify_prestop_abort_witness(layout: &RootLayout, journal: &str) -> Result<()> {
    let path = layout.root.join("prestop-abort-journal.txt");
    let bytes = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_PRESTOP_ABORT_JOURNAL_V1\noutcome=prestop-aborted\njournal={journal}\n"
    );
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            write_new_private(&path, bytes.as_bytes(), ROOT_ID, ROOT_ID, 0o600)?;
            require_no_acl_or_xattrs(&path)
        }
        Err(error) => Err(error.into()),
        Ok(_) => {
            require_regular(&path, ROOT_ID, ROOT_ID, 0o600)?;
            require_no_acl_or_xattrs(&path)?;
            if read_bounded_utf8(&path, 512)? != bytes {
                return Err(ControllerError(
                    "pointerless abort witness conflicts with prior recovery".to_owned(),
                ));
            }
            Ok(())
        }
    }
}

fn finalize_sealed_bootstrap_without_root_pointer(fixed_digest: &str) -> Result<()> {
    require_sealed_regular(Path::new(ROOT_BOOTSTRAP_LOCATOR), ROOT_SEALED_RECORD_MODE)?;
    let request = parse_root_request_text(&read_bounded_utf8(
        Path::new(ROOT_BOOTSTRAP_LOCATOR),
        4_096,
    )?)?;
    if request.controller_sha256 != fixed_digest {
        return Err(ControllerError(
            "bootstrap locator differs from the fixed recovery controller".to_owned(),
        ));
    }
    let controller_support = request.root_controller.parent().ok_or_else(|| {
        ControllerError("bootstrap locator controller support is absent".to_owned())
    })?;
    root_directory_identity(Path::new(ROOT_SUPPORT), 0o755)?;
    root_directory_identity(Path::new(ROOT_CONTROLLER_PARENT), ROOT_SEALED_TRAVERSE_MODE)?;
    root_directory_identity(controller_support, ROOT_SEALED_TRAVERSE_MODE)?;
    verify_installed_v7_driver()?;
    require_legacy_disabled_and_absent()?;
    let host = verify_live_v8_host()?;
    verify_pairing_metadata_only()?;
    let route = stable_route_snapshot()?;

    let layout = root_layout(&request.nonce)?;
    if layout.root.exists() {
        require_pointerless_partial_root_layout(&layout, &request)?;
        let initial_journal = format!("{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\n");
        match fs::symlink_metadata(&layout.journal) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                require_absent(
                    &layout.journal.with_file_name("journal.log.pending"),
                    "pointerless journal pending without canonical",
                )?;
                let mut journal =
                    Journal::create(&layout.journal, ROOT_JOURNAL_HEADER, ROOT_ID, ROOT_ID)?;
                journal.record(UpdateState::PrestopAborted, &[])?;
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {
                let metadata = require_regular(&layout.journal, ROOT_ID, ROOT_ID, 0o600)?;
                if metadata.len() > initial_journal.len() as u64 {
                    let mut journal =
                        Journal::open(&layout.journal, ROOT_JOURNAL_HEADER, ROOT_ID, ROOT_ID)?;
                    if journal.state == UpdateState::Begun {
                        journal.record(UpdateState::PrestopAborted, &[])?;
                    } else if journal.state != UpdateState::PrestopAborted {
                        return Err(ControllerError(
                            "pointerless bootstrap journal advanced beyond pre-stop abort"
                                .to_owned(),
                        ));
                    }
                } else {
                    let bytes = read_bounded(&layout.journal, initial_journal.len() as u64)?;
                    if !initial_journal.as_bytes().starts_with(&bytes) {
                        return Err(ControllerError(
                            "pointerless bootstrap journal is not an exact initial prefix"
                                .to_owned(),
                        ));
                    }
                    if bytes == initial_journal.as_bytes() {
                        let mut journal =
                            Journal::open(&layout.journal, ROOT_JOURNAL_HEADER, ROOT_ID, ROOT_ID)?;
                        journal.record(UpdateState::PrestopAborted, &[])?;
                    } else {
                        require_absent(
                            &layout.journal.with_file_name("journal.log.pending"),
                            "partial pointerless journal pending",
                        )?;
                        write_or_verify_prestop_abort_witness(&layout, "partial-initial-prefix")?;
                    }
                }
            }
        }
        write_root_state(&layout, UpdateState::PrestopAborted, &host, Some(&route))?;
        write_root_recovery_result(
            &layout,
            "prestop-aborted",
            "sealed-bootstrap-finalized-before-root-pointer",
        )?;
    }
    let abort_result = controller_support.join("bootstrap-abort-result.txt");
    let bytes = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_BOOTSTRAP_ABORT_V1\nnonce={}\nhost_pid={}\noutcome=prestop-aborted\n",
        request.nonce, host.pid
    );
    match fs::symlink_metadata(&abort_result) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            write_new_private(&abort_result, bytes.as_bytes(), ROOT_ID, ROOT_ID, 0o400)?;
            require_no_acl_or_xattrs(&abort_result)?;
        }
        Err(error) => return Err(error.into()),
        Ok(_) => {
            require_regular(&abort_result, ROOT_ID, ROOT_ID, 0o400)?;
            if read_bounded_utf8(&abort_result, 1_024)? != bytes {
                return Err(ControllerError(
                    "bootstrap abort result conflicts with prior recovery".to_owned(),
                ));
            }
        }
    }
    println!(
        "DIAGNOSTIC_DRIVER_V1_ROOT_PRESTOP_ABORTED host_pid={} routes=unchanged pairing=preserved",
        host.pid
    );
    Ok(())
}

fn root_sealed_rollback_authorized_update() -> Result<()> {
    if unsafe { geteuid() } != ROOT_ID {
        return Err(ControllerError(
            "sealed root rollback mode requires exact root EUID".to_owned(),
        ));
    }
    let fixed_digest = verify_fixed_root_recovery_controller()?;
    let _root_lock = acquire_root_update_lock()?;
    require_sealed_regular(Path::new(ROOT_BOOTSTRAP_LOCATOR), ROOT_SEALED_RECORD_MODE)?;
    let locator_request = parse_root_request_text(&read_bounded_utf8(
        Path::new(ROOT_BOOTSTRAP_LOCATOR),
        4_096,
    )?)?;
    if locator_request.controller_sha256 != fixed_digest {
        return Err(ControllerError(
            "bootstrap locator differs from fixed recovery digest".to_owned(),
        ));
    }
    let Some(layout) = reconcile_root_pointer_for_recovery(&locator_request)? else {
        return finalize_sealed_bootstrap_without_root_pointer(&fixed_digest);
    };
    let request = parse_sealed_root_request(&layout.recovery_request)?;
    if request.nonce
        != layout
            .root
            .file_name()
            .and_then(OsStr::to_str)
            .and_then(|value| value.strip_prefix("transaction-"))
            .unwrap_or_default()
        || request.controller_sha256 != fixed_digest
        || root_request_text(&request)? != root_request_text(&locator_request)?
    {
        return Err(ControllerError(
            "sealed recovery request differs from fixed root entrypoint".to_owned(),
        ));
    }
    verify_sealed_transaction_controller(&request)?;
    verify_root_bootstrap_locator(&request)?;
    let probe_directory = Path::new(ROOT_PROBE_PARENT).join(format!("probes-{}", request.nonce));
    let ancestry = capture_root_transaction_ancestry(
        &layout,
        &request,
        probe_directory
            .exists()
            .then_some(probe_directory.as_path()),
    )?;
    revalidate_root_transaction_ancestry(&ancestry)?;
    complete_root_recovery(request, layout)
}

fn require_self_test_rejection<T>(result: Result<T>, label: &str) -> Result<()> {
    if result.is_ok() {
        return Err(ControllerError(format!(
            "self-test hostile fixture was accepted: {label}"
        )));
    }
    Ok(())
}

fn uid501_can_traverse_and_read(ancestor_mode: u32, artifact_mode: u32) -> bool {
    ancestor_mode & 0o001 != 0 && artifact_mode & 0o004 != 0
}

fn uid501_can_traverse_and_execute(ancestor_mode: u32, artifact_mode: u32) -> bool {
    ancestor_mode & 0o001 != 0 && artifact_mode & 0o001 != 0
}

fn uid501_can_modify(ancestor_mode: u32, artifact_mode: u32) -> bool {
    ancestor_mode & 0o002 != 0 || artifact_mode & 0o002 != 0
}

fn self_test() -> Result<()> {
    for (value, length, label) in [
        (EXPECTED_SOURCE_COMMIT, 40, "candidate commit"),
        (EXPECTED_SOURCE_TREE, 40, "candidate tree"),
        (CANDIDATE_MANIFEST_SHA256, 64, "candidate manifest"),
        (CANDIDATE_DRIVER_TREE_SHA256, 64, "candidate driver tree"),
        (
            CANDIDATE_DRIVER_EXECUTABLE_SHA256,
            64,
            "candidate executable",
        ),
        (CANDIDATE_PACKAGE_SHA256, 64, "candidate package"),
        (
            CANDIDATE_CODE_RESOURCES_SHA256,
            64,
            "candidate code resources",
        ),
        (CANDIDATE_INFO_PLIST_SHA256, 64, "candidate Info.plist"),
        (CANDIDATE_LICENSE_SHA256, 64, "candidate license"),
        (CANDIDATE_LOCALIZABLE_SHA256, 64, "candidate localization"),
        (INSTALLED_DRIVER_TREE_SHA256, 64, "installed driver tree"),
        (
            INSTALLED_DRIVER_EXECUTABLE_SHA256,
            64,
            "installed executable",
        ),
        (DIAGNOSTIC_READER_SHA256, 64, "diagnostic reader"),
        (BOTH_ORDER_PROBE_SHA256, 64, "both-order probe"),
    ] {
        require_lower_hex(value, length, label)?;
    }
    let forward = [
        UpdateState::Begun,
        UpdateState::Authenticated,
        UpdateState::HostStopInitiated,
        UpdateState::HostStopped,
        UpdateState::PriorDriverRetained,
        UpdateState::CandidatePublished,
        UpdateState::CoreAudioReloaded,
        UpdateState::DriverValidated,
        UpdateState::HostBootstrapped,
        UpdateState::ReadyVerified,
        UpdateState::Committed,
    ];
    for pair in forward.windows(2) {
        if !valid_transition(pair[0], pair[1]) {
            return Err(ControllerError(
                "forward state model is incomplete".to_owned(),
            ));
        }
    }
    let rollback = [
        UpdateState::CandidatePublished,
        UpdateState::RollbackStarted,
        UpdateState::FailedDriverArchived,
        UpdateState::PriorDriverRestored,
        UpdateState::RollbackCoreAudioReloadInitiated,
        UpdateState::RollbackCoreAudioReloaded,
        UpdateState::HostRebootstrapped,
        UpdateState::RolledBack,
    ];
    for pair in rollback.windows(2) {
        if !valid_transition(pair[0], pair[1]) {
            return Err(ControllerError(
                "rollback state model is incomplete".to_owned(),
            ));
        }
    }
    let synthetic = RootRequest {
        nonce: "0123456789abcdef0123456789abcdef".to_owned(),
        evidence: PathBuf::from(
            "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1/diagnostic-driver-v1-1-1-0123456789abcdef0123456789abcdef",
        ),
        controller_sha256: "1".repeat(64),
        root_controller: PathBuf::from(
            "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1/controller-0123456789abcdef0123456789abcdef/controller",
        ),
        reader_sha256: DIAGNOSTIC_READER_SHA256.to_owned(),
        authorized_commit: "2".repeat(40),
        authorized_tree: "3".repeat(40),
    };
    let request_text = root_request_text(&synthetic)?;
    if request_text.lines().count() != 8 || !request_text.ends_with('\n') {
        return Err(ControllerError(
            "root request serialization is not exact".to_owned(),
        ));
    }
    let parsed_request = parse_root_request_text(&request_text)?;
    if parsed_request.nonce != synthetic.nonce
        || parsed_request.evidence != synthetic.evidence
        || parsed_request.root_controller != synthetic.root_controller
    {
        return Err(ControllerError(
            "pure root request round trip changed its binding".to_owned(),
        ));
    }
    let request_tree_line = format!("authorized_tree={}\n", synthetic.authorized_tree);
    let request_evidence_line = format!("evidence={}\n", path_text(&synthetic.evidence)?);
    let request_controller_line = format!(
        "root_controller={}\n",
        path_text(&synthetic.root_controller)?
    );
    for (fixture, label) in [
        (
            request_text.replace(
                &request_tree_line,
                &format!("{request_tree_line}{request_tree_line}"),
            ),
            "request duplicate key",
        ),
        (
            request_text.replace(&request_tree_line, ""),
            "request missing key",
        ),
        (
            format!("{request_text}unexpected=1\n"),
            "request unknown extra key",
        ),
        (
            request_text.trim_end_matches('\n').to_owned(),
            "request truncation",
        ),
        (
            request_text.replace(
                &request_evidence_line,
                "evidence=/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1/../escape\n",
            ),
            "request evidence traversal",
        ),
        (
            request_text.replace(
                &request_controller_line,
                "root_controller=/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1/controller-0123456789abcdef0123456789abcdef/../controller\n",
            ),
            "request controller traversal",
        ),
        (
            request_text.replace(
                &format!("reader_sha256={}\n", DIAGNOSTIC_READER_SHA256),
                &format!("reader_sha256={}\n", "4".repeat(64)),
            ),
            "request reader pin substitution",
        ),
        (
            request_text.replace(
                "nonce=0123456789abcdef0123456789abcdef\n",
                "nonce=0123456789abcdef0123456789abcdeg\n",
            ),
            "request invalid nonce",
        ),
    ] {
        require_self_test_rejection(parse_root_request_text(&fixture), label)?;
    }

    let passive_json = format!(
        r#"{{"readerSchema":1,"mode":"read-once","claim":"read-only-virtual-driver-diagnostic-snapshot","visibleDeviceUID":"{VISIBLE_UID}","writerDeviceUID":"{WRITER_UID}","endpointReadsCoherent":true,"snapshotSchemaVersion":1,"snapshotStructSize":8608,"driverInstanceGeneration":7,"allDeclaredInvariantsHold":true,"coreInitialized":true,"timelineActive":false,"activeClientCount":0,"visibleInputActiveCount":0,"hiddenWriterActiveCount":0,"coreActiveSlotCount":0,"driverRegisteredCount":0,"driverStartedCount":0,"visibleDriverRegisteredCount":0,"hiddenDriverRegisteredCount":0,"visibleDriverStartedCount":0,"hiddenDriverStartedCount":0,"timelineSeed":0,"currentSeedGeneration":0,"anchorHostTicks":0,"coreActiveSlotBitmap":"0000000000000000","driverRegisteredSlotBitmap":"0000000000000000","driverStartedSlotBitmap":"0000000000000000","driverClientSlots":[],"coreClientSlots":[]}}"#
    );
    if validate_passive_snapshot_json(passive_json.as_bytes())? != 7 {
        return Err(ControllerError(
            "native passive JSON fixture changed generation".to_owned(),
        ));
    }
    for (fixture, label) in [
        (
            passive_json.replace("\"coreInitialized\":true", "\"coreInitialized\":false"),
            "passive JSON inactive core",
        ),
        (
            passive_json.replace(
                "\"readerSchema\":1",
                "\"readerSchema\":1,\"readerSchema\":1",
            ),
            "passive JSON duplicate key",
        ),
        (format!("{passive_json}x"), "passive JSON trailing byte"),
    ] {
        require_self_test_rejection(validate_passive_snapshot_json(fixture.as_bytes()), label)?;
    }
    let mirror_json = r#"{"schema":"opensteamer.virtual-microphone-mirror-loopback.v2","status":"passed","mode":"real-dual-audioqueue","realQueuePathImplemented":true,"lifecycle":{"requiredStartOrders":["visible-first","hidden-first"],"cycles":[{"startOrder":"visible-first","quiescentBefore":true,"quiescentAfter":true,"nearZeroSharedClock":true,"timelinesAdvanced":true,"queuesStoppedAndDisposed":true},{"startOrder":"hidden-first","quiescentBefore":true,"quiescentAfter":true,"nearZeroSharedClock":true,"timelinesAdvanced":true,"queuesStoppedAndDisposed":true}]},"defaults":{"inputBeforeAfterEqual":true,"outputBeforeAfterEqual":true,"systemOutputBeforeAfterEqual":true,"hiddenEndpointNeverDefault":true,"virtualEndpointsNeverOutputDefault":true,"notificationCount":0,"mutated":false},"teardown":{"cleanupEvidenceComplete":true,"callbackGatesDrained":true,"listenersRemoved":true,"contextsReleased":true},"failureCode":"none","failureReasons":[]}"#;
    validate_mirror_loopback_json(mirror_json.as_bytes())?;
    for (fixture, label) in [
        (
            mirror_json.replace("\"mutated\":false", "\"mutated\":true"),
            "both-order JSON default mutation",
        ),
        (
            mirror_json.replace(
                "\"status\":\"passed\"",
                "\"status\":\"passed\",\"status\":\"passed\"",
            ),
            "both-order JSON duplicate key",
        ),
        (
            mirror_json.trim_end_matches('}').to_owned(),
            "both-order JSON truncation",
        ),
    ] {
        require_self_test_rejection(validate_mirror_loopback_json(fixture.as_bytes()), label)?;
    }

    let root_state = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_STATE_V1\nstate=COREAUDIO_RELOADED\ninitial_host_pid=123\ninitial_host_runs=1\ninitial_host_start=Sat Aug 23 12:34:56 2026\ninitial_host_nonce={}\ninitial_host_lock_device=16777229\ninitial_host_lock_inode=28002132\nrollback_reserve_status=allocated\nrollback_reserve_device=16777229\nrollback_reserve_inode=28009999\nrollback_reserve_bytes=8388608\ninput_uid=com.apple.BuiltInMicrophoneDevice\noutput_uid=com.apple.BuiltInSpeakerDevice\nsystem_output_uid=com.apple.BuiltInSpeakerDevice\n",
        "a".repeat(64)
    );
    let (root_state_token, root_state_host, root_state_route, root_state_reserve) =
        parse_root_state_text(&root_state)?;
    if root_state_token != UpdateState::CoreAudioReloaded
        || root_state_host.pid != 123
        || root_state_route.is_none()
        || root_state_reserve.is_none_or(|reserve| reserve.released)
    {
        return Err(ControllerError(
            "pure root state round trip changed its binding".to_owned(),
        ));
    }
    for (fixture, label) in [
        (
            root_state.replace(
                "state=COREAUDIO_RELOADED\n",
                "state=COREAUDIO_RELOADED\nstate=HOST_STOPPED\n",
            ),
            "root state duplicate key",
        ),
        (
            root_state.replace("state=COREAUDIO_RELOADED\n", "state=UNKNOWN\n"),
            "root state unknown token",
        ),
        (
            root_state.replace("initial_host_runs=1\n", ""),
            "root state missing key",
        ),
        (
            format!("{root_state}unexpected=1\n"),
            "root state extra key",
        ),
        (
            root_state.trim_end_matches('\n').to_owned(),
            "root state truncation",
        ),
        (
            root_state.replace("initial_host_runs=1\n", "initial_host_runs=01\n"),
            "root state leading-zero runs",
        ),
        (
            root_state.replace("initial_host_runs=1\n", "initial_host_runs=0\n"),
            "root state zero runs",
        ),
        (
            root_state.replace(
                "initial_host_lock_device=16777229\n",
                "initial_host_lock_device=+16777229\n",
            ),
            "root state signed device",
        ),
        (
            root_state.replace(
                "initial_host_lock_inode=28002132\n",
                "initial_host_lock_inode=0\n",
            ),
            "root state zero inode",
        ),
        (
            root_state.replace(
                "initial_host_start=Sat Aug 23 12:34:56 2026\n",
                "initial_host_start=not-a-process-time\n",
            ),
            "root state malformed process start",
        ),
    ] {
        require_self_test_rejection(parse_root_state_text(&fixture), label)?;
    }

    let root_journal = format!(
        "{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE AUTHENTICATED host_pid=123 host_runs=1 coreaudiod_pid=456 coreaudiod_runs=2 release_commit={} release_tree={}\nSTATE HOST_STOP_INITIATED available_bytes=1073741824 reserve_bytes=8388608 reserve_device=16777229 reserve_inode=28009999\nSTATE HOST_STOPPED\nSTATE PRIOR_DRIVER_RETAINED device=16777229 inode=27877539\nSTATE CANDIDATE_PUBLISHED\nSTATE COREAUDIO_RELOADED old_pid=456 new_pid=457 new_runs=3\nSTATE DRIVER_VALIDATED driver_generation=99\nSTATE HOST_BOOTSTRAPPED pid=789 runs=1 nonce={}\nSTATE READY_VERIFIED\nSTATE COMMITTED\n",
        "b".repeat(40),
        "c".repeat(40),
        "d".repeat(64)
    );
    if parse_journal_text(&root_journal, ROOT_JOURNAL_HEADER)? != UpdateState::Committed {
        return Err(ControllerError(
            "pure forward journal did not reach committed".to_owned(),
        ));
    }
    let authenticated_line = format!(
        "STATE AUTHENTICATED host_pid=123 host_runs=1 coreaudiod_pid=456 coreaudiod_runs=2 release_commit={} release_tree={}\n",
        "b".repeat(40),
        "c".repeat(40)
    );
    for (fixture, label) in [
        (
            root_journal.replace(
                &authenticated_line,
                &authenticated_line.replace("host_pid=123 ", "host_pid=123 host_pid=123 "),
            ),
            "journal duplicate field",
        ),
        (
            root_journal.replace(
                &authenticated_line,
                &authenticated_line.replace(" host_runs=1", ""),
            ),
            "journal missing field",
        ),
        (
            root_journal.replace(
                &authenticated_line,
                &authenticated_line.replace(" host_runs=1", " host_runs=1 extra=1"),
            ),
            "journal unknown field",
        ),
        (
            root_journal.trim_end_matches('\n').to_owned(),
            "journal truncation",
        ),
        (
            format!("{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE UNKNOWN\n"),
            "journal unknown state",
        ),
        (
            format!("{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE HOST_STOP_INITIATED\n"),
            "journal skipped transition",
        ),
        (
            format!("{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\n{authenticated_line}STATE HOST_STOPPED\n"),
            "journal reordered transition",
        ),
        (
            format!("{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE BEGUN\n"),
            "journal duplicate state",
        ),
        (
            root_journal.replace("host_pid=123 ", "host_pid=0123 "),
            "journal noncanonical number",
        ),
    ] {
        require_self_test_rejection(parse_journal_text(&fixture, ROOT_JOURNAL_HEADER), label)?;
    }

    let rollback_journal = format!(
        "{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\n{authenticated_line}STATE HOST_STOP_INITIATED available_bytes=1073741824 reserve_bytes=8388608 reserve_device=16777229 reserve_inode=28009999\nSTATE HOST_STOPPED\nSTATE ROLLBACK_STARTED\nSTATE PRIOR_DRIVER_RESTORED\nSTATE ROLLBACK_COREAUDIO_RELOAD_INITIATED old_pid=456 old_runs=3\nSTATE ROLLBACK_COREAUDIO_RELOADED old_pid=456 new_pid=457 new_runs=4\nSTATE HOST_REBOOTSTRAPPED pid=789 runs=1 nonce={}\nSTATE ROLLED_BACK\n",
        "e".repeat(64)
    );
    if parse_journal_text(&rollback_journal, ROOT_JOURNAL_HEADER)? != UpdateState::RolledBack {
        return Err(ControllerError(
            "durable rollback reload bracket journal did not parse".to_owned(),
        ));
    }
    require_self_test_rejection(
        parse_journal_text(
            &rollback_journal.replace(" old_runs=3", ""),
            ROOT_JOURNAL_HEADER,
        ),
        "rollback reload intent without exact baseline runs",
    )?;

    let canonical_begun = format!("{ROOT_JOURNAL_HEADER}\nSTATE BEGUN\n");
    let exact_successor = format!("{canonical_begun}{authenticated_line}");
    if classify_pending_journal_snapshot(
        &canonical_begun,
        UpdateState::Begun,
        &exact_successor,
        ROOT_JOURNAL_HEADER,
    )? != PendingJournalAction::Promote(UpdateState::Authenticated)
        || classify_pending_journal_snapshot(
            &canonical_begun,
            UpdateState::Begun,
            &canonical_begun,
            ROOT_JOURNAL_HEADER,
        )? != PendingJournalAction::Discard
        || classify_pending_journal_snapshot(
            &canonical_begun,
            UpdateState::Begun,
            exact_successor.trim_end_matches('\n'),
            ROOT_JOURNAL_HEADER,
        )? != PendingJournalAction::Discard
    {
        return Err(ControllerError(
            "atomic journal successor/stale/torn reconciliation model failed".to_owned(),
        ));
    }
    let canonical_authenticated = exact_successor.clone();
    let divergent_authenticated = exact_successor.replace("host_pid=123", "host_pid=124");
    require_self_test_rejection(
        classify_pending_journal_snapshot(
            &canonical_authenticated,
            UpdateState::Authenticated,
            &divergent_authenticated,
            ROOT_JOURNAL_HEADER,
        ),
        "valid divergent pending journal",
    )?;
    let two_successors = format!(
        "{exact_successor}STATE HOST_STOP_INITIATED available_bytes=1073741824 reserve_bytes=8388608 reserve_device=16777229 reserve_inode=28009999\n"
    );
    require_self_test_rejection(
        classify_pending_journal_snapshot(
            &canonical_begun,
            UpdateState::Begun,
            &two_successors,
            ROOT_JOURNAL_HEADER,
        ),
        "pending journal with two successors",
    )?;
    let canonical_ready = root_journal
        .strip_suffix("STATE COMMITTED\n")
        .ok_or_else(|| ControllerError("commit fixture has no terminal record".to_owned()))?;
    if classify_pending_journal_snapshot(
        canonical_ready,
        UpdateState::ReadyVerified,
        &root_journal,
        ROOT_JOURNAL_HEADER,
    )? != PendingJournalAction::Promote(UpdateState::Committed)
    {
        return Err(ControllerError(
            "pending committed journal was not recognized as terminal success".to_owned(),
        ));
    }
    if rollback_reserve_released(0, 0)? != true
        || rollback_reserve_released(0, 512).is_ok()
        || rollback_reserve_released(ROLLBACK_RESERVE_BYTES, ROLLBACK_RESERVE_BYTES)?
        || rollback_reserve_released(ROLLBACK_RESERVE_BYTES - 1, ROLLBACK_RESERVE_BYTES).is_ok()
        || rollback_reserve_released(ROLLBACK_RESERVE_BYTES, ROLLBACK_RESERVE_BYTES - 512).is_ok()
        || prestop_headroom_is_sufficient(
            MINIMUM_PRESTOP_AVAILABLE_BYTES + ROLLBACK_RESERVE_BYTES - 1,
            false,
        )
        || !prestop_headroom_is_sufficient(
            MINIMUM_PRESTOP_AVAILABLE_BYTES + ROLLBACK_RESERVE_BYTES,
            false,
        )
        || prestop_headroom_is_sufficient(MINIMUM_PRESTOP_AVAILABLE_BYTES - 1, true)
        || !prestop_headroom_is_sufficient(MINIMUM_PRESTOP_AVAILABLE_BYTES, true)
    {
        return Err(ControllerError(
            "rollback reserve/headroom boundary model failed".to_owned(),
        ));
    }
    if ls_mode_has_forbidden_extended_metadata("-rwxr-xr-x+") != true
        || ls_mode_has_forbidden_extended_metadata("-rwxr-xr-x@") != true
        || ls_mode_has_forbidden_extended_metadata("-rwxr-xr-x")
    {
        return Err(ControllerError(
            "POSIX ACL/xattr rejection model failed".to_owned(),
        ));
    }
    let pointer_bytes = b"/Library/Application Support/opensteamer/diagnostic-driver-updates-v1/transaction-0123456789abcdef0123456789abcdef\n";
    if classify_root_pointer_bytes(None, pointer_bytes)? != RootPointerImage::Absent
        || classify_root_pointer_bytes(Some(b""), pointer_bytes)? != RootPointerImage::Partial
        || classify_root_pointer_bytes(Some(&pointer_bytes[..19]), pointer_bytes)?
            != RootPointerImage::Partial
        || classify_root_pointer_bytes(Some(pointer_bytes), pointer_bytes)?
            != RootPointerImage::Complete
        || root_pointer_recovery_action(RootPointerImage::Complete, RootPointerImage::Absent)?
            != RootPointerRecoveryAction::UseCanonical
        || root_pointer_recovery_action(RootPointerImage::Absent, RootPointerImage::Complete)?
            != RootPointerRecoveryAction::PromotePending
        || root_pointer_recovery_action(RootPointerImage::Partial, RootPointerImage::Complete)?
            != RootPointerRecoveryAction::PreserveHost
        || root_pointer_recovery_action(RootPointerImage::Absent, RootPointerImage::Partial)?
            != RootPointerRecoveryAction::PreserveHost
    {
        return Err(ControllerError(
            "atomic root-pointer recovery matrix failed".to_owned(),
        ));
    }
    require_self_test_rejection(
        classify_root_pointer_bytes(Some(b"hostile-pointer"), pointer_bytes),
        "root pointer unrelated bytes",
    )?;
    require_self_test_rejection(
        classify_root_pointer_bytes(
            Some(&[pointer_bytes.as_slice(), b"extra"].concat()),
            pointer_bytes,
        ),
        "root pointer overlong bytes",
    )?;
    require_self_test_rejection(
        root_pointer_recovery_action(RootPointerImage::Complete, RootPointerImage::Partial),
        "complete root pointer with partial pending image",
    )?;
    if !canonical_applications_values_are_exact(
        Path::new("/Applications"),
        false,
        true,
        ROOT_ID,
        LEGACY_EXECUTABLE_GROUP,
        0o775,
        APPLICATIONS_DEVICE,
        APPLICATIONS_INODE,
        APPLICATIONS_NLINK,
        APPLICATIONS_FLAGS,
    ) || canonical_applications_values_are_exact(
        Path::new("/Applications"),
        true,
        true,
        ROOT_ID,
        LEGACY_EXECUTABLE_GROUP,
        0o775,
        APPLICATIONS_DEVICE,
        APPLICATIONS_INODE,
        APPLICATIONS_NLINK,
        APPLICATIONS_FLAGS,
    ) || canonical_applications_values_are_exact(
        Path::new("/Applications"),
        false,
        true,
        ROOT_ID,
        USER_GROUP,
        0o775,
        APPLICATIONS_DEVICE,
        APPLICATIONS_INODE,
        APPLICATIONS_NLINK,
        APPLICATIONS_FLAGS,
    ) || canonical_applications_values_are_exact(
        Path::new("/Applications"),
        false,
        true,
        ROOT_ID,
        LEGACY_EXECUTABLE_GROUP,
        0o775,
        APPLICATIONS_DEVICE,
        APPLICATIONS_INODE + 1,
        APPLICATIONS_NLINK,
        APPLICATIONS_FLAGS,
    ) || canonical_applications_values_are_exact(
        Path::new("/Applications"),
        false,
        true,
        ROOT_ID,
        LEGACY_EXECUTABLE_GROUP,
        0o775,
        APPLICATIONS_DEVICE,
        APPLICATIONS_INODE,
        APPLICATIONS_NLINK,
        0,
    ) {
        return Err(ControllerError(
            "pinned canonical /Applications exception is overbroad".to_owned(),
        ));
    }
    require_lower_hex(
        HOST_BUNDLE_MANIFEST_SHA256,
        64,
        "host bundle manifest SHA-256",
    )?;

    let host_launch = format!(
        "gui/{USER_ID}/{HOST_LABEL} = {{\n\tpath = {HOST_PLIST}\n\ttype = LaunchAgent\n\tstate = running\n\tprogram = {HOST_EXECUTABLE}\n\targuments = {{\n\t\t{HOST_EXECUTABLE}\n\t\t{}\n\t}}\n\tpid = 123\n\truns = 1\n}}\n",
        HOST_ARGUMENTS.join("\n\t\t")
    );
    if parse_host_launch_state(&host_launch)? != (123, 1) {
        return Err(ControllerError(
            "exact host launch identity fixture did not parse".to_owned(),
        ));
    }
    for (fixture, label) in [
        (
            host_launch.replace("--verbose\n", "--verbose\n\t\t--extra\n"),
            "host launch extra argument",
        ),
        (
            host_launch.replace("type = LaunchAgent", "type = LaunchDaemon"),
            "host launch wrong type",
        ),
        (
            format!("{host_launch}trailing\n"),
            "host launch trailing record",
        ),
        (
            host_launch.replace("pid = 123\n", "pid = 123\n\tpid = 123\n"),
            "host launch duplicate pid",
        ),
    ] {
        require_self_test_rejection(parse_host_launch_state(&fixture), label)?;
    }
    let coreaudio_launch = "system/com.apple.audio.coreaudiod = {\n\tstate = running\n\tprogram = /usr/sbin/coreaudiod\n\tdomain = system\n\tusername = _coreaudiod\n\tgroup = _coreaudiod\n\truns = 9\n\tpid = 456\n}\n";
    if parse_coreaudio_launch_state(coreaudio_launch)? != (456, 9) {
        return Err(ControllerError(
            "exact coreaudiod launch identity fixture did not parse".to_owned(),
        ));
    }
    let same_second_before = CoreAudioGeneration {
        pid: 456,
        runs: 9,
        process_start: "Sat Aug 23 12:34:56 2026".to_owned(),
    };
    let same_second_after = CoreAudioGeneration {
        pid: 457,
        runs: 10,
        process_start: same_second_before.process_start.clone(),
    };
    if !coreaudio_restart_successor_is_exact(&same_second_before, &same_second_after) {
        return Err(ControllerError(
            "same-second exact Core Audio successor was rejected".to_owned(),
        ));
    }
    for (fixture, label) in [
        (
            coreaudio_launch.replace("domain = system", "domain = gui/501"),
            "coreaudiod wrong domain",
        ),
        (
            coreaudio_launch.replace("runs = 9\n", "runs = 9\n\truns = 9\n"),
            "coreaudiod duplicate runs",
        ),
        (
            format!("{coreaudio_launch}trailing\n"),
            "coreaudiod trailing record",
        ),
    ] {
        require_self_test_rejection(parse_coreaudio_launch_state(&fixture), label)?;
    }

    for (journal, durable, expected, label) in [
        (
            UpdateState::Begun,
            None,
            RootRecoveryPlan::PrestopPreserveHost,
            "root pointer/journal without state",
        ),
        (
            UpdateState::Authenticated,
            Some(UpdateState::Authenticated),
            RootRecoveryPlan::PrestopPreserveHost,
            "authenticated before reserve/stop",
        ),
        (
            UpdateState::Authenticated,
            Some(UpdateState::HostStopInitiated),
            RootRecoveryPlan::ResumeRollback,
            "authenticated journal with durable stop intent",
        ),
        (
            UpdateState::Committed,
            Some(UpdateState::ReadyVerified),
            RootRecoveryPlan::RepairCommittedState,
            "committed journal/state publication lag",
        ),
        (
            UpdateState::RolledBack,
            Some(UpdateState::HostRebootstrapped),
            RootRecoveryPlan::RepairRolledBackState,
            "rolled-back journal/state publication lag",
        ),
        (
            UpdateState::PrestopAborted,
            Some(UpdateState::Authenticated),
            RootRecoveryPlan::PrestopPreserveHost,
            "prestop pending promotion/state lag",
        ),
    ] {
        if root_recovery_plan(journal, durable) != expected {
            return Err(ControllerError(format!(
                "root recovery-plan fixture failed: {label}"
            )));
        }
    }
    for (journal, durable, label) in [
        (
            UpdateState::Authenticated,
            Some(UpdateState::HostStopped),
            "authenticated journal with non-stop durable state",
        ),
        (
            UpdateState::ReadyVerified,
            Some(UpdateState::Committed),
            "root state ahead of commit journal",
        ),
        (
            UpdateState::Committed,
            Some(UpdateState::Authenticated),
            "committed journal with prestop state",
        ),
    ] {
        if root_recovery_plan(journal, durable) != RootRecoveryPlan::Reject {
            return Err(ControllerError(format!(
                "hostile root recovery pair was accepted: {label}"
            )));
        }
    }

    let resumable = [
        UpdateState::HostStopInitiated,
        UpdateState::HostStopped,
        UpdateState::PriorDriverRetained,
        UpdateState::CandidatePublished,
        UpdateState::CoreAudioReloaded,
        UpdateState::DriverValidated,
        UpdateState::HostBootstrapped,
        UpdateState::ReadyVerified,
        UpdateState::RollbackStarted,
        UpdateState::FailedDriverArchived,
        UpdateState::PriorDriverRestored,
        UpdateState::RollbackCoreAudioReloadInitiated,
        UpdateState::RollbackCoreAudioReloaded,
        UpdateState::HostRebootstrapped,
        UpdateState::RolledBack,
        UpdateState::CriticalFailure,
    ];
    let all_states = [
        UpdateState::Begun,
        UpdateState::Authenticated,
        UpdateState::PrestopAborted,
        UpdateState::HostStopInitiated,
        UpdateState::HostStopped,
        UpdateState::PriorDriverRetained,
        UpdateState::CandidatePublished,
        UpdateState::CoreAudioReloaded,
        UpdateState::DriverValidated,
        UpdateState::HostBootstrapped,
        UpdateState::ReadyVerified,
        UpdateState::Committed,
        UpdateState::RollbackStarted,
        UpdateState::FailedDriverArchived,
        UpdateState::PriorDriverRestored,
        UpdateState::RollbackCoreAudioReloadInitiated,
        UpdateState::RollbackCoreAudioReloaded,
        UpdateState::HostRebootstrapped,
        UpdateState::RolledBack,
        UpdateState::CriticalFailure,
    ];
    for journal_state in resumable {
        if rollback_resume_action(journal_state) == RollbackResumeAction::Refuse
            || !all_states
                .iter()
                .any(|state| journal_and_root_state_are_crash_coherent(journal_state, *state))
        {
            return Err(ControllerError(format!(
                "resumable state lacks a pure recovery/coherence model: {}",
                journal_state.token()
            )));
        }
    }
    for (journal_state, state) in [
        (UpdateState::HostStopped, UpdateState::CandidatePublished),
        (UpdateState::CoreAudioReloaded, UpdateState::DriverValidated),
        (UpdateState::HostRebootstrapped, UpdateState::RolledBack),
        (UpdateState::RolledBack, UpdateState::Committed),
        (UpdateState::Committed, UpdateState::RolledBack),
        (
            UpdateState::PriorDriverRetained,
            UpdateState::PriorDriverRetained,
        ),
    ] {
        if journal_and_root_state_are_crash_coherent(journal_state, state) {
            return Err(ControllerError(
                "impossible ahead/divergent journal-state pair was accepted".to_owned(),
            ));
        }
    }
    if rollback_resume_action(UpdateState::HostRebootstrapped)
        != RollbackResumeAction::FinalizePreservingHost
        || rollback_resume_action(UpdateState::Committed) != RollbackResumeAction::Refuse
        || valid_transition(UpdateState::Committed, UpdateState::CriticalFailure)
        || valid_transition(UpdateState::RolledBack, UpdateState::CriticalFailure)
        || valid_transition(UpdateState::Committed, UpdateState::RollbackStarted)
    {
        return Err(ControllerError(
            "terminal/finalize-only rollback model is unsafe".to_owned(),
        ));
    }
    if critical_failure_state_publication_is_authorized(
        UpdateState::HostStopped,
        false,
        UpdateState::HostStopped,
    ) || !critical_failure_state_publication_is_authorized(
        UpdateState::HostStopped,
        true,
        UpdateState::CriticalFailure,
    ) || !critical_failure_state_publication_is_authorized(
        UpdateState::CriticalFailure,
        false,
        UpdateState::CriticalFailure,
    ) {
        return Err(ControllerError(
            "failed journal publication could advance root state".to_owned(),
        ));
    }
    if uid501_can_traverse_and_read(ROOT_PRIVATE_MODE, ROOT_SEALED_EXECUTABLE_MODE)
        || uid501_can_traverse_and_execute(ROOT_PRIVATE_MODE, ROOT_SEALED_EXECUTABLE_MODE)
        || !uid501_can_traverse_and_read(ROOT_SEALED_TRAVERSE_MODE, ROOT_SEALED_EXECUTABLE_MODE)
        || !uid501_can_traverse_and_execute(ROOT_SEALED_TRAVERSE_MODE, ROOT_SEALED_EXECUTABLE_MODE)
        || uid501_can_modify(ROOT_SEALED_TRAVERSE_MODE, ROOT_SEALED_EXECUTABLE_MODE)
        || !uid501_can_traverse_and_read(ROOT_SEALED_TRAVERSE_MODE, ROOT_SEALED_RECORD_MODE)
        || uid501_can_modify(ROOT_SEALED_TRAVERSE_MODE, ROOT_SEALED_RECORD_MODE)
        || Path::new(ROOT_PROBE_PARENT).starts_with(ROOT_UPDATE_ROOT)
        || Path::new(ROOT_CONTROLLER_PARENT).starts_with(ROOT_UPDATE_ROOT)
    {
        return Err(ControllerError(
            "sealed controller/probe traversal model is unsafe".to_owned(),
        ));
    }
    if !uid501_source_path_is_allowed(Path::new(BOTH_ORDER_PROBE), false)
        || !uid501_source_path_is_allowed(Path::new(HOST_EXECUTABLE), false)
        || uid501_source_path_is_allowed(Path::new("/tmp/controller"), false)
        || uid501_source_path_is_allowed(
            &Path::new(CANDIDATE_DRIVER).join("Contents/../Contents/Info.plist"),
            false,
        )
        || uid501_source_path_is_allowed(
            Path::new("/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1/../escape/probes/both-order.json"),
            true,
        )
    {
        return Err(ControllerError(
            "UID501 openat lexical scope accepted a hostile path".to_owned(),
        ));
    }
    let source = include_str!("opensteamer-diagnostic-driver-v1-update-controller.rs");
    let forbidden = [
        ["AudioObjectSet", "PropertyData"].concat(),
        ["/usr/sbin/", "installer"].concat(),
        ["default-route-", "guardian"].concat(),
        ["public-", "vpio"].concat(),
        ["sudo ", "-k"].concat(),
        ["/usr/bin/", "ditto"].concat(),
    ];
    for forbidden in forbidden {
        if source.contains(&forbidden) {
            return Err(ControllerError(format!(
                "forbidden mutation surface appears in controller: {forbidden}"
            )));
        }
    }
    if !source.contains("--read-once")
        || !source.contains("inputBeforeAfterEqual")
        || !source.contains("rollback_root_transaction")
        || !source.contains("ROOT_CONTROLLER_PARENT")
        || !source.contains("ROOT_RECOVERY_CONTROLLER")
        || !source.contains("ROOT_SEALED_ROLLBACK_MODE")
        || !source.contains("UID501_OPENAT_HELPER_IMPLEMENTATION")
        || !source.contains("BOUNDED_NATIVE_JSON_VALIDATOR")
        || !source.contains("ROOT_HELD_BOTH_ORDER_RESULT")
        || !source.contains("ROOT_ANCESTRY_ACL_XATTR_SEAL")
        || !source.contains("ROOT_BOOTSTRAP_LOCATOR")
        || !source.contains("sudo_stream_root_file")
        || !source.contains("POSIX_ACL_FORBIDDEN")
        || !source.contains("effective_state_with_pending")
        || !source.contains("RollbackCoreAudioReloadInitiated")
        || !source.contains("write_root_recovery_result")
        || !source.contains("OPENSTEAMER_V8_HOST_BUNDLE_FD_MANIFEST_V1")
        || !source.contains("ROOT_ACTIVE_POINTER_PENDING")
        || !source.contains("prestop-abort-journal.txt")
        || !source.contains("canonical_applications_values_are_exact")
        || !source.contains(".current_dir(\"/\")")
    {
        return Err(ControllerError(
            "required guarded-deployment contract is absent".to_owned(),
        ));
    }
    println!("DIAGNOSTIC_DRIVER_V1_SELF_TEST_OK tests=105");
    Ok(())
}
