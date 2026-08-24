//! Narrow UID501 resume stager for the exact authenticated V2 attempt.
//!
//! This program never runs as root and contains no host-stop, Core Audio reload,
//! driver publication, route mutation, pairing mutation, or legacy mutation code.
//! Its only privileged operations are constant-argument inspection/staging commands
//! and execution of the sealed root-owned original/fixed V2 controllers.

use std::collections::BTreeSet;
use std::env;
use std::ffi::{CString, OsStr};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitCode, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

type Result<T> = std::result::Result<T, StagerError>;

#[derive(Debug)]
struct StagerError(String);

impl std::fmt::Display for StagerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl From<std::io::Error> for StagerError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

const USER_ID: u32 = 501;
const USER_GROUP: u32 = 20;
const ROOT_ID: u32 = 0;
const ROOT_GROUP: u32 = 0;
const APPLICATIONS_DEVICE: u64 = 16_777_229;
const APPLICATIONS_INODE: u64 = 4_982_341;
const APPLICATIONS_NLINK: u64 = 26;
const APPLICATIONS_FLAGS: u32 = 1_048_576;
const O_NOFOLLOW: i32 = 0x0000_0100;
const O_CLOEXEC: i32 = 0x0100_0000;
const O_DIRECTORY: i32 = 0x0010_0000;
const O_RDONLY: i32 = 0;
const O_RDWR: i32 = 2;
const ACL_TYPE_EXTENDED: i32 = 0x0000_0100;
const ACL_FIRST_ENTRY: i32 = 0;
const ENOENT: i32 = 2;
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const MAX_OUTPUT_BYTES: usize = 8 * 1_048_576;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const ROOT_TRANSACTION_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const RECOVERY_QUIESCENCE_TIMEOUT: Duration = Duration::from_secs(35 * 60);

unsafe extern "C" {
    fn getuid() -> u32;
    fn geteuid() -> u32;
    fn flock(file_descriptor: i32, operation: i32) -> i32;
    fn openat(directory_fd: i32, path: *const i8, flags: i32, mode: u32) -> i32;
    fn dup(file_descriptor: i32) -> i32;
    fn lseek(file_descriptor: i32, offset: i64, whence: i32) -> i64;
    fn fdopendir(file_descriptor: i32) -> *mut std::ffi::c_void;
    fn readdir(directory: *mut std::ffi::c_void) -> *mut DarwinDirent;
    fn closedir(directory: *mut std::ffi::c_void) -> i32;
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
    fn acl_get_fd_np(file_descriptor: i32, acl_type: i32) -> *mut std::ffi::c_void;
    fn acl_get_entry(
        acl: *mut std::ffi::c_void,
        entry_id: i32,
        entry: *mut *mut std::ffi::c_void,
    ) -> i32;
    fn acl_free(object: *mut std::ffi::c_void) -> i32;
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

const RESUME_PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v2-resume-preflight";
const RESUME_EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v2-resume";
const RESUME_SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v2-resume";

const EXPECTED_REPO: &str = "/Users/ahmed/Documents/Codex/opensteamer";
const EXPECTED_REMOTE: &str = "https://github.com/ahmedelami/opensteamer.git";
const ORIGINAL_SOURCE: &str = "/Users/ahmed/Documents/Codex/opensteamer/macOS/scripts/opensteamer-diagnostic-driver-v2-update-controller.rs";
const RETAINED_V2_ORIGINAL_SOURCE_SHA256: &str =
    "4df37ebcb2634ea1fed78165cc530ea8cb739fe1e9b59744010e2b64b922c98b";
const RETAINED_V2_ORIGINAL_CONTROLLER_SHA256: &str =
    "da55bc73f7143ffe6f09516c84c70532c18d37af53da0e12c00fb79924926201";
const RETAINED_V2_ORIGINAL_CONTROLLER_SIZE: u64 = 1_622_120;
const RETAINED_V2_NONCE: &str = "ea5a600cf397995156907bc1609b68d6";
const RETAINED_V2_RELEASE_COMMIT: &str = "eb1463d28fa84d9b768dfc4f17e2e4466c9f3f87";
const RETAINED_V2_RELEASE_TREE: &str = "1258ff5f31c183bdc75bc4cc7734aae72d94bdf1";
const DIAGNOSTIC_READER_SHA256: &str =
    "6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded";
const DIAGNOSTIC_READER_SIZE: u64 = 118_832;

const USER_SUPPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer";
const RETAINED_DEVICE: u64 = 16_777_229;
const RETAINED_V1_DEVICE: u64 = RETAINED_DEVICE;
const RETAINED_V1_USER_SUPPORT_INODE: u64 = 20_549_090;
const RETAINED_V1_USER_UPDATE_ROOT_INODE: u64 = 28_503_613;
const RETAINED_V1_USER_UPDATE_LOCK_INODE: u64 = 28_503_554;
const RETAINED_V1_USER_ACTIVE_POINTER_INODE: u64 = 28_503_619;
const RETAINED_V1_USER_ACTIVE_POINTER_SHA256: &str =
    "0dbb83c4ce3fbba0cb851365b1ea9fa98f2ab356f2b182ab02552cb538d571ea";
const RETAINED_V1_EVIDENCE_LEAF: &str =
    "diagnostic-driver-v1-1787554318-4604-c527b05a0a64c531c19533240b9df031";
const RETAINED_V1_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1/diagnostic-driver-v1-1787554318-4604-c527b05a0a64c531c19533240b9df031";
const RETAINED_V1_EVIDENCE_INODE: u64 = 28_503_614;
const RETAINED_V1_PROBES_INODE: u64 = 28_503_615;
const RETAINED_V1_READER_INODE: u64 = 28_503_616;
const RETAINED_V1_REQUEST_INODE: u64 = 28_503_618;
const RETAINED_V1_JOURNAL_INODE: u64 = 28_503_620;
const RETAINED_V1_JOURNAL_SHA256: &str =
    "7e488883f3069b7dd86ad82e46c70a7b40ca7d1a5458d10f6d3b17291e048504";
const RETAINED_V1_REQUEST_SHA256: &str =
    "b5a56144453a12fa5b6b65c14baab56a8947319804f8bc1a7934fb99869a2baf";
const RETAINED_V1_ROOT_BOOTSTRAP_LOCATOR: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-bootstrap-v1.txt";
const RETAINED_V1_ROOT_BOOTSTRAP_LOCATOR_INODE: u64 = 28_503_621;
const RETAINED_V1_JOURNAL_TEXT: &str = concat!(
    "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V1\n",
    "STATE BEGUN\n",
    "STATE AUTHENTICATED nonce=c527b05a0a64c531c19533240b9df031 host_pid=98080 ",
    "release_commit=82f6fc48ffcfa59c8c7a8ee2372ff78c14b95eba ",
    "release_tree=68dcacada57bca418381781a1acdb5f4b7dfc652\n",
);
const RETAINED_V1_REQUEST_TEXT: &str = concat!(
    "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_REQUEST_V1\n",
    "nonce=c527b05a0a64c531c19533240b9df031\n",
    "evidence=/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1/",
    "diagnostic-driver-v1-1787554318-4604-c527b05a0a64c531c19533240b9df031\n",
    "controller_sha256=26f27b033bc02b9c21860e533a4032644c405b9335c5208b9eba9c8769d4e0ec\n",
    "root_controller=/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1/",
    "controller-c527b05a0a64c531c19533240b9df031/controller\n",
    "reader_sha256=6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded\n",
    "authorized_commit=82f6fc48ffcfa59c8c7a8ee2372ff78c14b95eba\n",
    "authorized_tree=68dcacada57bca418381781a1acdb5f4b7dfc652\n",
);

const RETAINED_V2_USER_UPDATE_ROOT_INODE: u64 = 28_527_190;
const RETAINED_V2_USER_UPDATE_LOCK_INODE: u64 = 28_527_165;
const RETAINED_V2_USER_ACTIVE_POINTER_INODE: u64 = 28_527_196;
const RETAINED_V2_USER_ACTIVE_POINTER_SHA256: &str =
    "9a4aa07cab19e0abe07d10e5486f88c86bacf9d377ad5c4a771270bc0e3999a6";
const RETAINED_V2_EVIDENCE_LEAF: &str =
    "diagnostic-driver-v2-1787558786-39111-ea5a600cf397995156907bc1609b68d6";
const RETAINED_V2_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v2/diagnostic-driver-v2-1787558786-39111-ea5a600cf397995156907bc1609b68d6";
const RETAINED_V2_EVIDENCE_INODE: u64 = 28_527_191;
const RETAINED_V2_PROBES_INODE: u64 = 28_527_192;
const RETAINED_V2_READER_INODE: u64 = 28_527_193;
const RETAINED_V2_REQUEST_INODE: u64 = 28_527_195;
const RETAINED_V2_JOURNAL_INODE: u64 = 28_527_197;
const RETAINED_V2_JOURNAL_SHA256: &str =
    "0e535de861063877ac88ebbaa48092a8d519046115d574a5e6d429110fae30cc";
const RETAINED_V2_REQUEST_SHA256: &str =
    "6193d1d942fcc7e4b3da2ca0c7dfbc3e75b4c6b4ebb8cda1ca639a7ba70294ac";
const RETAINED_V2_JOURNAL_TEXT: &str = concat!(
    "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V2\n",
    "STATE BEGUN\n",
    "STATE AUTHENTICATED nonce=ea5a600cf397995156907bc1609b68d6 host_pid=98080 ",
    "release_commit=eb1463d28fa84d9b768dfc4f17e2e4466c9f3f87 ",
    "release_tree=1258ff5f31c183bdc75bc4cc7734aae72d94bdf1\n",
);
const RETAINED_V2_REQUEST_TEXT: &str = concat!(
    "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_REQUEST_V2\n",
    "nonce=ea5a600cf397995156907bc1609b68d6\n",
    "evidence=/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v2/",
    "diagnostic-driver-v2-1787558786-39111-ea5a600cf397995156907bc1609b68d6\n",
    "controller_sha256=da55bc73f7143ffe6f09516c84c70532c18d37af53da0e12c00fb79924926201\n",
    "root_controller=/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/",
    "controller-ea5a600cf397995156907bc1609b68d6/controller\n",
    "reader_sha256=6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded\n",
    "authorized_commit=eb1463d28fa84d9b768dfc4f17e2e4466c9f3f87\n",
    "authorized_tree=1258ff5f31c183bdc75bc4cc7734aae72d94bdf1\n",
);

const ROOT_SUPPORT: &str = "/Library/Application Support/opensteamer";
const ROOT_BOOTSTRAP_LOCATOR: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-bootstrap-v2.txt";
const RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE: u64 = 28_527_198;
const ROOT_CONTROLLER_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2";
const RETAINED_V2_ROOT_CONTROLLER_PARENT_INODE: u64 = 28_527_199;
const RETAINED_V2_ROOT_CONTROLLER_SUPPORT: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6";
const RETAINED_V2_ROOT_CONTROLLER: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/controller";
const RETAINED_V2_ROOT_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/controller.sha256";
const RETAINED_V2_ROOT_CONTROLLER_IDENTITY: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/controller-identity.txt";
const RETAINED_V2_ROOT_BOOTSTRAP_REQUEST: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/bootstrap-request.txt";
const ROOT_RECOVERY_CONTROLLER: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/recovery-controller";
const ROOT_RECOVERY_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/recovery-controller.sha256";
const ROOT_SEALED_TRAVERSE_MODE: u32 = 0o711;
const ROOT_SEALED_EXECUTABLE_MODE: u32 = 0o555;
const ROOT_SEALED_RECORD_MODE: u32 = 0o444;
const ROOT_UPDATE_ROOT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-updates-v2";
const ROOT_ACTIVE_POINTER: &str =
    "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v2";
const ROOT_ACTIVE_POINTER_PENDING: &str =
    "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v2.pending";
const ROOT_UPDATE_LOCK: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-update-v2.lock";
const ROOT_PROBE_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-probes-v2";
const RESUME_DISPATCH_INTENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-v2-resume-dispatch-intent";
const RESUME_DISPATCH_INTENT_PENDING: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-v2-resume-dispatch-intent.pending";
const RESUME_DISPATCH_INTENT_HEADER: &str =
    "OPENSTEAMER_DIAGNOSTIC_DRIVER_V2_RESUME_DISPATCH_INTENT_V1";
const RESUME_DISPATCH_INTENT_SIZE: usize = 261;
const RESUME_DISPATCH_INTENT_SHA256: &str =
    "0bea593bb494b132204a898129ba62e3cc0ba12998fbcb1ed9e2b29671c8d9d2";
const ORIGINAL_V2_ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v2-update";
const ORIGINAL_V2_ROOT_SEALED_RECOVERY_MODE: &str =
    "--root-sealed-rollback-diagnostic-driver-v2-update";

fn resume_dispatch_intent_text() -> String {
    format!(
        "{RESUME_DISPATCH_INTENT_HEADER}\nnonce={RETAINED_V2_NONCE}\ncontroller_sha256={RETAINED_V2_ORIGINAL_CONTROLLER_SHA256}\nrequest_sha256={RETAINED_V2_REQUEST_SHA256}\n"
    )
}

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
const FRESH_HOST_PID: u32 = 98_080;
const FRESH_HOST_RUNS: u64 = 1;
const FRESH_HOST_START: &str = "Sat Aug 22 19:23:17 2026";
const FRESH_HOST_NONCE: &str = "f704872a3d2a08dd242fb9ab65323e367d0094baf8b03528988c3959ee29488f";
const FRESH_HOST_LOCK_INODE: u64 = 10_835_208;
const FRESH_HOST_LOCK_SIZE: u64 = 122;
const FRESH_COREAUDIO_PID: u32 = 2_621;
const FRESH_COREAUDIO_RUNS: u64 = 5;
const FRESH_COREAUDIO_START: &str = "Sat Aug 22 11:03:06 2026";
const FRESH_INPUT_UID: &str = "BlackHole2ch_UID";
const FRESH_OUTPUT_UID: &str = "BuiltInSpeakerDevice";
const LSOF_SHA256: &str = "28c36d6b6dfcce1f544717b0d1961aa03441ee0a736fee3e1eaeb215c0fbff4c";
const LSOF_SIZE: u64 = 307_600;
const LSOF_FLAGS: u32 = 524_320;

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
const PAIRING_METADATA_STDOUT_SIZE: usize = 742;
const PAIRING_METADATA_SHA256: [&str; 2] = [
    "fbd7bd69d3ee3e7a91416427a44365cde6199ccee62eaf4f619f9d12ee7aa9d6",
    "751ae04bb168ae92472b0b3d31066d371b95c34fe62a7df374e3449f5a7be7a5",
];

const PRODUCT_DRIVER: &str = "/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver";
const DRIVER_EXECUTABLE_RELATIVE: &str = "Contents/MacOS/OpensteamerVirtualMicrophone";
const INSTALLED_DRIVER_TREE_SHA256: &str =
    "f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49";
const INSTALLED_DRIVER_EXECUTABLE_SHA256: &str =
    "ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866";
const INSTALLED_DRIVER_DEVICE: u64 = 16_777_229;
const INSTALLED_DRIVER_INODE: u64 = 27_877_539;
const CANDIDATE_DRIVER_TREE_SHA256: &str =
    "84bfc68a9bf808936e60c80dbd8a02f601f54fe248c3f1f8de0b095142401dba";
const CANDIDATE_DRIVER_EXECUTABLE_SHA256: &str =
    "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d";

fn main() -> ExitCode {
    match real_main() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("opensteamer diagnostic-driver resume stager: {error}");
            ExitCode::from(1)
        }
    }
}

fn real_main() -> Result<()> {
    let arguments = env::args().collect::<Vec<_>>();
    match arguments.as_slice() {
        [_, mode] if mode == RESUME_SELF_TEST_MODE => self_test(),
        [_, mode, repo, original_controller] if mode == RESUME_PREFLIGHT_MODE => {
            let _sealed_stager = require_sealed_uid501_stager_identity()?;
            let guards = acquire_retained_attempt_guards()?;
            verify_resume_preflight(
                Path::new(repo),
                Path::new(original_controller),
                &guards,
            )?;
            println!(
                "DIAGNOSTIC_DRIVER_V2_RESUME_PREFLIGHT_OK nonce={RETAINED_V2_NONCE}"
            );
            Ok(())
        }
        [_, mode, repo, commit, tree, original_controller] if mode == RESUME_EXECUTE_MODE => {
            let _sealed_stager = require_sealed_uid501_stager_identity()?;
            execute_authorized_resume(
                Path::new(repo),
                commit,
                tree,
                Path::new(original_controller),
            )
        }
        _ => Err(StagerError(format!(
            "usage: resume-stager {RESUME_PREFLIGHT_MODE} {EXPECTED_REPO} <original-controller> | {RESUME_EXECUTE_MODE} {EXPECTED_REPO} <commit> <tree> <original-controller> | {RESUME_SELF_TEST_MODE}"
        ))),
    }
}

fn path_text(path: &Path) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| StagerError(format!("path is not UTF-8: {}", path.display())))
}

fn require_lower_hex(value: &str, length: usize, label: &str) -> Result<()> {
    if value.len() != length
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(StagerError(format!("{label} is not exact lower hex")));
    }
    Ok(())
}

fn read_pipe_bounded(mut pipe: impl Read, maximum: usize) -> std::io::Result<(Vec<u8>, bool)> {
    let mut bytes = Vec::new();
    Read::by_ref(&mut pipe)
        .take(maximum.saturating_add(1) as u64)
        .read_to_end(&mut bytes)?;
    let exceeded = bytes.len() > maximum;
    if exceeded {
        bytes.truncate(maximum);
    }
    Ok((bytes, exceeded))
}

