// Guarded, crash-recoverable Mac-only opensteamer host migration controller.
//
// This Rust 2021 program owns the transaction lock, journal, state transitions, cutover,
// readiness verification, rollback, and recovery. It never operates on an iPhone.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::{CString, OsStr};
use std::fs::{self, File, Metadata, OpenOptions, Permissions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{self, Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const AUTHORIZED_MODE: &str = "--execute-authorized-mac-only-migration";
const SELF_TEST_MODE: &str = "--self-test";
const USER_HOME: &str = "/Users/ahmed";
const USER_ID: u32 = 501;
const MIGRATIONS_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/migrations";
const PRIVATE_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer";
const ACTIVE_TRANSACTION_NAME: &str = "active-migration-v11";
const ACTIVE_TRANSACTION_PENDING_NAME: &str = ".active-migration-v11.pending";
const ACTIVE_TRANSACTION_FINALIZING_NAME: &str = ".active-migration-v11.finalizing";
const ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = ".active-migration-v11.linearized";
const PRIOR_V10_ACTIVE_TRANSACTION_NAME: &str = "active-migration-v10";
const PRIOR_V10_ACTIVE_TRANSACTION_PENDING_NAME: &str = ".active-migration-v10.pending";
const PRIOR_V10_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = ".active-migration-v10.finalizing";
const PRIOR_V10_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = ".active-migration-v10.linearized";
const PRIOR_ACTIVE_TRANSACTION_NAME: &str = "active-migration-v9";
const PRIOR_ACTIVE_TRANSACTION_PENDING_NAME: &str = ".active-migration-v9.pending";
const PRIOR_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = ".active-migration-v9.finalizing";
const PRIOR_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = ".active-migration-v9.linearized";
const PRIOR_EVIDENCE_PATH: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v9-1785629833-85682";
const PRIOR_ACTIVE_RECORD: &[u8] = b"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v9-1785629833-85682\n";
const PRIOR_ACTIVE_SHA256: &str =
    "55c5936e520d65c2096811546357853e05064eca41553603793bea5843518559";
const LEGACY_APP: &str = "/Applications/AudioStreamer Host.app";
const LEGACY_EXECUTABLE: &str = "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer";
const LEGACY_LABEL: &str = "com.elamin.audiostreamer.worldwide";
const LEGACY_PLIST: &str =
    "/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist";
const LEGACY_EXECUTABLE_SHA256: &str =
    "1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc";
const LEGACY_PLIST_SHA256: &str =
    "419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730";
const NEW_APP: &str = "/Applications/opensteamer Host.app";
const NEW_EXECUTABLE: &str = "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer";
const NEW_LABEL: &str = "org.example.opensteamer.worldwide";
const NEW_PLIST: &str = "/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist";
const LOCK_DIRECTORY: &str =
    "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime";
const LOCK_FILE: &str = "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock";
const TEAM_ID: &str = "MSMG8CJLB3";
const SIGNING_IDENTITY_SHA1: &str = "483C08B6517EBC1CFCCAB1A88BBEE8028750AA13";
const CODE_IDENTIFIER: &str = "com.elamin.AudioStreamer.CaptureServer";
const ONLINE_LOG: &str = "/var/tmp/opensteamer-worldwide-host.log";
const ERROR_LOG: &str = "/var/tmp/opensteamer-worldwide-host.err.log";
const ONLINE_MARKER: &str = "Worldwide paired-device availability is online";
const JOURNAL_VERSION: &str = "OPENSTEAMER_MIGRATION_JOURNAL_V11";
const PRIOR_PRESTOP_JOURNAL: &[u8] = b"OPENSTEAMER_MIGRATION_JOURNAL_V9\nSTATE BEGUN\nSTATE ROLLBACK_STARTED legacy_disable_was_journaled=false rollback_mode=BeforeLegacyStop\nSTATE LEGACY_REENABLED\nSTATE LEGACY_RECOVERED\nSTATE ROLLED_BACK\n";
const PRIOR_PRESTOP_RESULT: &[u8] = b"result=rolled-back-before-stop\nlegacy_launchd_disabled=false\nphysical_iphone_e2e=unavailable-not-claimed\n";
const PRIOR_JOURNAL_SHA256: &str =
    "566504aa212b4b4ae627996859991c0aa8742f9fa5019145a9e73ca9c6ddf524";
const PRIOR_RESULT_SHA256: &str =
    "d1e58fcd7c826e015fab662e5669abfdfa142f904fc3277c5cf62f754890f875";
const PRIOR_SOURCE_ARCHIVE_SIZE: u64 = 6_266_880;
const PRIOR_SOURCE_ARCHIVE_SHA256: &str =
    "0d0022af455d2d7a2d49c43025760ece421b9cdd0b33451fad55f338f9746202";
const PRIOR_SOURCE_COMMIT: &str = "2ef1c9cbb972c0c138ae36bbe996eacda214113d";
const APPLICATIONS_DIRECTORY: &str = "/Applications";
const APPLICATIONS_UID: u32 = 0;
const APPLICATIONS_GID: u32 = 80;
const APPLICATIONS_MODE: u32 = 0o775;
const PRIOR_V10_EVIDENCE_PATH: &str =
    "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v10-1785631164-7724";
const PRIOR_V10_ACTIVE_RECORD: &[u8] = b"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v10-1785631164-7724\n";
const PRIOR_V10_ACTIVE_SHA256: &str =
    "af917e5ca70f533d1e78b62cf7bda66a682d2fd61dc2d1e337615f52e44ac02a";
const PRIOR_V10_SOURCE_COMMIT: &str = "a0a25f7010a1170330ad7ebd48d0e85839219af4";
const PRIOR_V10_SOURCE_TREE: &str = "98c0c0d230aa89f56121916f0ef158cf8c0563b1";
const PRIOR_V10_FINAL_JOURNAL_SHA256: &str =
    "3d29812b215a1a765492ac76dd849454159170be618334ccfd08585c67371b0c";
const PRIOR_V10_FINAL_JOURNAL: &[u8] = br#"OPENSTEAMER_MIGRATION_JOURNAL_V10
STATE BEGUN
STATE BEGUN prior_v9_active_sha256=55c5936e520d65c2096811546357853e05064eca41553603793bea5843518559 prior_v9_journal_sha256=566504aa212b4b4ae627996859991c0aa8742f9fa5019145a9e73ca9c6ddf524 prior_v9_result_sha256=d1e58fcd7c826e015fab662e5669abfdfa142f904fc3277c5cf62f754890f875 prior_v9_source_archive_sha256=0d0022af455d2d7a2d49c43025760ece421b9cdd0b33451fad55f338f9746202 prior_v9_source_commit=2ef1c9cbb972c0c138ae36bbe996eacda214113d
STATE PROVENANCE_VERIFIED commit=a0a25f7010a1170330ad7ebd48d0e85839219af4 tree=98c0c0d230aa89f56121916f0ef158cf8c0563b1
STATE LEGACY_SNAPSHOTTED
STATE NEW_STAGED
STATE PRECUTOVER_VERIFIED
STATE LEGACY_DISABLED
STATE LEGACY_STOPPED
STATE LOCK_HANDED_OFF
STATE ROLLBACK_STARTED legacy_disable_was_journaled=true rollback_mode=FullRestore
STATE NEW_STOPPED
STATE CRITICAL_FAILURE primary=directory%20%27/Applications%27%20is%20group/world%20writable%20with%20mode%200775 rollback=directory%20%27/Applications%27%20is%20group/world%20writable%20with%20mode%200775
STATE ROLLBACK_STARTED legacy_disable_was_journaled=true rollback_mode=FullRestore
STATE NEW_STOPPED
STATE NEW_DESTINATIONS_CLEARED
STATE LEGACY_REENABLED
STATE LEGACY_BOOTSTRAPPED
STATE LEGACY_RECOVERED
STATE ROLLED_BACK
"#;
const PRIOR_V10_FINAL_RESULT: &[u8] = b"result=rolled-back\nlegacy_launchd_disabled=false\nphysical_iphone_e2e=unavailable-not-claimed\n";
const PRIOR_V10_FINAL_RESULT_SHA256: &str =
    "434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301";
const PRIOR_V10_SOURCE_ARCHIVE_SIZE: u64 = 6_287_360;
const PRIOR_V10_SOURCE_ARCHIVE_SHA256: &str =
    "b742d38f5e21f8febbc6a436112de633cc15e34be9ecd698915b3231a253acb3";
const PRIOR_V10_PROVENANCE_SHA256: &str =
    "7bea7b1f67a0a88467526b333e6a941302d160c8fe05393a3619ed398821bba6";
const PRIOR_V10_PROVENANCE: &[u8] = br#"commit=a0a25f7010a1170330ad7ebd48d0e85839219af4
tree=98c0c0d230aa89f56121916f0ef158cf8c0563b1
remote=https://github.com/ahmedelami/opensteamer.git
upstream=origin/agent/auto-select-iphone-microphone
source_archive_sha256=b742d38f5e21f8febbc6a436112de633cc15e34be9ecd698915b3231a253acb3
package_resolved_sha256=161213e9507513e41f0acba0d7439fcf633b9d03d78c22b1e4b15fa9f83a01d9
"#;
const PRIOR_V10_LEGACY_MANIFEST_SHA256: &str =
    "2bdaddf99c5101a8f994d3916b44a66f6c8fcbd3c0cda1b3ae44694263d6971f";
const PRIOR_V10_LEGACY_XATTRS_SHA256: &str =
    "cc69a330ffd8dcb92e45bfa1b2f7163f749b2c1875bc2ead51f9ed50dd252ea8";
const PRIOR_V10_STAGED_HASHES_SHA256: &str =
    "176c8c5e3523e8a7a97131fb414f2d27ae8c3d23ff33705e617eee8d34478ea8";
const PRIOR_V10_SOURCE_EXPORT_MANIFEST_SHA256: &str =
    "89964eeffb7787860c52ea2745a690d21fe98fe28cb9eec21a709f4f0b334b2c";
const PRIOR_V10_BUILD_STDOUT_SHA256: &str =
    "ef569e73e8b88e85c24c133dab6464473515f3c341e494a5bf77238be5d23fd4";
const PRIOR_V10_BUILD_STDERR_SHA256: &str =
    "f36f6e9ae4f5c5c1471669ff8bffd1b1882c2742578d26e0bb084eefb9b10b3c";
const PRIOR_V10_STAGED_EXECUTABLE_SHA256: &str =
    "0044981bbfffbe81a6403eb941d3a627890b4528fc45c8ff85c831bae9c53d53";
const PRIOR_V10_STAGED_PLIST_SHA256: &str =
    "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";
const CHFLAGS_SHA256: &str = "a67367c7fda2e962b72db6cc730173e82115f3709bf4a208d1d2ed1a6787a211";
const DITTO_SHA256: &str = "31a07d70d9ebea58b083e47d4fa380c1d5b8f7fe58ac3fefa9ce2714ca898ca6";
const EMBEDDED_BUILD_SCRIPT: &[u8] = include_bytes!("build-opensteamer-host-app.sh");
const EMBEDDED_BUILD_SCRIPT_SHA256: &str =
    "bda01b7ec76e5112a127fd97427fbff4a23c5d352232bed64d3cc93cf44e9619";
const EMBEDDED_BUNDLE_VERIFIER: &[u8] = include_bytes!("verify-mac-host-bundle.sh");
const EMBEDDED_BUNDLE_VERIFIER_SHA256: &str =
    "b667df23e06d55140a61e8b8e7c1de3a6aa5ebd6f4c4f063c805ddf98b5edc27";
const EMBEDDED_LAUNCH_VERIFIER: &[u8] = include_bytes!("verify-mac-host-launch-state.sh");
const EMBEDDED_LAUNCH_VERIFIER_SHA256: &str =
    "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
const EMBEDDED_DEPLOYMENT_VERIFIER: &[u8] = include_bytes!("verify-mac-host-deployment.sh");
const EMBEDDED_DEPLOYMENT_VERIFIER_SHA256: &str =
    "394960cffadf889adffc6fa9a8e54fd86820ef1e715b75c5d7889b6a09861893";
const EMBEDDED_LIVE_PROCESS_VERIFIER: &[u8] = include_bytes!("verify-live-mac-host-process.sh");
const EMBEDDED_LIVE_PROCESS_VERIFIER_SHA256: &str =
    "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
const REVIEWED_RUSTC_SHA256: &str =
    "d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd";
const REVIEWED_RUSTC_CDHASH_FULL: &str =
    "d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e";

#[cfg(target_os = "macos")]
const LOCK_EX: i32 = 0x02;
#[cfg(target_os = "macos")]
const LOCK_NB: i32 = 0x04;
#[cfg(target_os = "macos")]
const LOCK_UN: i32 = 0x08;
#[cfg(not(target_os = "macos"))]
const LOCK_EX: i32 = 2;
#[cfg(not(target_os = "macos"))]
const LOCK_NB: i32 = 4;
#[cfg(not(target_os = "macos"))]
const LOCK_UN: i32 = 8;

#[cfg(target_os = "macos")]
type ModeValue = u16;
#[cfg(not(target_os = "macos"))]
type ModeValue = u32;

#[cfg(target_os = "macos")]
const AT_FDCWD: i32 = -2;
#[cfg(target_os = "linux")]
const AT_FDCWD: i32 = -100;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const AT_FDCWD: i32 = -1;
#[cfg(target_os = "macos")]
const O_DIRECTORY_VALUE: i32 = 0x0010_0000;
#[cfg(target_os = "linux")]
const O_DIRECTORY_VALUE: i32 = 0x0001_0000;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const O_DIRECTORY_VALUE: i32 = 0;
#[cfg(target_os = "macos")]
const O_CLOEXEC_VALUE: i32 = 0x0100_0000;
#[cfg(target_os = "linux")]
const O_CLOEXEC_VALUE: i32 = 0x0008_0000;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const O_CLOEXEC_VALUE: i32 = 0;
#[cfg(target_os = "macos")]
const O_CREAT_VALUE: i32 = 0x0000_0200;
#[cfg(target_os = "linux")]
const O_CREAT_VALUE: i32 = 0x0000_0040;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const O_CREAT_VALUE: i32 = 0;
#[cfg(target_os = "macos")]
const O_EXCL_VALUE: i32 = 0x0000_0800;
#[cfg(target_os = "linux")]
const O_EXCL_VALUE: i32 = 0x0000_0080;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const O_EXCL_VALUE: i32 = 0;
const O_RDONLY_VALUE: i32 = 0;
const O_RDWR_VALUE: i32 = 2;
const W_OK_VALUE: i32 = 2;
const X_OK_VALUE: i32 = 1;
#[cfg(target_os = "macos")]
const O_NONBLOCK_VALUE: i32 = 0x0000_0004;
#[cfg(target_os = "linux")]
const O_NONBLOCK_VALUE: i32 = 0x0000_0800;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const O_NONBLOCK_VALUE: i32 = 0;
#[cfg(target_os = "macos")]
const RENAME_EXCL_VALUE: u32 = 0x0000_0004;
#[cfg(target_os = "linux")]
const RENAME_EXCL_VALUE: u32 = 0x0000_0001;
#[cfg(target_os = "macos")]
const F_PREALLOCATE_VALUE: i32 = 42;
#[cfg(target_os = "macos")]
const F_ALLOCATECONTIG_VALUE: u32 = 0x0000_0002;
#[cfg(target_os = "macos")]
const F_ALLOCATEALL_VALUE: u32 = 0x0000_0004;
#[cfg(target_os = "macos")]
const F_PEOFPOSMODE_VALUE: i32 = 3;

#[cfg(target_os = "macos")]
#[repr(C)]
struct FStore {
    flags: u32,
    posmode: i32,
    offset: i64,
    length: i64,
    bytes_allocated: i64,
}

extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
    fn geteuid() -> u32;
    fn openat(dirfd: i32, path: *const i8, flags: i32, ...) -> i32;
    fn mkdirat(dirfd: i32, path: *const i8, mode: ModeValue) -> i32;
    fn faccessat(dirfd: i32, path: *const i8, mode: i32, flags: i32) -> i32;
    fn setpgid(pid: i32, pgid: i32) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
    fn fcntl(fd: i32, command: i32, ...) -> i32;
}

#[cfg(target_os = "macos")]
extern "C" {
    fn renameatx_np(
        old_dir_fd: i32,
        old_path: *const i8,
        new_dir_fd: i32,
        new_path: *const i8,
        flags: u32,
    ) -> i32;
}

#[cfg(target_os = "linux")]
extern "C" {
    fn renameat2(
        old_dir_fd: i32,
        old_path: *const i8,
        new_dir_fd: i32,
        new_path: *const i8,
        flags: u32,
    ) -> i32;
}

#[derive(Debug)]
struct ControllerError(String);

type Result<T> = std::result::Result<T, ControllerError>;

impl From<io::Error> for ControllerError {
    fn from(error: io::Error) -> Self {
        Self(error.to_string())
    }
}

impl std::fmt::Display for ControllerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Debug)]
struct PinnedDirectory {
    path: PathBuf,
    file: File,
    device: u64,
    inode: u64,
    expected_uid: Option<u32>,
    expected_gid: Option<u32>,
    expected_mode: Option<u32>,
}

fn directory_write_policy_allows(
    path: &Path,
    actual_uid: u32,
    actual_gid: u32,
    actual_mode: u32,
    expected_uid: Option<u32>,
    expected_gid: Option<u32>,
    expected_mode: Option<u32>,
) -> bool {
    if actual_mode & 0o002 != 0 {
        return false;
    }
    if actual_mode & 0o020 == 0 {
        return true;
    }
    path == Path::new(APPLICATIONS_DIRECTORY)
        && actual_uid == APPLICATIONS_UID
        && actual_gid == APPLICATIONS_GID
        && actual_mode == APPLICATIONS_MODE
        && expected_uid == Some(APPLICATIONS_UID)
        && expected_gid == Some(APPLICATIONS_GID)
        && expected_mode == Some(APPLICATIONS_MODE)
}

impl PinnedDirectory {
    fn open(path: &Path, expected_uid: Option<u32>, expected_mode: Option<u32>) -> Result<Self> {
        Self::open_with_policy(path, expected_uid, None, expected_mode)
    }

    fn open_applications() -> Result<Self> {
        Self::open_with_policy(
            Path::new(APPLICATIONS_DIRECTORY),
            Some(APPLICATIONS_UID),
            Some(APPLICATIONS_GID),
            Some(APPLICATIONS_MODE),
        )
    }

    fn open_with_policy(
        path: &Path,
        expected_uid: Option<u32>,
        expected_gid: Option<u32>,
        expected_mode: Option<u32>,
    ) -> Result<Self> {
        let before = fs::symlink_metadata(path).map_err(|error| {
            ControllerError(format!(
                "cannot inspect directory '{}': {error}",
                path.display()
            ))
        })?;
        Self::validate_metadata(path, &before, expected_uid, expected_gid, expected_mode)?;
        let name = path_cstring(path)?;
        // SAFETY: `name` is a valid NUL-terminated path and flags request a directory without
        // following a final-component symbolic link.
        let descriptor = unsafe {
            openat(
                AT_FDCWD,
                name.as_ptr(),
                O_RDONLY_VALUE | O_DIRECTORY_VALUE | O_CLOEXEC_VALUE | libc_o_nofollow(),
            )
        };
        if descriptor < 0 {
            return Err(ControllerError(format!(
                "cannot pin directory '{}': {}",
                path.display(),
                io::Error::last_os_error()
            )));
        }
        // SAFETY: `descriptor` was returned by openat and ownership transfers to `File`.
        let file = unsafe { File::from_raw_fd(descriptor) };
        let opened = file.metadata()?;
        Self::validate_metadata(path, &opened, expected_uid, expected_gid, expected_mode)?;
        if !same_inode(&before, &opened) {
            return Err(ControllerError(format!(
                "directory changed while opening: {}",
                path.display()
            )));
        }
        let canonical = fs::canonicalize(path)?;
        if canonical != path {
            return Err(ControllerError(format!(
                "directory path is not canonical: {}",
                path.display()
            )));
        }
        Ok(Self {
            path: path.to_path_buf(),
            file,
            device: opened.dev(),
            inode: opened.ino(),
            expected_uid,
            expected_gid,
            expected_mode,
        })
    }

    fn open_or_create_private_root() -> Result<Self> {
        let application_support = Path::new("/Users/ahmed/Library/Application Support");
        let parent = Self::open(application_support, Some(effective_uid()), None)?;
        if let Some(directory) =
            parent.try_open_directory_child("opensteamer", Some(effective_uid()), Some(0o700))?
        {
            return Ok(directory);
        }
        let child_name = CString::new("opensteamer").expect("literal has no NUL");
        // SAFETY: the parent descriptor is pinned and the child name is a valid C string.
        let result =
            unsafe { mkdirat(parent.as_raw_fd(), child_name.as_ptr(), 0o700 as ModeValue) };
        if result != 0 {
            let creation_error = io::Error::last_os_error();
            if creation_error.kind() != io::ErrorKind::AlreadyExists {
                return Err(ControllerError(format!(
                    "cannot create private opensteamer directory: {creation_error}"
                )));
            }
        }
        parent
            .try_open_directory_child("opensteamer", Some(effective_uid()), Some(0o700))?
            .ok_or_else(|| {
                ControllerError(
                    "private opensteamer directory disappeared after creation".to_owned(),
                )
            })
    }

    fn try_open_directory_child(
        &self,
        name: &str,
        expected_uid: Option<u32>,
        expected_mode: Option<u32>,
    ) -> Result<Option<Self>> {
        self.revalidate()?;
        let name_c = CString::new(name)
            .map_err(|_| ControllerError("directory child contains a NUL byte".to_owned()))?;
        // SAFETY: parent descriptor and child C string are valid.
        let descriptor = unsafe {
            openat(
                self.as_raw_fd(),
                name_c.as_ptr(),
                O_RDONLY_VALUE | O_DIRECTORY_VALUE | O_CLOEXEC_VALUE | libc_o_nofollow(),
            )
        };
        if descriptor < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::NotFound {
                return Ok(None);
            }
            return Err(ControllerError(format!(
                "cannot open pinned child directory '{}': {error}",
                self.path.join(name).display()
            )));
        }
        // SAFETY: ownership of the valid descriptor transfers to File.
        let file = unsafe { File::from_raw_fd(descriptor) };
        let metadata = file.metadata()?;
        let child_path = self.path.join(name);
        Self::validate_metadata(&child_path, &metadata, expected_uid, None, expected_mode)?;
        let current = fs::symlink_metadata(&child_path)?;
        Self::validate_metadata(&child_path, &current, expected_uid, None, expected_mode)?;
        if !same_inode(&metadata, &current) {
            return Err(ControllerError(format!(
                "child directory changed while opening: {}",
                child_path.display()
            )));
        }
        Ok(Some(Self {
            path: child_path,
            device: metadata.dev(),
            inode: metadata.ino(),
            file,
            expected_uid,
            expected_gid: None,
            expected_mode,
        }))
    }

    fn validate_metadata(
        path: &Path,
        metadata: &Metadata,
        expected_uid: Option<u32>,
        expected_gid: Option<u32>,
        expected_mode: Option<u32>,
    ) -> Result<()> {
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(ControllerError(format!(
                "path is not a real directory: {}",
                path.display()
            )));
        }
        if let Some(uid) = expected_uid {
            if metadata.uid() != uid {
                return Err(ControllerError(format!(
                    "directory '{}' is owned by uid {}, expected {uid}",
                    path.display(),
                    metadata.uid()
                )));
            }
        }
        if let Some(gid) = expected_gid {
            if metadata.gid() != gid {
                return Err(ControllerError(format!(
                    "directory '{}' is owned by gid {}, expected {gid}",
                    path.display(),
                    metadata.gid()
                )));
            }
        }
        let actual_mode = metadata.permissions().mode() & 0o7777;
        if !directory_write_policy_allows(
            path,
            metadata.uid(),
            metadata.gid(),
            actual_mode,
            expected_uid,
            expected_gid,
            expected_mode,
        ) {
            return Err(ControllerError(format!(
                "directory '{}' is group/world writable with mode {:04o}",
                path.display(),
                actual_mode
            )));
        }
        if let Some(mode) = expected_mode {
            if actual_mode != mode {
                return Err(ControllerError(format!(
                    "directory '{}' has mode {:04o}, expected {:04o}",
                    path.display(),
                    actual_mode,
                    mode
                )));
            }
        }
        Ok(())
    }

    fn revalidate(&self) -> Result<()> {
        let current = fs::symlink_metadata(&self.path)?;
        Self::validate_metadata(
            &self.path,
            &current,
            self.expected_uid,
            self.expected_gid,
            self.expected_mode,
        )?;
        if current.dev() != self.device || current.ino() != self.inode {
            return Err(ControllerError(format!(
                "pinned directory path was replaced: {}",
                self.path.display()
            )));
        }
        let reopened = Self::open_with_policy(
            &self.path,
            self.expected_uid,
            self.expected_gid,
            self.expected_mode,
        )?;
        if reopened.device != self.device || reopened.inode != self.inode {
            return Err(ControllerError(format!(
                "pinned directory identity changed: {}",
                self.path.display()
            )));
        }
        Ok(())
    }

    fn prove_write_execute_and_sync(&self) -> Result<()> {
        self.revalidate()?;
        let current_directory = CString::new(".").expect("literal has no NUL");
        // SAFETY: the directory descriptor and constant NUL-terminated relative path are valid.
        if unsafe {
            faccessat(
                self.as_raw_fd(),
                current_directory.as_ptr(),
                W_OK_VALUE | X_OK_VALUE,
                0,
            )
        } != 0
        {
            return Err(ControllerError(format!(
                "destination directory is not writable/searchable: {}: {}",
                self.path.display(),
                io::Error::last_os_error()
            )));
        }
        self.file.sync_all()?;
        self.revalidate()
    }

    fn as_raw_fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }

    fn ensure_file_at_name(&self, name: &str, opened: &File) -> Result<()> {
        self.revalidate()?;
        let name_c = CString::new(name)
            .map_err(|_| ControllerError("file name contains a NUL byte".to_owned()))?;
        // SAFETY: the pinned parent descriptor and C string are valid.
        let descriptor = unsafe {
            openat(
                self.as_raw_fd(),
                name_c.as_ptr(),
                O_RDONLY_VALUE | O_CLOEXEC_VALUE | O_NONBLOCK_VALUE | libc_o_nofollow(),
            )
        };
        if descriptor < 0 {
            return Err(ControllerError(format!(
                "file entry '{}' changed while opening: {}",
                self.path.join(name).display(),
                io::Error::last_os_error()
            )));
        }
        // SAFETY: ownership of the new descriptor transfers to File.
        let current = unsafe { File::from_raw_fd(descriptor) };
        let current_metadata = current.metadata()?;
        validate_regular_metadata(&self.path.join(name), &current_metadata)?;
        let opened_metadata = opened.metadata()?;
        if !same_inode(&opened_metadata, &current_metadata) {
            return Err(ControllerError(format!(
                "file entry was substituted: {}",
                self.path.join(name).display()
            )));
        }
        self.revalidate()
    }

    fn open_existing_regular(&self, name: &str, writable: bool) -> Result<Option<File>> {
        self.revalidate()?;
        let name_c = CString::new(name)
            .map_err(|_| ControllerError("file name contains a NUL byte".to_owned()))?;
        let access = if writable {
            O_RDWR_VALUE
        } else {
            O_RDONLY_VALUE
        };
        // SAFETY: parent descriptor and C string are valid.
        let descriptor = unsafe {
            openat(
                self.as_raw_fd(),
                name_c.as_ptr(),
                access | O_CLOEXEC_VALUE | O_NONBLOCK_VALUE | libc_o_nofollow(),
            )
        };
        if descriptor < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::NotFound {
                return Ok(None);
            }
            return Err(ControllerError(format!(
                "cannot open '{}': {error}",
                self.path.join(name).display()
            )));
        }
        // SAFETY: ownership transfers to File.
        let file = unsafe { File::from_raw_fd(descriptor) };
        let metadata = file.metadata()?;
        validate_regular_metadata(&self.path.join(name), &metadata)?;
        self.ensure_file_at_name(name, &file)?;
        Ok(Some(file))
    }

    fn create_new_regular(&self, name: &str, mode: u32) -> Result<File> {
        self.revalidate()?;
        let name_c = CString::new(name)
            .map_err(|_| ControllerError("file name contains a NUL byte".to_owned()))?;
        // SAFETY: parent descriptor and C string are valid.
        let descriptor = unsafe {
            openat(
                self.as_raw_fd(),
                name_c.as_ptr(),
                O_RDWR_VALUE | O_CREAT_VALUE | O_EXCL_VALUE | O_CLOEXEC_VALUE | libc_o_nofollow(),
                mode,
            )
        };
        if descriptor < 0 {
            return Err(ControllerError(format!(
                "cannot exclusively create '{}': {}",
                self.path.join(name).display(),
                io::Error::last_os_error()
            )));
        }
        // SAFETY: ownership transfers to File.
        let file = unsafe { File::from_raw_fd(descriptor) };
        let metadata = file.metadata()?;
        validate_regular_metadata(&self.path.join(name), &metadata)?;
        self.ensure_file_at_name(name, &file)?;
        file.set_permissions(Permissions::from_mode(mode))?;
        let secured = file.metadata()?;
        validate_owned_regular(&self.path.join(name), &secured, mode)?;
        self.ensure_file_at_name(name, &file)?;
        Ok(file)
    }

    fn rename_exclusive(&self, source: &str, destination: &str) -> Result<()> {
        self.revalidate()?;
        let source_c = CString::new(source)
            .map_err(|_| ControllerError("source name contains a NUL byte".to_owned()))?;
        let destination_c = CString::new(destination)
            .map_err(|_| ControllerError("destination name contains a NUL byte".to_owned()))?;
        #[cfg(target_os = "macos")]
        let result = {
            // SAFETY: descriptors and C strings are valid.
            unsafe {
                renameatx_np(
                    self.as_raw_fd(),
                    source_c.as_ptr(),
                    self.as_raw_fd(),
                    destination_c.as_ptr(),
                    RENAME_EXCL_VALUE,
                )
            }
        };
        #[cfg(target_os = "linux")]
        let result = {
            // SAFETY: descriptors and C strings are valid.
            unsafe {
                renameat2(
                    self.as_raw_fd(),
                    source_c.as_ptr(),
                    self.as_raw_fd(),
                    destination_c.as_ptr(),
                    RENAME_EXCL_VALUE,
                )
            }
        };
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let result = -1;
        if result != 0 {
            return Err(ControllerError(format!(
                "cannot exclusively publish '{}' as '{}': {}",
                source,
                destination,
                io::Error::last_os_error()
            )));
        }
        self.file.sync_all()?;
        self.revalidate()
    }
}

struct PinnedSystemTool {
    path: PathBuf,
    file: File,
    device: u64,
    inode: u64,
    expected_sha256: &'static str,
}

impl PinnedSystemTool {
    fn open(path: &Path, expected_sha256: &'static str) -> Result<Self> {
        let before = fs::symlink_metadata(path)?;
        Self::validate_metadata(path, &before)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
            .open(path)?;
        let opened = file.metadata()?;
        Self::validate_metadata(path, &opened)?;
        if !same_inode(&before, &opened) || sha256_file(path)? != expected_sha256 {
            return Err(ControllerError(format!(
                "reviewed system tool changed while pinning: {}",
                path.display()
            )));
        }
        Ok(Self {
            path: path.to_path_buf(),
            file,
            device: opened.dev(),
            inode: opened.ino(),
            expected_sha256,
        })
    }

    fn validate_metadata(path: &Path, metadata: &Metadata) -> Result<()> {
        if metadata.file_type().is_symlink()
            || !metadata.is_file()
            || metadata.uid() != 0
            || metadata.gid() != 0
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o7777 != 0o755
        {
            return Err(ControllerError(format!(
                "reviewed system tool identity or mode is unsafe: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn revalidate(&self) -> Result<()> {
        let current = fs::symlink_metadata(&self.path)?;
        let opened = self.file.metadata()?;
        Self::validate_metadata(&self.path, &current)?;
        Self::validate_metadata(&self.path, &opened)?;
        if current.dev() != self.device
            || current.ino() != self.inode
            || !same_inode(&current, &opened)
            || sha256_file(&self.path)? != self.expected_sha256
        {
            return Err(ControllerError(format!(
                "reviewed system tool changed after preflight: {}",
                self.path.display()
            )));
        }
        Ok(())
    }
}

struct PinnedScript {
    name: &'static str,
    logical_path: PathBuf,
    file: File,
    device: u64,
    inode: u64,
    expected: &'static [u8],
    text: String,
}

impl PinnedScript {
    fn open(
        scripts_directory: &PinnedDirectory,
        name: &'static str,
        expected: &'static [u8],
    ) -> Result<Self> {
        let file = scripts_directory
            .open_existing_regular(name, false)?
            .ok_or_else(|| ControllerError(format!("pinned script is missing: {name}")))?;
        let logical_path = scripts_directory.path.join(name);
        let metadata = file.metadata()?;
        validate_pinned_script_metadata(&logical_path, &metadata)?;
        let bytes = read_pinned_script_bytes(&file, &logical_path)?;
        if bytes != expected {
            return Err(ControllerError(format!(
                "source-export script differs from the bytes embedded in the attested controller: {}",
                logical_path.display()
            )));
        }
        let text = String::from_utf8(bytes)
            .map_err(|_| ControllerError(format!("pinned script is not UTF-8: {name}")))?;
        if text.as_bytes().contains(&0) {
            return Err(ControllerError(format!(
                "pinned script contains a NUL byte: {name}"
            )));
        }
        scripts_directory.ensure_file_at_name(name, &file)?;
        Ok(Self {
            name,
            logical_path,
            file,
            device: metadata.dev(),
            inode: metadata.ino(),
            expected,
            text,
        })
    }

    fn revalidate(&self, scripts_directory: &PinnedDirectory) -> Result<()> {
        scripts_directory.ensure_file_at_name(self.name, &self.file)?;
        let opened = self.file.metadata()?;
        validate_pinned_script_metadata(&self.logical_path, &opened)?;
        if opened.dev() != self.device
            || opened.ino() != self.inode
            || read_pinned_script_bytes(&self.file, &self.logical_path)? != self.expected
        {
            return Err(ControllerError(format!(
                "pinned script changed after attestation: {}",
                self.logical_path.display()
            )));
        }
        scripts_directory.ensure_file_at_name(self.name, &self.file)
    }
}

fn validate_pinned_script_metadata(path: &Path, metadata: &Metadata) -> Result<()> {
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o022 != 0
        || metadata.permissions().mode() & 0o111 == 0
        || metadata.len() == 0
        || metadata.len() > MAX_PINNED_SCRIPT_BYTES
    {
        return Err(ControllerError(format!(
            "pinned script metadata is unsafe: {}",
            path.display()
        )));
    }
    Ok(())
}

fn read_pinned_script_bytes(file: &File, path: &Path) -> Result<Vec<u8>> {
    let before = file.metadata()?;
    validate_pinned_script_metadata(path, &before)?;
    let mut reader = file.try_clone()?;
    reader.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    reader
        .take(MAX_PINNED_SCRIPT_BYTES + 1)
        .read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    validate_pinned_script_metadata(path, &after)?;
    if !same_inode(&before, &after)
        || before.len() != after.len()
        || bytes.len() as u64 != after.len()
    {
        return Err(ControllerError(format!(
            "pinned script changed while being read: {}",
            path.display()
        )));
    }
    Ok(bytes)
}

struct PinnedVerifierSet {
    source_export: PinnedDirectory,
    macos_directory: PinnedDirectory,
    scripts_directory: PinnedDirectory,
    records: PinnedDirectory,
    source_manifest: File,
    build: PinnedScript,
    bundle: PinnedScript,
    launch: PinnedScript,
    deployment: PinnedScript,
    live_process: PinnedScript,
}

impl PinnedVerifierSet {
    fn open(layout: &Layout) -> Result<Self> {
        verify_embedded_verifier_hashes()?;
        let source_export =
            PinnedDirectory::open(&layout.source_export, Some(effective_uid()), Some(0o700))?;
        let macos_directory = source_export
            .try_open_directory_child("macOS", Some(effective_uid()), Some(0o700))?
            .ok_or_else(|| ControllerError("source export lacks macOS directory".to_owned()))?;
        let scripts_directory = macos_directory
            .try_open_directory_child("scripts", Some(effective_uid()), Some(0o700))?
            .ok_or_else(|| ControllerError("source export lacks scripts directory".to_owned()))?;
        let records = PinnedDirectory::open(&layout.records, Some(effective_uid()), Some(0o700))?;
        let source_manifest =
            open_required_pinned_regular(&records, "source-export-manifest.txt", 0o600)?;
        let set = Self {
            build: PinnedScript::open(
                &scripts_directory,
                "build-opensteamer-host-app.sh",
                EMBEDDED_BUILD_SCRIPT,
            )?,
            bundle: PinnedScript::open(
                &scripts_directory,
                "verify-mac-host-bundle.sh",
                EMBEDDED_BUNDLE_VERIFIER,
            )?,
            launch: PinnedScript::open(
                &scripts_directory,
                "verify-mac-host-launch-state.sh",
                EMBEDDED_LAUNCH_VERIFIER,
            )?,
            deployment: PinnedScript::open(
                &scripts_directory,
                "verify-mac-host-deployment.sh",
                EMBEDDED_DEPLOYMENT_VERIFIER,
            )?,
            live_process: PinnedScript::open(
                &scripts_directory,
                "verify-live-mac-host-process.sh",
                EMBEDDED_LIVE_PROCESS_VERIFIER,
            )?,
            source_export,
            macos_directory,
            scripts_directory,
            records,
            source_manifest,
        };
        set.revalidate()?;
        Ok(set)
    }

    fn revalidate(&self) -> Result<()> {
        self.source_export.revalidate()?;
        self.macos_directory.revalidate()?;
        self.scripts_directory.revalidate()?;
        self.records
            .ensure_file_at_name("source-export-manifest.txt", &self.source_manifest)?;
        let recorded_manifest = read_opened_regular(
            &self.source_manifest,
            &self.records.path.join("source-export-manifest.txt"),
            0o600,
        )?;
        if tree_manifest(&self.source_export.path)?.as_bytes() != recorded_manifest {
            return Err(ControllerError(
                "source export changed after immutable-manifest attestation".to_owned(),
            ));
        }
        for script in [
            &self.build,
            &self.bundle,
            &self.launch,
            &self.deployment,
            &self.live_process,
        ] {
            script.revalidate(&self.scripts_directory)?;
        }
        self.source_export.revalidate()
    }

    fn add_helper_environment(&self, environment: &mut BTreeMap<String, String>) {
        environment.insert(
            "OPENSTEAMER_PINNED_BUNDLE_VERIFIER_SCRIPT".to_owned(),
            self.bundle.text.clone(),
        );
        environment.insert(
            "OPENSTEAMER_PINNED_LAUNCH_STATE_VERIFIER_SCRIPT".to_owned(),
            self.launch.text.clone(),
        );
        environment.insert(
            "OPENSTEAMER_PINNED_LIVE_PROCESS_VERIFIER_SCRIPT".to_owned(),
            self.live_process.text.clone(),
        );
    }
}

fn verify_embedded_verifier_hashes() -> Result<()> {
    for (label, bytes, expected) in [
        (
            "build verifier",
            EMBEDDED_BUILD_SCRIPT,
            EMBEDDED_BUILD_SCRIPT_SHA256,
        ),
        (
            "bundle verifier",
            EMBEDDED_BUNDLE_VERIFIER,
            EMBEDDED_BUNDLE_VERIFIER_SHA256,
        ),
        (
            "launch verifier",
            EMBEDDED_LAUNCH_VERIFIER,
            EMBEDDED_LAUNCH_VERIFIER_SHA256,
        ),
        (
            "deployment verifier",
            EMBEDDED_DEPLOYMENT_VERIFIER,
            EMBEDDED_DEPLOYMENT_VERIFIER_SHA256,
        ),
        (
            "live-process verifier",
            EMBEDDED_LIVE_PROCESS_VERIFIER,
            EMBEDDED_LIVE_PROCESS_VERIFIER_SHA256,
        ),
    ] {
        if sha256_bytes(bytes)? != expected {
            return Err(ControllerError(format!(
                "embedded {label} bytes differ from the reviewed controller trust anchor"
            )));
        }
    }
    Ok(())
}

fn validate_regular_metadata(path: &Path, metadata: &Metadata) -> Result<()> {
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
    {
        return Err(ControllerError(format!(
            "unsafe regular file: {}",
            path.display()
        )));
    }
    Ok(())
}

fn path_cstring(path: &Path) -> Result<CString> {
    CString::new(path.as_os_str().as_bytes())
        .map_err(|_| ControllerError(format!("path contains a NUL byte: {}", path.display())))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State {
    Begun,
    ProvenanceVerified,
    LegacySnapshotted,
    NewStaged,
    PrecutoverVerified,
    LegacyDisabled,
    LegacyStopped,
    LockHandedOff,
    NewInstalled,
    NewBootstrapped,
    NewPidObserved,
    ReadyVerified,
    Committed,
    CommittedRecoveryStarted,
    CommittedRecoveryBootstrapped,
    CommittedRecoveryReady,
    RollbackStarted,
    NewStopped,
    NewDestinationsCleared,
    LegacyReenabled,
    LegacyBootstrapped,
    LegacyRecovered,
    RolledBack,
    CriticalFailure,
}

impl State {
    fn as_str(self) -> &'static str {
        match self {
            Self::Begun => "BEGUN",
            Self::ProvenanceVerified => "PROVENANCE_VERIFIED",
            Self::LegacySnapshotted => "LEGACY_SNAPSHOTTED",
            Self::NewStaged => "NEW_STAGED",
            Self::PrecutoverVerified => "PRECUTOVER_VERIFIED",
            Self::LegacyDisabled => "LEGACY_DISABLED",
            Self::LegacyStopped => "LEGACY_STOPPED",
            Self::LockHandedOff => "LOCK_HANDED_OFF",
            Self::NewInstalled => "NEW_INSTALLED",
            Self::NewBootstrapped => "NEW_BOOTSTRAPPED",
            Self::NewPidObserved => "NEW_PID_OBSERVED",
            Self::ReadyVerified => "READY_VERIFIED",
            Self::Committed => "COMMITTED",
            Self::CommittedRecoveryStarted => "COMMITTED_RECOVERY_STARTED",
            Self::CommittedRecoveryBootstrapped => "COMMITTED_RECOVERY_BOOTSTRAPPED",
            Self::CommittedRecoveryReady => "COMMITTED_RECOVERY_READY",
            Self::RollbackStarted => "ROLLBACK_STARTED",
            Self::NewStopped => "NEW_STOPPED",
            Self::NewDestinationsCleared => "NEW_DESTINATIONS_CLEARED",
            Self::LegacyReenabled => "LEGACY_REENABLED",
            Self::LegacyBootstrapped => "LEGACY_BOOTSTRAPPED",
            Self::LegacyRecovered => "LEGACY_RECOVERED",
            Self::RolledBack => "ROLLED_BACK",
            Self::CriticalFailure => "CRITICAL_FAILURE",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "BEGUN" => Self::Begun,
            "PROVENANCE_VERIFIED" => Self::ProvenanceVerified,
            "LEGACY_SNAPSHOTTED" => Self::LegacySnapshotted,
            "NEW_STAGED" => Self::NewStaged,
            "PRECUTOVER_VERIFIED" => Self::PrecutoverVerified,
            "LEGACY_DISABLED" => Self::LegacyDisabled,
            "LEGACY_STOPPED" => Self::LegacyStopped,
            "LOCK_HANDED_OFF" => Self::LockHandedOff,
            "NEW_INSTALLED" => Self::NewInstalled,
            "NEW_BOOTSTRAPPED" => Self::NewBootstrapped,
            "NEW_PID_OBSERVED" => Self::NewPidObserved,
            "READY_VERIFIED" => Self::ReadyVerified,
            "COMMITTED" => Self::Committed,
            "COMMITTED_RECOVERY_STARTED" => Self::CommittedRecoveryStarted,
            "COMMITTED_RECOVERY_BOOTSTRAPPED" => Self::CommittedRecoveryBootstrapped,
            "COMMITTED_RECOVERY_READY" => Self::CommittedRecoveryReady,
            "ROLLBACK_STARTED" => Self::RollbackStarted,
            "NEW_STOPPED" => Self::NewStopped,
            "NEW_DESTINATIONS_CLEARED" => Self::NewDestinationsCleared,
            "LEGACY_REENABLED" => Self::LegacyReenabled,
            "LEGACY_BOOTSTRAPPED" => Self::LegacyBootstrapped,
            "LEGACY_RECOVERED" => Self::LegacyRecovered,
            "ROLLED_BACK" => Self::RolledBack,
            "CRITICAL_FAILURE" => Self::CriticalFailure,
            _ => return None,
        })
    }

    fn is_committed_family(self) -> bool {
        matches!(
            self,
            Self::Committed
                | Self::CommittedRecoveryStarted
                | Self::CommittedRecoveryBootstrapped
                | Self::CommittedRecoveryReady
        )
    }

    fn requires_rollback(self) -> bool {
        !self.is_committed_family() && !matches!(self, Self::RolledBack | Self::CriticalFailure)
    }
}

struct TransactionLock {
    file: File,
    parent: PinnedDirectory,
}

impl TransactionLock {
    fn acquire() -> Result<Self> {
        let parent = PinnedDirectory::open_or_create_private_root()?;
        let name = "migration-controller.lock".to_owned();
        let mut file = match parent.open_existing_regular(&name, true)? {
            Some(existing) => {
                let metadata = existing.metadata()?;
                validate_recoverable_owned_regular(
                    &Path::new(PRIVATE_ROOT).join(&name),
                    &metadata,
                    0o600,
                )?;
                existing.set_permissions(Permissions::from_mode(0o600))?;
                existing
            }
            None => match parent.create_new_regular(&name, 0o600) {
                Ok(created) => created,
                Err(create_error) => match parent.open_existing_regular(&name, true)? {
                    Some(raced) => {
                        let metadata = raced.metadata()?;
                        validate_recoverable_owned_regular(
                            &Path::new(PRIVATE_ROOT).join(&name),
                            &metadata,
                            0o600,
                        )?;
                        raced.set_permissions(Permissions::from_mode(0o600))?;
                        raced
                    }
                    None => return Err(create_error),
                },
            },
        };
        let opened = file.metadata()?;
        validate_owned_regular(&Path::new(PRIVATE_ROOT).join(&name), &opened, 0o600)?;
        parent.ensure_file_at_name(&name, &file)?;
        // SAFETY: flock is called with a valid open file descriptor.
        let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if result != 0 {
            let error = io::Error::last_os_error();
            if matches!(error.raw_os_error(), Some(11) | Some(35)) {
                return Err(ControllerError(
                    "another opensteamer migration controller holds the transaction lock"
                        .to_owned(),
                ));
            }
            return Err(ControllerError(format!(
                "cannot acquire transaction lock: {error}"
            )));
        }
        parent.ensure_file_at_name(&name, &file)?;
        file.seek(SeekFrom::Start(0))?;
        file.set_len(0)?;
        writeln!(file, "pid={}", process::id())?;
        file.sync_all()?;
        parent.file.sync_all()?;
        parent.revalidate()?;
        Ok(Self { file, parent })
    }

    fn parent(&self) -> &PinnedDirectory {
        &self.parent
    }
}

impl Drop for TransactionLock {
    fn drop(&mut self) {
        // SAFETY: the descriptor remains valid until `file` is dropped after this method.
        let _ = unsafe { flock(self.file.as_raw_fd(), LOCK_UN) };
        let _ = self.file.sync_all();
    }
}

struct Journal {
    path: PathBuf,
    file: File,
    state: State,
    saw_legacy_disabled: bool,
    saw_legacy_stopped: bool,
    fields: BTreeMap<String, String>,
}

impl Journal {
    fn create(path: &Path) -> Result<Self> {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
            .open(path)
            .map_err(|error| ControllerError(format!("cannot create journal: {error}")))?;
        let created = file.metadata()?;
        validate_regular_metadata(path, &created)?;
        file.set_permissions(Permissions::from_mode(0o600))?;
        validate_owned_regular(path, &file.metadata()?, 0o600)?;
        writeln!(file, "{JOURNAL_VERSION}")?;
        file.sync_all()?;
        sync_parent(path)?;
        let mut journal = Self {
            path: path.to_path_buf(),
            file,
            state: State::Begun,
            saw_legacy_disabled: false,
            saw_legacy_stopped: false,
            fields: BTreeMap::new(),
        };
        journal.transition(State::Begun, &[])?;
        Ok(journal)
    }

    fn open(path: &Path) -> Result<Self> {
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| ControllerError(format!("cannot inspect journal: {error}")))?;
        validate_recoverable_owned_regular(path, &metadata, 0o600)?;
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
            .open(path)?;
        let opened_before_chmod = file.metadata()?;
        validate_recoverable_owned_regular(path, &opened_before_chmod, 0o600)?;
        if !same_inode(&metadata, &opened_before_chmod) {
            return Err(ControllerError("journal changed while opening".to_owned()));
        }
        file.set_permissions(Permissions::from_mode(0o600))?;
        let opened = file.metadata()?;
        validate_owned_regular(path, &opened, 0o600)?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        let last_newline = bytes.iter().rposition(|byte| *byte == b'\n');
        let valid_length = last_newline.map_or(0, |index| index + 1);
        if valid_length != bytes.len() {
            file.set_len(valid_length as u64)?;
            file.sync_all()?;
            bytes.truncate(valid_length);
        }
        let text = String::from_utf8(bytes)
            .map_err(|_| ControllerError("journal is not UTF-8".to_owned()))?;
        if text.is_empty() {
            file.seek(SeekFrom::Start(0))?;
            file.write_all(format!("{JOURNAL_VERSION}\nSTATE BEGUN\n").as_bytes())?;
            file.sync_all()?;
            sync_parent(path)?;
            file.seek(SeekFrom::End(0))?;
            return Ok(Self {
                path: path.to_path_buf(),
                file,
                state: State::Begun,
                saw_legacy_disabled: false,
                saw_legacy_stopped: false,
                fields: BTreeMap::new(),
            });
        }
        let mut lines = text.lines();
        if lines.next() != Some(JOURNAL_VERSION) {
            return Err(ControllerError("journal version is invalid".to_owned()));
        }
        let mut state = None;
        let mut saw_legacy_disabled = false;
        let mut saw_legacy_stopped = false;
        let mut fields = BTreeMap::new();
        for line in lines {
            if let Some(value) = line.strip_prefix("STATE ") {
                let mut parts = value.split_whitespace();
                let token = parts.next().unwrap_or_default();
                let parsed = State::parse(token).ok_or_else(|| {
                    ControllerError(format!("journal contains unknown state '{token}'"))
                })?;
                state = Some(parsed);
                if matches!(
                    parsed,
                    State::LegacyDisabled
                        | State::LegacyStopped
                        | State::LockHandedOff
                        | State::NewInstalled
                        | State::NewBootstrapped
                        | State::NewPidObserved
                        | State::ReadyVerified
                        | State::Committed
                        | State::CommittedRecoveryStarted
                        | State::CommittedRecoveryBootstrapped
                        | State::CommittedRecoveryReady
                        | State::RollbackStarted
                        | State::NewStopped
                        | State::NewDestinationsCleared
                        | State::LegacyReenabled
                        | State::LegacyBootstrapped
                        | State::LegacyRecovered
                        | State::RolledBack
                ) {
                    saw_legacy_disabled = true;
                }
                if matches!(
                    parsed,
                    State::LegacyStopped
                        | State::LockHandedOff
                        | State::NewInstalled
                        | State::NewBootstrapped
                        | State::NewPidObserved
                        | State::ReadyVerified
                        | State::Committed
                        | State::CommittedRecoveryStarted
                        | State::CommittedRecoveryBootstrapped
                        | State::CommittedRecoveryReady
                        | State::RollbackStarted
                        | State::NewStopped
                        | State::NewDestinationsCleared
                        | State::LegacyReenabled
                        | State::LegacyBootstrapped
                        | State::LegacyRecovered
                        | State::RolledBack
                ) {
                    saw_legacy_stopped = true;
                }
                for field in parts {
                    let (key, encoded) = field.split_once('=').ok_or_else(|| {
                        ControllerError(format!("journal field is malformed: {field}"))
                    })?;
                    if key.is_empty() || key.contains(char::is_whitespace) {
                        return Err(ControllerError("journal field key is unsafe".to_owned()));
                    }
                    let decoded = percent_decode(encoded)?;
                    fields.insert(key.to_owned(), decoded);
                }
            } else if !line.is_empty() {
                return Err(ControllerError(format!(
                    "journal contains unknown record '{line}'"
                )));
            }
        }
        let state = state.unwrap_or(State::Begun);
        file.seek(SeekFrom::End(0))?;
        Ok(Self {
            path: path.to_path_buf(),
            file,
            state,
            saw_legacy_disabled,
            saw_legacy_stopped,
            fields,
        })
    }

    fn transition(&mut self, state: State, fields: &[(&str, String)]) -> Result<()> {
        let current = fs::symlink_metadata(&self.path)?;
        let opened = self.file.metadata()?;
        validate_owned_regular(&self.path, &current, 0o600)?;
        if !same_inode(&current, &opened) {
            return Err(ControllerError("journal path was substituted".to_owned()));
        }
        write!(self.file, "STATE {}", state.as_str())?;
        for (key, value) in fields {
            if value.contains('\n') || value.contains('\r') || key.contains(char::is_whitespace) {
                return Err(ControllerError("unsafe journal field".to_owned()));
            }
            write!(self.file, " {key}={}", percent_encode(value.as_bytes()))?;
        }
        writeln!(self.file)?;
        self.file.sync_all()?;
        sync_parent(&self.path)?;
        if matches!(
            state,
            State::LegacyDisabled
                | State::LegacyStopped
                | State::LockHandedOff
                | State::NewInstalled
                | State::NewBootstrapped
                | State::NewPidObserved
                | State::ReadyVerified
                | State::Committed
                | State::CommittedRecoveryStarted
                | State::CommittedRecoveryBootstrapped
                | State::CommittedRecoveryReady
                | State::RollbackStarted
                | State::NewStopped
                | State::NewDestinationsCleared
                | State::LegacyReenabled
                | State::LegacyBootstrapped
                | State::LegacyRecovered
                | State::RolledBack
        ) {
            self.saw_legacy_disabled = true;
        }
        if matches!(
            state,
            State::LegacyStopped
                | State::LockHandedOff
                | State::NewInstalled
                | State::NewBootstrapped
                | State::NewPidObserved
                | State::ReadyVerified
                | State::Committed
                | State::CommittedRecoveryStarted
                | State::CommittedRecoveryBootstrapped
                | State::CommittedRecoveryReady
                | State::RollbackStarted
                | State::NewStopped
                | State::NewDestinationsCleared
                | State::LegacyReenabled
                | State::LegacyBootstrapped
                | State::LegacyRecovered
                | State::RolledBack
        ) {
            self.saw_legacy_stopped = true;
        }
        for (key, value) in fields {
            self.fields.insert((*key).to_owned(), value.clone());
        }
        self.state = state;
        Ok(())
    }

    fn required_field(&self, key: &str) -> Result<&str> {
        self.fields
            .get(key)
            .map(String::as_str)
            .ok_or_else(|| ControllerError(format!("journal lacks required field '{key}'")))
    }
}

#[derive(Clone)]
struct Layout {
    repo: PathBuf,
    evidence: PathBuf,
    journal: PathBuf,
    records: PathBuf,
    source_export: PathBuf,
    source_archive: PathBuf,
    staged: PathBuf,
    staged_app: PathBuf,
    staged_plist: PathBuf,
    scratch: PathBuf,
    legacy_snapshot_executable: PathBuf,
    legacy_snapshot_plist: PathBuf,
    failed_new: PathBuf,
}

impl Layout {
    fn transaction_tag(&self) -> Result<String> {
        self.evidence
            .file_name()
            .and_then(OsStr::to_str)
            .map(str::to_owned)
            .ok_or_else(|| ControllerError("evidence directory has a non-UTF-8 name".to_owned()))
    }

    fn install_app_hold(&self) -> Result<PathBuf> {
        Ok(Path::new("/Applications").join(format!(
            ".opensteamer-install-hold-{}",
            self.transaction_tag()?
        )))
    }

    fn install_plist_hold(&self) -> Result<PathBuf> {
        Ok(Path::new("/Users/ahmed/Library/LaunchAgents").join(format!(
            ".org.example.opensteamer.worldwide.plist.install-{}",
            self.transaction_tag()?
        )))
    }

    fn create(repo: PathBuf) -> Result<Self> {
        ensure_private_directory(Path::new(MIGRATIONS_ROOT), 0o700)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ControllerError("system clock is before epoch".to_owned()))?
            .as_secs();
        let evidence =
            Path::new(MIGRATIONS_ROOT).join(format!("migration-v11-{now}-{}", process::id()));
        fs::create_dir(&evidence).map_err(|error| {
            ControllerError(format!("cannot create evidence directory: {error}"))
        })?;
        fs::set_permissions(&evidence, Permissions::from_mode(0o700))?;
        sync_parent(&evidence)?;
        let records = evidence.join("records");
        let source_export = evidence.join("source-export");
        let staged = evidence.join("staged");
        let scratch = evidence.join("swiftpm-scratch");
        let legacy_snapshot = evidence.join("legacy-snapshot");
        let failed_new = evidence.join("failed-new");
        for directory in [
            &records,
            &source_export,
            &staged,
            &scratch,
            &legacy_snapshot,
            &failed_new,
        ] {
            fs::create_dir(directory)?;
            fs::set_permissions(directory, Permissions::from_mode(0o700))?;
        }
        sync_directory(&evidence)?;
        let journal = evidence.join("journal.log");
        let source_archive = evidence.join("source.tar");
        let staged_app = staged.join("opensteamer Host.app");
        let staged_plist = staged.join("org.example.opensteamer.worldwide.plist");
        let legacy_snapshot_executable = legacy_snapshot.join("CaptureServer");
        let legacy_snapshot_plist =
            legacy_snapshot.join("com.elamin.audiostreamer.worldwide.plist");
        Ok(Self {
            repo,
            evidence,
            journal,
            records,
            source_export,
            source_archive,
            staged,
            staged_app,
            staged_plist,
            scratch,
            legacy_snapshot_executable,
            legacy_snapshot_plist,
            failed_new,
        })
    }

    fn open(repo: PathBuf, evidence: PathBuf) -> Result<Self> {
        validate_private_directory(Path::new(MIGRATIONS_ROOT), 0o700)?;
        validate_private_directory(&evidence, 0o700)?;
        if fs::canonicalize(&evidence)? != evidence {
            return Err(ControllerError(
                "active evidence directory is not canonical".to_owned(),
            ));
        }
        for child in [
            evidence.join("records"),
            evidence.join("source-export"),
            evidence.join("staged"),
            evidence.join("swiftpm-scratch"),
            evidence.join("legacy-snapshot"),
            evidence.join("failed-new"),
        ] {
            validate_private_directory(&child, 0o700)?;
        }
        if !evidence.starts_with(Path::new(MIGRATIONS_ROOT)) {
            return Err(ControllerError(
                "active evidence path escapes migrations root".to_owned(),
            ));
        }
        Ok(Self {
            repo,
            journal: evidence.join("journal.log"),
            records: evidence.join("records"),
            source_export: evidence.join("source-export"),
            source_archive: evidence.join("source.tar"),
            staged: evidence.join("staged"),
            staged_app: evidence.join("staged/opensteamer Host.app"),
            staged_plist: evidence.join("staged/org.example.opensteamer.worldwide.plist"),
            scratch: evidence.join("swiftpm-scratch"),
            legacy_snapshot_executable: evidence.join("legacy-snapshot/CaptureServer"),
            legacy_snapshot_plist: evidence
                .join("legacy-snapshot/com.elamin.audiostreamer.worldwide.plist"),
            failed_new: evidence.join("failed-new"),
            evidence,
        })
    }
}

#[derive(Debug)]
struct CommandOutput {
    status: ExitStatus,
    stdout: String,
    stderr: String,
}

impl CommandOutput {
    fn require_success(self, label: &str) -> Result<String> {
        if self.status.success() {
            Ok(self.stdout)
        } else {
            Err(ControllerError(format!(
                "{label} failed with {:?}: {}",
                self.status.code(),
                self.stderr.trim()
            )))
        }
    }
}

const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const BUILD_COMMAND_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const MINIMUM_PRECUTOVER_AVAILABLE_BYTES: u64 = 1024 * 1024 * 1024;
const ROLLBACK_RESERVE_BYTES: u64 = 8 * 1024 * 1024;
const ROLLBACK_RESERVE_NAME: &str = "rollback-reserve.bin";
const MAX_PINNED_SCRIPT_BYTES: u64 = 128 * 1024;
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(10);
const SIGKILL_VALUE: i32 = 9;

fn deadline_after(timeout: Duration) -> Result<Instant> {
    Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| ControllerError("command deadline overflowed".to_owned()))
}

fn require_before_deadline(deadline: Instant, label: &str) -> Result<()> {
    if Instant::now() >= deadline {
        return Err(ControllerError(format!(
            "{label} exceeded its shared monotonic deadline"
        )));
    }
    Ok(())
}

const F_GETFL_VALUE: i32 = 3;
const F_SETFL_VALUE: i32 = 4;
const MAX_COMMAND_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
const COMMAND_TERMINATION_RESERVE_MAX: Duration = Duration::from_millis(250);

fn fixed_child_environment() -> BTreeMap<String, String> {
    [
        ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        ("HOME", USER_HOME),
        ("TMPDIR", "/var/tmp"),
        ("LANG", "C"),
        ("LC_ALL", "C"),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_owned(), value.to_owned()))
    .collect()
}

fn set_pipe_nonblocking(fd: RawFd, label: &str) -> Result<()> {
    // SAFETY: `fd` is an owned child pipe descriptor and F_GETFL/F_SETFL do not dereference
    // pointers. The descriptor remains open for the duration of both calls.
    let flags = unsafe { fcntl(fd, F_GETFL_VALUE) };
    if flags < 0 {
        return Err(ControllerError(format!(
            "cannot read {label} pipe flags: {}",
            io::Error::last_os_error()
        )));
    }
    // SAFETY: same valid descriptor and integer flags as above.
    if unsafe { fcntl(fd, F_SETFL_VALUE, flags | O_NONBLOCK_VALUE) } != 0 {
        return Err(ControllerError(format!(
            "cannot make {label} pipe nonblocking: {}",
            io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn drain_nonblocking<R: Read>(
    reader: &mut R,
    output: &mut Vec<u8>,
    label: &str,
    deadline: Instant,
) -> Result<bool> {
    let mut buffer = [0u8; 8192];
    loop {
        require_before_deadline(deadline, label)?;
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                let next_length = output
                    .len()
                    .checked_add(count)
                    .ok_or_else(|| ControllerError(format!("{label} output length overflowed")))?;
                if next_length > MAX_COMMAND_OUTPUT_BYTES {
                    return Err(ControllerError(format!(
                        "{label} exceeded the bounded {}-byte output limit",
                        MAX_COMMAND_OUTPUT_BYTES
                    )));
                }
                output.extend_from_slice(&buffer[..count]);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) => {
                return Err(ControllerError(format!(
                    "cannot read {label} nonblocking pipe: {error}"
                )))
            }
        }
    }
}

fn configure_isolated_process_group(command: &mut Command) {
    // SAFETY: the closure runs in the child between fork and exec and calls only the async-signal-
    // safe setpgid operation. It returns the OS error to abort spawning if isolation fails.
    unsafe {
        command.pre_exec(|| {
            if setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        });
    }
}

fn terminate_process_group_and_reap(
    child: &mut Child,
    program: &Path,
    deadline: Instant,
) -> Result<ExitStatus> {
    let process_group = i32::try_from(child.id()).map_err(|_| {
        ControllerError(format!(
            "child PID for '{}' does not fit the process-group API",
            program.display()
        ))
    })?;
    // SAFETY: a negative PID addresses the isolated child process group established by pre_exec.
    let killed = unsafe { kill(-process_group, SIGKILL_VALUE) };
    let mut termination_error = None;
    if killed != 0 {
        let error = io::Error::last_os_error();
        // ESRCH is acceptable when the child exited between the final poll and group kill.
        if error.raw_os_error() != Some(3) {
            if let Err(fallback) = child.kill() {
                termination_error = Some(format!(
                    "group kill failed ({error}) and direct-child kill failed ({fallback})"
                ));
            } else {
                termination_error = Some(format!(
                    "group kill failed ({error}); direct-child SIGKILL fallback was issued"
                ));
            }
        }
    }
    loop {
        if let Some(status) = child.try_wait().map_err(|error| {
            ControllerError(format!(
                "cannot poll terminated child '{}': {error}",
                program.display()
            ))
        })? {
            if let Some(error) = termination_error {
                return Err(ControllerError(format!(
                    "child '{}' was reaped after incomplete process-group termination: {error}",
                    program.display()
                )));
            }
            return Ok(status);
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ControllerError(format!(
                "child '{}' was signalled but could not be reaped before the shared monotonic deadline{}",
                program.display(),
                termination_error
                    .as_deref()
                    .map_or_else(String::new, |error| format!(": {error}"))
            )));
        }
        thread::sleep(
            deadline
                .saturating_duration_since(now)
                .min(COMMAND_POLL_INTERVAL),
        );
    }
}

fn command_kill_at(started: Instant, deadline: Instant) -> Instant {
    let remaining = deadline.saturating_duration_since(started);
    let reserve = remaining
        .checked_div(4)
        .unwrap_or(Duration::ZERO)
        .min(COMMAND_TERMINATION_RESERVE_MAX);
    deadline.checked_sub(reserve).unwrap_or(started)
}

fn run_spawned_command(
    mut command: Command,
    program: &Path,
    deadline: Instant,
) -> Result<CommandOutput> {
    let started = Instant::now();
    if started >= deadline {
        return Err(ControllerError(format!(
            "command '{}' was not started because its monotonic deadline expired",
            program.display()
        )));
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_isolated_process_group(&mut command);
    let mut child = command.spawn().map_err(|error| {
        ControllerError(format!("cannot execute '{}': {error}", program.display()))
    })?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| ControllerError("child stdout pipe is unavailable".to_owned()))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| ControllerError("child stderr pipe is unavailable".to_owned()))?;
    if let Err(error) = set_pipe_nonblocking(stdout.as_raw_fd(), "child stdout")
        .and_then(|_| set_pipe_nonblocking(stderr.as_raw_fd(), "child stderr"))
    {
        let _ = terminate_process_group_and_reap(&mut child, program, deadline);
        return Err(error);
    }
    let mut stdout_bytes = Vec::new();
    let mut stderr_bytes = Vec::new();
    let kill_at = command_kill_at(started, deadline);

    loop {
        if let Err(error) =
            drain_nonblocking(&mut stdout, &mut stdout_bytes, "child stdout", deadline).and_then(
                |_| drain_nonblocking(&mut stderr, &mut stderr_bytes, "child stderr", deadline),
            )
        {
            let _ = terminate_process_group_and_reap(&mut child, program, deadline);
            return Err(error);
        }
        if let Some(status) = child.try_wait().map_err(|error| {
            ControllerError(format!(
                "cannot poll child '{}': {error}",
                program.display()
            ))
        })? {
            // A descendant may retain an inherited pipe after the direct child exits. Both pipes
            // are nonblocking, so collect only the bytes already available and close them rather
            // than waiting for an untrusted descendant to produce EOF.
            let _ = drain_nonblocking(&mut stdout, &mut stdout_bytes, "child stdout", deadline)?;
            let _ = drain_nonblocking(&mut stderr, &mut stderr_bytes, "child stderr", deadline)?;
            return Ok(CommandOutput {
                status,
                stdout: String::from_utf8(stdout_bytes).map_err(|_| {
                    ControllerError(format!("{} stdout is not UTF-8", program.display()))
                })?,
                stderr: String::from_utf8(stderr_bytes).map_err(|_| {
                    ControllerError(format!("{} stderr is not UTF-8", program.display()))
                })?,
            });
        }

        let now = Instant::now();
        if now >= kill_at {
            let reaped = terminate_process_group_and_reap(&mut child, program, deadline)?;
            let _ = drain_nonblocking(
                &mut stdout,
                &mut stdout_bytes,
                "timed-out child stdout",
                deadline,
            )?;
            let _ = drain_nonblocking(
                &mut stderr,
                &mut stderr_bytes,
                "timed-out child stderr",
                deadline,
            )?;
            return Err(ControllerError(format!(
                "command '{}' exceeded its monotonic deadline budget (process-group-terminated, reaped={:?}, stdout_bytes={}, stderr={})",
                program.display(),
                reaped.code(),
                stdout_bytes.len(),
                String::from_utf8_lossy(&stderr_bytes).trim()
            )));
        }
        thread::sleep(
            kill_at
                .saturating_duration_since(now)
                .min(COMMAND_POLL_INTERVAL),
        );
    }
}

fn run_command_until(
    program: &Path,
    arguments: &[&OsStr],
    cwd: Option<&Path>,
    deadline: Instant,
) -> Result<CommandOutput> {
    if Instant::now() >= deadline {
        return Err(ControllerError(format!(
            "command '{}' was not started because its monotonic deadline expired",
            program.display()
        )));
    }
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("HOME", USER_HOME)
        .env("TMPDIR", "/var/tmp")
        .env("LANG", "C")
        .env("LC_ALL", "C");
    if let Some(directory) = cwd {
        command.current_dir(directory);
    }
    run_spawned_command(command, program, deadline)
}

fn run_command(program: &Path, arguments: &[&OsStr], cwd: Option<&Path>) -> Result<CommandOutput> {
    run_command_until(
        program,
        arguments,
        cwd,
        deadline_after(DEFAULT_COMMAND_TIMEOUT)?,
    )
}

fn run_command_owned_until(
    program: &Path,
    arguments: &[String],
    cwd: Option<&Path>,
    environment: &BTreeMap<String, String>,
    deadline: Instant,
) -> Result<CommandOutput> {
    if Instant::now() >= deadline {
        return Err(ControllerError(format!(
            "command '{}' was not started because its monotonic deadline expired",
            program.display()
        )));
    }
    let mut command = Command::new(program);
    command.args(arguments);
    if let Some(directory) = cwd {
        command.current_dir(directory);
    }
    command.env_clear();
    command.envs(environment);
    run_spawned_command(command, program, deadline)
}

fn run_pinned_script_until(
    verifiers: &PinnedVerifierSet,
    script: &PinnedScript,
    arguments: &[&OsStr],
    cwd: Option<&Path>,
    environment: &BTreeMap<String, String>,
    deadline: Instant,
) -> Result<CommandOutput> {
    verifiers.revalidate()?;
    if Instant::now() >= deadline {
        return Err(ControllerError(format!(
            "pinned script '{}' was not started because its monotonic deadline expired",
            script.logical_path.display()
        )));
    }
    let mut command = Command::new("/bin/zsh");
    command
        .arg("-c")
        .arg(&script.text)
        .arg(&script.logical_path)
        .args(arguments)
        .env_clear()
        .envs(environment);
    if let Some(directory) = cwd {
        command.current_dir(directory);
    }
    let output = run_spawned_command(command, &script.logical_path, deadline)?;
    verifiers.revalidate()?;
    Ok(output)
}

fn run_pinned_script(
    verifiers: &PinnedVerifierSet,
    script: &PinnedScript,
    arguments: &[&OsStr],
    cwd: Option<&Path>,
    environment: &BTreeMap<String, String>,
) -> Result<CommandOutput> {
    run_pinned_script_until(
        verifiers,
        script,
        arguments,
        cwd,
        environment,
        deadline_after(DEFAULT_COMMAND_TIMEOUT)?,
    )
}

fn run_command_with_stdout_file(
    program: &Path,
    arguments: &[&OsStr],
    cwd: Option<&Path>,
    stdout_file: File,
    deadline: Instant,
) -> Result<(ExitStatus, String)> {
    let started = Instant::now();
    if started >= deadline {
        return Err(ControllerError(format!(
            "command '{}' was not started because its monotonic deadline expired",
            program.display()
        )));
    }
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("HOME", USER_HOME)
        .env("TMPDIR", "/var/tmp")
        .env("LANG", "C")
        .env("LC_ALL", "C");
    if let Some(directory) = cwd {
        command.current_dir(directory);
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout_file))
        .stderr(Stdio::piped());
    configure_isolated_process_group(&mut command);
    let mut child = command.spawn().map_err(|error| {
        ControllerError(format!("cannot execute '{}': {error}", program.display()))
    })?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| ControllerError("child stderr pipe is unavailable".to_owned()))?;
    if let Err(error) = set_pipe_nonblocking(stderr.as_raw_fd(), "child stderr") {
        let _ = terminate_process_group_and_reap(&mut child, program, deadline);
        return Err(error);
    }
    let mut stderr_bytes = Vec::new();
    let kill_at = command_kill_at(started, deadline);
    loop {
        if let Err(error) =
            drain_nonblocking(&mut stderr, &mut stderr_bytes, "child stderr", deadline)
        {
            let _ = terminate_process_group_and_reap(&mut child, program, deadline);
            return Err(error);
        }
        if let Some(status) = child.try_wait().map_err(|error| {
            ControllerError(format!(
                "cannot poll child '{}': {error}",
                program.display()
            ))
        })? {
            let _ = drain_nonblocking(&mut stderr, &mut stderr_bytes, "child stderr", deadline)?;
            let stderr_text = String::from_utf8(stderr_bytes).map_err(|_| {
                ControllerError(format!("{} stderr is not UTF-8", program.display()))
            })?;
            return Ok((status, stderr_text));
        }
        let now = Instant::now();
        if now >= kill_at {
            let reaped = terminate_process_group_and_reap(&mut child, program, deadline)?;
            let _ = drain_nonblocking(
                &mut stderr,
                &mut stderr_bytes,
                "timed-out child stderr",
                deadline,
            )?;
            return Err(ControllerError(format!(
                "command '{}' exceeded its monotonic deadline budget (process-group-terminated, reaped={:?}, stderr={})",
                program.display(),
                reaped.code(),
                String::from_utf8_lossy(&stderr_bytes).trim()
            )));
        }
        thread::sleep(
            kill_at
                .saturating_duration_since(now)
                .min(COMMAND_POLL_INTERVAL),
        );
    }
}

fn main() {
    let code = match controller_main() {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("opensteamer migration controller: {error}");
            1
        }
    };
    process::exit(code);
}

fn controller_main() -> Result<()> {
    let arguments: Vec<String> = env::args().collect();
    match arguments.as_slice() {
        [_, mode, case] if mode == SELF_TEST_MODE => run_self_test(case),
        [_, mode, runtime, lock, pid] if mode == "--probe-lock" => {
            probe_lock_cli(Path::new(runtime), Path::new(lock), pid)
        }
        [_, mode, root] if mode == AUTHORIZED_MODE => execute(Path::new(root)),
        _ => Err(ControllerError(format!(
            "usage: {} {AUTHORIZED_MODE} <absolute-canonical-repository-root>\n       {} {SELF_TEST_MODE} <all|crash|faults|rollback|readiness|concurrency|journal|publication|disable|committed|active-pointer|side-effects|parsers|generation-race|deadlines|modes|real-adapter>\n       {} --probe-lock <runtime-directory> <lock-file> <expected-pid>",
            arguments.first().map_or("opensteamer-host-migration-controller", String::as_str),
            arguments.first().map_or("opensteamer-host-migration-controller", String::as_str),
            arguments.first().map_or("opensteamer-host-migration-controller", String::as_str)
        ))),
    }
}

fn execute(root: &Path) -> Result<()> {
    if cfg!(not(target_os = "macos")) {
        return Err(ControllerError(
            "the real migration controller may run only on macOS".to_owned(),
        ));
    }
    let repo = validate_repository_root(root)?;
    verify_launcher_attestation(&repo)?;
    if effective_uid() != USER_ID {
        return Err(ControllerError(format!(
            "migration must run as audited uid {USER_ID}, found {}",
            effective_uid()
        )));
    }
    let transaction_lock = TransactionLock::acquire()?;
    let private_root = transaction_lock.parent();
    match recover_active_pointer(private_root)? {
        ActivePointerRecovery::None => {
            verify_chflags_tool()?;
            let prior_v9 = validate_prior_v9_prestop_retry(private_root)?;
            let prior_v10 = validate_prior_v10_rolledback_retry(private_root)?;
            start_new(repo, private_root, prior_v9, prior_v10)
        }
        ActivePointerRecovery::Active => recover_active(repo, private_root),
    }
}

fn require_lower_hex_hash(variable: &str) -> Result<String> {
    let value = env::var(variable).map_err(|_| {
        ControllerError(format!(
            "required launcher attestation is missing: {variable}"
        ))
    })?;
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(ControllerError(format!(
            "launcher attestation hash is malformed: {variable}"
        )));
    }
    Ok(value)
}

fn verify_launcher_attestation(repo: &Path) -> Result<()> {
    let expected_binary_path =
        env::var_os("OPENSTEAMER_MIGRATION_CONTROLLER_BINARY").ok_or_else(|| {
            ControllerError("launcher did not identify the controller binary".to_owned())
        })?;
    let expected_binary = fs::canonicalize(Path::new(&expected_binary_path))?;
    let current_binary = fs::canonicalize(env::current_exe()?)?;
    if current_binary != expected_binary {
        return Err(ControllerError(format!(
            "running controller '{}' differs from launcher-attested binary '{}'",
            current_binary.display(),
            expected_binary.display()
        )));
    }
    let binary_metadata = fs::symlink_metadata(&current_binary)?;
    validate_owned_regular(&current_binary, &binary_metadata, 0o500)?;
    let expected_binary_hash =
        require_lower_hex_hash("OPENSTEAMER_MIGRATION_CONTROLLER_BINARY_SHA256")?;
    if sha256_file(&current_binary)? != expected_binary_hash {
        return Err(ControllerError(
            "running controller binary hash differs from launcher attestation".to_owned(),
        ));
    }

    let source = repo.join("macOS/scripts/opensteamer-host-migration-controller.rs");
    let source_metadata = fs::symlink_metadata(&source)?;
    validate_owned_regular(&source, &source_metadata, 0o644)?;
    let expected_source_hash =
        require_lower_hex_hash("OPENSTEAMER_MIGRATION_CONTROLLER_SOURCE_SHA256")?;
    if sha256_file(&source)? != expected_source_hash {
        return Err(ControllerError(
            "controller source hash differs from launcher attestation".to_owned(),
        ));
    }

    let compiler_hash = require_lower_hex_hash("OPENSTEAMER_MIGRATION_RUSTC_SHA256")?;
    if compiler_hash != REVIEWED_RUSTC_SHA256 {
        return Err(ControllerError(
            "launcher compiler SHA-256 differs from the reviewed trust anchor".to_owned(),
        ));
    }
    let compiler_cdhash = require_lower_hex_hash("OPENSTEAMER_MIGRATION_RUSTC_CDHASH_FULL")?;
    if compiler_cdhash != REVIEWED_RUSTC_CDHASH_FULL {
        return Err(ControllerError(
            "launcher compiler full CDHash differs from the reviewed trust anchor".to_owned(),
        ));
    }
    Ok(())
}

fn validate_prior_v9_prestop_records(evidence: &Path, journal: &[u8], result: &[u8]) -> Result<()> {
    if evidence != Path::new(PRIOR_EVIDENCE_PATH) {
        return Err(ControllerError(
            "prior active pointer does not name the exact reviewed v9 evidence".to_owned(),
        ));
    }
    if journal != PRIOR_PRESTOP_JOURNAL {
        return Err(ControllerError(
            "prior v9 journal is not the exact reviewed rolled-back-before-stop sequence"
                .to_owned(),
        ));
    }
    if result != PRIOR_PRESTOP_RESULT {
        return Err(ControllerError(
            "prior v9 result is not the exact reviewed rolled-back-before-stop outcome".to_owned(),
        ));
    }
    Ok(())
}

fn verify_chflags_tool() -> Result<()> {
    let path = Path::new("/usr/bin/chflags");
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o7777 != 0o755
    {
        return Err(ControllerError(
            "reviewed /usr/bin/chflags identity or mode is unsafe".to_owned(),
        ));
    }
    if sha256_file(path)? != CHFLAGS_SHA256 {
        return Err(ControllerError(
            "reviewed /usr/bin/chflags SHA-256 changed".to_owned(),
        ));
    }
    Ok(())
}

fn open_required_pinned_regular(parent: &PinnedDirectory, name: &str, mode: u32) -> Result<File> {
    let file = parent
        .open_existing_regular(name, false)?
        .ok_or_else(|| ControllerError(format!("required private record is missing: {name}")))?;
    validate_owned_regular(&parent.path.join(name), &file.metadata()?, mode)?;
    parent.ensure_file_at_name(name, &file)?;
    Ok(file)
}

fn read_opened_regular(file: &File, path: &Path, mode: u32) -> Result<Vec<u8>> {
    validate_owned_regular(path, &file.metadata()?, mode)?;
    let mut reader = file.try_clone()?;
    reader.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn require_exact_directory_entries(directory: &PinnedDirectory, expected: &[&str]) -> Result<()> {
    directory.revalidate()?;
    let mut actual = BTreeSet::new();
    for entry in fs::read_dir(&directory.path)? {
        let entry = entry?;
        let name = entry.file_name().into_string().map_err(|_| {
            ControllerError(format!(
                "private directory contains a non-UTF-8 entry: {}",
                directory.path.display()
            ))
        })?;
        actual.insert(name);
    }
    directory.revalidate()?;
    let expected: BTreeSet<String> = expected.iter().map(|value| (*value).to_owned()).collect();
    if actual != expected {
        return Err(ControllerError(format!(
            "private directory entries differ at {}: actual={actual:?} expected={expected:?}",
            directory.path.display()
        )));
    }
    Ok(())
}

struct PriorV9RetryGuard {
    pointer: File,
    evidence: PinnedDirectory,
    records: PinnedDirectory,
    empty_directories: Vec<PinnedDirectory>,
    journal: File,
    result: File,
    source_archive: File,
}

impl PriorV9RetryGuard {
    fn journal_fields(&self) -> Vec<(&'static str, String)> {
        vec![
            ("prior_v9_active_sha256", PRIOR_ACTIVE_SHA256.to_owned()),
            ("prior_v9_journal_sha256", PRIOR_JOURNAL_SHA256.to_owned()),
            ("prior_v9_result_sha256", PRIOR_RESULT_SHA256.to_owned()),
            (
                "prior_v9_source_archive_sha256",
                PRIOR_SOURCE_ARCHIVE_SHA256.to_owned(),
            ),
            ("prior_v9_source_commit", PRIOR_SOURCE_COMMIT.to_owned()),
        ]
    }

    fn revalidate(&self, private_root: &PinnedDirectory) -> Result<()> {
        private_root.ensure_file_at_name(PRIOR_ACTIVE_TRANSACTION_NAME, &self.pointer)?;
        let pointer = read_opened_regular(
            &self.pointer,
            &private_root.path.join(PRIOR_ACTIVE_TRANSACTION_NAME),
            0o600,
        )?;
        if pointer != PRIOR_ACTIVE_RECORD || sha256_bytes(&pointer)? != PRIOR_ACTIVE_SHA256 {
            return Err(ControllerError(
                "prior v9 active pointer changed during retry proof".to_owned(),
            ));
        }
        private_root.ensure_file_at_name(PRIOR_ACTIVE_TRANSACTION_NAME, &self.pointer)?;

        self.evidence.revalidate()?;
        self.records.revalidate()?;
        require_exact_directory_entries(
            &self.evidence,
            &[
                "failed-new",
                "journal.log",
                "legacy-snapshot",
                "records",
                "source-export",
                "source.tar",
                "staged",
                "swiftpm-scratch",
            ],
        )?;
        require_exact_directory_entries(&self.records, &["result.txt"])?;
        for directory in &self.empty_directories {
            require_exact_directory_entries(directory, &[])?;
        }

        self.evidence
            .ensure_file_at_name("journal.log", &self.journal)?;
        self.records
            .ensure_file_at_name("result.txt", &self.result)?;
        self.evidence
            .ensure_file_at_name("source.tar", &self.source_archive)?;
        let journal = read_opened_regular(
            &self.journal,
            &self.evidence.path.join("journal.log"),
            0o600,
        )?;
        let result =
            read_opened_regular(&self.result, &self.records.path.join("result.txt"), 0o600)?;
        validate_prior_v9_prestop_records(&self.evidence.path, &journal, &result)?;
        if sha256_bytes(&journal)? != PRIOR_JOURNAL_SHA256
            || sha256_bytes(&result)? != PRIOR_RESULT_SHA256
        {
            return Err(ControllerError(
                "prior v9 journal or result hash changed during retry proof".to_owned(),
            ));
        }
        let archive_metadata = self.source_archive.metadata()?;
        validate_owned_regular(
            &self.evidence.path.join("source.tar"),
            &archive_metadata,
            0o600,
        )?;
        let source_archive = read_opened_regular(
            &self.source_archive,
            &self.evidence.path.join("source.tar"),
            0o600,
        )?;
        if archive_metadata.len() != PRIOR_SOURCE_ARCHIVE_SIZE
            || sha256_bytes(&source_archive)? != PRIOR_SOURCE_ARCHIVE_SHA256
        {
            return Err(ControllerError(
                "prior v9 source archive differs from the reviewed failed attempt".to_owned(),
            ));
        }
        self.evidence
            .ensure_file_at_name("journal.log", &self.journal)?;
        self.records
            .ensure_file_at_name("result.txt", &self.result)?;
        self.evidence
            .ensure_file_at_name("source.tar", &self.source_archive)?;
        Ok(())
    }
}

/// Version 9 failed before the legacy-stop boundary on this Mac because it referenced the
/// nonexistent `/bin/chflags`. Its retained evidence must remain untouched. Version 11 may start
/// only after independently pinning that exact tombstone together with the exact fully rolled-back
/// version-10 tombstone and reproving the untouched legacy runtime. Any other residue fails closed.
fn validate_prior_v9_prestop_retry(private_root: &PinnedDirectory) -> Result<PriorV9RetryGuard> {
    for residue in [
        PRIOR_ACTIVE_TRANSACTION_PENDING_NAME,
        PRIOR_ACTIVE_TRANSACTION_FINALIZING_NAME,
        PRIOR_ACTIVE_TRANSACTION_LINEARIZED_NAME,
    ] {
        if private_root
            .open_existing_regular(residue, false)?
            .is_some()
        {
            return Err(ControllerError(format!(
                "prior v9 active-pointer residue requires manual recovery: {residue}"
            )));
        }
    }
    let pointer = open_required_pinned_regular(private_root, PRIOR_ACTIVE_TRANSACTION_NAME, 0o600)?;
    let pointer_bytes = read_opened_regular(
        &pointer,
        &private_root.path.join(PRIOR_ACTIVE_TRANSACTION_NAME),
        0o600,
    )?;
    if pointer_bytes != PRIOR_ACTIVE_RECORD {
        return Err(ControllerError(
            "prior v9 active pointer is not the exact reviewed record".to_owned(),
        ));
    }
    let evidence = parse_active_record(&pointer_bytes)?;
    if evidence != Path::new(PRIOR_EVIDENCE_PATH) {
        return Err(ControllerError(
            "prior v9 active pointer resolved to unexpected evidence".to_owned(),
        ));
    }
    let evidence_directory = PinnedDirectory::open(&evidence, Some(effective_uid()), Some(0o700))?;
    let mut empty_directories = Vec::new();
    for child in [
        "source-export",
        "staged",
        "swiftpm-scratch",
        "legacy-snapshot",
        "failed-new",
    ] {
        let directory = evidence_directory
            .try_open_directory_child(child, Some(effective_uid()), Some(0o700))?
            .ok_or_else(|| {
                ControllerError(format!(
                    "prior v9 evidence lacks private directory '{child}'"
                ))
            })?;
        empty_directories.push(directory);
    }
    let records = evidence_directory
        .try_open_directory_child("records", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| ControllerError("prior v9 evidence lacks records directory".to_owned()))?;
    let journal = open_required_pinned_regular(&evidence_directory, "journal.log", 0o600)?;
    let result = open_required_pinned_regular(&records, "result.txt", 0o600)?;
    let source_archive = open_required_pinned_regular(&evidence_directory, "source.tar", 0o600)?;
    let guard = PriorV9RetryGuard {
        pointer,
        evidence: evidence_directory,
        records,
        empty_directories,
        journal,
        result,
        source_archive,
    };
    guard.revalidate(private_root)?;

    let tag = guard
        .evidence
        .path
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("prior v9 evidence tag is not UTF-8".to_owned()))?;
    for residue in [
        Path::new("/Applications").join(format!(".opensteamer-disabled-v9-{tag}")),
        Path::new("/Applications").join(format!(".opensteamer-install-hold-{tag}")),
        Path::new("/Users/ahmed/Library/LaunchAgents").join(format!(
            ".org.example.opensteamer.worldwide.plist.disabled-v9-{tag}"
        )),
        Path::new("/Users/ahmed/Library/LaunchAgents").join(format!(
            ".org.example.opensteamer.worldwide.plist.install-{tag}"
        )),
    ] {
        if entry_exists(&residue)? {
            return Err(ControllerError(format!(
                "prior v9 rollback residue remains at {}",
                residue.display()
            )));
        }
    }

    let deadline = deadline_after(Duration::from_secs(15))?;
    require_new_absent()?;
    verify_legacy_static_until(deadline)?;
    verify_legacy_disabled_until(false, deadline)?;
    wait_for_exact_legacy_readiness_until(deadline)?;
    guard.revalidate(private_root)?;
    Ok(guard)
}

fn validate_prior_v10_rolledback_records(
    evidence: &Path,
    journal: &[u8],
    result: &[u8],
    provenance: &[u8],
) -> Result<()> {
    if evidence != Path::new(PRIOR_V10_EVIDENCE_PATH) {
        return Err(ControllerError(
            "prior v10 pointer does not name the exact reviewed evidence".to_owned(),
        ));
    }
    if journal != PRIOR_V10_FINAL_JOURNAL {
        return Err(ControllerError(
            "prior v10 journal is not the exact reviewed full-restore rollback".to_owned(),
        ));
    }
    if result != PRIOR_V10_FINAL_RESULT {
        return Err(ControllerError(
            "prior v10 result is not the exact reviewed rolled-back outcome".to_owned(),
        ));
    }
    if provenance != PRIOR_V10_PROVENANCE {
        return Err(ControllerError(
            "prior v10 provenance is not the exact reviewed record".to_owned(),
        ));
    }
    Ok(())
}

struct PriorV10RetryGuard {
    pointer: File,
    evidence: PinnedDirectory,
    records: PinnedDirectory,
    legacy_snapshot: PinnedDirectory,
    failed_new: PinnedDirectory,
    failed_app: PinnedDirectory,
    staged: PinnedDirectory,
    staged_app: PinnedDirectory,
    source_export: PinnedDirectory,
    scratch: PinnedDirectory,
    journal: File,
    result: File,
    provenance: File,
    legacy_manifest: File,
    legacy_xattrs: File,
    staged_hashes: File,
    source_export_manifest: File,
    build_stdout: File,
    build_stderr: File,
    staged_plist: File,
    source_archive: File,
    snapshot_executable: File,
    snapshot_plist: File,
}

impl PriorV10RetryGuard {
    fn journal_fields(&self) -> Vec<(&'static str, String)> {
        vec![
            (
                "prior_v10_active_sha256",
                PRIOR_V10_ACTIVE_SHA256.to_owned(),
            ),
            (
                "prior_v10_journal_sha256",
                PRIOR_V10_FINAL_JOURNAL_SHA256.to_owned(),
            ),
            (
                "prior_v10_result_sha256",
                PRIOR_V10_FINAL_RESULT_SHA256.to_owned(),
            ),
            (
                "prior_v10_source_archive_sha256",
                PRIOR_V10_SOURCE_ARCHIVE_SHA256.to_owned(),
            ),
            (
                "prior_v10_source_commit",
                PRIOR_V10_SOURCE_COMMIT.to_owned(),
            ),
            ("prior_v10_source_tree", PRIOR_V10_SOURCE_TREE.to_owned()),
            (
                "prior_v10_provenance_sha256",
                PRIOR_V10_PROVENANCE_SHA256.to_owned(),
            ),
            (
                "prior_v10_legacy_executable_sha256",
                LEGACY_EXECUTABLE_SHA256.to_owned(),
            ),
            (
                "prior_v10_legacy_plist_sha256",
                LEGACY_PLIST_SHA256.to_owned(),
            ),
        ]
    }

    fn revalidate(&self, private_root: &PinnedDirectory) -> Result<()> {
        private_root.ensure_file_at_name(PRIOR_V10_ACTIVE_TRANSACTION_NAME, &self.pointer)?;
        let pointer_path = private_root.path.join(PRIOR_V10_ACTIVE_TRANSACTION_NAME);
        let pointer = read_opened_regular(&self.pointer, &pointer_path, 0o600)?;
        if pointer != PRIOR_V10_ACTIVE_RECORD || sha256_bytes(&pointer)? != PRIOR_V10_ACTIVE_SHA256
        {
            return Err(ControllerError(
                "prior v10 active pointer changed during retry proof".to_owned(),
            ));
        }
        private_root.ensure_file_at_name(PRIOR_V10_ACTIVE_TRANSACTION_NAME, &self.pointer)?;

        self.evidence.revalidate()?;
        self.records.revalidate()?;
        self.legacy_snapshot.revalidate()?;
        self.failed_new.revalidate()?;
        self.failed_app.revalidate()?;
        self.staged.revalidate()?;
        self.staged_app.revalidate()?;
        self.source_export.revalidate()?;
        self.scratch.revalidate()?;
        require_exact_directory_entries(
            &self.evidence,
            &[
                "failed-new",
                "journal.log",
                "legacy-snapshot",
                "records",
                "source-export",
                "source.tar",
                "staged",
                "swiftpm-scratch",
            ],
        )?;
        require_exact_directory_entries(
            &self.records,
            &[
                "build.stderr",
                "build.stdout",
                "legacy-app-tree-manifest.txt",
                "legacy-app-xattrs.txt",
                "provenance.txt",
                "result.txt",
                "source-export-manifest.txt",
                "staged-hashes.txt",
            ],
        )?;
        require_exact_directory_entries(
            &self.legacy_snapshot,
            &["CaptureServer", "com.elamin.audiostreamer.worldwide.plist"],
        )?;
        require_exact_directory_entries(&self.failed_new, &["partial-install-hold"])?;
        require_exact_directory_entries(
            &self.staged,
            &[
                "opensteamer Host.app",
                "org.example.opensteamer.worldwide.plist",
            ],
        )?;

        self.evidence
            .ensure_file_at_name("journal.log", &self.journal)?;
        self.records
            .ensure_file_at_name("result.txt", &self.result)?;
        self.records
            .ensure_file_at_name("provenance.txt", &self.provenance)?;
        self.records
            .ensure_file_at_name("legacy-app-tree-manifest.txt", &self.legacy_manifest)?;
        self.records
            .ensure_file_at_name("legacy-app-xattrs.txt", &self.legacy_xattrs)?;
        self.records
            .ensure_file_at_name("staged-hashes.txt", &self.staged_hashes)?;
        self.records
            .ensure_file_at_name("source-export-manifest.txt", &self.source_export_manifest)?;
        self.records
            .ensure_file_at_name("build.stdout", &self.build_stdout)?;
        self.records
            .ensure_file_at_name("build.stderr", &self.build_stderr)?;
        self.staged.ensure_file_at_name(
            "org.example.opensteamer.worldwide.plist",
            &self.staged_plist,
        )?;
        self.evidence
            .ensure_file_at_name("source.tar", &self.source_archive)?;
        self.legacy_snapshot
            .ensure_file_at_name("CaptureServer", &self.snapshot_executable)?;
        self.legacy_snapshot.ensure_file_at_name(
            "com.elamin.audiostreamer.worldwide.plist",
            &self.snapshot_plist,
        )?;

        let journal = read_opened_regular(
            &self.journal,
            &self.evidence.path.join("journal.log"),
            0o600,
        )?;
        let result =
            read_opened_regular(&self.result, &self.records.path.join("result.txt"), 0o600)?;
        let provenance = read_opened_regular(
            &self.provenance,
            &self.records.path.join("provenance.txt"),
            0o600,
        )?;
        let legacy_manifest = read_opened_regular(
            &self.legacy_manifest,
            &self.records.path.join("legacy-app-tree-manifest.txt"),
            0o600,
        )?;
        let legacy_xattrs = read_opened_regular(
            &self.legacy_xattrs,
            &self.records.path.join("legacy-app-xattrs.txt"),
            0o600,
        )?;
        let source_export_manifest = read_opened_regular(
            &self.source_export_manifest,
            &self.records.path.join("source-export-manifest.txt"),
            0o600,
        )?;
        let staged_hashes = read_opened_regular(
            &self.staged_hashes,
            &self.records.path.join("staged-hashes.txt"),
            0o600,
        )?;
        let build_stdout = read_opened_regular(
            &self.build_stdout,
            &self.records.path.join("build.stdout"),
            0o600,
        )?;
        let build_stderr = read_opened_regular(
            &self.build_stderr,
            &self.records.path.join("build.stderr"),
            0o600,
        )?;
        validate_prior_v10_rolledback_records(&self.evidence.path, &journal, &result, &provenance)?;
        if tree_manifest(&self.source_export.path)?.as_bytes() != source_export_manifest {
            return Err(ControllerError(
                "prior v10 source export differs from its exact reviewed manifest".to_owned(),
            ));
        }
        if tree_manifest(Path::new(LEGACY_APP))?.as_bytes() != legacy_manifest {
            return Err(ControllerError(
                "live legacy app differs from the exact prior v10 snapshot manifest".to_owned(),
            ));
        }
        if capture_legacy_xattrs()?.as_bytes() != legacy_xattrs {
            return Err(ControllerError(
                "live legacy app xattrs differ from the exact prior v10 snapshot".to_owned(),
            ));
        }
        if sha256_bytes(&journal)? != PRIOR_V10_FINAL_JOURNAL_SHA256
            || sha256_bytes(&result)? != PRIOR_V10_FINAL_RESULT_SHA256
            || sha256_bytes(&provenance)? != PRIOR_V10_PROVENANCE_SHA256
        {
            return Err(ControllerError(
                "prior v10 journal, result, or provenance hash changed during retry proof"
                    .to_owned(),
            ));
        }
        for (path, bytes, expected) in [
            (
                self.records.path.join("legacy-app-tree-manifest.txt"),
                legacy_manifest.as_slice(),
                PRIOR_V10_LEGACY_MANIFEST_SHA256,
            ),
            (
                self.records.path.join("legacy-app-xattrs.txt"),
                legacy_xattrs.as_slice(),
                PRIOR_V10_LEGACY_XATTRS_SHA256,
            ),
            (
                self.records.path.join("staged-hashes.txt"),
                staged_hashes.as_slice(),
                PRIOR_V10_STAGED_HASHES_SHA256,
            ),
            (
                self.records.path.join("source-export-manifest.txt"),
                source_export_manifest.as_slice(),
                PRIOR_V10_SOURCE_EXPORT_MANIFEST_SHA256,
            ),
            (
                self.records.path.join("build.stdout"),
                build_stdout.as_slice(),
                PRIOR_V10_BUILD_STDOUT_SHA256,
            ),
            (
                self.records.path.join("build.stderr"),
                build_stderr.as_slice(),
                PRIOR_V10_BUILD_STDERR_SHA256,
            ),
        ] {
            if sha256_bytes(bytes)? != expected {
                return Err(ControllerError(format!(
                    "prior v10 anchored record changed: {}",
                    path.display()
                )));
            }
        }

        let archive_metadata = self.source_archive.metadata()?;
        validate_owned_regular(
            &self.evidence.path.join("source.tar"),
            &archive_metadata,
            0o600,
        )?;
        let source_archive = read_opened_regular(
            &self.source_archive,
            &self.evidence.path.join("source.tar"),
            0o600,
        )?;
        if archive_metadata.len() != PRIOR_V10_SOURCE_ARCHIVE_SIZE
            || sha256_bytes(&source_archive)? != PRIOR_V10_SOURCE_ARCHIVE_SHA256
        {
            return Err(ControllerError(
                "prior v10 source archive differs from the reviewed rolled-back attempt".to_owned(),
            ));
        }
        let snapshot_executable = read_opened_regular(
            &self.snapshot_executable,
            &self.legacy_snapshot.path.join("CaptureServer"),
            0o500,
        )?;
        let snapshot_plist = read_opened_regular(
            &self.snapshot_plist,
            &self
                .legacy_snapshot
                .path
                .join("com.elamin.audiostreamer.worldwide.plist"),
            0o400,
        )?;
        if sha256_bytes(&snapshot_executable)? != LEGACY_EXECUTABLE_SHA256
            || sha256_bytes(&snapshot_plist)? != LEGACY_PLIST_SHA256
        {
            return Err(ControllerError(
                "prior v10 offline legacy snapshot changed".to_owned(),
            ));
        }
        if sha256_file(&self.staged_app.path.join("Contents/MacOS/CaptureServer"))?
            != PRIOR_V10_STAGED_EXECUTABLE_SHA256
            || sha256_file(&self.failed_app.path.join("Contents/MacOS/CaptureServer"))?
                != PRIOR_V10_STAGED_EXECUTABLE_SHA256
            || sha256_bytes(&read_opened_regular(
                &self.staged_plist,
                &self
                    .staged
                    .path
                    .join("org.example.opensteamer.worldwide.plist"),
                0o600,
            )?)? != PRIOR_V10_STAGED_PLIST_SHA256
        {
            return Err(ControllerError(
                "prior v10 staged or archived artifact hash changed".to_owned(),
            ));
        }
        if directory_manifest(&self.failed_app.path)? != directory_manifest(&self.staged_app.path)?
        {
            return Err(ControllerError(
                "prior v10 archived install hold differs from its staged app".to_owned(),
            ));
        }

        self.evidence
            .ensure_file_at_name("journal.log", &self.journal)?;
        self.records
            .ensure_file_at_name("result.txt", &self.result)?;
        self.records
            .ensure_file_at_name("provenance.txt", &self.provenance)?;
        self.records
            .ensure_file_at_name("legacy-app-tree-manifest.txt", &self.legacy_manifest)?;
        self.records
            .ensure_file_at_name("legacy-app-xattrs.txt", &self.legacy_xattrs)?;
        self.records
            .ensure_file_at_name("staged-hashes.txt", &self.staged_hashes)?;
        self.records
            .ensure_file_at_name("source-export-manifest.txt", &self.source_export_manifest)?;
        self.records
            .ensure_file_at_name("build.stdout", &self.build_stdout)?;
        self.records
            .ensure_file_at_name("build.stderr", &self.build_stderr)?;
        self.staged.ensure_file_at_name(
            "org.example.opensteamer.worldwide.plist",
            &self.staged_plist,
        )?;
        self.evidence
            .ensure_file_at_name("source.tar", &self.source_archive)?;
        private_root.ensure_file_at_name(PRIOR_V10_ACTIVE_TRANSACTION_NAME, &self.pointer)
    }
}

fn validate_prior_v10_rolledback_retry(
    private_root: &PinnedDirectory,
) -> Result<PriorV10RetryGuard> {
    for residue in [
        PRIOR_V10_ACTIVE_TRANSACTION_PENDING_NAME,
        PRIOR_V10_ACTIVE_TRANSACTION_FINALIZING_NAME,
        PRIOR_V10_ACTIVE_TRANSACTION_LINEARIZED_NAME,
    ] {
        if private_root
            .open_existing_regular(residue, false)?
            .is_some()
        {
            return Err(ControllerError(format!(
                "prior v10 active-pointer residue requires manual recovery: {residue}"
            )));
        }
    }
    let pointer =
        open_required_pinned_regular(private_root, PRIOR_V10_ACTIVE_TRANSACTION_NAME, 0o600)?;
    let pointer_bytes = read_opened_regular(
        &pointer,
        &private_root.path.join(PRIOR_V10_ACTIVE_TRANSACTION_NAME),
        0o600,
    )?;
    if pointer_bytes != PRIOR_V10_ACTIVE_RECORD {
        return Err(ControllerError(
            "prior v10 active pointer is not the exact reviewed record".to_owned(),
        ));
    }
    let evidence = parse_active_record(&pointer_bytes)?;
    if evidence != Path::new(PRIOR_V10_EVIDENCE_PATH) {
        return Err(ControllerError(
            "prior v10 active pointer resolved to unexpected evidence".to_owned(),
        ));
    }

    let evidence = PinnedDirectory::open(&evidence, Some(effective_uid()), Some(0o700))?;
    let records = evidence
        .try_open_directory_child("records", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| ControllerError("prior v10 evidence lacks records".to_owned()))?;
    let legacy_snapshot = evidence
        .try_open_directory_child("legacy-snapshot", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| ControllerError("prior v10 evidence lacks legacy snapshot".to_owned()))?;
    let failed_new = evidence
        .try_open_directory_child("failed-new", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| ControllerError("prior v10 evidence lacks failed-new".to_owned()))?;
    let failed_app = failed_new
        .try_open_directory_child("partial-install-hold", Some(effective_uid()), None)?
        .ok_or_else(|| {
            ControllerError("prior v10 evidence lacks archived install hold".to_owned())
        })?;
    let staged = evidence
        .try_open_directory_child("staged", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| ControllerError("prior v10 evidence lacks staged directory".to_owned()))?;
    let staged_app = staged
        .try_open_directory_child("opensteamer Host.app", Some(effective_uid()), None)?
        .ok_or_else(|| ControllerError("prior v10 evidence lacks staged app".to_owned()))?;
    let source_export = evidence
        .try_open_directory_child("source-export", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| {
            ControllerError("prior v10 evidence lacks source export directory".to_owned())
        })?;
    let scratch = evidence
        .try_open_directory_child("swiftpm-scratch", Some(effective_uid()), Some(0o700))?
        .ok_or_else(|| {
            ControllerError("prior v10 evidence lacks SwiftPM scratch directory".to_owned())
        })?;
    let journal = open_required_pinned_regular(&evidence, "journal.log", 0o600)?;
    let result = open_required_pinned_regular(&records, "result.txt", 0o600)?;
    let provenance = open_required_pinned_regular(&records, "provenance.txt", 0o600)?;
    let legacy_manifest =
        open_required_pinned_regular(&records, "legacy-app-tree-manifest.txt", 0o600)?;
    let legacy_xattrs = open_required_pinned_regular(&records, "legacy-app-xattrs.txt", 0o600)?;
    let staged_hashes = open_required_pinned_regular(&records, "staged-hashes.txt", 0o600)?;
    let source_export_manifest =
        open_required_pinned_regular(&records, "source-export-manifest.txt", 0o600)?;
    let build_stdout = open_required_pinned_regular(&records, "build.stdout", 0o600)?;
    let build_stderr = open_required_pinned_regular(&records, "build.stderr", 0o600)?;
    let staged_plist =
        open_required_pinned_regular(&staged, "org.example.opensteamer.worldwide.plist", 0o600)?;
    let source_archive = open_required_pinned_regular(&evidence, "source.tar", 0o600)?;
    let snapshot_executable =
        open_required_pinned_regular(&legacy_snapshot, "CaptureServer", 0o500)?;
    let snapshot_plist = open_required_pinned_regular(
        &legacy_snapshot,
        "com.elamin.audiostreamer.worldwide.plist",
        0o400,
    )?;
    let guard = PriorV10RetryGuard {
        pointer,
        evidence,
        records,
        legacy_snapshot,
        failed_new,
        failed_app,
        staged,
        staged_app,
        source_export,
        scratch,
        journal,
        result,
        provenance,
        legacy_manifest,
        legacy_xattrs,
        staged_hashes,
        source_export_manifest,
        build_stdout,
        build_stderr,
        staged_plist,
        source_archive,
        snapshot_executable,
        snapshot_plist,
    };
    guard.revalidate(private_root)?;

    let tag = guard
        .evidence
        .path
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("prior v10 evidence tag is not UTF-8".to_owned()))?;
    for residue in [
        Path::new(APPLICATIONS_DIRECTORY).join(format!(".opensteamer-disabled-v10-{tag}")),
        Path::new(APPLICATIONS_DIRECTORY).join(format!(".opensteamer-install-hold-{tag}")),
        Path::new("/Users/ahmed/Library/LaunchAgents").join(format!(
            ".org.example.opensteamer.worldwide.plist.disabled-v10-{tag}"
        )),
        Path::new("/Users/ahmed/Library/LaunchAgents").join(format!(
            ".org.example.opensteamer.worldwide.plist.install-{tag}"
        )),
    ] {
        if entry_exists(&residue)? {
            return Err(ControllerError(format!(
                "prior v10 rollback residue remains at {}",
                residue.display()
            )));
        }
    }

    let deadline = deadline_after(Duration::from_secs(15))?;
    require_new_absent()?;
    verify_legacy_static_until(deadline)?;
    verify_legacy_disabled_until(false, deadline)?;
    wait_for_exact_legacy_readiness_until(deadline)?;
    guard.revalidate(private_root)?;
    Ok(guard)
}

fn start_new(
    repo: PathBuf,
    private_root: &PinnedDirectory,
    prior_v9: PriorV9RetryGuard,
    prior_v10: PriorV10RetryGuard,
) -> Result<()> {
    let layout = Layout::create(repo)?;
    let mut journal = Journal::create(&layout.journal)?;
    let mut prior_fields = prior_v9.journal_fields();
    prior_fields.extend(prior_v10.journal_fields());
    journal.transition(State::Begun, &prior_fields)?;
    let operation = (|| {
        prior_v9.revalidate(private_root)?;
        prior_v10.revalidate(private_root)?;
        write_active(private_root, &layout.evidence)?;
        prior_v9.revalidate(private_root)?;
        prior_v10.revalidate(private_root)?;
        run_transaction(&layout, &mut journal, private_root, &prior_v9, &prior_v10)
    })();
    match operation {
        Ok(()) => {
            println!("MIGRATION_OK evidence={}", layout.evidence.display());
            println!("PHYSICAL_IPHONE_E2E=UNAVAILABLE_NOT_CLAIMED");
            Ok(())
        }
        Err(primary) => {
            if journal.state.requires_rollback() {
                match rollback(&layout, &mut journal) {
                    Ok(()) => {
                        Err(ControllerError(format!(
                            "migration failed and exact legacy service was recovered; the active recovery tombstone was retained and reruns fail closed: {primary}"
                        )))
                    }
                    Err(rollback_error) => {
                        let _ = journal.transition(
                            State::CriticalFailure,
                            &[("primary", primary.to_string()), ("rollback", rollback_error.to_string())],
                        );
                        Err(ControllerError(format!(
                            "CRITICAL rollback failure; keep Mac offline; evidence={}: primary={primary}; rollback={rollback_error}",
                            layout.evidence.display()
                        )))
                    }
                }
            } else {
                Err(primary)
            }
        }
    }
}

fn recover_active(repo: PathBuf, private_root: &PinnedDirectory) -> Result<()> {
    let evidence = read_active(private_root)?;
    let layout = Layout::open(repo, evidence)?;
    if !entry_exists(&layout.journal)? {
        let readiness_deadline = deadline_after(Duration::from_secs(15))?;
        require_new_absent()?;
        verify_legacy_static_until(readiness_deadline)?;
        verify_legacy_disabled_until(false, readiness_deadline)?;
        wait_for_exact_legacy_readiness_until(readiness_deadline)?;
        return Err(ControllerError(format!(
            "pre-journal migration tombstone retained after exact legacy readiness was verified; refusing an automatic rerun; evidence={}",
            layout.evidence.display()
        )));
    }
    let mut journal = Journal::open(&layout.journal)?;
    match journal.state {
        state if state.is_committed_family() => {
            verify_committed_runtime(&layout, &mut journal, private_root)?;
            println!(
                "MIGRATION_RECOVERY_COMMITTED evidence={}",
                layout.evidence.display()
            );
            Ok(())
        }
        State::RolledBack => {
            verify_recovered_legacy(&layout)?;
            Err(ControllerError(format!(
                "rolled-back migration tombstone retained after exact legacy recovery was verified; refusing an automatic rerun; evidence={}",
                layout.evidence.display()
            )))
        }
        State::CriticalFailure => Err(ControllerError(format!(
            "active v11 transaction is in CRITICAL_FAILURE; keep Mac offline; evidence={}",
            layout.evidence.display()
        ))),
        _ => {
            rollback(&layout, &mut journal)?;
            Err(ControllerError(format!(
                "interrupted migration was rolled back exactly; the active recovery tombstone was retained and reruns fail closed; evidence={}",
                layout.evidence.display()
            )))
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ForwardOperation {
    VerifyProvenance,
    SnapshotLegacy,
    BuildAndStage,
    VerifyPrecutover,
    DisableLegacy,
    StopLegacy,
    VerifyLockHandoff,
    InstallNew,
    BootstrapNew,
    ObserveNewPid,
    VerifyReadiness,
    Commit,
}

const FORWARD_PLAN: &[(ForwardOperation, State)] = &[
    (
        ForwardOperation::VerifyProvenance,
        State::ProvenanceVerified,
    ),
    (ForwardOperation::SnapshotLegacy, State::LegacySnapshotted),
    (ForwardOperation::BuildAndStage, State::NewStaged),
    (
        ForwardOperation::VerifyPrecutover,
        State::PrecutoverVerified,
    ),
    (ForwardOperation::DisableLegacy, State::LegacyDisabled),
    (ForwardOperation::StopLegacy, State::LegacyStopped),
    (ForwardOperation::VerifyLockHandoff, State::LockHandedOff),
    (ForwardOperation::InstallNew, State::NewInstalled),
    (ForwardOperation::BootstrapNew, State::NewBootstrapped),
    (ForwardOperation::ObserveNewPid, State::NewPidObserved),
    (ForwardOperation::VerifyReadiness, State::ReadyVerified),
    (ForwardOperation::Commit, State::Committed),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ForwardEffect {
    VerifyProvenance,
    SnapshotLegacy,
    BuildAndStage,
    VerifyPrecutover,
    DisableLegacy,
    VerifyLegacyDisabled,
    BootoutLegacy,
    WaitLegacyServiceAbsent,
    WaitLegacyProcessAbsent,
    VerifyNoCaptureServers,
    VerifyLockHandoff,
    PrepareLogs,
    CopyAppInstallHold,
    PublishApp,
    CopyPlistInstallHold,
    PublishPlist,
    VerifyInstalledDestinations,
    BootstrapNew,
    ObserveNewPid,
    CheckpointGenerationLog,
    ObserveFreshMarker,
    VerifyStableDeployment,
    VerifyCommitState,
}

trait ForwardEffectBackend {
    fn perform_effect(&mut self, effect: ForwardEffect) -> Result<()>;
    fn operation_fields(&mut self, operation: ForwardOperation) -> Result<Vec<(String, String)>>;
    fn revalidate_commit_fields(&mut self, fields: &[(String, String)]) -> Result<()>;
    fn after_commit_revalidation_before_durable_write(&mut self) -> Result<()>;
    fn committed_recorded(&mut self, fields: &[(String, String)]) -> Result<()>;
    fn before_retained_active_pointer_validation(
        &mut self,
        fields: &[(String, String)],
    ) -> Result<()>;
}

trait JournalSink {
    fn record(&mut self, state: State, fields: &[(String, String)]) -> Result<()>;
}

impl JournalSink for Journal {
    fn record(&mut self, state: State, fields: &[(String, String)]) -> Result<()> {
        let borrowed: Vec<(&str, String)> = fields
            .iter()
            .map(|(key, value)| (key.as_str(), value.clone()))
            .collect();
        self.transition(state, &borrowed)
    }
}

fn forward_effects(operation: ForwardOperation) -> &'static [ForwardEffect] {
    match operation {
        ForwardOperation::VerifyProvenance => &[ForwardEffect::VerifyProvenance],
        ForwardOperation::SnapshotLegacy => &[ForwardEffect::SnapshotLegacy],
        ForwardOperation::BuildAndStage => &[ForwardEffect::BuildAndStage],
        ForwardOperation::VerifyPrecutover => &[ForwardEffect::VerifyPrecutover],
        ForwardOperation::DisableLegacy => &[
            ForwardEffect::DisableLegacy,
            ForwardEffect::VerifyLegacyDisabled,
        ],
        ForwardOperation::StopLegacy => &[
            ForwardEffect::BootoutLegacy,
            ForwardEffect::WaitLegacyServiceAbsent,
            ForwardEffect::WaitLegacyProcessAbsent,
            ForwardEffect::VerifyNoCaptureServers,
        ],
        ForwardOperation::VerifyLockHandoff => &[ForwardEffect::VerifyLockHandoff],
        ForwardOperation::InstallNew => &[
            ForwardEffect::PrepareLogs,
            ForwardEffect::CopyAppInstallHold,
            ForwardEffect::PublishApp,
            ForwardEffect::CopyPlistInstallHold,
            ForwardEffect::PublishPlist,
            ForwardEffect::VerifyInstalledDestinations,
        ],
        ForwardOperation::BootstrapNew => &[ForwardEffect::BootstrapNew],
        ForwardOperation::ObserveNewPid => &[
            ForwardEffect::ObserveNewPid,
            ForwardEffect::CheckpointGenerationLog,
        ],
        ForwardOperation::VerifyReadiness => &[
            ForwardEffect::ObserveFreshMarker,
            ForwardEffect::VerifyStableDeployment,
        ],
        ForwardOperation::Commit => &[ForwardEffect::VerifyCommitState],
    }
}

fn drive_forward<B, J, H>(
    backend: &mut B,
    journal: &mut J,
    mut hook: H,
) -> Result<Vec<(String, String)>>
where
    B: ForwardEffectBackend,
    J: JournalSink,
    H: FnMut(usize, usize, ForwardOperation, ForwardEffect, EffectPhase) -> Result<()>,
{
    let mut committed_fields: Option<Vec<(String, String)>> = None;
    for (operation_index, (operation, state)) in FORWARD_PLAN.iter().copied().enumerate() {
        let effects = forward_effects(operation);
        for (effect_index, effect) in effects.iter().copied().enumerate() {
            hook(
                operation_index,
                effect_index,
                operation,
                effect,
                EffectPhase::BeforeSideEffect,
            )?;
            backend.perform_effect(effect)?;
            hook(
                operation_index,
                effect_index,
                operation,
                effect,
                EffectPhase::AfterSideEffect,
            )?;
        }
        let last_effect = *effects
            .last()
            .ok_or_else(|| ControllerError("forward operation has no effects".to_owned()))?;
        hook(
            operation_index,
            effects.len(),
            operation,
            last_effect,
            EffectPhase::BeforeFieldCapture,
        )?;
        let fields = backend.operation_fields(operation)?;
        hook(
            operation_index,
            effects.len(),
            operation,
            last_effect,
            EffectPhase::AfterFieldCapture,
        )?;
        if operation == ForwardOperation::Commit {
            // Capture, same-generation verification, durable write, immediate post-write
            // verification, and retained-tombstone validation form one commit protocol. A crash
            // after the durable record leaves the active pointer in place, and committed recovery
            // never accepts the historical generation without restarting and proving a fresh one.
            backend.revalidate_commit_fields(&fields)?;
            backend.after_commit_revalidation_before_durable_write()?;
            hook(
                operation_index,
                effects.len(),
                operation,
                last_effect,
                EffectPhase::AfterCommitRevalidationBeforeDurableWrite,
            )?;
        } else {
            hook(
                operation_index,
                effects.len(),
                operation,
                last_effect,
                EffectPhase::BeforeJournal,
            )?;
        }
        journal.record(state, &fields)?;
        if operation == ForwardOperation::Commit {
            backend.committed_recorded(&fields)?;
            committed_fields = Some(fields.clone());
        }
        hook(
            operation_index,
            effects.len(),
            operation,
            last_effect,
            EffectPhase::AfterJournal,
        )?;
    }
    let commit_index = FORWARD_PLAN
        .len()
        .checked_sub(1)
        .ok_or_else(|| ControllerError("forward plan is empty".to_owned()))?;
    hook(
        commit_index,
        forward_effects(ForwardOperation::Commit).len(),
        ForwardOperation::Commit,
        ForwardEffect::VerifyCommitState,
        EffectPhase::BeforeRetainedActivePointerValidation,
    )?;
    let fields = committed_fields.as_deref().ok_or_else(|| {
        ControllerError(
            "forward engine reached retained-pointer validation without durable COMMIT fields"
                .to_owned(),
        )
    })?;
    backend.before_retained_active_pointer_validation(fields)?;
    Ok(fields.to_vec())
}

struct RealForwardBackend<'a> {
    layout: &'a Layout,
    private_root: &'a PinnedDirectory,
    prior_v9: &'a PriorV9RetryGuard,
    prior_v10: &'a PriorV10RetryGuard,
    provenance: Option<Provenance>,
    verifiers: Option<PinnedVerifierSet>,
    cutover: Option<CutoverPreflight>,
    checkpoint: Option<LogCheckpoint>,
    generation: Option<LaunchGeneration>,
}

impl<'a> RealForwardBackend<'a> {
    fn new(
        layout: &'a Layout,
        private_root: &'a PinnedDirectory,
        prior_v9: &'a PriorV9RetryGuard,
        prior_v10: &'a PriorV10RetryGuard,
    ) -> Self {
        Self {
            layout,
            private_root,
            prior_v9,
            prior_v10,
            provenance: None,
            verifiers: None,
            cutover: None,
            checkpoint: None,
            generation: None,
        }
    }

    fn checkpoint_fields(&self) -> Result<Vec<(String, String)>> {
        let checkpoint = self
            .checkpoint
            .ok_or_else(|| ControllerError("forward engine has no log checkpoint".to_owned()))?;
        let mut fields = vec![
            ("log_offset".to_owned(), checkpoint.offset.to_string()),
            ("log_device".to_owned(), checkpoint.device.to_string()),
            ("log_inode".to_owned(), checkpoint.inode.to_string()),
        ];
        if let Some(generation) = &self.generation {
            fields.extend(generation_fields("", generation));
        }
        Ok(fields)
    }

    fn finalize_success(&self) -> Result<()> {
        write_record_idempotent(
            &self.layout.records.join("result.txt"),
            format!(
                "result=success\nevidence={}\nlegacy_app=untouched\nlegacy_plist=untouched\nlegacy_launchd_disabled=true\nphysical_iphone_e2e=unavailable-not-claimed\n",
                self.layout.evidence.display()
            )
            .as_bytes(),
            0o600,
        )
    }
}

impl ForwardEffectBackend for RealForwardBackend<'_> {
    fn perform_effect(&mut self, effect: ForwardEffect) -> Result<()> {
        match effect {
            ForwardEffect::VerifyProvenance => {
                self.provenance = Some(verify_provenance(self.layout)?);
                Ok(())
            }
            ForwardEffect::SnapshotLegacy => snapshot_legacy(self.layout),
            ForwardEffect::BuildAndStage => {
                let provenance = self.provenance.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks verified provenance".to_owned())
                })?;
                let verifiers = PinnedVerifierSet::open(self.layout)?;
                build_and_stage(self.layout, provenance, &verifiers)?;
                self.verifiers = Some(verifiers);
                Ok(())
            }
            ForwardEffect::VerifyPrecutover => {
                let verifiers = self.verifiers.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned verifier set".to_owned())
                })?;
                self.cutover = Some(verify_precutover(self.layout, verifiers)?);
                Ok(())
            }
            ForwardEffect::DisableLegacy => {
                self.prior_v9.revalidate(self.private_root)?;
                self.prior_v10.revalidate(self.private_root)?;
                self.verifiers
                    .as_ref()
                    .ok_or_else(|| {
                        ControllerError("forward engine lacks pinned verifier set".to_owned())
                    })?
                    .revalidate()?;
                let cutover = self.cutover.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                })?;
                cutover.revalidate()?;
                require_cutover_hidden_paths_absent(self.layout)?;
                verify_legacy_static_against_snapshot(self.layout)?;
                verify_legacy_running()?;
                require_new_absent()?;
                set_legacy_disabled(true)
            }
            ForwardEffect::VerifyLegacyDisabled => verify_legacy_disabled(true),
            ForwardEffect::BootoutLegacy => {
                self.prior_v9.revalidate(self.private_root)?;
                self.prior_v10.revalidate(self.private_root)?;
                self.verifiers
                    .as_ref()
                    .ok_or_else(|| {
                        ControllerError("forward engine lacks pinned verifier set".to_owned())
                    })?
                    .revalidate()?;
                self.cutover
                    .as_ref()
                    .ok_or_else(|| {
                        ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                    })?
                    .revalidate()?;
                require_cutover_hidden_paths_absent(self.layout)?;
                verify_legacy_static_against_snapshot(self.layout)?;
                verify_legacy_disabled(true)?;
                verify_legacy_running()?;
                require_new_absent()?;
                bootout_exact_service(LEGACY_LABEL)
            }
            ForwardEffect::WaitLegacyServiceAbsent => {
                wait_service_absent(LEGACY_LABEL, Duration::from_secs(10))
            }
            ForwardEffect::WaitLegacyProcessAbsent => {
                wait_exact_process_absent(LEGACY_EXECUTABLE, Duration::from_secs(10))
            }
            ForwardEffect::VerifyNoCaptureServers => require_no_capture_server_processes(),
            ForwardEffect::VerifyLockHandoff => prove_lock_acquirable(),
            ForwardEffect::PrepareLogs => {
                require_new_absent()?;
                self.cutover
                    .as_ref()
                    .ok_or_else(|| {
                        ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                    })?
                    .revalidate()?;
                prepare_logs()
            }
            ForwardEffect::CopyAppInstallHold => {
                let cutover = self.cutover.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                })?;
                copy_new_app_to_install_hold(self.layout, cutover)
            }
            ForwardEffect::PublishApp => {
                let cutover = self.cutover.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                })?;
                publish_new_app_from_install_hold(self.layout, &cutover.applications)
            }
            ForwardEffect::CopyPlistInstallHold => {
                let cutover = self.cutover.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                })?;
                copy_new_plist_to_install_hold(self.layout, &cutover.launch_agents)
            }
            ForwardEffect::PublishPlist => {
                let cutover = self.cutover.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                })?;
                publish_new_plist_from_install_hold(self.layout, &cutover.launch_agents)
            }
            ForwardEffect::VerifyInstalledDestinations => {
                let verifiers = self.verifiers.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned verifier set".to_owned())
                })?;
                verify_committed_destinations(self.layout, verifiers)
            }
            ForwardEffect::BootstrapNew => {
                let verifiers = self.verifiers.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned verifier set".to_owned())
                })?;
                verifiers.revalidate()?;
                verify_committed_destinations(self.layout, verifiers)?;
                verify_legacy_disabled(true)?;
                if service_state(LEGACY_LABEL)? != ServiceState::Absent
                    || !exact_process_pids(LEGACY_EXECUTABLE)?.is_empty()
                {
                    return Err(ControllerError(
                        "legacy host reappeared immediately before new bootstrap".to_owned(),
                    ));
                }
                require_new_runtime_absent()?;
                require_no_capture_server_processes()?;
                prove_lock_acquirable()?;
                require_new_runtime_absent()?;
                bootstrap_exact_plist(Path::new(NEW_PLIST))
            }
            ForwardEffect::ObserveNewPid => {
                self.generation = Some(observe_launch_generation(
                    NEW_LABEL,
                    NEW_EXECUTABLE,
                    Duration::from_secs(10),
                )?);
                Ok(())
            }
            ForwardEffect::CheckpointGenerationLog => {
                let generation = self.generation.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks a launch generation".to_owned())
                })?;
                self.checkpoint = Some(checkpoint_log_for_generation(generation)?);
                Ok(())
            }
            ForwardEffect::ObserveFreshMarker => {
                let checkpoint = self.checkpoint.ok_or_else(|| {
                    ControllerError("forward engine lacks readiness checkpoint".to_owned())
                })?;
                let generation = self.generation.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks a launch generation".to_owned())
                })?;
                wait_for_online_marker_for_generation(
                    Path::new(ONLINE_LOG),
                    &checkpoint,
                    generation,
                    Duration::from_secs(20),
                )
            }
            ForwardEffect::VerifyStableDeployment => {
                let checkpoint = self.checkpoint.ok_or_else(|| {
                    ControllerError("forward engine lacks readiness checkpoint".to_owned())
                })?;
                let generation = self.generation.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks a launch generation".to_owned())
                })?;
                let verifiers = self.verifiers.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks pinned verifier set".to_owned())
                })?;
                verify_deployment(self.layout, verifiers, generation, &checkpoint)?;
                verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
                verify_legacy_disabled(true)
            }
            ForwardEffect::VerifyCommitState => {
                let generation = self
                    .generation
                    .as_ref()
                    .ok_or_else(|| ControllerError("commit has no generation proof".to_owned()))?;
                let checkpoint = self
                    .checkpoint
                    .ok_or_else(|| ControllerError("commit has no marker checkpoint".to_owned()))?;
                verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
                require_marker_after_checkpoint(Path::new(ONLINE_LOG), &checkpoint)?;
                verify_legacy_disabled(true)?;
                if service_state(LEGACY_LABEL)? != ServiceState::Absent
                    || !exact_process_pids(LEGACY_EXECUTABLE)?.is_empty()
                {
                    return Err(ControllerError(
                        "legacy host reappeared immediately before COMMIT".to_owned(),
                    ));
                }
                verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)
            }
        }
    }

    fn operation_fields(&mut self, operation: ForwardOperation) -> Result<Vec<(String, String)>> {
        match operation {
            ForwardOperation::VerifyProvenance => {
                let provenance = self.provenance.as_ref().ok_or_else(|| {
                    ControllerError("forward engine lacks verified provenance fields".to_owned())
                })?;
                Ok(vec![
                    ("commit".to_owned(), provenance.commit.clone()),
                    ("tree".to_owned(), provenance.tree.clone()),
                ])
            }
            ForwardOperation::ObserveNewPid
            | ForwardOperation::VerifyReadiness
            | ForwardOperation::Commit => self.checkpoint_fields(),
            ForwardOperation::VerifyPrecutover => self
                .cutover
                .as_ref()
                .ok_or_else(|| {
                    ControllerError("forward engine lacks pinned cutover preflight".to_owned())
                })
                .map(CutoverPreflight::journal_fields),
            ForwardOperation::InstallNew | ForwardOperation::BootstrapNew => Ok(Vec::new()),
            ForwardOperation::SnapshotLegacy
            | ForwardOperation::BuildAndStage
            | ForwardOperation::DisableLegacy
            | ForwardOperation::StopLegacy
            | ForwardOperation::VerifyLockHandoff => Ok(Vec::new()),
        }
    }
    fn revalidate_commit_fields(&mut self, fields: &[(String, String)]) -> Result<()> {
        let expected_fields = self.checkpoint_fields()?;
        if fields != expected_fields.as_slice() {
            return Err(ControllerError(
                "COMMIT fields changed between capture and final generation revalidation"
                    .to_owned(),
            ));
        }
        let generation = self.generation.as_ref().ok_or_else(|| {
            ControllerError("final COMMIT revalidation has no generation proof".to_owned())
        })?;
        let checkpoint = self.checkpoint.ok_or_else(|| {
            ControllerError("final COMMIT revalidation has no log checkpoint".to_owned())
        })?;
        let deadline = deadline_after(Duration::from_secs(10))?;
        verify_launch_generation_until(NEW_LABEL, NEW_EXECUTABLE, generation, deadline)?;
        require_marker_after_checkpoint(Path::new(ONLINE_LOG), &checkpoint)?;
        verify_legacy_disabled_until(true, deadline)?;
        if service_state_until(LEGACY_LABEL, deadline)? != ServiceState::Absent
            || !exact_process_pids_until(LEGACY_EXECUTABLE, deadline)?.is_empty()
        {
            return Err(ControllerError(
                "legacy host reappeared during final COMMIT revalidation".to_owned(),
            ));
        }
        verify_launch_generation_until(NEW_LABEL, NEW_EXECUTABLE, generation, deadline)
    }

    fn after_commit_revalidation_before_durable_write(&mut self) -> Result<()> {
        Ok(())
    }

    fn committed_recorded(&mut self, fields: &[(String, String)]) -> Result<()> {
        // If KeepAlive changes generation after the pre-write proof, the already-durable record is
        // treated as recovery evidence while the exact active tombstone remains permanent.
        self.revalidate_commit_fields(fields)
    }

    fn before_retained_active_pointer_validation(
        &mut self,
        fields: &[(String, String)],
    ) -> Result<()> {
        self.revalidate_commit_fields(fields)
    }
}

fn run_transaction(
    layout: &Layout,
    journal: &mut Journal,
    private_root: &PinnedDirectory,
    prior_v9: &PriorV9RetryGuard,
    prior_v10: &PriorV10RetryGuard,
) -> Result<()> {
    let mut backend = RealForwardBackend::new(layout, private_root, prior_v9, prior_v10);
    let fields = drive_forward(&mut backend, journal, |_, _, _, _, _| Ok(()))?;
    release_rollback_reserve(layout, journal)?;
    backend.finalize_success()?;
    verify_retained_active_pointer_after_commit(
        private_root,
        &format!("{}\n", layout.evidence.display()).into_bytes(),
        || backend.revalidate_commit_fields(&fields),
        |_| Ok(()),
    )?;
    Ok(())
}

#[derive(Debug)]
struct Provenance {
    commit: String,
    tree: String,
    remote: String,
    upstream: String,
    archive_sha256: String,
    package_resolved_sha256: String,
}

fn verify_provenance(layout: &Layout) -> Result<Provenance> {
    let git = Path::new("/usr/bin/git");
    let status = run_command(
        git,
        &[OsStr::new("status"), OsStr::new("--porcelain=v1")],
        Some(&layout.repo),
    )?
    .require_success("git status")?;
    if !status.is_empty() {
        return Err(ControllerError(
            "repository must be clean before migration".to_owned(),
        ));
    }
    let commit = command_line(git, &["rev-parse", "HEAD"], &layout.repo, "git HEAD")?;
    let tree = command_line(git, &["rev-parse", "HEAD^{tree}"], &layout.repo, "git tree")?;
    let upstream = command_line(
        git,
        &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        &layout.repo,
        "git upstream",
    )?;
    let upstream_commit =
        command_line(git, &["rev-parse", "@{u}"], &layout.repo, "upstream commit")?;
    if upstream_commit != commit {
        return Err(ControllerError(
            "local HEAD does not equal its upstream commit".to_owned(),
        ));
    }
    let remote_name = upstream
        .split_once('/')
        .map(|(remote, _)| remote)
        .ok_or_else(|| ControllerError("upstream has no remote component".to_owned()))?;
    let remote = command_line(
        git,
        &["remote", "get-url", "--push", remote_name],
        &layout.repo,
        "git remote URL",
    )?;
    let remote_ref = upstream
        .strip_prefix(&format!("{remote_name}/"))
        .ok_or_else(|| ControllerError("upstream remote prefix is malformed".to_owned()))?;
    let ls_remote = run_command(
        git,
        &[
            OsStr::new("ls-remote"),
            OsStr::new(&remote),
            OsStr::new(&format!("refs/heads/{remote_ref}")),
        ],
        Some(&layout.repo),
    )?
    .require_success("git ls-remote")?;
    let remote_commit = ls_remote
        .split_whitespace()
        .next()
        .ok_or_else(|| ControllerError("git ls-remote returned no object".to_owned()))?;
    if remote_commit != commit {
        return Err(ControllerError(
            "pushed remote ref does not equal local HEAD".to_owned(),
        ));
    }

    let archive_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(&layout.source_archive)?;
    let archive_clone = archive_file.try_clone()?;
    let (archive_status, archive_stderr) = run_command_with_stdout_file(
        git,
        &[
            OsStr::new("archive"),
            OsStr::new("--format=tar"),
            OsStr::new("HEAD"),
        ],
        Some(&layout.repo),
        archive_clone,
        deadline_after(DEFAULT_COMMAND_TIMEOUT)?,
    )?;
    if !archive_status.success() {
        return Err(ControllerError(format!(
            "git archive failed: {}",
            archive_stderr.trim()
        )));
    }
    archive_file.sync_all()?;
    sync_parent(&layout.source_archive)?;
    let archive_sha256 = sha256_file(&layout.source_archive)?;
    run_command(
        Path::new("/usr/bin/chflags"),
        &[OsStr::new("uchg"), layout.source_archive.as_os_str()],
        None,
    )?
    .require_success("make source archive immutable")?;
    run_command(
        Path::new("/usr/bin/tar"),
        &[
            OsStr::new("-xf"),
            layout.source_archive.as_os_str(),
            OsStr::new("-C"),
            layout.source_export.as_os_str(),
        ],
        None,
    )?
    .require_success("source archive extraction")?;
    sync_directory(&layout.source_export)?;
    let live_controller_source = layout
        .repo
        .join("macOS/scripts/opensteamer-host-migration-controller.rs");
    let exported_controller_source = layout
        .source_export
        .join("macOS/scripts/opensteamer-host-migration-controller.rs");
    if fs::read(&live_controller_source)? != fs::read(&exported_controller_source)? {
        return Err(ControllerError(
            "running controller source differs from the pushed immutable export".to_owned(),
        ));
    }
    let source_export_manifest = tree_manifest(&layout.source_export)?;
    write_record(
        &layout.records.join("source-export-manifest.txt"),
        source_export_manifest.as_bytes(),
        0o600,
    )?;
    run_command(
        Path::new("/usr/bin/chflags"),
        &[
            OsStr::new("-R"),
            OsStr::new("uchg"),
            layout.source_export.as_os_str(),
        ],
        None,
    )?
    .require_success("make source export immutable")?;

    let package_resolved = locate_package_resolved(&layout.source_export)?;
    let package_resolved_sha256 = sha256_file(&package_resolved)?;
    let provenance = Provenance {
        commit,
        tree,
        remote,
        upstream,
        archive_sha256,
        package_resolved_sha256,
    };
    write_record(
        &layout.records.join("provenance.txt"),
        format!(
            "commit={}\ntree={}\nremote={}\nupstream={}\nsource_archive_sha256={}\npackage_resolved_sha256={}\n",
            provenance.commit,
            provenance.tree,
            provenance.remote,
            provenance.upstream,
            provenance.archive_sha256,
            provenance.package_resolved_sha256
        )
        .as_bytes(),
        0o600,
    )?;
    Ok(provenance)
}

fn locate_package_resolved(root: &Path) -> Result<PathBuf> {
    let candidates = [
        root.join("Package.resolved"),
        root.join(".swiftpm/configuration/Package.resolved"),
        root.join("macOS/Package.resolved"),
    ];
    let mut found = Vec::new();
    for candidate in candidates {
        match fs::symlink_metadata(&candidate) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.nlink() != 1
                {
                    return Err(ControllerError(format!(
                        "Package.resolved candidate is unsafe: {}",
                        candidate.display()
                    )));
                }
                found.push(candidate);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(ControllerError(format!(
                    "cannot inspect Package.resolved candidate: {error}"
                )))
            }
        }
    }
    if found.len() != 1 {
        return Err(ControllerError(format!(
            "expected exactly one Package.resolved, found {}",
            found.len()
        )));
    }
    Ok(found.remove(0))
}

fn snapshot_legacy(layout: &Layout) -> Result<()> {
    verify_legacy_static()?;
    verify_legacy_running()?;
    copy_exact_file(
        Path::new(LEGACY_EXECUTABLE),
        &layout.legacy_snapshot_executable,
        0o500,
    )?;
    copy_exact_file(
        Path::new(LEGACY_PLIST),
        &layout.legacy_snapshot_plist,
        0o400,
    )?;
    if sha256_file(&layout.legacy_snapshot_executable)? != LEGACY_EXECUTABLE_SHA256
        || sha256_file(&layout.legacy_snapshot_plist)? != LEGACY_PLIST_SHA256
    {
        return Err(ControllerError("legacy snapshot hash mismatch".to_owned()));
    }
    let manifest = tree_manifest(Path::new(LEGACY_APP))?;
    write_record(
        &layout.records.join("legacy-app-tree-manifest.txt"),
        manifest.as_bytes(),
        0o600,
    )?;
    let xattrs = capture_legacy_xattrs()?;
    write_record(
        &layout.records.join("legacy-app-xattrs.txt"),
        xattrs.as_bytes(),
        0o600,
    )?;
    Ok(())
}

fn build_and_stage(
    layout: &Layout,
    provenance: &Provenance,
    verifiers: &PinnedVerifierSet,
) -> Result<()> {
    let mut environment = BTreeMap::new();
    environment.insert(
        "PATH".to_owned(),
        "/usr/bin:/bin:/usr/sbin:/sbin".to_owned(),
    );
    environment.insert("HOME".to_owned(), USER_HOME.to_owned());
    environment.insert("TMPDIR".to_owned(), "/var/tmp".to_owned());
    environment.insert("LANG".to_owned(), "C".to_owned());
    environment.insert("LC_ALL".to_owned(), "C".to_owned());
    environment.insert("MACOSX_DEPLOYMENT_TARGET".to_owned(), "14.0".to_owned());
    environment.insert(
        "OPENSTEAMER_HOST_APP_OUTPUT_DIR".to_owned(),
        layout.staged.display().to_string(),
    );
    environment.insert(
        "OPENSTEAMER_HOST_SCRATCH_PATH".to_owned(),
        layout.scratch.display().to_string(),
    );
    environment.insert(
        "OPENSTEAMER_HOST_CODESIGN_IDENTITY".to_owned(),
        SIGNING_IDENTITY_SHA1.to_owned(),
    );
    environment.insert(
        "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1".to_owned(),
        SIGNING_IDENTITY_SHA1.to_owned(),
    );
    environment.insert(
        "OPENSTEAMER_EXPECTED_TEAM_ID".to_owned(),
        TEAM_ID.to_owned(),
    );
    environment.insert(
        "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE".to_owned(),
        layout.legacy_snapshot_executable.display().to_string(),
    );
    environment.insert(
        "OPENSTEAMER_REQUIRE_FRESH_RELEASE".to_owned(),
        "1".to_owned(),
    );
    environment.insert(
        "SWIFT_TREAT_WARNINGS_AS_ERRORS".to_owned(),
        "YES".to_owned(),
    );
    environment.insert(
        "OTHER_SWIFT_FLAGS".to_owned(),
        "-warnings-as-errors".to_owned(),
    );
    environment.insert("OTHER_CFLAGS".to_owned(), "-Werror".to_owned());
    environment.insert("OTHER_CPLUSPLUSFLAGS".to_owned(), "-Werror".to_owned());
    verifiers.add_helper_environment(&mut environment);
    let build = run_pinned_script_until(
        verifiers,
        &verifiers.build,
        &[],
        Some(&layout.source_export),
        &environment,
        deadline_after(BUILD_COMMAND_TIMEOUT)?,
    )?;
    write_record(
        &layout.records.join("build.stdout"),
        build.stdout.as_bytes(),
        0o600,
    )?;
    write_record(
        &layout.records.join("build.stderr"),
        build.stderr.as_bytes(),
        0o600,
    )?;
    if !build.status.success() {
        return Err(ControllerError("fresh Release build failed".to_owned()));
    }
    let exported_manifest = tree_manifest(&layout.source_export)?;
    let recorded_export_manifest =
        fs::read_to_string(layout.records.join("source-export-manifest.txt"))?;
    if exported_manifest != recorded_export_manifest {
        return Err(ControllerError(
            "immutable source export changed during the Release build".to_owned(),
        ));
    }
    if !layout.staged_app.is_dir() {
        return Err(ControllerError("fresh staged app is missing".to_owned()));
    }
    copy_exact_file(
        &layout
            .source_export
            .join("macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"),
        &layout.staged_plist,
        0o600,
    )?;
    run_pinned_script(
        verifiers,
        &verifiers.bundle,
        &[
            layout.staged_app.as_os_str(),
            OsStr::new(TEAM_ID),
            layout.legacy_snapshot_executable.as_os_str(),
        ],
        Some(&layout.source_export),
        &environment,
    )?
    .require_success("staged bundle verification")?;
    run_pinned_script(
        verifiers,
        &verifiers.launch,
        &[
            OsStr::new("--verify-plist"),
            OsStr::new(NEW_EXECUTABLE),
            layout.staged_plist.as_os_str(),
        ],
        Some(&layout.source_export),
        &environment,
    )?
    .require_success("staged LaunchAgent verification")?;
    write_record(
        &layout.records.join("staged-hashes.txt"),
        format!(
            "source_commit={}\nstaged_executable_sha256={}\nstaged_plist_sha256={}\n",
            provenance.commit,
            sha256_file(&layout.staged_app.join("Contents/MacOS/CaptureServer"))?,
            sha256_file(&layout.staged_plist)?
        )
        .as_bytes(),
        0o600,
    )?;
    Ok(())
}

struct CutoverPreflight {
    applications: PinnedDirectory,
    launch_agents: PinnedDirectory,
    records: PinnedDirectory,
    rollback_reserve: RollbackReserve,
    ditto: PinnedSystemTool,
    initial_available_bytes: u64,
}

struct RollbackReserve {
    file: File,
    device: u64,
    inode: u64,
}

impl RollbackReserve {
    fn create(records: &PinnedDirectory) -> Result<Self> {
        if records
            .open_existing_regular(ROLLBACK_RESERVE_NAME, false)?
            .is_some()
        {
            return Err(ControllerError(
                "rollback reserve already exists before pre-cutover".to_owned(),
            ));
        }
        let file = records.create_new_regular(ROLLBACK_RESERVE_NAME, 0o600)?;
        physically_preallocate(&file, ROLLBACK_RESERVE_BYTES)?;
        file.set_len(ROLLBACK_RESERVE_BYTES)?;
        file.sync_all()?;
        records.file.sync_all()?;
        let metadata = file.metadata()?;
        validate_owned_regular(&records.path.join(ROLLBACK_RESERVE_NAME), &metadata, 0o600)?;
        if metadata.len() != ROLLBACK_RESERVE_BYTES {
            return Err(ControllerError(
                "rollback reserve length differs from its physical allocation".to_owned(),
            ));
        }
        records.ensure_file_at_name(ROLLBACK_RESERVE_NAME, &file)?;
        Ok(Self {
            file,
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    fn revalidate_full(&self, records: &PinnedDirectory) -> Result<()> {
        records.ensure_file_at_name(ROLLBACK_RESERVE_NAME, &self.file)?;
        let metadata = self.file.metadata()?;
        validate_owned_regular(&records.path.join(ROLLBACK_RESERVE_NAME), &metadata, 0o600)?;
        if metadata.dev() != self.device
            || metadata.ino() != self.inode
            || metadata.len() != ROLLBACK_RESERVE_BYTES
        {
            return Err(ControllerError(
                "rollback reserve changed before the legacy stop boundary".to_owned(),
            ));
        }
        records.ensure_file_at_name(ROLLBACK_RESERVE_NAME, &self.file)
    }
}

#[cfg(target_os = "macos")]
fn physically_preallocate(file: &File, bytes: u64) -> Result<()> {
    let length = i64::try_from(bytes)
        .map_err(|_| ControllerError("rollback reserve length is too large".to_owned()))?;
    let mut store = FStore {
        flags: F_ALLOCATECONTIG_VALUE,
        posmode: F_PEOFPOSMODE_VALUE,
        offset: 0,
        length,
        bytes_allocated: 0,
    };
    // SAFETY: the file descriptor and writable FStore pointer remain valid for the call.
    let contiguous = unsafe { fcntl(file.as_raw_fd(), F_PREALLOCATE_VALUE, &mut store) };
    if contiguous != 0 || store.bytes_allocated < length {
        store.flags = F_ALLOCATEALL_VALUE;
        store.bytes_allocated = 0;
        // SAFETY: same valid descriptor and FStore pointer; this is the documented fallback.
        if unsafe { fcntl(file.as_raw_fd(), F_PREALLOCATE_VALUE, &mut store) } != 0 {
            return Err(ControllerError(format!(
                "cannot physically allocate rollback reserve: {}",
                io::Error::last_os_error()
            )));
        }
    }
    if store.bytes_allocated < length {
        return Err(ControllerError(format!(
            "rollback reserve allocated {} bytes, expected at least {length}",
            store.bytes_allocated
        )));
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn physically_preallocate(file: &File, bytes: u64) -> Result<()> {
    let mut writer = file.try_clone()?;
    writer.seek(SeekFrom::Start(0))?;
    let block = [0x5au8; 64 * 1024];
    let mut remaining = bytes;
    while remaining != 0 {
        let length = usize::try_from(remaining.min(block.len() as u64))
            .map_err(|_| ControllerError("rollback reserve chunk overflowed".to_owned()))?;
        writer.write_all(&block[..length])?;
        remaining -= length as u64;
    }
    writer.sync_all()?;
    Ok(())
}

#[derive(Clone, Copy)]
struct CutoverParentIdentities {
    applications_device: u64,
    applications_inode: u64,
    launch_agents_device: u64,
    launch_agents_inode: u64,
}

impl CutoverPreflight {
    fn open(layout: &Layout) -> Result<Self> {
        let initial_available_bytes = require_precutover_disk_headroom()?;
        let records = PinnedDirectory::open(&layout.records, Some(effective_uid()), Some(0o700))?;
        let rollback_reserve = RollbackReserve::create(&records)?;
        Ok(Self {
            applications: PinnedDirectory::open_applications()?,
            launch_agents: PinnedDirectory::open(
                Path::new("/Users/ahmed/Library/LaunchAgents"),
                Some(effective_uid()),
                None,
            )?,
            records,
            rollback_reserve,
            ditto: PinnedSystemTool::open(Path::new("/usr/bin/ditto"), DITTO_SHA256)?,
            initial_available_bytes,
        })
    }

    fn revalidate(&self) -> Result<()> {
        self.applications.prove_write_execute_and_sync()?;
        self.launch_agents.prove_write_execute_and_sync()?;
        self.rollback_reserve.revalidate_full(&self.records)?;
        self.ditto.revalidate()?;
        require_precutover_disk_headroom()?;
        Ok(())
    }

    fn journal_fields(&self) -> Vec<(String, String)> {
        vec![
            (
                "applications_device".to_owned(),
                self.applications.device.to_string(),
            ),
            (
                "applications_inode".to_owned(),
                self.applications.inode.to_string(),
            ),
            (
                "launch_agents_device".to_owned(),
                self.launch_agents.device.to_string(),
            ),
            (
                "launch_agents_inode".to_owned(),
                self.launch_agents.inode.to_string(),
            ),
            (
                "precutover_available_bytes".to_owned(),
                self.initial_available_bytes.to_string(),
            ),
            (
                "rollback_reserve_device".to_owned(),
                self.rollback_reserve.device.to_string(),
            ),
            (
                "rollback_reserve_inode".to_owned(),
                self.rollback_reserve.inode.to_string(),
            ),
            (
                "rollback_reserve_bytes".to_owned(),
                ROLLBACK_RESERVE_BYTES.to_string(),
            ),
        ]
    }
}

fn parse_posix_df_available_bytes(output: &str) -> Result<u64> {
    let lines: Vec<&str> = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    if lines.len() != 2 {
        return Err(ControllerError(format!(
            "df returned {} nonempty lines, expected exactly two",
            lines.len()
        )));
    }
    let fields: Vec<&str> = lines[1].split_whitespace().collect();
    if fields.len() != 6 {
        return Err(ControllerError(format!(
            "df data row has {} fields, expected exactly six",
            fields.len()
        )));
    }
    let available_kib = fields[3]
        .parse::<u64>()
        .map_err(|_| ControllerError("df available-block count is malformed".to_owned()))?;
    available_kib
        .checked_mul(1024)
        .ok_or_else(|| ControllerError("df available-byte count overflowed".to_owned()))
}

fn available_bytes_for(path: &Path) -> Result<u64> {
    let output = run_command(
        Path::new("/bin/df"),
        &[OsStr::new("-P"), OsStr::new("-k"), path.as_os_str()],
        None,
    )?
    .require_success("pre-cutover disk headroom")?;
    parse_posix_df_available_bytes(&output)
}

fn require_precutover_disk_headroom() -> Result<u64> {
    let available = available_bytes_for(Path::new(PRIVATE_ROOT))?
        .min(available_bytes_for(Path::new(APPLICATIONS_DIRECTORY))?);
    if available < MINIMUM_PRECUTOVER_AVAILABLE_BYTES {
        return Err(ControllerError(format!(
            "pre-cutover disk headroom is {available} bytes, below the required {MINIMUM_PRECUTOVER_AVAILABLE_BYTES} bytes"
        )));
    }
    Ok(available)
}

fn require_cutover_hidden_paths_absent(layout: &Layout) -> Result<()> {
    let (disabled_app, disabled_plist, install_app_hold, install_plist_hold) =
        rollback_hidden_paths(layout)?;
    require_paths_absent(&[
        disabled_app,
        disabled_plist,
        install_app_hold,
        install_plist_hold,
    ])
}

fn require_paths_absent(paths: &[PathBuf]) -> Result<()> {
    for path in paths {
        if entry_exists(&path)? {
            return Err(ControllerError(format!(
                "transaction-specific hidden cutover path already exists: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn verify_precutover(layout: &Layout, verifiers: &PinnedVerifierSet) -> Result<CutoverPreflight> {
    let cutover = CutoverPreflight::open(layout)?;
    cutover.revalidate()?;
    require_cutover_hidden_paths_absent(layout)?;
    validate_logs_precutover()?;
    let mut environment = fixed_child_environment();
    verifiers.add_helper_environment(&mut environment);
    let deployment_parser = run_pinned_script(
        verifiers,
        &verifiers.deployment,
        &[OsStr::new("--self-test-disabled-parser")],
        Some(&layout.source_export),
        &environment,
    )?
    .require_success("deployment disabled-state parser self-test")?;
    if deployment_parser.trim() != "SELF_TEST_OK disabled-parser" {
        return Err(ControllerError(
            "deployment disabled-state parser self-test returned unexpected output".to_owned(),
        ));
    }
    verify_legacy_static()?;
    verify_legacy_disabled(false)?;
    verify_legacy_running()?;
    require_new_absent()?;
    prove_lock_held_by_legacy()?;
    let current_manifest = tree_manifest(Path::new(LEGACY_APP))?;
    let recorded = fs::read_to_string(layout.records.join("legacy-app-tree-manifest.txt"))?;
    if current_manifest != recorded {
        return Err(ControllerError(
            "legacy app tree changed after snapshot".to_owned(),
        ));
    }
    let current_xattrs = capture_legacy_xattrs()?;
    let recorded_xattrs = fs::read_to_string(layout.records.join("legacy-app-xattrs.txt"))?;
    if current_xattrs != recorded_xattrs {
        return Err(ControllerError(
            "legacy app extended attributes changed after snapshot".to_owned(),
        ));
    }
    require_cutover_hidden_paths_absent(layout)?;
    cutover.revalidate()?;
    Ok(cutover)
}

fn copy_new_app_to_install_hold(layout: &Layout, cutover: &CutoverPreflight) -> Result<()> {
    let applications = &cutover.applications;
    cutover.ditto.revalidate()?;
    applications.revalidate()?;
    require_new_absent()?;
    let install_hold = layout.install_app_hold()?;
    if install_hold.parent() != Some(applications.path.as_path()) {
        return Err(ControllerError(
            "install app hold escaped the pinned Applications directory".to_owned(),
        ));
    }
    if entry_exists(&install_hold)? {
        return Err(ControllerError(format!(
            "install app hold already exists: {}",
            install_hold.display()
        )));
    }
    run_command(
        Path::new("/usr/bin/ditto"),
        &[layout.staged_app.as_os_str(), install_hold.as_os_str()],
        None,
    )?
    .require_success("copy staged app to install hold")?;
    cutover.ditto.revalidate()?;
    applications.revalidate()?;
    let hold_name = install_hold
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("install app hold name is not UTF-8".to_owned()))?;
    let _hold = applications
        .try_open_directory_child(hold_name, Some(effective_uid()), None)?
        .ok_or_else(|| ControllerError("install app hold disappeared after copy".to_owned()))?;
    applications.revalidate()
}

fn publish_directory_hold(
    parent: &PinnedDirectory,
    hold_name: &str,
    destination_name: &str,
) -> Result<()> {
    let hold = parent.path.join(hold_name);
    let destination = parent.path.join(destination_name);
    validate_real_directory(&hold)?;
    if entry_exists(&destination)? {
        return Err(ControllerError(format!(
            "directory destination appeared before exclusive publication: {}",
            destination.display()
        )));
    }
    parent.rename_exclusive(hold_name, destination_name)?;
    validate_real_directory(&destination)
}

fn publish_regular_file_hold(
    parent: &PinnedDirectory,
    hold_name: &str,
    destination_name: &str,
    mode: u32,
) -> Result<()> {
    let hold = parent.path.join(hold_name);
    let destination = parent.path.join(destination_name);
    validate_real_file(&hold, Some(mode))?;
    if entry_exists(&destination)? {
        return Err(ControllerError(format!(
            "file destination appeared before exclusive publication: {}",
            destination.display()
        )));
    }
    parent.rename_exclusive(hold_name, destination_name)?;
    validate_real_file(&destination, Some(mode))?;
    Ok(())
}

fn publish_new_app_from_install_hold(
    layout: &Layout,
    applications: &PinnedDirectory,
) -> Result<()> {
    applications.revalidate()?;
    let install_hold = layout.install_app_hold()?;
    let app_hold_name = install_hold
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("install app hold name is not UTF-8".to_owned()))?;
    publish_directory_hold(applications, app_hold_name, "opensteamer Host.app")
}

fn copy_new_plist_to_install_hold(layout: &Layout, launch_agents: &PinnedDirectory) -> Result<()> {
    launch_agents.revalidate()?;
    let plist_hold = layout.install_plist_hold()?;
    if plist_hold.parent() != Some(launch_agents.path.as_path()) {
        return Err(ControllerError(
            "install plist hold escaped the pinned LaunchAgents directory".to_owned(),
        ));
    }
    if entry_exists(&plist_hold)? {
        return Err(ControllerError(format!(
            "install plist hold already exists: {}",
            plist_hold.display()
        )));
    }
    copy_exact_file(&layout.staged_plist, &plist_hold, 0o600)?;
    launch_agents.revalidate()?;
    let hold_name = plist_hold
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("install plist hold name is not UTF-8".to_owned()))?;
    let hold = launch_agents
        .open_existing_regular(hold_name, false)?
        .ok_or_else(|| ControllerError("install plist hold disappeared after copy".to_owned()))?;
    validate_owned_regular(&plist_hold, &hold.metadata()?, 0o600)?;
    launch_agents.ensure_file_at_name(hold_name, &hold)
}

fn publish_new_plist_from_install_hold(
    layout: &Layout,
    launch_agents: &PinnedDirectory,
) -> Result<()> {
    launch_agents.revalidate()?;
    let plist_hold = layout.install_plist_hold()?;
    let plist_hold_name = plist_hold
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("install plist hold name is not UTF-8".to_owned()))?;
    publish_regular_file_hold(
        launch_agents,
        plist_hold_name,
        "org.example.opensteamer.worldwide.plist",
        0o600,
    )
}

fn verify_committed_destinations(layout: &Layout, verifiers: &PinnedVerifierSet) -> Result<()> {
    verify_legacy_static_against_snapshot(layout)?;
    validate_real_directory(Path::new(NEW_APP))?;
    validate_real_file(Path::new(NEW_PLIST), Some(0o600))?;
    if directory_manifest(&layout.staged_app)? != directory_manifest(Path::new(NEW_APP))? {
        return Err(ControllerError(
            "installed app differs from staged app".to_owned(),
        ));
    }
    if fs::read(&layout.staged_plist)? != fs::read(NEW_PLIST)? {
        return Err(ControllerError(
            "installed plist differs from staged plist".to_owned(),
        ));
    }
    let mut environment = fixed_child_environment();
    verifiers.add_helper_environment(&mut environment);
    run_pinned_script(
        verifiers,
        &verifiers.bundle,
        &[
            OsStr::new(NEW_APP),
            OsStr::new(TEAM_ID),
            layout.legacy_snapshot_executable.as_os_str(),
        ],
        Some(&layout.source_export),
        &environment,
    )?
    .require_success("installed bundle verification")?;
    run_pinned_script(
        verifiers,
        &verifiers.launch,
        &[
            OsStr::new("--verify-plist"),
            OsStr::new(NEW_EXECUTABLE),
            OsStr::new(NEW_PLIST),
        ],
        Some(&layout.source_export),
        &environment,
    )?
    .require_success("installed LaunchAgent verification")?;
    Ok(())
}

fn verify_deployment(
    layout: &Layout,
    verifiers: &PinnedVerifierSet,
    generation: &LaunchGeneration,
    log_checkpoint: &LogCheckpoint,
) -> Result<()> {
    verify_deployment_with_prefix(layout, verifiers, generation, log_checkpoint, "deployment")
}

fn verify_deployment_with_prefix(
    layout: &Layout,
    verifiers: &PinnedVerifierSet,
    generation: &LaunchGeneration,
    log_checkpoint: &LogCheckpoint,
    record_prefix: &str,
) -> Result<()> {
    verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
    require_marker_after_checkpoint(Path::new(ONLINE_LOG), log_checkpoint)?;
    let controller_binary = env::var_os("OPENSTEAMER_MIGRATION_CONTROLLER_BINARY")
        .map(PathBuf::from)
        .unwrap_or(env::current_exe()?);
    validate_real_file(&controller_binary, None)?;
    let log_offset = log_checkpoint.offset.to_string();
    let log_device = log_checkpoint.device.to_string();
    let log_inode = log_checkpoint.inode.to_string();
    let expected_pid = generation.pid.to_string();
    let expected_runs = generation.runs.to_string();
    let expected_lock_device = generation.lock_device.to_string();
    let expected_lock_inode = generation.lock_inode.to_string();
    let arguments = [
        layout.staged_app.as_os_str(),
        layout.legacy_snapshot_executable.as_os_str(),
        layout.staged_plist.as_os_str(),
        OsStr::new(&log_offset),
        OsStr::new(&log_device),
        OsStr::new(&log_inode),
        OsStr::new(&expected_pid),
        OsStr::new(&expected_runs),
        OsStr::new(&generation.process_start),
        OsStr::new(&generation.nonce),
        OsStr::new(&expected_lock_device),
        OsStr::new(&expected_lock_inode),
    ];
    let mut environment = fixed_child_environment();
    environment.insert(
        "OPENSTEAMER_MIGRATION_CONTROLLER_BINARY".to_owned(),
        controller_binary.display().to_string(),
    );
    verifiers.add_helper_environment(&mut environment);
    let output = run_pinned_script(
        verifiers,
        &verifiers.deployment,
        &arguments,
        Some(&layout.source_export),
        &environment,
    )?;
    let CommandOutput {
        status,
        stdout,
        stderr,
    } = output;
    let unique_prefix = if record_prefix == "deployment" {
        record_prefix.to_owned()
    } else {
        format!("{record_prefix}-{}", process::id())
    };
    write_record(
        &layout.records.join(format!("{unique_prefix}.stdout")),
        stdout.as_bytes(),
        0o600,
    )?;
    write_record(
        &layout.records.join(format!("{unique_prefix}.stderr")),
        stderr.as_bytes(),
        0o600,
    )?;
    if !status.success() {
        return Err(ControllerError(format!(
            "stable deployment oracle failed with {:?}",
            status.code()
        )));
    }
    verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
    require_marker_after_checkpoint(Path::new(ONLINE_LOG), log_checkpoint)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EffectPhase {
    BeforeSideEffect,
    AfterSideEffect,
    BeforeFieldCapture,
    AfterFieldCapture,
    BeforeJournal,
    AfterCommitRevalidationBeforeDurableWrite,
    AfterJournal,
    BeforeRetainedActivePointerValidation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommittedRecoveryOperation {
    VerifyCommittedDestinations,
    StopCurrentNew,
    BootstrapNew,
    ObserveCurrentGeneration,
    CheckpointCurrentGeneration,
    ObserveFreshMarker,
    VerifyStableCurrentGeneration,
}

trait CommittedRecoveryBackend {
    fn perform(&mut self, operation: CommittedRecoveryOperation) -> Result<Vec<(String, String)>>;
}

fn committed_recovery_state(operation: CommittedRecoveryOperation) -> Option<State> {
    match operation {
        CommittedRecoveryOperation::BootstrapNew => Some(State::CommittedRecoveryStarted),
        CommittedRecoveryOperation::ObserveCurrentGeneration => {
            Some(State::CommittedRecoveryBootstrapped)
        }
        CommittedRecoveryOperation::VerifyStableCurrentGeneration => {
            Some(State::CommittedRecoveryReady)
        }
        CommittedRecoveryOperation::VerifyCommittedDestinations
        | CommittedRecoveryOperation::StopCurrentNew
        | CommittedRecoveryOperation::CheckpointCurrentGeneration
        | CommittedRecoveryOperation::ObserveFreshMarker => None,
    }
}

fn drive_committed_recovery<B, J, H>(backend: &mut B, journal: &mut J, mut hook: H) -> Result<()>
where
    B: CommittedRecoveryBackend,
    J: JournalSink,
    H: FnMut(usize, CommittedRecoveryOperation, EffectPhase) -> Result<()>,
{
    const PLAN: &[CommittedRecoveryOperation] = &[
        CommittedRecoveryOperation::VerifyCommittedDestinations,
        CommittedRecoveryOperation::StopCurrentNew,
        CommittedRecoveryOperation::BootstrapNew,
        CommittedRecoveryOperation::ObserveCurrentGeneration,
        CommittedRecoveryOperation::CheckpointCurrentGeneration,
        CommittedRecoveryOperation::ObserveFreshMarker,
        CommittedRecoveryOperation::VerifyStableCurrentGeneration,
    ];
    for (index, operation) in PLAN.iter().copied().enumerate() {
        hook(index, operation, EffectPhase::BeforeSideEffect)?;
        let fields = backend.perform(operation)?;
        hook(index, operation, EffectPhase::AfterSideEffect)?;
        if let Some(state) = committed_recovery_state(operation) {
            journal.record(state, &fields)?;
            hook(index, operation, EffectPhase::AfterJournal)?;
        }
    }
    Ok(())
}

struct RealCommittedRecoveryBackend<'a> {
    layout: &'a Layout,
    verifiers: PinnedVerifierSet,
    historical_pid: u32,
    historical_nonce: String,
    checkpoint: Option<LogCheckpoint>,
    current_generation: Option<LaunchGeneration>,
}

impl RealCommittedRecoveryBackend<'_> {
    fn recovery_fields(&self) -> Result<Vec<(String, String)>> {
        let generation = self.current_generation.as_ref().ok_or_else(|| {
            ControllerError("committed recovery has no current launch generation".to_owned())
        })?;
        let mut fields = generation_fields("recovery_", generation);
        if let Some(checkpoint) = self.checkpoint {
            fields.extend([
                (
                    "recovery_log_offset".to_owned(),
                    checkpoint.offset.to_string(),
                ),
                (
                    "recovery_log_device".to_owned(),
                    checkpoint.device.to_string(),
                ),
                (
                    "recovery_log_inode".to_owned(),
                    checkpoint.inode.to_string(),
                ),
            ]);
        }
        fields.push(("historical_pid".to_owned(), self.historical_pid.to_string()));
        fields.push(("historical_nonce".to_owned(), self.historical_nonce.clone()));
        Ok(fields)
    }

    fn revalidate_current_generation_for_retained_pointer(&self) -> Result<()> {
        let checkpoint = self.checkpoint.ok_or_else(|| {
            ControllerError(
                "committed recovery retained-pointer validation lacks a checkpoint".to_owned(),
            )
        })?;
        let generation = self.current_generation.as_ref().ok_or_else(|| {
            ControllerError(
                "committed recovery retained-pointer validation lacks a generation".to_owned(),
            )
        })?;
        if generation.pid == self.historical_pid || generation.nonce == self.historical_nonce {
            return Err(ControllerError(
                "committed recovery retained-pointer validation resolved to the historical generation"
                    .to_owned(),
            ));
        }
        let deadline = deadline_after(Duration::from_secs(10))?;
        verify_launch_generation_until(NEW_LABEL, NEW_EXECUTABLE, generation, deadline)?;
        require_marker_after_checkpoint(Path::new(ONLINE_LOG), &checkpoint)?;
        verify_legacy_disabled_until(true, deadline)?;
        if service_state_until(LEGACY_LABEL, deadline)? != ServiceState::Absent
            || !exact_process_pids_until(LEGACY_EXECUTABLE, deadline)?.is_empty()
        {
            return Err(ControllerError(
                "legacy host appeared during committed-recovery retained-pointer validation"
                    .to_owned(),
            ));
        }
        verify_launch_generation_until(NEW_LABEL, NEW_EXECUTABLE, generation, deadline)
    }
}

impl CommittedRecoveryBackend for RealCommittedRecoveryBackend<'_> {
    fn perform(&mut self, operation: CommittedRecoveryOperation) -> Result<Vec<(String, String)>> {
        match operation {
            CommittedRecoveryOperation::VerifyCommittedDestinations => {
                verify_committed_destinations(self.layout, &self.verifiers)?;
                verify_legacy_static_against_snapshot(self.layout)?;
                verify_legacy_disabled(true)?;
                if service_state(LEGACY_LABEL)? != ServiceState::Absent {
                    return Err(ControllerError(
                        "legacy service is loaded during committed recovery".to_owned(),
                    ));
                }
                wait_exact_process_absent(LEGACY_EXECUTABLE, Duration::from_secs(2))?;
                Ok(Vec::new())
            }
            CommittedRecoveryOperation::StopCurrentNew => {
                if service_state(NEW_LABEL)? == ServiceState::Loaded {
                    bootout_exact_service(NEW_LABEL)?;
                }
                wait_service_absent(NEW_LABEL, Duration::from_secs(10))?;
                wait_exact_process_absent(NEW_EXECUTABLE, Duration::from_secs(10))?;
                require_no_capture_server_processes()?;
                prove_lock_acquirable()?;
                Ok(Vec::new())
            }
            CommittedRecoveryOperation::BootstrapNew => {
                prepare_logs()?;
                self.verifiers.revalidate()?;
                verify_committed_destinations(self.layout, &self.verifiers)?;
                verify_legacy_disabled(true)?;
                if service_state(LEGACY_LABEL)? != ServiceState::Absent
                    || !exact_process_pids(LEGACY_EXECUTABLE)?.is_empty()
                {
                    return Err(ControllerError(
                        "legacy host appeared immediately before committed-recovery bootstrap"
                            .to_owned(),
                    ));
                }
                require_new_runtime_absent()?;
                require_no_capture_server_processes()?;
                prove_lock_acquirable()?;
                require_new_runtime_absent()?;
                bootstrap_exact_plist(Path::new(NEW_PLIST))?;
                Ok(Vec::new())
            }
            CommittedRecoveryOperation::ObserveCurrentGeneration => {
                let generation =
                    observe_launch_generation(NEW_LABEL, NEW_EXECUTABLE, Duration::from_secs(10))?;
                if generation.pid == self.historical_pid {
                    return Err(ControllerError(
                        "committed recovery reused the historical PID; refusing a PID-reuse ambiguity"
                            .to_owned(),
                    ));
                }
                if generation.nonce == self.historical_nonce {
                    return Err(ControllerError(
                        "committed recovery did not publish a fresh generation nonce".to_owned(),
                    ));
                }
                self.current_generation = Some(generation);
                self.recovery_fields()
            }
            CommittedRecoveryOperation::CheckpointCurrentGeneration => {
                let generation = self.current_generation.as_ref().ok_or_else(|| {
                    ControllerError(
                        "committed recovery checkpoint lacks a launch generation".to_owned(),
                    )
                })?;
                self.checkpoint = Some(checkpoint_log_for_generation(generation)?);
                self.recovery_fields()
            }
            CommittedRecoveryOperation::ObserveFreshMarker => {
                let checkpoint = self.checkpoint.ok_or_else(|| {
                    ControllerError("committed recovery marker check lacks a checkpoint".to_owned())
                })?;
                let generation = self.current_generation.as_ref().ok_or_else(|| {
                    ControllerError("committed recovery marker check lacks a generation".to_owned())
                })?;
                wait_for_online_marker_for_generation(
                    Path::new(ONLINE_LOG),
                    &checkpoint,
                    generation,
                    Duration::from_secs(20),
                )?;
                Ok(Vec::new())
            }
            CommittedRecoveryOperation::VerifyStableCurrentGeneration => {
                let checkpoint = self.checkpoint.ok_or_else(|| {
                    ControllerError(
                        "committed recovery stability check lacks a checkpoint".to_owned(),
                    )
                })?;
                let generation = self.current_generation.as_ref().ok_or_else(|| {
                    ControllerError(
                        "committed recovery stability check lacks a generation".to_owned(),
                    )
                })?;
                verify_deployment_with_prefix(
                    self.layout,
                    &self.verifiers,
                    generation,
                    &checkpoint,
                    "deployment-committed-recovery",
                )?;
                verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
                require_marker_after_checkpoint(Path::new(ONLINE_LOG), &checkpoint)?;
                verify_legacy_disabled(true)?;
                if service_state(LEGACY_LABEL)? != ServiceState::Absent
                    || !exact_process_pids(LEGACY_EXECUTABLE)?.is_empty()
                {
                    return Err(ControllerError(
                        "legacy host appeared during committed recovery".to_owned(),
                    ));
                }
                verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
                self.recovery_fields()
            }
        }
    }
}

fn verify_committed_runtime(
    layout: &Layout,
    journal: &mut Journal,
    private_root: &PinnedDirectory,
) -> Result<()> {
    release_rollback_reserve(layout, journal)?;
    let historical_pid = journal
        .fields
        .get("pid")
        .ok_or_else(|| ControllerError("COMMIT journal has no historical PID".to_owned()))?
        .parse::<u32>()
        .map_err(|_| ControllerError("COMMIT historical PID is malformed".to_owned()))?;
    let historical_nonce = journal.fields.get("nonce").cloned().ok_or_else(|| {
        ControllerError("COMMIT journal has no historical generation nonce".to_owned())
    })?;
    let verifiers = PinnedVerifierSet::open(layout)?;
    let mut backend = RealCommittedRecoveryBackend {
        layout,
        verifiers,
        historical_pid,
        historical_nonce,
        checkpoint: None,
        current_generation: None,
    };
    drive_committed_recovery(&mut backend, journal, |_, _, _| Ok(()))?;
    write_record_idempotent(
        &layout.records.join("result.txt"),
        format!(
            "result=success\nevidence={}\nlegacy_app=untouched\nlegacy_plist=untouched\nlegacy_launchd_disabled=true\nphysical_iphone_e2e=unavailable-not-claimed\n",
            layout.evidence.display()
        )
        .as_bytes(),
        0o600,
    )?;
    verify_retained_active_pointer_after_commit(
        private_root,
        &format!("{}\n", layout.evidence.display()).into_bytes(),
        || backend.revalidate_current_generation_for_retained_pointer(),
        |_| Ok(()),
    )?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RollbackMode {
    BeforeLegacyStop,
    LegacyStillRunning,
    FullRestore,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RollbackOperation {
    Begin,
    VerifyBeforeStop,
    StopNew,
    ClearNewDestinations,
    EnableLegacy,
    BootstrapLegacy,
    VerifyLegacy,
    ArchiveEvidence,
    Finish,
}

trait RollbackBackend {
    fn legacy_is_loaded(&mut self) -> Result<bool>;
    fn perform(&mut self, mode: RollbackMode, operation: RollbackOperation) -> Result<()>;
}

fn rollback_state(operation: RollbackOperation) -> Option<State> {
    match operation {
        RollbackOperation::Begin => Some(State::RollbackStarted),
        RollbackOperation::StopNew => Some(State::NewStopped),
        RollbackOperation::ClearNewDestinations => Some(State::NewDestinationsCleared),
        RollbackOperation::EnableLegacy => Some(State::LegacyReenabled),
        RollbackOperation::BootstrapLegacy => Some(State::LegacyBootstrapped),
        RollbackOperation::VerifyLegacy => Some(State::LegacyRecovered),
        RollbackOperation::Finish => Some(State::RolledBack),
        RollbackOperation::VerifyBeforeStop | RollbackOperation::ArchiveEvidence => None,
    }
}

fn drive_rollback<B, J, H>(
    backend: &mut B,
    journal: &mut J,
    crossed_legacy_stop_boundary: bool,
    legacy_disable_was_journaled: bool,
    mut hook: H,
) -> Result<RollbackMode>
where
    B: RollbackBackend,
    J: JournalSink,
    H: FnMut(usize, RollbackOperation, EffectPhase) -> Result<()>,
{
    let mut sequence = 0usize;
    let mut run = |backend: &mut B,
                   journal: &mut J,
                   mode: RollbackMode,
                   operation: RollbackOperation|
     -> Result<()> {
        hook(sequence, operation, EffectPhase::BeforeSideEffect)?;
        backend.perform(mode, operation)?;
        hook(sequence, operation, EffectPhase::AfterSideEffect)?;
        if let Some(state) = rollback_state(operation) {
            let fields = if operation == RollbackOperation::Begin {
                vec![
                    (
                        "legacy_disable_was_journaled".to_owned(),
                        legacy_disable_was_journaled.to_string(),
                    ),
                    ("rollback_mode".to_owned(), format!("{mode:?}")),
                ]
            } else {
                Vec::new()
            };
            journal.record(state, &fields)?;
            hook(sequence, operation, EffectPhase::AfterJournal)?;
        }
        sequence += 1;
        Ok(())
    };

    if !crossed_legacy_stop_boundary {
        let mode = RollbackMode::BeforeLegacyStop;
        run(backend, journal, mode, RollbackOperation::Begin)?;
        run(backend, journal, mode, RollbackOperation::VerifyBeforeStop)?;
        run(backend, journal, mode, RollbackOperation::EnableLegacy)?;
        run(backend, journal, mode, RollbackOperation::VerifyLegacy)?;
        run(backend, journal, mode, RollbackOperation::ArchiveEvidence)?;
        run(backend, journal, mode, RollbackOperation::Finish)?;
        return Ok(mode);
    }

    // Stop and prove the new generation absent before deciding whether the legacy process
    // actually crossed its stop boundary. This covers interruption after disable/stop intent but
    // before the legacy bootout side effect.
    let provisional_mode = RollbackMode::FullRestore;
    run(backend, journal, provisional_mode, RollbackOperation::Begin)?;
    run(
        backend,
        journal,
        provisional_mode,
        RollbackOperation::StopNew,
    )?;
    let mode = if backend.legacy_is_loaded()? {
        RollbackMode::LegacyStillRunning
    } else {
        RollbackMode::FullRestore
    };

    if mode == RollbackMode::FullRestore {
        run(
            backend,
            journal,
            mode,
            RollbackOperation::ClearNewDestinations,
        )?;
    }
    run(backend, journal, mode, RollbackOperation::EnableLegacy)?;
    if mode == RollbackMode::FullRestore {
        run(backend, journal, mode, RollbackOperation::BootstrapLegacy)?;
    }
    run(backend, journal, mode, RollbackOperation::VerifyLegacy)?;
    run(backend, journal, mode, RollbackOperation::ArchiveEvidence)?;
    run(backend, journal, mode, RollbackOperation::Finish)?;
    Ok(mode)
}

struct RealRollbackBackend<'a> {
    layout: &'a Layout,
    parent_identities: Option<CutoverParentIdentities>,
}

impl RollbackBackend for RealRollbackBackend<'_> {
    fn legacy_is_loaded(&mut self) -> Result<bool> {
        Ok(service_state(LEGACY_LABEL)? == ServiceState::Loaded)
    }

    fn perform(&mut self, mode: RollbackMode, operation: RollbackOperation) -> Result<()> {
        match operation {
            RollbackOperation::Begin => Ok(()),
            RollbackOperation::VerifyBeforeStop => {
                require_new_absent()?;
                verify_legacy_static()?;
                Ok(())
            }
            RollbackOperation::StopNew => {
                if service_state(NEW_LABEL)? == ServiceState::Loaded {
                    bootout_exact_service(NEW_LABEL)?;
                }
                wait_service_absent(NEW_LABEL, Duration::from_secs(10))?;
                wait_exact_process_absent(NEW_EXECUTABLE, Duration::from_secs(10))
            }
            RollbackOperation::ClearNewDestinations => {
                require_no_capture_server_processes()?;
                prove_lock_acquirable()?;
                let identities = self.parent_identities.ok_or_else(|| {
                    ControllerError(
                        "post-stop rollback lacks pre-cutover destination-parent identities"
                            .to_owned(),
                    )
                })?;
                clear_new_live_destinations(self.layout, identities)
            }
            RollbackOperation::EnableLegacy => {
                match mode {
                    RollbackMode::BeforeLegacyStop => {
                        require_new_absent()?;
                        verify_legacy_static()?;
                    }
                    RollbackMode::LegacyStillRunning => {
                        require_new_absent()?;
                        verify_legacy_static_against_snapshot(self.layout)?;
                    }
                    RollbackMode::FullRestore => {
                        verify_legacy_static_against_snapshot(self.layout)?;
                        prove_lock_acquirable()?;
                    }
                }
                // Idempotent enable covers interruption after the durable-disable side effect but
                // before its journal record.
                set_legacy_disabled(false)?;
                verify_legacy_disabled(false)
            }
            RollbackOperation::BootstrapLegacy => {
                if service_state(LEGACY_LABEL)? == ServiceState::Absent {
                    require_new_absent()?;
                    verify_legacy_static_against_snapshot(self.layout)?;
                    require_no_capture_server_processes()?;
                    prove_lock_acquirable()?;
                    require_new_absent()?;
                    bootstrap_exact_plist(Path::new(LEGACY_PLIST))?;
                }
                Ok(())
            }
            RollbackOperation::VerifyLegacy => match mode {
                RollbackMode::BeforeLegacyStop | RollbackMode::LegacyStillRunning => {
                    wait_for_exact_legacy_readiness(Duration::from_secs(15))
                }
                RollbackMode::FullRestore => verify_recovered_legacy(self.layout),
            },
            RollbackOperation::ArchiveEvidence => {
                // Availability has already been restored and verified before secondary evidence.
                archive_failed_new_best_effort(self.layout);
                Ok(())
            }
            RollbackOperation::Finish => {
                let bytes: &[u8] = match mode {
                    RollbackMode::BeforeLegacyStop => b"result=rolled-back-before-stop\nlegacy_launchd_disabled=false\nphysical_iphone_e2e=unavailable-not-claimed\n",
                    RollbackMode::LegacyStillRunning => b"result=rolled-back-legacy-never-stopped\nlegacy_launchd_disabled=false\nphysical_iphone_e2e=unavailable-not-claimed\n",
                    RollbackMode::FullRestore => b"result=rolled-back\nlegacy_launchd_disabled=false\nphysical_iphone_e2e=unavailable-not-claimed\n",
                };
                write_record_idempotent(&self.layout.records.join("result.txt"), bytes, 0o600)
            }
        }
    }
}

fn rollback(layout: &Layout, journal: &mut Journal) -> Result<()> {
    if let Err(error) = release_rollback_reserve(layout, journal) {
        eprintln!(
            "opensteamer migration controller: could not release rollback reserve before recovery: {error}"
        );
    }
    let legacy_service_before_rollback = service_state(LEGACY_LABEL)?;
    let crossed_legacy_stop_boundary =
        journal.saw_legacy_stopped || legacy_service_before_rollback == ServiceState::Absent;
    let legacy_disable_was_journaled = journal.saw_legacy_disabled;
    let parent_identities = if crossed_legacy_stop_boundary {
        Some(CutoverParentIdentities {
            applications_device: journal
                .required_field("applications_device")?
                .parse::<u64>()
                .map_err(|_| {
                    ControllerError("journal applications device is malformed".to_owned())
                })?,
            applications_inode: journal
                .required_field("applications_inode")?
                .parse::<u64>()
                .map_err(|_| {
                    ControllerError("journal applications inode is malformed".to_owned())
                })?,
            launch_agents_device: journal
                .required_field("launch_agents_device")?
                .parse::<u64>()
                .map_err(|_| {
                    ControllerError("journal LaunchAgents device is malformed".to_owned())
                })?,
            launch_agents_inode: journal
                .required_field("launch_agents_inode")?
                .parse::<u64>()
                .map_err(|_| {
                    ControllerError("journal LaunchAgents inode is malformed".to_owned())
                })?,
        })
    } else {
        None
    };
    let mut backend = RealRollbackBackend {
        layout,
        parent_identities,
    };
    let _mode = drive_rollback(
        &mut backend,
        journal,
        crossed_legacy_stop_boundary,
        legacy_disable_was_journaled,
        |_, _, _| Ok(()),
    )?;
    Ok(())
}

fn release_rollback_reserve(layout: &Layout, journal: &Journal) -> Result<()> {
    let device = journal.fields.get("rollback_reserve_device");
    let inode = journal.fields.get("rollback_reserve_inode");
    let bytes = journal.fields.get("rollback_reserve_bytes");
    if device.is_none() && inode.is_none() && bytes.is_none() {
        return release_unjournaled_rollback_reserve(layout);
    }
    let (device, inode, bytes) = match (device, inode, bytes) {
        (Some(device), Some(inode), Some(bytes)) => (device, inode, bytes),
        _ => {
            return Err(ControllerError(
                "journal has an incomplete rollback-reserve identity".to_owned(),
            ))
        }
    };
    let expected_device = device
        .parse::<u64>()
        .map_err(|_| ControllerError("rollback-reserve device is malformed".to_owned()))?;
    let expected_inode = inode
        .parse::<u64>()
        .map_err(|_| ControllerError("rollback-reserve inode is malformed".to_owned()))?;
    let expected_bytes = bytes
        .parse::<u64>()
        .map_err(|_| ControllerError("rollback-reserve length is malformed".to_owned()))?;
    if expected_bytes != ROLLBACK_RESERVE_BYTES {
        return Err(ControllerError(
            "journal rollback-reserve length differs from the reviewed size".to_owned(),
        ));
    }
    release_rollback_reserve_at(
        &layout.records,
        expected_device,
        expected_inode,
        expected_bytes,
    )
}

fn release_unjournaled_rollback_reserve(layout: &Layout) -> Result<()> {
    release_unjournaled_rollback_reserve_at(&layout.records)
}

fn release_unjournaled_rollback_reserve_at(records_path: &Path) -> Result<()> {
    let records = PinnedDirectory::open(records_path, Some(effective_uid()), Some(0o700))?;
    let Some(file) = records.open_existing_regular(ROLLBACK_RESERVE_NAME, true)? else {
        return Ok(());
    };
    let before = file.metadata()?;
    validate_owned_regular(&records.path.join(ROLLBACK_RESERVE_NAME), &before, 0o600)?;
    if before.len() != 0 && before.len() != ROLLBACK_RESERVE_BYTES {
        return Err(ControllerError(
            "unjournaled rollback reserve has an unreviewed length".to_owned(),
        ));
    }
    file.set_len(0)?;
    file.sync_all()?;
    records.file.sync_all()?;
    let after = file.metadata()?;
    if !same_inode(&before, &after) || after.len() != 0 {
        return Err(ControllerError(
            "unjournaled rollback reserve did not release on its pinned inode".to_owned(),
        ));
    }
    records.ensure_file_at_name(ROLLBACK_RESERVE_NAME, &file)
}

fn release_rollback_reserve_at(
    records_path: &Path,
    expected_device: u64,
    expected_inode: u64,
    expected_bytes: u64,
) -> Result<()> {
    if expected_bytes != ROLLBACK_RESERVE_BYTES {
        return Err(ControllerError(
            "rollback-reserve release received an unreviewed size".to_owned(),
        ));
    }
    let records = PinnedDirectory::open(records_path, Some(effective_uid()), Some(0o700))?;
    let file = records
        .open_existing_regular(ROLLBACK_RESERVE_NAME, true)?
        .ok_or_else(|| ControllerError("journaled rollback reserve is missing".to_owned()))?;
    let before = file.metadata()?;
    validate_owned_regular(&records.path.join(ROLLBACK_RESERVE_NAME), &before, 0o600)?;
    if before.dev() != expected_device
        || before.ino() != expected_inode
        || (before.len() != 0 && before.len() != expected_bytes)
    {
        return Err(ControllerError(
            "journaled rollback reserve identity or length changed".to_owned(),
        ));
    }
    file.set_len(0)?;
    file.sync_all()?;
    records.file.sync_all()?;
    let after = file.metadata()?;
    validate_owned_regular(&records.path.join(ROLLBACK_RESERVE_NAME), &after, 0o600)?;
    if after.dev() != expected_device || after.ino() != expected_inode || after.len() != 0 {
        return Err(ControllerError(
            "rollback reserve did not release to the same zero-length evidence inode".to_owned(),
        ));
    }
    records.ensure_file_at_name(ROLLBACK_RESERVE_NAME, &file)
}

fn rollback_hidden_paths(layout: &Layout) -> Result<(PathBuf, PathBuf, PathBuf, PathBuf)> {
    let tag = layout.transaction_tag()?;
    Ok((
        Path::new(APPLICATIONS_DIRECTORY).join(format!(".opensteamer-disabled-v11-{tag}")),
        Path::new("/Users/ahmed/Library/LaunchAgents").join(format!(
            ".org.example.opensteamer.worldwide.plist.disabled-v11-{tag}"
        )),
        layout.install_app_hold()?,
        layout.install_plist_hold()?,
    ))
}

fn clear_new_live_destinations(layout: &Layout, expected: CutoverParentIdentities) -> Result<()> {
    let (disabled_app, disabled_plist, _, _) = rollback_hidden_paths(layout)?;
    let applications = PinnedDirectory::open_applications()?;
    let launch_agents = PinnedDirectory::open(
        Path::new("/Users/ahmed/Library/LaunchAgents"),
        Some(effective_uid()),
        None,
    )?;
    if applications.device != expected.applications_device
        || applications.inode != expected.applications_inode
        || launch_agents.device != expected.launch_agents_device
        || launch_agents.inode != expected.launch_agents_inode
    {
        return Err(ControllerError(
            "destination parent identity changed after pre-cutover verification".to_owned(),
        ));
    }

    if entry_exists(Path::new(NEW_APP))? {
        validate_real_directory(Path::new(NEW_APP))?;
        if entry_exists(&disabled_app)? {
            return Err(ControllerError(
                "deterministic hidden new-app hold already exists while live app is present"
                    .to_owned(),
            ));
        }
        let disabled_name = disabled_app
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| ControllerError("disabled app hold name is not UTF-8".to_owned()))?;
        applications.rename_exclusive("opensteamer Host.app", disabled_name)?;
    }
    if entry_exists(Path::new(NEW_PLIST))? {
        validate_real_file(Path::new(NEW_PLIST), Some(0o600))?;
        if entry_exists(&disabled_plist)? {
            return Err(ControllerError(
                "deterministic hidden new-plist hold already exists while live plist is present"
                    .to_owned(),
            ));
        }
        let disabled_name = disabled_plist
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| ControllerError("disabled plist hold name is not UTF-8".to_owned()))?;
        launch_agents.rename_exclusive("org.example.opensteamer.worldwide.plist", disabled_name)?;
    }
    if entry_exists(Path::new(NEW_APP))? || entry_exists(Path::new(NEW_PLIST))? {
        return Err(ControllerError(
            "new live destinations remain during rollback".to_owned(),
        ));
    }
    Ok(())
}

fn archive_failed_new_best_effort(layout: &Layout) {
    let Ok((disabled_app, disabled_plist, install_app_hold, install_plist_hold)) =
        rollback_hidden_paths(layout)
    else {
        record_secondary_warning(
            layout,
            "hidden-paths",
            "could not derive hidden evidence paths",
        );
        return;
    };
    preserve_hidden_app_best_effort(
        layout,
        &disabled_app,
        &layout.failed_new.join("opensteamer Host.app"),
        "disabled-new-app",
    );
    preserve_hidden_plist_best_effort(
        layout,
        &disabled_plist,
        &layout
            .failed_new
            .join("org.example.opensteamer.worldwide.plist"),
        "disabled-new-plist",
    );
    preserve_hidden_app_best_effort(
        layout,
        &install_app_hold,
        &layout.failed_new.join("partial-install-hold"),
        "partial-install-app",
    );
    preserve_hidden_plist_best_effort(
        layout,
        &install_plist_hold,
        &layout.failed_new.join("partial-install-plist"),
        "partial-install-plist",
    );
}

fn preserve_hidden_app_best_effort(layout: &Layout, hidden: &Path, evidence: &Path, label: &str) {
    let operation = (|| -> Result<()> {
        if !entry_exists(hidden)? {
            return Ok(());
        }
        validate_real_directory(hidden)?;
        if entry_exists(evidence)? {
            validate_real_directory(evidence)?;
            if directory_manifest(hidden)? != directory_manifest(evidence)? {
                return Err(ControllerError(format!(
                    "existing failed-new app evidence differs from hidden hold: {}",
                    evidence.display()
                )));
            }
        } else {
            run_command(
                Path::new("/usr/bin/ditto"),
                &[hidden.as_os_str(), evidence.as_os_str()],
                None,
            )?
            .require_success("preserve hidden failed-new app")?;
            if directory_manifest(hidden)? != directory_manifest(evidence)? {
                return Err(ControllerError(
                    "failed-new app evidence differs after copy".to_owned(),
                ));
            }
        }
        remove_tree(hidden)
    })();
    if let Err(error) = operation {
        record_secondary_warning(layout, label, &error.to_string());
    }
}

fn preserve_hidden_plist_best_effort(layout: &Layout, hidden: &Path, evidence: &Path, label: &str) {
    let operation = (|| -> Result<()> {
        if !entry_exists(hidden)? {
            return Ok(());
        }
        validate_real_file(hidden, Some(0o600))?;
        if entry_exists(evidence)? {
            validate_real_file(evidence, Some(0o600))?;
            if fs::read(hidden)? != fs::read(evidence)? {
                return Err(ControllerError(format!(
                    "existing failed-new plist evidence differs from hidden hold: {}",
                    evidence.display()
                )));
            }
        } else {
            copy_exact_file(hidden, evidence, 0o600)?;
            if fs::read(hidden)? != fs::read(evidence)? {
                return Err(ControllerError(
                    "failed-new plist evidence differs after copy".to_owned(),
                ));
            }
        }
        fs::remove_file(hidden)?;
        sync_parent(hidden)
    })();
    if let Err(error) = operation {
        record_secondary_warning(layout, label, &error.to_string());
    }
}

fn record_secondary_warning(layout: &Layout, label: &str, message: &str) {
    eprintln!("opensteamer migration controller: secondary evidence warning [{label}]: {message}");
    let path = layout
        .records
        .join(format!("secondary-warning-{label}.txt"));
    if matches!(entry_exists(&path), Ok(false)) {
        let _ = write_record(
            &path,
            format!(
                "label={label}\nmessage={}\n",
                percent_encode(message.as_bytes())
            )
            .as_bytes(),
            0o600,
        );
    }
}

fn verify_recovered_legacy(layout: &Layout) -> Result<()> {
    let deadline = deadline_after(Duration::from_secs(15))?;
    verify_legacy_static_against_snapshot_until(layout, deadline)?;
    verify_legacy_disabled_until(false, deadline)?;
    if service_state_until(NEW_LABEL, deadline)? != ServiceState::Absent {
        return Err(ControllerError(
            "new service is not absent after rollback".to_owned(),
        ));
    }
    require_before_deadline(deadline, "rollback destination absence proof")?;
    if entry_exists(Path::new(NEW_APP))? || entry_exists(Path::new(NEW_PLIST))? {
        return Err(ControllerError(
            "new live destinations reappeared after rollback".to_owned(),
        ));
    }
    wait_for_exact_legacy_readiness_until(deadline)
}

fn verify_legacy_static_against_snapshot_until(layout: &Layout, deadline: Instant) -> Result<()> {
    verify_legacy_static_until(deadline)?;
    if sha256_file_until(&layout.legacy_snapshot_executable, deadline)? != LEGACY_EXECUTABLE_SHA256
        || sha256_file_until(&layout.legacy_snapshot_plist, deadline)? != LEGACY_PLIST_SHA256
    {
        return Err(ControllerError(
            "offline legacy snapshot changed".to_owned(),
        ));
    }
    require_before_deadline(deadline, "legacy tree-manifest verification")?;
    let current = tree_manifest_until(Path::new(LEGACY_APP), deadline)?;
    require_before_deadline(deadline, "legacy tree-manifest verification")?;
    let recorded = fs::read_to_string(layout.records.join("legacy-app-tree-manifest.txt"))?;
    if current != recorded {
        return Err(ControllerError(
            "legacy app full-tree manifest changed".to_owned(),
        ));
    }
    let current_xattrs = capture_legacy_xattrs_until(deadline)?;
    require_before_deadline(deadline, "legacy xattr evidence verification")?;
    let recorded_xattrs = fs::read_to_string(layout.records.join("legacy-app-xattrs.txt"))?;
    if current_xattrs != recorded_xattrs {
        return Err(ControllerError(
            "legacy app extended attributes changed".to_owned(),
        ));
    }
    require_before_deadline(deadline, "legacy static snapshot verification")
}

fn verify_legacy_static_against_snapshot(layout: &Layout) -> Result<()> {
    verify_legacy_static_against_snapshot_until(layout, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn verify_legacy_bundle_signatures_until(deadline: Instant) -> Result<()> {
    run_command_until(
        Path::new("/usr/bin/codesign"),
        &[
            OsStr::new("--verify"),
            OsStr::new("--deep"),
            OsStr::new("--strict"),
            OsStr::new("--verbose=2"),
            OsStr::new(LEGACY_APP),
        ],
        None,
        deadline,
    )?
    .require_success("legacy app nested-signature verification")?;
    Ok(())
}

fn capture_legacy_xattrs_until(deadline: Instant) -> Result<String> {
    let arguments = [OsStr::new("-lr"), OsStr::new(LEGACY_APP)];
    run_command_until(Path::new("/usr/bin/xattr"), &arguments, None, deadline)?
        .require_success("legacy app xattr capture")
}

fn capture_legacy_xattrs() -> Result<String> {
    capture_legacy_xattrs_until(deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn verify_legacy_static_until(deadline: Instant) -> Result<()> {
    require_before_deadline(deadline, "legacy static verification")?;
    validate_real_directory(Path::new(LEGACY_APP))?;
    validate_real_file(Path::new(LEGACY_EXECUTABLE), None)?;
    validate_real_file(Path::new(LEGACY_PLIST), None)?;
    if sha256_file_until(Path::new(LEGACY_EXECUTABLE), deadline)? != LEGACY_EXECUTABLE_SHA256 {
        return Err(ControllerError(
            "legacy executable hash mismatch".to_owned(),
        ));
    }
    if sha256_file_until(Path::new(LEGACY_PLIST), deadline)? != LEGACY_PLIST_SHA256 {
        return Err(ControllerError("legacy plist hash mismatch".to_owned()));
    }
    verify_code_identity_until(Path::new(LEGACY_EXECUTABLE), deadline)?;
    verify_legacy_bundle_signatures_until(deadline)?;
    let arguments = plist_arguments_until(Path::new(LEGACY_PLIST), deadline)?;
    let expected = vec![
        LEGACY_EXECUTABLE.to_owned(),
        "--worldwide".to_owned(),
        "--allow-remote-control".to_owned(),
        "--duration".to_owned(),
        "0".to_owned(),
        "--verbose".to_owned(),
    ];
    if arguments != expected {
        return Err(ControllerError(
            "legacy plist arguments differ from audited baseline".to_owned(),
        ));
    }
    require_before_deadline(deadline, "legacy static verification")
}

fn verify_legacy_static() -> Result<()> {
    verify_legacy_static_until(deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn prove_new_host_absent_during_rollback_until(deadline: Instant) -> Result<()> {
    if service_state_until(NEW_LABEL, deadline)? != ServiceState::Absent {
        return Err(ControllerError(
            "new launchd job reappeared while waiting for legacy readiness".to_owned(),
        ));
    }
    if !exact_process_pids_until(NEW_EXECUTABLE, deadline)?.is_empty() {
        return Err(ControllerError(
            "new executable reappeared while waiting for legacy readiness".to_owned(),
        ));
    }
    if entry_exists(Path::new(NEW_APP))? || entry_exists(Path::new(NEW_PLIST))? {
        return Err(ControllerError(
            "new live destination reappeared while waiting for legacy readiness".to_owned(),
        ));
    }
    Ok(())
}

fn legacy_readiness_probe_until(deadline: Instant) -> Result<bool> {
    prove_new_host_absent_during_rollback_until(deadline)?;
    if service_state_until(LEGACY_LABEL, deadline)? == ServiceState::Absent {
        return Ok(false);
    }
    let snapshot = launch_snapshot_until(LEGACY_LABEL, deadline)?;
    let parsed = parse_launch_snapshot(&snapshot, LEGACY_LABEL)?;
    let expected_arguments = vec![
        LEGACY_EXECUTABLE.to_owned(),
        "--worldwide".to_owned(),
        "--allow-remote-control".to_owned(),
        "--duration".to_owned(),
        "0".to_owned(),
        "--verbose".to_owned(),
    ];
    if parsed.program != LEGACY_EXECUTABLE || parsed.arguments != expected_arguments {
        return Err(ControllerError(
            "legacy launchd job started with the wrong program or arguments".to_owned(),
        ));
    }
    let pids = exact_process_pids_until(LEGACY_EXECUTABLE, deadline)?;
    if pids.is_empty() {
        return Ok(false);
    }
    if pids != vec![parsed.pid] {
        return Err(ControllerError(format!(
            "legacy process set {:?} differs from launchd PID {}",
            pids, parsed.pid
        )));
    }
    let captures = all_capture_server_processes_until(deadline)?;
    if captures.is_empty() {
        return Ok(false);
    }
    if captures.len() != 1 || captures[0].0 != parsed.pid || captures[0].1 != LEGACY_EXECUTABLE {
        return Err(ControllerError(
            "a wrong or concurrent CaptureServer appeared during rollback".to_owned(),
        ));
    }
    match prove_lock_held_only_by_until(parsed.pid, deadline) {
        Ok(()) => {
            prove_new_host_absent_during_rollback_until(deadline)?;
            Ok(true)
        }
        Err(error) if Instant::now() < deadline => {
            let _ = error;
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

fn wait_for_exact_legacy_readiness_until(deadline: Instant) -> Result<()> {
    verify_legacy_static_until(deadline)?;
    verify_legacy_disabled_until(false, deadline)?;
    loop {
        if legacy_readiness_probe_until(deadline)? {
            // The same monotonic deadline covers the late acceptance-boundary static, launch,
            // process, lock, and new-host-absence proofs. No nested verifier receives a fresh
            // default command budget.
            verify_legacy_static_until(deadline)?;
            verify_legacy_disabled_until(false, deadline)?;
            prove_new_host_absent_during_rollback_until(deadline)?;
            verify_legacy_running_until(deadline)?;
            prove_new_host_absent_during_rollback_until(deadline)?;
            return require_before_deadline(deadline, "rollback readiness acceptance");
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ControllerError(
                "legacy host did not reach exact startup/readiness before rollback timeout"
                    .to_owned(),
            ));
        }
        thread::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(100)),
        );
    }
}

fn wait_for_exact_legacy_readiness(timeout: Duration) -> Result<()> {
    let deadline = deadline_after(timeout)?;
    wait_for_exact_legacy_readiness_until(deadline)
}

fn verify_legacy_running_until(deadline: Instant) -> Result<()> {
    let snapshot = launch_snapshot_until(LEGACY_LABEL, deadline)?;
    let parsed = parse_launch_snapshot(&snapshot, LEGACY_LABEL)?;
    let expected_arguments = vec![
        LEGACY_EXECUTABLE.to_owned(),
        "--worldwide".to_owned(),
        "--allow-remote-control".to_owned(),
        "--duration".to_owned(),
        "0".to_owned(),
        "--verbose".to_owned(),
    ];
    if parsed.program != LEGACY_EXECUTABLE || parsed.arguments != expected_arguments {
        return Err(ControllerError(
            "legacy live launch state differs from the audited executable/arguments".to_owned(),
        ));
    }
    let pids = exact_process_pids_until(LEGACY_EXECUTABLE, deadline)?;
    if pids != vec![parsed.pid] {
        return Err(ControllerError(format!(
            "legacy process set {:?} differs from launchd PID {}",
            pids, parsed.pid
        )));
    }
    let others = all_capture_server_processes_until(deadline)?;
    if others.len() != 1 || others[0].0 != parsed.pid || others[0].1 != LEGACY_EXECUTABLE {
        return Err(ControllerError(
            "legacy host is not the sole CaptureServer".to_owned(),
        ));
    }
    prove_lock_held_only_by_until(parsed.pid, deadline)
}

fn verify_legacy_running() -> Result<()> {
    verify_legacy_running_until(deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn require_new_absent() -> Result<()> {
    if entry_exists(Path::new(NEW_APP))? || entry_exists(Path::new(NEW_PLIST))? {
        return Err(ControllerError(
            "new live destination already exists".to_owned(),
        ));
    }
    require_new_runtime_absent()
}

fn require_new_runtime_absent() -> Result<()> {
    if service_state(NEW_LABEL)? != ServiceState::Absent {
        return Err(ControllerError("new service is already loaded".to_owned()));
    }
    if !exact_process_pids(NEW_EXECUTABLE)?.is_empty() {
        return Err(ControllerError(
            "new executable is already running".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ServiceState {
    Loaded,
    Absent,
}

fn set_legacy_disabled(disabled: bool) -> Result<()> {
    let action = if disabled { "disable" } else { "enable" };
    run_command(
        Path::new("/bin/launchctl"),
        &[
            OsStr::new(action),
            OsStr::new(&format!("gui/{USER_ID}/{LEGACY_LABEL}")),
        ],
        None,
    )?
    .require_success(&format!("launchctl {action} legacy service"))?;
    verify_legacy_disabled(disabled)
}

fn parse_disabled_override(text: &str, label: &str) -> Result<Option<bool>> {
    let mut lines = text.lines().filter(|line| !line.trim().is_empty());
    let header = lines
        .next()
        .ok_or_else(|| ControllerError("launchctl print-disabled output is empty".to_owned()))?
        .trim();
    if header != "disabled services = {" {
        return Err(ControllerError(format!(
            "launchctl print-disabled header is malformed: {header}"
        )));
    }
    let prefix = format!("\"{label}\" => ");
    let mut value = None;
    let mut closed = false;
    for line in lines {
        let trimmed = line.trim();
        if closed {
            return Err(ControllerError(
                "launchctl print-disabled has data after its top-level block".to_owned(),
            ));
        }
        if trimmed == "}" {
            closed = true;
            continue;
        }
        if trimmed.contains('{') || trimmed.contains('}') {
            return Err(ControllerError(
                "launchctl print-disabled contains an unexpected nested block".to_owned(),
            ));
        }
        if let Some(raw) = trimmed.strip_prefix(&prefix) {
            if value.is_some() {
                return Err(ControllerError(format!(
                    "launchctl print-disabled returned multiple entries for '{label}'"
                )));
            }
            value = Some(match raw {
                "disabled" | "true" => true,
                "enabled" | "false" => false,
                other => {
                    return Err(ControllerError(format!(
                        "launchctl disabled-state value for '{label}' is malformed: {other}"
                    )))
                }
            });
        } else if trimmed.starts_with(&format!("\"{label}\"")) {
            return Err(ControllerError(format!(
                "launchctl disabled-state entry for '{label}' is malformed"
            )));
        } else {
            let Some((entry_label, entry_value)) = trimmed.split_once(" => ") else {
                return Err(ControllerError(
                    "launchctl print-disabled contains a malformed entry".to_owned(),
                ));
            };
            let unquoted_label = entry_label
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'));
            if unquoted_label.is_none()
                || unquoted_label.is_some_and(|value| value.contains('"'))
                || !matches!(entry_value, "enabled" | "disabled" | "true" | "false")
            {
                return Err(ControllerError(
                    "launchctl print-disabled contains an ambiguous or malformed entry".to_owned(),
                ));
            }
        }
    }
    if !closed {
        return Err(ControllerError(
            "launchctl print-disabled top-level block is not closed".to_owned(),
        ));
    }
    Ok(value)
}

fn verify_legacy_disabled_until(expected: bool, deadline: Instant) -> Result<()> {
    let output = run_command_until(
        Path::new("/bin/launchctl"),
        &[
            OsStr::new("print-disabled"),
            OsStr::new(&format!("gui/{USER_ID}")),
        ],
        None,
        deadline,
    )?
    .require_success("launchctl print-disabled")?;
    // An omitted label has no durable disable override and is therefore enabled.
    let actual = parse_disabled_override(&output, LEGACY_LABEL)?.unwrap_or(false);
    if actual != expected {
        return Err(ControllerError(format!(
            "legacy launchd disabled state is {actual}, expected {expected}"
        )));
    }
    Ok(())
}

fn verify_legacy_disabled(expected: bool) -> Result<()> {
    verify_legacy_disabled_until(expected, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn service_state_until(label: &str, deadline: Instant) -> Result<ServiceState> {
    let output = run_command_until(
        Path::new("/bin/launchctl"),
        &[
            OsStr::new("print"),
            OsStr::new(&format!("gui/{USER_ID}/{label}")),
        ],
        None,
        deadline,
    )?;
    if output.status.success() {
        return Ok(ServiceState::Loaded);
    }
    let absence_lines: Vec<&str> = output
        .stderr
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    let explicit_absence = output.stdout.trim().is_empty()
        && absence_lines
            .iter()
            .any(|line| line.starts_with("Could not find service"))
        && absence_lines
            .iter()
            .all(|line| *line == "Bad request." || line.starts_with("Could not find service"));
    if explicit_absence {
        return Ok(ServiceState::Absent);
    }
    Err(ControllerError(format!(
        "launchctl could not classify service '{label}': {}",
        output.stderr.trim()
    )))
}

fn service_state(label: &str) -> Result<ServiceState> {
    service_state_until(label, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn bootout_exact_service(label: &str) -> Result<()> {
    if service_state(label)? == ServiceState::Absent {
        return Ok(());
    }
    run_command(
        Path::new("/bin/launchctl"),
        &[
            OsStr::new("bootout"),
            OsStr::new(&format!("gui/{USER_ID}/{label}")),
        ],
        None,
    )?
    .require_success("launchctl bootout")?;
    Ok(())
}

fn bootstrap_exact_plist(plist: &Path) -> Result<()> {
    run_command(
        Path::new("/bin/launchctl"),
        &[
            OsStr::new("bootstrap"),
            OsStr::new(&format!("gui/{USER_ID}")),
            plist.as_os_str(),
        ],
        None,
    )?
    .require_success("launchctl bootstrap")?;
    Ok(())
}

fn wait_service_absent(label: &str, timeout: Duration) -> Result<()> {
    let deadline = deadline_after(timeout)?;
    loop {
        if service_state_until(label, deadline)? == ServiceState::Absent {
            return Ok(());
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ControllerError(format!(
                "service '{label}' did not become absent"
            )));
        }
        thread::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(100)),
        );
    }
}

fn wait_exact_process_absent(executable: &str, timeout: Duration) -> Result<()> {
    let deadline = deadline_after(timeout)?;
    loop {
        if exact_process_pids_until(executable, deadline)?.is_empty() {
            return Ok(());
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ControllerError(format!(
                "process '{executable}' did not become absent"
            )));
        }
        thread::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(100)),
        );
    }
}

fn launch_snapshot_until(label: &str, deadline: Instant) -> Result<String> {
    let output = run_command_until(
        Path::new("/bin/launchctl"),
        &[
            OsStr::new("print"),
            OsStr::new(&format!("gui/{USER_ID}/{label}")),
        ],
        None,
        deadline,
    )?;
    output.require_success("launchctl print")
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ParsedLaunch {
    pid: u32,
    runs: u64,
    program: String,
    arguments: Vec<String>,
}

fn parse_launch_snapshot(text: &str, expected_label: &str) -> Result<ParsedLaunch> {
    let mut lines = text.lines().filter(|line| !line.trim().is_empty());
    let header = lines
        .next()
        .ok_or_else(|| ControllerError("launchctl snapshot is empty".to_owned()))?
        .trim();
    let expected_header = format!("gui/{USER_ID}/{expected_label} = {{");
    if header != expected_header {
        return Err(ControllerError(format!(
            "launchctl snapshot header is '{header}', expected '{expected_header}'"
        )));
    }

    let mut depth = 1usize;
    let mut closed = false;
    let mut arguments_depth = None;
    let mut argument_blocks = 0usize;
    let mut arguments = Vec::new();
    let mut pid = None;
    let mut runs = None;
    let mut program = None;
    let mut pid_fields = 0usize;
    let mut runs_fields = 0usize;
    let mut program_fields = 0usize;

    for raw in lines {
        let line = raw.trim();
        if closed {
            return Err(ControllerError(
                "launchctl snapshot has data after its top-level job block".to_owned(),
            ));
        }
        if line == "}" {
            if depth == 0 {
                return Err(ControllerError(
                    "launchctl snapshot has an unmatched closing brace".to_owned(),
                ));
            }
            if arguments_depth == Some(depth) {
                arguments_depth = None;
            }
            depth -= 1;
            if depth == 0 {
                closed = true;
            }
            continue;
        }
        if line.ends_with(" = {") {
            if depth == 1 && line == "arguments = {" {
                argument_blocks += 1;
                if argument_blocks != 1 {
                    return Err(ControllerError(
                        "launchctl snapshot has multiple top-level arguments blocks".to_owned(),
                    ));
                }
                depth += 1;
                arguments_depth = Some(depth);
                continue;
            }
            if arguments_depth == Some(depth) {
                return Err(ControllerError(
                    "launchctl arguments block contains a nested block".to_owned(),
                ));
            }
            depth += 1;
            continue;
        }
        if line.contains('{') || line.contains('}') {
            return Err(ControllerError(
                "launchctl snapshot contains malformed brace structure".to_owned(),
            ));
        }
        if arguments_depth == Some(depth) {
            if line.is_empty() {
                return Err(ControllerError(
                    "launchctl snapshot contains an empty argument".to_owned(),
                ));
            }
            arguments.push(line.to_owned());
            continue;
        }
        if depth != 1 {
            continue;
        }
        if let Some(value) = line.strip_prefix("pid = ") {
            pid_fields += 1;
            pid = Some(
                value
                    .parse::<u32>()
                    .map_err(|_| ControllerError("launchctl PID is malformed".to_owned()))?,
            );
        } else if let Some(value) = line.strip_prefix("runs = ") {
            runs_fields += 1;
            runs =
                Some(value.parse::<u64>().map_err(|_| {
                    ControllerError("launchctl runs value is malformed".to_owned())
                })?);
        } else if let Some(value) = line.strip_prefix("program = ") {
            program_fields += 1;
            if value.is_empty() {
                return Err(ControllerError(
                    "launchctl program path is empty".to_owned(),
                ));
            }
            program = Some(value.to_owned());
        }
    }
    if !closed || depth != 0 || arguments_depth.is_some() || argument_blocks != 1 {
        return Err(ControllerError(
            "launchctl snapshot has wrong top-level/arguments block structure".to_owned(),
        ));
    }
    if pid_fields != 1 || runs_fields != 1 || program_fields != 1 {
        return Err(ControllerError(format!(
            "launchctl top-level pid/runs/program field counts are {pid_fields}/{runs_fields}/{program_fields}, expected 1/1/1"
        )));
    }
    if arguments.is_empty() {
        return Err(ControllerError(
            "launchctl snapshot has no top-level arguments".to_owned(),
        ));
    }
    let parsed_pid =
        pid.ok_or_else(|| ControllerError("launchctl snapshot has no PID".to_owned()))?;
    if parsed_pid == 0 {
        return Err(ControllerError("launchctl PID must be positive".to_owned()));
    }
    let parsed_runs =
        runs.ok_or_else(|| ControllerError("launchctl snapshot has no runs value".to_owned()))?;
    if parsed_runs == 0 {
        return Err(ControllerError(
            "launchctl runs must be positive".to_owned(),
        ));
    }
    Ok(ParsedLaunch {
        pid: parsed_pid,
        runs: parsed_runs,
        program: program
            .ok_or_else(|| ControllerError("launchctl snapshot has no program".to_owned()))?,
        arguments,
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct LaunchGeneration {
    pid: u32,
    runs: u64,
    process_start: String,
    nonce: String,
    lock_device: u64,
    lock_inode: u64,
}

fn generation_fields(prefix: &str, generation: &LaunchGeneration) -> Vec<(String, String)> {
    vec![
        (format!("{prefix}pid"), generation.pid.to_string()),
        (format!("{prefix}runs"), generation.runs.to_string()),
        (
            format!("{prefix}process_start"),
            generation.process_start.clone(),
        ),
        (format!("{prefix}nonce"), generation.nonce.clone()),
        (
            format!("{prefix}lock_device"),
            generation.lock_device.to_string(),
        ),
        (
            format!("{prefix}lock_inode"),
            generation.lock_inode.to_string(),
        ),
    ]
}

fn expected_new_arguments() -> Vec<String> {
    vec![
        NEW_EXECUTABLE.to_owned(),
        "--worldwide".to_owned(),
        "--allow-remote-control".to_owned(),
        "--duration".to_owned(),
        "0".to_owned(),
        "--verbose".to_owned(),
        "--rendezvous-url".to_owned(),
        "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev".to_owned(),
    ]
}

fn parse_generation_record(bytes: &[u8]) -> Result<Option<(u32, String)>> {
    if bytes.is_empty() {
        return Ok(None);
    }
    let text = std::str::from_utf8(bytes)
        .map_err(|_| ControllerError("worldwide generation record is not UTF-8".to_owned()))?;
    let mut lines = text.split_terminator('\n');
    if lines.next() != Some("OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1") {
        return Err(ControllerError(
            "worldwide generation record has the wrong version".to_owned(),
        ));
    }
    let pid_line = lines
        .next()
        .ok_or_else(|| ControllerError("worldwide generation record has no PID".to_owned()))?;
    let nonce_line = lines
        .next()
        .ok_or_else(|| ControllerError("worldwide generation record has no nonce".to_owned()))?;
    if lines.next().is_some() || !text.ends_with('\n') {
        return Err(ControllerError(
            "worldwide generation record has extra or unterminated data".to_owned(),
        ));
    }
    let pid = pid_line
        .strip_prefix("pid=")
        .ok_or_else(|| ControllerError("worldwide generation PID field is malformed".to_owned()))?
        .parse::<u32>()
        .map_err(|_| ControllerError("worldwide generation PID is malformed".to_owned()))?;
    if pid == 0 {
        return Err(ControllerError(
            "worldwide generation PID must be positive".to_owned(),
        ));
    }
    let nonce = nonce_line.strip_prefix("nonce=").ok_or_else(|| {
        ControllerError("worldwide generation nonce field is malformed".to_owned())
    })?;
    if nonce.len() != 64
        || !nonce
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(ControllerError(
            "worldwide generation nonce must be 64 lowercase hexadecimal characters".to_owned(),
        ));
    }
    Ok(Some((pid, nonce.to_owned())))
}

fn read_generation_record() -> Result<Option<(u32, String, u64, u64)>> {
    let directory = PinnedDirectory::open(
        Path::new(LOCK_DIRECTORY),
        Some(effective_uid()),
        Some(0o700),
    )?;
    let Some(mut file) = directory.open_existing_regular("worldwide-host.lock", false)? else {
        return Ok(None);
    };
    let before = file.metadata()?;
    validate_owned_regular(Path::new(LOCK_FILE), &before, 0o600)?;
    if before.len() > 512 {
        return Err(ControllerError(
            "worldwide generation record is unexpectedly large".to_owned(),
        ));
    }
    let mut bytes = Vec::with_capacity(before.len() as usize);
    file.read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    if !same_inode(&before, &after) || before.len() != after.len() {
        return Err(ControllerError(
            "worldwide generation record changed while being read".to_owned(),
        ));
    }
    directory.ensure_file_at_name("worldwide-host.lock", &file)?;
    Ok(parse_generation_record(&bytes)?
        .map(|(pid, nonce)| (pid, nonce, before.dev(), before.ino())))
}

fn process_start_identity_until(pid: u32, deadline: Instant) -> Result<String> {
    let pid_text = pid.to_string();
    let output = run_command_until(
        Path::new("/bin/ps"),
        &[
            OsStr::new("-p"),
            OsStr::new(&pid_text),
            OsStr::new("-o"),
            OsStr::new("lstart="),
        ],
        None,
        deadline,
    )?
    .require_success("read process start identity")?;
    let values: Vec<&str> = output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    if values.len() != 1 {
        return Err(ControllerError(format!(
            "process start identity returned {} records, expected one",
            values.len()
        )));
    }
    Ok(values[0].to_owned())
}

fn current_launch_generation_until(
    label: &str,
    executable: &str,
    deadline: Instant,
) -> Result<Option<LaunchGeneration>> {
    if service_state_until(label, deadline)? == ServiceState::Absent {
        return Ok(None);
    }
    let parsed = parse_launch_snapshot(&launch_snapshot_until(label, deadline)?, label)?;
    let expected_arguments = if label == NEW_LABEL {
        expected_new_arguments()
    } else {
        vec![executable.to_owned()]
    };
    if parsed.program != executable
        || (label == NEW_LABEL && parsed.arguments != expected_arguments)
        || (label != NEW_LABEL && parsed.arguments.first().map(String::as_str) != Some(executable))
    {
        return Err(ControllerError(format!(
            "launchctl service '{label}' targets unexpected program arguments"
        )));
    }
    if exact_process_pids_until(executable, deadline)? != vec![parsed.pid] {
        return Ok(None);
    }
    let process_start = process_start_identity_until(parsed.pid, deadline)?;
    let Some((token_pid, nonce, lock_device, lock_inode)) = read_generation_record()? else {
        return Ok(None);
    };
    if token_pid != parsed.pid {
        return Ok(None);
    }
    Ok(Some(LaunchGeneration {
        pid: parsed.pid,
        runs: parsed.runs,
        process_start,
        nonce,
        lock_device,
        lock_inode,
    }))
}

fn observe_launch_generation(
    label: &str,
    executable: &str,
    timeout: Duration,
) -> Result<LaunchGeneration> {
    let deadline = deadline_after(timeout)?;
    loop {
        if let Some(first) = current_launch_generation_until(label, executable, deadline)? {
            if let Some(second) = current_launch_generation_until(label, executable, deadline)? {
                if first == second {
                    return Ok(first);
                }
            }
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ControllerError(format!(
                "service '{label}' did not expose one stable launch generation"
            )));
        }
        thread::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(100)),
        );
    }
}

fn verify_launch_generation_until(
    label: &str,
    executable: &str,
    expected: &LaunchGeneration,
    deadline: Instant,
) -> Result<()> {
    let actual =
        current_launch_generation_until(label, executable, deadline)?.ok_or_else(|| {
            ControllerError(format!(
                "service '{label}' has no complete current generation"
            ))
        })?;
    if &actual != expected {
        return Err(ControllerError(format!(
            "service '{label}' generation changed: expected pid/runs/start/nonce/inode {}/{}/{}/{}/{}:{}, observed {}/{}/{}/{}/{}:{}",
            expected.pid,
            expected.runs,
            expected.process_start,
            expected.nonce,
            expected.lock_device,
            expected.lock_inode,
            actual.pid,
            actual.runs,
            actual.process_start,
            actual.nonce,
            actual.lock_device,
            actual.lock_inode
        )));
    }
    Ok(())
}

fn verify_launch_generation(
    label: &str,
    executable: &str,
    expected: &LaunchGeneration,
) -> Result<()> {
    verify_launch_generation_until(
        label,
        executable,
        expected,
        deadline_after(DEFAULT_COMMAND_TIMEOUT)?,
    )
}

fn checkpoint_log_for_generation(generation: &LaunchGeneration) -> Result<LogCheckpoint> {
    verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
    let checkpoint = safe_log_size(Path::new(ONLINE_LOG))?;
    verify_launch_generation(NEW_LABEL, NEW_EXECUTABLE, generation)?;
    Ok(checkpoint)
}

fn process_snapshot_until(deadline: Instant) -> Result<String> {
    run_command_until(
        Path::new("/bin/ps"),
        &[
            OsStr::new("-ww"),
            OsStr::new("-axo"),
            OsStr::new("pid=,comm="),
        ],
        None,
        deadline,
    )?
    .require_success("ps process enumeration")
}

fn parse_processes(snapshot: &str) -> Result<Vec<(u32, String)>> {
    let mut processes = Vec::new();
    for line in snapshot.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            continue;
        }
        let split = trimmed
            .find(char::is_whitespace)
            .ok_or_else(|| ControllerError("ps output line is malformed".to_owned()))?;
        let pid = trimmed[..split]
            .parse::<u32>()
            .map_err(|_| ControllerError("ps PID is malformed".to_owned()))?;
        let command = trimmed[split..].trim_start();
        if command.is_empty() {
            return Err(ControllerError("ps command path is empty".to_owned()));
        }
        processes.push((pid, command.to_owned()));
    }
    Ok(processes)
}

fn exact_process_pids_until(executable: &str, deadline: Instant) -> Result<Vec<u32>> {
    Ok(parse_processes(&process_snapshot_until(deadline)?)?
        .into_iter()
        .filter_map(|(pid, command)| (command == executable).then_some(pid))
        .collect())
}

fn exact_process_pids(executable: &str) -> Result<Vec<u32>> {
    exact_process_pids_until(executable, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn all_capture_server_processes_until(deadline: Instant) -> Result<Vec<(u32, String)>> {
    Ok(parse_processes(&process_snapshot_until(deadline)?)?
        .into_iter()
        .filter(|(_, command)| command.ends_with("/CaptureServer"))
        .collect())
}

fn require_no_capture_server_processes_until(deadline: Instant) -> Result<()> {
    let processes = all_capture_server_processes_until(deadline)?;
    if processes.is_empty() {
        Ok(())
    } else {
        Err(ControllerError(format!(
            "CaptureServer processes remain: {processes:?}"
        )))
    }
}

fn require_no_capture_server_processes() -> Result<()> {
    require_no_capture_server_processes_until(deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn prove_lock_held_by_legacy() -> Result<()> {
    let deadline = deadline_after(DEFAULT_COMMAND_TIMEOUT)?;
    let snapshot = launch_snapshot_until(LEGACY_LABEL, deadline)?;
    let parsed = parse_launch_snapshot(&snapshot, LEGACY_LABEL)?;
    prove_lock_held_only_by_until(parsed.pid, deadline)
}

fn prove_lock_held_only_by_until(expected_pid: u32, deadline: Instant) -> Result<()> {
    let metadata = validate_lock_path()?;
    let holders = lsof_holders_until(Path::new(LOCK_FILE), deadline)?;
    let expected_holders: BTreeSet<u32> = std::iter::once(expected_pid).collect();
    if holders != expected_holders {
        return Err(ControllerError(format!(
            "shared lock holders {holders:?}, expected only {expected_pid}"
        )));
    }
    let file = open_lock_file()?;
    // SAFETY: flock is called with a valid open file descriptor.
    let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if result == 0 {
        // SAFETY: release the unexpectedly acquired lock before returning failure.
        let _ = unsafe { flock(file.as_raw_fd(), LOCK_UN) };
        return Err(ControllerError(
            "shared advisory lock was unexpectedly acquirable".to_owned(),
        ));
    }
    let error = io::Error::last_os_error();
    if !matches!(error.raw_os_error(), Some(11) | Some(35)) {
        return Err(ControllerError(format!(
            "nonblocking shared-lock probe failed operationally: {error}"
        )));
    }
    revalidate_lock_path(&metadata, &file.metadata()?)
}

fn prove_lock_acquirable_until(deadline: Instant) -> Result<()> {
    let metadata = validate_lock_path()?;
    let holders = lsof_holders_until(Path::new(LOCK_FILE), deadline)?;
    if !holders.is_empty() {
        return Err(ControllerError(format!(
            "shared lock still has holders: {holders:?}"
        )));
    }
    let file = open_lock_file()?;
    // SAFETY: flock is called with a valid open file descriptor.
    let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if result != 0 {
        return Err(ControllerError(format!(
            "shared advisory lock is not acquirable: {}",
            io::Error::last_os_error()
        )));
    }
    revalidate_lock_path(&metadata, &file.metadata()?)?;
    // SAFETY: release the probe lock before returning.
    if unsafe { flock(file.as_raw_fd(), LOCK_UN) } != 0 {
        return Err(ControllerError(format!(
            "cannot release shared-lock probe: {}",
            io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn prove_lock_acquirable() -> Result<()> {
    prove_lock_acquirable_until(deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

#[derive(Clone)]
struct LockPathMetadata {
    directory: Metadata,
    lock: Metadata,
}

fn validate_lock_path() -> Result<LockPathMetadata> {
    let directory = fs::symlink_metadata(LOCK_DIRECTORY)
        .map_err(|error| ControllerError(format!("cannot inspect runtime directory: {error}")))?;
    if directory.file_type().is_symlink()
        || !directory.is_dir()
        || directory.uid() != USER_ID
        || directory.permissions().mode() & 0o7777 != 0o700
    {
        return Err(ControllerError("runtime directory is unsafe".to_owned()));
    }
    let lock = fs::symlink_metadata(LOCK_FILE)
        .map_err(|error| ControllerError(format!("cannot inspect shared lock: {error}")))?;
    validate_owned_regular(Path::new(LOCK_FILE), &lock, 0o600)?;
    Ok(LockPathMetadata { directory, lock })
}

fn revalidate_lock_path(expected: &LockPathMetadata, opened: &Metadata) -> Result<()> {
    let current = validate_lock_path()?;
    if !same_inode(&expected.directory, &current.directory)
        || !same_inode(&expected.lock, &current.lock)
        || !same_inode(&expected.lock, opened)
    {
        return Err(ControllerError(
            "canonical runtime directory or lock inode was substituted".to_owned(),
        ));
    }
    Ok(())
}

fn open_lock_file() -> Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(LOCK_FILE)
        .map_err(|error| ControllerError(format!("cannot open shared lock: {error}")))
}

fn probe_lock_cli(runtime: &Path, lock_path: &Path, expected_pid_text: &str) -> Result<()> {
    let expected_pid = expected_pid_text.parse::<u32>().map_err(|_| {
        ControllerError("expected lock-holder PID must be a positive decimal integer".to_owned())
    })?;
    if expected_pid == 0 {
        return Err(ControllerError(
            "expected lock-holder PID must be positive".to_owned(),
        ));
    }
    if lock_path.parent() != Some(runtime) {
        return Err(ControllerError(
            "lock file must be an immediate child of the supplied runtime directory".to_owned(),
        ));
    }
    let lock_name = lock_path
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| ControllerError("lock filename is not UTF-8".to_owned()))?;
    let parent = PinnedDirectory::open(runtime, Some(effective_uid()), Some(0o700))?;
    let file = parent
        .open_existing_regular(lock_name, true)?
        .ok_or_else(|| ControllerError("shared runtime lock is missing".to_owned()))?;
    validate_owned_regular(lock_path, &file.metadata()?, 0o600)?;
    let holders = lsof_holders(lock_path)?;
    let expected: BTreeSet<u32> = std::iter::once(expected_pid).collect();
    if holders != expected {
        return Err(ControllerError(format!(
            "shared lock holders {holders:?}, expected only {expected_pid}"
        )));
    }
    // SAFETY: flock is called with a valid open descriptor.
    let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if result == 0 {
        // SAFETY: release the unexpectedly acquired probe lock.
        let _ = unsafe { flock(file.as_raw_fd(), LOCK_UN) };
        return Err(ControllerError(
            "shared advisory lock was unexpectedly acquirable".to_owned(),
        ));
    }
    let error = io::Error::last_os_error();
    if !matches!(error.raw_os_error(), Some(11) | Some(35)) {
        return Err(ControllerError(format!(
            "nonblocking shared-lock probe failed operationally: {error}"
        )));
    }
    let reopened = parent
        .open_existing_regular(lock_name, false)?
        .ok_or_else(|| ControllerError("shared lock disappeared during probe".to_owned()))?;
    if !same_inode(&file.metadata()?, &reopened.metadata()?) {
        return Err(ControllerError(
            "shared lock inode was substituted during probe".to_owned(),
        ));
    }
    parent.revalidate()?;
    println!("lock_holder={expected_pid}");
    Ok(())
}

fn lsof_holders_until(path: &Path, deadline: Instant) -> Result<BTreeSet<u32>> {
    let output = run_command_until(
        Path::new("/usr/sbin/lsof"),
        &[
            OsStr::new("-n"),
            OsStr::new("-P"),
            OsStr::new("-t"),
            path.as_os_str(),
        ],
        None,
        deadline,
    )?;
    if !output.status.success() {
        if output.status.code() == Some(1)
            && output.stdout.trim().is_empty()
            && output.stderr.trim().is_empty()
        {
            return Ok(BTreeSet::new());
        }
        return Err(ControllerError(format!(
            "lsof holder attribution failed: {}",
            output.stderr.trim()
        )));
    }
    let mut holders = BTreeSet::new();
    for line in output.stdout.lines() {
        holders.insert(
            line.trim()
                .parse::<u32>()
                .map_err(|_| ControllerError("lsof returned malformed PID".to_owned()))?,
        );
    }
    Ok(holders)
}

fn lsof_holders(path: &Path) -> Result<BTreeSet<u32>> {
    lsof_holders_until(path, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn validate_logs_precutover() -> Result<()> {
    validate_real_directory(Path::new("/var/tmp"))?;
    for path in [Path::new(ONLINE_LOG), Path::new(ERROR_LOG)] {
        let metadata = fs::symlink_metadata(path).map_err(|error| {
            ControllerError(format!(
                "required pre-cutover log '{}' is unavailable: {error}",
                path.display()
            ))
        })?;
        validate_owned_regular(path, &metadata, 0o600)?;
    }
    Ok(())
}

fn prepare_logs() -> Result<()> {
    validate_real_directory(Path::new("/var/tmp"))?;
    for path in [Path::new(ONLINE_LOG), Path::new(ERROR_LOG)] {
        match fs::symlink_metadata(path) {
            Ok(metadata) => validate_owned_regular(path, &metadata, 0o600)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let file = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
                    .open(path)?;
                file.set_permissions(Permissions::from_mode(0o600))?;
                file.sync_all()?;
                sync_parent(path)?;
                let metadata = file.metadata()?;
                validate_owned_regular(path, &metadata, 0o600)?;
            }
            Err(error) => return Err(ControllerError(format!("cannot inspect log: {error}"))),
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug)]
struct LogCheckpoint {
    offset: u64,
    device: u64,
    inode: u64,
}

fn safe_log_size(path: &Path) -> Result<LogCheckpoint> {
    let before = fs::symlink_metadata(path)?;
    validate_owned_regular(path, &before, 0o600)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(path)?;
    let opened = file.metadata()?;
    if !same_inode(&before, &opened) {
        return Err(ControllerError(
            "log inode changed while opening".to_owned(),
        ));
    }
    let after = fs::symlink_metadata(path)?;
    if !same_inode(&opened, &after) {
        return Err(ControllerError(
            "log inode changed while checkpointing".to_owned(),
        ));
    }
    Ok(LogCheckpoint {
        offset: opened.len(),
        device: opened.dev(),
        inode: opened.ino(),
    })
}

fn require_marker_after_checkpoint(path: &Path, checkpoint: &LogCheckpoint) -> Result<()> {
    let before = fs::symlink_metadata(path)?;
    validate_owned_regular(path, &before, 0o600)?;
    if before.dev() != checkpoint.device || before.ino() != checkpoint.inode {
        return Err(ControllerError(
            "online log inode differs from the generation-bound checkpoint".to_owned(),
        ));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(path)?;
    let opened = file.metadata()?;
    if !same_inode(&before, &opened) || opened.len() < checkpoint.offset {
        return Err(ControllerError(
            "online log was replaced or truncated after the generation-bound checkpoint".to_owned(),
        ));
    }
    file.seek(SeekFrom::Start(checkpoint.offset))?;
    let mut suffix = String::new();
    file.read_to_string(&mut suffix)
        .map_err(|_| ControllerError("online log suffix is not UTF-8".to_owned()))?;
    let after = fs::symlink_metadata(path)?;
    if !same_inode(&opened, &after) {
        return Err(ControllerError(
            "online log inode changed while revalidating readiness evidence".to_owned(),
        ));
    }
    if !suffix.lines().any(|line| line.contains(ONLINE_MARKER)) {
        return Err(ControllerError(
            "generation-bound online marker disappeared before commit".to_owned(),
        ));
    }
    Ok(())
}

fn wait_for_online_marker_for_generation(
    path: &Path,
    checkpoint: &LogCheckpoint,
    generation: &LaunchGeneration,
    timeout: Duration,
) -> Result<()> {
    let deadline = deadline_after(timeout)?;
    loop {
        verify_launch_generation_until(NEW_LABEL, NEW_EXECUTABLE, generation, deadline)?;
        let before = fs::symlink_metadata(path)?;
        validate_owned_regular(path, &before, 0o600)?;
        if before.dev() != checkpoint.device || before.ino() != checkpoint.inode {
            return Err(ControllerError(
                "online log inode was substituted after the generation-bound checkpoint".to_owned(),
            ));
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
            .open(path)?;
        let opened = file.metadata()?;
        if !same_inode(&before, &opened) || opened.len() < checkpoint.offset {
            return Err(ControllerError(
                "online log was replaced or truncated after the generation-bound checkpoint"
                    .to_owned(),
            ));
        }
        file.seek(SeekFrom::Start(checkpoint.offset))?;
        let mut suffix = String::new();
        file.read_to_string(&mut suffix)
            .map_err(|_| ControllerError("online log suffix is not UTF-8".to_owned()))?;
        let after = fs::symlink_metadata(path)?;
        if !same_inode(&opened, &after) {
            return Err(ControllerError(
                "online log inode changed while reading readiness evidence".to_owned(),
            ));
        }
        verify_launch_generation_until(NEW_LABEL, NEW_EXECUTABLE, generation, deadline)?;
        if suffix.lines().any(|line| line.contains(ONLINE_MARKER)) {
            return Ok(());
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ControllerError(
                "fresh online marker was not observed after the current generation was identified"
                    .to_owned(),
            ));
        }
        thread::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(100)),
        );
    }
}

fn verify_code_identity_until(target: &Path, deadline: Instant) -> Result<()> {
    run_command_until(
        Path::new("/usr/bin/codesign"),
        &[
            OsStr::new("--verify"),
            OsStr::new("--strict"),
            target.as_os_str(),
        ],
        None,
        deadline,
    )?
    .require_success("legacy signature verification")?;
    let metadata = run_command_until(
        Path::new("/usr/bin/codesign"),
        &[
            OsStr::new("--display"),
            OsStr::new("--verbose=4"),
            target.as_os_str(),
        ],
        None,
        deadline,
    )?;
    if !metadata.status.success() {
        return Err(ControllerError(
            "cannot read legacy code metadata".to_owned(),
        ));
    }
    let combined = format!("{}{}", metadata.stdout, metadata.stderr);
    let identifier = metadata_field(&combined, "Identifier")?;
    let team = metadata_field(&combined, "TeamIdentifier")?;
    if identifier != CODE_IDENTIFIER || team != TEAM_ID {
        return Err(ControllerError(
            "legacy code identity differs from audited identifier/team".to_owned(),
        ));
    }
    let requirement = format!(
        "identifier \"{CODE_IDENTIFIER}\" and anchor apple generic and certificate leaf[subject.OU] = \"{TEAM_ID}\""
    );
    run_command_until(
        Path::new("/usr/bin/codesign"),
        &[
            OsStr::new("--verify"),
            OsStr::new("--strict"),
            OsStr::new(&format!("-R={requirement}")),
            target.as_os_str(),
        ],
        None,
        deadline,
    )?
    .require_success("legacy identifier/team requirement")?;
    Ok(())
}

fn metadata_field<'a>(text: &'a str, key: &str) -> Result<&'a str> {
    text.lines()
        .find_map(|line| line.strip_prefix(&format!("{key}=")))
        .ok_or_else(|| ControllerError(format!("code metadata lacks {key}")))
}

fn plist_arguments_until(plist: &Path, deadline: Instant) -> Result<Vec<String>> {
    let mut arguments = Vec::new();
    for index in 0..64 {
        require_before_deadline(deadline, "legacy plist argument parsing")?;
        let command = format!("Print :ProgramArguments:{index}");
        let output = run_command_until(
            Path::new("/usr/libexec/PlistBuddy"),
            &[OsStr::new("-c"), OsStr::new(&command), plist.as_os_str()],
            None,
            deadline,
        )?;
        if output.status.success() {
            if output.stderr.trim().is_empty() {
                let value = output.stdout.trim_end_matches(&['\n', '\r'][..]);
                if value.contains('\n') || value.contains('\r') {
                    return Err(ControllerError(
                        "PlistBuddy returned a multiline ProgramArgument".to_owned(),
                    ));
                }
                arguments.push(value.to_owned());
                continue;
            }
            return Err(ControllerError(format!(
                "PlistBuddy emitted diagnostics while reading ProgramArguments: {}",
                output.stderr.trim()
            )));
        }
        let missing_entry =
            output.stdout.trim().is_empty() && output.stderr.contains("Does Not Exist");
        if missing_entry {
            if index == 0 {
                return Err(ControllerError("plist has no ProgramArguments".to_owned()));
            }
            return Ok(arguments);
        }
        return Err(ControllerError(format!(
            "PlistBuddy failed while reading ProgramArguments index {index}: {}",
            output.stderr.trim()
        )));
    }
    Err(ControllerError(
        "plist ProgramArguments exceeds the bounded 64-item limit".to_owned(),
    ))
}

fn read_pinned_regular(parent: &PinnedDirectory, name: &str, mode: u32) -> Result<Vec<u8>> {
    let mut file = parent
        .open_existing_regular(name, false)?
        .ok_or_else(|| ControllerError(format!("required private record is missing: {name}")))?;
    validate_owned_regular(&parent.path.join(name), &file.metadata()?, mode)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    parent.ensure_file_at_name(name, &file)?;
    Ok(bytes)
}

#[derive(Debug)]
enum ActivePointerRecovery {
    None,
    Active,
}

fn recover_active_pointer(parent: &PinnedDirectory) -> Result<ActivePointerRecovery> {
    let active_exists = parent
        .open_existing_regular(ACTIVE_TRANSACTION_NAME, false)?
        .is_some();
    let pending_exists = parent
        .open_existing_regular(ACTIVE_TRANSACTION_PENDING_NAME, false)?
        .is_some();
    let finalizing_exists = parent
        .open_existing_regular(ACTIVE_TRANSACTION_FINALIZING_NAME, false)?
        .is_some();
    let linearized_exists = parent
        .open_existing_regular(ACTIVE_TRANSACTION_LINEARIZED_NAME, false)?
        .is_some();

    if linearized_exists {
        let linearized_bytes =
            read_pinned_regular(parent, ACTIVE_TRANSACTION_LINEARIZED_NAME, 0o600)?;
        let _ = parse_active_record(&linearized_bytes)?;
        if finalizing_exists {
            let finalizing_bytes =
                read_pinned_regular(parent, ACTIVE_TRANSACTION_FINALIZING_NAME, 0o600)?;
            if finalizing_bytes != linearized_bytes {
                return Err(ControllerError(
                    "linearized and cleanup-only finalizing records disagree".to_owned(),
                ));
            }
        }
        return Err(ControllerError(
            "obsolete linearized active-pointer marker retained without mutation; refusing automatic recovery"
                .to_owned(),
        ));
    }

    if finalizing_exists {
        if pending_exists {
            return Err(ControllerError(
                "active-pointer recovery found pending and finalizing records together".to_owned(),
            ));
        }
        let finalizing_bytes =
            read_pinned_regular(parent, ACTIVE_TRANSACTION_FINALIZING_NAME, 0o600)?;
        let _ = parse_active_record(&finalizing_bytes)?;
        if active_exists {
            let active_bytes = read_pinned_regular(parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
            if active_bytes != finalizing_bytes {
                return Err(ControllerError(
                    "active and finalizing transaction records disagree".to_owned(),
                ));
            }
            // Both names are exact retained recovery evidence. Never unlink either name: a
            // same-UID actor could substitute a foreign inode after validation.
            return Ok(ActivePointerRecovery::Active);
        }
        parent.rename_exclusive(ACTIVE_TRANSACTION_FINALIZING_NAME, ACTIVE_TRANSACTION_NAME)?;
        let restored = read_pinned_regular(parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
        if restored != finalizing_bytes {
            return Err(ControllerError(
                "restored active transaction pointer bytes changed during publication".to_owned(),
            ));
        }
        return Ok(ActivePointerRecovery::Active);
    }

    match (active_exists, pending_exists) {
        (false, false) => Ok(ActivePointerRecovery::None),
        (true, false) => {
            let _ = parse_active_record(&read_pinned_regular(
                parent,
                ACTIVE_TRANSACTION_NAME,
                0o600,
            )?)?;
            Ok(ActivePointerRecovery::Active)
        }
        (true, true) => {
            let active_bytes = read_pinned_regular(parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
            let pending_bytes =
                read_pinned_regular(parent, ACTIVE_TRANSACTION_PENDING_NAME, 0o600)?;
            if active_bytes != pending_bytes {
                return Err(ControllerError(
                    "active and pending transaction records disagree".to_owned(),
                ));
            }
            let _ = parse_active_record(&active_bytes)?;
            // An identical pending record is harmless retained evidence. It is intentionally not
            // unlinked because validation and pathname deletion cannot be made atomic on macOS.
            Ok(ActivePointerRecovery::Active)
        }
        (false, true) => {
            let bytes = read_pinned_regular(parent, ACTIVE_TRANSACTION_PENDING_NAME, 0o600)?;
            let _ = parse_active_record(&bytes).map_err(|error| {
                ControllerError(format!(
                    "malformed pending active pointer was retained without mutation: {error}"
                ))
            })?;
            parent.rename_exclusive(ACTIVE_TRANSACTION_PENDING_NAME, ACTIVE_TRANSACTION_NAME)?;
            let published = read_pinned_regular(parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
            if published != bytes {
                return Err(ControllerError(
                    "recovered active transaction pointer bytes changed during publication"
                        .to_owned(),
                ));
            }
            Ok(ActivePointerRecovery::Active)
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ActivePointerOperation {
    CreatePending,
    WriteAndSyncPending,
    PublishPending,
    VerifyPublished,
}

trait ActivePointerBackend {
    fn perform_active_pointer(&mut self, operation: ActivePointerOperation) -> Result<()>;
}

fn drive_active_pointer<B, H>(backend: &mut B, mut interruption_hook: H) -> Result<()>
where
    B: ActivePointerBackend,
    H: FnMut(usize, ActivePointerOperation, EffectPhase) -> Result<()>,
{
    let operations = [
        ActivePointerOperation::CreatePending,
        ActivePointerOperation::WriteAndSyncPending,
        ActivePointerOperation::PublishPending,
        ActivePointerOperation::VerifyPublished,
    ];
    for (index, operation) in operations.into_iter().enumerate() {
        interruption_hook(index, operation, EffectPhase::BeforeSideEffect)?;
        backend.perform_active_pointer(operation)?;
        interruption_hook(index, operation, EffectPhase::AfterSideEffect)?;
    }
    Ok(())
}

struct RealActivePointerBackend<'a> {
    parent: &'a PinnedDirectory,
    expected: Vec<u8>,
    pending_file: Option<File>,
}

impl ActivePointerBackend for RealActivePointerBackend<'_> {
    fn perform_active_pointer(&mut self, operation: ActivePointerOperation) -> Result<()> {
        match operation {
            ActivePointerOperation::CreatePending => {
                if self
                    .parent
                    .open_existing_regular(ACTIVE_TRANSACTION_NAME, false)?
                    .is_some()
                    || self
                        .parent
                        .open_existing_regular(ACTIVE_TRANSACTION_PENDING_NAME, false)?
                        .is_some()
                {
                    return Err(ControllerError(
                        "active or pending transaction pointer already exists".to_owned(),
                    ));
                }
                self.pending_file = Some(
                    self.parent
                        .create_new_regular(ACTIVE_TRANSACTION_PENDING_NAME, 0o600)?,
                );
                Ok(())
            }
            ActivePointerOperation::WriteAndSyncPending => {
                let file = self.pending_file.as_mut().ok_or_else(|| {
                    ControllerError("active-pointer pending file is unavailable".to_owned())
                })?;
                file.write_all(&self.expected)?;
                file.sync_all()?;
                self.parent
                    .ensure_file_at_name(ACTIVE_TRANSACTION_PENDING_NAME, file)?;
                self.parent.file.sync_all()?;
                Ok(())
            }
            ActivePointerOperation::PublishPending => {
                self.parent
                    .rename_exclusive(ACTIVE_TRANSACTION_PENDING_NAME, ACTIVE_TRANSACTION_NAME)?;
                self.pending_file = None;
                Ok(())
            }
            ActivePointerOperation::VerifyPublished => {
                let published = read_pinned_regular(self.parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
                if published != self.expected {
                    return Err(ControllerError(
                        "active transaction pointer bytes changed during publication".to_owned(),
                    ));
                }
                Ok(())
            }
        }
    }
}

fn write_active(parent: &PinnedDirectory, evidence: &Path) -> Result<()> {
    let expected = format!("{}\n", evidence.display()).into_bytes();
    let mut backend = RealActivePointerBackend {
        parent,
        expected,
        pending_file: None,
    };
    drive_active_pointer(&mut backend, |_, _, _| Ok(()))
}

fn read_active(parent: &PinnedDirectory) -> Result<PathBuf> {
    parse_active_record(&read_pinned_regular(
        parent,
        ACTIVE_TRANSACTION_NAME,
        0o600,
    )?)
}

fn parse_active_record(bytes: &[u8]) -> Result<PathBuf> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| ControllerError("active transaction record is not UTF-8".to_owned()))?;
    let value = text.trim();
    if value.is_empty() || value.contains('\n') || value.contains('\r') {
        return Err(ControllerError(
            "active transaction record is malformed".to_owned(),
        ));
    }
    let evidence = PathBuf::from(value);
    let canonical = fs::canonicalize(&evidence)?;
    if canonical != evidence || !evidence.starts_with(Path::new(MIGRATIONS_ROOT)) {
        return Err(ControllerError(
            "active evidence path is not canonical/private".to_owned(),
        ));
    }
    validate_private_directory(&evidence, 0o700)?;
    Ok(evidence)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RetainedActivePointerPhase {
    AfterInitialPointerValidation,
    AfterCommittedGenerationProof,
    AfterFinalPointerValidation,
}

fn verify_retained_active_pointer_after_commit<P, H>(
    parent: &PinnedDirectory,
    expected: &[u8],
    mut prove_current_generation: P,
    mut hook: H,
) -> Result<()>
where
    P: FnMut() -> Result<()>,
    H: FnMut(RetainedActivePointerPhase) -> Result<()>,
{
    // The durable COMMITTED journal record is the sole commit point. The exact active pointer is
    // retained permanently as a recovery tombstone; this function publishes and removes no
    // pathname. Consequently there is no check/publication or check/unlink interval in which a
    // same-UID replacement can become authoritative or be deleted. This proof is a committed
    // readiness observation. A KeepAlive restart after it is ordinary committed lifecycle.
    let before = read_pinned_regular(parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
    if before != expected {
        return Err(ControllerError(
            "retained active pointer differs from the committed evidence path".to_owned(),
        ));
    }
    hook(RetainedActivePointerPhase::AfterInitialPointerValidation)?;
    prove_current_generation()?;
    hook(RetainedActivePointerPhase::AfterCommittedGenerationProof)?;
    let after = read_pinned_regular(parent, ACTIVE_TRANSACTION_NAME, 0o600)?;
    if after != expected {
        return Err(ControllerError(
            "retained active pointer changed after the committed generation proof; preserving it"
                .to_owned(),
        ));
    }
    hook(RetainedActivePointerPhase::AfterFinalPointerValidation)?;
    Ok(())
}

fn entry_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(ControllerError(format!(
            "cannot inspect path '{}': {error}",
            path.display()
        ))),
    }
}

fn validate_repository_root(root: &Path) -> Result<PathBuf> {
    if !root.is_absolute() {
        return Err(ControllerError(
            "repository root must be absolute".to_owned(),
        ));
    }
    let metadata = fs::symlink_metadata(root)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() || metadata.uid() != effective_uid()
    {
        return Err(ControllerError(
            "repository root must be a real directory owned by the current uid".to_owned(),
        ));
    }
    let root_mode = metadata.permissions().mode() & 0o7777;
    if root_mode & 0o022 != 0 {
        return Err(ControllerError(format!(
            "repository root is group/world writable with mode {:04o}",
            root_mode
        )));
    }
    let canonical = fs::canonicalize(root)?;
    if canonical != root {
        return Err(ControllerError(format!(
            "repository root is not canonical: {}",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn validate_private_directory(path: &Path, mode: u32) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() || metadata.uid() != effective_uid()
    {
        return Err(ControllerError(format!(
            "private directory is unsafe: {}",
            path.display()
        )));
    }
    if metadata.permissions().mode() & 0o7777 != mode {
        return Err(ControllerError(format!(
            "private directory mode is wrong: {}",
            path.display()
        )));
    }
    if fs::canonicalize(path)? != path {
        return Err(ControllerError(format!(
            "private directory path is not canonical: {}",
            path.display()
        )));
    }
    Ok(())
}

fn ensure_private_directory(path: &Path, mode: u32) -> Result<()> {
    if entry_exists(path)? {
        validate_private_directory(path, mode)
    } else {
        let parent = path
            .parent()
            .ok_or_else(|| ControllerError("private directory has no parent".to_owned()))?;
        let parent_metadata = fs::symlink_metadata(parent)?;
        if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
            return Err(ControllerError(format!(
                "private directory parent is unsafe: {}",
                parent.display()
            )));
        }
        if parent.starts_with(Path::new(USER_HOME)) && parent_metadata.uid() != effective_uid() {
            return Err(ControllerError(format!(
                "private directory parent has the wrong owner: {}",
                parent.display()
            )));
        }
        if fs::canonicalize(parent)? != parent {
            return Err(ControllerError(format!(
                "private directory parent is not canonical: {}",
                parent.display()
            )));
        }
        fs::create_dir(path)?;
        fs::set_permissions(path, Permissions::from_mode(mode))?;
        sync_parent(path)?;
        validate_private_directory(path, mode)
    }
}

fn validate_real_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(ControllerError(format!(
            "path is not a real directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn validate_real_file(path: &Path, mode: Option<u32>) -> Result<Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.nlink() != 1 {
        return Err(ControllerError(format!(
            "path is not a single-link real file: {}",
            path.display()
        )));
    }
    if let Some(mode) = mode {
        if metadata.permissions().mode() & 0o7777 != mode {
            return Err(ControllerError(format!(
                "file mode is wrong: {}",
                path.display()
            )));
        }
    }
    Ok(metadata)
}

fn validate_owned_regular(path: &Path, metadata: &Metadata, mode: u32) -> Result<()> {
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o7777 != mode
    {
        return Err(ControllerError(format!(
            "owned regular-file contract failed: {}",
            path.display()
        )));
    }
    Ok(())
}

fn validate_recoverable_owned_regular(
    path: &Path,
    metadata: &Metadata,
    maximum_mode: u32,
) -> Result<()> {
    let mode = metadata.permissions().mode() & 0o7777;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
        || mode & !maximum_mode != 0
    {
        return Err(ControllerError(format!(
            "recoverable owned regular-file contract failed: {}",
            path.display()
        )));
    }
    Ok(())
}

fn copy_exact_file(source: &Path, destination: &Path, mode: u32) -> Result<()> {
    validate_real_file(source, None)?;
    if entry_exists(destination)? {
        return Err(ControllerError(format!(
            "copy destination already exists: {}",
            destination.display()
        )));
    }
    let mut input = OpenOptions::new()
        .read(true)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(source)?;
    let input_metadata = input.metadata()?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(destination)?;
    io::copy(&mut input, &mut output)?;
    output.set_permissions(Permissions::from_mode(mode))?;
    output.sync_all()?;
    sync_parent(destination)?;
    let copied = output.metadata()?;
    if copied.len() != input_metadata.len() {
        return Err(ControllerError("copied file size mismatch".to_owned()));
    }
    Ok(())
}

fn write_record(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    if entry_exists(path)? {
        return Err(ControllerError(format!(
            "record already exists: {}",
            path.display()
        )));
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(path)?;
    file.write_all(bytes)?;
    file.set_permissions(Permissions::from_mode(mode))?;
    file.sync_all()?;
    sync_parent(path)
}

fn write_record_idempotent(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    if entry_exists(path)? {
        let metadata = validate_real_file(path, Some(mode))?;
        if metadata.uid() != effective_uid() || fs::read(path)? != bytes {
            return Err(ControllerError(format!(
                "existing idempotent record differs: {}",
                path.display()
            )));
        }
        return Ok(());
    }
    write_record(path, bytes, mode)
}

fn tree_manifest_until(root: &Path, deadline: Instant) -> Result<String> {
    let output = run_command_until(
        Path::new("/usr/bin/find"),
        &[root.as_os_str(), OsStr::new("-print")],
        None,
        deadline,
    )?
    .require_success("tree enumeration")?;
    let mut paths: Vec<&str> = output.lines().collect();
    paths.sort_unstable();
    let mut manifest = String::new();
    for path in paths {
        require_before_deadline(deadline, "tree manifest")?;
        let path = Path::new(path);
        let metadata = fs::symlink_metadata(path)?;
        let kind = if metadata.file_type().is_symlink() {
            "symlink"
        } else if metadata.is_dir() {
            "directory"
        } else if metadata.is_file() {
            "file"
        } else {
            "other"
        };
        let hash = if metadata.is_file() && !metadata.file_type().is_symlink() {
            sha256_file_until(path, deadline)?
        } else {
            "-".to_owned()
        };
        manifest.push_str(&format!(
            "{}|{}|{:o}|{}|{}|{}\n",
            path.strip_prefix(root).unwrap_or(path).display(),
            kind,
            metadata.permissions().mode() & 0o7777,
            metadata.uid(),
            metadata.nlink(),
            hash
        ));
    }
    require_before_deadline(deadline, "tree manifest")?;
    Ok(manifest)
}

fn tree_manifest(root: &Path) -> Result<String> {
    tree_manifest_until(root, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn directory_manifest(root: &Path) -> Result<String> {
    tree_manifest(root)
}

fn sha256_file_until(path: &Path, deadline: Instant) -> Result<String> {
    let output = run_command_until(
        Path::new("/usr/bin/shasum"),
        &[OsStr::new("-a"), OsStr::new("256"), path.as_os_str()],
        None,
        deadline,
    )?
    .require_success("SHA-256")?;
    let hash = output
        .split_whitespace()
        .next()
        .ok_or_else(|| ControllerError("shasum returned no hash".to_owned()))?;
    if hash.len() != 64 || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ControllerError("shasum returned malformed hash".to_owned()));
    }
    Ok(hash.to_ascii_lowercase())
}

fn sha256_file(path: &Path) -> Result<String> {
    sha256_file_until(path, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)
}

fn sha256_bytes(bytes: &[u8]) -> Result<String> {
    const INITIAL: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    const ROUND: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let bit_length = u64::try_from(bytes.len())
        .ok()
        .and_then(|length| length.checked_mul(8))
        .ok_or_else(|| ControllerError("SHA-256 input length overflowed".to_owned()))?;
    let mut padded = bytes.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());

    let mut state = INITIAL;
    for chunk in padded.chunks_exact(64) {
        let mut schedule = [0u32; 64];
        for (index, word) in schedule.iter_mut().take(16).enumerate() {
            let offset = index * 4;
            *word = u32::from_be_bytes([
                chunk[offset],
                chunk[offset + 1],
                chunk[offset + 2],
                chunk[offset + 3],
            ]);
        }
        for index in 16..64 {
            let s0 = schedule[index - 15].rotate_right(7)
                ^ schedule[index - 15].rotate_right(18)
                ^ (schedule[index - 15] >> 3);
            let s1 = schedule[index - 2].rotate_right(17)
                ^ schedule[index - 2].rotate_right(19)
                ^ (schedule[index - 2] >> 10);
            schedule[index] = schedule[index - 16]
                .wrapping_add(s0)
                .wrapping_add(schedule[index - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for index in 0..64 {
            let upper_e = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choose = (e & f) ^ ((!e) & g);
            let temp_one = h
                .wrapping_add(upper_e)
                .wrapping_add(choose)
                .wrapping_add(ROUND[index])
                .wrapping_add(schedule[index]);
            let upper_a = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp_two = upper_a.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp_one);
            d = c;
            c = b;
            b = a;
            a = temp_one.wrapping_add(temp_two);
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h].into_iter()) {
            *slot = slot.wrapping_add(value);
        }
    }
    let mut digest = String::with_capacity(64);
    for value in state {
        digest.push_str(&format!("{value:08x}"));
    }
    Ok(digest)
}

fn command_line(program: &Path, arguments: &[&str], cwd: &Path, label: &str) -> Result<String> {
    let os_arguments: Vec<&OsStr> = arguments.iter().map(|value| OsStr::new(value)).collect();
    let output = run_command(program, &os_arguments, Some(cwd))?.require_success(label)?;
    let lines: Vec<&str> = output.lines().filter(|line| !line.is_empty()).collect();
    if lines.len() != 1 {
        return Err(ControllerError(format!(
            "{label} returned {} nonempty lines, expected one",
            lines.len()
        )));
    }
    Ok(lines[0].to_owned())
}

fn remove_tree(path: &Path) -> Result<()> {
    if !entry_exists(path)? {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(ControllerError(format!(
            "refusing to recursively remove symlink: {}",
            path.display()
        )));
    }
    fs::remove_dir_all(path)?;
    sync_parent(path)
}

fn sync_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| ControllerError("path has no parent for fsync".to_owned()))?;
    sync_directory(parent)
}

fn sync_directory(path: &Path) -> Result<()> {
    let file = File::open(path)?;
    file.sync_all()?;
    Ok(())
}

fn same_inode(left: &Metadata, right: &Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { geteuid() }
}

#[cfg(target_os = "macos")]
fn libc_o_nofollow() -> i32 {
    0x0000_0100
}

#[cfg(target_os = "linux")]
fn libc_o_nofollow() -> i32 {
    0x0002_0000
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn libc_o_nofollow() -> i32 {
    0
}

fn percent_encode(bytes: &[u8]) -> String {
    let mut output = String::new();
    for byte in bytes {
        if byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'_' | b'.' | b'/') {
            output.push(*byte as char);
        } else {
            output.push('%');
            output.push_str(&format!("{byte:02X}"));
        }
    }
    output
}

fn percent_decode(value: &str) -> Result<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return Err(ControllerError("truncated percent encoding".to_owned()));
            }
            let high = hex_value(bytes[index + 1])?;
            let low = hex_value(bytes[index + 2])?;
            decoded.push((high << 4) | low);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded)
        .map_err(|_| ControllerError("percent-decoded journal field is not UTF-8".to_owned()))
}

fn hex_value(byte: u8) -> Result<u8> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(ControllerError(
            "invalid percent-encoding hex digit".to_owned(),
        )),
    }
}

// Deterministic executable transaction tests. The real forward, rollback, committed-recovery,
// and active-pointer sequencers above run against fake launchd/process/filesystem backends here.
// Every fake mutation enforces the no-overlap and immutable-legacy invariants immediately.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FakeLockOwner {
    Legacy,
    New,
}

#[derive(Clone, Debug)]
struct FakeWorld {
    legacy_app_unchanged: bool,
    legacy_plist_unchanged: bool,
    active_pending: bool,
    active_published: bool,
    legacy_disabled: bool,
    legacy_running: bool,
    new_app_hold: bool,
    new_app_present: bool,
    new_plist_hold: bool,
    new_plist_present: bool,
    new_running: bool,
    lock_owner: Option<FakeLockOwner>,
    generation: u64,
    current_pid: Option<u32>,
    committed_pid: Option<u32>,
    checkpoint_generation: Option<u64>,
    marker_generation: Option<u64>,
    stable_generation: Option<u64>,
    committed: bool,
    recovery_in_progress: bool,
    evidence_written: bool,
    operation_log: Vec<String>,
}

impl FakeWorld {
    fn baseline() -> Self {
        Self {
            legacy_app_unchanged: true,
            legacy_plist_unchanged: true,
            active_pending: false,
            active_published: true,
            legacy_disabled: false,
            legacy_running: true,
            new_app_hold: false,
            new_app_present: false,
            new_plist_hold: false,
            new_plist_present: false,
            new_running: false,
            lock_owner: Some(FakeLockOwner::Legacy),
            generation: 0,
            current_pid: None,
            committed_pid: None,
            checkpoint_generation: None,
            marker_generation: None,
            stable_generation: None,
            committed: false,
            recovery_in_progress: false,
            evidence_written: false,
            operation_log: Vec::new(),
        }
    }

    fn assert_invariants(&self) -> Result<()> {
        if !self.legacy_app_unchanged || !self.legacy_plist_unchanged {
            return Err(ControllerError(
                "fake backend mutated a protected legacy rollback source".to_owned(),
            ));
        }
        if self.active_pending && self.active_published {
            return Err(ControllerError(
                "fake active pointer has pending and published names together".to_owned(),
            ));
        }
        if self.new_app_hold && self.new_app_present {
            return Err(ControllerError(
                "fake app exists at both hold and live destination".to_owned(),
            ));
        }
        if self.new_plist_hold && self.new_plist_present {
            return Err(ControllerError(
                "fake plist exists at both hold and live destination".to_owned(),
            ));
        }
        if self.legacy_running && self.new_running {
            return Err(ControllerError(
                "fake backend overlapped legacy and new hosts".to_owned(),
            ));
        }
        if self.legacy_running && self.lock_owner != Some(FakeLockOwner::Legacy) {
            return Err(ControllerError(
                "fake legacy process does not exclusively own the runtime lock".to_owned(),
            ));
        }
        if self.new_running && self.lock_owner != Some(FakeLockOwner::New) {
            return Err(ControllerError(
                "fake new process does not exclusively own the runtime lock".to_owned(),
            ));
        }
        if self.lock_owner == Some(FakeLockOwner::Legacy) && !self.legacy_running {
            return Err(ControllerError(
                "fake legacy lock owner exists without the legacy process".to_owned(),
            ));
        }
        if self.lock_owner == Some(FakeLockOwner::New) && !self.new_running {
            return Err(ControllerError(
                "fake new lock owner exists without the new process".to_owned(),
            ));
        }
        if self.new_running
            && (!self.new_app_present
                || !self.new_plist_present
                || !self.legacy_disabled
                || self.legacy_running
                || self.current_pid.is_none())
        {
            return Err(ControllerError(
                "fake new process lacks its exact installed/disabled contract".to_owned(),
            ));
        }
        if self.operation_log.len() > 4_096 {
            return Err(ControllerError(
                "fake operation log exceeded its deterministic bound".to_owned(),
            ));
        }
        if self.committed && !self.recovery_in_progress {
            if !self.evidence_written
                || !self.new_running
                || self.legacy_running
                || !self.legacy_disabled
                || self.marker_generation != Some(self.generation)
                || self.stable_generation != Some(self.generation)
            {
                return Err(ControllerError(
                    "fake committed state lacks current-generation readiness".to_owned(),
                ));
            }
        }
        if self.recovery_in_progress
            && (!self.committed || self.legacy_running || !self.legacy_disabled)
        {
            return Err(ControllerError(
                "fake committed recovery violates the legacy absence boundary".to_owned(),
            ));
        }
        Ok(())
    }

    fn assert_legacy_restored(&self) -> Result<()> {
        self.assert_invariants()?;
        if !self.evidence_written
            || self.legacy_disabled
            || !self.legacy_running
            || self.new_running
            || self.new_app_present
            || self.new_plist_present
            || self.new_app_hold
            || self.new_plist_hold
            || self.lock_owner != Some(FakeLockOwner::Legacy)
        {
            return Err(ControllerError(
                "fake rollback did not restore the exact legacy runtime".to_owned(),
            ));
        }
        Ok(())
    }

    fn assert_committed_current_generation(&self) -> Result<()> {
        self.assert_invariants()?;
        if !self.committed
            || self.recovery_in_progress
            || !self.new_running
            || self.lock_owner != Some(FakeLockOwner::New)
            || self.marker_generation != Some(self.generation)
            || self.stable_generation != Some(self.generation)
            || self.current_pid.is_none()
        {
            return Err(ControllerError(
                "fake committed recovery lacks a fresh stable generation".to_owned(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommitRacePoint {
    AfterVerifyEffect,
    DuringFieldCapture,
    AfterRevalidationBeforeDurableWrite,
    ImmediatelyAfterDurableWrite,
    BeforeRetainedActivePointerValidation,
}

struct FakeBackend {
    world: FakeWorld,
    provenance_ready: bool,
    observed_pid: Option<u32>,
    historical_pid: String,
    reject_marker: bool,
    race_before_effect: Option<ForwardEffect>,
    commit_race: Option<CommitRacePoint>,
}

impl FakeBackend {
    fn baseline() -> Self {
        Self {
            world: FakeWorld::baseline(),
            provenance_ready: false,
            observed_pid: None,
            historical_pid: "unrecorded".to_owned(),
            reject_marker: false,
            race_before_effect: None,
            commit_race: None,
        }
    }

    fn from_world(world: FakeWorld) -> Self {
        let historical_pid = world
            .committed_pid
            .map_or_else(|| "unrecorded".to_owned(), |pid| pid.to_string());
        Self {
            world,
            provenance_ready: true,
            observed_pid: None,
            historical_pid,
            reject_marker: false,
            race_before_effect: None,
            commit_race: None,
        }
    }

    fn log(&mut self, value: impl Into<String>) -> Result<()> {
        self.world.operation_log.push(value.into());
        self.world.assert_invariants()
    }

    fn checkpoint_fields(&self) -> Result<Vec<(String, String)>> {
        let generation = self
            .world
            .checkpoint_generation
            .ok_or_else(|| ControllerError("fake backend lacks a log checkpoint".to_owned()))?;
        let mut fields = vec![
            ("log_offset".to_owned(), (100 + generation).to_string()),
            ("log_device".to_owned(), "7".to_owned()),
            ("log_inode".to_owned(), "11".to_owned()),
        ];
        if let Some(pid) = self.observed_pid.or(self.world.current_pid) {
            fields.extend([
                ("pid".to_owned(), pid.to_string()),
                ("runs".to_owned(), generation.to_string()),
                (
                    "process_start".to_owned(),
                    format!("fake-start-{generation}"),
                ),
                ("nonce".to_owned(), format!("{generation:064x}")),
                ("lock_device".to_owned(), "29".to_owned()),
                ("lock_inode".to_owned(), "31".to_owned()),
            ]);
        }
        Ok(fields)
    }

    fn recovery_fields(&self) -> Result<Vec<(String, String)>> {
        let generation = self.world.generation;
        let mut fields = Vec::new();
        if let Some(checkpoint_generation) = self.world.checkpoint_generation {
            fields.extend([
                (
                    "recovery_log_offset".to_owned(),
                    (200 + checkpoint_generation).to_string(),
                ),
                ("recovery_log_device".to_owned(), "17".to_owned()),
                ("recovery_log_inode".to_owned(), "19".to_owned()),
            ]);
        }
        if let Some(pid) = self.observed_pid.or(self.world.current_pid) {
            fields.extend([
                ("recovery_pid".to_owned(), pid.to_string()),
                ("recovery_runs".to_owned(), generation.to_string()),
                (
                    "recovery_process_start".to_owned(),
                    format!("fake-start-{generation}"),
                ),
                ("recovery_nonce".to_owned(), format!("{generation:064x}")),
                ("recovery_lock_device".to_owned(), "37".to_owned()),
                ("recovery_lock_inode".to_owned(), "41".to_owned()),
            ]);
        }
        Ok(fields)
    }
}

impl ForwardEffectBackend for FakeBackend {
    fn perform_effect(&mut self, effect: ForwardEffect) -> Result<()> {
        if self.race_before_effect == Some(effect) {
            self.race_before_effect = None;
            match effect {
                ForwardEffect::ObserveNewPid => {
                    // Generation A published readiness, then KeepAlive replaced it with B
                    // before the controller observed the launch generation.
                    self.world.marker_generation = Some(self.world.generation);
                    restart_fake_generation(&mut self.world);
                    self.reject_marker = true;
                }
                ForwardEffect::ObserveFreshMarker
                | ForwardEffect::VerifyStableDeployment
                | ForwardEffect::VerifyCommitState => {
                    restart_fake_generation(&mut self.world);
                }
                _ => {}
            }
        }
        match effect {
            ForwardEffect::VerifyProvenance => {
                self.provenance_ready = true;
            }
            ForwardEffect::SnapshotLegacy => {
                if !self.world.legacy_running {
                    return Err(ControllerError(
                        "fake snapshot requires the running legacy host".to_owned(),
                    ));
                }
            }
            ForwardEffect::BuildAndStage => {
                if !self.provenance_ready {
                    return Err(ControllerError(
                        "fake build lacks verified provenance".to_owned(),
                    ));
                }
            }
            ForwardEffect::VerifyPrecutover => {
                if self.world.legacy_disabled
                    || !self.world.legacy_running
                    || self.world.new_running
                    || self.world.new_app_present
                    || self.world.new_plist_present
                    || self.world.lock_owner != Some(FakeLockOwner::Legacy)
                {
                    return Err(ControllerError(
                        "fake precutover verification rejected drift".to_owned(),
                    ));
                }
            }
            ForwardEffect::DisableLegacy => {
                self.world.legacy_disabled = true;
            }
            ForwardEffect::VerifyLegacyDisabled => {
                if !self.world.legacy_disabled {
                    return Err(ControllerError(
                        "fake legacy disable did not persist".to_owned(),
                    ));
                }
            }
            ForwardEffect::BootoutLegacy => {
                if !self.world.legacy_disabled {
                    return Err(ControllerError(
                        "fake bootout requires durable disable".to_owned(),
                    ));
                }
                self.world.legacy_running = false;
                self.world.lock_owner = None;
            }
            ForwardEffect::WaitLegacyServiceAbsent | ForwardEffect::WaitLegacyProcessAbsent => {
                if self.world.legacy_running {
                    return Err(ControllerError(
                        "fake legacy host remained present".to_owned(),
                    ));
                }
            }
            ForwardEffect::VerifyNoCaptureServers => {
                if self.world.legacy_running || self.world.new_running {
                    return Err(ControllerError(
                        "fake CaptureServer process remained".to_owned(),
                    ));
                }
            }
            ForwardEffect::VerifyLockHandoff => {
                if self.world.lock_owner.is_some() {
                    return Err(ControllerError(
                        "fake shared lock remained owned".to_owned(),
                    ));
                }
            }
            ForwardEffect::PrepareLogs => {
                if self.world.legacy_running
                    || self.world.new_running
                    || self.world.lock_owner.is_some()
                {
                    return Err(ControllerError(
                        "fake checkpoint preceded lock handoff".to_owned(),
                    ));
                }
                self.world.checkpoint_generation = None;
                self.world.marker_generation = None;
                self.world.stable_generation = None;
            }
            ForwardEffect::CopyAppInstallHold => {
                if self.world.new_app_hold || self.world.new_app_present {
                    return Err(ControllerError(
                        "fake app install destination is occupied".to_owned(),
                    ));
                }
                self.world.new_app_hold = true;
            }
            ForwardEffect::PublishApp => {
                if !self.world.new_app_hold || self.world.new_app_present {
                    return Err(ControllerError(
                        "fake app hold cannot be published".to_owned(),
                    ));
                }
                self.world.new_app_hold = false;
                self.world.new_app_present = true;
            }
            ForwardEffect::CopyPlistInstallHold => {
                if self.world.new_plist_hold || self.world.new_plist_present {
                    return Err(ControllerError(
                        "fake plist install destination is occupied".to_owned(),
                    ));
                }
                self.world.new_plist_hold = true;
            }
            ForwardEffect::PublishPlist => {
                if !self.world.new_plist_hold || self.world.new_plist_present {
                    return Err(ControllerError(
                        "fake plist hold cannot be published".to_owned(),
                    ));
                }
                self.world.new_plist_hold = false;
                self.world.new_plist_present = true;
            }
            ForwardEffect::VerifyInstalledDestinations => {
                if !self.world.new_app_present
                    || !self.world.new_plist_present
                    || self.world.new_app_hold
                    || self.world.new_plist_hold
                {
                    return Err(ControllerError(
                        "fake installed destinations are incomplete".to_owned(),
                    ));
                }
            }
            ForwardEffect::BootstrapNew => {
                if !self.world.new_app_present
                    || !self.world.new_plist_present
                    || self.world.legacy_running
                    || !self.world.legacy_disabled
                    || self.world.lock_owner.is_some()
                {
                    return Err(ControllerError(
                        "fake bootstrap rejected unsafe state".to_owned(),
                    ));
                }
                self.world.generation += 1;
                self.world.current_pid = Some(4_200 + self.world.generation as u32);
                self.world.new_running = true;
                self.world.lock_owner = Some(FakeLockOwner::New);
                self.world.marker_generation = None;
                self.world.stable_generation = None;
            }
            ForwardEffect::ObserveNewPid => {
                self.observed_pid = self.world.current_pid;
                if !self.world.new_running || self.observed_pid.is_none() {
                    return Err(ControllerError(
                        "fake launchd generation has no PID".to_owned(),
                    ));
                }
            }
            ForwardEffect::CheckpointGenerationLog => {
                if !self.world.new_running || self.observed_pid != self.world.current_pid {
                    return Err(ControllerError(
                        "fake generation checkpoint lacks the observed process".to_owned(),
                    ));
                }
                self.world.checkpoint_generation = Some(self.world.generation);
                self.world.marker_generation = None;
                self.world.stable_generation = None;
            }
            ForwardEffect::ObserveFreshMarker => {
                if self.reject_marker {
                    return Err(injected_failure(
                        InjectedFault::Readiness,
                        ForwardEffect::ObserveFreshMarker,
                        EffectPhase::BeforeSideEffect,
                    ));
                }
                if self.world.checkpoint_generation != Some(self.world.generation)
                    || !self.world.new_running
                {
                    return Err(ControllerError(
                        "fake marker is not tied to the checkpointed generation".to_owned(),
                    ));
                }
                self.world.marker_generation = Some(self.world.generation);
            }
            ForwardEffect::VerifyStableDeployment => {
                if self.world.marker_generation != Some(self.world.generation)
                    || !self.world.new_running
                    || self.world.legacy_running
                    || self.world.lock_owner != Some(FakeLockOwner::New)
                {
                    return Err(ControllerError(
                        "fake stability proof rejected current state".to_owned(),
                    ));
                }
                self.world.stable_generation = Some(self.world.generation);
            }
            ForwardEffect::VerifyCommitState => {
                if self.world.marker_generation != Some(self.world.generation)
                    || self.world.stable_generation != Some(self.world.generation)
                {
                    return Err(ControllerError(
                        "fake commit lacks fresh stable readiness".to_owned(),
                    ));
                }
                if self.commit_race == Some(CommitRacePoint::AfterVerifyEffect) {
                    self.commit_race = None;
                    restart_fake_generation(&mut self.world);
                }
            }
        }
        self.log(format!("forward:{effect:?}"))
    }

    fn operation_fields(&mut self, operation: ForwardOperation) -> Result<Vec<(String, String)>> {
        match operation {
            ForwardOperation::VerifyProvenance => Ok(vec![
                ("commit".to_owned(), "0123456789abcdef".to_owned()),
                ("tree".to_owned(), "fedcba9876543210".to_owned()),
            ]),
            ForwardOperation::ObserveNewPid | ForwardOperation::VerifyReadiness => {
                self.checkpoint_fields()
            }
            ForwardOperation::Commit => {
                let fields = self.checkpoint_fields()?;
                if self.commit_race == Some(CommitRacePoint::DuringFieldCapture) {
                    self.commit_race = None;
                    restart_fake_generation(&mut self.world);
                }
                Ok(fields)
            }
            ForwardOperation::InstallNew | ForwardOperation::BootstrapNew => Ok(Vec::new()),
            ForwardOperation::SnapshotLegacy
            | ForwardOperation::BuildAndStage
            | ForwardOperation::VerifyPrecutover
            | ForwardOperation::DisableLegacy
            | ForwardOperation::StopLegacy
            | ForwardOperation::VerifyLockHandoff => Ok(Vec::new()),
        }
    }

    fn revalidate_commit_fields(&mut self, fields: &[(String, String)]) -> Result<()> {
        let expected = self.checkpoint_fields()?;
        if fields != expected.as_slice()
            || self.world.marker_generation != Some(self.world.generation)
            || self.world.stable_generation != Some(self.world.generation)
            || self.observed_pid != self.world.current_pid
            || !self.world.new_running
            || self.world.legacy_running
            || self.world.lock_owner != Some(FakeLockOwner::New)
        {
            return Err(ControllerError(
                "fake final COMMIT generation revalidation failed".to_owned(),
            ));
        }
        Ok(())
    }

    fn after_commit_revalidation_before_durable_write(&mut self) -> Result<()> {
        if self.commit_race == Some(CommitRacePoint::AfterRevalidationBeforeDurableWrite) {
            self.commit_race = None;
            restart_fake_generation(&mut self.world);
        }
        Ok(())
    }

    fn committed_recorded(&mut self, fields: &[(String, String)]) -> Result<()> {
        self.world.committed = true;
        self.world.committed_pid = self.observed_pid;
        self.world.evidence_written = true;
        if self.commit_race == Some(CommitRacePoint::ImmediatelyAfterDurableWrite) {
            self.commit_race = None;
            self.world.recovery_in_progress = true;
            restart_fake_generation(&mut self.world);
        }
        if let Err(error) = self.revalidate_commit_fields(fields) {
            self.world.recovery_in_progress = true;
            self.world.assert_invariants()?;
            return Err(error);
        }
        self.world.assert_invariants()
    }

    fn before_retained_active_pointer_validation(
        &mut self,
        fields: &[(String, String)],
    ) -> Result<()> {
        if self.commit_race == Some(CommitRacePoint::BeforeRetainedActivePointerValidation) {
            self.commit_race = None;
            self.world.recovery_in_progress = true;
            restart_fake_generation(&mut self.world);
        }
        if let Err(error) = self.revalidate_commit_fields(fields) {
            self.world.recovery_in_progress = true;
            self.world.assert_invariants()?;
            return Err(error);
        }
        Ok(())
    }
}

impl RollbackBackend for FakeBackend {
    fn legacy_is_loaded(&mut self) -> Result<bool> {
        Ok(self.world.legacy_running)
    }

    fn perform(&mut self, mode: RollbackMode, operation: RollbackOperation) -> Result<()> {
        match operation {
            RollbackOperation::Begin => {
                // Durable COMMIT, not an unjournaled side effect, is the only
                // state that may enter committed recovery instead of rollback.
                self.world.committed = false;
                self.world.recovery_in_progress = false;
            }
            RollbackOperation::VerifyBeforeStop => {
                if !self.world.legacy_running
                    || self.world.new_running
                    || self.world.new_app_present
                    || self.world.new_plist_present
                {
                    return Err(ControllerError(
                        "fake pre-stop rollback rejected drift".to_owned(),
                    ));
                }
            }
            RollbackOperation::StopNew => {
                if self.world.new_running {
                    self.world.new_running = false;
                    self.world.current_pid = None;
                    if self.world.lock_owner == Some(FakeLockOwner::New) {
                        self.world.lock_owner = None;
                    }
                }
                self.world.marker_generation = None;
                self.world.stable_generation = None;
            }
            RollbackOperation::ClearNewDestinations => {
                if self.world.new_running || self.world.lock_owner == Some(FakeLockOwner::New) {
                    return Err(ControllerError(
                        "fake destination clearing preceded new-host absence".to_owned(),
                    ));
                }
                self.world.new_app_hold = false;
                self.world.new_app_present = false;
                self.world.new_plist_hold = false;
                self.world.new_plist_present = false;
            }
            RollbackOperation::EnableLegacy => {
                self.world.legacy_disabled = false;
            }
            RollbackOperation::BootstrapLegacy => {
                if self.world.new_running
                    || self.world.new_app_present
                    || self.world.new_plist_present
                    || self.world.lock_owner.is_some()
                {
                    return Err(ControllerError(
                        "fake legacy bootstrap would overlap the new host".to_owned(),
                    ));
                }
                self.world.legacy_running = true;
                self.world.lock_owner = Some(FakeLockOwner::Legacy);
            }
            RollbackOperation::VerifyLegacy => {
                if !self.world.legacy_running
                    || self.world.legacy_disabled
                    || self.world.new_running
                {
                    return Err(ControllerError(
                        "fake restored legacy verification failed".to_owned(),
                    ));
                }
                if mode == RollbackMode::FullRestore
                    && (self.world.new_app_present
                        || self.world.new_plist_present
                        || self.world.new_app_hold
                        || self.world.new_plist_hold)
                {
                    return Err(ControllerError(
                        "fake full rollback left a new live destination".to_owned(),
                    ));
                }
            }
            RollbackOperation::ArchiveEvidence => {
                self.world.evidence_written = true;
            }
            RollbackOperation::Finish => {
                self.world.checkpoint_generation = None;
                self.world.observed_cleanup();
            }
        }
        self.log(format!("rollback:{mode:?}:{operation:?}"))
    }
}

impl FakeWorld {
    fn observed_cleanup(&mut self) {
        self.marker_generation = None;
        self.stable_generation = None;
        self.current_pid = None;
        self.committed_pid = None;
    }
}

impl CommittedRecoveryBackend for FakeBackend {
    fn perform(&mut self, operation: CommittedRecoveryOperation) -> Result<Vec<(String, String)>> {
        let fields = match operation {
            CommittedRecoveryOperation::VerifyCommittedDestinations => {
                if !self.world.committed
                    || !self.world.new_app_present
                    || !self.world.new_plist_present
                    || !self.world.legacy_disabled
                    || self.world.legacy_running
                {
                    return Err(ControllerError(
                        "fake committed destinations are invalid".to_owned(),
                    ));
                }
                Vec::new()
            }
            CommittedRecoveryOperation::StopCurrentNew => {
                self.world.recovery_in_progress = true;
                if self.world.new_running {
                    self.world.new_running = false;
                    self.world.current_pid = None;
                    self.world.lock_owner = None;
                }
                self.world.checkpoint_generation = None;
                self.world.marker_generation = None;
                self.world.stable_generation = None;
                Vec::new()
            }
            CommittedRecoveryOperation::BootstrapNew => {
                if self.world.new_running || self.world.lock_owner.is_some() {
                    return Err(ControllerError(
                        "fake committed bootstrap preceded exact stop/lock handoff".to_owned(),
                    ));
                }
                self.world.generation += 1;
                self.world.current_pid = Some(5_200 + self.world.generation as u32);
                self.world.new_running = true;
                self.world.lock_owner = Some(FakeLockOwner::New);
                Vec::new()
            }
            CommittedRecoveryOperation::ObserveCurrentGeneration => {
                self.observed_pid = self.world.current_pid;
                if !self.world.new_running || self.observed_pid.is_none() {
                    return Err(ControllerError(
                        "fake committed generation has no PID".to_owned(),
                    ));
                }
                if self.historical_pid == self.observed_pid.unwrap().to_string() {
                    return Err(ControllerError(
                        "fake committed recovery reused historical PID".to_owned(),
                    ));
                }
                self.recovery_fields()?
            }
            CommittedRecoveryOperation::CheckpointCurrentGeneration => {
                if !self.world.new_running
                    || self.world.lock_owner != Some(FakeLockOwner::New)
                    || self.observed_pid != self.world.current_pid
                {
                    return Err(ControllerError(
                        "fake committed checkpoint is not bound to the observed generation"
                            .to_owned(),
                    ));
                }
                self.world.checkpoint_generation = Some(self.world.generation);
                let mut values = self.recovery_fields()?;
                values.push(("historical_pid".to_owned(), self.historical_pid.clone()));
                values
            }
            CommittedRecoveryOperation::ObserveFreshMarker => {
                if self.reject_marker {
                    return Err(injected_failure(
                        InjectedFault::Readiness,
                        CommittedRecoveryOperation::ObserveFreshMarker,
                        EffectPhase::BeforeSideEffect,
                    ));
                }
                if self.world.checkpoint_generation != Some(self.world.generation)
                    || self.observed_pid != self.world.current_pid
                {
                    return Err(ControllerError(
                        "fake committed marker predates or mismatches its generation checkpoint"
                            .to_owned(),
                    ));
                }
                self.world.marker_generation = Some(self.world.generation);
                Vec::new()
            }
            CommittedRecoveryOperation::VerifyStableCurrentGeneration => {
                if self.world.marker_generation != Some(self.world.generation)
                    || self.world.checkpoint_generation != Some(self.world.generation)
                    || self.observed_pid != self.world.current_pid
                    || !self.world.new_running
                    || self.world.lock_owner != Some(FakeLockOwner::New)
                    || self.world.legacy_running
                {
                    return Err(ControllerError(
                        "fake committed stability proof failed".to_owned(),
                    ));
                }
                self.world.stable_generation = Some(self.world.generation);
                self.world.recovery_in_progress = false;
                self.recovery_fields()?
            }
        };
        self.log(format!("committed-recovery:{operation:?}"))?;
        Ok(fields)
    }
}

struct TemporaryDirectory {
    path: PathBuf,
}

impl TemporaryDirectory {
    fn create(label: &str) -> Result<Self> {
        let base = env::temp_dir();
        for attempt in 0..128u32 {
            let candidate = base.join(format!(
                "opensteamer-controller-{label}-{}-{attempt}",
                process::id()
            ));
            match fs::create_dir(&candidate) {
                Ok(()) => {
                    fs::set_permissions(&candidate, Permissions::from_mode(0o700))?;
                    let canonical = fs::canonicalize(&candidate)?;
                    return Ok(Self { path: canonical });
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        }
        Err(ControllerError(
            "could not create unique self-test directory".to_owned(),
        ))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

const FAKE_JOURNAL_VERSION: &str = "OPENSTEAMER_FAKE_MIGRATION_JOURNAL_V11";

struct FakeJournal {
    path: PathBuf,
    file: File,
    last_state: State,
    saw_legacy_disabled: bool,
    saw_legacy_stopped: bool,
}

fn state_implies_legacy_disabled(state: State) -> bool {
    matches!(
        state,
        State::LegacyDisabled
            | State::LegacyStopped
            | State::LockHandedOff
            | State::NewInstalled
            | State::NewBootstrapped
            | State::NewPidObserved
            | State::ReadyVerified
            | State::Committed
            | State::CommittedRecoveryStarted
            | State::CommittedRecoveryBootstrapped
            | State::CommittedRecoveryReady
            | State::RollbackStarted
            | State::NewStopped
            | State::NewDestinationsCleared
            | State::LegacyReenabled
            | State::LegacyBootstrapped
            | State::LegacyRecovered
            | State::RolledBack
    )
}

fn state_implies_legacy_stopped(state: State) -> bool {
    matches!(
        state,
        State::LegacyStopped
            | State::LockHandedOff
            | State::NewInstalled
            | State::NewBootstrapped
            | State::NewPidObserved
            | State::ReadyVerified
            | State::Committed
            | State::CommittedRecoveryStarted
            | State::CommittedRecoveryBootstrapped
            | State::CommittedRecoveryReady
            | State::RollbackStarted
            | State::NewStopped
            | State::NewDestinationsCleared
            | State::LegacyReenabled
            | State::LegacyBootstrapped
            | State::LegacyRecovered
            | State::RolledBack
    )
}

impl FakeJournal {
    fn create(path: &Path) -> Result<Self> {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
            .open(path)?;
        file.set_permissions(Permissions::from_mode(0o600))?;
        writeln!(file, "{FAKE_JOURNAL_VERSION}")?;
        writeln!(file, "STATE {}", State::Begun.as_str())?;
        file.sync_all()?;
        sync_parent(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            file,
            last_state: State::Begun,
            saw_legacy_disabled: false,
            saw_legacy_stopped: false,
        })
    }

    fn open(path: &Path) -> Result<Self> {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
            .open(path)?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        let valid_length = bytes
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map_or(0, |index| index + 1);
        if valid_length != bytes.len() {
            file.set_len(valid_length as u64)?;
            file.sync_all()?;
            bytes.truncate(valid_length);
        }
        let text = String::from_utf8(bytes)
            .map_err(|_| ControllerError("fake journal is not UTF-8".to_owned()))?;
        let mut lines = text.lines();
        if lines.next() != Some(FAKE_JOURNAL_VERSION) {
            return Err(ControllerError(
                "fake journal version is invalid".to_owned(),
            ));
        }
        let mut last_state = State::Begun;
        let mut saw_legacy_disabled = false;
        let mut saw_legacy_stopped = false;
        for line in lines {
            let value = line
                .strip_prefix("STATE ")
                .ok_or_else(|| ControllerError("fake journal record is invalid".to_owned()))?;
            let token = value.split_whitespace().next().unwrap_or_default();
            let state = State::parse(token).ok_or_else(|| {
                ControllerError(format!("fake journal state is unknown: {token}"))
            })?;
            last_state = state;
            saw_legacy_disabled |= state_implies_legacy_disabled(state);
            saw_legacy_stopped |= state_implies_legacy_stopped(state);
        }
        file.seek(SeekFrom::End(0))?;
        Ok(Self {
            path: path.to_path_buf(),
            file,
            last_state,
            saw_legacy_disabled,
            saw_legacy_stopped,
        })
    }

    fn append_partial(&mut self, bytes: &[u8]) -> Result<()> {
        self.file.write_all(bytes)?;
        self.file.sync_all()?;
        Ok(())
    }
}

impl JournalSink for FakeJournal {
    fn record(&mut self, state: State, fields: &[(String, String)]) -> Result<()> {
        write!(self.file, "STATE {}", state.as_str())?;
        for (key, value) in fields {
            write!(self.file, " {key}={}", percent_encode(value.as_bytes()))?;
        }
        writeln!(self.file)?;
        self.file.sync_all()?;
        sync_parent(&self.path)?;
        self.last_state = state;
        self.saw_legacy_disabled |= state_implies_legacy_disabled(state);
        self.saw_legacy_stopped |= state_implies_legacy_stopped(state);
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InjectedFault {
    Permission,
    Storage,
    Command,
    MalformedOutput,
    Readiness,
    Interruption,
}

fn injected_failure(
    fault: InjectedFault,
    label: impl std::fmt::Debug,
    phase: EffectPhase,
) -> ControllerError {
    ControllerError(format!(
        "injected {fault:?} failure at {label:?} during {phase:?}"
    ))
}

fn recover_fake_transaction(world: FakeWorld, journal: &mut FakeJournal) -> Result<FakeWorld> {
    let mut backend = FakeBackend::from_world(world);
    if journal.last_state.is_committed_family() {
        drive_committed_recovery(&mut backend, journal, |_, _, _| Ok(()))?;
        backend.world.evidence_written = true;
        backend.world.assert_committed_current_generation()?;
    } else {
        let crossed = journal.saw_legacy_stopped || !backend.world.legacy_running;
        let saw_legacy_disabled = journal.saw_legacy_disabled;
        drive_rollback(
            &mut backend,
            journal,
            crossed,
            saw_legacy_disabled,
            |_, _, _| Ok(()),
        )?;
        backend.world.assert_legacy_restored()?;
    }
    Ok(backend.world)
}

fn run_forward_with_boundary_fault(
    fault: InjectedFault,
    target: usize,
) -> Result<(bool, FakeWorld, FakeJournal, TemporaryDirectory)> {
    let directory = TemporaryDirectory::create("forward-boundary")?;
    let path = directory.path.join("journal.log");
    let mut journal = FakeJournal::create(&path)?;
    let mut backend = FakeBackend::baseline();
    let mut boundary = 0usize;
    let result = drive_forward(&mut backend, &mut journal, |_, _, _, effect, phase| {
        if boundary == target {
            return Err(injected_failure(fault, effect, phase));
        }
        boundary += 1;
        Ok(())
    });
    Ok((result.is_err(), backend.world, journal, directory))
}

fn prepare_failed_forward() -> Result<(FakeWorld, FakeJournal, TemporaryDirectory)> {
    let directory = TemporaryDirectory::create("failed-forward")?;
    let path = directory.path.join("journal.log");
    let mut journal = FakeJournal::create(&path)?;
    let mut backend = FakeBackend::baseline();
    backend.reject_marker = true;
    if drive_forward(&mut backend, &mut journal, |_, _, _, _, _| Ok(())).is_ok() {
        return Err(ControllerError(
            "fake readiness failure unexpectedly committed".to_owned(),
        ));
    }
    Ok((backend.world, journal, directory))
}

fn replace_exactly_once(
    input: &str,
    needle: &str,
    replacement: &str,
    label: &str,
) -> Result<String> {
    let matches = input.match_indices(needle).count();
    if matches != 1 {
        return Err(ControllerError(format!(
            "{label} mutation expected exactly one site, found {matches}"
        )));
    }
    let output = input.replacen(needle, replacement, 1);
    if output == input {
        return Err(ControllerError(format!("{label} mutation was a no-op")));
    }
    Ok(output)
}

fn self_test_parsers() -> Result<()> {
    if sha256_bytes(b"")? != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        || sha256_bytes(b"abc")?
            != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    {
        return Err(ControllerError(
            "in-process SHA-256 failed its reviewed test vectors".to_owned(),
        ));
    }
    verify_embedded_verifier_hashes()?;

    let df_fixture = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s1 239362496 206822552 8990052 96% /System/Volumes/Data\n";
    if parse_posix_df_available_bytes(df_fixture)? != 8_990_052 * 1024 {
        return Err(ControllerError(
            "df parser returned the wrong available-byte count".to_owned(),
        ));
    }
    for malformed in [
        "",
        "header only\n",
        "header\n/dev/disk3s1 1 2 nope 4% /\n",
        "header\n/dev/disk3s1 1 2 3 4% / extra\n",
    ] {
        if parse_posix_df_available_bytes(malformed).is_ok() {
            return Err(ControllerError(
                "df parser accepted malformed or ambiguous output".to_owned(),
            ));
        }
    }

    let missing = "disabled services = {\n    \"other.label\" => enabled\n}\n";
    if parse_disabled_override(missing, LEGACY_LABEL)? != None {
        return Err(ControllerError(
            "disabled parser did not report an omitted label".to_owned(),
        ));
    }
    for (value, expected) in [
        ("enabled", false),
        ("disabled", true),
        ("false", false),
        ("true", true),
    ] {
        let fixture = format!("disabled services = {{\n    \"{LEGACY_LABEL}\" => {value}\n}}\n");
        if parse_disabled_override(&fixture, LEGACY_LABEL)? != Some(expected) {
            return Err(ControllerError(format!(
                "disabled parser misclassified '{value}'"
            )));
        }
    }
    for malformed in [
        format!(
            "disabled services = {{\n    \"{LEGACY_LABEL}\" => disabled\n    \"{LEGACY_LABEL}\" => disabled\n}}\n"
        ),
        format!(
            "disabled services = {{\n    \"{LEGACY_LABEL}\" => maybe\n}}\n"
        ),
        format!(
            "disabled services = {{\n    \"{LEGACY_LABEL}\" => disabled\n"
        ),
        format!(
            "disabled services = {{\n    \"{LEGACY_LABEL}\" => disabled\n}}\ntrailing\n"
        ),
    ] {
        if parse_disabled_override(&malformed, LEGACY_LABEL).is_ok() {
            return Err(ControllerError(
                "disabled parser accepted malformed or ambiguous output".to_owned(),
            ));
        }
    }

    let real_launchctl_fixture = [
        format!("gui/{USER_ID}/{NEW_LABEL} = {{"),
        "    active count = 1".to_owned(),
        format!("    path = {NEW_PLIST}"),
        "    type = LaunchAgent".to_owned(),
        "    state = running".to_owned(),
        format!("    program = {NEW_EXECUTABLE}"),
        "    arguments = {".to_owned(),
        format!("        {NEW_EXECUTABLE}"),
        "        --worldwide".to_owned(),
        "        --allow-remote-control".to_owned(),
        "        --duration".to_owned(),
        "        0".to_owned(),
        "        --verbose".to_owned(),
        "        --rendezvous-url".to_owned(),
        "        wss://audiostreamer-rendezvous.elaminahmed03.workers.dev".to_owned(),
        "    }".to_owned(),
        "    minimum runtime = 10".to_owned(),
        "    runs = 7".to_owned(),
        "    pid = 820".to_owned(),
        "    resource coalition = {".to_owned(),
        "        ID = 919".to_owned(),
        "        type = resource".to_owned(),
        "        state = active".to_owned(),
        "        pid = 99999".to_owned(),
        "        program = /tmp/attacker".to_owned(),
        "        arguments = {".to_owned(),
        "            /tmp/attacker".to_owned(),
        "        }".to_owned(),
        "    }".to_owned(),
        "    jetsam coalition = {".to_owned(),
        "        ID = 920".to_owned(),
        "        type = jetsam".to_owned(),
        "        state = active".to_owned(),
        "        runs = 999".to_owned(),
        "    }".to_owned(),
        "    properties = keepalive | runatload | inferred program | managed LWCR | has LWCR"
            .to_owned(),
        "}".to_owned(),
    ]
    .join("\n")
        + "\n";

    let parsed = parse_launch_snapshot(&real_launchctl_fixture, NEW_LABEL)?;
    if parsed.pid != 820
        || parsed.runs != 7
        || parsed.program != NEW_EXECUTABLE
        || parsed.arguments != expected_new_arguments()
    {
        return Err(ControllerError(
            "top-level launchctl parser was influenced by nested coalition fields".to_owned(),
        ));
    }

    let duplicate_pid = replace_exactly_once(
        &real_launchctl_fixture,
        "    pid = 820\n",
        "    pid = 820\n    pid = 821\n",
        "duplicate top-level PID",
    )?;
    if parse_launch_snapshot(&duplicate_pid, NEW_LABEL).is_ok() {
        return Err(ControllerError(
            "launchctl parser accepted duplicate top-level PID fields".to_owned(),
        ));
    }

    let duplicate_arguments = replace_exactly_once(
        &real_launchctl_fixture,
        "    minimum runtime = 10\n",
        "    arguments = {\n        /tmp/attacker\n    }\n    minimum runtime = 10\n",
        "duplicate top-level arguments",
    )?;
    if parse_launch_snapshot(&duplicate_arguments, NEW_LABEL).is_ok() {
        return Err(ControllerError(
            "launchctl parser accepted duplicate top-level arguments blocks".to_owned(),
        ));
    }

    let wrong_runs = replace_exactly_once(
        &real_launchctl_fixture,
        "    runs = 7\n",
        "    runs = not-a-number\n",
        "malformed top-level runs",
    )?;
    if parse_launch_snapshot(&wrong_runs, NEW_LABEL).is_ok() {
        return Err(ControllerError(
            "launchctl parser accepted malformed top-level runs".to_owned(),
        ));
    }

    let unclosed = real_launchctl_fixture.strip_suffix("}\n").ok_or_else(|| {
        ControllerError("unclosed launchctl mutation found no final job brace".to_owned())
    })?;
    if unclosed == real_launchctl_fixture || parse_launch_snapshot(unclosed, NEW_LABEL).is_ok() {
        return Err(ControllerError(
            "launchctl parser accepted an unclosed top-level job block".to_owned(),
        ));
    }
    Ok(())
}

fn restart_fake_generation(world: &mut FakeWorld) {
    world.generation += 1;
    world.current_pid = Some(4_800 + world.generation as u32);
    world.lock_owner = Some(FakeLockOwner::New);
    world.new_running = true;
}

fn self_test_generation_race() -> Result<()> {
    self_test_final_generation_active_pointer_boundary()?;
    for injection in [
        ForwardEffect::ObserveNewPid,
        ForwardEffect::ObserveFreshMarker,
        ForwardEffect::VerifyStableDeployment,
        ForwardEffect::VerifyCommitState,
    ] {
        let directory = TemporaryDirectory::create("generation-race")?;
        let path = directory.path.join("journal.log");
        let mut journal = FakeJournal::create(&path)?;
        let mut backend = FakeBackend::baseline();
        backend.race_before_effect = Some(injection);
        let result = drive_forward(&mut backend, &mut journal, |_, _, _, _, _| Ok(()));
        if result.is_ok() {
            return Err(ControllerError(format!(
                "generation race false-committed at {injection:?}"
            )));
        }
        let recovered = recover_fake_transaction(backend.world, &mut journal)?;
        recovered.assert_legacy_restored()?;
    }

    for injection in [
        CommitRacePoint::AfterVerifyEffect,
        CommitRacePoint::DuringFieldCapture,
        CommitRacePoint::AfterRevalidationBeforeDurableWrite,
        CommitRacePoint::ImmediatelyAfterDurableWrite,
        CommitRacePoint::BeforeRetainedActivePointerValidation,
    ] {
        let directory = TemporaryDirectory::create("commit-generation-race")?;
        let path = directory.path.join("journal.log");
        let mut journal = FakeJournal::create(&path)?;
        let mut backend = FakeBackend::baseline();
        backend.commit_race = Some(injection);
        let result = drive_forward(&mut backend, &mut journal, |_, _, _, _, _| Ok(()));
        if result.is_ok() {
            return Err(ControllerError(format!(
                "post-verification generation race false-committed at {injection:?}"
            )));
        }
        let committed_before_recovery = journal.last_state.is_committed_family();
        if matches!(
            injection,
            CommitRacePoint::AfterRevalidationBeforeDurableWrite
                | CommitRacePoint::ImmediatelyAfterDurableWrite
                | CommitRacePoint::BeforeRetainedActivePointerValidation
        ) && !committed_before_recovery
        {
            return Err(ControllerError(format!(
                "commit-boundary injection {injection:?} did not exercise a durable COMMITTED record"
            )));
        }
        let historical_pid = backend.world.committed_pid;
        let recovered = recover_fake_transaction(backend.world, &mut journal)?;
        if committed_before_recovery {
            recovered.assert_committed_current_generation()?;
            if historical_pid.is_some() && recovered.current_pid == historical_pid {
                return Err(ControllerError(format!(
                    "committed recovery reused historical generation after {injection:?}"
                )));
            }
        } else {
            recovered.assert_legacy_restored()?;
        }
    }

    let generation_a = LaunchGeneration {
        pid: 9001,
        runs: 1,
        process_start: "Mon Jul 27 12:00:00 2026".to_owned(),
        nonce: "a".repeat(64),
        lock_device: 10,
        lock_inode: 11,
    };
    let mut generation_b = generation_a.clone();
    generation_b.pid = 9002;
    generation_b.runs = 2;
    generation_b.process_start = "Mon Jul 27 12:00:01 2026".to_owned();
    generation_b.nonce = "b".repeat(64);
    if generation_a == generation_b {
        return Err(ControllerError(
            "generation identity failed to distinguish a KeepAlive restart".to_owned(),
        ));
    }
    Ok(())
}

fn assert_disposable_adapter_root(root: &Path) -> Result<PathBuf> {
    if root == Path::new("/") {
        return Err(ControllerError(
            "real-adapter root may not be the filesystem root".to_owned(),
        ));
    }
    let protected = [
        Path::new("/Applications"),
        Path::new("/Users/ahmed/Library/LaunchAgents"),
        Path::new(PRIVATE_ROOT),
        Path::new(MIGRATIONS_ROOT),
        Path::new(LOCK_DIRECTORY),
    ];
    if protected
        .iter()
        .any(|path| root == *path || root.starts_with(path) || path.starts_with(root))
    {
        return Err(ControllerError(format!(
            "real-adapter root overlaps a protected/live path: {}",
            root.display()
        )));
    }
    let canonical = fs::canonicalize(root)?;
    let temporary = fs::canonicalize(env::temp_dir())?;
    let name_is_guarded = canonical
        .file_name()
        .and_then(OsStr::to_str)
        .is_some_and(|name| name.starts_with("opensteamer-controller-real-adapter-"));
    if !canonical.starts_with(&temporary) || !name_is_guarded {
        return Err(ControllerError(format!(
            "real-adapter root is not a mandatory guarded temporary root: {}",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn run_sandbox_launch_command(root: &Path, action: &str) -> Result<CommandOutput> {
    let root = assert_disposable_adapter_root(root)?;
    let state = root.join("launch-state.txt");
    let log = root.join("launch-command.log");
    if !entry_exists(&state)? {
        write_record(&state, b"loaded\n", 0o600)?;
    }
    let script = r#"
set -eu
ACTION=$1
STATE=$2
LOG=$3
CURRENT=$(cat "$STATE")
case "$ACTION" in
  bootout)
    if [ "$CURRENT" = absent ]; then
      printf '%s\n' 'Could not find service "sandbox" in domain for user' >&2
      exit 3
    fi
    printf 'absent\n' > "$STATE"
    ;;
  bootstrap)
    if [ "$CURRENT" = loaded ]; then
      printf '%s\n' 'service already loaded' >&2
      exit 5
    fi
    printf 'loaded\n' > "$STATE"
    ;;
  malformed)
    printf '%s\n' 'unclassified launch command failure' >&2
    exit 9
    ;;
  *)
    printf '%s\n' 'unknown adapter action' >&2
    exit 64
    ;;
esac
printf '%s\n' "$ACTION" >> "$LOG"
"#;
    run_command(
        Path::new("/bin/sh"),
        &[
            OsStr::new("-c"),
            OsStr::new(script),
            OsStr::new("opensteamer-sandbox-adapter"),
            OsStr::new(action),
            state.as_os_str(),
            log.as_os_str(),
        ],
        Some(&root),
    )
}

fn sandbox_bootout(root: &Path) -> Result<()> {
    let output = run_sandbox_launch_command(root, "bootout")?;
    if output.status.success() {
        return Ok(());
    }
    let lines: Vec<&str> = output
        .stderr
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    if output.stdout.trim().is_empty()
        && lines
            .iter()
            .any(|line| line.starts_with("Could not find service"))
        && lines
            .iter()
            .all(|line| *line == "Bad request." || line.starts_with("Could not find service"))
    {
        return Ok(());
    }
    Err(ControllerError(format!(
        "sandbox bootout outcome is unclassified: {}",
        output.stderr.trim()
    )))
}

fn sandbox_bootstrap(root: &Path) -> Result<()> {
    run_sandbox_launch_command(root, "bootstrap")?.require_success("sandbox bootstrap")?;
    Ok(())
}

#[derive(Clone, Copy)]
enum RealAdapterOperation {
    CopyAppHold,
    PublishApp,
    CopyPlistHold,
    PublishPlist,
    Bootout,
    Bootstrap,
    Checkpoint,
    Commit,
}

fn recover_real_adapter_transaction(
    root: &Path,
    applications: &Path,
    launch_agents: &Path,
    legacy_app: &Path,
    legacy_plist: &Path,
    journal_path: &Path,
    expected_legacy_app: &[u8],
    expected_legacy_plist: &[u8],
) -> Result<()> {
    let mut journal = Journal::open(journal_path)?;
    let app_destination = applications.join("opensteamer Host.app");
    let plist_destination = launch_agents.join("org.example.opensteamer.worldwide.plist");
    if journal.state.is_committed_family() {
        validate_real_directory(&app_destination)?;
        validate_real_file(&plist_destination, Some(0o600))?;
        sandbox_bootout(root)?;
        journal.transition(State::CommittedRecoveryStarted, &[])?;
        sandbox_bootstrap(root)?;
        journal.transition(State::CommittedRecoveryBootstrapped, &[])?;
        let checkpoint = root.join("online.log");
        let checkpoint_bytes = fs::read(&checkpoint)?;
        if checkpoint_bytes != b"checkpoint-generation=2\n" {
            return Err(ControllerError(
                "committed real-adapter recovery lost durable checkpoint bytes".to_owned(),
            ));
        }
        journal.transition(State::CommittedRecoveryReady, &[])?;
    } else {
        sandbox_bootout(root)?;
        journal.transition(State::RollbackStarted, &[])?;
        for path in [
            app_destination,
            applications.join(".opensteamer-install-hold"),
        ] {
            if entry_exists(&path)? {
                remove_tree(&path)?;
            }
        }
        for path in [
            plist_destination,
            launch_agents.join(".opensteamer-plist-install-hold"),
        ] {
            if entry_exists(&path)? {
                fs::remove_file(&path)?;
                sync_parent(&path)?;
            }
        }
        journal.transition(State::RolledBack, &[])?;
    }
    if fs::read(legacy_app)? != expected_legacy_app
        || fs::read(legacy_plist)? != expected_legacy_plist
    {
        return Err(ControllerError(
            "real-adapter recovery changed protected legacy bytes".to_owned(),
        ));
    }
    let metadata = fs::symlink_metadata(journal_path)?;
    validate_owned_regular(journal_path, &metadata, 0o600)?;
    let journal_bytes = fs::read(journal_path)?;
    if !journal_bytes.starts_with(format!("{JOURNAL_VERSION}\n").as_bytes())
        || !journal_bytes.windows(6).any(|window| window == b"STATE ")
    {
        return Err(ControllerError(
            "real-adapter journal bytes are not durable state records".to_owned(),
        ));
    }
    Ok(())
}

fn run_real_adapter_fault_case(target_boundary: usize) -> Result<bool> {
    let directory = TemporaryDirectory::create("real-adapter")?;
    let root = assert_disposable_adapter_root(&directory.path)?;
    let applications = root.join("Applications");
    let launch_agents = root.join("LaunchAgents");
    fs::create_dir(&applications)?;
    fs::create_dir(&launch_agents)?;
    fs::set_permissions(&applications, Permissions::from_mode(0o700))?;
    fs::set_permissions(&launch_agents, Permissions::from_mode(0o700))?;
    let staged_app = root.join("staged-app");
    fs::create_dir(&staged_app)?;
    write_record(&staged_app.join("CaptureServer"), b"new-app-bytes\n", 0o700)?;
    let staged_plist = root.join("staged.plist");
    write_record(&staged_plist, b"new-plist-bytes\n", 0o600)?;
    let legacy_app = root.join("protected-legacy-app.bin");
    let legacy_plist = root.join("protected-legacy.plist");
    let expected_legacy_app = b"legacy-app-exact-bytes\n";
    let expected_legacy_plist = b"legacy-plist-exact-bytes\n";
    write_record(&legacy_app, expected_legacy_app, 0o700)?;
    write_record(&legacy_plist, expected_legacy_plist, 0o600)?;
    let journal_path = root.join("journal.log");
    let mut journal = Journal::create(&journal_path)?;
    let applications_pin =
        PinnedDirectory::open(&applications, Some(effective_uid()), Some(0o700))?;
    let launch_agents_pin =
        PinnedDirectory::open(&launch_agents, Some(effective_uid()), Some(0o700))?;
    let operations = [
        RealAdapterOperation::CopyAppHold,
        RealAdapterOperation::PublishApp,
        RealAdapterOperation::CopyPlistHold,
        RealAdapterOperation::PublishPlist,
        RealAdapterOperation::Bootout,
        RealAdapterOperation::Bootstrap,
        RealAdapterOperation::Checkpoint,
        RealAdapterOperation::Commit,
    ];
    let mut boundary = 0usize;
    let mut interrupted = false;
    for operation in operations {
        if boundary == target_boundary {
            interrupted = true;
            break;
        }
        boundary += 1;
        match operation {
            RealAdapterOperation::CopyAppHold => {
                let hold = applications.join(".opensteamer-install-hold");
                fs::create_dir(&hold)?;
                copy_exact_file(
                    &staged_app.join("CaptureServer"),
                    &hold.join("CaptureServer"),
                    0o700,
                )?;
                sync_directory(&hold)?;
            }
            RealAdapterOperation::PublishApp => publish_directory_hold(
                &applications_pin,
                ".opensteamer-install-hold",
                "opensteamer Host.app",
            )?,
            RealAdapterOperation::CopyPlistHold => copy_exact_file(
                &staged_plist,
                &launch_agents.join(".opensteamer-plist-install-hold"),
                0o600,
            )?,
            RealAdapterOperation::PublishPlist => publish_regular_file_hold(
                &launch_agents_pin,
                ".opensteamer-plist-install-hold",
                "org.example.opensteamer.worldwide.plist",
                0o600,
            )?,
            RealAdapterOperation::Bootout => sandbox_bootout(&root)?,
            RealAdapterOperation::Bootstrap => sandbox_bootstrap(&root)?,
            RealAdapterOperation::Checkpoint => {
                write_record(
                    &root.join("online.log"),
                    b"checkpoint-generation=2\n",
                    0o600,
                )?;
            }
            RealAdapterOperation::Commit => {}
        }
        if boundary == target_boundary {
            interrupted = true;
            break;
        }
        boundary += 1;
        let state = match operation {
            RealAdapterOperation::CopyAppHold => Some(State::NewStaged),
            RealAdapterOperation::PublishPlist => Some(State::NewInstalled),
            RealAdapterOperation::Bootstrap => Some(State::NewBootstrapped),
            RealAdapterOperation::Checkpoint => Some(State::NewPidObserved),
            RealAdapterOperation::Commit => Some(State::Committed),
            RealAdapterOperation::PublishApp
            | RealAdapterOperation::CopyPlistHold
            | RealAdapterOperation::Bootout => None,
        };
        if let Some(state) = state {
            let fields: Vec<(&str, String)> =
                if state == State::NewPidObserved || state == State::Committed {
                    vec![
                        ("pid", "4242".to_owned()),
                        ("runs", "2".to_owned()),
                        ("process_start", "sandbox-generation-2".to_owned()),
                        ("nonce", "2".repeat(64)),
                        ("log_offset", "24".to_owned()),
                        ("log_device", "7".to_owned()),
                        ("log_inode", "11".to_owned()),
                    ]
                } else {
                    Vec::new()
                };
            journal.transition(state, &fields)?;
        }
        if boundary == target_boundary {
            interrupted = true;
            break;
        }
        boundary += 1;
    }
    drop(journal);
    recover_real_adapter_transaction(
        &root,
        &applications,
        &launch_agents,
        &legacy_app,
        &legacy_plist,
        &journal_path,
        expected_legacy_app,
        expected_legacy_plist,
    )?;
    Ok(interrupted)
}

fn self_test_real_adapter() -> Result<()> {
    for protected in [
        Path::new("/"),
        Path::new("/Applications"),
        Path::new("/Users/ahmed/Library/LaunchAgents"),
        Path::new(LOCK_DIRECTORY),
    ] {
        if assert_disposable_adapter_root(protected).is_ok() {
            return Err(ControllerError(format!(
                "real adapter accepted protected root {}",
                protected.display()
            )));
        }
    }

    let mut target = 0usize;
    loop {
        if !run_real_adapter_fault_case(target)? {
            break;
        }
        target += 1;
        if target > 64 {
            return Err(ControllerError(
                "real-adapter fault matrix exceeded its bound".to_owned(),
            ));
        }
    }
    if target < 20 {
        return Err(ControllerError(format!(
            "real-adapter fault matrix covered only {target} boundaries"
        )));
    }

    let collision = TemporaryDirectory::create("real-adapter")?;
    let root = assert_disposable_adapter_root(&collision.path)?;
    let applications = root.join("Applications");
    fs::create_dir(&applications)?;
    fs::set_permissions(&applications, Permissions::from_mode(0o700))?;
    let hold = applications.join("hold");
    fs::create_dir(&hold)?;
    write_record(&hold.join("payload"), b"ours", 0o600)?;
    let destination = applications.join("destination");
    fs::create_dir(&destination)?;
    write_record(&destination.join("payload"), b"foreign", 0o600)?;
    let pinned = PinnedDirectory::open(&applications, Some(effective_uid()), Some(0o700))?;
    if publish_directory_hold(&pinned, "hold", "destination").is_ok()
        || fs::read(destination.join("payload"))? != b"foreign"
    {
        return Err(ControllerError(
            "real-adapter publication did not preserve a foreign collision".to_owned(),
        ));
    }
    let displaced = root.join("Applications.displaced");
    fs::rename(&applications, &displaced)?;
    fs::create_dir(&applications)?;
    fs::set_permissions(&applications, Permissions::from_mode(0o700))?;
    if pinned.revalidate().is_ok() {
        return Err(ControllerError(
            "real-adapter pinned parent accepted inode substitution".to_owned(),
        ));
    }
    fs::remove_dir(&applications)?;
    fs::rename(&displaced, &applications)?;

    let malformed = run_sandbox_launch_command(&root, "malformed")?;
    if malformed.status.success() || sandbox_bootout(&root).is_err() {
        return Err(ControllerError(
            "real command adapter failed launch outcome classification".to_owned(),
        ));
    }
    Ok(())
}

fn self_test_command_deadlines() -> Result<()> {
    let sanitized = run_command(Path::new("/usr/bin/env"), &[], None)?
        .require_success("sanitized child environment")?;
    let actual_environment: BTreeSet<String> = sanitized.lines().map(str::to_owned).collect();
    let expected_environment: BTreeSet<String> = [
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME=/Users/ahmed",
        "TMPDIR=/var/tmp",
        "LANG=C",
        "LC_ALL=C",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    if actual_environment != expected_environment {
        return Err(ControllerError(format!(
            "ordinary child environment was not fully sanitized: {actual_environment:?}"
        )));
    }

    let hanging_script = "trap '' TERM\n( trap '' TERM; while :; do /bin/sleep 1; done ) &\nwhile :; do /bin/sleep 1; done\n";
    for label in [
        "forward-launchctl",
        "rollback-ps",
        "committed-recovery-lsof",
    ] {
        let started = Instant::now();
        let result = run_command_until(
            Path::new("/bin/sh"),
            &[
                OsStr::new("-c"),
                OsStr::new(hanging_script),
                OsStr::new(label),
            ],
            None,
            deadline_after(Duration::from_millis(250))?,
        );
        if result.is_ok() {
            return Err(ControllerError(format!(
                "{label} hung-command deadline false-passed"
            )));
        }
        if started.elapsed() > Duration::from_secs(2) {
            return Err(ControllerError(format!(
                "{label} termination, nonblocking output collection, and reap exceeded the end-to-end bound"
            )));
        }
    }

    let mut environment = BTreeMap::new();
    environment.insert("PATH".to_owned(), "/usr/bin:/bin".to_owned());
    let owned_started = Instant::now();
    let owned_result = run_command_owned_until(
        Path::new("/bin/sh"),
        &[
            "-c".to_owned(),
            hanging_script.to_owned(),
            "owned-adapter".to_owned(),
        ],
        None,
        &environment,
        deadline_after(Duration::from_millis(250))?,
    );
    if owned_result.is_ok() || owned_started.elapsed() > Duration::from_secs(2) {
        return Err(ControllerError(
            "owned-environment command deadline failed to terminate and reap a resistant child tree"
                .to_owned(),
        ));
    }

    // A successful direct child may leave a short-lived descendant holding inherited stdout and
    // stderr descriptors. Output collection must return with the reaped direct child rather than
    // block waiting for descendant EOF.
    let retained_pipe_started = Instant::now();
    let retained_pipe = run_command_until(
        Path::new("/bin/sh"),
        &[
            OsStr::new("-c"),
            OsStr::new("( /bin/sleep 0.4 ) & printf retained-pipe\\n; exit 0"),
        ],
        None,
        deadline_after(Duration::from_secs(3))?,
    )?;
    if !retained_pipe.status.success()
        || !retained_pipe.stdout.contains("retained-pipe")
        || retained_pipe_started.elapsed() > Duration::from_secs(1)
    {
        return Err(ControllerError(
            "nonblocking command output collection waited for an inherited-pipe descendant"
                .to_owned(),
        ));
    }

    // Model the documented rollback-readiness scope: an initial static verification and a late
    // acceptance-boundary recheck share one deadline. The second command receives only the
    // remainder; it may not manufacture a fresh default sixty-second budget.
    let readiness_started = Instant::now();
    let readiness_deadline = deadline_after(Duration::from_millis(350))?;
    run_command_until(
        Path::new("/bin/sh"),
        &[OsStr::new("-c"), OsStr::new("/bin/sleep 0.20")],
        None,
        readiness_deadline,
    )?
    .require_success("readiness initial static verifier")?;
    let late_recheck = run_command_until(
        Path::new("/bin/sh"),
        &[OsStr::new("-c"), OsStr::new(hanging_script)],
        None,
        readiness_deadline,
    );
    if late_recheck.is_ok() || readiness_started.elapsed() > Duration::from_secs(2) {
        return Err(ControllerError(
            "late rollback-readiness acceptance recheck escaped the original monotonic deadline"
                .to_owned(),
        ));
    }

    let static_started = Instant::now();
    let static_result = run_command_until(
        Path::new("/bin/sh"),
        &[OsStr::new("-c"), OsStr::new(hanging_script)],
        None,
        deadline_after(Duration::from_millis(250))?,
    );
    if static_result.is_ok() || static_started.elapsed() > Duration::from_secs(2) {
        return Err(ControllerError(
            "hung rollback static verifier escaped the advertised readiness deadline".to_owned(),
        ));
    }

    // Model a wall clock moving backward while the monotonic clock advances. The acceptance
    // decision is intentionally derived only from Instant.
    let monotonic_start = Instant::now();
    let wall_before = SystemTime::now();
    thread::sleep(Duration::from_millis(5));
    let wall_after = wall_before
        .checked_sub(Duration::from_secs(3600))
        .ok_or_else(|| {
            ControllerError("could not construct backward wall-clock sample".to_owned())
        })?;
    if wall_after >= wall_before || monotonic_start.elapsed().is_zero() {
        return Err(ControllerError(
            "monotonic deadline regression did not distinguish a backward wall clock".to_owned(),
        ));
    }
    Ok(())
}

fn self_test_directory_modes() -> Result<()> {
    let applications = Path::new(APPLICATIONS_DIRECTORY);
    if !directory_write_policy_allows(
        applications,
        APPLICATIONS_UID,
        APPLICATIONS_GID,
        APPLICATIONS_MODE,
        Some(APPLICATIONS_UID),
        Some(APPLICATIONS_GID),
        Some(APPLICATIONS_MODE),
    ) {
        return Err(ControllerError(
            "exact root:admin /Applications 0775 policy was rejected".to_owned(),
        ));
    }
    for (path, uid, gid, mode, expected_uid, expected_gid, expected_mode) in [
        (
            applications,
            APPLICATIONS_UID,
            APPLICATIONS_GID,
            0o777,
            Some(APPLICATIONS_UID),
            Some(APPLICATIONS_GID),
            Some(0o777),
        ),
        (
            applications,
            APPLICATIONS_UID + 1,
            APPLICATIONS_GID,
            APPLICATIONS_MODE,
            Some(APPLICATIONS_UID + 1),
            Some(APPLICATIONS_GID),
            Some(APPLICATIONS_MODE),
        ),
        (
            applications,
            APPLICATIONS_UID,
            20,
            APPLICATIONS_MODE,
            Some(APPLICATIONS_UID),
            Some(20),
            Some(APPLICATIONS_MODE),
        ),
        (
            applications,
            APPLICATIONS_UID,
            APPLICATIONS_GID,
            APPLICATIONS_MODE,
            Some(APPLICATIONS_UID),
            Some(APPLICATIONS_GID),
            Some(0o755),
        ),
        (
            applications,
            APPLICATIONS_UID,
            APPLICATIONS_GID,
            APPLICATIONS_MODE,
            None,
            None,
            None,
        ),
        (
            Path::new("/tmp/Applications"),
            APPLICATIONS_UID,
            APPLICATIONS_GID,
            APPLICATIONS_MODE,
            Some(APPLICATIONS_UID),
            Some(APPLICATIONS_GID),
            Some(APPLICATIONS_MODE),
        ),
    ] {
        if directory_write_policy_allows(
            path,
            uid,
            gid,
            mode,
            expected_uid,
            expected_gid,
            expected_mode,
        ) {
            return Err(ControllerError(format!(
                "directory write policy accepted unsafe case {} uid={uid} gid={gid} mode={mode:04o}",
                path.display()
            )));
        }
    }

    let directory = TemporaryDirectory::create("directory-modes")?;
    fs::set_permissions(&directory.path, Permissions::from_mode(0o777))?;
    if validate_repository_root(&directory.path).is_ok() {
        return Err(ControllerError(
            "repository-root mode gate accepted a group/world-writable directory".to_owned(),
        ));
    }
    if PinnedDirectory::open(&directory.path, Some(effective_uid()), None).is_ok() {
        return Err(ControllerError(
            "pinned-directory mode gate accepted a group/world-writable directory".to_owned(),
        ));
    }

    fs::set_permissions(&directory.path, Permissions::from_mode(0o700))?;
    let policy_pin = PinnedDirectory::open(&directory.path, Some(effective_uid()), Some(0o700))?;
    policy_pin.prove_write_execute_and_sync()?;
    fs::set_permissions(&directory.path, Permissions::from_mode(0o750))?;
    if policy_pin.revalidate().is_ok() {
        return Err(ControllerError(
            "pinned-directory revalidation forgot its original owner/mode policy".to_owned(),
        ));
    }
    fs::set_permissions(&directory.path, Permissions::from_mode(0o700))?;
    let child = directory.path.join("writable-parent");
    fs::create_dir(&child)?;
    fs::set_permissions(&child, Permissions::from_mode(0o777))?;
    if PinnedDirectory::open(&child, Some(effective_uid()), None).is_ok() {
        return Err(ControllerError(
            "transaction-parent mode gate accepted a group/world-writable directory".to_owned(),
        ));
    }

    let collision_root = TemporaryDirectory::create("hidden-collision")?;
    let absent = collision_root.path.join("absent");
    require_paths_absent(std::slice::from_ref(&absent))?;
    let collision = collision_root.path.join("foreign");
    write_record(&collision, b"foreign", 0o600)?;
    if require_paths_absent(std::slice::from_ref(&collision)).is_ok()
        || fs::read(&collision)? != b"foreign"
    {
        return Err(ControllerError(
            "hidden-path collision gate did not preserve foreign data".to_owned(),
        ));
    }

    let reserve_root = TemporaryDirectory::create("rollback-reserve")?;
    let records_path = reserve_root.path.join("records");
    fs::create_dir(&records_path)?;
    fs::set_permissions(&records_path, Permissions::from_mode(0o700))?;
    let records = PinnedDirectory::open(&records_path, Some(effective_uid()), Some(0o700))?;
    let reserve = RollbackReserve::create(&records)?;
    reserve.revalidate_full(&records)?;
    release_rollback_reserve_at(
        &records_path,
        reserve.device,
        reserve.inode,
        ROLLBACK_RESERVE_BYTES,
    )?;
    release_rollback_reserve_at(
        &records_path,
        reserve.device,
        reserve.inode,
        ROLLBACK_RESERVE_BYTES,
    )?;
    let released = reserve.file.metadata()?;
    if released.dev() != reserve.device || released.ino() != reserve.inode || released.len() != 0 {
        return Err(ControllerError(
            "rollback reserve release was not idempotent on the same evidence inode".to_owned(),
        ));
    }
    let unjournaled_path = reserve_root.path.join("unjournaled-records");
    fs::create_dir(&unjournaled_path)?;
    fs::set_permissions(&unjournaled_path, Permissions::from_mode(0o700))?;
    let unjournaled_records =
        PinnedDirectory::open(&unjournaled_path, Some(effective_uid()), Some(0o700))?;
    let unjournaled = RollbackReserve::create(&unjournaled_records)?;
    release_unjournaled_rollback_reserve_at(&unjournaled_path)?;
    let released_unjournaled = unjournaled.file.metadata()?;
    if released_unjournaled.dev() != unjournaled.device
        || released_unjournaled.ino() != unjournaled.inode
        || released_unjournaled.len() != 0
    {
        return Err(ControllerError(
            "pre-journal rollback reserve recovery changed the evidence inode".to_owned(),
        ));
    }
    Ok(())
}

fn run_self_test(case: &str) -> Result<()> {
    match case {
        "all" => {
            self_test_crash()?;
            self_test_fault_matrix()?;
            self_test_rollback()?;
            self_test_readiness()?;
            self_test_concurrency()?;
            self_test_journal()?;
            self_test_publication()?;
            self_test_disable()?;
            self_test_committed()?;
            self_test_active_pointer()?;
            self_test_side_effects()?;
            self_test_parsers()?;
            self_test_generation_race()?;
            self_test_command_deadlines()?;
            self_test_directory_modes()?;
            self_test_real_adapter()?;
        }
        "crash" => self_test_crash()?,
        "faults" => self_test_fault_matrix()?,
        "rollback" => self_test_rollback()?,
        "readiness" => self_test_readiness()?,
        "concurrency" => self_test_concurrency()?,
        "journal" => self_test_journal()?,
        "publication" => self_test_publication()?,
        "disable" => self_test_disable()?,
        "committed" => self_test_committed()?,
        "active-pointer" => self_test_active_pointer()?,
        "side-effects" => self_test_side_effects()?,
        "parsers" => self_test_parsers()?,
        "generation-race" => self_test_generation_race()?,
        "deadlines" => self_test_command_deadlines()?,
        "modes" => self_test_directory_modes()?,
        "real-adapter" => self_test_real_adapter()?,
        _ => return Err(ControllerError(format!("unknown self-test case '{case}'"))),
    }
    println!("SELF_TEST_OK {case}");
    Ok(())
}

fn self_test_crash() -> Result<()> {
    let mut target = 0usize;
    loop {
        let (interrupted, world, journal, _directory) =
            run_forward_with_boundary_fault(InjectedFault::Interruption, target)?;
        if !interrupted {
            break;
        }
        let path = journal.path.clone();
        drop(journal);
        let mut reopened = FakeJournal::open(&path)?;
        let recovered = recover_fake_transaction(world, &mut reopened)?;
        if reopened.last_state.is_committed_family() {
            recovered.assert_committed_current_generation()?;
        } else {
            recovered.assert_legacy_restored()?;
        }
        target += 1;
        if target > 256 {
            return Err(ControllerError(
                "forward boundary test exceeded its bound".to_owned(),
            ));
        }
    }
    if target < 40 {
        return Err(ControllerError(format!(
            "forward crash matrix covered only {target} boundaries"
        )));
    }
    Ok(())
}

fn self_test_fault_matrix() -> Result<()> {
    let faults = [
        InjectedFault::Permission,
        InjectedFault::Storage,
        InjectedFault::Command,
        InjectedFault::MalformedOutput,
    ];
    for fault in faults {
        let mut target = 0usize;
        loop {
            let (interrupted, world, journal, _directory) =
                run_forward_with_boundary_fault(fault, target)?;
            if !interrupted {
                break;
            }
            let path = journal.path.clone();
            drop(journal);
            let mut reopened = FakeJournal::open(&path)?;
            let recovered = recover_fake_transaction(world, &mut reopened)?;
            if reopened.last_state.is_committed_family() {
                recovered.assert_committed_current_generation()?;
            } else {
                recovered.assert_legacy_restored()?;
            }
            target += 1;
            if target > 256 {
                return Err(ControllerError(
                    "fault boundary matrix exceeded its bound".to_owned(),
                ));
            }
        }
        if target < 40 {
            return Err(ControllerError(format!(
                "{fault:?} matrix covered only {target} boundaries"
            )));
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RollbackReadinessSample {
    Pending,
    Ready,
    WrongProcess,
    NewHostReappeared,
}

fn evaluate_bounded_rollback_readiness(
    samples: &[RollbackReadinessSample],
    maximum_checks: usize,
) -> Result<usize> {
    for (index, sample) in samples.iter().take(maximum_checks).enumerate() {
        match sample {
            RollbackReadinessSample::Pending => {}
            RollbackReadinessSample::Ready => return Ok(index + 1),
            RollbackReadinessSample::WrongProcess => {
                return Err(ControllerError(
                    "rollback readiness observed the wrong legacy process".to_owned(),
                ))
            }
            RollbackReadinessSample::NewHostReappeared => {
                return Err(ControllerError(
                    "new host reappeared during rollback readiness".to_owned(),
                ))
            }
        }
    }
    Err(ControllerError(
        "rollback readiness exhausted its bounded checks".to_owned(),
    ))
}

fn self_test_rollback() -> Result<()> {
    let mut target = 0usize;
    loop {
        let (world, mut journal, _forward_directory) = prepare_failed_forward()?;
        let crossed = journal.saw_legacy_stopped || !world.legacy_running;
        let mut backend = FakeBackend::from_world(world);
        let mut boundary = 0usize;
        let saw_legacy_disabled = journal.saw_legacy_disabled;
        let result = drive_rollback(
            &mut backend,
            &mut journal,
            crossed,
            saw_legacy_disabled,
            |_, operation, phase| {
                if boundary == target {
                    return Err(injected_failure(
                        InjectedFault::Interruption,
                        operation,
                        phase,
                    ));
                }
                boundary += 1;
                Ok(())
            },
        );
        if result.is_ok() {
            backend.world.assert_legacy_restored()?;
            break;
        }
        let path = journal.path.clone();
        let interrupted_world = backend.world;
        drop(journal);
        let mut reopened = FakeJournal::open(&path)?;
        let recovered = recover_fake_transaction(interrupted_world, &mut reopened)?;
        recovered.assert_legacy_restored()?;
        target += 1;
        if target > 128 {
            return Err(ControllerError(
                "rollback interruption matrix exceeded its bound".to_owned(),
            ));
        }
    }
    if target < 15 {
        return Err(ControllerError(format!(
            "rollback matrix covered only {target} boundaries"
        )));
    }
    let delayed = evaluate_bounded_rollback_readiness(
        &[
            RollbackReadinessSample::Pending,
            RollbackReadinessSample::Pending,
            RollbackReadinessSample::Ready,
        ],
        4,
    )?;
    if delayed != 3 {
        return Err(ControllerError(
            "delayed legacy readiness completed at the wrong sample".to_owned(),
        ));
    }
    if evaluate_bounded_rollback_readiness(&[RollbackReadinessSample::Pending; 4], 4).is_ok() {
        return Err(ControllerError(
            "rollback readiness timeout false-passed".to_owned(),
        ));
    }
    if evaluate_bounded_rollback_readiness(&[RollbackReadinessSample::WrongProcess], 4).is_ok() {
        return Err(ControllerError(
            "wrong legacy process false-passed rollback readiness".to_owned(),
        ));
    }
    if evaluate_bounded_rollback_readiness(&[RollbackReadinessSample::NewHostReappeared], 4).is_ok()
    {
        return Err(ControllerError(
            "new-host reappearance false-passed rollback readiness".to_owned(),
        ));
    }
    Ok(())
}

fn self_test_readiness() -> Result<()> {
    let directory = TemporaryDirectory::create("readiness")?;
    let path = directory.path.join("journal.log");
    let mut journal = FakeJournal::create(&path)?;
    let mut backend = FakeBackend::baseline();
    backend.reject_marker = true;
    if drive_forward(&mut backend, &mut journal, |_, _, _, _, _| Ok(())).is_ok() {
        return Err(ControllerError("readiness failure false-passed".to_owned()));
    }
    let recovered = recover_fake_transaction(backend.world, &mut journal)?;
    recovered.assert_legacy_restored()
}

fn self_test_concurrency() -> Result<()> {
    let directory = TemporaryDirectory::create("concurrency")?;
    let pinned = PinnedDirectory::open(&directory.path, Some(effective_uid()), Some(0o700))?;
    let first = pinned.create_new_regular("transaction.lock", 0o600)?;
    // SAFETY: flock is called with a valid descriptor.
    if unsafe { flock(first.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(ControllerError(
            "could not acquire first self-test transaction lock".to_owned(),
        ));
    }
    let second = pinned
        .open_existing_regular("transaction.lock", true)?
        .ok_or_else(|| ControllerError("self-test lock disappeared".to_owned()))?;
    // SAFETY: flock is called with a valid descriptor.
    if unsafe { flock(second.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        // SAFETY: release the unexpected lock.
        let _ = unsafe { flock(second.as_raw_fd(), LOCK_UN) };
        return Err(ControllerError(
            "second concurrent transaction lock unexpectedly succeeded".to_owned(),
        ));
    }
    // SAFETY: release the first lock.
    if unsafe { flock(first.as_raw_fd(), LOCK_UN) } != 0 {
        return Err(ControllerError(
            "could not release self-test transaction lock".to_owned(),
        ));
    }
    Ok(())
}

fn self_test_journal() -> Result<()> {
    let directory = TemporaryDirectory::create("journal")?;
    let path = directory.path.join("journal.log");
    let mut journal = FakeJournal::create(&path)?;
    journal.record(State::LegacyDisabled, &[])?;
    journal.append_partial(b"STATE LEGACY_STOP")?;
    drop(journal);
    let reopened = FakeJournal::open(&path)?;
    if reopened.last_state != State::LegacyDisabled {
        return Err(ControllerError(
            "journal truncation recovery accepted a partial record".to_owned(),
        ));
    }

    let real_path = directory.path.join("real-journal.log");
    let mut real = Journal::create(&real_path)?;
    real.transition(
        State::NewPidObserved,
        &[("pid", "4242".to_owned()), ("log_offset", "100".to_owned())],
    )?;
    drop(real);
    let mut append = OpenOptions::new()
        .append(true)
        .custom_flags(libc_o_nofollow() | O_NONBLOCK_VALUE)
        .open(&real_path)?;
    append.write_all(b"STATE COMMIT")?;
    append.sync_all()?;
    drop(append);
    let reopened_real = Journal::open(&real_path)?;
    if reopened_real.state != State::NewPidObserved
        || reopened_real.required_field("pid")? != "4242"
    {
        return Err(ControllerError(
            "real journal did not recover its last complete durable record".to_owned(),
        ));
    }

    let prior_evidence = Path::new(PRIOR_EVIDENCE_PATH);
    validate_prior_v9_prestop_records(prior_evidence, PRIOR_PRESTOP_JOURNAL, PRIOR_PRESTOP_RESULT)?;
    let mut mutated_journal = PRIOR_PRESTOP_JOURNAL.to_vec();
    mutated_journal.extend_from_slice(b"STATE LEGACY_DISABLED\n");
    let invalid_prior_records = [
        (
            Path::new(
                "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v8-1-2",
            ),
            PRIOR_PRESTOP_JOURNAL,
            PRIOR_PRESTOP_RESULT,
        ),
        (
            Path::new(
                "/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v9-bad-2",
            ),
            PRIOR_PRESTOP_JOURNAL,
            PRIOR_PRESTOP_RESULT,
        ),
        (
            prior_evidence,
            mutated_journal.as_slice(),
            PRIOR_PRESTOP_RESULT,
        ),
        (
            prior_evidence,
            PRIOR_PRESTOP_JOURNAL,
            b"result=rolled-back\n".as_slice(),
        ),
    ];
    for (evidence, prior_journal, prior_result) in invalid_prior_records {
        if validate_prior_v9_prestop_records(evidence, prior_journal, prior_result).is_ok() {
            return Err(ControllerError(
                "prior v9 retry contract accepted mutated evidence".to_owned(),
            ));
        }
    }

    validate_prior_v10_rolledback_records(
        Path::new(PRIOR_V10_EVIDENCE_PATH),
        PRIOR_V10_FINAL_JOURNAL,
        PRIOR_V10_FINAL_RESULT,
        PRIOR_V10_PROVENANCE,
    )?;
    let prior_v10_journal_path = directory.path.join("prior-v10-journal.log");
    let prior_v10_result_path = directory.path.join("prior-v10-result.txt");
    let prior_v10_provenance_path = directory.path.join("prior-v10-provenance.txt");
    write_record(&prior_v10_journal_path, PRIOR_V10_FINAL_JOURNAL, 0o600)?;
    write_record(&prior_v10_result_path, PRIOR_V10_FINAL_RESULT, 0o600)?;
    write_record(&prior_v10_provenance_path, PRIOR_V10_PROVENANCE, 0o600)?;
    if sha256_file(&prior_v10_journal_path)? != PRIOR_V10_FINAL_JOURNAL_SHA256
        || sha256_file(&prior_v10_result_path)? != PRIOR_V10_FINAL_RESULT_SHA256
        || sha256_file(&prior_v10_provenance_path)? != PRIOR_V10_PROVENANCE_SHA256
    {
        return Err(ControllerError(
            "embedded prior v10 retry records do not match their reviewed hashes".to_owned(),
        ));
    }
    let mut mutated_journal = PRIOR_V10_FINAL_JOURNAL.to_vec();
    mutated_journal.extend_from_slice(b"STATE LEGACY_DISABLED\n");
    let mut mutated_result = PRIOR_V10_FINAL_RESULT.to_vec();
    mutated_result.extend_from_slice(b"unexpected=true\n");
    let mut mutated_provenance = PRIOR_V10_PROVENANCE.to_vec();
    mutated_provenance.extend_from_slice(b"unexpected=true\n");
    for (evidence, journal, result, provenance) in [
        (
            Path::new(PRIOR_EVIDENCE_PATH),
            PRIOR_V10_FINAL_JOURNAL,
            PRIOR_V10_FINAL_RESULT,
            PRIOR_V10_PROVENANCE,
        ),
        (
            Path::new(PRIOR_V10_EVIDENCE_PATH),
            mutated_journal.as_slice(),
            PRIOR_V10_FINAL_RESULT,
            PRIOR_V10_PROVENANCE,
        ),
        (
            Path::new(PRIOR_V10_EVIDENCE_PATH),
            PRIOR_V10_FINAL_JOURNAL,
            mutated_result.as_slice(),
            PRIOR_V10_PROVENANCE,
        ),
        (
            Path::new(PRIOR_V10_EVIDENCE_PATH),
            PRIOR_V10_FINAL_JOURNAL,
            PRIOR_V10_FINAL_RESULT,
            mutated_provenance.as_slice(),
        ),
    ] {
        if validate_prior_v10_rolledback_records(evidence, journal, result, provenance).is_ok() {
            return Err(ControllerError(
                "prior v10 retry contract accepted mutated evidence".to_owned(),
            ));
        }
    }
    Ok(())
}

fn self_test_publication() -> Result<()> {
    let directory = TemporaryDirectory::create("publication")?;
    let pinned = PinnedDirectory::open(&directory.path, Some(effective_uid()), Some(0o700))?;
    let mut stage = pinned.create_new_regular("stage", 0o600)?;
    stage.write_all(b"new")?;
    stage.sync_all()?;
    let mut attacker = pinned.create_new_regular("destination", 0o600)?;
    attacker.write_all(b"attacker")?;
    attacker.sync_all()?;
    if pinned.rename_exclusive("stage", "destination").is_ok() {
        return Err(ControllerError(
            "exclusive publication overwrote a concurrent destination".to_owned(),
        ));
    }
    let mut destination = pinned
        .open_existing_regular("destination", false)?
        .ok_or_else(|| ControllerError("publication destination disappeared".to_owned()))?;
    let mut bytes = Vec::new();
    destination.read_to_end(&mut bytes)?;
    if bytes != b"attacker" {
        return Err(ControllerError(
            "exclusive publication mutated the concurrent destination".to_owned(),
        ));
    }

    let displaced = directory.path.with_extension("displaced");
    fs::rename(&directory.path, &displaced)?;
    fs::create_dir(&directory.path)?;
    fs::set_permissions(&directory.path, Permissions::from_mode(0o700))?;
    if pinned.revalidate().is_ok() {
        return Err(ControllerError(
            "pinned directory accepted pathname replacement".to_owned(),
        ));
    }
    fs::remove_dir(&directory.path)?;
    fs::rename(&displaced, &directory.path)?;
    Ok(())
}

fn self_test_disable() -> Result<()> {
    let directory = TemporaryDirectory::create("disable")?;
    let path = directory.path.join("journal.log");
    let mut journal = FakeJournal::create(&path)?;
    journal.record(State::LegacyDisabled, &[])?;
    let mut world = FakeWorld::baseline();
    world.legacy_disabled = true;
    let mut backend = FakeBackend::from_world(world);
    drive_rollback(&mut backend, &mut journal, false, true, |_, _, _| Ok(()))?;
    backend.world.assert_legacy_restored()
}

fn committed_fake_fixture() -> Result<(FakeBackend, FakeJournal, TemporaryDirectory)> {
    let directory = TemporaryDirectory::create("committed-fixture")?;
    let path = directory.path.join("journal.log");
    let mut journal = FakeJournal::create(&path)?;
    let mut backend = FakeBackend::baseline();
    drive_forward(&mut backend, &mut journal, |_, _, _, _, _| Ok(()))?;
    if journal.last_state != State::Committed {
        return Err(ControllerError(
            "committed fixture did not durably record COMMITTED".to_owned(),
        ));
    }
    backend.world.assert_committed_current_generation()?;
    Ok((backend, journal, directory))
}

fn self_test_committed() -> Result<()> {
    let (mut backend, mut journal, _directory) = committed_fake_fixture()?;
    let historical_pid = backend
        .world
        .current_pid
        .ok_or_else(|| ControllerError("committed fixture has no historical PID".to_owned()))?;

    // Simulate a legitimate KeepAlive/login/reboot generation after durable COMMIT while the
    // permanent active tombstone remains. Recovery must not bind to the old PID or accept the old
    // marker generation.
    backend.world.generation += 1;
    backend.world.current_pid = Some(4_800 + backend.world.generation as u32);
    backend.world.committed_pid = Some(historical_pid);
    backend.world.marker_generation = Some(backend.world.generation - 1);
    backend.world.stable_generation = Some(backend.world.generation - 1);
    backend.world.recovery_in_progress = true;
    backend.world.new_running = true;
    backend.world.lock_owner = Some(FakeLockOwner::New);
    backend.historical_pid = historical_pid.to_string();

    drive_committed_recovery(&mut backend, &mut journal, |_, _, _| Ok(()))?;
    backend.world.evidence_written = true;
    backend.world.assert_committed_current_generation()?;
    let current_pid = backend
        .world
        .current_pid
        .ok_or_else(|| ControllerError("committed recovery has no current PID".to_owned()))?;
    if current_pid == historical_pid {
        return Err(ControllerError(
            "committed recovery incorrectly retained the historical PID".to_owned(),
        ));
    }
    if backend.world.marker_generation != Some(backend.world.generation) {
        return Err(ControllerError(
            "committed recovery accepted a stale marker generation".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Clone)]
struct FakeActivePointerBackend {
    pending: Option<Vec<u8>>,
    active: Option<Vec<u8>>,
    expected: Vec<u8>,
}

impl ActivePointerBackend for FakeActivePointerBackend {
    fn perform_active_pointer(&mut self, operation: ActivePointerOperation) -> Result<()> {
        match operation {
            ActivePointerOperation::CreatePending => {
                if self.pending.is_some() || self.active.is_some() {
                    return Err(ControllerError(
                        "fake active pointer name is occupied".to_owned(),
                    ));
                }
                self.pending = Some(Vec::new());
            }
            ActivePointerOperation::WriteAndSyncPending => {
                let pending = self.pending.as_mut().ok_or_else(|| {
                    ControllerError("fake pending active pointer is absent".to_owned())
                })?;
                *pending = self.expected.clone();
            }
            ActivePointerOperation::PublishPending => {
                if self.active.is_some() {
                    return Err(ControllerError(
                        "fake active pointer publication would overwrite".to_owned(),
                    ));
                }
                self.active = self.pending.take();
            }
            ActivePointerOperation::VerifyPublished => {
                if self.active.as_deref() != Some(self.expected.as_slice()) {
                    return Err(ControllerError(
                        "fake active pointer bytes differ".to_owned(),
                    ));
                }
            }
        }
        Ok(())
    }
}

fn recover_fake_active_pointer(backend: &mut FakeActivePointerBackend) -> Result<()> {
    if let Some(active) = backend.active.as_ref() {
        if active != &backend.expected {
            return Err(ControllerError(
                "fake recovered active pointer bytes differ".to_owned(),
            ));
        }
        if let Some(pending) = backend.pending.as_ref() {
            if pending != active {
                return Err(ControllerError(
                    "fake active and retained pending pointers disagree".to_owned(),
                ));
            }
        }
        return Ok(());
    }
    if let Some(pending) = backend.pending.as_ref() {
        if pending == &backend.expected {
            backend.active = backend.pending.take();
        } else {
            return Err(ControllerError(
                "fake malformed pending pointer retained without mutation".to_owned(),
            ));
        }
    }
    if backend.active.is_none() {
        drive_active_pointer(backend, |_, _, _| Ok(()))?;
    }
    Ok(())
}

fn create_final_active_pointer_fixture(
    label: &str,
) -> Result<(TemporaryDirectory, PinnedDirectory, Vec<u8>)> {
    let directory = TemporaryDirectory::create(label)?;
    let parent = PinnedDirectory::open(&directory.path, Some(effective_uid()), Some(0o700))?;
    let expected = b"/private/fake-evidence\n".to_vec();
    let mut active = parent.create_new_regular(ACTIVE_TRANSACTION_NAME, 0o600)?;
    active.write_all(&expected)?;
    active.sync_all()?;
    parent.ensure_file_at_name(ACTIVE_TRANSACTION_NAME, &active)?;
    parent.file.sync_all()?;
    Ok((directory, parent, expected))
}

fn self_test_final_generation_active_pointer_boundary() -> Result<()> {
    // A generation change before the committed readiness observation must fail while retaining
    // the exact active tombstone.
    let (_pre_directory, pre_parent, pre_expected) =
        create_final_active_pointer_fixture("retained-active-pre-proof")?;
    let pre_generation = std::cell::Cell::new(1u64);
    let pre_result = verify_retained_active_pointer_after_commit(
        &pre_parent,
        &pre_expected,
        || {
            if pre_generation.get() == 1 {
                Ok(())
            } else {
                Err(ControllerError(
                    "injected pre-proof KeepAlive generation replacement".to_owned(),
                ))
            }
        },
        |phase| {
            if phase == RetainedActivePointerPhase::AfterInitialPointerValidation {
                pre_generation.set(2);
            }
            Ok(())
        },
    );
    if pre_result.is_ok()
        || read_pinned_regular(&pre_parent, ACTIVE_TRANSACTION_NAME, 0o600)? != pre_expected
    {
        return Err(ControllerError(
            "pre-proof failure did not retain the exact active tombstone".to_owned(),
        ));
    }

    // A same-UID pathname replacement at the old validation/unlink boundary is detected and
    // preserved because the production path performs no rename or unlink.
    let (_race_directory, race_parent, race_expected) =
        create_final_active_pointer_fixture("retained-active-substitution")?;
    let foreign_bytes = b"/private/foreign-evidence\n";
    let race_hook_ran = std::cell::Cell::new(false);
    let race_result = verify_retained_active_pointer_after_commit(
        &race_parent,
        &race_expected,
        || Ok(()),
        |phase| {
            if phase == RetainedActivePointerPhase::AfterInitialPointerValidation {
                race_hook_ran.set(true);
                fs::remove_file(race_parent.path.join(ACTIVE_TRANSACTION_NAME))?;
                let mut foreign = race_parent.create_new_regular(ACTIVE_TRANSACTION_NAME, 0o600)?;
                foreign.write_all(foreign_bytes)?;
                foreign.sync_all()?;
                race_parent.ensure_file_at_name(ACTIVE_TRANSACTION_NAME, &foreign)?;
                race_parent.file.sync_all()?;
            }
            Ok(())
        },
    );
    if race_result.is_ok() || !race_hook_ran.get() {
        return Err(ControllerError(
            "retained-active substitution race false-passed".to_owned(),
        ));
    }
    if read_pinned_regular(&race_parent, ACTIVE_TRANSACTION_NAME, 0o600)? != foreign_bytes {
        return Err(ControllerError(
            "retained-active substitution race did not preserve foreign bytes".to_owned(),
        ));
    }

    // Every post-proof interruption leaves the exact active tombstone, so a later invocation
    // deterministically re-enters committed recovery with the same retained tombstone.
    for phase_to_interrupt in [
        RetainedActivePointerPhase::AfterCommittedGenerationProof,
        RetainedActivePointerPhase::AfterFinalPointerValidation,
    ] {
        let (_directory, parent, expected) =
            create_final_active_pointer_fixture("retained-active-interruption")?;
        let hook_ran = std::cell::Cell::new(false);
        let result = verify_retained_active_pointer_after_commit(
            &parent,
            &expected,
            || Ok(()),
            |phase| {
                if phase == phase_to_interrupt {
                    hook_ran.set(true);
                    return Err(ControllerError(
                        "injected retained-active interruption".to_owned(),
                    ));
                }
                Ok(())
            },
        );
        if result.is_ok()
            || !hook_ran.get()
            || read_pinned_regular(&parent, ACTIVE_TRANSACTION_NAME, 0o600)? != expected
        {
            return Err(ControllerError(format!(
                "retained-active interruption at {phase_to_interrupt:?} lost recovery authority"
            )));
        }
    }

    // The COMMITTED journal is already the durable commit point. A restart after the readiness
    // proof is therefore ordinary committed lifecycle and does not require another proof or any
    // marker publication.
    let (_ordinary_directory, ordinary_parent, ordinary_expected) =
        create_final_active_pointer_fixture("retained-active-ordinary-postcommit")?;
    let ordinary_generation = std::cell::Cell::new(1u64);
    let ordinary_proof_calls = std::cell::Cell::new(0usize);
    verify_retained_active_pointer_after_commit(
        &ordinary_parent,
        &ordinary_expected,
        || {
            ordinary_proof_calls.set(ordinary_proof_calls.get() + 1);
            if ordinary_generation.get() == 1 {
                Ok(())
            } else {
                Err(ControllerError(
                    "post-proof generation is ordinary committed lifecycle".to_owned(),
                ))
            }
        },
        |phase| {
            if phase == RetainedActivePointerPhase::AfterCommittedGenerationProof {
                ordinary_generation.set(2);
            }
            Ok(())
        },
    )?;
    if ordinary_proof_calls.get() != 1
        || read_pinned_regular(&ordinary_parent, ACTIVE_TRANSACTION_NAME, 0o600)?
            != ordinary_expected
    {
        return Err(ControllerError(
            "ordinary committed lifecycle did not retain exact recovery authority".to_owned(),
        ));
    }
    Ok(())
}

fn self_test_active_pointer() -> Result<()> {
    let expected = b"/private/fake-evidence\n".to_vec();
    let mut target = 0usize;
    loop {
        let mut backend = FakeActivePointerBackend {
            pending: None,
            active: None,
            expected: expected.clone(),
        };
        let mut boundary = 0usize;
        let result = drive_active_pointer(&mut backend, |_, operation, phase| {
            if boundary == target {
                return Err(injected_failure(
                    InjectedFault::Interruption,
                    operation,
                    phase,
                ));
            }
            boundary += 1;
            Ok(())
        });
        if result.is_ok() {
            break;
        }
        let retained_pending = backend.pending.clone();
        match recover_fake_active_pointer(&mut backend) {
            Ok(()) => {
                if backend.active.as_deref() != Some(expected.as_slice()) {
                    return Err(ControllerError(
                        "active-pointer recovery did not publish exact bytes".to_owned(),
                    ));
                }
            }
            Err(_) => {
                if retained_pending.is_none()
                    || backend.pending != retained_pending
                    || backend.active.is_some()
                {
                    return Err(ControllerError(
                        "malformed pending recovery did not fail closed with exact residue"
                            .to_owned(),
                    ));
                }
            }
        }
        target += 1;
        if target > 32 {
            return Err(ControllerError(
                "active-pointer matrix exceeded its bound".to_owned(),
            ));
        }
    }
    if target < 8 {
        return Err(ControllerError(format!(
            "active-pointer matrix covered only {target} boundaries"
        )));
    }

    let mut identical_residue = FakeActivePointerBackend {
        pending: Some(expected.clone()),
        active: Some(expected.clone()),
        expected: expected.clone(),
    };
    recover_fake_active_pointer(&mut identical_residue)?;
    if identical_residue.pending.as_deref() != Some(expected.as_slice())
        || identical_residue.active.as_deref() != Some(expected.as_slice())
    {
        return Err(ControllerError(
            "identical active/pending recovery did not retain both exact records".to_owned(),
        ));
    }

    let malformed = b"partial".to_vec();
    let mut malformed_residue = FakeActivePointerBackend {
        pending: Some(malformed.clone()),
        active: None,
        expected,
    };
    if recover_fake_active_pointer(&mut malformed_residue).is_ok()
        || malformed_residue.pending.as_deref() != Some(malformed.as_slice())
    {
        return Err(ControllerError(
            "malformed pending recovery did not retain exact bytes and fail closed".to_owned(),
        ));
    }
    Ok(())
}

fn self_test_side_effects() -> Result<()> {
    self_test_rollback()?;
    self_test_committed()?;
    self_test_active_pointer()?;

    // Interrupt every committed-recovery side-effect and journal boundary, then
    // restart from the durable journal and require a new PID/marker generation.
    let mut target = 0usize;
    loop {
        let (mut backend, mut journal, _directory) = committed_fake_fixture()?;
        let historical_pid = backend
            .world
            .current_pid
            .ok_or_else(|| ControllerError("committed fixture lacks a PID".to_owned()))?;
        backend.historical_pid = historical_pid.to_string();
        backend.world.committed_pid = Some(historical_pid);
        let mut boundary = 0usize;
        let result = drive_committed_recovery(&mut backend, &mut journal, |_, operation, phase| {
            if boundary == target {
                return Err(injected_failure(
                    InjectedFault::Interruption,
                    operation,
                    phase,
                ));
            }
            boundary += 1;
            Ok(())
        });
        if result.is_ok() {
            backend.world.assert_committed_current_generation()?;
            break;
        }
        let path = journal.path.clone();
        let interrupted_world = backend.world;
        drop(journal);
        let mut reopened = FakeJournal::open(&path)?;
        let recovered = recover_fake_transaction(interrupted_world, &mut reopened)?;
        recovered.assert_committed_current_generation()?;
        if recovered.current_pid == Some(historical_pid) {
            return Err(ControllerError(
                "interrupted committed recovery reused historical PID".to_owned(),
            ));
        }
        target += 1;
        if target > 96 {
            return Err(ControllerError(
                "committed-recovery matrix exceeded its bound".to_owned(),
            ));
        }
    }
    if target < 15 {
        return Err(ControllerError(format!(
            "committed-recovery matrix covered only {target} boundaries"
        )));
    }
    Ok(())
}