fn bounded_output(program: &str, arguments: &[&str], timeout: Duration) -> Result<Output> {
    let mut child = Command::new(program)
        .args(arguments)
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| StagerError("child stdout is unavailable".to_owned()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| StagerError("child stderr is unavailable".to_owned()))?;
    let stdout_reader = thread::spawn(move || read_pipe_bounded(stdout, MAX_OUTPUT_BYTES));
    let stderr_reader = thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES));
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| StagerError("child deadline overflowed".to_owned()))?;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(StagerError(format!("bounded child timed out: {program}")));
        }
        thread::sleep(Duration::from_millis(20));
    };
    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| StagerError("stdout reader panicked".to_owned()))??;
    let (stderr, stderr_exceeded) = stderr_reader
        .join()
        .map_err(|_| StagerError("stderr reader panicked".to_owned()))??;
    if stdout_exceeded || stderr_exceeded {
        return Err(StagerError(format!(
            "bounded child output exceeded limit: {program}"
        )));
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn require_success(output: &Output, label: &str) -> Result<()> {
    if !output.status.success() {
        return Err(StagerError(format!(
            "{label} failed with {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim_end()
        )));
    }
    Ok(())
}

fn command_line(program: &str, arguments: &[&str], label: &str) -> Result<String> {
    let output = bounded_output(program, arguments, COMMAND_TIMEOUT)?;
    require_success(&output, label)?;
    if !output.stderr.is_empty() {
        return Err(StagerError(format!("{label} wrote stderr")));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError(format!("{label} output is not UTF-8")))?;
    let line = text
        .strip_suffix('\n')
        .ok_or_else(|| StagerError(format!("{label} has no exact newline")))?;
    if line.contains('\n') || line.is_empty() {
        return Err(StagerError(format!("{label} is not one exact line")));
    }
    Ok(line.to_owned())
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
        .ok_or_else(|| StagerError("shasum stdin is unavailable".to_owned()))?
        .write_all(bytes)?;
    let output = child.wait_with_output()?;
    require_success(&output, "hash bounded bytes")?;
    if !output.stderr.is_empty() {
        return Err(StagerError("shasum wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("shasum output is not UTF-8".to_owned()))?;
    let digest = text
        .split_ascii_whitespace()
        .next()
        .ok_or_else(|| StagerError("shasum output is empty".to_owned()))?;
    require_lower_hex(digest, 64, "SHA-256")?;
    Ok(digest.to_owned())
}

fn sha256(path: &Path) -> Result<String> {
    let output = bounded_output(
        "/usr/bin/shasum",
        &["-a", "256", path_text(path)?],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "hash file")?;
    if !output.stderr.is_empty() {
        return Err(StagerError("file shasum wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("file shasum output is not UTF-8".to_owned()))?;
    let digest = text
        .split_ascii_whitespace()
        .next()
        .ok_or_else(|| StagerError("file shasum output is empty".to_owned()))?;
    require_lower_hex(digest, 64, "file SHA-256")?;
    Ok(digest.to_owned())
}

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

fn openat_component_walk_with_final_flags(
    path: &Path,
    final_flags: i32,
) -> Result<(File, Vec<OpenatIdentity>)> {
    if !path.is_absolute() {
        return Err(StagerError("openat path is not absolute".to_owned()));
    }
    let components = path.components().collect::<Vec<_>>();
    if components.len() < 2
        || components[0] != Component::RootDir
        || components[1..]
            .iter()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(StagerError(
            "openat path has a non-canonical component".to_owned(),
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
        let name = CString::new(name.as_bytes())
            .map_err(|_| StagerError("openat component contains NUL".to_owned()))?;
        let final_component = index + 2 == components.len();
        let flags = (if final_component {
            final_flags
        } else {
            O_RDONLY | O_DIRECTORY
        }) | O_NOFOLLOW
            | O_CLOEXEC;
        let descriptor = unsafe { openat(directory.as_raw_fd(), name.as_ptr(), flags, 0) };
        if descriptor < 0 {
            return Err(StagerError(format!(
                "openat component refused: {}",
                std::io::Error::last_os_error()
            )));
        }
        let opened = unsafe { File::from_raw_fd(descriptor) };
        let metadata = opened.metadata()?;
        opened_path.push(OsStr::from_bytes(name.to_bytes()));
        let canonical_applications = !final_component
            && opened_path == Path::new("/Applications")
            && metadata.file_type().is_dir()
            && metadata.uid() == ROOT_ID
            && metadata.gid() == LEGACY_EXECUTABLE_GROUP
            && metadata.permissions().mode() & 0o7777 == 0o775
            && metadata.dev() == APPLICATIONS_DEVICE
            && metadata.ino() == APPLICATIONS_INODE
            && metadata.nlink() == APPLICATIONS_NLINK
            && metadata.st_flags() == APPLICATIONS_FLAGS;
        if canonical_applications {
            require_descriptor_no_acl_or_xattrs(&opened, "canonical /Applications")?;
        }
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
            return Err(StagerError("openat ancestry metadata is unsafe".to_owned()));
        }
        identities.push(identity_from_metadata(&metadata));
        directory = opened;
    }
    Ok((directory, identities))
}

fn openat_child(parent: &File, name: &[u8], flags: i32) -> Result<File> {
    let name =
        CString::new(name).map_err(|_| StagerError("openat child contains NUL".to_owned()))?;
    let descriptor = unsafe {
        openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | O_NOFOLLOW | O_CLOEXEC,
            0,
        )
    };
    if descriptor < 0 {
        return Err(StagerError(format!(
            "openat child refused: {}",
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
                    return Err(StagerError(format!(
                        "readdir failed: {}",
                        std::io::Error::from_raw_os_error(code)
                    )));
                }
                break;
            }
            let entry = unsafe { &*entry };
            let length = usize::from(entry.name_length);
            if length == 0
                || length >= entry.name.len()
                || entry.name[length] != 0
                || usize::from(entry.record_length) < 22_usize.saturating_add(length)
            {
                return Err(StagerError("directory entry is malformed".to_owned()));
            }
            let name = entry.name[..length]
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
                return Err(StagerError("directory name is unsafe".to_owned()));
            }
            names.push(name);
            if names.len() > 128 {
                return Err(StagerError("directory exceeds its node bound".to_owned()));
            }
        }
        names.sort();
        if names.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(StagerError("directory contains duplicate names".to_owned()));
        }
        Ok(names)
    })();
    let close = unsafe { closedir(stream) };
    if close != 0 && result.is_ok() {
        return Err(std::io::Error::last_os_error().into());
    }
    result
}

fn descriptor_xattrs(file: &File) -> Result<Vec<(String, u64, String)>> {
    let count = unsafe { flistxattr(file.as_raw_fd(), std::ptr::null_mut(), 0, 0) };
    if count < 0 || count as usize > 64 * 1_024 {
        return Err(StagerError(
            "descriptor xattr-name list is unavailable or oversized".to_owned(),
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
            return Err(StagerError("descriptor xattr list changed".to_owned()));
        }
    }
    let mut result = Vec::new();
    for raw_name in names
        .split(|byte| *byte == 0)
        .filter(|name| !name.is_empty())
    {
        let name = std::str::from_utf8(raw_name)
            .map_err(|_| StagerError("xattr name is not UTF-8".to_owned()))?;
        let c_name = CString::new(raw_name)
            .map_err(|_| StagerError("xattr name contains NUL".to_owned()))?;
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
            return Err(StagerError(
                "xattr value is unavailable or oversized".to_owned(),
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
                return Err(StagerError("xattr value changed".to_owned()));
            }
        }
        result.push((name.to_owned(), size as u64, sha256_bytes(&value)?));
    }
    result.sort();
    Ok(result)
}

fn descriptor_has_acl_or_xattrs(file: &File) -> Result<bool> {
    if !descriptor_xattrs(file)?.is_empty() {
        return Ok(true);
    }
    unsafe { *__error() = 0 };
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) };
    let error = unsafe { *__error() };
    if acl.is_null() {
        if error == ENOENT {
            return Ok(false);
        }
        return Err(StagerError(format!(
            "descriptor ACL absence is unproven: {}",
            std::io::Error::from_raw_os_error(error)
        )));
    }
    let mut entry = std::ptr::null_mut();
    let _ = unsafe { acl_get_entry(acl, ACL_FIRST_ENTRY, &mut entry) };
    if unsafe { acl_free(acl) } != 0 {
        return Err(StagerError("descriptor ACL release failed".to_owned()));
    }
    Ok(true)
}

fn require_descriptor_no_acl_or_xattrs(file: &File, label: &str) -> Result<()> {
    if descriptor_has_acl_or_xattrs(file)? {
        return Err(StagerError(format!(
            "descriptor ACL/xattrs are forbidden for {label}"
        )));
    }
    Ok(())
}

fn require_exact_child_names_fd(directory: &File, expected: &[&[u8]], label: &str) -> Result<()> {
    let mut expected = expected
        .iter()
        .map(|name| name.to_vec())
        .collect::<Vec<_>>();
    expected.sort();
    if list_directory_fd(directory)? != expected {
        return Err(StagerError(format!("unexpected child set: {label}")));
    }
    Ok(())
}

fn require_empty_directory_fd(directory: &File, label: &str) -> Result<()> {
    require_exact_child_names_fd(directory, &[], label)
}

fn read_retained_descriptor(file: &File, maximum: u64, label: &str) -> Result<Vec<u8>> {
    let before = file.metadata()?;
    if before.len() > maximum {
        return Err(StagerError(format!(
            "retained descriptor is oversized: {label}"
        )));
    }
    let mut reader = file.try_clone()?;
    reader.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::with_capacity(before.len() as usize);
    Read::by_ref(&mut reader)
        .take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    require_descriptor_no_acl_or_xattrs(file, label)?;
    if bytes.len() as u64 != before.len()
        || identity_from_metadata(&before) != identity_from_metadata(&after)
    {
        return Err(StagerError(format!(
            "retained descriptor changed during read: {label}"
        )));
    }
    Ok(bytes)
}

fn require_retained_support_descriptor(file: &File, label: &str) -> Result<OpenatIdentity> {
    let metadata = file.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if !metadata.file_type().is_dir()
        || identity.device != RETAINED_DEVICE
        || identity.inode != RETAINED_V1_USER_SUPPORT_INODE
        || identity.uid != USER_ID
        || identity.gid != USER_GROUP
        || identity.mode != 0o700
        || identity.flags != 0
    {
        return Err(StagerError(format!("retained support changed: {label}")));
    }
    require_descriptor_no_acl_or_xattrs(file, label)?;
    Ok(identity)
}

#[allow(clippy::too_many_arguments)]
fn retained_descriptor_identity_matches(
    identity: &OpenatIdentity,
    actual_is_directory: bool,
    actual_is_symlink: bool,
    expected_is_directory: bool,
    inode: u64,
    links: u64,
    length: u64,
    mode: u32,
) -> bool {
    actual_is_directory == expected_is_directory
        && !actual_is_symlink
        && identity.device == RETAINED_DEVICE
        && identity.inode == inode
        && identity.uid == USER_ID
        && identity.gid == USER_GROUP
        && identity.mode == mode
        && identity.links == links
        && identity.length == length
        && identity.flags == 0
}

#[allow(clippy::too_many_arguments)]
fn require_retained_descriptor(
    file: &File,
    is_directory: bool,
    inode: u64,
    links: u64,
    length: u64,
    mode: u32,
    label: &str,
) -> Result<OpenatIdentity> {
    let metadata = file.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if !retained_descriptor_identity_matches(
        &identity,
        metadata.file_type().is_dir(),
        metadata.file_type().is_symlink(),
        is_directory,
        inode,
        links,
        length,
        mode,
    ) {
        return Err(StagerError(format!("retained descriptor changed: {label}")));
    }
    require_descriptor_no_acl_or_xattrs(file, label)?;
    Ok(identity)
}

fn require_retained_descriptor_children(
    directory: &File,
    expected: &[&[u8]],
    label: &str,
) -> Result<()> {
    require_exact_child_names_fd(directory, expected, label)
}

struct RetainedV1DescriptorGraph {
    support: File,
    support_ancestry: Vec<OpenatIdentity>,
    update_root: File,
    evidence: File,
    probes: File,
    pointer: File,
    journal: File,
    request: File,
    reader: File,
    named_lock: File,
}

fn open_retained_v1_descriptor_graph() -> Result<RetainedV1DescriptorGraph> {
    let (support, support_ancestry) =
        openat_component_walk_with_final_flags(Path::new(USER_SUPPORT), O_RDONLY | O_DIRECTORY)?;
    let update_root = openat_child(
        &support,
        b"diagnostic-driver-updates-v1",
        O_RDONLY | O_DIRECTORY,
    )?;
    let evidence = openat_child(
        &update_root,
        RETAINED_V1_EVIDENCE_LEAF.as_bytes(),
        O_RDONLY | O_DIRECTORY,
    )?;
    let probes = openat_child(&evidence, b"probes", O_RDONLY | O_DIRECTORY)?;
    let pointer = openat_child(&support, b"active-diagnostic-driver-update-v1", O_RDONLY)?;
    let journal = openat_child(&evidence, b"journal.log", O_RDONLY)?;
    let request = openat_child(&evidence, b"root-request.txt", O_RDONLY)?;
    let reader = openat_child(
        &evidence,
        b"opensteamer-diagnostic-snapshot-reader",
        O_RDONLY,
    )?;
    let named_lock = openat_child(&support, b"diagnostic-driver-update-v1.lock", O_RDONLY)?;
    Ok(RetainedV1DescriptorGraph {
        support,
        support_ancestry,
        update_root,
        evidence,
        probes,
        pointer,
        journal,
        request,
        reader,
        named_lock,
    })
}

fn retained_v1_descriptor_graph_identities(
    graph: &RetainedV1DescriptorGraph,
    held_lock: &File,
) -> Result<Vec<OpenatIdentity>> {
    let support = require_retained_support_descriptor(&graph.support, "retained V1 support")?;
    let update_root = require_retained_descriptor(
        &graph.update_root,
        true,
        RETAINED_V1_USER_UPDATE_ROOT_INODE,
        3,
        96,
        0o700,
        "retained V1 update root",
    )?;
    let evidence = require_retained_descriptor(
        &graph.evidence,
        true,
        RETAINED_V1_EVIDENCE_INODE,
        6,
        192,
        0o700,
        "retained V1 evidence",
    )?;
    let probes = require_retained_descriptor(
        &graph.probes,
        true,
        RETAINED_V1_PROBES_INODE,
        2,
        64,
        0o700,
        "retained V1 probes",
    )?;
    let pointer = require_retained_descriptor(
        &graph.pointer,
        false,
        RETAINED_V1_USER_ACTIVE_POINTER_INODE,
        1,
        format!("{RETAINED_V1_EVIDENCE}\n").len() as u64,
        0o600,
        "retained V1 pointer",
    )?;
    let journal = require_retained_descriptor(
        &graph.journal,
        false,
        RETAINED_V1_JOURNAL_INODE,
        1,
        RETAINED_V1_JOURNAL_TEXT.len() as u64,
        0o600,
        "retained V1 journal",
    )?;
    let request = require_retained_descriptor(
        &graph.request,
        false,
        RETAINED_V1_REQUEST_INODE,
        1,
        RETAINED_V1_REQUEST_TEXT.len() as u64,
        0o400,
        "retained V1 request",
    )?;
    let reader = require_retained_descriptor(
        &graph.reader,
        false,
        RETAINED_V1_READER_INODE,
        1,
        DIAGNOSTIC_READER_SIZE,
        0o755,
        "retained V1 reader",
    )?;
    let named_lock = require_retained_descriptor(
        &graph.named_lock,
        false,
        RETAINED_V1_USER_UPDATE_LOCK_INODE,
        1,
        0,
        0o600,
        "retained V1 named lock",
    )?;
    let held = require_retained_descriptor(
        held_lock,
        false,
        RETAINED_V1_USER_UPDATE_LOCK_INODE,
        1,
        0,
        0o600,
        "retained V1 held lock",
    )?;
    if named_lock != held {
        return Err(StagerError(
            "retained V1 held/named lock identity differs".to_owned(),
        ));
    }
    Ok(vec![
        support,
        update_root,
        evidence,
        probes,
        pointer,
        journal,
        request,
        reader,
        named_lock,
    ])
}

fn verify_retained_v1_descriptor_graph_payload(graph: &RetainedV1DescriptorGraph) -> Result<()> {
    require_retained_descriptor_children(
        &graph.update_root,
        &[RETAINED_V1_EVIDENCE_LEAF.as_bytes()],
        "retained V1 update root",
    )?;
    require_retained_descriptor_children(
        &graph.evidence,
        &[
            b"journal.log",
            b"opensteamer-diagnostic-snapshot-reader",
            b"probes",
            b"root-request.txt",
        ],
        "retained V1 evidence",
    )?;
    require_empty_directory_fd(&graph.probes, "retained V1 probes")?;
    let pointer = read_retained_descriptor(&graph.pointer, 1_024, "retained V1 pointer")?;
    let journal = read_retained_descriptor(&graph.journal, 1_024, "retained V1 journal")?;
    let request = read_retained_descriptor(&graph.request, 4_096, "retained V1 request")?;
    let reader =
        read_retained_descriptor(&graph.reader, DIAGNOSTIC_READER_SIZE, "retained V1 reader")?;
    if pointer != format!("{RETAINED_V1_EVIDENCE}\n").as_bytes()
        || sha256_bytes(&pointer)? != RETAINED_V1_USER_ACTIVE_POINTER_SHA256
        || journal != RETAINED_V1_JOURNAL_TEXT.as_bytes()
        || sha256_bytes(&journal)? != RETAINED_V1_JOURNAL_SHA256
        || request != RETAINED_V1_REQUEST_TEXT.as_bytes()
        || sha256_bytes(&request)? != RETAINED_V1_REQUEST_SHA256
        || sha256_bytes(&reader)? != DIAGNOSTIC_READER_SHA256
    {
        return Err(StagerError("retained V1 payload changed".to_owned()));
    }
    Ok(())
}

fn verify_retained_v1_descriptor_graph(
    graph: &RetainedV1DescriptorGraph,
    held_lock: &File,
) -> Result<Vec<OpenatIdentity>> {
    let first = retained_v1_descriptor_graph_identities(graph, held_lock)?;
    verify_retained_v1_descriptor_graph_payload(graph)?;
    let second = retained_v1_descriptor_graph_identities(graph, held_lock)?;
    verify_retained_v1_descriptor_graph_payload(graph)?;
    let third = retained_v1_descriptor_graph_identities(graph, held_lock)?;
    if first != second || second != third {
        return Err(StagerError(
            "retained V1 descriptor graph changed during proof".to_owned(),
        ));
    }
    Ok(first)
}

struct RetainedV2DescriptorGraph {
    support: File,
    support_ancestry: Vec<OpenatIdentity>,
    update_root: File,
    evidence: File,
    probes: File,
    pointer: File,
    journal: File,
    request: File,
    reader: File,
    named_lock: File,
}

fn open_retained_v2_descriptor_graph() -> Result<RetainedV2DescriptorGraph> {
    let (support, support_ancestry) =
        openat_component_walk_with_final_flags(Path::new(USER_SUPPORT), O_RDONLY | O_DIRECTORY)?;
    let update_root = openat_child(
        &support,
        b"diagnostic-driver-updates-v2",
        O_RDONLY | O_DIRECTORY,
    )?;
    let evidence = openat_child(
        &update_root,
        RETAINED_V2_EVIDENCE_LEAF.as_bytes(),
        O_RDONLY | O_DIRECTORY,
    )?;
    let probes = openat_child(&evidence, b"probes", O_RDONLY | O_DIRECTORY)?;
    let pointer = openat_child(&support, b"active-diagnostic-driver-update-v2", O_RDONLY)?;
    let journal = openat_child(&evidence, b"journal.log", O_RDONLY)?;
    let request = openat_child(&evidence, b"root-request.txt", O_RDONLY)?;
    let reader = openat_child(
        &evidence,
        b"opensteamer-diagnostic-snapshot-reader",
        O_RDONLY,
    )?;
    let named_lock = openat_child(&support, b"diagnostic-driver-update-v2.lock", O_RDONLY)?;
    Ok(RetainedV2DescriptorGraph {
        support,
        support_ancestry,
        update_root,
        evidence,
        probes,
        pointer,
        journal,
        request,
        reader,
        named_lock,
    })
}

fn retained_v2_descriptor_graph_identities(
    graph: &RetainedV2DescriptorGraph,
    held_lock: &File,
) -> Result<Vec<OpenatIdentity>> {
    let support = require_retained_support_descriptor(&graph.support, "retained V2 support")?;
    let update_root = require_retained_descriptor(
        &graph.update_root,
        true,
        RETAINED_V2_USER_UPDATE_ROOT_INODE,
        3,
        96,
        0o700,
        "retained V2 update root",
    )?;
    let evidence = require_retained_descriptor(
        &graph.evidence,
        true,
        RETAINED_V2_EVIDENCE_INODE,
        6,
        192,
        0o700,
        "retained V2 evidence",
    )?;
    let probes = require_retained_descriptor(
        &graph.probes,
        true,
        RETAINED_V2_PROBES_INODE,
        2,
        64,
        0o700,
        "retained V2 probes",
    )?;
    let pointer = require_retained_descriptor(
        &graph.pointer,
        false,
        RETAINED_V2_USER_ACTIVE_POINTER_INODE,
        1,
        format!("{RETAINED_V2_EVIDENCE}\n").len() as u64,
        0o600,
        "retained V2 pointer",
    )?;
    let journal = require_retained_descriptor(
        &graph.journal,
        false,
        RETAINED_V2_JOURNAL_INODE,
        1,
        RETAINED_V2_JOURNAL_TEXT.len() as u64,
        0o600,
        "retained V2 journal",
    )?;
    let request = require_retained_descriptor(
        &graph.request,
        false,
        RETAINED_V2_REQUEST_INODE,
        1,
        RETAINED_V2_REQUEST_TEXT.len() as u64,
        0o400,
        "retained V2 request",
    )?;
    let reader = require_retained_descriptor(
        &graph.reader,
        false,
        RETAINED_V2_READER_INODE,
        1,
        DIAGNOSTIC_READER_SIZE,
        0o755,
        "retained V2 reader",
    )?;
    let named_lock = require_retained_descriptor(
        &graph.named_lock,
        false,
        RETAINED_V2_USER_UPDATE_LOCK_INODE,
        1,
        0,
        0o600,
        "retained V2 named lock",
    )?;
    let held = require_retained_descriptor(
        held_lock,
        false,
        RETAINED_V2_USER_UPDATE_LOCK_INODE,
        1,
        0,
        0o600,
        "retained V2 held lock",
    )?;
    if named_lock != held {
        return Err(StagerError(
            "retained V2 held/named lock identity differs".to_owned(),
        ));
    }
    Ok(vec![
        support,
        update_root,
        evidence,
        probes,
        pointer,
        journal,
        request,
        reader,
        named_lock,
    ])
}

fn verify_retained_v2_descriptor_graph_payload(graph: &RetainedV2DescriptorGraph) -> Result<()> {
    require_retained_descriptor_children(
        &graph.update_root,
        &[RETAINED_V2_EVIDENCE_LEAF.as_bytes()],
        "retained V2 update root",
    )?;
    require_retained_descriptor_children(
        &graph.evidence,
        &[
            b"journal.log",
            b"opensteamer-diagnostic-snapshot-reader",
            b"probes",
            b"root-request.txt",
        ],
        "retained V2 evidence",
    )?;
    require_empty_directory_fd(&graph.probes, "retained V2 probes")?;
    let pointer = read_retained_descriptor(&graph.pointer, 1_024, "retained V2 pointer")?;
    let journal = read_retained_descriptor(&graph.journal, 1_024, "retained V2 journal")?;
    let request = read_retained_descriptor(&graph.request, 4_096, "retained V2 request")?;
    let reader =
        read_retained_descriptor(&graph.reader, DIAGNOSTIC_READER_SIZE, "retained V2 reader")?;
    if pointer != format!("{RETAINED_V2_EVIDENCE}\n").as_bytes()
        || sha256_bytes(&pointer)? != RETAINED_V2_USER_ACTIVE_POINTER_SHA256
        || journal != RETAINED_V2_JOURNAL_TEXT.as_bytes()
        || sha256_bytes(&journal)? != RETAINED_V2_JOURNAL_SHA256
        || request != RETAINED_V2_REQUEST_TEXT.as_bytes()
        || sha256_bytes(&request)? != RETAINED_V2_REQUEST_SHA256
        || sha256_bytes(&reader)? != DIAGNOSTIC_READER_SHA256
    {
        return Err(StagerError("retained V2 payload changed".to_owned()));
    }
    Ok(())
}

fn verify_retained_v2_descriptor_graph(
    graph: &RetainedV2DescriptorGraph,
    held_lock: &File,
) -> Result<Vec<OpenatIdentity>> {
    let first = retained_v2_descriptor_graph_identities(graph, held_lock)?;
    verify_retained_v2_descriptor_graph_payload(graph)?;
    let second = retained_v2_descriptor_graph_identities(graph, held_lock)?;
    verify_retained_v2_descriptor_graph_payload(graph)?;
    let third = retained_v2_descriptor_graph_identities(graph, held_lock)?;
    if first != second || second != third {
        return Err(StagerError(
            "retained V2 descriptor graph changed during proof".to_owned(),
        ));
    }
    Ok(first)
}

struct RetainedAttemptGuards {
    v1_lock: File,
    v2_lock: File,
}

fn acquire_exact_retained_lock(path: &Path, inode: u64, label: &str) -> Result<File> {
    let (file, ancestry_before) = openat_component_walk_with_final_flags(path, O_RDWR)?;
    let opened = require_retained_descriptor(&file, false, inode, 1, 0, 0o600, label)?;
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(StagerError(format!(
            "{label} is already held or unavailable: {}",
            std::io::Error::last_os_error()
        )));
    }
    let (named, ancestry_after) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    let named = require_retained_descriptor(&named, false, inode, 1, 0, 0o600, label)?;
    if opened != named || ancestry_before != ancestry_after {
        return Err(StagerError(format!(
            "{label} held/named descriptor or ancestry changed"
        )));
    }
    Ok(file)
}

fn acquire_retained_v1_lock() -> Result<File> {
    acquire_exact_retained_lock(
        Path::new(
            "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-update-v1.lock",
        ),
        RETAINED_V1_USER_UPDATE_LOCK_INODE,
        "retained V1 update lock",
    )
}

fn acquire_retained_v2_lock() -> Result<File> {
    acquire_exact_retained_lock(
        Path::new(
            "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-update-v2.lock",
        ),
        RETAINED_V2_USER_UPDATE_LOCK_INODE,
        "retained V2 update lock",
    )
}

fn acquire_retained_attempt_guards() -> Result<RetainedAttemptGuards> {
    let v1_lock = acquire_retained_v1_lock()?;
    let v2_lock = acquire_retained_v2_lock()?;
    Ok(RetainedAttemptGuards { v1_lock, v2_lock })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RetainedGraphProof {
    ancestry: Vec<OpenatIdentity>,
    identities: Vec<OpenatIdentity>,
}

fn prove_retained_graphs(
    guards: &RetainedAttemptGuards,
) -> Result<(RetainedGraphProof, RetainedGraphProof)> {
    let first_v1 = open_retained_v1_descriptor_graph()?;
    let first_v1_proof = RetainedGraphProof {
        ancestry: first_v1.support_ancestry.clone(),
        identities: verify_retained_v1_descriptor_graph(&first_v1, &guards.v1_lock)?,
    };
    let second_v1 = open_retained_v1_descriptor_graph()?;
    let second_v1_proof = RetainedGraphProof {
        ancestry: second_v1.support_ancestry.clone(),
        identities: verify_retained_v1_descriptor_graph(&second_v1, &guards.v1_lock)?,
    };
    if first_v1_proof != second_v1_proof {
        return Err(StagerError("retained V1 graph reopen changed".to_owned()));
    }
    let first_v2 = open_retained_v2_descriptor_graph()?;
    let first_v2_proof = RetainedGraphProof {
        ancestry: first_v2.support_ancestry.clone(),
        identities: verify_retained_v2_descriptor_graph(&first_v2, &guards.v2_lock)?,
    };
    let second_v2 = open_retained_v2_descriptor_graph()?;
    let second_v2_proof = RetainedGraphProof {
        ancestry: second_v2.support_ancestry.clone(),
        identities: verify_retained_v2_descriptor_graph(&second_v2, &guards.v2_lock)?,
    };
    if first_v2_proof != second_v2_proof {
        return Err(StagerError("retained V2 graph reopen changed".to_owned()));
    }
    Ok((first_v1_proof, first_v2_proof))
}

const RETAINED_V1_ROOT_UPDATE_ROOT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-updates-v1";
const RETAINED_V1_ROOT_ACTIVE_POINTER: &str =
    "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1";
const RETAINED_V1_ROOT_ACTIVE_POINTER_PENDING: &str =
    "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1.pending";
const RETAINED_V1_ROOT_UPDATE_LOCK: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-update-v1.lock";
const RETAINED_V1_ROOT_CONTROLLER_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1";
const RETAINED_V1_ROOT_PROBE_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-probes-v1";

const TRANSACTION_CONTROLLER_PENDING: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/.controller.pending";
const TRANSACTION_PIN_PENDING: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/.controller.sha256.pending";
const TRANSACTION_IDENTITY_PENDING: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/.controller-identity.txt.pending";
const TRANSACTION_BOOTSTRAP_PENDING: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/.bootstrap-request.txt.pending";
const BOOTSTRAP_ABORT_RESULT: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/controller-ea5a600cf397995156907bc1609b68d6/bootstrap-abort-result.txt";
const RECOVERY_CONTROLLER_PENDING: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/.recovery-controller.pending";
const RECOVERY_PIN_PENDING: &str = "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v2/.recovery-controller.sha256.pending";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootArtifact {
    TransactionController,
    TransactionPin,
    TransactionIdentity,
    TransactionBootstrap,
    RecoveryController,
    RecoveryPin,
    DispatchIntent,
}

impl RootArtifact {
    fn final_path(self) -> &'static str {
        match self {
            Self::TransactionController => RETAINED_V2_ROOT_CONTROLLER,
            Self::TransactionPin => RETAINED_V2_ROOT_CONTROLLER_PIN,
            Self::TransactionIdentity => RETAINED_V2_ROOT_CONTROLLER_IDENTITY,
            Self::TransactionBootstrap => RETAINED_V2_ROOT_BOOTSTRAP_REQUEST,
            Self::RecoveryController => ROOT_RECOVERY_CONTROLLER,
            Self::RecoveryPin => ROOT_RECOVERY_CONTROLLER_PIN,
            Self::DispatchIntent => RESUME_DISPATCH_INTENT,
        }
    }

    fn pending_path(self) -> &'static str {
        match self {
            Self::TransactionController => TRANSACTION_CONTROLLER_PENDING,
            Self::TransactionPin => TRANSACTION_PIN_PENDING,
            Self::TransactionIdentity => TRANSACTION_IDENTITY_PENDING,
            Self::TransactionBootstrap => TRANSACTION_BOOTSTRAP_PENDING,
            Self::RecoveryController => RECOVERY_CONTROLLER_PENDING,
            Self::RecoveryPin => RECOVERY_PIN_PENDING,
            Self::DispatchIntent => RESUME_DISPATCH_INTENT_PENDING,
        }
    }

    fn staging_mode(self) -> &'static str {
        match self {
            Self::TransactionController | Self::RecoveryController => "0500",
            _ => "0400",
        }
    }

    fn published_mode(self) -> u32 {
        match self {
            Self::TransactionController | Self::RecoveryController => ROOT_SEALED_EXECUTABLE_MODE,
            _ => ROOT_SEALED_RECORD_MODE,
        }
    }

    fn published_mode_text(self) -> &'static str {
        match self {
            Self::TransactionController | Self::RecoveryController => "0555",
            _ => "0444",
        }
    }
}

fn controller_identity_text() -> String {
    format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_CONTROLLER_IDENTITY_V2\ncontroller={RETAINED_V2_ROOT_CONTROLLER}\nsha256={RETAINED_V2_ORIGINAL_CONTROLLER_SHA256}\n"
    )
}

fn artifact_bytes(artifact: RootArtifact, controller_bytes: &[u8]) -> Vec<u8> {
    match artifact {
        RootArtifact::TransactionController | RootArtifact::RecoveryController => {
            controller_bytes.to_vec()
        }
        RootArtifact::TransactionPin | RootArtifact::RecoveryPin => {
            format!("{RETAINED_V2_ORIGINAL_CONTROLLER_SHA256}\n").into_bytes()
        }
        RootArtifact::TransactionIdentity => controller_identity_text().into_bytes(),
        RootArtifact::TransactionBootstrap => RETAINED_V2_REQUEST_TEXT.as_bytes().to_vec(),
        RootArtifact::DispatchIntent => resume_dispatch_intent_text().into_bytes(),
    }
}

#[derive(Clone, Copy)]
enum RootPath {
    V1Locator,
    V1UpdateRoot,
    V1Pointer,
    V1PendingPointer,
    V1Lock,
    V1ControllerParent,
    V1ProbeParent,
    V2Locator,
    V2ControllerParent,
    V2ControllerSupport,
    V2UpdateRoot,
    V2Pointer,
    V2PendingPointer,
    V2Lock,
    V2ProbeParent,
    BootstrapAbortResult,
    ArtifactFinal(RootArtifact),
    ArtifactPending(RootArtifact),
}

impl RootPath {
    fn text(self) -> &'static str {
        match self {
            Self::V1Locator => RETAINED_V1_ROOT_BOOTSTRAP_LOCATOR,
            Self::V1UpdateRoot => RETAINED_V1_ROOT_UPDATE_ROOT,
            Self::V1Pointer => RETAINED_V1_ROOT_ACTIVE_POINTER,
            Self::V1PendingPointer => RETAINED_V1_ROOT_ACTIVE_POINTER_PENDING,
            Self::V1Lock => RETAINED_V1_ROOT_UPDATE_LOCK,
            Self::V1ControllerParent => RETAINED_V1_ROOT_CONTROLLER_PARENT,
            Self::V1ProbeParent => RETAINED_V1_ROOT_PROBE_PARENT,
            Self::V2Locator => ROOT_BOOTSTRAP_LOCATOR,
            Self::V2ControllerParent => ROOT_CONTROLLER_PARENT,
            Self::V2ControllerSupport => RETAINED_V2_ROOT_CONTROLLER_SUPPORT,
            Self::V2UpdateRoot => ROOT_UPDATE_ROOT,
            Self::V2Pointer => ROOT_ACTIVE_POINTER,
            Self::V2PendingPointer => ROOT_ACTIVE_POINTER_PENDING,
            Self::V2Lock => ROOT_UPDATE_LOCK,
            Self::V2ProbeParent => ROOT_PROBE_PARENT,
            Self::BootstrapAbortResult => BOOTSTRAP_ABORT_RESULT,
            Self::ArtifactFinal(artifact) => artifact.final_path(),
            Self::ArtifactPending(artifact) => artifact.pending_path(),
        }
    }
}

enum SudoAction {
    Stat(RootPath),
    List(RootPath),
    Acl(RootPath),
    Xattr(RootPath),
    Cat(RootPath),
    CreateSupportDirectory,
    CreatePending(RootArtifact),
    StreamPending(RootArtifact),
    SealPending(RootArtifact),
    PublishPending(RootArtifact),
    Sync,
    DispatchOriginal,
    RecoverSealed,
}

struct SudoInvocation {
    arguments: Vec<&'static str>,
    accepts_stdin: bool,
    timeout: Duration,
}

fn sudo_invocation(action: SudoAction) -> SudoInvocation {
    let (arguments, accepts_stdin, timeout) = match action {
        SudoAction::Stat(path) => (
            vec![
                "/usr/bin/stat",
                "-f",
                "%d|%i|%u|%g|%p|%l|%z|%f",
                path.text(),
            ],
            false,
            COMMAND_TIMEOUT,
        ),
        SudoAction::List(path) => (vec!["/bin/ls", "-1A", path.text()], false, COMMAND_TIMEOUT),
        SudoAction::Acl(path) => (
            vec!["/bin/ls", "-lde@", path.text()],
            false,
            COMMAND_TIMEOUT,
        ),
        SudoAction::Xattr(path) => (vec!["/usr/bin/xattr", path.text()], false, COMMAND_TIMEOUT),
        SudoAction::Cat(path) => (vec!["/bin/cat", path.text()], false, COMMAND_TIMEOUT),
        SudoAction::CreateSupportDirectory => (
            vec![
                "/usr/bin/install",
                "-d",
                "-o",
                "root",
                "-g",
                "wheel",
                "-m",
                "0711",
                RETAINED_V2_ROOT_CONTROLLER_SUPPORT,
            ],
            false,
            COMMAND_TIMEOUT,
        ),
        SudoAction::CreatePending(artifact) => (
            vec![
                "/usr/bin/install",
                "-o",
                "root",
                "-g",
                "wheel",
                "-m",
                artifact.staging_mode(),
                "/dev/null",
                artifact.pending_path(),
            ],
            false,
            COMMAND_TIMEOUT,
        ),
        SudoAction::StreamPending(artifact) => (
            vec!["/usr/bin/tee", artifact.pending_path()],
            true,
            COMMAND_TIMEOUT,
        ),
        SudoAction::SealPending(artifact) => (
            vec![
                "/bin/chmod",
                artifact.published_mode_text(),
                artifact.pending_path(),
            ],
            false,
            COMMAND_TIMEOUT,
        ),
        SudoAction::PublishPending(artifact) => (
            vec![
                "/bin/mv",
                "-n",
                artifact.pending_path(),
                artifact.final_path(),
            ],
            false,
            COMMAND_TIMEOUT,
        ),
        SudoAction::Sync => (vec!["/bin/sync"], false, COMMAND_TIMEOUT),
        SudoAction::DispatchOriginal => (
            vec![
                RETAINED_V2_ROOT_CONTROLLER,
                ORIGINAL_V2_ROOT_MODE,
                RETAINED_V2_ROOT_BOOTSTRAP_REQUEST,
            ],
            false,
            ROOT_TRANSACTION_TIMEOUT,
        ),
        SudoAction::RecoverSealed => (
            vec![
                ROOT_RECOVERY_CONTROLLER,
                ORIGINAL_V2_ROOT_SEALED_RECOVERY_MODE,
            ],
            false,
            ROOT_TRANSACTION_TIMEOUT,
        ),
    };
    SudoInvocation {
        arguments,
        accepts_stdin,
        timeout,
    }
}

fn run_sudo_constant_argv(action: SudoAction, input: Option<&[u8]>) -> Result<Output> {
    let invocation = sudo_invocation(action);
    if invocation.accepts_stdin != input.is_some() {
        return Err(StagerError(
            "typed sudo action/input contract is inconsistent".to_owned(),
        ));
    }
    if invocation.arguments.iter().any(|value| {
        value.is_empty() || *value == "/bin/sh" || *value == "-c" || value.contains('\0')
    }) {
        return Err(StagerError(
            "typed sudo action escaped the closed argv allowlist".to_owned(),
        ));
    }
    let mut child = Command::new("/usr/bin/sudo")
        .arg("-n")
        .arg("--")
        .args(&invocation.arguments)
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| StagerError("typed sudo stdout is unavailable".to_owned()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| StagerError("typed sudo stderr is unavailable".to_owned()))?;
    let stdout_reader = thread::spawn(move || read_pipe_bounded(stdout, MAX_OUTPUT_BYTES));
    let stderr_reader = thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES));
    let stdin_writer = if let Some(bytes) = input {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| StagerError("typed sudo stdin is unavailable".to_owned()))?;
        let bytes = bytes.to_vec();
        Some(thread::spawn(move || stdin.write_all(&bytes)))
    } else {
        None
    };
    let deadline = Instant::now()
        .checked_add(invocation.timeout)
        .ok_or_else(|| StagerError("typed sudo deadline overflowed".to_owned()))?;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            // The sudo process can have a still-running privileged descendant.
            // Do not block on inherited pipe readers here; the caller proves
            // transaction quiescence before any sealed recovery dispatch.
            drop(stdin_writer);
            drop(stdout_reader);
            drop(stderr_reader);
            return Err(StagerError(
                "typed sudo action exceeded deadline".to_owned(),
            ));
        }
        thread::sleep(Duration::from_millis(20));
    };
    if let Some(writer) = stdin_writer {
        writer
            .join()
            .map_err(|_| StagerError("typed sudo stdin writer panicked".to_owned()))??;
    }
    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| StagerError("typed sudo stdout reader panicked".to_owned()))??;
    let (stderr, stderr_exceeded) = stderr_reader
        .join()
        .map_err(|_| StagerError("typed sudo stderr reader panicked".to_owned()))??;
    if stdout_exceeded || stderr_exceeded {
        return Err(StagerError(
            "typed sudo output exceeded its bound".to_owned(),
        ));
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootFileType {
    Regular,
    Directory,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RootIdentity {
    device: u64,
    inode: u64,
    uid: u32,
    gid: u32,
    mode: u32,
    links: u64,
    length: u64,
    flags: u32,
    file_type: RootFileType,
}

fn parse_root_identity(text: &str) -> Result<RootIdentity> {
    let line = text
        .strip_suffix('\n')
        .ok_or_else(|| StagerError("root stat output lacks exact newline".to_owned()))?;
    if line.contains('\n') {
        return Err(StagerError("root stat output has extra records".to_owned()));
    }
    let fields = line.split('|').collect::<Vec<_>>();
    if fields.len() != 8 {
        return Err(StagerError("root stat output is malformed".to_owned()));
    }
    let decimal = |value: &str, label: &str| -> Result<u64> {
        let parsed = value
            .parse::<u64>()
            .map_err(|_| StagerError(format!("root stat {label} is malformed")))?;
        if parsed.to_string() != value {
            return Err(StagerError(format!("root stat {label} is noncanonical")));
        }
        Ok(parsed)
    };
    let raw_mode = u32::from_str_radix(fields[4], 8)
        .map_err(|_| StagerError("root stat mode is malformed".to_owned()))?;
    let file_type = match raw_mode & 0o170000 {
        0o100000 => RootFileType::Regular,
        0o040000 => RootFileType::Directory,
        _ => return Err(StagerError("root stat file type is forbidden".to_owned())),
    };
    Ok(RootIdentity {
        device: decimal(fields[0], "device")?,
        inode: decimal(fields[1], "inode")?,
        uid: decimal(fields[2], "uid")? as u32,
        gid: decimal(fields[3], "gid")? as u32,
        mode: raw_mode & 0o7777,
        links: decimal(fields[5], "links")?,
        length: decimal(fields[6], "length")?,
        flags: decimal(fields[7], "flags")? as u32,
        file_type,
    })
}

fn sudo_root_directory_identity(path: RootPath) -> Result<RootIdentity> {
    let output = run_sudo_constant_argv(SudoAction::Stat(path), None)?;
    require_success(&output, "inspect privileged root identity")?;
    if !output.stderr.is_empty() {
        return Err(StagerError("root stat wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("root stat output is not UTF-8".to_owned()))?;
    parse_root_identity(&text)
}

fn sudo_root_exists(path: RootPath) -> Result<bool> {
    let output = run_sudo_constant_argv(SudoAction::Stat(path), None)?;
    if output.status.success() {
        if output.stderr.is_empty() {
            let text = String::from_utf8(output.stdout)
                .map_err(|_| StagerError("root stat output is not UTF-8".to_owned()))?;
            let _ = parse_root_identity(&text)?;
            return Ok(true);
        }
    } else if output.stdout.is_empty()
        && String::from_utf8_lossy(&output.stderr).contains("No such file or directory")
    {
        return Ok(false);
    }
    Err(StagerError(
        "privileged root existence proof was operationally ambiguous".to_owned(),
    ))
}

fn sudo_root_require_absent(path: RootPath, label: &str) -> Result<()> {
    if sudo_root_exists(path)? {
        return Err(StagerError(format!("{label} unexpectedly exists")));
    }
    Ok(())
}

fn sudo_root_exact_child_names(path: RootPath) -> Result<Vec<String>> {
    let output = run_sudo_constant_argv(SudoAction::List(path), None)?;
    require_success(&output, "enumerate privileged root directory")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "root directory listing wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("root directory listing is not UTF-8".to_owned()))?;
    if !text.is_empty() && !text.ends_with('\n') {
        return Err(StagerError(
            "root directory listing lacks exact termination".to_owned(),
        ));
    }
    let mut names = text.lines().map(str::to_owned).collect::<Vec<_>>();
    if names.iter().any(|name| {
        name.is_empty() || name.as_bytes().contains(&b'/') || name.as_bytes().contains(&0)
    }) {
        return Err(StagerError("root directory child is unsafe".to_owned()));
    }
    names.sort();
    if names.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(StagerError(
            "root directory listing contains duplicates".to_owned(),
        ));
    }
    Ok(names)
}

fn sudo_root_require_no_acl_or_xattrs(path: RootPath) -> Result<()> {
    let listing = run_sudo_constant_argv(SudoAction::Acl(path), None)?;
    require_success(&listing, "inspect privileged root ACL")?;
    if !listing.stderr.is_empty() {
        return Err(StagerError("root ACL probe wrote stderr".to_owned()));
    }
    let text = String::from_utf8(listing.stdout)
        .map_err(|_| StagerError("root ACL output is not UTF-8".to_owned()))?;
    let lines = text.lines().collect::<Vec<_>>();
    let mode = lines
        .first()
        .and_then(|line| line.split_ascii_whitespace().next())
        .ok_or_else(|| StagerError("root ACL output is empty".to_owned()))?;
    if lines.len() != 1 || mode.ends_with('+') || mode.ends_with('@') {
        return Err(StagerError(
            "root artifact has a POSIX ACL or xattr marker".to_owned(),
        ));
    }
    let xattrs = run_sudo_constant_argv(SudoAction::Xattr(path), None)?;
    require_success(&xattrs, "inspect privileged root xattrs")?;
    if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
        return Err(StagerError(
            "root artifact has extended attributes".to_owned(),
        ));
    }
    Ok(())
}

fn sudo_root_bytes(path: RootPath, maximum: usize) -> Result<Vec<u8>> {
    let before = sudo_root_directory_identity(path)?;
    if before.length > maximum as u64 {
        return Err(StagerError(
            "root artifact exceeds its read bound".to_owned(),
        ));
    }
    let output = run_sudo_constant_argv(SudoAction::Cat(path), None)?;
    require_success(&output, "read privileged root artifact")?;
    if !output.stderr.is_empty() || output.stdout.len() as u64 != before.length {
        return Err(StagerError(
            "root artifact read differs from its stat".to_owned(),
        ));
    }
    let after = sudo_root_directory_identity(path)?;
    if before != after {
        return Err(StagerError("root artifact changed during read".to_owned()));
    }
    Ok(output.stdout)
}

fn exact_root_file_metadata_matches(
    identity: &RootIdentity,
    mode: u32,
    length: u64,
    pinned_inode: Option<u64>,
    has_acl_or_xattrs: bool,
) -> bool {
    identity.device == RETAINED_DEVICE
        && identity.file_type == RootFileType::Regular
        && identity.uid == ROOT_ID
        && identity.gid == ROOT_GROUP
        && identity.mode == mode
        && identity.links == 1
        && identity.length == length
        && identity.flags == 0
        && pinned_inode.is_none_or(|inode| identity.inode == inode)
        && !has_acl_or_xattrs
}

fn exact_root_bytes_match(actual: &[u8], expected: &[u8]) -> bool {
    actual == expected
}

fn pending_root_bytes_match(actual: &[u8], expected: &[u8]) -> bool {
    expected.starts_with(actual)
}

fn verify_root_file_identity(
    path: RootPath,
    mode: u32,
    length: u64,
    expected_bytes: &[u8],
    expected_digest: &str,
    pinned_inode: Option<u64>,
) -> Result<RootIdentity> {
    let before = sudo_root_directory_identity(path)?;
    if !exact_root_file_metadata_matches(&before, mode, length, pinned_inode, false) {
        return Err(StagerError("root file metadata changed".to_owned()));
    }
    sudo_root_require_no_acl_or_xattrs(path)?;
    let bytes = sudo_root_bytes(path, MAX_OUTPUT_BYTES)?;
    if !exact_root_bytes_match(&bytes, expected_bytes) || sha256_bytes(&bytes)? != expected_digest {
        return Err(StagerError("root file bytes changed".to_owned()));
    }
    let after = sudo_root_directory_identity(path)?;
    if before != after {
        return Err(StagerError(
            "root file identity changed during proof".to_owned(),
        ));
    }
    Ok(before)
}

fn verify_existing_exact_root_file(
    artifact: RootArtifact,
    expected: &[u8],
) -> Result<RootIdentity> {
    verify_root_file_identity(
        RootPath::ArtifactFinal(artifact),
        artifact.published_mode(),
        expected.len() as u64,
        expected,
        &sha256_bytes(expected)?,
        None,
    )
}

fn verify_exact_or_partial_pending_root_file(
    artifact: RootArtifact,
    expected: &[u8],
) -> Result<RootIdentity> {
    let path = RootPath::ArtifactPending(artifact);
    let before = sudo_root_directory_identity(path)?;
    if before.device != RETAINED_DEVICE
        || before.file_type != RootFileType::Regular
        || before.uid != ROOT_ID
        || before.gid != ROOT_GROUP
        || !matches!(before.mode, 0o400 | 0o444 | 0o500 | 0o555)
        || before.links != 1
        || before.length > expected.len() as u64
        || before.flags != 0
    {
        return Err(StagerError(
            "root pending artifact metadata is not an allowed prefix".to_owned(),
        ));
    }
    sudo_root_require_no_acl_or_xattrs(path)?;
    let bytes = sudo_root_bytes(path, MAX_OUTPUT_BYTES)?;
    if !pending_root_bytes_match(&bytes, expected) {
        return Err(StagerError(
            "root pending artifact is not an exact byte prefix".to_owned(),
        ));
    }
    let after = sudo_root_directory_identity(path)?;
    if before != after {
        return Err(StagerError(
            "root pending artifact changed during proof".to_owned(),
        ));
    }
    Ok(before)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ResumeStagePrefix {
    LocatorAndEmptyControllerParent,
    TransactionSupportDirectory,
    TransactionController,
    TransactionControllerPin,
    TransactionControllerIdentity,
    TransactionBootstrapRequest,
    FixedRecoveryController,
    Complete,
    Partial(RootArtifact),
}

fn root_artifact_leaf(artifact: RootArtifact, pending: bool) -> String {
    Path::new(if pending {
        artifact.pending_path()
    } else {
        artifact.final_path()
    })
    .file_name()
    .expect("root artifact constants have a leaf")
    .to_string_lossy()
    .into_owned()
}

fn classify_stage_child_observation(
    parent_children: &[String],
    support_children: &[String],
) -> Result<ResumeStagePrefix> {
    let unique_parent = parent_children.iter().collect::<BTreeSet<_>>();
    let unique_support = support_children.iter().collect::<BTreeSet<_>>();
    if unique_parent.len() != parent_children.len()
        || unique_support.len() != support_children.len()
    {
        return Err(StagerError(
            "root stage child observation is duplicated".to_owned(),
        ));
    }
    let support_name = format!("controller-{RETAINED_V2_NONCE}");
    let allowed_parent = BTreeSet::from([
        support_name.clone(),
        "recovery-controller".to_owned(),
        "recovery-controller.sha256".to_owned(),
        ".recovery-controller.pending".to_owned(),
        ".recovery-controller.sha256.pending".to_owned(),
    ]);
    if parent_children
        .iter()
        .any(|name| !allowed_parent.contains(name))
    {
        return Err(StagerError(
            "unexpected child in root controller parent".to_owned(),
        ));
    }
    if !parent_children.contains(&support_name) {
        if parent_children.is_empty() && support_children.is_empty() {
            return Ok(ResumeStagePrefix::LocatorAndEmptyControllerParent);
        }
        return Err(StagerError(
            "fixed recovery artifacts appeared before transaction support".to_owned(),
        ));
    }
    let transaction_artifacts = [
        RootArtifact::TransactionController,
        RootArtifact::TransactionPin,
        RootArtifact::TransactionIdentity,
        RootArtifact::TransactionBootstrap,
    ];
    let allowed_support = transaction_artifacts
        .iter()
        .flat_map(|artifact| {
            [
                root_artifact_leaf(*artifact, false),
                root_artifact_leaf(*artifact, true),
            ]
        })
        .chain(["bootstrap-abort-result.txt".to_owned()])
        .collect::<BTreeSet<_>>();
    if support_children
        .iter()
        .any(|name| !allowed_support.contains(name))
    {
        return Err(StagerError(
            "unexpected child in transaction controller support".to_owned(),
        ));
    }
    let has_abort = support_children
        .iter()
        .any(|name| name == "bootstrap-abort-result.txt");
    for (index, artifact) in transaction_artifacts.iter().enumerate() {
        let final_exists = support_children.contains(&root_artifact_leaf(*artifact, false));
        let pending_exists = support_children.contains(&root_artifact_leaf(*artifact, true));
        if final_exists && pending_exists {
            return Err(StagerError(
                "canonical and pending transaction artifacts coexist".to_owned(),
            ));
        }
        if final_exists {
            continue;
        }
        if pending_exists {
            if has_abort || support_children.len() != index + 1 || parent_children.len() != 1 {
                return Err(StagerError(
                    "transaction pending artifact is not an exact prefix".to_owned(),
                ));
            }
            return Ok(ResumeStagePrefix::Partial(*artifact));
        }
        if has_abort || support_children.len() != index || parent_children.len() != 1 {
            return Err(StagerError(
                "transaction controller files are not an exact prefix".to_owned(),
            ));
        }
        return Ok(match index {
            0 => ResumeStagePrefix::TransactionSupportDirectory,
            1 => ResumeStagePrefix::TransactionController,
            2 => ResumeStagePrefix::TransactionControllerPin,
            3 => ResumeStagePrefix::TransactionControllerIdentity,
            _ => unreachable!(),
        });
    }
    if support_children.len() != transaction_artifacts.len() + usize::from(has_abort) {
        return Err(StagerError(
            "transaction support contains an extra child".to_owned(),
        ));
    }
    let recovery_artifacts = [RootArtifact::RecoveryController, RootArtifact::RecoveryPin];
    for (index, artifact) in recovery_artifacts.iter().enumerate() {
        let final_exists = parent_children.contains(&root_artifact_leaf(*artifact, false));
        let pending_exists = parent_children.contains(&root_artifact_leaf(*artifact, true));
        if final_exists && pending_exists {
            return Err(StagerError(
                "canonical and pending recovery artifacts coexist".to_owned(),
            ));
        }
        if final_exists {
            continue;
        }
        if pending_exists {
            if has_abort || parent_children.len() != index + 2 {
                return Err(StagerError(
                    "fixed recovery pending artifact is not an exact prefix".to_owned(),
                ));
            }
            return Ok(ResumeStagePrefix::Partial(*artifact));
        }
        if has_abort || parent_children.len() != index + 1 {
            return Err(StagerError(
                "fixed recovery files are not an exact prefix".to_owned(),
            ));
        }
        return Ok(if index == 0 {
            ResumeStagePrefix::TransactionBootstrapRequest
        } else {
            ResumeStagePrefix::FixedRecoveryController
        });
    }
    if parent_children.len() != 3 {
        return Err(StagerError(
            "complete root stage has unexpected children".to_owned(),
        ));
    }
    Ok(ResumeStagePrefix::Complete)
}

fn parent_child_names_for_prefix() -> Result<Vec<String>> {
    sudo_root_exact_child_names(RootPath::V2ControllerParent)
}

fn classify_resume_stage_prefix(controller_bytes: &[u8]) -> Result<ResumeStagePrefix> {
    let parent_children = parent_child_names_for_prefix()?;
    let support_name = format!("controller-{RETAINED_V2_NONCE}");
    let allowed_parent = BTreeSet::from([
        support_name.clone(),
        "recovery-controller".to_owned(),
        "recovery-controller.sha256".to_owned(),
        ".recovery-controller.pending".to_owned(),
        ".recovery-controller.sha256.pending".to_owned(),
    ]);
    if parent_children
        .iter()
        .any(|name| !allowed_parent.contains(name))
    {
        return Err(StagerError(
            "unexpected child in root controller parent".to_owned(),
        ));
    }
    if !parent_children.contains(&support_name) {
        return classify_stage_child_observation(&parent_children, &[]);
    }
    let support_identity = sudo_root_directory_identity(RootPath::V2ControllerSupport)?;
    if support_identity.device != RETAINED_DEVICE
        || support_identity.file_type != RootFileType::Directory
        || support_identity.uid != ROOT_ID
        || support_identity.gid != ROOT_GROUP
        || support_identity.mode != ROOT_SEALED_TRAVERSE_MODE
        || support_identity.links != 2
        || support_identity.flags != 0
    {
        return Err(StagerError(
            "transaction controller support metadata changed".to_owned(),
        ));
    }
    sudo_root_require_no_acl_or_xattrs(RootPath::V2ControllerSupport)?;
    let support_children = sudo_root_exact_child_names(RootPath::V2ControllerSupport)?;
    let _observed_prefix = classify_stage_child_observation(&parent_children, &support_children)?;
    if support_identity.length != 64 + 32 * support_children.len() as u64 {
        return Err(StagerError(
            "transaction support size differs from its exact child prefix".to_owned(),
        ));
    }
    let transaction_artifacts = [
        RootArtifact::TransactionController,
        RootArtifact::TransactionPin,
        RootArtifact::TransactionIdentity,
        RootArtifact::TransactionBootstrap,
    ];
    let allowed_support = transaction_artifacts
        .iter()
        .flat_map(|artifact| {
            [
                Path::new(artifact.final_path())
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
                Path::new(artifact.pending_path())
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
            ]
        })
        .chain(["bootstrap-abort-result.txt".to_owned()])
        .collect::<BTreeSet<_>>();
    if support_children
        .iter()
        .any(|name| !allowed_support.contains(name))
    {
        return Err(StagerError(
            "unexpected child in transaction controller support".to_owned(),
        ));
    }
    let mut completed = 0_usize;
    let has_bootstrap_abort = support_children
        .iter()
        .any(|name| name == "bootstrap-abort-result.txt");
    for artifact in transaction_artifacts {
        let final_name = Path::new(artifact.final_path())
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let pending_name = Path::new(artifact.pending_path())
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let expected = artifact_bytes(artifact, controller_bytes);
        let final_exists = support_children.contains(&final_name);
        let pending_exists = support_children.contains(&pending_name);
        if final_exists && pending_exists {
            return Err(StagerError(
                "canonical and pending transaction artifacts coexist".to_owned(),
            ));
        }
        if final_exists {
            verify_existing_exact_root_file(artifact, &expected)?;
            completed += 1;
        } else if pending_exists {
            verify_exact_or_partial_pending_root_file(artifact, &expected)?;
            if completed
                != transaction_artifacts
                    .iter()
                    .position(|candidate| *candidate == artifact)
                    .unwrap()
            {
                return Err(StagerError(
                    "transaction pending artifact is out of sequence".to_owned(),
                ));
            }
            return Ok(ResumeStagePrefix::Partial(artifact));
        } else {
            let expected_completed = transaction_artifacts
                .iter()
                .position(|candidate| *candidate == artifact)
                .unwrap();
            if has_bootstrap_abort
                || completed != expected_completed
                || support_children.len() != completed
                || parent_children.len() != 1
            {
                return Err(StagerError(
                    "transaction controller files are not an exact prefix".to_owned(),
                ));
            }
            return Ok(match completed {
                0 => ResumeStagePrefix::TransactionSupportDirectory,
                1 => ResumeStagePrefix::TransactionController,
                2 => ResumeStagePrefix::TransactionControllerPin,
                3 => ResumeStagePrefix::TransactionControllerIdentity,
                _ => unreachable!(),
            });
        }
    }
    if support_children.len() != transaction_artifacts.len() + usize::from(has_bootstrap_abort) {
        return Err(StagerError(
            "transaction support contains an extra child".to_owned(),
        ));
    }
    let recovery_artifacts = [RootArtifact::RecoveryController, RootArtifact::RecoveryPin];
    if has_bootstrap_abort
        && (!parent_children
            .iter()
            .any(|name| name == "recovery-controller")
            || !parent_children
                .iter()
                .any(|name| name == "recovery-controller.sha256"))
    {
        return Err(StagerError(
            "bootstrap-abort result appeared before the fixed recovery pair".to_owned(),
        ));
    }
    let mut recovery_completed = 0_usize;
    for artifact in recovery_artifacts {
        let final_name = Path::new(artifact.final_path())
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let pending_name = Path::new(artifact.pending_path())
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let expected = artifact_bytes(artifact, controller_bytes);
        let final_exists = parent_children.contains(&final_name);
        let pending_exists = parent_children.contains(&pending_name);
        if final_exists && pending_exists {
            return Err(StagerError(
                "canonical and pending recovery artifacts coexist".to_owned(),
            ));
        }
        if final_exists {
            verify_existing_exact_root_file(artifact, &expected)?;
            recovery_completed += 1;
        } else if pending_exists {
            verify_exact_or_partial_pending_root_file(artifact, &expected)?;
            return Ok(ResumeStagePrefix::Partial(artifact));
        } else {
            let expected_parent_count = 1 + recovery_completed;
            if parent_children.len() != expected_parent_count {
                return Err(StagerError(
                    "fixed recovery files are not an exact prefix".to_owned(),
                ));
            }
            return Ok(if recovery_completed == 0 {
                ResumeStagePrefix::TransactionBootstrapRequest
            } else {
                ResumeStagePrefix::FixedRecoveryController
            });
        }
    }
    if parent_children.len() != 3 {
        return Err(StagerError(
            "complete root stage has unexpected children".to_owned(),
        ));
    }
    if has_bootstrap_abort {
        let _ = verify_bootstrap_abort_result()?;
    }
    Ok(ResumeStagePrefix::Complete)
}

fn parse_bootstrap_abort_result(text: &str) -> Result<u32> {
    if !text.ends_with('\n') {
        return Err(StagerError(
            "bootstrap-abort result lacks exact newline".to_owned(),
        ));
    }
    let mut lines = text.lines();
    if lines.next() != Some("OPENSTEAMER_DIAGNOSTIC_DRIVER_BOOTSTRAP_ABORT_V2")
        || lines.next() != Some(&format!("nonce={RETAINED_V2_NONCE}"))
    {
        return Err(StagerError(
            "bootstrap-abort result header/nonce changed".to_owned(),
        ));
    }
    let pid = lines
        .next()
        .and_then(|line| line.strip_prefix("host_pid="))
        .ok_or_else(|| StagerError("bootstrap-abort host PID is absent".to_owned()))?;
    let pid = parse_positive_u32(pid, "bootstrap-abort host PID")?;
    if lines.next() != Some("outcome=prestop-aborted") || lines.next().is_some() {
        return Err(StagerError(
            "bootstrap-abort result outcome changed".to_owned(),
        ));
    }
    Ok(pid)
}

fn verify_bootstrap_abort_result() -> Result<u32> {
    let path = RootPath::BootstrapAbortResult;
    let before = sudo_root_directory_identity(path)?;
    if before.file_type != RootFileType::Regular
        || before.device != RETAINED_DEVICE
        || before.uid != ROOT_ID
        || before.gid != ROOT_GROUP
        || before.mode != 0o400
        || before.links != 1
        || before.flags != 0
        || before.length == 0
        || before.length > 512
    {
        return Err(StagerError(
            "bootstrap-abort result metadata changed".to_owned(),
        ));
    }
    sudo_root_require_no_acl_or_xattrs(path)?;
    let bytes = sudo_root_bytes(path, 512)?;
    let text = String::from_utf8(bytes)
        .map_err(|_| StagerError("bootstrap-abort result is not UTF-8".to_owned()))?;
    let pid = parse_bootstrap_abort_result(&text)?;
    if sudo_root_directory_identity(path)? != before {
        return Err(StagerError(
            "bootstrap-abort result changed during proof".to_owned(),
        ));
    }
    Ok(pid)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RootStageProof {
    locator: RootIdentity,
    controller_parent: RootIdentity,
    prefix: ResumeStagePrefix,
}

fn verify_retained_v1_root_attestation() -> Result<()> {
    let _locator = verify_root_file_identity(
        RootPath::V1Locator,
        0o400,
        RETAINED_V1_REQUEST_TEXT.len() as u64,
        RETAINED_V1_REQUEST_TEXT.as_bytes(),
        RETAINED_V1_REQUEST_SHA256,
        Some(RETAINED_V1_ROOT_BOOTSTRAP_LOCATOR_INODE),
    )?;
    for (path, label) in [
        (RootPath::V1UpdateRoot, "retained V1 root update root"),
        (RootPath::V1Pointer, "retained V1 root pointer"),
        (
            RootPath::V1PendingPointer,
            "retained V1 root pending pointer",
        ),
        (RootPath::V1Lock, "retained V1 root lock"),
        (
            RootPath::V1ControllerParent,
            "retained V1 root controller parent",
        ),
        (RootPath::V1ProbeParent, "retained V1 root probe parent"),
    ] {
        sudo_root_require_absent(path, label)?;
    }
    Ok(())
}

fn verify_privileged_partial_root_stage(controller_bytes: &[u8]) -> Result<RootStageProof> {
    verify_retained_v1_root_attestation()?;
    let locator_before = verify_root_file_identity(
        RootPath::V2Locator,
        ROOT_SEALED_RECORD_MODE,
        RETAINED_V2_REQUEST_TEXT.len() as u64,
        RETAINED_V2_REQUEST_TEXT.as_bytes(),
        RETAINED_V2_REQUEST_SHA256,
        Some(RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE),
    )?;
    let parent_before = sudo_root_directory_identity(RootPath::V2ControllerParent)?;
    if parent_before.device != RETAINED_DEVICE
        || parent_before.file_type != RootFileType::Directory
        || parent_before.inode != RETAINED_V2_ROOT_CONTROLLER_PARENT_INODE
        || parent_before.uid != ROOT_ID
        || parent_before.gid != ROOT_GROUP
        || parent_before.mode != ROOT_SEALED_TRAVERSE_MODE
        || parent_before.flags != 0
    {
        return Err(StagerError(
            "pinned root controller parent metadata changed".to_owned(),
        ));
    }
    sudo_root_require_no_acl_or_xattrs(RootPath::V2ControllerParent)?;
    let prefix = classify_resume_stage_prefix(controller_bytes)?;
    let parent_children = sudo_root_exact_child_names(RootPath::V2ControllerParent)?;
    let expected_parent_links = if parent_children
        .iter()
        .any(|name| name == &format!("controller-{RETAINED_V2_NONCE}"))
    {
        3
    } else {
        2
    };
    if parent_before.links != expected_parent_links
        || parent_before.length != 64 + 32 * parent_children.len() as u64
        || (prefix == ResumeStagePrefix::LocatorAndEmptyControllerParent
            && (parent_before.links != 2 || parent_before.length != 64))
    {
        return Err(StagerError(
            "root controller-parent nlink/size differs from exact prefix".to_owned(),
        ));
    }
    let locator_after = verify_root_file_identity(
        RootPath::V2Locator,
        ROOT_SEALED_RECORD_MODE,
        RETAINED_V2_REQUEST_TEXT.len() as u64,
        RETAINED_V2_REQUEST_TEXT.as_bytes(),
        RETAINED_V2_REQUEST_SHA256,
        Some(RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE),
    )?;
    let parent_after = sudo_root_directory_identity(RootPath::V2ControllerParent)?;
    if locator_before != locator_after || parent_before != parent_after {
        return Err(StagerError(
            "root locator/controller parent changed during privileged proof".to_owned(),
        ));
    }
    Ok(RootStageProof {
        locator: locator_before,
        controller_parent: parent_before,
        prefix,
    })
}

fn sudo_install_root_directory_create_once() -> Result<()> {
    if !sudo_root_exists(RootPath::V2ControllerSupport)? {
        let output = run_sudo_constant_argv(SudoAction::CreateSupportDirectory, None)?;
        require_success(&output, "create exact root controller support")?;
        if !output.stdout.is_empty() || !output.stderr.is_empty() {
            return Err(StagerError(
                "root support creation wrote unexpected output".to_owned(),
            ));
        }
        let sync = run_sudo_constant_argv(SudoAction::Sync, None)?;
        require_success(&sync, "durably sync root support creation")?;
    }
    let identity = sudo_root_directory_identity(RootPath::V2ControllerSupport)?;
    if identity.device != RETAINED_DEVICE
        || identity.file_type != RootFileType::Directory
        || identity.uid != ROOT_ID
        || identity.gid != ROOT_GROUP
        || identity.mode != ROOT_SEALED_TRAVERSE_MODE
        || identity.links != 2
        || identity.flags != 0
    {
        return Err(StagerError(
            "created root controller support is unsafe".to_owned(),
        ));
    }
    sudo_root_require_no_acl_or_xattrs(RootPath::V2ControllerSupport)
}

fn sudo_stream_root_file_create_once(artifact: RootArtifact, expected: &[u8]) -> Result<()> {
    if sudo_root_exists(RootPath::ArtifactFinal(artifact))? {
        sudo_root_require_absent(
            RootPath::ArtifactPending(artifact),
            "pending root artifact beside canonical",
        )?;
        let _ = verify_existing_exact_root_file(artifact, expected)?;
        return Ok(());
    }
    if !sudo_root_exists(RootPath::ArtifactPending(artifact))? {
        let create = run_sudo_constant_argv(SudoAction::CreatePending(artifact), None)?;
        require_success(&create, "create root-owned pending artifact")?;
        if !create.stdout.is_empty() || !create.stderr.is_empty() {
            return Err(StagerError(
                "root pending creation wrote unexpected output".to_owned(),
            ));
        }
    }
    let _ = verify_exact_or_partial_pending_root_file(artifact, expected)?;
    let stream = run_sudo_constant_argv(SudoAction::StreamPending(artifact), Some(expected))?;
    require_success(&stream, "stream exact root pending artifact")?;
    if stream.stdout != expected || !stream.stderr.is_empty() {
        return Err(StagerError(
            "root pending stream echo differs from exact bytes".to_owned(),
        ));
    }
    let sync = run_sudo_constant_argv(SudoAction::Sync, None)?;
    require_success(&sync, "sync root pending artifact")?;
    let seal = run_sudo_constant_argv(SudoAction::SealPending(artifact), None)?;
    require_success(&seal, "seal root pending artifact")?;
    if !seal.stdout.is_empty() || !seal.stderr.is_empty() {
        return Err(StagerError(
            "root pending seal wrote unexpected output".to_owned(),
        ));
    }
    let pending = verify_exact_or_partial_pending_root_file(artifact, expected)?;
    if pending.mode != artifact.published_mode()
        || pending.length != expected.len() as u64
        || sha256_bytes(&sudo_root_bytes(
            RootPath::ArtifactPending(artifact),
            MAX_OUTPUT_BYTES,
        )?)? != sha256_bytes(expected)?
    {
        return Err(StagerError(
            "sealed root pending artifact is not complete".to_owned(),
        ));
    }
    let sync = run_sudo_constant_argv(SudoAction::Sync, None)?;
    require_success(&sync, "sync sealed root pending artifact")?;
    let publish = run_sudo_constant_argv(SudoAction::PublishPending(artifact), None)?;
    require_success(&publish, "exclusive-publish root artifact")?;
    if !publish.stdout.is_empty() || !publish.stderr.is_empty() {
        return Err(StagerError(
            "root artifact publication wrote unexpected output".to_owned(),
        ));
    }
    let sync = run_sudo_constant_argv(SudoAction::Sync, None)?;
    require_success(&sync, "sync published root artifact")?;
    sudo_root_require_absent(
        RootPath::ArtifactPending(artifact),
        "published root pending artifact",
    )?;
    let _ = verify_existing_exact_root_file(artifact, expected)?;
    Ok(())
}

fn verify_transaction_support_complete(controller_bytes: &[u8]) -> Result<()> {
    for artifact in [
        RootArtifact::TransactionController,
        RootArtifact::TransactionPin,
        RootArtifact::TransactionIdentity,
        RootArtifact::TransactionBootstrap,
    ] {
        let expected = artifact_bytes(artifact, controller_bytes);
        let _ = verify_existing_exact_root_file(artifact, &expected)?;
        sudo_root_require_absent(
            RootPath::ArtifactPending(artifact),
            "transaction support pending artifact",
        )?;
    }
    Ok(())
}

fn verify_resume_stage_complete(controller_bytes: &[u8]) -> Result<RootStageProof> {
    let proof = verify_privileged_partial_root_stage(controller_bytes)?;
    if proof.prefix != ResumeStagePrefix::Complete {
        return Err(StagerError("root resume stage is not complete".to_owned()));
    }
    Ok(proof)
}

fn stage_original_v2_root_controller(controller_bytes: &[u8]) -> Result<RootStageProof> {
    if controller_bytes.len() as u64 != RETAINED_V2_ORIGINAL_CONTROLLER_SIZE
        || sha256_bytes(controller_bytes)? != RETAINED_V2_ORIGINAL_CONTROLLER_SHA256
    {
        return Err(StagerError(
            "held original V2 controller bytes differ from da55 pin".to_owned(),
        ));
    }
    let _ = verify_privileged_partial_root_stage(controller_bytes)?;
    sudo_install_root_directory_create_once()?;
    for artifact in [
        RootArtifact::TransactionController,
        RootArtifact::TransactionPin,
        RootArtifact::TransactionIdentity,
        RootArtifact::TransactionBootstrap,
    ] {
        let expected = artifact_bytes(artifact, controller_bytes);
        sudo_stream_root_file_create_once(artifact, &expected)?;
        let _ = verify_privileged_partial_root_stage(controller_bytes)?;
    }
    let sync = run_sudo_constant_argv(SudoAction::Sync, None)?;
    require_success(&sync, "durably sync complete transaction support")?;
    verify_transaction_support_complete(controller_bytes)?;
    for artifact in [RootArtifact::RecoveryController, RootArtifact::RecoveryPin] {
        let expected = artifact_bytes(artifact, controller_bytes);
        sudo_stream_root_file_create_once(artifact, &expected)?;
        let _ = verify_privileged_partial_root_stage(controller_bytes)?;
    }
    let sync = run_sudo_constant_argv(SudoAction::Sync, None)?;
    require_success(&sync, "durably sync fixed recovery pair")?;
    verify_resume_stage_complete(controller_bytes)
}

const SEALED_STAGER_ENV: &str = "OPENSTEAMER_RESUME_STAGER_SEALED_PATH";
const SEALED_STAGER_PARENT: &str =
    "/Library/Application Support/opensteamer/diagnostic-driver-resume-stagers-v2";
const SEALED_STAGER_PREFIX: &str = "resume-stager-";
const ORIGINAL_BUILD_PARENT: &str =
    "/Users/ahmed/Library/Caches/opensteamer-diagnostic-driver-v2-resume-builds";

fn read_descriptor_exact(
    file: &File,
    maximum: u64,
    expected: Option<(u64, &str)>,
    label: &str,
) -> Result<Vec<u8>> {
    let before = file.metadata()?;
    if !before.file_type().is_file()
        || before.file_type().is_symlink()
        || before.nlink() != 1
        || before.st_flags() != 0
        || before.len() > maximum
    {
        return Err(StagerError(format!(
            "{label} descriptor metadata is unsafe"
        )));
    }
    require_descriptor_no_acl_or_xattrs(file, label)?;
    let mut reader = file.try_clone()?;
    reader.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::with_capacity(before.len() as usize);
    Read::by_ref(&mut reader)
        .take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    if bytes.len() as u64 != before.len()
        || identity_from_metadata(&before) != identity_from_metadata(&after)
    {
        return Err(StagerError(format!(
            "{label} changed during descriptor read"
        )));
    }
    if let Some((length, digest)) = expected {
        if before.len() != length || sha256_bytes(&bytes)? != digest {
            return Err(StagerError(format!("{label} differs from its exact pin")));
        }
    }
    Ok(bytes)
}

fn require_sealed_root_directory(path: &Path, label: &str) -> Result<OpenatIdentity> {
    let (directory, ancestry_before) =
        openat_component_walk_with_final_flags(path, O_RDONLY | O_DIRECTORY)?;
    let identity = identity_from_metadata(&directory.metadata()?);
    if identity.uid != ROOT_ID
        || identity.gid != ROOT_GROUP
        || identity.mode != 0o755
        || identity.flags != 0
        || !directory.metadata()?.file_type().is_dir()
    {
        return Err(StagerError(format!("{label} metadata is unsafe")));
    }
    require_descriptor_no_acl_or_xattrs(&directory, label)?;
    let (named, ancestry_after) =
        openat_component_walk_with_final_flags(path, O_RDONLY | O_DIRECTORY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry_before != ancestry_after {
        return Err(StagerError(format!("{label} named identity changed")));
    }
    Ok(identity)
}

fn require_sealed_uid501_stager_identity() -> Result<OpenatIdentity> {
    if unsafe { getuid() } != USER_ID || unsafe { geteuid() } != USER_ID {
        return Err(StagerError(
            "resume stager must execute as exact UID501/EUID501".to_owned(),
        ));
    }
    let expected = env::var(SEALED_STAGER_ENV)
        .map_err(|_| StagerError("sealed resume-stager path environment is absent".to_owned()))?;
    let expected = PathBuf::from(expected);
    if expected.parent() != Some(Path::new(SEALED_STAGER_PARENT)) {
        return Err(StagerError(
            "sealed resume-stager escaped its exact parent".to_owned(),
        ));
    }
    let digest = expected
        .file_name()
        .and_then(OsStr::to_str)
        .and_then(|name| name.strip_prefix(SEALED_STAGER_PREFIX))
        .ok_or_else(|| StagerError("sealed resume-stager filename is malformed".to_owned()))?;
    require_lower_hex(digest, 64, "sealed resume-stager filename digest")?;
    let environment = env::vars().collect::<std::collections::BTreeMap<_, _>>();
    if environment.len() != 3
        || environment.get("LC_ALL").map(String::as_str) != Some("C")
        || environment.get("PATH").map(String::as_str) != Some("/usr/bin:/bin:/usr/sbin:/sbin")
        || environment.get(SEALED_STAGER_ENV).map(String::as_str) != Some(path_text(&expected)?)
    {
        return Err(StagerError(
            "resume-stager live environment is not exact and clean".to_owned(),
        ));
    }
    let _root_support = require_sealed_root_directory(Path::new(ROOT_SUPPORT), "root support")?;
    let _sealed_parent =
        require_sealed_root_directory(Path::new(SEALED_STAGER_PARENT), "sealed stager parent")?;
    if env::current_exe()? != expected {
        return Err(StagerError(
            "current executable differs from sealed resume-stager path".to_owned(),
        ));
    }
    let (file, ancestry_before) = openat_component_walk_with_final_flags(&expected, O_RDONLY)?;
    let before = file.metadata()?;
    let identity = identity_from_metadata(&before);
    if identity.uid != ROOT_ID
        || identity.gid != ROOT_GROUP
        || identity.mode != ROOT_SEALED_EXECUTABLE_MODE
        || identity.links != 1
        || identity.flags != 0
    {
        return Err(StagerError(
            "sealed resume-stager descriptor metadata is unsafe".to_owned(),
        ));
    }
    let bytes = read_descriptor_exact(&file, 16 * 1_048_576, None, "sealed resume stager")?;
    if sha256_bytes(&bytes)? != digest {
        return Err(StagerError(
            "sealed resume-stager bytes differ from hash-qualified path".to_owned(),
        ));
    }
    let (named, ancestry_after) = openat_component_walk_with_final_flags(&expected, O_RDONLY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry_before != ancestry_after {
        return Err(StagerError(
            "sealed resume-stager named identity changed".to_owned(),
        ));
    }
    let parent = openat_component_walk_with_final_flags(
        Path::new(SEALED_STAGER_PARENT),
        O_RDONLY | O_DIRECTORY,
    )?
    .0;
    let expected_name = expected
        .file_name()
        .ok_or_else(|| StagerError("sealed stager has no filename".to_owned()))?
        .as_bytes();
    require_exact_child_names_fd(&parent, &[expected_name], "sealed stager parent")?;
    Ok(identity)
}

fn canonical_repo(repo: &Path) -> Result<PathBuf> {
    if repo != Path::new(EXPECTED_REPO) || repo.is_symlink() {
        return Err(StagerError("repository path is not exact".to_owned()));
    }
    let canonical = fs::canonicalize(repo)?;
    if canonical != Path::new(EXPECTED_REPO) {
        return Err(StagerError("repository canonical path changed".to_owned()));
    }
    Ok(canonical)
}

fn bounded_git_output(repo: &Path, arguments: &[&str]) -> Result<Output> {
    let mut child = Command::new("/usr/bin/git")
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-C",
        ])
        .arg(repo)
        .args(arguments)
        .current_dir("/")
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| StagerError("git stdout is unavailable".to_owned()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| StagerError("git stderr is unavailable".to_owned()))?;
    let stdout_reader = thread::spawn(move || read_pipe_bounded(stdout, MAX_OUTPUT_BYTES));
    let stderr_reader = thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES));
    let deadline = Instant::now()
        .checked_add(COMMAND_TIMEOUT)
        .ok_or_else(|| StagerError("git deadline overflowed".to_owned()))?;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(StagerError("bounded git command timed out".to_owned()));
        }
        thread::sleep(Duration::from_millis(20));
    };
    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| StagerError("git stdout reader panicked".to_owned()))??;
    let (stderr, stderr_exceeded) = stderr_reader
        .join()
        .map_err(|_| StagerError("git stderr reader panicked".to_owned()))??;
    if stdout_exceeded || stderr_exceeded {
        return Err(StagerError("bounded git output exceeded limit".to_owned()));
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn git(repo: &Path, arguments: &[&str], label: &str) -> Result<String> {
    let output = bounded_git_output(repo, arguments)?;
    require_success(&output, label)?;
    if !output.stderr.is_empty() {
        return Err(StagerError(format!("{label} wrote stderr")));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError(format!("{label} output is not UTF-8")))?;
    Ok(text.trim_end_matches('\n').to_owned())
}

fn verify_git_provenance(repo: &Path) -> Result<(String, String)> {
    let repo = canonical_repo(repo)?;
    let inside = git(
        &repo,
        &["rev-parse", "--is-inside-work-tree"],
        "inspect worktree",
    )?;
    let top = git(
        &repo,
        &["rev-parse", "--show-toplevel"],
        "inspect repository root",
    )?;
    let branch = git(&repo, &["branch", "--show-current"], "inspect branch")?;
    let commit = git(&repo, &["rev-parse", "HEAD"], "inspect HEAD")?;
    let tree = git(&repo, &["rev-parse", "HEAD^{tree}"], "inspect HEAD tree")?;
    let main = git(&repo, &["rev-parse", "main"], "inspect main")?;
    let origin = git(&repo, &["rev-parse", "origin/main"], "inspect origin/main")?;
    let remote = git(
        &repo,
        &["remote", "get-url", "origin"],
        "inspect origin URL",
    )?;
    let status = git(
        &repo,
        &["status", "--porcelain=v1", "--untracked-files=all"],
        "inspect repository status",
    )?;
    if inside != "true"
        || top != EXPECTED_REPO
        || branch != "main"
        || commit != main
        || commit != origin
        || remote != EXPECTED_REMOTE
        || !status.is_empty()
    {
        return Err(StagerError(
            "repository is not exact clean pushed main".to_owned(),
        ));
    }
    require_lower_hex(&commit, 40, "resume release commit")?;
    require_lower_hex(&tree, 40, "resume release tree")?;
    let retained_commit = git(
        &repo,
        &["rev-parse", RETAINED_V2_RELEASE_COMMIT],
        "inspect retained V2 release commit",
    )?;
    let retained_tree = git(
        &repo,
        &[
            "rev-parse",
            &format!("{RETAINED_V2_RELEASE_COMMIT}^{{tree}}"),
        ],
        "inspect retained V2 release tree",
    )?;
    if retained_commit != RETAINED_V2_RELEASE_COMMIT || retained_tree != RETAINED_V2_RELEASE_TREE {
        return Err(StagerError(
            "retained V2 release commit/tree changed".to_owned(),
        ));
    }
    Ok((commit, tree))
}

#[derive(Debug)]
struct OriginalControllerProof {
    descriptor: File,
    identity: OpenatIdentity,
    ancestry: Vec<OpenatIdentity>,
    bytes: Vec<u8>,
}

fn original_controller_path_is_allowed(path: &Path) -> bool {
    path.parent()
        .filter(|parent| parent.parent() == Some(Path::new(ORIGINAL_BUILD_PARENT)))
        .and_then(Path::file_name)
        .and_then(OsStr::to_str)
        .is_some_and(|name| name.starts_with(".resume-b.") && name.len() == 16)
        && path.file_name() == Some(OsStr::new("original-controller"))
}

fn read_exact_original_controller(path: &Path) -> Result<OriginalControllerProof> {
    if !original_controller_path_is_allowed(path) {
        return Err(StagerError(
            "original-controller path escaped the reviewed twin-build scope".to_owned(),
        ));
    }
    let (descriptor, ancestry) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    let metadata = descriptor.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if identity.uid != USER_ID
        || identity.gid != USER_GROUP
        || identity.mode != 0o500
        || identity.links != 1
        || identity.length != RETAINED_V2_ORIGINAL_CONTROLLER_SIZE
        || identity.flags != 0
    {
        return Err(StagerError(
            "original-controller descriptor metadata changed".to_owned(),
        ));
    }
    let bytes = read_descriptor_exact(
        &descriptor,
        RETAINED_V2_ORIGINAL_CONTROLLER_SIZE,
        Some((
            RETAINED_V2_ORIGINAL_CONTROLLER_SIZE,
            RETAINED_V2_ORIGINAL_CONTROLLER_SHA256,
        )),
        "original V2 controller",
    )?;
    let (named, named_ancestry) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry != named_ancestry {
        return Err(StagerError(
            "original-controller named identity changed".to_owned(),
        ));
    }
    Ok(OriginalControllerProof {
        descriptor,
        identity,
        ancestry,
        bytes,
    })
}

fn verify_original_source() -> Result<OpenatIdentity> {
    let path = Path::new(ORIGINAL_SOURCE);
    let (file, ancestry_before) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    let metadata = file.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if identity.uid != USER_ID
        || identity.gid != USER_GROUP
        || identity.mode != 0o644
        || identity.links != 1
        || identity.flags != 0
    {
        return Err(StagerError(
            "original V2 source descriptor metadata changed".to_owned(),
        ));
    }
    let bytes = read_descriptor_exact(&file, 1_048_576, None, "original V2 source")?;
    if sha256_bytes(&bytes)? != RETAINED_V2_ORIGINAL_SOURCE_SHA256 {
        return Err(StagerError("original V2 source bytes changed".to_owned()));
    }
    let (named, ancestry_after) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry_before != ancestry_after {
        return Err(StagerError(
            "original V2 source named identity changed".to_owned(),
        ));
    }
    Ok(identity)
}

fn require_no_acl_or_xattrs(path: &Path) -> Result<()> {
    let listing = bounded_output("/bin/ls", &["-lde@", path_text(path)?], COMMAND_TIMEOUT)?;
    require_success(&listing, "inspect ACL")?;
    if !listing.stderr.is_empty() {
        return Err(StagerError("ACL inspection wrote stderr".to_owned()));
    }
    let text = String::from_utf8(listing.stdout)
        .map_err(|_| StagerError("ACL output is not UTF-8".to_owned()))?;
    let lines = text.lines().collect::<Vec<_>>();
    let mode = lines
        .first()
        .and_then(|line| line.split_ascii_whitespace().next())
        .ok_or_else(|| StagerError("ACL output is empty".to_owned()))?;
    if lines.len() != 1 || mode.ends_with('+') || mode.ends_with('@') {
        return Err(StagerError("ACL/xattr marker is present".to_owned()));
    }
    let xattrs = bounded_output("/usr/bin/xattr", &[path_text(path)?], COMMAND_TIMEOUT)?;
    require_success(&xattrs, "inspect xattrs")?;
    if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
        return Err(StagerError("extended attributes are present".to_owned()));
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DriverIdentity {
    outer_device: u64,
    outer_inode: u64,
    tree_sha256: String,
    executable_sha256: String,
}

fn verify_driver_bundle(
    bundle: &Path,
    expected_tree: &str,
    expected_executable: &str,
) -> Result<DriverIdentity> {
    let expected = [
        (".", "directory", 0o755),
        ("Contents", "directory", 0o755),
        ("Contents/Info.plist", "file", 0o644),
        ("Contents/MacOS", "directory", 0o755),
        (DRIVER_EXECUTABLE_RELATIVE, "file", 0o755),
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
    fn walk(root: &Path, relative: &Path, output: &mut Vec<(String, String, u32)>) -> Result<()> {
        let absolute = if relative.as_os_str().is_empty() {
            root.to_path_buf()
        } else {
            root.join(relative)
        };
        let metadata = fs::symlink_metadata(&absolute)?;
        if metadata.file_type().is_symlink()
            || metadata.uid() != ROOT_ID
            || metadata.gid() != ROOT_GROUP
            || metadata.st_flags() != 0
            || (metadata.file_type().is_file() && metadata.nlink() != 1)
        {
            return Err(StagerError(format!(
                "driver node metadata changed: {}",
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
                walk(root, &relative.join(child), output)?;
            }
        }
        Ok(())
    }
    let mut actual = Vec::new();
    walk(bundle, Path::new(""), &mut actual)?;
    let expected = expected
        .iter()
        .map(|(path, kind, mode)| (path.to_string(), kind.to_string(), *mode))
        .collect::<Vec<_>>();
    if actual != expected {
        return Err(StagerError("driver lstat manifest is not exact".to_owned()));
    }
    let mut manifest = Vec::new();
    for (path, kind, mode) in &actual {
        let type_name = if kind == "directory" {
            "Directory"
        } else {
            "Regular File"
        };
        write!(manifest, "{type_name}|{:o}|{path}\0", mode)
            .map_err(|error| StagerError(error.to_string()))?;
    }
    for relative in [
        "Contents/Info.plist",
        DRIVER_EXECUTABLE_RELATIVE,
        "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
        "Contents/Resources/en.lproj/Localizable.strings",
        "Contents/_CodeSignature/CodeResources",
    ] {
        write!(
            manifest,
            "{relative}\0{}\0",
            sha256(&bundle.join(relative))?
        )
        .map_err(|error| StagerError(error.to_string()))?;
    }
    let tree_sha256 = sha256_bytes(&manifest)?;
    let executable_sha256 = sha256(&bundle.join(DRIVER_EXECUTABLE_RELATIVE))?;
    if tree_sha256 != expected_tree || executable_sha256 != expected_executable {
        return Err(StagerError(
            "driver bytes differ from exact pins".to_owned(),
        ));
    }
    let outer = fs::symlink_metadata(bundle)?;
    Ok(DriverIdentity {
        outer_device: outer.dev(),
        outer_inode: outer.ino(),
        tree_sha256,
        executable_sha256,
    })
}

fn verify_installed_v7_driver() -> Result<DriverIdentity> {
    let identity = verify_driver_bundle(
        Path::new(PRODUCT_DRIVER),
        INSTALLED_DRIVER_TREE_SHA256,
        INSTALLED_DRIVER_EXECUTABLE_SHA256,
    )?;
    if identity.outer_device != INSTALLED_DRIVER_DEVICE
        || identity.outer_inode != INSTALLED_DRIVER_INODE
    {
        return Err(StagerError(
            "installed V7 driver outer inode changed".to_owned(),
        ));
    }
    Ok(identity)
}

fn verify_installed_candidate_driver() -> Result<DriverIdentity> {
    verify_driver_bundle(
        Path::new(PRODUCT_DRIVER),
        CANDIDATE_DRIVER_TREE_SHA256,
        CANDIDATE_DRIVER_EXECUTABLE_SHA256,
    )
}

fn verify_installed_driver_absent() -> Result<()> {
    let driver = Path::new(PRODUCT_DRIVER);
    let parent_path = driver
        .parent()
        .ok_or_else(|| StagerError("installed driver parent is absent".to_owned()))?;
    let leaf = driver
        .file_name()
        .ok_or_else(|| StagerError("installed driver leaf is absent".to_owned()))?;
    let leaf_bytes = leaf.as_bytes();
    let (parent, ancestry_before) =
        openat_component_walk_with_final_flags(parent_path, O_RDONLY | O_DIRECTORY)?;
    let parent_identity = identity_from_metadata(&parent.metadata()?);
    let children_before = list_directory_fd(&parent)?;
    if children_before.iter().any(|name| name == leaf_bytes) {
        return Err(StagerError(
            "installed driver path exists in recovery-only absence state".to_owned(),
        ));
    }
    let name = CString::new(leaf_bytes)
        .map_err(|_| StagerError("installed driver leaf contains NUL".to_owned()))?;
    unsafe { *__error() = 0 };
    let descriptor = unsafe {
        openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            0,
        )
    };
    if descriptor >= 0 {
        unsafe {
            let _ = File::from_raw_fd(descriptor);
        }
        return Err(StagerError(
            "installed driver unexpectedly opened in absence state".to_owned(),
        ));
    }
    let open_error = unsafe { *__error() };
    if open_error != ENOENT {
        return Err(StagerError(format!(
            "installed driver absence is ambiguous: {}",
            std::io::Error::from_raw_os_error(open_error)
        )));
    }
    let (parent_after, ancestry_after) =
        openat_component_walk_with_final_flags(parent_path, O_RDONLY | O_DIRECTORY)?;
    if identity_from_metadata(&parent_after.metadata()?) != parent_identity
        || ancestry_after != ancestry_before
        || list_directory_fd(&parent_after)? != children_before
    {
        return Err(StagerError(
            "installed driver parent changed during absence proof".to_owned(),
        ));
    }
    Ok(())
}

fn read_pinned_uid501_file(
    path: &Path,
    mode: u32,
    group: u32,
    size: u64,
    digest: &str,
) -> Result<OpenatIdentity> {
    let (file, ancestry_before) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    let metadata = file.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if identity.uid != USER_ID
        || identity.gid != group
        || identity.mode != mode
        || identity.links != 1
        || identity.length != size
        || identity.flags != 0
    {
        return Err(StagerError(format!(
            "pinned UID501 file metadata changed: {}",
            path.display()
        )));
    }
    let bytes = read_descriptor_exact(&file, size, Some((size, digest)), "pinned UID501 file")?;
    if bytes.len() as u64 != size {
        return Err(StagerError("pinned UID501 file is short".to_owned()));
    }
    let (named, ancestry_after) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry_before != ancestry_after {
        return Err(StagerError(
            "pinned UID501 named file changed during proof".to_owned(),
        ));
    }
    Ok(identity)
}

fn launchctl_print(target: &str) -> Result<Output> {
    bounded_output("/bin/launchctl", &["print", target], COMMAND_TIMEOUT)
}

fn require_service_absence_output(output: &Output, label: &str) -> Result<()> {
    if output.status.code() != Some(113) || !output.stdout.is_empty() {
        return Err(StagerError(format!(
            "launchd did not prove service absent: {label}"
        )));
    }
    let stderr = String::from_utf8(output.stderr.clone())
        .map_err(|_| StagerError("launchctl absence diagnostic is not UTF-8".to_owned()))?;
    let expected = format!(
        "Bad request.\nCould not find service \"{label}\" in domain for user gui: {USER_ID}\n"
    );
    if stderr != expected {
        return Err(StagerError(format!(
            "launchctl absence diagnostic changed for {label}"
        )));
    }
    Ok(())
}

fn require_service_absent(label: &str) -> Result<()> {
    let target = format!("gui/{USER_ID}/{label}");
    let output = launchctl_print(&target)?;
    require_service_absence_output(&output, label)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct LegacyIdentity {
    executable: OpenatIdentity,
    plist: OpenatIdentity,
}

fn require_legacy_disabled_and_absent() -> Result<LegacyIdentity> {
    let executable = read_pinned_uid501_file(
        Path::new(LEGACY_EXECUTABLE),
        0o755,
        LEGACY_EXECUTABLE_GROUP,
        LEGACY_EXECUTABLE_SIZE,
        LEGACY_EXECUTABLE_SHA256,
    )?;
    let plist = read_pinned_uid501_file(
        Path::new(LEGACY_PLIST),
        0o600,
        USER_GROUP,
        LEGACY_PLIST_SIZE,
        LEGACY_PLIST_SHA256,
    )?;
    require_service_absent(LEGACY_LABEL)?;
    let domain = format!("gui/{USER_ID}");
    let output = bounded_output(
        "/bin/launchctl",
        &["print-disabled", &domain],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "inspect disabled launchd overrides")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "launchctl disabled-map probe wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("launchctl disabled map is not UTF-8".to_owned()))?;
    let matching = text
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with(&format!("\"{LEGACY_LABEL}\" => ")))
        .collect::<Vec<_>>();
    if matching.len() != 1 || !(matching[0].ends_with("disabled") || matching[0].ends_with("true"))
    {
        return Err(StagerError(
            "protected legacy launchd override is not exact disabled".to_owned(),
        ));
    }
    Ok(LegacyIdentity { executable, plist })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PairingMetadataIdentity {
    account: String,
    stdout_sha256: String,
}

fn verify_pairing_metadata_only() -> Result<Vec<PairingMetadataIdentity>> {
    let mut identities = Vec::new();
    for (account, expected_digest) in PAIRING_ACCOUNTS.into_iter().zip(PAIRING_METADATA_SHA256) {
        let output = bounded_output(
            "/usr/bin/security",
            &[
                "find-generic-password",
                "-s",
                PAIRING_SERVICE,
                "-a",
                account,
            ],
            COMMAND_TIMEOUT,
        )?;
        if output.status.code() != Some(0)
            || !output.stderr.is_empty()
            || output.stdout.len() != PAIRING_METADATA_STDOUT_SIZE
        {
            return Err(StagerError(format!(
                "isolated new-host pairing metadata shape changed: {account}"
            )));
        }
        let digest = sha256_bytes(&output.stdout)?;
        if digest != expected_digest {
            return Err(StagerError(format!(
                "isolated new-host pairing metadata identity changed: {account}"
            )));
        }
        identities.push(PairingMetadataIdentity {
            account: account.to_owned(),
            stdout_sha256: digest,
        });
    }
    Ok(identities)
}

fn parse_positive_u32(value: &str, label: &str) -> Result<u32> {
    let parsed = value
        .parse::<u32>()
        .map_err(|_| StagerError(format!("{label} is malformed")))?;
    if parsed == 0 || parsed.to_string() != value {
        return Err(StagerError(format!("{label} is not canonical positive")));
    }
    Ok(parsed)
}

fn parse_positive_u64(value: &str, label: &str) -> Result<u64> {
    let parsed = value
        .parse::<u64>()
        .map_err(|_| StagerError(format!("{label} is malformed")))?;
    if parsed == 0 || parsed.to_string() != value {
        return Err(StagerError(format!("{label} is not canonical positive")));
    }
    Ok(parsed)
}

fn parse_canonical_u64(value: &str, label: &str) -> Result<u64> {
    let parsed = value
        .parse::<u64>()
        .map_err(|_| StagerError(format!("{label} is malformed")))?;
    if parsed.to_string() != value {
        return Err(StagerError(format!("{label} is not canonical")));
    }
    Ok(parsed)
}

fn set_once(slot: &mut Option<String>, value: &str, label: &str) -> Result<()> {
    if value.is_empty() || slot.replace(value.to_owned()).is_some() {
        return Err(StagerError(format!("{label} is empty or duplicated")));
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HostLaunchRecord {
    state: String,
    pid: Option<u32>,
    runs: u64,
}

fn parse_host_launch_record(text: &str) -> Result<HostLaunchRecord> {
    let expected_first = format!("gui/{USER_ID}/{HOST_LABEL} = {{");
    let mut lines = text.lines();
    if lines.next() != Some(expected_first.as_str()) || !text.ends_with('\n') {
        return Err(StagerError(
            "V8 host launch state header/termination is malformed".to_owned(),
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
                return Err(StagerError("host launch braces are malformed".to_owned()));
            }
            if depth == 0 {
                block = "closed";
            } else if depth == 1 {
                block = "";
            }
            continue;
        }
        if block == "closed" {
            return Err(StagerError(
                "host launch state has trailing records".to_owned(),
            ));
        }
        if line.ends_with(" = {") {
            block = if depth == 1 && line == "arguments = {" {
                "arguments"
            } else {
                "other"
            };
            depth += 1;
            continue;
        }
        if depth == 1 {
            if let Some(value) = line.strip_prefix("path = ") {
                set_once(&mut path, value, "host plist path")?;
            } else if let Some(value) = line.strip_prefix("type = ") {
                set_once(&mut job_type, value, "host job type")?;
            } else if let Some(value) = line.strip_prefix("state = ") {
                set_once(&mut state, value, "host state")?;
            } else if let Some(value) = line.strip_prefix("program = ") {
                set_once(&mut program, value, "host program")?;
            } else if let Some(value) = line.strip_prefix("pid = ") {
                if pid
                    .replace(parse_positive_u32(value, "host PID")?)
                    .is_some()
                {
                    return Err(StagerError("duplicate host PID".to_owned()));
                }
            } else if let Some(value) = line.strip_prefix("runs = ") {
                if runs
                    .replace(parse_canonical_u64(value, "host runs")?)
                    .is_some()
                {
                    return Err(StagerError("duplicate host runs".to_owned()));
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
        || program.as_deref() != Some(HOST_EXECUTABLE)
        || arguments != expected_arguments
    {
        return Err(StagerError(
            "V8 host launchd identity/arguments differ from contract".to_owned(),
        ));
    }
    Ok(HostLaunchRecord {
        state: state.ok_or_else(|| StagerError("host launch state is absent".to_owned()))?,
        pid,
        runs: runs.ok_or_else(|| StagerError("host run count is absent".to_owned()))?,
    })
}

fn parse_host_launch_state(text: &str) -> Result<(u32, u64)> {
    let record = parse_host_launch_record(text)?;
    if record.state != "running" || record.runs == 0 {
        return Err(StagerError(
            "V8 host launch state is not exact running".to_owned(),
        ));
    }
    Ok((
        record
            .pid
            .ok_or_else(|| StagerError("host PID is absent".to_owned()))?,
        record.runs,
    ))
}

fn require_no_process_host_launch_record(output: &Output) -> Result<HostLaunchRecord> {
    require_success(output, "inspect stopped V8 host launch state")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "stopped V8 host launch state wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout.clone())
        .map_err(|_| StagerError("stopped V8 host launch state is not UTF-8".to_owned()))?;
    let record = parse_host_launch_record(&text)?;
    if record.pid.is_some() {
        return Err(StagerError(
            "no-process V8 host launch job unexpectedly reports a PID".to_owned(),
        ));
    }
    Ok(record)
}

fn read_host_launch_state() -> Result<(u32, u64)> {
    let target = format!("gui/{USER_ID}/{HOST_LABEL}");
    let output = launchctl_print(&target)?;
    require_success(&output, "inspect V8 host launch state")?;
    if !output.stderr.is_empty() {
        return Err(StagerError("V8 host launch state wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("V8 host launch state is not UTF-8".to_owned()))?;
    parse_host_launch_state(&text)
}

fn capture_server_processes() -> Result<Vec<(u32, u32, String)>> {
    let output = bounded_output(
        "/bin/ps",
        &["-ww", "-axo", "pid=,uid=,comm="],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "enumerate CaptureServer processes")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "CaptureServer enumeration wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("process snapshot is not UTF-8".to_owned()))?;
    let mut result = Vec::new();
    for line in text.lines() {
        if !line.contains("CaptureServer") {
            continue;
        }
        let fields = line.split_ascii_whitespace().collect::<Vec<_>>();
        if fields.len() < 3 {
            return Err(StagerError("CaptureServer record is short".to_owned()));
        }
        let pid = parse_positive_u32(fields[0], "CaptureServer PID")?;
        let uid = fields[1]
            .parse::<u32>()
            .map_err(|_| StagerError("CaptureServer UID is malformed".to_owned()))?;
        result.push((pid, uid, fields[2..].join(" ")));
    }
    result.sort();
    Ok(result)
}

fn require_solo_v8_host(pid: u32) -> Result<()> {
    let processes = capture_server_processes()?;
    if processes != vec![(pid, USER_ID, HOST_EXECUTABLE.to_owned())] {
        return Err(StagerError(
            "V8 host is not the sole exact CaptureServer process".to_owned(),
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
    )?;
    require_success(&output, "prove exact V8 host arguments")?;
    if !output.stderr.is_empty() {
        return Err(StagerError("host process proof wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("host process proof is not UTF-8".to_owned()))?;
    let records = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>();
    let expected_command = format!("{HOST_EXECUTABLE} {}", HOST_ARGUMENTS.join(" "));
    if records.len() != 1 {
        return Err(StagerError("host process proof is ambiguous".to_owned()));
    }
    let fields = records[0].split_ascii_whitespace().collect::<Vec<_>>();
    if fields.len() < 6
        || fields[0] != pid_text
        || fields[1] != "1"
        || fields[2] != USER_ID.to_string()
        || fields[3] != USER_GROUP.to_string()
        || fields[4..].join(" ") != expected_command
    {
        return Err(StagerError(
            "host PID/PPID/UID/GID/arguments are not exact".to_owned(),
        ));
    }
    Ok(())
}

fn process_start(pid: u32) -> Result<String> {
    let pid_text = pid.to_string();
    let output = bounded_output(
        "/bin/ps",
        &["-p", &pid_text, "-o", "lstart="],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "inspect process start")?;
    if !output.stderr.is_empty() {
        return Err(StagerError("process-start probe wrote stderr".to_owned()));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("process start is not UTF-8".to_owned()))?;
    let normalized = text.split_ascii_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.split_ascii_whitespace().count() != 5 {
        return Err(StagerError(
            "process start identity is malformed".to_owned(),
        ));
    }
    Ok(normalized)
}

fn verify_installed_v8_runtime_bytes() -> Result<()> {
    let _ = read_pinned_uid501_file(
        Path::new(HOST_EXECUTABLE),
        0o755,
        USER_GROUP,
        HOST_EXECUTABLE_SIZE,
        HOST_EXECUTABLE_SHA256,
    )?;
    let _ = read_pinned_uid501_file(
        &Path::new(HOST_APP).join("Contents/Info.plist"),
        0o644,
        USER_GROUP,
        HOST_INFO_PLIST_SIZE,
        HOST_INFO_PLIST_SHA256,
    )?;
    let _ = read_pinned_uid501_file(
        Path::new(HOST_PLIST),
        0o600,
        USER_GROUP,
        HOST_PLIST_SIZE,
        HOST_PLIST_SHA256,
    )?;
    let verify = bounded_output(
        "/usr/bin/codesign",
        &["--verify", "--deep", "--strict", HOST_APP],
        COMMAND_TIMEOUT,
    )?;
    require_success(&verify, "verify installed V8 host signature")?;
    let details = bounded_output(
        "/usr/bin/codesign",
        &["-d", "--verbose=4", HOST_APP],
        COMMAND_TIMEOUT,
    )?;
    require_success(&details, "inspect installed V8 host signature")?;
    let text = String::from_utf8(details.stderr)
        .map_err(|_| StagerError("host codesign details are not UTF-8".to_owned()))?;
    if !text.contains(&format!("Identifier={HOST_IDENTIFIER}\n"))
        || !text.contains(&format!("TeamIdentifier={TEAM_ID}\n"))
        || !text.contains(&format!("CDHash={HOST_CDHASH}\n"))
    {
        return Err(StagerError("host code identity changed".to_owned()));
    }
    Ok(())
}

fn read_host_generation_lock(pid: u32) -> Result<(OpenatIdentity, String)> {
    let (file, ancestry_before) =
        openat_component_walk_with_final_flags(Path::new(HOST_LOCK), O_RDWR)?;
    let metadata = file.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if identity.uid != USER_ID
        || identity.gid != USER_GROUP
        || identity.mode != 0o600
        || identity.links != 1
        || identity.flags != 0
        || identity.length > 1_024
    {
        return Err(StagerError(
            "host generation-lock metadata changed".to_owned(),
        ));
    }
    let bytes = read_descriptor_exact(&file, 1_024, None, "host generation lock")?;
    let text = String::from_utf8(bytes)
        .map_err(|_| StagerError("host generation lock is not UTF-8".to_owned()))?;
    let mut lines = text.lines();
    if lines.next() != Some("OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1")
        || lines.next() != Some(&format!("pid={pid}"))
    {
        return Err(StagerError(
            "host generation lock record changed".to_owned(),
        ));
    }
    let nonce = lines
        .next()
        .and_then(|line| line.strip_prefix("nonce="))
        .ok_or_else(|| StagerError("host generation nonce is absent".to_owned()))?
        .to_owned();
    require_lower_hex(&nonce, 64, "host generation nonce")?;
    if lines.next().is_some() || !text.ends_with('\n') {
        return Err(StagerError(
            "host generation lock has extra data".to_owned(),
        ));
    }
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        return Err(StagerError(
            "host generation lock is unexpectedly acquirable".to_owned(),
        ));
    }
    if !matches!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(11 | 35)
    ) {
        return Err(StagerError(
            "host generation lock contention is operationally ambiguous".to_owned(),
        ));
    }
    let (named, ancestry_after) =
        openat_component_walk_with_final_flags(Path::new(HOST_LOCK), O_RDONLY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry_before != ancestry_after {
        return Err(StagerError(
            "host generation lock named identity changed".to_owned(),
        ));
    }
    Ok((identity, nonce))
}

fn require_pinned_lsof() -> Result<()> {
    let path = Path::new("/usr/sbin/lsof");
    let (file, ancestry_before) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    let metadata = file.metadata()?;
    let identity = identity_from_metadata(&metadata);
    if !metadata.file_type().is_file()
        || identity.uid != ROOT_ID
        || identity.gid != ROOT_GROUP
        || identity.mode != 0o755
        || identity.links != 1
        || identity.length != LSOF_SIZE
        || identity.flags != LSOF_FLAGS
    {
        return Err(StagerError(
            "lsof metadata differs from the exact reviewed system binary".to_owned(),
        ));
    }
    let _ = read_descriptor_exact(&file, LSOF_SIZE, Some((LSOF_SIZE, LSOF_SHA256)), "lsof")?;
    let (named, ancestry_after) = openat_component_walk_with_final_flags(path, O_RDONLY)?;
    if identity_from_metadata(&named.metadata()?) != identity || ancestry_after != ancestry_before {
        return Err(StagerError(
            "lsof named identity changed during descriptor proof".to_owned(),
        ));
    }
    Ok(())
}

fn host_lock_openers() -> Result<Vec<(u32, String, u32, String)>> {
    require_pinned_lsof()?;
    let output = bounded_output(
        "/usr/sbin/lsof",
        &["-n", "-Fpcufa", "--", HOST_LOCK],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "attribute host generation-lock openers")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "host lock opener attribution wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("host lock opener output is not UTF-8".to_owned()))?;
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
                return Err(StagerError("lsof command record is malformed".to_owned()));
            }
        } else if let Some(value) = line.strip_prefix('u') {
            let uid = value
                .parse::<u32>()
                .map_err(|_| StagerError("lsof UID is malformed".to_owned()))?;
            if current_pid.is_none()
                || uid.to_string() != value
                || current_uid.replace(uid).is_some()
            {
                return Err(StagerError("lsof UID record is malformed".to_owned()));
            }
        } else if line.starts_with('f') {
            if current_pid.is_none() || current_fd {
                return Err(StagerError(
                    "lsof file-descriptor record is out of order".to_owned(),
                ));
            }
            current_fd = true;
        } else if let Some(access) = line.strip_prefix('a') {
            if !current_fd || !matches!(access, "r" | "w" | "u") {
                return Err(StagerError("lsof access record is malformed".to_owned()));
            }
            openers.push((
                current_pid.ok_or_else(|| StagerError("lsof access lacks PID".to_owned()))?,
                current_command
                    .clone()
                    .ok_or_else(|| StagerError("lsof access lacks command".to_owned()))?,
                current_uid.ok_or_else(|| StagerError("lsof access lacks UID".to_owned()))?,
                access.to_owned(),
            ));
            current_fd = false;
        } else {
            return Err(StagerError(
                "lsof opener output contains an unknown record".to_owned(),
            ));
        }
    }
    if current_fd || openers.is_empty() {
        return Err(StagerError(
            "lsof opener output is incomplete or empty".to_owned(),
        ));
    }
    Ok(openers)
}

fn prove_lock_sole_host_opener(generation: &HostGeneration) -> Result<()> {
    let openers = host_lock_openers()?;
    if openers.iter().any(|(pid, command, uid, access)| {
        *pid != generation.pid
            || command != "CaptureServer"
            || *uid != USER_ID
            || !matches!(access.as_str(), "r" | "w" | "u")
    }) || !openers
        .iter()
        .any(|(pid, _, _, access)| *pid == generation.pid && matches!(access.as_str(), "w" | "u"))
    {
        return Err(StagerError(
            "host generation lock is not solely held by the exact live host".to_owned(),
        ));
    }
    let (file, _) = openat_component_walk_with_final_flags(Path::new(HOST_LOCK), O_RDWR)?;
    if identity_from_metadata(&file.metadata()?) != generation.lock_identity {
        return Err(StagerError(
            "host generation lock identity changed before contention proof".to_owned(),
        ));
    }
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        return Err(StagerError(
            "host generation lock is unexpectedly acquirable".to_owned(),
        ));
    }
    if !matches!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(11 | 35)
    ) {
        return Err(StagerError(
            "host generation lock contention is operationally ambiguous".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HostGeneration {
    pid: u32,
    runs: u64,
    process_start: String,
    nonce: String,
    lock_identity: OpenatIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum HostPreflightState {
    ExactLive(HostGeneration),
    NoProcessServicePresent(HostLaunchRecord),
    NoProcessServiceAbsent,
}

fn disposition_allows_host_state(
    disposition: ResumeDisposition,
    state: &HostPreflightState,
) -> bool {
    disposition == ResumeDisposition::RecoveryOnly
        || matches!(state, HostPreflightState::ExactLive(_))
}

fn accept_host_preflight_state(
    disposition: ResumeDisposition,
    state: HostPreflightState,
) -> Result<HostPreflightState> {
    if !disposition_allows_host_state(disposition, &state) {
        return Err(StagerError(
            "fresh dispatch requires the exact live V8 host".to_owned(),
        ));
    }
    Ok(state)
}

fn fresh_host_generation_is_exact(generation: &HostGeneration) -> bool {
    let expected_lock = OpenatIdentity {
        device: RETAINED_DEVICE,
        inode: FRESH_HOST_LOCK_INODE,
        uid: USER_ID,
        gid: USER_GROUP,
        mode: 0o600,
        length: FRESH_HOST_LOCK_SIZE,
        links: 1,
        flags: 0,
    };
    generation.pid == FRESH_HOST_PID
        && generation.runs == FRESH_HOST_RUNS
        && generation.process_start == FRESH_HOST_START
        && generation.nonce == FRESH_HOST_NONCE
        && generation.lock_identity == expected_lock
}

fn require_exact_fresh_host_generation(generation: &HostGeneration) -> Result<()> {
    if !fresh_host_generation_is_exact(generation) {
        return Err(StagerError(
            "fresh-dispatch V8 host baseline is not the retained failed-attempt generation"
                .to_owned(),
        ));
    }
    Ok(())
}

fn verify_live_v8_host() -> Result<HostGeneration> {
    verify_installed_v8_runtime_bytes()?;
    let _ = require_legacy_disabled_and_absent()?;
    let (pid, runs) = read_host_launch_state()?;
    require_solo_v8_host(pid)?;
    let initial_process_start = process_start(pid)?;
    let (lock_identity, nonce) = read_host_generation_lock(pid)?;
    let first = HostGeneration {
        pid,
        runs,
        process_start: initial_process_start,
        nonce,
        lock_identity,
    };
    thread::sleep(Duration::from_millis(250));
    let (pid_again, runs_again) = read_host_launch_state()?;
    let (lock_again, nonce_again) = read_host_generation_lock(pid)?;
    if pid_again != first.pid
        || runs_again != first.runs
        || process_start(pid)? != first.process_start
        || lock_again != first.lock_identity
        || nonce_again != first.nonce
    {
        return Err(StagerError(
            "V8 host generation changed during proof".to_owned(),
        ));
    }
    require_solo_v8_host(pid)?;
    prove_lock_sole_host_opener(&first)?;
    Ok(first)
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
        return Err(StagerError(format!(
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
    let mut value = std::ptr::null::<std::ffi::c_void>();
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
    if status != 0 || value.is_null() {
        return Err(StagerError(format!(
            "read-only device UID lookup failed: device={device} status={status}"
        )));
    }
    let mut buffer = [0_i8; 1_024];
    let converted = unsafe {
        CFStringGetCString(
            value,
            buffer.as_mut_ptr(),
            buffer.len() as isize,
            CF_STRING_UTF8,
        )
    };
    if converted == 0 {
        return Err(StagerError("device UID is not bounded UTF-8".to_owned()));
    }
    let bytes = buffer
        .iter()
        .take_while(|byte| **byte != 0)
        .map(|byte| *byte as u8)
        .collect::<Vec<_>>();
    let uid =
        String::from_utf8(bytes).map_err(|_| StagerError("device UID is not UTF-8".to_owned()))?;
    if uid.is_empty() || uid.len() > 255 || uid.chars().any(char::is_control) {
        return Err(StagerError("device UID is malformed".to_owned()));
    }
    Ok(uid)
}

fn capture_route_snapshot() -> Result<RouteSnapshot> {
    Ok(RouteSnapshot {
        input_uid: audio_device_uid(audio_default_device(SELECTOR_DEFAULT_INPUT)?)?,
        output_uid: audio_device_uid(audio_default_device(SELECTOR_DEFAULT_OUTPUT)?)?,
        system_output_uid: audio_device_uid(audio_default_device(SELECTOR_DEFAULT_SYSTEM_OUTPUT)?)?,
    })
}

fn stable_route_snapshot() -> Result<RouteSnapshot> {
    let first = capture_route_snapshot()?;
    thread::sleep(Duration::from_millis(250));
    let second = capture_route_snapshot()?;
    if first != second {
        return Err(StagerError(
            "default routes changed during read-only proof".to_owned(),
        ));
    }
    Ok(first)
}

fn require_exact_fresh_routes(routes: &RouteSnapshot) -> Result<()> {
    if routes.input_uid != FRESH_INPUT_UID
        || routes.output_uid != FRESH_OUTPUT_UID
        || routes.system_output_uid != FRESH_OUTPUT_UID
    {
        return Err(StagerError(
            "fresh-dispatch default routes differ from retained failed-attempt baseline".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CoreAudioGeneration {
    pid: u32,
    runs: u64,
    process_start: String,
}

fn parse_coreaudio_launch_state(text: &str) -> Result<(u32, u64)> {
    if !text.starts_with("system/com.apple.audio.coreaudiod = {\n") || !text.ends_with("}\n") {
        return Err(StagerError(
            "coreaudiod launch state framing changed".to_owned(),
        ));
    }
    for required in [
        "\tstate = running\n",
        "\tprogram = /usr/sbin/coreaudiod\n",
        "\tdomain = system\n",
        "\tusername = _coreaudiod\n",
        "\tgroup = _coreaudiod\n",
    ] {
        if text.matches(required).count() != 1 {
            return Err(StagerError(
                "coreaudiod launch identity field changed".to_owned(),
            ));
        }
    }
    let parse_field = |prefix: &str, label: &str| -> Result<String> {
        let matches = text
            .lines()
            .map(str::trim)
            .filter_map(|line| line.strip_prefix(prefix))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if matches.len() != 1 {
            return Err(StagerError(format!(
                "coreaudiod {label} is absent or duplicated"
            )));
        }
        Ok(matches[0].clone())
    };
    Ok((
        parse_positive_u32(&parse_field("pid = ", "PID")?, "coreaudiod PID")?,
        parse_positive_u64(&parse_field("runs = ", "runs")?, "coreaudiod runs")?,
    ))
}

fn read_coreaudio_generation() -> Result<CoreAudioGeneration> {
    let output = launchctl_print("system/com.apple.audio.coreaudiod")?;
    require_success(&output, "inspect system coreaudiod")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "coreaudiod launch state wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("coreaudiod launch state is not UTF-8".to_owned()))?;
    let (pid, runs) = parse_coreaudio_launch_state(&text)?;
    let pid_text = pid.to_string();
    let output = bounded_output(
        "/bin/ps",
        &[
            "-ww", "-p", &pid_text, "-o", "pid=", "-o", "ppid=", "-o", "uid=", "-o", "gid=", "-o",
            "comm=",
        ],
        COMMAND_TIMEOUT,
    )?;
    require_success(&output, "inspect coreaudiod process")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "coreaudiod process probe wrote stderr".to_owned(),
        ));
    }
    let record = String::from_utf8(output.stdout)
        .map_err(|_| StagerError("coreaudiod process record is not UTF-8".to_owned()))?;
    if record.split_ascii_whitespace().collect::<Vec<_>>()
        != [pid_text.as_str(), "1", "202", "202", "/usr/sbin/coreaudiod"]
    {
        return Err(StagerError(
            "coreaudiod process identity changed".to_owned(),
        ));
    }
    let pgrep = command_line(
        "/usr/bin/pgrep",
        &["-x", "coreaudiod"],
        "enumerate coreaudiod",
    )?;
    if pgrep != pid_text {
        return Err(StagerError(
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
        return Err(StagerError(
            "coreaudiod generation changed during proof".to_owned(),
        ));
    }
    Ok(first)
}

fn require_exact_fresh_coreaudio(generation: &CoreAudioGeneration) -> Result<()> {
    if generation.pid != FRESH_COREAUDIO_PID
        || generation.runs != FRESH_COREAUDIO_RUNS
        || generation.process_start != FRESH_COREAUDIO_START
    {
        return Err(StagerError(
            "fresh-dispatch coreaudiod baseline is not the retained failed-attempt generation"
                .to_owned(),
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ResumeDisposition {
    FreshDispatch,
    RecoveryOnly,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InstalledDriverStateClass {
    ExactV7,
    ExactCandidate,
    ExactAbsent,
    Other,
}

fn disposition_allows_driver_state(
    disposition: ResumeDisposition,
    state: InstalledDriverStateClass,
) -> bool {
    match disposition {
        ResumeDisposition::FreshDispatch => state == InstalledDriverStateClass::ExactV7,
        ResumeDisposition::RecoveryOnly => matches!(
            state,
            InstalledDriverStateClass::ExactV7
                | InstalledDriverStateClass::ExactCandidate
                | InstalledDriverStateClass::ExactAbsent
        ),
    }
}

fn classify_dispatch_observation(
    canonical_intent: bool,
    pending_intent: bool,
    root_state_present: bool,
) -> Result<ResumeDisposition> {
    if canonical_intent && pending_intent {
        return Err(StagerError(
            "canonical and pending resume dispatch intents coexist".to_owned(),
        ));
    }
    if canonical_intent || pending_intent || root_state_present {
        Ok(ResumeDisposition::RecoveryOnly)
    } else {
        Ok(ResumeDisposition::FreshDispatch)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootStateObservation {
    Absent,
    Present,
    Ambiguous,
}

fn durable_intent_allows_forward_dispatch(
    recovery_only: bool,
    observation: RootStateObservation,
) -> bool {
    !recovery_only && observation == RootStateObservation::Absent
}

fn root_v2_state_appeared() -> Result<bool> {
    let mut appeared = false;
    for path in [
        RootPath::V2UpdateRoot,
        RootPath::V2Pointer,
        RootPath::V2PendingPointer,
        RootPath::V2Lock,
        RootPath::V2ProbeParent,
    ] {
        appeared |= sudo_root_exists(path)?;
    }
    Ok(appeared)
}

fn resume_dispatch_intent_exists() -> Result<(bool, bool)> {
    Ok((
        sudo_root_exists(RootPath::ArtifactFinal(RootArtifact::DispatchIntent))?,
        sudo_root_exists(RootPath::ArtifactPending(RootArtifact::DispatchIntent))?,
    ))
}

fn verify_resume_dispatch_intent() -> Result<()> {
    let expected = artifact_bytes(RootArtifact::DispatchIntent, &[]);
    if expected.len() != RESUME_DISPATCH_INTENT_SIZE
        || sha256_bytes(&expected)? != RESUME_DISPATCH_INTENT_SHA256
    {
        return Err(StagerError(
            "compiled resume dispatch-intent bytes differ from exact authorization pin".to_owned(),
        ));
    }
    let _ = verify_existing_exact_root_file(RootArtifact::DispatchIntent, &expected)?;
    sudo_root_require_absent(
        RootPath::ArtifactPending(RootArtifact::DispatchIntent),
        "resume dispatch-intent pending file",
    )
}

fn classify_dispatch_or_recovery_state() -> Result<ResumeDisposition> {
    let (canonical, pending) = resume_dispatch_intent_exists()?;
    let _ = classify_dispatch_observation(canonical, pending, false)?;
    if canonical {
        verify_resume_dispatch_intent()?;
        return classify_dispatch_observation(true, false, false);
    }
    if pending {
        let expected = artifact_bytes(RootArtifact::DispatchIntent, &[]);
        let _ = verify_exact_or_partial_pending_root_file(RootArtifact::DispatchIntent, &expected)?;
        return classify_dispatch_observation(false, true, false);
    }
    classify_dispatch_observation(false, false, root_v2_state_appeared()?)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ResumePreflightSnapshot {
    release_commit: String,
    release_tree: String,
    sealed_stager_identity: OpenatIdentity,
    original_source_identity: OpenatIdentity,
    original_controller_identity: OpenatIdentity,
    original_controller_ancestry: Vec<OpenatIdentity>,
    host_state: HostPreflightState,
    coreaudio_generation: Option<CoreAudioGeneration>,
    installed_driver_identity: Option<DriverIdentity>,
    route_snapshot: Option<RouteSnapshot>,
    pairing_metadata: Vec<PairingMetadataIdentity>,
    legacy_identity: LegacyIdentity,
    retained_v1_identities: RetainedGraphProof,
    retained_v2_identities: RetainedGraphProof,
    root_stage: RootStageProof,
    disposition: ResumeDisposition,
}

#[derive(Debug)]
struct ResumePreflightGuard {
    snapshot: ResumePreflightSnapshot,
    original_controller: OriginalControllerProof,
}

fn verify_installed_driver_for_disposition(
    disposition: ResumeDisposition,
) -> Result<Option<DriverIdentity>> {
    if !disposition_allows_driver_state(disposition, InstalledDriverStateClass::ExactCandidate)
        && !disposition_allows_driver_state(disposition, InstalledDriverStateClass::ExactAbsent)
    {
        return verify_installed_v7_driver().map(Some);
    }
    match verify_installed_v7_driver() {
        Ok(identity) => Ok(Some(identity)),
        Err(v7_error) => match verify_installed_candidate_driver() {
            Ok(identity) => Ok(Some(identity)),
            Err(candidate_error) => verify_installed_driver_absent()
                .map(|()| None)
                .map_err(|absence_error| {
                    StagerError(format!(
                        "recovery-only driver is not exact V7, exact candidate, or exact absence: v7={v7_error}; candidate={candidate_error}; absence={absence_error}"
                    ))
                }),
        },
    }
}

fn verify_host_for_disposition(disposition: ResumeDisposition) -> Result<HostPreflightState> {
    if disposition == ResumeDisposition::FreshDispatch {
        let generation = verify_live_v8_host()?;
        require_exact_fresh_host_generation(&generation)?;
        return accept_host_preflight_state(disposition, HostPreflightState::ExactLive(generation));
    }
    let processes = capture_server_processes()?;
    if !processes.is_empty() {
        return verify_live_v8_host()
            .map(HostPreflightState::ExactLive)
            .and_then(|state| accept_host_preflight_state(disposition, state));
    }
    verify_installed_v8_runtime_bytes()?;
    let _ = require_legacy_disabled_and_absent()?;
    let target = format!("gui/{USER_ID}/{HOST_LABEL}");
    let output = launchctl_print(&target)?;
    if output.status.success() {
        return require_no_process_host_launch_record(&output)
            .map(HostPreflightState::NoProcessServicePresent)
            .and_then(|state| accept_host_preflight_state(disposition, state));
    }
    require_service_absence_output(&output, HOST_LABEL)?;
    accept_host_preflight_state(disposition, HostPreflightState::NoProcessServiceAbsent)
}

fn verify_resume_preflight(
    repo: &Path,
    original_controller_path: &Path,
    guards: &RetainedAttemptGuards,
) -> Result<ResumePreflightGuard> {
    let sealed_stager_identity = require_sealed_uid501_stager_identity()?;
    let (release_commit, release_tree) = verify_git_provenance(repo)?;
    let original_source_identity = verify_original_source()?;
    let original_controller = read_exact_original_controller(original_controller_path)?;
    let (retained_v1_identities, retained_v2_identities) = prove_retained_graphs(guards)?;
    let root_stage = verify_privileged_partial_root_stage(&original_controller.bytes)?;
    let disposition = classify_dispatch_or_recovery_state()?;
    let installed_driver_identity = verify_installed_driver_for_disposition(disposition)?;
    let host_state = verify_host_for_disposition(disposition)?;
    let (coreaudio_generation, route_snapshot) = if disposition == ResumeDisposition::FreshDispatch
    {
        let coreaudio = stable_coreaudio_generation()?;
        require_exact_fresh_coreaudio(&coreaudio)?;
        let routes = stable_route_snapshot()?;
        require_exact_fresh_routes(&routes)?;
        (Some(coreaudio), Some(routes))
    } else {
        (None, None)
    };
    let pairing_metadata = verify_pairing_metadata_only()?;
    let legacy_identity = require_legacy_disabled_and_absent()?;
    Ok(ResumePreflightGuard {
        snapshot: ResumePreflightSnapshot {
            release_commit,
            release_tree,
            sealed_stager_identity,
            original_source_identity,
            original_controller_identity: original_controller.identity.clone(),
            original_controller_ancestry: original_controller.ancestry.clone(),
            host_state,
            coreaudio_generation,
            installed_driver_identity,
            route_snapshot,
            pairing_metadata,
            legacy_identity,
            retained_v1_identities,
            retained_v2_identities,
            root_stage,
            disposition,
        },
        original_controller,
    })
}

fn compare_root_stage_anchors(left: &RootStageProof, right: &RootStageProof) -> bool {
    left.locator == right.locator
        && left.controller_parent.device == right.controller_parent.device
        && left.controller_parent.inode == right.controller_parent.inode
        && left.controller_parent.uid == right.controller_parent.uid
        && left.controller_parent.gid == right.controller_parent.gid
        && left.controller_parent.mode == right.controller_parent.mode
        && left.controller_parent.flags == right.controller_parent.flags
        && left.controller_parent.file_type == right.controller_parent.file_type
}

fn compare_preflight_guards(
    initial: &ResumePreflightGuard,
    final_snapshot: &ResumePreflightGuard,
) -> Result<()> {
    let left = &initial.snapshot;
    let right = &final_snapshot.snapshot;
    if left.release_commit != right.release_commit
        || left.release_tree != right.release_tree
        || left.sealed_stager_identity != right.sealed_stager_identity
        || left.original_source_identity != right.original_source_identity
        || left.original_controller_identity != right.original_controller_identity
        || left.original_controller_ancestry != right.original_controller_ancestry
        || initial.original_controller.bytes != final_snapshot.original_controller.bytes
        || left.host_state != right.host_state
        || left.coreaudio_generation != right.coreaudio_generation
        || left.installed_driver_identity != right.installed_driver_identity
        || left.route_snapshot != right.route_snapshot
        || left.pairing_metadata != right.pairing_metadata
        || left.legacy_identity != right.legacy_identity
        || left.retained_v1_identities != right.retained_v1_identities
        || left.retained_v2_identities != right.retained_v2_identities
        || !compare_root_stage_anchors(&left.root_stage, &right.root_stage)
    {
        return Err(StagerError(
            "live/preflight invariants changed while root artifacts were staged".to_owned(),
        ));
    }
    Ok(())
}

fn publish_resume_dispatch_intent() -> Result<()> {
    let expected = artifact_bytes(RootArtifact::DispatchIntent, &[]);
    let (canonical, pending) = resume_dispatch_intent_exists()?;
    if canonical {
        if pending {
            return Err(StagerError(
                "canonical/pending dispatch intent collision".to_owned(),
            ));
        }
        return verify_resume_dispatch_intent();
    }
    if pending {
        let _ = verify_exact_or_partial_pending_root_file(RootArtifact::DispatchIntent, &expected)?;
    }
    sudo_stream_root_file_create_once(RootArtifact::DispatchIntent, &expected)?;
    verify_resume_dispatch_intent()
}

fn require_root_owned_sealed_executable(artifact: RootArtifact, bytes: &[u8]) -> Result<()> {
    if artifact.published_mode() != ROOT_SEALED_EXECUTABLE_MODE {
        return Err(StagerError(
            "sealed executable verifier received a record artifact".to_owned(),
        ));
    }
    let _ = verify_existing_exact_root_file(artifact, bytes)?;
    Ok(())
}

fn require_root_owned_sealed_record(artifact: RootArtifact, bytes: &[u8]) -> Result<()> {
    if artifact.published_mode() != ROOT_SEALED_RECORD_MODE {
        return Err(StagerError(
            "sealed record verifier received an executable artifact".to_owned(),
        ));
    }
    let _ = verify_existing_exact_root_file(artifact, bytes)?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootOutcome {
    Committed,
    RolledBack,
    PrestopAborted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootCompletionEntrypoint {
    Forward,
    PointerBackedRecovery,
    PointerlessPrestop,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RootCompletion {
    outcome: RootOutcome,
    entrypoint: RootCompletionEntrypoint,
    host_pid: u32,
    host_runs: Option<u64>,
}

fn root_completion_matches_live_host(
    completion: RootCompletion,
    generation: &HostGeneration,
) -> bool {
    generation.pid == completion.host_pid
        && completion
            .host_runs
            .is_none_or(|marker_runs| generation.runs == marker_runs)
        && (completion.entrypoint != RootCompletionEntrypoint::PointerlessPrestop
            || fresh_host_generation_is_exact(generation))
}

fn parse_root_success_marker(output: &Output) -> Result<RootCompletion> {
    require_success(output, "sealed root V2 controller")?;
    if !output.stderr.is_empty() {
        return Err(StagerError(
            "successful sealed root controller wrote stderr".to_owned(),
        ));
    }
    let text = String::from_utf8(output.stdout.clone())
        .map_err(|_| StagerError("sealed root marker is not UTF-8".to_owned()))?;
    let line = text
        .strip_suffix('\n')
        .ok_or_else(|| StagerError("sealed root marker lacks exact newline".to_owned()))?;
    if line.contains('\n') {
        return Err(StagerError(
            "sealed root controller emitted multiple records".to_owned(),
        ));
    }
    let fields = line.split_ascii_whitespace().collect::<Vec<_>>();
    let parse_host_pid = |field: &str| -> Result<u32> {
        let value = field
            .strip_prefix("host_pid=")
            .ok_or_else(|| StagerError("root marker host PID field is absent".to_owned()))?;
        parse_positive_u32(value, "root marker host PID")
    };
    let parse_host_runs = |field: &str| -> Result<u64> {
        let value = field
            .strip_prefix("host_runs=")
            .ok_or_else(|| StagerError("root marker host runs field is absent".to_owned()))?;
        let runs = parse_positive_u64(value, "root marker host runs")?;
        if runs != 1 {
            return Err(StagerError(
                "root marker host runs is not exact one".to_owned(),
            ));
        }
        Ok(runs)
    };
    let exact_six_tail = |prefix: &str| -> bool {
        fields.len() == 6
            && fields[0] == prefix
            && fields[3] == "pairing=preserved"
            && fields[4] == "routes=unchanged"
            && fields[5] == "legacy=protected"
    };
    if exact_six_tail("DIAGNOSTIC_DRIVER_V2_UPDATE_COMMITTED") {
        return Ok(RootCompletion {
            outcome: RootOutcome::Committed,
            entrypoint: RootCompletionEntrypoint::Forward,
            host_pid: parse_host_pid(fields[1])?,
            host_runs: Some(parse_host_runs(fields[2])?),
        });
    }
    if exact_six_tail("DIAGNOSTIC_DRIVER_V2_ROOT_RECOVERY_COMMITTED") {
        return Ok(RootCompletion {
            outcome: RootOutcome::Committed,
            entrypoint: RootCompletionEntrypoint::PointerBackedRecovery,
            host_pid: parse_host_pid(fields[1])?,
            host_runs: Some(parse_host_runs(fields[2])?),
        });
    }
    if exact_six_tail("DIAGNOSTIC_DRIVER_V2_ROOT_ROLLBACK_COMPLETE") {
        return Ok(RootCompletion {
            outcome: RootOutcome::RolledBack,
            entrypoint: RootCompletionEntrypoint::PointerBackedRecovery,
            host_pid: parse_host_pid(fields[1])?,
            host_runs: Some(parse_host_runs(fields[2])?),
        });
    }
    let pointerless_prestop = fields.len() == 4
        && fields[0] == "DIAGNOSTIC_DRIVER_V2_ROOT_PRESTOP_ABORTED"
        && fields[2] == "routes=unchanged"
        && fields[3] == "pairing=preserved";
    if pointerless_prestop {
        return Ok(RootCompletion {
            outcome: RootOutcome::PrestopAborted,
            entrypoint: RootCompletionEntrypoint::PointerlessPrestop,
            host_pid: parse_host_pid(fields[1])?,
            host_runs: None,
        });
    }
    if exact_six_tail("DIAGNOSTIC_DRIVER_V2_ROOT_PRESTOP_ABORTED") {
        return Ok(RootCompletion {
            outcome: RootOutcome::PrestopAborted,
            entrypoint: RootCompletionEntrypoint::PointerBackedRecovery,
            host_pid: parse_host_pid(fields[1])?,
            host_runs: Some(parse_host_runs(fields[2])?),
        });
    }
    Err(StagerError(
        "sealed root controller success marker shape is unknown".to_owned(),
    ))
}

fn dispatch_original_v2_controller_once(controller_bytes: &[u8]) -> Result<RootCompletion> {
    require_root_owned_sealed_executable(RootArtifact::TransactionController, controller_bytes)?;
    require_root_owned_sealed_record(
        RootArtifact::TransactionBootstrap,
        RETAINED_V2_REQUEST_TEXT.as_bytes(),
    )?;
    if root_v2_state_appeared()? {
        return Err(StagerError(
            "root V2 state appeared before the one-shot dispatch".to_owned(),
        ));
    }
    let output = run_sudo_constant_argv(SudoAction::DispatchOriginal, None)?;
    parse_root_success_marker(&output)
}

fn recover_from_resume_dispatch_intent(controller_bytes: &[u8]) -> Result<RootCompletion> {
    verify_resume_dispatch_intent()?;
    require_root_owned_sealed_executable(RootArtifact::RecoveryController, controller_bytes)?;
    require_root_owned_sealed_record(
        RootArtifact::RecoveryPin,
        format!("{RETAINED_V2_ORIGINAL_CONTROLLER_SHA256}\n").as_bytes(),
    )?;
    let deadline = Instant::now()
        .checked_add(RECOVERY_QUIESCENCE_TIMEOUT)
        .ok_or_else(|| StagerError("sealed recovery quiescence deadline overflowed".to_owned()))?;
    loop {
        let output = run_sudo_constant_argv(SudoAction::RecoverSealed, None)?;
        let exact_busy = output.status.code() == Some(1)
            && output.stdout.is_empty()
            && output.stderr
                == b"opensteamer diagnostic-driver updater: another root diagnostic-driver transaction is active\n";
        if exact_busy && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(250));
            continue;
        }
        if exact_busy {
            return Err(StagerError(
                "original root controller did not quiesce before recovery deadline".to_owned(),
            ));
        }
        return parse_root_success_marker(&output);
    }
}

fn host_successor_for_outcome(
    before: &HostGeneration,
    after: &HostGeneration,
    outcome: RootOutcome,
) -> bool {
    match outcome {
        RootOutcome::PrestopAborted => after == before,
        RootOutcome::Committed | RootOutcome::RolledBack => {
            before.pid != after.pid
                && after.runs == 1
                && after.process_start != before.process_start
                && same_host_lock_anchor(&after.lock_identity, &before.lock_identity)
                && after.nonce != before.nonce
        }
    }
}

fn same_host_lock_anchor(left: &OpenatIdentity, right: &OpenatIdentity) -> bool {
    left.device == right.device
        && left.inode == right.inode
        && left.uid == right.uid
        && left.gid == right.gid
        && left.mode == right.mode
        && left.links == right.links
        && left.flags == right.flags
}

fn host_transition_allowed(
    disposition: ResumeDisposition,
    before: &HostGeneration,
    after: &HostGeneration,
    outcome: RootOutcome,
) -> bool {
    match outcome {
        RootOutcome::PrestopAborted => after == before,
        RootOutcome::Committed | RootOutcome::RolledBack => {
            host_successor_for_outcome(before, after, outcome)
                || (disposition == ResumeDisposition::RecoveryOnly && after == before)
        }
    }
}

fn coreaudio_successor_for_outcome(
    before: &CoreAudioGeneration,
    after: &CoreAudioGeneration,
    outcome: RootOutcome,
) -> bool {
    if outcome == RootOutcome::PrestopAborted {
        return after == before;
    }
    let valid_increment = match outcome {
        RootOutcome::Committed => 1,
        RootOutcome::RolledBack => {
            return after.pid != before.pid
                && matches!(after.runs.checked_sub(before.runs), Some(1 | 2));
        }
        RootOutcome::PrestopAborted => unreachable!(),
    };
    after.pid != before.pid && after.runs == before.runs.saturating_add(valid_increment)
}

fn coreaudio_transition_allowed(
    disposition: ResumeDisposition,
    before: &CoreAudioGeneration,
    after: &CoreAudioGeneration,
    outcome: RootOutcome,
) -> bool {
    coreaudio_successor_for_outcome(before, after, outcome)
        || (disposition == ResumeDisposition::RecoveryOnly
            && matches!(outcome, RootOutcome::Committed | RootOutcome::RolledBack)
            && after == before)
}

fn retained_terminal_coreaudio_is_exact(
    generation: &CoreAudioGeneration,
    outcome: RootOutcome,
) -> bool {
    match outcome {
        RootOutcome::Committed => {
            generation.pid != FRESH_COREAUDIO_PID && generation.runs == FRESH_COREAUDIO_RUNS + 1
        }
        RootOutcome::RolledBack => {
            generation.pid != FRESH_COREAUDIO_PID
                && matches!(
                    generation.runs.checked_sub(FRESH_COREAUDIO_RUNS),
                    Some(1 | 2)
                )
        }
        RootOutcome::PrestopAborted => {
            generation.pid == FRESH_COREAUDIO_PID
                && generation.runs == FRESH_COREAUDIO_RUNS
                && generation.process_start == FRESH_COREAUDIO_START
        }
    }
}

fn verify_post_dispatch_live(
    before: &ResumePreflightSnapshot,
    completion: RootCompletion,
) -> Result<()> {
    let outcome = completion.outcome;
    let installed_driver_identity = match outcome {
        RootOutcome::Committed => verify_installed_candidate_driver()?,
        RootOutcome::RolledBack | RootOutcome::PrestopAborted => verify_installed_v7_driver()?,
    };
    let host = verify_live_v8_host()?;
    if !root_completion_matches_live_host(completion, &host) {
        return Err(StagerError(
            "terminal live host PID/runs differ from the exact root marker".to_owned(),
        ));
    }
    if let HostPreflightState::ExactLive(initial_host) = &before.host_state {
        if !host_transition_allowed(before.disposition, initial_host, &host, outcome) {
            return Err(StagerError(
                "live V8 host is not unchanged or one exact successor".to_owned(),
            ));
        }
    }
    let coreaudio = stable_coreaudio_generation()?;
    if !retained_terminal_coreaudio_is_exact(&coreaudio, outcome) {
        return Err(StagerError(
            "terminal coreaudiod generation is not exact for the retained outcome".to_owned(),
        ));
    }
    if let Some(initial_coreaudio) = &before.coreaudio_generation {
        if !coreaudio_transition_allowed(before.disposition, initial_coreaudio, &coreaudio, outcome)
        {
            return Err(StagerError(
                "coreaudiod transition is inconsistent with root outcome".to_owned(),
            ));
        }
    }
    let routes = stable_route_snapshot()?;
    require_exact_fresh_routes(&routes)?;
    if before
        .route_snapshot
        .as_ref()
        .is_some_and(|initial_routes| initial_routes != &routes)
        || verify_pairing_metadata_only()? != before.pairing_metadata
        || require_legacy_disabled_and_absent()? != before.legacy_identity
    {
        return Err(StagerError(
            "routes/pairing/protected legacy invariant changed".to_owned(),
        ));
    }
    let expected_executable = match outcome {
        RootOutcome::Committed => CANDIDATE_DRIVER_EXECUTABLE_SHA256,
        RootOutcome::RolledBack | RootOutcome::PrestopAborted => INSTALLED_DRIVER_EXECUTABLE_SHA256,
    };
    if installed_driver_identity.executable_sha256 != expected_executable {
        return Err(StagerError(
            "post-dispatch installed-driver proof is inconsistent".to_owned(),
        ));
    }
    Ok(())
}

fn dispatch_or_recover_after_durable_intent(
    initial: &ResumePreflightSnapshot,
    controller_bytes: &[u8],
    recovery_only: bool,
) -> Result<RootCompletion> {
    let root_observation = if recovery_only {
        RootStateObservation::Present
    } else {
        match root_v2_state_appeared() {
            Ok(false) => RootStateObservation::Absent,
            Ok(true) => RootStateObservation::Present,
            Err(_) => RootStateObservation::Ambiguous,
        }
    };
    let forward = if durable_intent_allows_forward_dispatch(recovery_only, root_observation) {
        dispatch_original_v2_controller_once(controller_bytes)
    } else {
        Err(StagerError(
            "durable intent/root state requires sealed recovery".to_owned(),
        ))
    };
    match forward {
        Ok(completion) => match verify_post_dispatch_live(initial, completion) {
            Ok(()) => Ok(completion),
            Err(_) => {
                let recovered = recover_from_resume_dispatch_intent(controller_bytes)?;
                verify_post_dispatch_live(initial, recovered)?;
                Ok(recovered)
            }
        },
        Err(_) => {
            let recovered = recover_from_resume_dispatch_intent(controller_bytes)?;
            verify_post_dispatch_live(initial, recovered)?;
            Ok(recovered)
        }
    }
}

fn verify_post_completion_anchors(
    guards: &RetainedAttemptGuards,
    initial: &ResumePreflightGuard,
) -> Result<()> {
    let (retained_v1, retained_v2) = prove_retained_graphs(guards)?;
    if retained_v1 != initial.snapshot.retained_v1_identities
        || retained_v2 != initial.snapshot.retained_v2_identities
    {
        return Err(StagerError(
            "retained V1/V2 evidence changed across root completion".to_owned(),
        ));
    }
    verify_retained_v1_root_attestation()?;
    let root_stage = verify_privileged_partial_root_stage(&initial.original_controller.bytes)?;
    if root_stage.prefix != ResumeStagePrefix::Complete
        || !compare_root_stage_anchors(&initial.snapshot.root_stage, &root_stage)
    {
        return Err(StagerError(
            "sealed controller/recovery root stage changed across completion".to_owned(),
        ));
    }
    let _ = verify_resume_stage_complete(&initial.original_controller.bytes)?;
    verify_resume_dispatch_intent()?;
    let descriptor_identity =
        identity_from_metadata(&initial.original_controller.descriptor.metadata()?);
    let descriptor_bytes = read_descriptor_exact(
        &initial.original_controller.descriptor,
        RETAINED_V2_ORIGINAL_CONTROLLER_SIZE,
        Some((
            RETAINED_V2_ORIGINAL_CONTROLLER_SIZE,
            RETAINED_V2_ORIGINAL_CONTROLLER_SHA256,
        )),
        "held original V2 controller after completion",
    )?;
    if descriptor_identity != initial.snapshot.original_controller_identity
        || descriptor_bytes != initial.original_controller.bytes
    {
        return Err(StagerError(
            "held original V2 controller changed across root completion".to_owned(),
        ));
    }
    Ok(())
}

fn execute_authorized_resume(
    repo: &Path,
    authorized_commit: &str,
    authorized_tree: &str,
    original_controller_path: &Path,
) -> Result<()> {
    require_lower_hex(authorized_commit, 40, "authorized resume commit")?;
    require_lower_hex(authorized_tree, 40, "authorized resume tree")?;
    let guards = acquire_retained_attempt_guards()?;
    let initial = verify_resume_preflight(repo, original_controller_path, &guards)?;
    if initial.snapshot.release_commit != authorized_commit
        || initial.snapshot.release_tree != authorized_tree
    {
        return Err(StagerError(
            "authorized resume release differs from exact pushed main".to_owned(),
        ));
    }
    let initial_disposition = initial.snapshot.disposition;
    let _stage = stage_original_v2_root_controller(&initial.original_controller.bytes)?;
    let final_snapshot = verify_resume_preflight(repo, original_controller_path, &guards)?;
    compare_preflight_guards(&initial, &final_snapshot)?;
    let final_disposition = classify_dispatch_or_recovery_state()?;
    let _ = prove_retained_graphs(&guards)?;
    let _ = verify_resume_stage_complete(&initial.original_controller.bytes)?;
    publish_resume_dispatch_intent()?;
    let recovery_only = initial_disposition == ResumeDisposition::RecoveryOnly
        || final_disposition == ResumeDisposition::RecoveryOnly;
    let completion = dispatch_or_recover_after_durable_intent(
        &initial.snapshot,
        &initial.original_controller.bytes,
        recovery_only,
    )?;
    verify_post_completion_anchors(&guards, &initial)?;
    println!(
        "DIAGNOSTIC_DRIVER_V2_RESUME_COMPLETE outcome={} pairing=preserved routes=unchanged legacy=protected",
        match completion.outcome {
            RootOutcome::Committed => "committed",
            RootOutcome::RolledBack => "rolled-back",
            RootOutcome::PrestopAborted => "prestop-aborted",
        }
    );
    Ok(())
}

fn require_self_test(condition: bool, label: &str) -> Result<()> {
    if !condition {
        return Err(StagerError(format!("self-test failed: {label}")));
    }
    Ok(())
}

fn self_test() -> Result<()> {
    let tests = std::cell::Cell::new(0_u32);
    let check = |condition: bool, label: &str| -> Result<()> {
        tests.set(tests.get().saturating_add(1));
        require_self_test(condition, label)
    };

    for (value, length, label) in [
        (
            RETAINED_V2_ORIGINAL_SOURCE_SHA256,
            64,
            "original-source-pin",
        ),
        (
            RETAINED_V2_ORIGINAL_CONTROLLER_SHA256,
            64,
            "original-controller-pin",
        ),
        (RETAINED_V2_REQUEST_SHA256, 64, "request-pin"),
        (RETAINED_V2_JOURNAL_SHA256, 64, "journal-pin"),
        (DIAGNOSTIC_READER_SHA256, 64, "reader-pin"),
        (RETAINED_V2_NONCE, 32, "nonce-pin"),
        (RETAINED_V2_RELEASE_COMMIT, 40, "release-commit-pin"),
        (RETAINED_V2_RELEASE_TREE, 40, "release-tree-pin"),
    ] {
        tests.set(tests.get().saturating_add(1));
        require_lower_hex(value, length, label)?;
    }
    check(
        RETAINED_V1_DEVICE == RETAINED_DEVICE,
        "retained-device-alias",
    )?;
    check(
        RETAINED_V2_REQUEST_TEXT.len() == 670,
        "retained-v2-request-size",
    )?;
    check(
        RETAINED_V2_JOURNAL_TEXT.len() == 236,
        "retained-v2-journal-size",
    )?;
    check(
        resume_dispatch_intent_text().starts_with(RESUME_DISPATCH_INTENT_HEADER),
        "intent-header",
    )?;
    check(
        resume_dispatch_intent_text().ends_with('\n'),
        "intent-newline",
    )?;

    let regular = parse_root_identity("16777229|28527198|0|0|100444|1|670|0\n")?;
    check(
        regular.file_type == RootFileType::Regular
            && regular.mode == 0o444
            && regular.inode == RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE,
        "root-regular-parser",
    )?;
    let directory = parse_root_identity("16777229|28527199|0|0|40711|2|64|0\n")?;
    check(
        directory.file_type == RootFileType::Directory
            && directory.mode == ROOT_SEALED_TRAVERSE_MODE,
        "root-directory-parser",
    )?;
    for (fixture, label) in [
        (
            "16777229|28527198|0|0|120777|1|670|0\n",
            "reject-root-symlink",
        ),
        (
            "16777229|28527198|0|0|100444|1|670\n",
            "reject-root-short-stat",
        ),
        (
            "16777229|28527198|0|0|100444|1|670|0\ntrailing\n",
            "reject-root-extra-stat",
        ),
        (
            "016777229|28527198|0|0|100444|1|670|0\n",
            "reject-root-noncanonical-device",
        ),
    ] {
        tests.set(tests.get().saturating_add(1));
        require_self_test(parse_root_identity(fixture).is_err(), label)?;
    }

    let exact_intent = artifact_bytes(RootArtifact::DispatchIntent, &[]);
    check(
        exact_intent == resume_dispatch_intent_text().as_bytes(),
        "intent-exact-bytes",
    )?;
    check(
        exact_intent.starts_with(&exact_intent[..exact_intent.len() / 2]),
        "intent-pending-prefix",
    )?;
    check(
        !exact_intent.starts_with(b"wrong-intent"),
        "intent-wrong-prefix-rejected",
    )?;
    let abort_fixture = format!(
        "OPENSTEAMER_DIAGNOSTIC_DRIVER_BOOTSTRAP_ABORT_V2\nnonce={RETAINED_V2_NONCE}\nhost_pid=98080\noutcome=prestop-aborted\n"
    );
    check(
        parse_bootstrap_abort_result(&abort_fixture)? == 98_080,
        "bootstrap-abort-result-terminal-rerun",
    )?;
    check(
        parse_bootstrap_abort_result(
            &abort_fixture.replace("outcome=prestop-aborted", "outcome=committed"),
        )
        .is_err(),
        "bootstrap-abort-result-hostile-outcome",
    )?;

    let marker_output = |line: &str| Output {
        status: std::process::ExitStatus::from_raw(0),
        stdout: format!("{line}\n").into_bytes(),
        stderr: Vec::new(),
    };
    check(
        parse_root_success_marker(&marker_output(
            "DIAGNOSTIC_DRIVER_V2_UPDATE_COMMITTED host_pid=98080 host_runs=1 pairing=preserved routes=unchanged legacy=protected",
        ))?.outcome == RootOutcome::Committed,
        "forward-commit-marker-exact",
    )?;
    check(
        parse_root_success_marker(&marker_output(
            "DIAGNOSTIC_DRIVER_V2_ROOT_PRESTOP_ABORTED host_pid=98080 routes=unchanged pairing=preserved",
        ))?.outcome == RootOutcome::PrestopAborted,
        "pointerless-prestop-marker-exact",
    )?;
    check(
        parse_root_success_marker(&marker_output(
            "DIAGNOSTIC_DRIVER_V2_ROOT_ROLLBACK_COMPLETE host_pid=98080 host_runs=2 pairing=preserved routes=unchanged legacy=protected",
        ))
        .is_err(),
        "rollback-marker-rejects-nonunit-host-runs",
    )?;
    check(
        parse_root_success_marker(&marker_output(
            "DIAGNOSTIC_DRIVER_V2_ROOT_RECOVERY_COMMITTED host_pid=98080 host_runs=1 pairing=preserved routes=drifted legacy=protected",
        ))
        .is_err(),
        "recovery-marker-rejects-route-drift",
    )?;

    for (artifact, expected_mode, label) in [
        (
            RootArtifact::TransactionController,
            0o555,
            "transaction-controller-mode",
        ),
        (RootArtifact::TransactionPin, 0o444, "transaction-pin-mode"),
        (
            RootArtifact::TransactionIdentity,
            0o444,
            "transaction-identity-mode",
        ),
        (
            RootArtifact::TransactionBootstrap,
            0o444,
            "transaction-bootstrap-mode",
        ),
        (
            RootArtifact::RecoveryController,
            0o555,
            "recovery-controller-mode",
        ),
        (RootArtifact::RecoveryPin, 0o444, "recovery-pin-mode"),
        (RootArtifact::DispatchIntent, 0o444, "dispatch-intent-mode"),
    ] {
        check(artifact.published_mode() == expected_mode, label)?;
        check(
            artifact.final_path() != artifact.pending_path(),
            &format!("{label}-separate-pending"),
        )?;
    }

    let support_name = format!("controller-{RETAINED_V2_NONCE}");
    let mut parent_children = Vec::<String>::new();
    let mut support_children = Vec::<String>::new();
    check(
        classify_stage_child_observation(&parent_children, &support_children)?
            == ResumeStagePrefix::LocatorAndEmptyControllerParent,
        "stage-empty-prefix-classified",
    )?;
    parent_children.push(support_name.clone());
    check(
        classify_stage_child_observation(&parent_children, &support_children)?
            == ResumeStagePrefix::TransactionSupportDirectory,
        "stage-support-prefix-classified",
    )?;
    for (artifact, expected, label) in [
        (
            RootArtifact::TransactionController,
            ResumeStagePrefix::TransactionController,
            "stage-controller-prefix-classified",
        ),
        (
            RootArtifact::TransactionPin,
            ResumeStagePrefix::TransactionControllerPin,
            "stage-controller-pin-prefix-classified",
        ),
        (
            RootArtifact::TransactionIdentity,
            ResumeStagePrefix::TransactionControllerIdentity,
            "stage-controller-identity-prefix-classified",
        ),
        (
            RootArtifact::TransactionBootstrap,
            ResumeStagePrefix::TransactionBootstrapRequest,
            "stage-bootstrap-prefix-classified",
        ),
    ] {
        support_children.push(root_artifact_leaf(artifact, false));
        check(
            classify_stage_child_observation(&parent_children, &support_children)? == expected,
            label,
        )?;
    }
    parent_children.push(root_artifact_leaf(RootArtifact::RecoveryController, false));
    check(
        classify_stage_child_observation(&parent_children, &support_children)?
            == ResumeStagePrefix::FixedRecoveryController,
        "stage-recovery-controller-prefix-classified",
    )?;
    parent_children.push(root_artifact_leaf(RootArtifact::RecoveryPin, false));
    check(
        classify_stage_child_observation(&parent_children, &support_children)?
            == ResumeStagePrefix::Complete,
        "stage-complete-classified",
    )?;
    let pending_transaction = vec![root_artifact_leaf(
        RootArtifact::TransactionController,
        true,
    )];
    check(
        classify_stage_child_observation(&[support_name.clone()], &pending_transaction)?
            == ResumeStagePrefix::Partial(RootArtifact::TransactionController),
        "stage-transaction-pending-prefix-classified",
    )?;
    let mut recovery_pending_parent = vec![support_name.clone()];
    recovery_pending_parent.push(root_artifact_leaf(RootArtifact::RecoveryController, true));
    check(
        classify_stage_child_observation(&recovery_pending_parent, &support_children)?
            == ResumeStagePrefix::Partial(RootArtifact::RecoveryController),
        "stage-recovery-pending-prefix-classified",
    )?;
    let mut terminal_abort_support = support_children.clone();
    terminal_abort_support.push("bootstrap-abort-result.txt".to_owned());
    check(
        classify_stage_child_observation(&parent_children, &terminal_abort_support)?
            == ResumeStagePrefix::Complete,
        "stage-terminal-abort-result-classified",
    )?;
    check(
        classify_stage_child_observation(
            &[support_name.clone()],
            &[root_artifact_leaf(RootArtifact::TransactionPin, false)],
        )
        .is_err(),
        "stage-out-of-order-artifact-rejected",
    )?;
    check(
        classify_stage_child_observation(&[support_name.clone(), "unexpected".to_owned()], &[])
            .is_err(),
        "stage-extra-parent-child-rejected",
    )?;
    check(
        classify_stage_child_observation(
            &[support_name.clone()],
            &[
                root_artifact_leaf(RootArtifact::TransactionController, false),
                root_artifact_leaf(RootArtifact::TransactionController, true),
            ],
        )
        .is_err(),
        "stage-canonical-pending-collision-rejected",
    )?;
    check(
        classify_stage_child_observation(
            &[support_name.clone()],
            &["bootstrap-abort-result.txt".to_owned()],
        )
        .is_err(),
        "stage-early-abort-result-rejected",
    )?;

    let exact_root_identity = RootIdentity {
        device: RETAINED_DEVICE,
        inode: RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE,
        uid: ROOT_ID,
        gid: ROOT_GROUP,
        mode: ROOT_SEALED_RECORD_MODE,
        links: 1,
        length: RETAINED_V2_REQUEST_TEXT.len() as u64,
        flags: 0,
        file_type: RootFileType::Regular,
    };
    check(
        exact_root_file_metadata_matches(
            &exact_root_identity,
            ROOT_SEALED_RECORD_MODE,
            RETAINED_V2_REQUEST_TEXT.len() as u64,
            Some(RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE),
            false,
        ),
        "root-metadata-exact-accepted",
    )?;
    for (hostile, has_acl_or_xattrs, label) in [
        (
            {
                let mut value = exact_root_identity.clone();
                value.uid = USER_ID;
                value
            },
            false,
            "root-wrong-owner-rejected",
        ),
        (
            {
                let mut value = exact_root_identity.clone();
                value.mode = 0o644;
                value
            },
            false,
            "root-wrong-mode-rejected",
        ),
        (
            {
                let mut value = exact_root_identity.clone();
                value.inode = value.inode.saturating_add(1);
                value
            },
            false,
            "root-wrong-inode-rejected",
        ),
        (exact_root_identity.clone(), true, "root-acl-xattr-rejected"),
    ] {
        check(
            !exact_root_file_metadata_matches(
                &hostile,
                ROOT_SEALED_RECORD_MODE,
                RETAINED_V2_REQUEST_TEXT.len() as u64,
                Some(RETAINED_V2_ROOT_BOOTSTRAP_LOCATOR_INODE),
                has_acl_or_xattrs,
            ),
            label,
        )?;
    }
    check(
        exact_root_bytes_match(
            RETAINED_V2_REQUEST_TEXT.as_bytes(),
            RETAINED_V2_REQUEST_TEXT.as_bytes(),
        ),
        "root-exact-bytes-accepted",
    )?;
    check(
        !exact_root_bytes_match(
            &RETAINED_V2_REQUEST_TEXT.as_bytes()[..RETAINED_V2_REQUEST_TEXT.len() - 1],
            RETAINED_V2_REQUEST_TEXT.as_bytes(),
        ),
        "root-truncated-final-bytes-rejected",
    )?;
    check(
        pending_root_bytes_match(
            &RETAINED_V2_REQUEST_TEXT.as_bytes()[..100],
            RETAINED_V2_REQUEST_TEXT.as_bytes(),
        ) && !pending_root_bytes_match(b"wrong", RETAINED_V2_REQUEST_TEXT.as_bytes()),
        "root-pending-byte-prefix-behavior",
    )?;

    let retained_identity = OpenatIdentity {
        device: RETAINED_DEVICE,
        inode: RETAINED_V2_USER_ACTIVE_POINTER_INODE,
        uid: USER_ID,
        gid: USER_GROUP,
        mode: 0o600,
        length: 153,
        links: 1,
        flags: 0,
    };
    check(
        retained_descriptor_identity_matches(
            &retained_identity,
            false,
            false,
            false,
            RETAINED_V2_USER_ACTIVE_POINTER_INODE,
            1,
            153,
            0o600,
        ),
        "retained-identity-exact-accepted",
    )?;
    let mut wrong_retained = retained_identity.clone();
    wrong_retained.inode = wrong_retained.inode.saturating_add(1);
    check(
        !retained_descriptor_identity_matches(
            &wrong_retained,
            false,
            false,
            false,
            RETAINED_V2_USER_ACTIVE_POINTER_INODE,
            1,
            153,
            0o600,
        ) && !retained_descriptor_identity_matches(
            &retained_identity,
            false,
            true,
            false,
            RETAINED_V2_USER_ACTIVE_POINTER_INODE,
            1,
            153,
            0o600,
        ),
        "retained-identity-inode-and-symlink-rejected",
    )?;

    check(
        classify_dispatch_observation(false, false, false)? == ResumeDisposition::FreshDispatch,
        "intent-absent-fresh-classified",
    )?;
    check(
        classify_dispatch_observation(false, true, false)? == ResumeDisposition::RecoveryOnly
            && classify_dispatch_observation(true, false, false)?
                == ResumeDisposition::RecoveryOnly
            && classify_dispatch_observation(false, false, true)?
                == ResumeDisposition::RecoveryOnly,
        "intent-or-root-state-recovery-only-classified",
    )?;
    check(
        classify_dispatch_observation(true, true, false).is_err(),
        "intent-collision-rejected",
    )?;
    check(
        durable_intent_allows_forward_dispatch(false, RootStateObservation::Absent)
            && !durable_intent_allows_forward_dispatch(false, RootStateObservation::Present)
            && !durable_intent_allows_forward_dispatch(false, RootStateObservation::Ambiguous)
            && !durable_intent_allows_forward_dispatch(true, RootStateObservation::Absent),
        "durable-intent-forward-convergence-policy",
    )?;
    check(
        disposition_allows_driver_state(
            ResumeDisposition::FreshDispatch,
            InstalledDriverStateClass::ExactV7,
        ) && !disposition_allows_driver_state(
            ResumeDisposition::FreshDispatch,
            InstalledDriverStateClass::ExactCandidate,
        ) && !disposition_allows_driver_state(
            ResumeDisposition::FreshDispatch,
            InstalledDriverStateClass::ExactAbsent,
        ) && disposition_allows_driver_state(
            ResumeDisposition::RecoveryOnly,
            InstalledDriverStateClass::ExactCandidate,
        ) && disposition_allows_driver_state(
            ResumeDisposition::RecoveryOnly,
            InstalledDriverStateClass::ExactAbsent,
        ) && !disposition_allows_driver_state(
            ResumeDisposition::RecoveryOnly,
            InstalledDriverStateClass::Other,
        ),
        "fresh-recovery-driver-state-policy",
    )?;

    let fresh_lock = OpenatIdentity {
        device: RETAINED_DEVICE,
        inode: FRESH_HOST_LOCK_INODE,
        uid: USER_ID,
        gid: USER_GROUP,
        mode: 0o600,
        length: FRESH_HOST_LOCK_SIZE,
        links: 1,
        flags: 0,
    };
    let fresh_host = HostGeneration {
        pid: FRESH_HOST_PID,
        runs: FRESH_HOST_RUNS,
        process_start: FRESH_HOST_START.to_owned(),
        nonce: FRESH_HOST_NONCE.to_owned(),
        lock_identity: fresh_lock,
    };
    let mut successor_host = fresh_host.clone();
    successor_host.pid = 100_001;
    successor_host.process_start = "Sun Aug 23 00:00:00 2026".to_owned();
    successor_host.nonce =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned();
    successor_host.lock_identity.length = FRESH_HOST_LOCK_SIZE + 1;
    check(
        host_successor_for_outcome(&fresh_host, &successor_host, RootOutcome::Committed),
        "host-successor-allows-generation-record-length-change",
    )?;
    let mut wrong_lock_successor = successor_host.clone();
    wrong_lock_successor.lock_identity.inode = FRESH_HOST_LOCK_INODE + 1;
    check(
        !host_successor_for_outcome(&fresh_host, &wrong_lock_successor, RootOutcome::Committed),
        "host-successor-rejects-lock-inode-change",
    )?;
    let committed_completion = RootCompletion {
        outcome: RootOutcome::Committed,
        entrypoint: RootCompletionEntrypoint::PointerBackedRecovery,
        host_pid: successor_host.pid,
        host_runs: Some(1),
    };
    check(
        root_completion_matches_live_host(committed_completion, &successor_host),
        "root-marker-host-pid-runs-accepted",
    )?;
    check(
        !root_completion_matches_live_host(
            RootCompletion {
                host_pid: successor_host.pid + 1,
                ..committed_completion
            },
            &successor_host,
        ) && !root_completion_matches_live_host(
            RootCompletion {
                host_runs: Some(2),
                ..committed_completion
            },
            &successor_host,
        ),
        "root-marker-host-pid-runs-mismatch-rejected",
    )?;
    let pointerless_completion = RootCompletion {
        outcome: RootOutcome::PrestopAborted,
        entrypoint: RootCompletionEntrypoint::PointerlessPrestop,
        host_pid: fresh_host.pid,
        host_runs: None,
    };
    check(
        root_completion_matches_live_host(pointerless_completion, &fresh_host)
            && !root_completion_matches_live_host(pointerless_completion, &successor_host),
        "pointerless-marker-requires-retained-host-generation",
    )?;
    check(
        host_transition_allowed(
            ResumeDisposition::RecoveryOnly,
            &fresh_host,
            &fresh_host,
            RootOutcome::Committed,
        ) && !host_transition_allowed(
            ResumeDisposition::FreshDispatch,
            &fresh_host,
            &fresh_host,
            RootOutcome::Committed,
        ) && host_transition_allowed(
            ResumeDisposition::FreshDispatch,
            &fresh_host,
            &fresh_host,
            RootOutcome::PrestopAborted,
        ),
        "terminal-rerun-host-idempotence-policy",
    )?;
    let absent_host_state = HostPreflightState::NoProcessServiceAbsent;
    check(
        disposition_allows_host_state(ResumeDisposition::RecoveryOnly, &absent_host_state)
            && !disposition_allows_host_state(ResumeDisposition::FreshDispatch, &absent_host_state),
        "fresh-recovery-host-state-policy",
    )?;

    let host_launch_waiting = format!(
        "gui/{USER_ID}/{HOST_LABEL} = {{\n\tpath = {HOST_PLIST}\n\ttype = LaunchAgent\n\tstate = waiting\n\tprogram = {HOST_EXECUTABLE}\n\targuments = {{\n\t\t{HOST_EXECUTABLE}\n\t\t{}\n\t}}\n\truns = 1\n}}\n",
        HOST_ARGUMENTS.join("\n\t\t")
    );
    let waiting_output = Output {
        status: std::process::ExitStatus::from_raw(0),
        stdout: host_launch_waiting.as_bytes().to_vec(),
        stderr: Vec::new(),
    };
    check(
        require_no_process_host_launch_record(&waiting_output)?.state == "waiting",
        "no-process-loaded-transient-host-state-accepted",
    )?;
    let pid_output = Output {
        status: std::process::ExitStatus::from_raw(0),
        stdout: host_launch_waiting
            .replace("\truns = 1\n", "\tpid = 123\n\truns = 1\n")
            .into_bytes(),
        stderr: Vec::new(),
    };
    check(
        require_no_process_host_launch_record(&pid_output).is_err(),
        "no-process-loaded-host-pid-rejected",
    )?;

    let fresh_coreaudio = CoreAudioGeneration {
        pid: FRESH_COREAUDIO_PID,
        runs: FRESH_COREAUDIO_RUNS,
        process_start: FRESH_COREAUDIO_START.to_owned(),
    };
    let committed_coreaudio = CoreAudioGeneration {
        pid: FRESH_COREAUDIO_PID + 1,
        runs: FRESH_COREAUDIO_RUNS + 1,
        process_start: "Sun Aug 23 00:00:01 2026".to_owned(),
    };
    let rollback_coreaudio = CoreAudioGeneration {
        runs: FRESH_COREAUDIO_RUNS + 2,
        ..committed_coreaudio.clone()
    };
    check(
        coreaudio_successor_for_outcome(
            &fresh_coreaudio,
            &committed_coreaudio,
            RootOutcome::Committed,
        ) && coreaudio_successor_for_outcome(
            &fresh_coreaudio,
            &rollback_coreaudio,
            RootOutcome::RolledBack,
        ) && !coreaudio_successor_for_outcome(
            &fresh_coreaudio,
            &rollback_coreaudio,
            RootOutcome::Committed,
        ),
        "coreaudio-outcome-transition-policy",
    )?;
    check(
        coreaudio_transition_allowed(
            ResumeDisposition::RecoveryOnly,
            &fresh_coreaudio,
            &fresh_coreaudio,
            RootOutcome::Committed,
        ) && !coreaudio_transition_allowed(
            ResumeDisposition::FreshDispatch,
            &fresh_coreaudio,
            &fresh_coreaudio,
            RootOutcome::Committed,
        ),
        "terminal-rerun-coreaudio-idempotence-policy",
    )?;
    check(
        retained_terminal_coreaudio_is_exact(&committed_coreaudio, RootOutcome::Committed)
            && retained_terminal_coreaudio_is_exact(&rollback_coreaudio, RootOutcome::RolledBack)
            && retained_terminal_coreaudio_is_exact(&fresh_coreaudio, RootOutcome::PrestopAborted),
        "terminal-coreaudio-absolute-counts-accepted",
    )?;
    let unrelated_coreaudio = CoreAudioGeneration {
        pid: FRESH_COREAUDIO_PID + 2,
        runs: FRESH_COREAUDIO_RUNS + 3,
        process_start: "Sun Aug 23 00:00:02 2026".to_owned(),
    };
    check(
        !retained_terminal_coreaudio_is_exact(&unrelated_coreaudio, RootOutcome::Committed)
            && !retained_terminal_coreaudio_is_exact(&unrelated_coreaudio, RootOutcome::RolledBack)
            && !retained_terminal_coreaudio_is_exact(
                &committed_coreaudio,
                RootOutcome::PrestopAborted,
            ),
        "terminal-coreaudio-unrelated-generation-rejected",
    )?;
    let same_pid_reloaded_coreaudio = CoreAudioGeneration {
        pid: FRESH_COREAUDIO_PID,
        runs: FRESH_COREAUDIO_RUNS + 1,
        process_start: FRESH_COREAUDIO_START.to_owned(),
    };
    check(
        !retained_terminal_coreaudio_is_exact(&same_pid_reloaded_coreaudio, RootOutcome::Committed)
            && !retained_terminal_coreaudio_is_exact(
                &same_pid_reloaded_coreaudio,
                RootOutcome::RolledBack,
            ),
        "terminal-coreaudio-same-pid-reload-rejected",
    )?;
    let exact_routes = RouteSnapshot {
        input_uid: FRESH_INPUT_UID.to_owned(),
        output_uid: FRESH_OUTPUT_UID.to_owned(),
        system_output_uid: FRESH_OUTPUT_UID.to_owned(),
    };
    let mut hostile_routes = exact_routes.clone();
    hostile_routes.input_uid = "unexpected-input".to_owned();
    check(
        require_exact_fresh_routes(&exact_routes).is_ok()
            && require_exact_fresh_routes(&hostile_routes).is_err(),
        "recovery-post-route-policy",
    )?;
    check(
        PAIRING_ACCOUNTS.len() == PAIRING_METADATA_SHA256.len()
            && PAIRING_METADATA_SHA256
                .iter()
                .all(|digest| require_lower_hex(digest, 64, "pairing digest").is_ok()),
        "pairing-metadata-digest-pins",
    )?;

    let source = include_str!("opensteamer-diagnostic-driver-v2-resume-stager.rs");
    check(
        source.matches("Command::new(\"/usr/bin/sudo\")").count() == 1,
        "single-sudo-runner-site",
    )?;
    let route_mutator = ["AudioObjectSet", "PropertyData"].concat();
    let installer = ["/usr/sbin/", "installer"].concat();
    let pairing_reset = ["--reset-worldwide-", "pairing"].concat();
    let v3_namespace = ["diagnostic-driver-", "v3"].concat();
    check(!source.contains(&route_mutator), "no-route-mutation-api")?;
    check(!source.contains(&installer), "no-installer")?;
    check(!source.contains(&pairing_reset), "no-pairing-reset")?;
    check(!source.contains(&v3_namespace), "no-v3-namespace")?;
    check(
        source.contains("com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"),
        "new-host-pairing-service",
    )?;
    let protected_pairing = [
        "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing",
        ".v1",
    ]
    .concat();
    check(
        !source.contains(&protected_pairing),
        "no-protected-legacy-pairing-service",
    )?;
    let protected_hidden = [
        "/Applications/.audio",
        "streamer-failed-20260720-102747-44276/AudioStreamer Host.app",
    ]
    .concat();
    check(
        !source.contains(&protected_hidden),
        "no-protected-hidden-recovery-app",
    )?;
    check(tests.get() >= 60, "minimum-hostile-self-test-count")?;
    println!(
        "DIAGNOSTIC_DRIVER_V2_RESUME_SELF_TEST_OK tests={}",
        tests.get()
    );
    Ok(())
}
