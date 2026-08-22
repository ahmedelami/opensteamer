#[allow(dead_code)]
#[path = "opensteamer-host-paired-v7-update-controller.rs"]
mod v7_controller;

use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt as _;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitCode, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const EX_USAGE: u8 = 64;
const EX_NOINPUT: u8 = 66;
const EX_UNAVAILABLE: u8 = 69;
const EX_SOFTWARE: u8 = 70;
const EX_CONFIG: u8 = 78;

const SELF_TEST_MODE: &str = "--self-test";
const PREFLIGHT_MODE: &str = "--preflight";
const PREFLIGHT_KNOWN_FAILED_BOOTSTRAP_MODE: &str = "--preflight-known-failed-bootstrap";
const START_MODE: &str = "--start-local-trial";
const STOP_MODE: &str = "--stop-local-trial";
const ROOT_MODE: &str = "--root-local-trial-broker";
const UID_GUARDIAN_MODE: &str = "--uid501-local-trial-guardian";
const UID_ADMISSION_MODE: &str = "--uid501-verify-exact-v6-admission";
const UID_PRESTOP_REPAIR_MODE: &str = "--uid501-prestop-route-fence";
const UID_EMERGENCY_REPAIR_MODE: &str = "--uid501-emergency-route-repair";
const UID_EMERGENCY_V6_MODE: &str = "--uid501-emergency-v6-restore";
const UID_VERIFY_HAL_MODE: &str = "--uid501-verify-product-hal-absent";
const UID_VERIFY_CANDIDATE_MODE: &str = "--uid501-verify-local-trial-candidate";
const UID_STOP_V6_MODE: &str = "--uid501-stop-exact-v6";
const UID_FINALIZE_EVIDENCE_MODE: &str = "--uid501-finalize-local-trial-evidence";
const UID_CANDIDATE_GATE_MODE: &str = "--uid501-local-trial-candidate-gate";
const LIVE_RELEASE_STATUS: &str = "REVIEWED_LOCAL_TRIAL_READY";
const LIVE_RELEASE_READY: &str = "REVIEWED_LOCAL_TRIAL_READY";

const REPO: &str = "/Users/ahmed/Documents/Codex/opensteamer";
const ARTIFACT_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-prep/prep.L1Ciab";
const HOST_APP: &str = "/Applications/opensteamer Host.app";
const HOST_EXECUTABLE: &str =
    "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer";
const HOST_PLIST: &str =
    "/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist";
const LEGACY_APP: &str = "/Applications/AudioStreamer Host.app";
const LEGACY_EXECUTABLE: &str =
    "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer";
const LEGACY_PLIST: &str =
    "/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist";
const PRODUCT_DRIVER: &str =
    "/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver";
const SHARED_LOCK: &str = "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock";
const V6_LAUNCHD_LABEL: &str = "org.example.opensteamer.worldwide";

const TRIAL_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab";
const TRIAL_RUN_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/paired-v7-update-local-mono-prep-L1Ciab";
const TRIAL_PROBES: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/paired-v7-update-local-mono-prep-L1Ciab/probes";
const USER_GUARDIAN_STAGE: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging/opensteamer-v7-default-route-guardian";
const USER_CONTROLLER_STAGE: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging/opensteamer-local-mono-trial-controller";
const ACTIVE_POINTER: &str = "/Users/ahmed/Library/Application Support/opensteamer/active-local-mono-trial-v1";
const ACTIVE_POINTER_TEMP: &str = "/Users/ahmed/Library/Application Support/opensteamer/.active-local-mono-trial-v1.prep-L1Ciab.tmp";
const STOP_REQUEST: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/stop.request";
const PROXY_ARM: &str = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/proxy.arm";

const ROOT_SUPPORT: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1";
const ROOT_CONTROLLER: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/opensteamer-local-mono-trial-controller";
const ROOT_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/controller.sha256";
const ROOT_BROKER_SOCKET: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/broker-prep-L1Ciab.sock";
const ROOT_TRANSACTION: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/private-transaction-prep-L1Ciab";
const ROOT_SEALED: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab";
const SEALED_CONTROLLER: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/opensteamer-local-mono-trial-controller";
const SEALED_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/controller.sha256";
const SEALED_HOST_APP: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/opensteamer Host.app";
const SEALED_HOST_EXECUTABLE: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/opensteamer Host.app/Contents/MacOS/CaptureServer";
const SEALED_FRAMEWORK_EXECUTABLE: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC";
const SEALED_MIRROR_PROBE: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/physical-blackhole-microphone-probe";
const SEALED_VPIO_PROBE: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/opensteamer-public-vpio-probe";
const SEALED_GUARDIAN: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/opensteamer-v7-default-route-guardian";
const ROOT_PROXY_IDENTITY: &str = "/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab/uid501-proxy.identity";

// Phase budgets are derived below from fixed primitive bounds. Bundle and driver file hashing is
// one 120s batch plus one 30s manifest hash, independent of file count. Imported historical
// commands are privately transformed to 10s. Ordinary admission is capped at 256 calls (the
// exact current proof uses 238); the root-capability-only STOP/RESTORE helpers use a separate
// 800-call cap covering three complete admission passes plus 32 recovery commands.
// The pure self-test expands the complete guardian/root protocol sequence and requires the root
// absolute deadline to exceed that sum by at least 20%; heartbeats never extend either absolute
// deadline.
const ROOT_BROKER_DEADMAN_SECONDS: u64 = 75;
const ROOT_BROKER_ABSOLUTE_SECONDS: u64 = 73_000;
const ROOT_PROTOCOL_ABSOLUTE_SECONDS: u64 = 30_000;
const ROOT_GATE_RESPONSE_SECONDS: u64 = 480;
const ROOT_GUARDIAN_BIND_RESPONSE_SECONDS: u64 = 300;
const ROOT_PRESTOP_RESPONSE_SECONDS: u64 = 360;
const ROOT_CANDIDATE_STOP_RESPONSE_SECONDS: u64 = 300;
const ROOT_ROUTES_RESPONSE_SECONDS: u64 = 240;
const COMMAND_BOUND_SECONDS: u64 = 30;
const RUN_FIXED_BOUND_SECONDS: u64 = 60;
const FAST_PROCESS_BOUND_SECONDS: u64 = 5;
const BATCH_HASH_BOUND_SECONDS: u64 = 120;
const BUNDLE_TREE_PRIMITIVE_SECONDS: u64 = BATCH_HASH_BOUND_SECONDS + COMMAND_BOUND_SECONDS;
const SEALED_NORMALIZED_HOST_TREE_PRIMITIVE_SECONDS: u64 = BUNDLE_TREE_PRIMITIVE_SECONDS;
const DRIVER_TREE_PRIMITIVE_SECONDS: u64 = BATCH_HASH_BOUND_SECONDS + COMMAND_BOUND_SECONDS;
const SIGNATURE_PRIMITIVE_SECONDS: u64 = 6 * COMMAND_BOUND_SECONDS;
const PROBE_SIGNATURE_PRIMITIVE_SECONDS: u64 = 2 * COMMAND_BOUND_SECONDS;
const ACL_XATTR_PRIMITIVE_SECONDS: u64 = 40;
const COPY_TREE_PRIMITIVE_SECONDS: u64 = 2 * RUN_FIXED_BOUND_SECONDS + ACL_XATTR_PRIMITIVE_SECONDS;
const COREAUDIO_RESTART_ABSOLUTE_SECONDS: u64 = 120;
const COREAUDIO_RELOAD_PRIMITIVE_SECONDS: u64 = COREAUDIO_RESTART_ABSOLUTE_SECONDS + 40;
const GUARDIAN_BIND_PRIMITIVE_SECONDS: u64 = 150;
const PRESTOP_PRIMITIVE_SECONDS: u64 = 200;
const OWNED_SESSION_TERMINATION_PRIMITIVE_SECONDS: u64 = 120;
const CANDIDATE_MAPPING_HASH_BOUND_SECONDS: u64 = 15;
const CANDIDATE_CAPTURE_TOPOLOGY_MINIMUM_SECONDS: u64 =
    2 * (FAST_PROCESS_BOUND_SECONDS + 3 + CANDIDATE_MAPPING_HASH_BOUND_SECONDS + 3) + 1;
const CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS: u64 = 60;
const CANDIDATE_STOP_PRIMITIVE_SECONDS: u64 = OWNED_SESSION_TERMINATION_PRIMITIVE_SECONDS
    + CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS;
const PROXY_STOP_PRIMITIVE_SECONDS: u64 = 40;
const PROXY_FORCED_CLEANUP_RESERVE_SECONDS: u64 = 10;
const GUARDIAN_NATURAL_REAP_SECONDS: u64 = 10;
const GUARDIAN_FINISH_ABSOLUTE_SECONDS: u64 = 30;
const GUARDIAN_EVIDENCE_HASH_SECONDS: u64 = 5;
const GUARDIAN_EVIDENCE_JSON_SECONDS: u64 = 5;
const GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS: u64 =
    GUARDIAN_EVIDENCE_HASH_SECONDS + 3 + GUARDIAN_EVIDENCE_JSON_SECONDS + 3;
const GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS: u64 = COMMAND_BOUND_SECONDS + 3;
const POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS: u64 = 5;
const POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS: u64 =
    ROOT_BROKER_DEADMAN_SECONDS + POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS;
const POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS: u64 =
    ROOT_BROKER_DEADMAN_SECONDS + POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS;
const POST_PUBLISH_PARENT_SYNC_PRIMITIVE_SECONDS: u64 = 5;
const POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS: u64 =
    POST_PUBLISH_PARENT_SYNC_PRIMITIVE_SECONDS
        + GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS
        + GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS;
const POST_PUBLISH_FENCE_PRIMITIVE_SECONDS: u64 = reviewed_post_publish_fence_minimum(
    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS,
    POST_PUBLISH_PARENT_SYNC_PRIMITIVE_SECONDS,
    GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS,
    GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS,
    POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS,
);
const ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS: u64 = POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS;
const MIRROR_PROBE_TEARDOWN_SECONDS: u64 = 3;
const MIRROR_PROBE_HASH_SECONDS: u64 = COMMAND_BOUND_SECONDS;
const MIRROR_PROBE_HASH_PRIMITIVE_SECONDS: u64 =
    MIRROR_PROBE_HASH_SECONDS + MIRROR_PROBE_TEARDOWN_SECONDS;
const MIRROR_PROBE_EXECUTION_SECONDS: u64 = COMMAND_BOUND_SECONDS;
const MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS: u64 =
    MIRROR_PROBE_EXECUTION_SECONDS + MIRROR_PROBE_TEARDOWN_SECONDS;
const MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS: u64 = 5;
const MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS: u64 =
    2 * MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS;
const MIRROR_PROBE_JSON_SECONDS: u64 = 10;
const MIRROR_PROBE_JSON_PRIMITIVE_SECONDS: u64 =
    MIRROR_PROBE_JSON_SECONDS + MIRROR_PROBE_TEARDOWN_SECONDS;
const MIRROR_PROBE_PRIMITIVE_SECONDS: u64 = reviewed_mirror_probe_minimum(
    MIRROR_PROBE_HASH_PRIMITIVE_SECONDS,
    MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS,
    MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS,
    MIRROR_PROBE_JSON_PRIMITIVE_SECONDS,
);
const MIRROR_PROBE_CALL_HANDOFF_SECONDS: u64 = 1;
const MIRROR_PROBE_CALL_PRIMITIVE_SECONDS: u64 =
    MIRROR_PROBE_CALL_HANDOFF_SECONDS + MIRROR_PROBE_PRIMITIVE_SECONDS;
const LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS: u64 = 60;
const LIVE_GUARDIAN_TRANSCRIPT_PRIMITIVE_SECONDS: u64 = 5;
const LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS: u64 =
    LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS + LIVE_GUARDIAN_TRANSCRIPT_PRIMITIVE_SECONDS;
const LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS: u64 = POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS;
const LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS: u64 =
    2 * LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS + LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS;
const LIVE_ITERATION_OVERHANG_SECONDS: u64 =
    LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS + LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS;
const LIVE_ARM_SINGLE_EVIDENCE_WRITE_PRIMITIVE_SECONDS: u64 = 5;
const LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS: u64 =
    2 * LIVE_ARM_SINGLE_EVIDENCE_WRITE_PRIMITIVE_SECONDS;
const LIVE_ARM_PRIMITIVE_SECONDS: u64 =
    LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS + LIVE_ITERATION_OVERHANG_SECONDS;
const ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS: u64 =
    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;
const ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS: u64 =
    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;
const ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS: u64 =
    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS
        + POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS
        + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;
const ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS: u64 =
    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS
        + MIRROR_PROBE_CALL_PRIMITIVE_SECONDS
        + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;
const ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS: u64 =
    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;
const GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS: u64 = 5;
const ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS: u64 = 2
    * POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS
    + GUARDIAN_FINISH_ABSOLUTE_SECONDS
    + GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS
    + 2 * ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;
const GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS: u64 =
    ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS + ROOT_BROKER_DEADMAN_SECONDS;
const GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS: u64 =
    GUARDIAN_EVIDENCE_HASH_SECONDS + 3;
const GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS: u64 =
    reviewed_guardian_repair_reconciliation_maximum(
        GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS,
        GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS,
    );
const GUARDIAN_RECOVERY_STATE_BIND_MINIMUM_SECONDS: u64 =
    2 * GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
        + 2 * GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS;
const GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS: u64 = 150;
const GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_MINIMUM_SECONDS: u64 =
    GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
        + GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS;
const GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_SECONDS: u64 = 90;
const GUARDIAN_REPAIR_REPROOF_MINIMUM_SECONDS: u64 =
    GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS
        + GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS;
const GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS: u64 = 150;
const ROUTES_REPAIRED_PRIMITIVE_SECONDS: u64 = 90;
const ROLLBACK_PRIMITIVE_SECONDS: u64 = COMMAND_BOUND_SECONDS
    + FAST_PROCESS_BOUND_SECONDS
    + DRIVER_TREE_PRIMITIVE_SECONDS
    + SIGNATURE_PRIMITIVE_SECONDS
    + COREAUDIO_RELOAD_PRIMITIVE_SECONDS
    + UID_HAL_HELPER_SECONDS;
const PUBLISH_PRIMITIVE_SECONDS: u64 = COMMAND_BOUND_SECONDS
    + FAST_PROCESS_BOUND_SECONDS
    + 2 * (DRIVER_TREE_PRIMITIVE_SECONDS + SIGNATURE_PRIMITIVE_SECONDS)
    + COREAUDIO_RELOAD_PRIMITIVE_SECONDS;
const ROOT_PREPARE_PRIMITIVE_SECONDS: u64 = COMMAND_BOUND_SECONDS
    + 2 * (BUNDLE_TREE_PRIMITIVE_SECONDS + SIGNATURE_PRIMITIVE_SECONDS)
    + 3 * COMMAND_BOUND_SECONDS
    + (COPY_TREE_PRIMITIVE_SECONDS
        + BUNDLE_TREE_PRIMITIVE_SECONDS
        + SEALED_NORMALIZED_HOST_TREE_PRIMITIVE_SECONDS
        + 2 * COMMAND_BOUND_SECONDS
        + SIGNATURE_PRIMITIVE_SECONDS)
    + (COPY_TREE_PRIMITIVE_SECONDS
        + DRIVER_TREE_PRIMITIVE_SECONDS
        + SIGNATURE_PRIMITIVE_SECONDS)
    + 4 * RUN_FIXED_BOUND_SECONDS
    + 4 * COMMAND_BOUND_SECONDS
    + 2 * PROBE_SIGNATURE_PRIMITIVE_SECONDS
    + ACL_XATTR_PRIMITIVE_SECONDS;
const ROOT_PREPARE_SECONDS: u64 = 2_700;
const ROOT_STAGE_READY_SECONDS: u64 = 3_000;
const ROOT_PUBLISH_RESPONSE_SECONDS: u64 = 1_200;
const ROOT_PROBES_RESPONSE_SECONDS: u64 = 600;
const ROOT_CANDIDATE_RESPONSE_SECONDS: u64 = 900;
const ROOT_ROLLBACK_RESPONSE_SECONDS: u64 = 1_050;
const IMPORTED_COMMAND_BOUND_SECONDS: u64 = 10;
const ADMISSION_IMPORTED_COMMAND_MAXIMUM: u64 = 256;
const RECOVERY_IMPORTED_COMMAND_MAXIMUM: u64 = 800;
const CANDIDATE_IMPORTED_COMMAND_MAXIMUM: u64 = 32;
const NO_IMPORTED_COMMAND_MAXIMUM: u64 = 0;
const HEALTHY_ADMISSION_IMPORTED_COMMAND_COUNT: u64 = 238;
const BASELINE_PRIMITIVE_SECONDS: u64 =
    IMPORTED_COMMAND_BOUND_SECONDS * ADMISSION_IMPORTED_COMMAND_MAXIMUM;
const RECOVERY_IMPORTED_PRIMITIVE_SECONDS: u64 =
    IMPORTED_COMMAND_BOUND_SECONDS * RECOVERY_IMPORTED_COMMAND_MAXIMUM;
const UID_ADMISSION_PRIMITIVE_SECONDS: u64 = BASELINE_PRIMITIVE_SECONDS + 220;
const UID_STOP_PRIMITIVE_SECONDS: u64 = RECOVERY_IMPORTED_PRIMITIVE_SECONDS + 440;
const UID_RESTORE_PRIMITIVE_SECONDS: u64 = RECOVERY_IMPORTED_PRIMITIVE_SECONDS + 660;
const UID_HAL_HELPER_SECONDS: u64 = 180;
const UID_ROUTE_REPAIR_HELPER_SECONDS: u64 = 360;
const UID_SEALED_TEARDOWN_RESERVE_SECONDS: u64 = 4;
const GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS: u64 =
    GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_SECONDS
        + UID_ROUTE_REPAIR_HELPER_SECONDS
        + UID_SEALED_TEARDOWN_RESERVE_SECONDS
        + GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS;
const GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS: u64 =
    GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS
        + GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS;
const UID_STOP_HELPER_SECONDS: u64 = 8_700;
const UID_RESTORE_HELPER_SECONDS: u64 = 9_000;
const UID_CANDIDATE_HELPER_SECONDS: u64 = 720;
const UID_ADMISSION_SECONDS: u64 = 3_000;
const UID_FINALIZE_EVIDENCE_PRIMITIVE_SECONDS: u64 = UID_ADMISSION_PRIMITIVE_SECONDS + 120;
const UID_FINALIZE_EVIDENCE_HELPER_SECONDS: u64 = 3_300;
const ROOT_STOP_RESPONSE_SECONDS: u64 = 9_000;
const ROOT_RESTORE_RESPONSE_SECONDS: u64 = 9_300;
const ROOT_SOCKET_SETUP_SECONDS: u64 = RUN_FIXED_BOUND_SECONDS;
const ROOT_PROXY_SPAWN_SECONDS: u64 = 60 + CANDIDATE_STOP_PRIMITIVE_SECONDS;
const ROOT_ACCEPT_SECONDS: u64 = UID_ADMISSION_SECONDS + 600;
const ROOT_POST_COMPLETE_PROXY_SECONDS: u64 = PROXY_STOP_PRIMITIVE_SECONDS;
const START_READY_SECONDS: u64 = 18_000;
const STOP_COMPLETE_SECONDS: u64 = 16_000;
const EMERGENCY_CLEANUP_PRIMITIVE_SECONDS: u64 = PROXY_STOP_PRIMITIVE_SECONDS
    + CANDIDATE_STOP_PRIMITIVE_SECONDS
    + UID_STOP_HELPER_SECONDS
    + 4 * FAST_PROCESS_BOUND_SECONDS
    + ROUTES_REPAIRED_PRIMITIVE_SECONDS
    + GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS
    + ROLLBACK_PRIMITIVE_SECONDS
    + 120
    + UID_RESTORE_HELPER_SECONDS
    + UID_FINALIZE_EVIDENCE_HELPER_SECONDS;
const EMERGENCY_CLEANUP_ABSOLUTE_SECONDS: u64 = 24_000;
const GUARDIAN_IDLE_SECONDS: u64 = 9_900;
const GUARDIAN_MAXIMUM_SECONDS: u64 = 16_500;
const GUARDIAN_SOURCE_MAXIMUM_SECONDS: u64 = 20_000;
const O_NOFOLLOW: i32 = 0x0000_0100;
const O_CLOEXEC: i32 = 0x0100_0000;
const RENAME_EXCL: u32 = 0x0000_0004;
const AT_FDCWD: i32 = -2;
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
const COREAUDIOD_UID: u32 = 202;
const DARWIN_SIGCHLD: i32 = 20;
const DARWIN_CLD_EXITED: i32 = 1;
const DARWIN_CLD_KILLED: i32 = 2;
const DARWIN_CLD_DUMPED: i32 = 3;
const SOL_LOCAL: i32 = 0;
const LOCAL_PEERPID: i32 = 2;
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;
const AHMED_GROUPS: &[u32] = &[
    20, 503, 12, 61, 79, 80, 81, 502, 33, 98, 100, 204, 250, 395, 701,
];

const fn reviewed_post_publish_fence_minimum(
    guardian_exchange_seconds: u64,
    parent_sync_seconds: u64,
    evidence_seconds: u64,
    state_hash_seconds: u64,
    root_exchange_seconds: u64,
) -> u64 {
    guardian_exchange_seconds
        + parent_sync_seconds
        + evidence_seconds
        + state_hash_seconds
        + root_exchange_seconds
}

const fn reviewed_mirror_probe_minimum(
    hash_seconds: u64,
    execution_seconds: u64,
    output_writes_seconds: u64,
    json_seconds: u64,
) -> u64 {
    hash_seconds + execution_seconds + output_writes_seconds + json_seconds
}

const fn reviewed_guardian_repair_reconciliation_maximum(
    evidence_validation_seconds: u64,
    attempt_hash_seconds: u64,
) -> u64 {
    let existing_canonical_seconds = evidence_validation_seconds;
    let successful_publication_seconds = 2 * evidence_validation_seconds;
    let rejected_attempt_seconds = evidence_validation_seconds + 2 * attempt_hash_seconds;
    let recovered_canonical_seconds = 3 * evidence_validation_seconds;
    let mut maximum_seconds = existing_canonical_seconds;
    if successful_publication_seconds > maximum_seconds {
        maximum_seconds = successful_publication_seconds;
    }
    if rejected_attempt_seconds > maximum_seconds {
        maximum_seconds = rejected_attempt_seconds;
    }
    if recovered_canonical_seconds > maximum_seconds {
        maximum_seconds = recovered_canonical_seconds;
    }
    maximum_seconds
}

const V6_HOST_SHA256: &str =
    "63d55477ca440dd3feb27f68959b479a2292e6accc635d159674c6b420b60de6";
const V6_PLIST_SHA256: &str =
    "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";
const LEGACY_HOST_SHA256: &str =
    "1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc";
const LEGACY_PLIST_SHA256: &str =
    "419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730";

const DEVELOPMENT_IDENTITY_SHA1: &str =
    "483C08B6517EBC1CFCCAB1A88BBEE8028750AA13";
const DEVELOPMENT_LEAF_SHA256: &str =
    "79c20ad3c50b2428435435ac927c7d76cc60eaa56eaacb277fb8c467ea0684a4";
const TEAM_ID: &str = "MSMG8CJLB3";

const CANDIDATE_HOST_RELATIVE: &str =
    "host-output/opensteamer Host.app/Contents/MacOS/CaptureServer";
const CANDIDATE_HOST_APP_RELATIVE: &str = "host-output/opensteamer Host.app";
const CANDIDATE_FRAMEWORK_RELATIVE: &str = "host-output/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC";
const CANDIDATE_HOST_SHA256: &str =
    "04ee090a3ad79ce08ff62c09e6872a292ea22f645423430ea1cff0f5475a46d6";
const CANDIDATE_HOST_NON_DAEMONIZING_AUDIT_SHA256: &str =
    "04ee090a3ad79ce08ff62c09e6872a292ea22f645423430ea1cff0f5475a46d6";
const CANDIDATE_HOST_CDHASH: &str = "af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b";
const CANDIDATE_HOST_TREE_SHA256: &str =
    "0d6f16b191c8009636530214dbfed8d7018e49efd792f90f7047e1b241e3100a";
const SEALED_CANDIDATE_HOST_TREE_SHA256: &str =
    "2005ab3a80a52117b2368ccf9c6b7f85e9b9c12689e468ab4b52c91e4b4c225e";
const SEALED_HOST_SIGNATURE_RESOURCES: &[&str] = &[
    "Contents/_CodeSignature/CodeResources",
    "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/_CodeSignature/CodeResources",
];
const CANDIDATE_FRAMEWORK_SHA256: &str =
    "6963873e510a4022108dfd7106c0cac3467da0b74b6d6635a38865764f114d1b";
const CANDIDATE_DRIVER_RELATIVE: &str =
    "driver-output/OpensteamerVirtualMicrophone.driver/Contents/MacOS/OpensteamerVirtualMicrophone";
const CANDIDATE_DRIVER_SHA256: &str =
    "e78bfe1080660de99769d0f9313459fb22a08863d4ade52d25921db871383745";
const CANDIDATE_DRIVER_TREE_SHA256: &str =
    "48089061c4333dc29201f48eaa3b4e889fde99174dd99ffeaed414d9d98b3aa5";
const CANDIDATE_DRIVER_CDHASH: &str = "136282fbe7626c26618738e739eea2b0df2b59d5";
const MIRROR_PROBE_RELATIVE: &str = "probes/physical-blackhole-microphone-probe";
const MIRROR_PROBE_SHA256: &str =
    "403d1bf8aed711dba05c0ed575af4620ee8fa2454e6b50b6d51d07f261703d33";
const MIRROR_PROBE_NON_DAEMONIZING_AUDIT_SHA256: &str =
    "403d1bf8aed711dba05c0ed575af4620ee8fa2454e6b50b6d51d07f261703d33";
const VPIO_PROBE_RELATIVE: &str = "probes/opensteamer-public-vpio-probe";
const VPIO_PROBE_SHA256: &str =
    "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8";
const VPIO_PROBE_NON_DAEMONIZING_AUDIT_SHA256: &str =
    "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8";
const ROUTE_GUARDIAN_SHA256: &str =
    "72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c";
const ROUTE_GUARDIAN_NON_DAEMONIZING_AUDIT_SHA256: &str =
    "72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c";
const LIVE_PROCESS_VERIFIER: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716/source-export/macOS/scripts/verify-live-mac-host-process.sh";
const LIVE_PROCESS_VERIFIER_SHA256: &str =
    "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TrialStage {
    Prepared,
    CandidateGateBound,
    V6StopIntent,
    V6Stopped,
    PublishIntent,
    DriverRenamedBeforeJournal,
    DriverPublished,
    CoreAudioReloaded,
    ProbesVerified,
    CandidateSpawnedBeforeTracked,
    CandidateRunning,
    CandidateStopped,
    RoutesRepaired,
    DriverRestored,
    V6Restored,
}

#[derive(Default, Debug)]
struct RollbackTrace {
    candidate_stopped_at: Option<usize>,
    candidate_absent_at: Option<usize>,
    routes_repaired_at: Option<usize>,
    driver_restored_at: Option<usize>,
    v6_restored_at: Option<usize>,
    events: Vec<&'static str>,
}

impl RollbackTrace {
    fn push(&mut self, event: &'static str) -> usize {
        let index = self.events.len();
        self.events.push(event);
        index
    }
}

fn rollback_from(stage: TrialStage) -> RollbackTrace {
    let mut trace = RollbackTrace::default();
    if matches!(
        stage,
        TrialStage::CandidateGateBound
            | TrialStage::CandidateSpawnedBeforeTracked
            | TrialStage::CandidateRunning
    ) {
        let index = trace.push("candidate-stopped");
        trace.candidate_stopped_at = Some(index);
        let index = trace.push("candidate-and-shared-lock-proved-absent");
        trace.candidate_absent_at = Some(index);
    }
    if matches!(
        stage,
        TrialStage::V6StopIntent
            | TrialStage::V6Stopped
            | TrialStage::PublishIntent
            | TrialStage::DriverRenamedBeforeJournal
            | TrialStage::DriverPublished
            | TrialStage::CoreAudioReloaded
            | TrialStage::ProbesVerified
            | TrialStage::CandidateSpawnedBeforeTracked
            | TrialStage::CandidateRunning
            | TrialStage::CandidateStopped
    ) {
        let index = trace.push("guardian-repaired-and-verified-all-default-selectors");
        trace.routes_repaired_at = Some(index);
    }
    if matches!(
        stage,
        TrialStage::PublishIntent
            | TrialStage::V6StopIntent
            | TrialStage::V6Stopped
            | TrialStage::DriverRenamedBeforeJournal
            | TrialStage::DriverPublished
            | TrialStage::CoreAudioReloaded
            | TrialStage::ProbesVerified
            | TrialStage::CandidateSpawnedBeforeTracked
            | TrialStage::CandidateRunning
            | TrialStage::CandidateStopped
            | TrialStage::RoutesRepaired
    ) {
        let index = trace.push("driver-restored-and-coreaudio-reloaded");
        trace.driver_restored_at = Some(index);
    }
    if !matches!(
        stage,
        TrialStage::Prepared | TrialStage::CandidateGateBound | TrialStage::V6Restored
    ) {
        let index = trace.push("exact-v6-bootstrapped-and-verified");
        trace.v6_restored_at = Some(index);
    }
    trace
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GuardianRepairAttemptModel {
    Partial,
    Failed,
    Success,
}

fn guardian_repair_retry_model(
    initial_partial_attempt: bool,
    attempts: &[GuardianRepairAttemptModel],
) -> bool {
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum ArtifactState {
        Absent,
        Attempt,
        Published,
    }
    let mut state = if initial_partial_attempt {
        ArtifactState::Attempt
    } else {
        ArtifactState::Absent
    };
    for outcome in attempts {
        if state == ArtifactState::Published {
            break;
        }
        // Any exact safe bounded non-success attempt is durably summarized and
        // cleared before the fixed attempt path is reused.
        if state == ArtifactState::Attempt {
            state = ArtifactState::Absent;
        }
        if state != ArtifactState::Absent {
            return false;
        }
        state = ArtifactState::Attempt;
        if state != ArtifactState::Attempt {
            return false;
        }
        match outcome {
            GuardianRepairAttemptModel::Success => {
                state = ArtifactState::Published;
            }
            GuardianRepairAttemptModel::Partial | GuardianRepairAttemptModel::Failed => {
                state = ArtifactState::Absent;
            }
        }
    }
    state == ArtifactState::Published
}

fn source_slice<'a>(
    source: &'a str,
    start: &str,
    end: &str,
    label: &str,
) -> Result<&'a str, String> {
    let offset = source
        .find(start)
        .ok_or_else(|| format!("{label} source start is absent"))?;
    let remainder = &source[offset..];
    let length = remainder
        .find(end)
        .ok_or_else(|| format!("{label} source end is absent"))?;
    Ok(&remainder[..length])
}

fn verify_coreaudio_restart_body(body: &str) -> Result<(), String> {
    let ordered = [
        "let before_first = settle_stable_coreaudiod_generation(absolute_deadline)?;",
        "let before_second = coreaudiod_identity_until(absolute_deadline)?",
        "if before_second != before_first",
        "if Instant::now() >= absolute_deadline",
        "libc_kill(before_first.pid as i32, SIGTERM)",
        "wait_for_coreaudiod_generation_absence(&before_first, absolute_deadline)?;",
        "wait_for_changed_coreaudiod_generation(&before_first, absolute_deadline)?;",
        "if after == before_first",
    ];
    let mut cursor = 0;
    for step in ordered {
        if body.matches(step).count() != 1 {
            return Err(format!("Core Audio restart step count changed: {step}"));
        }
        let found = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("Core Audio restart step reordered: {step}"))?;
        cursor += found + step.len();
    }
    for forbidden in ["launchctl", "kickstart", "SIGKILL", "libc_kill(-", "killall"] {
        if body.contains(forbidden) {
            return Err(format!("Core Audio restart regained forbidden primitive: {forbidden}"));
        }
    }
    Ok(())
}

fn verify_coreaudio_restart_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let identity = source_slice(
        source,
        "\nfn process_generation_for_pid_until(",
        "\nfn coreaudiod_pids_until(",
        "Core Audio generation identity",
    )?;
    for required in [
        "process_bsd_identity(pid)?",
        "(1..=4).contains(&first.status)",
        "process_executable_path(pid)",
        "first.start_seconds",
        "first.start_microseconds",
    ] {
        if !identity.contains(required) {
            return Err(format!("Core Audio libproc identity contract changed: {required}"));
        }
    }
    let exact = source_slice(
        source,
        "\nfn coreaudiod_identity_until(",
        "\nfn wait_for_coreaudiod_generation_absence(",
        "Core Audio singleton identity",
    )?;
    for required in [
        "pids.len() != 1",
        "generation.uid != COREAUDIOD_UID",
        "generation.executable != Path::new(\"/usr/sbin/coreaudiod\")",
        "coreaudiod_pids_until(deadline)? != [pid]",
    ] {
        if exact.matches(required).count() != 1 {
            return Err(format!("Core Audio singleton contract changed: {required}"));
        }
    }
    let enumeration = source_slice(
        source,
        "\nfn coreaudiod_pids_until(",
        "\nfn coreaudiod_identity_until(",
        "Core Audio bounded singleton enumeration",
    )?;
    for required in [
        "checked_sub(Duration::from_secs(3))",
        "std::cmp::min(value, Duration::from_secs(2))",
        "coreaudiod enumeration lacks its process teardown reserve",
    ] {
        if !enumeration.contains(required) {
            return Err(format!("Core Audio enumerator deadline reserve changed: {required}"));
        }
    }
    let settle = source_slice(
        source,
        "\nfn settle_stable_coreaudiod_generation(",
        "\nfn reload_core_audio_root()",
        "Core Audio stable-generation polling",
    )?;
    if settle
        .matches("Err(error) if error.starts_with(\"transient coreaudiod topology:\") => {}")
        .count()
        < 4
    {
        return Err("Core Audio stable-generation polls no longer retry transient topology".to_owned());
    }
    let body = source_slice(
        source,
        "\nfn reload_core_audio_root() -> Result<(), String> {",
        "\nfn root_publish_driver(",
        "Core Audio positive-PID restart",
    )?;
    verify_coreaudio_restart_body(body)?;
    for (label, mutant) in [
        (
            "stale-pid",
            body.replacen(
                "let before_second = coreaudiod_identity_until(absolute_deadline)?",
                "let before_second = Some(before_first.clone())",
                1,
            ),
        ),
        (
            "name-restart",
            body.replacen(
                "libc_kill(before_first.pid as i32, SIGTERM)",
                "launchctl kickstart -k coreaudiod",
                1,
            ),
        ),
        (
            "same-generation",
            body.replacen("if after == before_first", "if false", 1),
        ),
    ] {
        if mutant == body || verify_coreaudio_restart_body(&mutant).is_ok() {
            return Err(format!("Core Audio source test admitted {label} mutant"));
        }
    }
    Ok(())
}

fn verify_retained_session_body(body: &str) -> Result<(), String> {
    for required in [
        "retained_child_exited_without_reap(child)",
        "checked_duration_since(Instant::now())",
        "*value > Duration::from_secs(CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS)",
        "candidate stop lacks its mandatory KILL/topology reserve",
        "signal_session_members(*pid, SIGTERM, signal_deadline)",
        "signal_session_members(*pid, SIGKILL, signal_deadline)",
        "while Instant::now() < signal_deadline",
        "CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS",
        "sleep_capped_by_absolute_deadline(term_deadline, Duration::from_millis(100))",
        "sleep_capped_by_absolute_deadline(signal_deadline, Duration::from_millis(100))",
        "finish_owned_candidate_stop(",
    ] {
        if !body.contains(required) {
            return Err(format!("retained candidate-session contract lost: {required}"));
        }
    }
    for forbidden in [
        "process_group_exists(",
        "libc_kill(-",
        "child.try_wait()",
        "child.wait()",
        "stop_exact_candidate_root",
        "verify_tracked_candidate_signal_identity",
        "thread::sleep(",
    ] {
        if body.contains(forbidden) {
            return Err(format!("retained candidate-session contract regained: {forbidden}"));
        }
    }
    Ok(())
}

fn verify_owned_session_binary_bodies(
    candidate_gate: &str,
    guardian_spawn: &str,
) -> Result<(), String> {
    let candidate_hash =
        "require_hash(Path::new(SEALED_HOST_EXECUTABLE), CANDIDATE_HOST_SHA256)?;";
    let candidate_command = "let mut command = Command::new(SEALED_HOST_EXECUTABLE);";
    let candidate_exec = "let error = command.exec();";
    if candidate_gate.matches(candidate_hash).count() != 1
        || candidate_gate.matches(candidate_command).count() != 1
        || candidate_gate.matches(candidate_exec).count() != 1
        || candidate_gate.contains("libc_setsid")
        || candidate_gate.contains(".spawn()")
    {
        return Err(
            "candidate gate lost its pinned, non-daemonizing same-process exec contract"
                .to_owned(),
        );
    }
    let candidate_hash_offset = candidate_gate
        .find(candidate_hash)
        .ok_or("candidate host hash proof is absent")?;
    let candidate_command_offset = candidate_gate
        .find(candidate_command)
        .ok_or("candidate host command construction is absent")?;
    let candidate_exec_offset = candidate_gate
        .find(candidate_exec)
        .ok_or("candidate host same-process exec is absent")?;
    if !(candidate_hash_offset < candidate_command_offset
        && candidate_command_offset < candidate_exec_offset)
    {
        return Err("candidate host hash/exec order changed".to_owned());
    }

    let guardian_hash =
        "require_hash(Path::new(SEALED_GUARDIAN), ROUTE_GUARDIAN_SHA256)?;";
    let guardian_child_hash =
        "require_hash(Path::new(SEALED_VPIO_PROBE), VPIO_PROBE_SHA256)?;";
    let guardian_command = "let mut command = Command::new(SEALED_GUARDIAN);";
    let guardian_spawn_call = "let child = command\n        .spawn()";
    if guardian_spawn.matches(guardian_hash).count() != 1
        || guardian_spawn.matches(guardian_child_hash).count() != 1
        || guardian_spawn.matches(guardian_command).count() != 1
        || guardian_spawn.matches(guardian_spawn_call).count() != 1
        || guardian_spawn.matches("if libc_setsid() < 0").count() != 1
        || guardian_spawn
            .matches("OwnedSessionChild::new(child, \"persistent guardian\")")
            .count()
            != 1
    {
        return Err(
            "guardian lost its pinned direct-Child/new-session ownership contract".to_owned(),
        );
    }
    let guardian_hash_offset = guardian_spawn
        .find(guardian_hash)
        .ok_or("guardian hash proof is absent")?;
    let guardian_command_offset = guardian_spawn
        .find(guardian_command)
        .ok_or("guardian command construction is absent")?;
    let guardian_spawn_offset = guardian_spawn
        .find(guardian_spawn_call)
        .ok_or("guardian spawn is absent")?;
    let guardian_child_hash_offset = guardian_spawn
        .find(guardian_child_hash)
        .ok_or("guardian child-probe hash proof is absent")?;
    if !(guardian_hash_offset < guardian_child_hash_offset
        && guardian_child_hash_offset < guardian_command_offset
        && guardian_command_offset < guardian_spawn_offset)
    {
        return Err("guardian hash/spawn order changed".to_owned());
    }
    Ok(())
}

fn verify_waitid_body(body: &str) -> Result<(), String> {
    for required in [
        "libc_waitid(",
        "0x0000_0001 | 0x0000_0004 | 0x0000_0020",
        "info.si_signo != DARWIN_SIGCHLD",
        "DARWIN_CLD_EXITED | DARWIN_CLD_KILLED | DARWIN_CLD_DUMPED",
    ] {
        if !body.contains(required) {
            return Err(format!("waitid retained-Child contract changed: {required}"));
        }
    }
    verify_ordered_source_steps(
        body,
        "waitid EINTR reset",
        &[
            "let (status, info) = loop {",
            "let mut info: DarwinSigInfo = unsafe { std::mem::zeroed() };",
            "libc_waitid(",
            "break (observed, info);",
        ],
    )
}

fn verify_candidate_topology_body(body: &str) -> Result<(), String> {
    for required in [
        "Duration::from_secs(CANDIDATE_CAPTURE_TOPOLOGY_MINIMUM_SECONDS)",
        "capture_server_pids_until(deadline)?",
        "verify_exact_v6_process_mapping_until(others[0], deadline)?;",
        "sleep_capped_by_absolute_deadline(deadline, Duration::from_millis(5))",
    ] {
        if !body.contains(required) {
            return Err(format!("candidate pre-reap deadline contract changed: {required}"));
        }
    }
    if body.contains("verify_exact_v6_process_mapping(others[0])") {
        return Err("candidate pre-reap topology regained an unbounded exact-v6 proof".to_owned());
    }
    Ok(())
}

fn verify_retained_session_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let waitid = source_slice(
        source,
        "\nfn retained_child_exited_without_reap(",
        "\nfn supervising_session(",
        "nonreaping waitid",
    )?;
    verify_waitid_body(waitid)?;
    let stale_siginfo_mutant = waitid.replacen(
        "let mut info: DarwinSigInfo = unsafe { std::mem::zeroed() };",
        "let mut info: DarwinSigInfo = retained_prior_siginfo;",
        1,
    );
    if stale_siginfo_mutant == waitid || verify_waitid_body(&stale_siginfo_mutant).is_ok() {
        return Err("waitid source test admitted stale siginfo across EINTR".to_owned());
    }
    let signal = source_slice(
        source,
        "\nfn signal_session_members(",
        "\nfn terminate_preconfigured_session(",
        "positive SID-member signal",
    )?;
    if !signal.contains("libc_kill(member.pid as i32, signal)")
        || !signal.contains("getsid_exact_or_absent(member.pid)")
        || signal.contains("libc_kill(-")
    {
        return Err("SID-member signal lost its adjacent positive-PID fence".to_owned());
    }
    let termination = source_slice(
        source,
        "\nfn terminate_preconfigured_session(",
        "\nfn owned_session_ready_to_reap(",
        "generic retained-session termination",
    )?;
    for required in [
        "checked_sub(kill_reserve)",
        "signal_session_members(session, SIGKILL, absolute_deadline)",
        "sleep_capped_by_absolute_deadline(term_deadline, Duration::from_millis(20))",
        "sleep_capped_by_absolute_deadline(absolute_deadline, Duration::from_millis(20))",
    ] {
        if !termination.contains(required) {
            return Err(format!("retained-session absolute-deadline contract changed: {required}"));
        }
    }
    if termination.contains("thread::sleep(") {
        return Err("retained-session termination regained an uncapped sleep".to_owned());
    }
    let barrier = source_slice(
        source,
        "\nfn owned_session_ready_to_reap(",
        "\nfn reap_quiescent_owned_session(",
        "two-scan retained-session reap barrier",
    )?;
    if barrier.matches("session_member_identities(session, deadline)?").count() != 2
        || barrier.matches("retained_child_exited_without_reap(child)").count() != 3
        || !barrier.contains("member.pid != session")
    {
        return Err("retained-session barrier lost two scans/leader-only WNOWAIT proof".to_owned());
    }
    let candidate_gate = source_slice(
        source,
        "\nfn uid_candidate_gate() -> Result<(), String> {",
        "\nfn finish_guardian(",
        "candidate same-process exec",
    )?;
    let guardian_spawn = source_slice(
        source,
        "\nfn spawn_persistent_guardian() -> Result<GuardianBroker, String> {",
        "\nfn uid_candidate_gate()",
        "guardian direct Child",
    )?;
    verify_owned_session_binary_bodies(candidate_gate, guardian_spawn)?;
    for (label, candidate_mutant, guardian_mutant) in [
        (
            "candidate-session-escape",
            candidate_gate.replacen(
                "let error = command.exec();",
                "let _ = unsafe { libc_setsid() };\n    let error = command.exec();",
                1,
            ),
            guardian_spawn.to_owned(),
        ),
        (
            "candidate-unpinned-exec",
            candidate_gate.replacen(
                "require_hash(Path::new(SEALED_HOST_EXECUTABLE), CANDIDATE_HOST_SHA256)?;",
                "",
                1,
            ),
            guardian_spawn.to_owned(),
        ),
        (
            "guardian-unpinned-spawn",
            candidate_gate.to_owned(),
            guardian_spawn.replacen(
                "require_hash(Path::new(SEALED_GUARDIAN), ROUTE_GUARDIAN_SHA256)?;",
                "",
                1,
            ),
        ),
        (
            "guardian-unpinned-child",
            candidate_gate.to_owned(),
            guardian_spawn.replacen(
                "require_hash(Path::new(SEALED_VPIO_PROBE), VPIO_PROBE_SHA256)?;",
                "",
                1,
            ),
        ),
    ] {
        if (candidate_mutant == candidate_gate && guardian_mutant == guardian_spawn)
            || verify_owned_session_binary_bodies(&candidate_mutant, &guardian_mutant).is_ok()
        {
            return Err(format!(
                "owned-session binary source test admitted {label} mutant"
            ));
        }
    }
    let mirror_probe = source_slice(
        source,
        "\nfn run_mirror_probe_until(",
        "\nfn run_live_guardian_heartbeat_until(",
        "mirror probe pinned spawn",
    )?;
    verify_ordered_source_steps(
        mirror_probe,
        "mirror probe non-daemonizing pin",
        &[
            "let observed_hash = sha256_until(",
            "if observed_hash != MIRROR_PROBE_SHA256",
            "Command::new(SEALED_MIRROR_PROBE)",
        ],
    )?;
    let candidate = source_slice(
        source,
        "\nfn stop_owned_candidate_root(",
        "\nfn run_uid_sealed_until(",
        "retained candidate stop",
    )?;
    verify_retained_session_body(candidate)?;
    let candidate_topology = source_slice(
        source,
        "\nfn prove_candidate_capture_topology_before_reap(",
        "\nfn finish_owned_candidate_stop(",
        "candidate pre-reap topology reserve",
    )?;
    verify_candidate_topology_body(candidate_topology)?;
    let deadline_hash = source_slice(
        source,
        "\nfn sha256_until(",
        "\nfn require_absent_no_follow(",
        "candidate deadline-aware executable hash",
    )?;
    for required in [
        "checked_duration_since(Instant::now())",
        "checked_sub(Duration::from_secs(3))",
        "Duration::from_secs(maximum_seconds)",
        "CANDIDATE_MAPPING_HASH_BOUND_SECONDS",
    ] {
        if !deadline_hash.contains(required) {
            return Err(format!("candidate hash deadline contract changed: {required}"));
        }
    }
    let exact_v6_until = source_slice(
        source,
        "\nfn verify_exact_v6_process_mapping_until(",
        "\nfn verify_root_guardian_process(",
        "candidate deadline-aware exact-v6 mapping",
    )?;
    if exact_v6_until
        .matches("require_hash_until(expected_path, V6_HOST_SHA256, deadline)?;")
        .count()
        != 1
        || !exact_v6_until.contains("process_executable_path(pid)? != expected_path")
        || !exact_v6_until.contains("Instant::now() >= deadline")
    {
        return Err("candidate exact-v6 mapping lost its shared absolute deadline".to_owned());
    }
    let unbounded_topology_mutant = candidate_topology.replacen(
        "capture_server_pids_until(deadline)?",
        "capture_server_pids()?",
        1,
    );
    if unbounded_topology_mutant == candidate_topology
        || verify_candidate_topology_body(&unbounded_topology_mutant).is_ok()
    {
        return Err("candidate source test admitted an unbounded pre-reap topology probe".to_owned());
    }
    let unbounded_mapping_mutant = candidate_topology.replacen(
        "verify_exact_v6_process_mapping_until(others[0], deadline)?;",
        "verify_exact_v6_process_mapping(others[0])?;",
        1,
    );
    if unbounded_mapping_mutant == candidate_topology
        || verify_candidate_topology_body(&unbounded_mapping_mutant).is_ok()
    {
        return Err("candidate source test admitted an unbounded pre-reap v6 mapping".to_owned());
    }
    for (label, mutant) in [
        (
            "negative-pgid",
            candidate.replacen(
                "signal_session_members(*pid, SIGKILL, signal_deadline)",
                "libc_kill(-(*pid as i32), SIGKILL)",
                1,
            ),
        ),
        (
            "missing-kill-sweep",
            candidate.replace(
                "signal_session_members(*pid, SIGKILL, signal_deadline)",
                "Ok(())",
            ),
        ),
        (
            "pre-empty-reap",
            candidate.replacen("finish_owned_candidate_stop(", "child.wait(); finish_owned_candidate_stop(", 1),
        ),
        (
            "uncapped-sleep",
            format!("{candidate}\nthread::sleep(Duration::from_secs(1));"),
        ),
        (
            "short-expired-caller-deadline",
            candidate.replacen(
                "*value > Duration::from_secs(CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS)",
                "true",
                1,
            ),
        ),
    ] {
        if mutant == candidate || verify_retained_session_body(&mutant).is_ok() {
            return Err(format!("retained-session source test admitted {label} mutant"));
        }
    }
    Ok(())
}

fn verify_emergency_cleanup_body(body: &str) -> Result<(), String> {
    let ordered = [
        "stop_root_spawned_proxy(state, 30, absolute_deadline)",
        "run_uid_sealed_until(UID_STOP_V6_MODE, None, absolute_deadline)",
        "stop_owned_candidate_root(\n                    child,\n                    identity,\n                    !offline_recovery_required,\n                    absolute_deadline,\n                )",
        "acquire_runtime_mutation_guard_root()",
        "let mut routes_satisfied",
        "root_restore_driver_reload_and_verify_hal(&state.hold, runtime_lock)",
        "remove_incomplete_active_pointer_temp_if_present()",
        "run_uid_sealed_until(UID_EMERGENCY_V6_MODE, None, absolute_deadline)",
        "run_uid_sealed_until(UID_FINALIZE_EVIDENCE_MODE, None, absolute_deadline)",
        "root_append_state(\"EMERGENCY_RECOVERY_COMPLETE\")",
        "root_append_state(\"EMERGENCY_RECOVERY_INCOMPLETE\")",
    ];
    let mut cursor = 0;
    for step in ordered {
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("emergency cleanup step absent/reordered: {step}"))?;
        cursor += offset + step.len();
    }
    for forbidden in [
        "stop_exact_candidate_root",
        "process_group_exists(",
        "libc_kill(-",
        "state.candidate.is_none()",
    ] {
        if body.contains(forbidden) {
            return Err(format!("emergency cleanup regained unsafe fallback: {forbidden}"));
        }
    }
    if body.contains("?;")
        || !body.contains("errors.push(\"pointer-temp-cleanup\"")
        || !body.contains("state.runtime_lock.is_none()")
        || !body.contains("guardian_reaped_authenticated")
        || !body.contains("guardian_quiescence_deadline")
        || !body.contains("wait_for_tracked_guardian_generation_absence(")
        || !body.contains("root_resume_or_run_emergency_route_repair(")
        || !body.contains("state.candidate_stopped = candidate_session_quiescent;")
        || !body.contains(
            "&& runtime_gate_satisfied\n        && routes_satisfied\n    {\n        let runtime_lock",
        )
        || !body.contains(
            "&& state.driver_restored\n        && state.v6_restored\n        && !state.v6_restore_may_have_begun\n        && state.runtime_lock.is_none();",
        )
        || !body.contains("let finalization_gate = finalization_scope\n        && proxy_quiescent")
    {
        return Err("emergency cleanup is fail-fast or lost a terminal barrier".to_owned());
    }
    Ok(())
}

fn verify_driver_reload_journal_nonblocking_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "driver rollback reload/HAL recovery",
        &[
            "let operation = root_restore_driver(hold_identity, runtime_lock);",
            "root_driver_restored_postcondition(hold_identity)?",
            "reload_core_audio_root()?;",
            "require_runtime_mutation_guard_barrier_root(runtime_lock)?;",
            "if let Err(error) = root_append_state(\"ROLLBACK_COREAUDIO_RELOADED\") {",
            "driver rollback Core Audio journal failed: {error}",
            "run_uid_sealed(UID_VERIFY_HAL_MODE, None)?;",
            "require_runtime_mutation_guard_barrier_root(runtime_lock)?;",
        ],
    )?;
    if body
        .matches("if let Err(error) = root_append_state(\"ROLLBACK_COREAUDIO_RELOADED\") {")
        .count()
        != 1
        || body.contains("root_append_state(\"ROLLBACK_COREAUDIO_RELOADED\")?;")
    {
        return Err("driver rollback journal can suppress independent HAL recovery".to_owned());
    }
    Ok(())
}

fn verify_emergency_cleanup_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let body = source_slice(
        source,
        "\nfn root_emergency_cleanup(\n    state: &mut RootBrokerState,\n    root_deadline: Instant,\n) -> Result<(), String> {",
        "\nfn spawn_line_reader<",
        "emergency cleanup state machine",
    )?;
    verify_emergency_cleanup_body(body)?;
    for (label, mutant) in [
        (
            "candidate-none-signal",
            body.replacen(
                "drop(state.candidate_control.take());",
                "stop_exact_candidate_root(None);",
                1,
            ),
        ),
        (
            "driver-before-routes",
            body.replacen(
                "&& runtime_gate_satisfied\n        && routes_satisfied\n    {\n        let runtime_lock",
                "&& runtime_gate_satisfied\n        && true\n    {\n        let runtime_lock",
                1,
            ),
        ),
        (
            "finalize-with-lock",
            body.replacen(
                "let finalization_gate = finalization_scope\n        && proxy_quiescent",
                "let finalization_gate = true || proxy_quiescent",
                1,
            ),
        ),
        (
            "missing-guardian-repair-fallback",
            body.replacen(
                "root_resume_or_run_emergency_route_repair(",
                "root_append_state(",
                1,
            ),
        ),
        (
            "candidate-stop-lost-on-guard-failure",
            body.replacen(
                "state.candidate_stopped = candidate_session_quiescent;",
                "state.candidate_stopped = candidate_session_quiescent && runtime_gate_satisfied;",
                1,
            ),
        ),
    ] {
        if mutant == body || verify_emergency_cleanup_body(&mutant).is_ok() {
            return Err(format!("emergency source test admitted {label} mutant"));
        }
    }
    let rollback = source_slice(
        source,
        "\nfn root_restore_driver_reload_and_verify_hal(",
        "\nfn process_start_identity(",
        "driver rollback reload/HAL recovery",
    )?;
    verify_driver_reload_journal_nonblocking_body(rollback)?;
    let fail_fast_reload_journal_mutant = rollback.replacen(
        "if let Err(error) = root_append_state(\"ROLLBACK_COREAUDIO_RELOADED\") {\n            outcome.diagnostics.push(format!(\n                \"driver rollback Core Audio journal failed: {error}\"\n            ));\n        }",
        "root_append_state(\"ROLLBACK_COREAUDIO_RELOADED\")?;",
        1,
    );
    if fail_fast_reload_journal_mutant == rollback
        || verify_driver_reload_journal_nonblocking_body(&fail_fast_reload_journal_mutant).is_ok()
    {
        return Err("emergency source test admitted reload journal failure suppressing HAL".to_owned());
    }
    Ok(())
}

fn verify_v6_restore_recovery_bodies(
    state: &str,
    normal_restore: &str,
    emergency: &str,
) -> Result<(), String> {
    for required in [
        "v6_restore_may_have_begun: bool",
        "recovery_complete: bool",
        "root_emergency_cleanup(self, pass_deadline)",
        "if self.recovery_complete",
    ] {
        if !state.contains(required) {
            return Err(format!("root owning recovery continuation changed: {required}"));
        }
    }
    verify_ordered_source_steps(
        normal_restore,
        "normal exact-v6 restore intent",
        &[
            "root_append_state(\"V6_RESTORE_MAY_HAVE_BEGUN\")?;",
            "state.v6_restore_may_have_begun = true;",
            "state.v6_stopped = false;",
            "runtime_lock.release()?;",
            "state.runtime_lock.take();",
            "run_uid_sealed(UID_EMERGENCY_V6_MODE, None)?;",
            "state.v6_restored = true;",
            "state.v6_restore_may_have_begun = false;",
        ],
    )?;
    verify_ordered_source_steps(
        emergency,
        "emergency partial-v6 convergence",
        &[
            "let restored_runtime_terminal = state.driver_restored",
            "let offline_recovery_required = !restored_runtime_terminal",
            "(!state.v6_stopped || state.v6_restore_may_have_begun)",
            "run_uid_sealed_until(UID_STOP_V6_MODE, None, absolute_deadline)",
            "state.v6_stopped = true;",
            "state.v6_restore_may_have_begun = false;",
            "state.v6_restore_may_have_begun = true;",
            "state.v6_stopped = false;",
            "guard.release()",
            "state.runtime_lock.take();",
            "run_uid_sealed_until(UID_EMERGENCY_V6_MODE, None, absolute_deadline)",
            "state.v6_restored = true;",
            "state.v6_restore_may_have_begun = false;",
            "state.recovery_complete = true;",
        ],
    )?;
    Ok(())
}

fn verify_v6_restore_recovery_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let state = source_slice(
        source,
        "\n#[derive(Debug)]\nstruct RootBrokerState {",
        "\nfn recovery_may_finalize_user_evidence(",
        "root owning recovery continuation",
    )?;
    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "normal root protocol",
    )?;
    let normal_restore = source_slice(
        protocol,
        "\n        } else if command == \"L1Ciab RESTORE_V6\"",
        "\n        } else if command == \"L1Ciab COMPLETE\"",
        "normal exact-v6 restore intent",
    )?;
    let emergency = source_slice(
        source,
        "\nfn root_emergency_cleanup(",
        "\nfn spawn_line_reader<",
        "emergency partial-v6 recovery",
    )?;
    verify_v6_restore_recovery_bodies(state, normal_restore, emergency)?;
    let early_unlock = swapped_source_steps(
        normal_restore,
        "state.v6_restore_may_have_begun = true;",
        "runtime_lock.release()?;",
    );
    if early_unlock == normal_restore
        || verify_v6_restore_recovery_bodies(state, &early_unlock, emergency).is_ok()
    {
        return Err("v6 restore source test admitted unlock before restore intent".to_owned());
    }
    let missing_restop = emergency.replacen(
        "(!state.v6_stopped || state.v6_restore_may_have_begun)",
        "!state.v6_stopped",
        1,
    );
    if missing_restop == emergency
        || verify_v6_restore_recovery_bodies(state, normal_restore, &missing_restop).is_ok()
    {
        return Err("v6 restore source test admitted partial bootstrap without re-stop".to_owned());
    }
    let restop_after_terminal_restore = emergency.replacen(
        "let offline_recovery_required = !restored_runtime_terminal",
        "let offline_recovery_required = true",
        1,
    );
    if restop_after_terminal_restore == emergency
        || verify_v6_restore_recovery_bodies(
            state,
            normal_restore,
            &restop_after_terminal_restore,
        )
        .is_ok()
    {
        return Err("v6 restore source test re-stopped a terminal restored generation".to_owned());
    }
    let dropped_owner = state.replacen("root_emergency_cleanup(self, pass_deadline)", "Ok(())", 1);
    if dropped_owner == state
        || verify_v6_restore_recovery_bodies(&dropped_owner, normal_restore, emergency).is_ok()
    {
        return Err("v6 restore source test admitted state Drop without recovery continuation".to_owned());
    }
    Ok(())
}

fn verify_generic_owned_session_body(body: &str) -> Result<(), String> {
    for required in [
        "ManagedChild::Owned(OwnedSessionChild::new(child, label))",
        "let cleanup_deadline = execution_deadline + Duration::from_secs(3);",
        "child.owned_mut()?",
        "reap_quiescent_owned_session(",
        "terminate_preconfigured_session(",
    ] {
        if !body.contains(required) {
            return Err(format!("generic retained-session cleanup changed: {required}"));
        }
    }
    Ok(())
}

fn verify_owned_session_lifecycle_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let owned = source_slice(
        source,
        "\n#[derive(Debug)]\nstruct OwnedSessionChild {",
        "\nfn push_session_diagnostic(",
        "owned retained-session wrapper",
    )?;
    for required in [
        "struct OwnedSessionChild {",
        "fn new(child: Child, label: &str) -> Self {",
        "impl Drop for OwnedSessionChild {",
        "match terminate_preconfigured_session(self, self.session, &self.label.clone(), deadline)",
    ] {
        if owned.matches(required).count() != 1 {
            return Err(format!("retained-session ownership contract changed: {required}"));
        }
    }
    let bounded = source_slice(
        source,
        "\nfn bounded_output_with_input_internal(",
        "\nfn command_output(",
        "generic bounded child ownership",
    )?;
    verify_generic_owned_session_body(bounded)?;
    let mutant = bounded.replacen(
        "ManagedChild::Owned(OwnedSessionChild::new(child, label))",
        "ManagedChild::Ordinary(child)",
        1,
    );
    if mutant == bounded || verify_generic_owned_session_body(&mutant).is_ok() {
        return Err("generic retained-session source test admitted raw Child ownership".to_owned());
    }
    let state = source_slice(
        source,
        "\n#[derive(Debug)]\nstruct RootBrokerState {",
        "\nfn recovery_may_finalize_user_evidence(",
        "root retained-session state",
    )?;
    for required in [
        "proxy_child: Option<OwnedSessionChild>",
        "candidate_child: Option<OwnedSessionChild>",
        "impl Drop for RootBrokerState {",
        "root_emergency_cleanup(self, pass_deadline)",
        "if self.recovery_complete {\n            return;\n        }\n        // Never let an incomplete",
    ] {
        if state.matches(required).count() != 1 {
            return Err(format!("root retained-session ownership changed: {required}"));
        }
    }
    for forbidden in [
        "self.candidate_child.take()",
        "self.proxy_child.take()",
        "self.proxy_capability.take()",
        "self.candidate_control.take()",
    ] {
        if state.contains(forbidden) {
            return Err(format!(
                "root Drop relinquishes retained ownership before recovery: {forbidden}"
            ));
        }
    }
    let premature_drop_mutant = state.replacen(
        "if self.recovery_complete {",
        "drop(self.proxy_child.take());\n        if self.recovery_complete {",
        1,
    );
    if premature_drop_mutant == state
        || !premature_drop_mutant.contains("self.proxy_child.take()")
    {
        return Err("root retained-ownership Drop mutant is not falsifiable".to_owned());
    }
    let guardian = source_slice(
        source,
        "\nstruct GuardianBroker {",
        "\nfn detach_root_broker_session(",
        "guardian retained-session state",
    )?;
    if guardian.matches("child: OwnedSessionChild").count() != 1
        || guardian.matches("impl Drop for GuardianBroker").count() != 1
    {
        return Err("guardian lost its retained-session ownership backstop".to_owned());
    }
    Ok(())
}

fn verify_ordered_source_steps(body: &str, label: &str, steps: &[&str]) -> Result<(), String> {
    let mut cursor = 0;
    for step in steps {
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("{label} step is absent or reordered: {step}"))?;
        cursor += offset + step.len();
    }
    Ok(())
}

fn swapped_source_steps(body: &str, first: &str, second: &str) -> String {
    body.replacen(first, "__OPENSTEAMER_FIRST_STEP__", 1)
        .replacen(second, first, 1)
        .replacen("__OPENSTEAMER_FIRST_STEP__", second, 1)
}

fn verify_runtime_lock_release_body(
    body: &str,
    label: &str,
    barrier: &str,
    release: &str,
    take: &str,
    terminal: &str,
) -> Result<(), String> {
    verify_ordered_source_steps(body, label, &[barrier, release, take, terminal])
}

fn verify_runtime_lock_ownership_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let release = source_slice(
        source,
        "\n    fn release(&mut self) -> Result<(), String> {",
        "\n}\n\nfn acquire_shared_lock_unowned_root(",
        "retained shared-lock release",
    )?;
    let preproof = release
        .find("self.require_named_identity()?;")
        .ok_or("shared-lock release lost its named/descriptor preproof")?;
    let unlock = release
        .find("libc_flock(self.file.as_raw_fd(), LOCK_UN)")
        .ok_or("shared-lock release lost its checked unlock")?;
    if preproof >= unlock || release.contains("fn release(self)") {
        return Err("shared-lock release consumes ownership before a fallible operation".to_owned());
    }
    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "normal runtime-lock protocol",
    )?;
    let candidate_release = source_slice(
        protocol,
        "\n        } else if command == \"L1Ciab RELEASE_CANDIDATE_GATE\" {",
        "\n        } else if command == \"L1Ciab PROBES_VERIFIED\"",
        "candidate-GO runtime-lock release",
    )?;
    let restore_release = source_slice(
        protocol,
        "\n        } else if command == \"L1Ciab RESTORE_V6\"",
        "\n        } else if command == \"L1Ciab COMPLETE\"",
        "exact-v6 runtime-lock release",
    )?;
    let normal_steps = (
        "require_runtime_mutation_guard_barrier_root(&runtime_lock)?;",
        "runtime_lock.release()?;",
        "state.runtime_lock.take();",
    );
    verify_runtime_lock_release_body(
        candidate_release,
        "candidate-GO runtime-lock",
        normal_steps.0,
        normal_steps.1,
        normal_steps.2,
        "root_release_candidate_gate(state)?",
    )?;
    verify_runtime_lock_release_body(
        restore_release,
        "exact-v6 runtime-lock",
        normal_steps.0,
        normal_steps.1,
        normal_steps.2,
        "run_uid_sealed(UID_EMERGENCY_V6_MODE, None)?",
    )?;
    for (label, body) in [
        ("candidate-GO", candidate_release),
        ("exact-v6", restore_release),
    ] {
        let mutant = swapped_source_steps(body, normal_steps.0, normal_steps.1);
        if mutant == body
            || verify_runtime_lock_release_body(
                &mutant,
                label,
                normal_steps.0,
                normal_steps.1,
                normal_steps.2,
                if label == "candidate-GO" {
                    "root_release_candidate_gate(state)?"
                } else {
                    "run_uid_sealed(UID_EMERGENCY_V6_MODE, None)?"
                },
            )
            .is_ok()
        {
            return Err(format!("runtime-lock source test admitted {label} unlock-before-barrier"));
        }
    }
    let emergency = source_slice(
        source,
        "\nfn root_emergency_cleanup(",
        "\nfn spawn_line_reader<",
        "emergency runtime-lock protocol",
    )?;
    let emergency_release = source_slice(
        emergency,
        "\n    if state.driver_restored && !state.v6_restored {",
        "\n    let finalization_gate =",
        "emergency exact-v6 runtime-lock release",
    )?;
    let emergency_steps = [
        "require_runtime_mutation_guard_barrier_root(guard)",
        "state.runtime_lock.as_mut()",
        "guard.release()",
        "state.runtime_lock.take();",
        "run_uid_sealed_until(UID_EMERGENCY_V6_MODE, None, absolute_deadline)",
    ];
    verify_ordered_source_steps(
        emergency_release,
        "emergency runtime-lock",
        &emergency_steps,
    )?;
    let mutant = swapped_source_steps(emergency_release, emergency_steps[0], emergency_steps[2]);
    if mutant == emergency_release
        || verify_ordered_source_steps(&mutant, "emergency runtime-lock", &emergency_steps).is_ok()
    {
        return Err("runtime-lock source test admitted emergency unlock-before-barrier".to_owned());
    }
    Ok(())
}

fn verify_guardian_absence_body(body: &str) -> Result<(), String> {
    for required in [
        "session_member_identities(tracked_pid, caller_deadline)?",
        "consecutive_empty_session_scans += 1;",
        "consecutive_empty_session_scans >= 2",
        "tracked guardian PID was reused before its SID became quiescent",
    ] {
        if !body.contains(required) {
            return Err(format!("guardian SID-quiescence contract changed: {required}"));
        }
    }
    Ok(())
}

fn verify_unbound_guardian_absence_body(body: &str) -> Result<(), String> {
    for required in [
        "Path::new(SEALED_GUARDIAN)",
        "Path::new(SEALED_VPIO_PROBE)",
        "ROUTE_GUARDIAN_SHA256",
        "VPIO_PROBE_SHA256",
        "libc_proc_listallpids",
        "let is_guardian = path == Path::new(SEALED_GUARDIAN);",
        "let is_vpio_child = path == Path::new(SEALED_VPIO_PROBE);",
        "process_executable_path(pid)? != path",
        "consecutive_empty_scans += 1;",
        "consecutive_empty_scans >= 2",
    ] {
        if !body.contains(required) {
            return Err(format!("unbound guardian/VPIO absence contract changed: {required}"));
        }
    }
    for forbidden in ["libc_kill(", "signal_session_members(", "process_group_exists("] {
        if body.contains(forbidden) {
            return Err(format!("unbound guardian absence gained signal authority: {forbidden}"));
        }
    }
    Ok(())
}

fn verify_resumable_guardian_repair_body(body: &str) -> Result<(), String> {
    for required in [
        "let route_recovery_started = Instant::now();",
        "GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS",
        "UID_SEALED_TEARDOWN_RESERVE_SECONDS",
        "GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS",
        "let evidence_deadline = route_recovery_deadline",
        "Duration::from_secs(GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS)",
        "stable_private_sha256_until(",
        "reconcile_guardian_repair_artifacts_until(&layout, helper_deadline)?;",
        "GuardianRepairArtifactState::RejectedAttemptCleared",
        "UID_ROUTE_REPAIR_HELPER_SECONDS + UID_SEALED_TEARDOWN_RESERVE_SECONDS",
        "let operation = existing_success.is_none().then(|| {",
        "run_uid_sealed_until(",
        "let proof = match existing_success",
        "reconcile_guardian_repair_artifacts_until(&layout, evidence_deadline)",
        "(None, Ok(_)) | (Some(Ok(())), Ok(_)) => Ok(()),",
        "(Some(Err(operation_error)), Ok(_)) => {",
    ] {
        if !body.contains(required) {
            return Err(format!("resumable guardian repair contract changed: {required}"));
        }
    }
    if body
        .matches("GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS")
        .count()
        != 2
        || body.matches("stable_private_sha256_until(").count() != 2
        || body
            .matches("reconcile_guardian_repair_artifacts_until(")
            .count()
            != 2
        || body.matches("run_uid_sealed_until(").count() != 1
        || body
            .matches("Duration::from_secs(GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS)")
            .count()
            != 1
    {
        return Err("resumable guardian repair proof counts changed".to_owned());
    }
    verify_ordered_source_steps(
        body,
        "resumable guardian repair",
        &[
            "let route_recovery_started = Instant::now();",
            "emergency route recovery lacks its full primitive deadline",
            "let route_recovery_deadline = std::cmp::min(",
            "let helper_deadline = route_recovery_deadline",
            "let evidence_deadline = route_recovery_deadline",
            "Duration::from_secs(GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS)",
            "stable_private_sha256_until(",
            "let initial_artifacts = reconcile_guardian_repair_artifacts_until(",
            "helper deadline reserve",
            "let operation = existing_success.is_none().then(|| {",
            "run_uid_sealed_until(",
            "let proof = match existing_success",
            "reconcile_guardian_repair_artifacts_until(&layout, evidence_deadline)",
            "stable_private_sha256_until(&layout.guardian_state, route_recovery_deadline)?",
            "match (operation, proof)",
        ],
    )
}

fn verify_guardian_repair_attempt_lifecycle_body(body: &str) -> Result<(), String> {
    for required in [
        "metadata.is_file()",
        "metadata.file_type().is_symlink()",
        "metadata.uid() != 501",
        "metadata.gid() != 20",
        "metadata.nlink() != 1",
        "metadata.mode() & 0o7777 != 0o600",
        "metadata.len() > 1_048_576",
        "stable_guardian_repair_attempt_until(attempt, deadline)?;",
        "root_append_state(&format!(",
        "fs::remove_file(attempt)",
        "sync_parent_directory(attempt)?;",
        "require_absent_no_follow(attempt, \"rejected guardian repair attempt after unlink\")?;",
        "require_absent_no_follow(result, \"published emergency route-repair result\")?;",
        "verify_guardian_evidence_until(\n        attempt,",
        "rename_exclusive(attempt, result)?;",
        "sync_parent_directory(result)?;",
        "require_absent_no_follow(attempt, \"guardian repair attempt after publication\")?;",
        "verify_guardian_evidence_until(\n        result,",
        "match fs::symlink_metadata(result)",
        "match fs::symlink_metadata(attempt)",
        "journal_and_clear_rejected_guardian_repair_attempt_until(",
    ] {
        if !body.contains(required) {
            return Err(format!("guardian repair attempt lifecycle changed: {required}"));
        }
    }
    if body.matches("fs::remove_file(attempt)").count() != 1
        || body.matches("rename_exclusive(attempt, result)?;").count() != 1
        || body.matches("sync_parent_directory(result)?;").count() != 3
        || body.contains("fs::remove_file(result)")
        || body.contains("remove_dir")
    {
        return Err("guardian repair attempt mutation scope changed".to_owned());
    }
    let cleanup = source_slice(
        body,
        "\nfn journal_and_clear_rejected_guardian_repair_attempt_until(",
        "\nfn publish_successful_guardian_repair_attempt_until(",
        "rejected guardian repair attempt cleanup",
    )?;
    verify_ordered_source_steps(
        cleanup,
        "rejected guardian repair attempt cleanup",
        &[
            "stable_guardian_repair_attempt_until(attempt, deadline)?;",
            "root_append_state(&format!(",
            "stable_guardian_repair_attempt_until(attempt, deadline)?;",
            "fs::remove_file(attempt)",
            "sync_parent_directory(attempt)?;",
            "require_absent_no_follow(attempt",
        ],
    )?;
    let publish = source_slice(
        body,
        "\nfn publish_successful_guardian_repair_attempt_until(",
        "\n#[derive(Debug, Eq, PartialEq)]\nenum GuardianRepairArtifactState",
        "successful guardian repair attempt publication",
    )?;
    verify_ordered_source_steps(
        publish,
        "successful guardian repair attempt publication",
        &[
            "require_absent_no_follow(result",
            "inspect_safe_guardian_repair_attempt(attempt)?;",
            "verify_guardian_evidence_until(\n        attempt,",
            "rename_exclusive(attempt, result)?;",
            "sync_parent_directory(result)?;",
            "require_absent_no_follow(attempt",
            "inspect_safe_guardian_repair_attempt(result)?",
            "verify_guardian_evidence_until(\n        result,",
        ],
    )?;
    let reconcile = source_slice(
        body,
        "\nfn reconcile_guardian_repair_artifacts_until(",
        "\nfn root_resume_or_run_emergency_route_repair(",
        "guardian repair artifact reconciliation",
    )?;
    let existing_canonical = source_slice(
        reconcile,
        "\n        Ok(_) => {",
        "\n    match fs::symlink_metadata(attempt)",
        "existing canonical guardian repair reconciliation",
    )?;
    verify_ordered_source_steps(
        existing_canonical,
        "existing canonical guardian repair durability",
        &[
            "require_absent_no_follow(attempt, \"attempt beside published guardian repair result\")?;",
            "sync_parent_directory(result)?;",
            "return verify_guardian_evidence_until(result, \"repair\", true, false, deadline)",
        ],
    )?;
    let recovered_canonical = source_slice(
        reconcile,
        "\"attempt beside recovered published guardian repair result\",",
        "\n                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {",
        "recovered canonical guardian repair reconciliation",
    )?;
    verify_ordered_source_steps(
        recovered_canonical,
        "recovered canonical guardian repair durability",
        &[
            "\"attempt beside recovered published guardian repair result\",",
            "sync_parent_directory(result)?;",
            "verify_guardian_evidence_until(",
        ],
    )?;
    verify_ordered_source_steps(
        reconcile,
        "guardian repair artifact reconciliation",
        &[
            "match fs::symlink_metadata(result)",
            "require_absent_no_follow(attempt, \"attempt beside published guardian repair result\")?;",
            "match fs::symlink_metadata(attempt)",
            "publish_successful_guardian_repair_attempt_until(attempt, result, deadline)",
            "match fs::symlink_metadata(result)",
            "journal_and_clear_rejected_guardian_repair_attempt_until(",
        ],
    )
}

fn verify_guardian_repair_execution_primitive_body(execution: &str) -> Result<(), String> {
    for summand in [
        "GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_SECONDS",
        "UID_ROUTE_REPAIR_HELPER_SECONDS",
        "UID_SEALED_TEARDOWN_RESERVE_SECONDS",
        "GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS",
    ] {
        if execution.matches(summand).count() != 1 {
            return Err(format!("guardian repair execution summand changed: {summand}"));
        }
    }
    Ok(())
}

fn verify_guardian_repair_reconciliation_maximum_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "guardian repair reconciliation maximum",
        &[
            "let existing_canonical_seconds = evidence_validation_seconds;",
            "let successful_publication_seconds = 2 * evidence_validation_seconds;",
            "let rejected_attempt_seconds = evidence_validation_seconds + 2 * attempt_hash_seconds;",
            "let recovered_canonical_seconds = 3 * evidence_validation_seconds;",
            "let mut maximum_seconds = existing_canonical_seconds;",
            "if successful_publication_seconds > maximum_seconds {",
            "if rejected_attempt_seconds > maximum_seconds {",
            "if recovered_canonical_seconds > maximum_seconds {",
            "maximum_seconds",
        ],
    )?;
    if body
        .matches("let existing_canonical_seconds = evidence_validation_seconds;")
        .count()
        != 1
        || body
        .matches("let successful_publication_seconds = 2 * evidence_validation_seconds;")
        .count()
        != 1
        || body
            .matches(
                "let rejected_attempt_seconds = evidence_validation_seconds + 2 * attempt_hash_seconds;",
            )
            .count()
            != 1
        || body
            .matches("let recovered_canonical_seconds = 3 * evidence_validation_seconds;")
            .count()
            != 1
        || body
            .matches("if successful_publication_seconds > maximum_seconds {")
            .count()
            != 1
        || body
            .matches("if rejected_attempt_seconds > maximum_seconds {")
            .count()
            != 1
        || body
            .matches("if recovered_canonical_seconds > maximum_seconds {")
            .count()
            != 1
    {
        return Err("guardian repair reconciliation maximum formula changed".to_owned());
    }
    Ok(())
}

fn verify_guardian_repair_preflight_minimum_body(minimum: &str) -> Result<(), String> {
    for summand in [
        "GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS",
        "+ GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS",
    ] {
        if minimum.matches(summand).count() != 1 {
            return Err(format!(
                "guardian repair preflight minimum summand changed: {summand}"
            ));
        }
    }
    Ok(())
}

fn verify_guardian_repair_reproof_minimum_body(minimum: &str) -> Result<(), String> {
    for summand in [
        "GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS",
        "+ GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS",
    ] {
        if minimum.matches(summand).count() != 1 {
            return Err(format!(
                "guardian repair reproof minimum summand changed: {summand}"
            ));
        }
    }
    Ok(())
}

fn verify_guardian_state_bind_minimum_body(minimum: &str) -> Result<(), String> {
    for summand in [
        "2 * GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS",
        "+ 2 * GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS",
    ] {
        if minimum.matches(summand).count() != 1 {
            return Err(format!(
                "guardian recovery state-bind minimum summand changed: {summand}"
            ));
        }
    }
    Ok(())
}

fn verify_guardian_route_recovery_primitive_body(route: &str) -> Result<(), String> {
    for summand in [
        "GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS",
        "GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS",
    ] {
        if route.matches(summand).count() != 1 {
            return Err(format!("guardian full route recovery summand changed: {summand}"));
        }
    }
    Ok(())
}

fn verify_emergency_route_recovery_summand_body(emergency: &str) -> Result<(), String> {
    if emergency
        .matches("+ GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS")
        .count()
        != 1
        || emergency.contains("+ UID_ROUTE_REPAIR_HELPER_SECONDS")
        || emergency.contains("+ GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS")
    {
        return Err("emergency deadline graph lost its named full route recovery primitive".to_owned());
    }
    Ok(())
}

fn verify_guardian_route_recovery_deadline_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let reconciliation_maximum_body = source_slice(
        source,
        "\nconst fn reviewed_guardian_repair_reconciliation_maximum(",
        "\nconst V6_HOST_SHA256:",
        "guardian repair reconciliation maximum",
    )?;
    verify_guardian_repair_reconciliation_maximum_body(reconciliation_maximum_body)?;
    let reconciliation_maximum = source_slice(
        source,
        "\nconst GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS: u64 =",
        "\nconst GUARDIAN_RECOVERY_STATE_BIND_MINIMUM_SECONDS:",
        "guardian repair reconciliation maximum binding",
    )?;
    for argument in [
        "reviewed_guardian_repair_reconciliation_maximum(",
        "GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS",
        "GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS",
    ] {
        if reconciliation_maximum.matches(argument).count() != 1 {
            return Err(format!(
                "guardian repair reconciliation maximum argument changed: {argument}"
            ));
        }
    }
    let bind_minimum = source_slice(
        source,
        "\nconst GUARDIAN_RECOVERY_STATE_BIND_MINIMUM_SECONDS: u64 =",
        "\nconst GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS:",
        "guardian recovery state-bind minimum",
    )?;
    verify_guardian_state_bind_minimum_body(bind_minimum)?;
    let preflight_minimum = source_slice(
        source,
        "\nconst GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_MINIMUM_SECONDS: u64 =",
        "\nconst GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_SECONDS:",
        "guardian repair attempt preflight minimum",
    )?;
    verify_guardian_repair_preflight_minimum_body(preflight_minimum)?;
    let reproof_minimum = source_slice(
        source,
        "\nconst GUARDIAN_REPAIR_REPROOF_MINIMUM_SECONDS: u64 =",
        "\nconst GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS:",
        "guardian repair reproof minimum",
    )?;
    verify_guardian_repair_reproof_minimum_body(reproof_minimum)?;
    let execution = source_slice(
        source,
        "\nconst GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS: u64 =",
        "\nconst GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS:",
        "guardian repair execution primitive",
    )?;
    verify_guardian_repair_execution_primitive_body(execution)?;
    let route = source_slice(
        source,
        "\nconst GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS: u64 =",
        "\nconst UID_STOP_HELPER_SECONDS:",
        "guardian route recovery primitive",
    )?;
    verify_guardian_route_recovery_primitive_body(route)?;
    let emergency = source_slice(
        source,
        "\nconst EMERGENCY_CLEANUP_PRIMITIVE_SECONDS: u64 =",
        "\nconst EMERGENCY_CLEANUP_ABSOLUTE_SECONDS:",
        "emergency route recovery deadline graph",
    )?;
    verify_emergency_route_recovery_summand_body(emergency)?;
    let missing_existing_validation_mutant = reconciliation_maximum_body.replacen(
        "let existing_canonical_seconds = evidence_validation_seconds;",
        "let existing_canonical_seconds = 0;",
        1,
    );
    if missing_existing_validation_mutant == reconciliation_maximum_body
        || verify_guardian_repair_reconciliation_maximum_body(
            &missing_existing_validation_mutant,
        )
        .is_ok()
    {
        return Err(
            "guardian repair preflight admitted existing canonical evidence without validation"
                .to_owned(),
        );
    }
    let one_success_validation_mutant = reconciliation_maximum_body.replacen(
        "let successful_publication_seconds = 2 * evidence_validation_seconds;",
        "let successful_publication_seconds = evidence_validation_seconds;",
        1,
    );
    if one_success_validation_mutant == reconciliation_maximum_body
        || verify_guardian_repair_reconciliation_maximum_body(&one_success_validation_mutant)
            .is_ok()
    {
        return Err(
            "guardian repair preflight admitted one success-evidence validation".to_owned(),
        );
    }
    let rejection_without_validation_mutant = reconciliation_maximum_body.replacen(
        "let rejected_attempt_seconds = evidence_validation_seconds + 2 * attempt_hash_seconds;",
        "let rejected_attempt_seconds = 2 * attempt_hash_seconds;",
        1,
    );
    if rejection_without_validation_mutant == reconciliation_maximum_body
        || verify_guardian_repair_reconciliation_maximum_body(
            &rejection_without_validation_mutant,
        )
        .is_ok()
    {
        return Err(
            "guardian repair preflight admitted rejected evidence without validation".to_owned(),
        );
    }
    let rejection_without_attempt_hash_mutant = reconciliation_maximum_body.replacen(
        "let rejected_attempt_seconds = evidence_validation_seconds + 2 * attempt_hash_seconds;",
        "let rejected_attempt_seconds = evidence_validation_seconds;",
        1,
    );
    if rejection_without_attempt_hash_mutant == reconciliation_maximum_body
        || verify_guardian_repair_reconciliation_maximum_body(
            &rejection_without_attempt_hash_mutant,
        )
        .is_ok()
    {
        return Err(
            "guardian repair preflight admitted rejected-attempt cleanup without two hashes"
                .to_owned(),
        );
    }
    let one_recovered_validation_mutant = reconciliation_maximum_body.replacen(
        "let recovered_canonical_seconds = 3 * evidence_validation_seconds;",
        "let recovered_canonical_seconds = 2 * evidence_validation_seconds;",
        1,
    );
    if one_recovered_validation_mutant == reconciliation_maximum_body
        || verify_guardian_repair_reconciliation_maximum_body(
            &one_recovered_validation_mutant,
        )
        .is_ok()
    {
        return Err(
            "guardian repair preflight admitted only two recovered-canonical validations"
                .to_owned(),
        );
    }
    let missing_recovered_maximum_mutant = reconciliation_maximum_body.replacen(
        "    if recovered_canonical_seconds > maximum_seconds {\n        maximum_seconds = recovered_canonical_seconds;\n    }\n",
        "",
        1,
    );
    if missing_recovered_maximum_mutant == reconciliation_maximum_body
        || verify_guardian_repair_reconciliation_maximum_body(
            &missing_recovered_maximum_mutant,
        )
        .is_ok()
    {
        return Err(
            "guardian repair preflight admitted a maximum that excludes recovery".to_owned(),
        );
    }
    let missing_preflight_reconciliation_mutant = preflight_minimum.replacen(
        "        + GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS;",
        ";",
        1,
    );
    if missing_preflight_reconciliation_mutant == preflight_minimum
        || verify_guardian_repair_preflight_minimum_body(
            &missing_preflight_reconciliation_mutant,
        )
        .is_ok()
    {
        return Err(
            "guardian repair preflight minimum omitted reconciliation".to_owned(),
        );
    }
    let missing_reproof_reconciliation_mutant = reproof_minimum.replacen(
        "GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS\n        + ",
        "",
        1,
    );
    if missing_reproof_reconciliation_mutant == reproof_minimum
        || verify_guardian_repair_reproof_minimum_body(
            &missing_reproof_reconciliation_mutant,
        )
        .is_ok()
    {
        return Err("guardian repair reproof minimum omitted reconciliation".to_owned());
    }
    let missing_reproof_state_hash_mutant = reproof_minimum.replacen(
        "        + GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS;",
        ";",
        1,
    );
    if missing_reproof_state_hash_mutant == reproof_minimum
        || verify_guardian_repair_reproof_minimum_body(&missing_reproof_state_hash_mutant).is_ok()
    {
        return Err("guardian repair reproof minimum omitted its final state hash".to_owned());
    }
    let missing_snapshot_validation_mutant = bind_minimum.replacen(
        " + 2 * GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS",
        " + GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS",
        1,
    );
    if missing_snapshot_validation_mutant == bind_minimum
        || verify_guardian_state_bind_minimum_body(&missing_snapshot_validation_mutant).is_ok()
    {
        return Err(
            "guardian state-bind minimum admitted one missing evidence validation".to_owned(),
        );
    }
    let missing_reproof_mutant = execution.replacen(
        "        + GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS;",
        ";",
        1,
    );
    if missing_reproof_mutant == execution
        || verify_guardian_repair_execution_primitive_body(&missing_reproof_mutant).is_ok()
    {
        return Err("guardian route deadline admitted a missing reproof summand".to_owned());
    }
    let missing_teardown_mutant = execution.replacen(
        "        + UID_SEALED_TEARDOWN_RESERVE_SECONDS",
        "",
        1,
    );
    if missing_teardown_mutant == execution
        || verify_guardian_repair_execution_primitive_body(&missing_teardown_mutant).is_ok()
    {
        return Err("guardian route deadline admitted a missing UID teardown summand".to_owned());
    }
    let missing_bind_mutant = route.replacen(
        "    GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS\n        + ",
        "    ",
        1,
    );
    if missing_bind_mutant == route
        || verify_guardian_route_recovery_primitive_body(&missing_bind_mutant).is_ok()
    {
        return Err("guardian route deadline admitted a missing state-bind summand".to_owned());
    }
    let direct_helper_mutant = emergency.replacen(
        "+ GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS",
        "+ UID_ROUTE_REPAIR_HELPER_SECONDS",
        1,
    );
    if direct_helper_mutant == emergency
        || verify_emergency_route_recovery_summand_body(&direct_helper_mutant).is_ok()
    {
        return Err("emergency route deadline admitted a helper-only summand".to_owned());
    }
    Ok(())
}

fn verify_guardian_finish_body(body: &str) -> Result<(), String> {
    for required in [
        "Duration::from_secs(GUARDIAN_FINISH_ABSOLUTE_SECONDS)",
        "Duration::from_secs(GUARDIAN_NATURAL_REAP_SECONDS)",
        "while Instant::now() < natural_deadline",
        "sleep_capped_by_absolute_deadline(natural_deadline",
        "let mut outcome = terminate_preconfigured_session(",
    ] {
        if !body.contains(required) {
            return Err(format!("guardian finish deadline contract changed: {required}"));
        }
    }
    let forced = body
        .split_once("let mut outcome = terminate_preconfigured_session(")
        .map(|(_, value)| value)
        .ok_or("guardian forced cleanup is absent")?;
    if !forced.contains("absolute_deadline") || forced.contains("natural_deadline") {
        return Err("guardian forced cleanup reused its expired natural-reap deadline".to_owned());
    }
    Ok(())
}

fn verify_proxy_stop_deadline_body(body: &str) -> Result<(), String> {
    for required in [
        "Duration::from_secs(PROXY_STOP_PRIMITIVE_SECONDS)",
        "checked_sub(Duration::from_secs(PROXY_FORCED_CLEANUP_RESERVE_SECONDS))",
        "Instant::now() + Duration::from_secs(graceful_seconds)",
        "forced_cleanup_boundary,",
        "phase_deadline,",
        "sleep_capped_by_absolute_deadline(deadline",
        "terminate_preconfigured_session(",
    ] {
        if !body.contains(required) {
            return Err(format!("proxy stop phase deadline changed: {required}"));
        }
    }
    let forced = body
        .split_once("let mut outcome = terminate_preconfigured_session(")
        .map(|(_, value)| value)
        .ok_or("proxy forced cleanup is absent")?;
    if !forced.contains("phase_deadline") {
        return Err("proxy forced cleanup can consume the whole emergency deadline".to_owned());
    }
    Ok(())
}

fn verify_guardian_finally_emergency_deadline_body(body: &str) -> Result<(), String> {
    if body
        .matches("Instant::now() + Duration::from_secs(ROUTES_REPAIRED_PRIMITIVE_SECONDS)")
        .count()
        != 1
        || body
            .matches("wait_for_tracked_guardian_generation_absence(\n                    state,\n                    guardian_quiescence_deadline,")
            .count()
            != 1
        || body
            .matches("wait_for_unbound_guardian_absence(guardian_quiescence_deadline)")
            .count()
            != 1
        || body
            .matches(
                "Instant::now()\n                    + Duration::from_secs(GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS)",
            )
            .count()
            != 1
        || body
            .matches(
                "bind_guardian_state_hash_for_recovery(state, guardian_state_bind_deadline)",
            )
            .count()
            != 1
        || body.contains(
            "wait_for_tracked_guardian_generation_absence(\n                    state,\n                    absolute_deadline,",
        )
        || body.contains("wait_for_unbound_guardian_absence(absolute_deadline)")
        || body.contains("bind_guardian_state_hash_for_recovery(state, absolute_deadline)")
    {
        return Err("guardian quiescence can consume the whole emergency deadline".to_owned());
    }
    Ok(())
}

fn verify_post_publish_transaction_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "post-publish guardian/root fence transaction",
        &[
            "\"L1Ciab PUBLISH\"",
            "\"LOCAL_ROOT_BROKER_DRIVER_PUBLISHED_AND_RELOADED\"",
            "let post_publish_fence_deadline = Instant::now()",
            "POST_PUBLISH_FENCE_PRIMITIVE_SECONDS",
            "let post_publish_local_deadline = post_publish_fence_deadline",
            "POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
            "let post_publish_guardian_deadline = post_publish_local_deadline",
            "POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS",
            "guardian.exchange_until(",
            "\"POST_PUBLISH_FENCE\"",
            "\"GUARDIAN_BROKER_POST_PUBLISH_FENCED\"",
            "post_publish_guardian_deadline,",
            "if Instant::now() >= post_publish_guardian_deadline",
            "let post_publish_evidence_deadline = post_publish_local_deadline",
            "GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS",
            "let post_publish_parent_sync_deadline = post_publish_evidence_deadline",
            "GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS",
            "sync_parent_directory(&layout.guardian_post_publish_fence_result)?;",
            "if Instant::now() >= post_publish_parent_sync_deadline",
            "let verified_post_publish_fence_hash = verify_guardian_evidence_until(",
            "\"broker-post-publish-fence\"",
            "post_publish_evidence_deadline,",
            "stable_private_sha256_until(",
            "post_publish_local_deadline,",
            "if post_publish_fence_hash != verified_post_publish_fence_hash",
            "root.exchange_until(",
            "L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}",
            "\"LOCAL_ROOT_BROKER_POST_PUBLISH_FENCED\"",
            "post_publish_fence_deadline,",
            "if Instant::now() >= post_publish_fence_deadline",
            "run_mirror_probe_until(mirror_probe_deadline)?;",
            "guardian.exchange(\"RUN_VPIO\", \"GUARDIAN_BROKER_VPIO_PASSED\")?;",
            "\"L1Ciab PROBES_VERIFIED\"",
            "\"L1Ciab RELEASE_CANDIDATE_GATE\"",
        ],
    )?;
    for exact in [
        "guardian.exchange_until(\n        \"POST_PUBLISH_FENCE\"",
        "sync_parent_directory(&layout.guardian_post_publish_fence_result)?;",
        "let verified_post_publish_fence_hash = verify_guardian_evidence_until(",
        "stable_private_sha256_until(\n        &layout.guardian_post_publish_fence_result,",
        "if post_publish_fence_hash != verified_post_publish_fence_hash",
        "L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}",
    ] {
        if body.matches(exact).count() != 1 {
            return Err(format!("post-publish transaction step count changed: {exact}"));
        }
    }
    if body.contains("verify_guardian_evidence(\n")
        || body.contains("stable_private_sha256(&layout.guardian_post_publish_fence_result)")
        || body.contains("post_publish_guardian_response_deadline")
        || body.contains("post_publish_root_response_deadline")
    {
        return Err("post-publish transaction restored a non-deadline helper".to_owned());
    }
    Ok(())
}

fn verify_post_publish_root_protocol_body(body: &str) -> Result<(), String> {
    let fence = source_slice(
        body,
        "command.strip_prefix(\"L1Ciab POST_PUBLISH_FENCE \")",
        "command == \"L1Ciab RELEASE_CANDIDATE_GATE\"",
        "root post-publish fence branch",
    )?;
    verify_ordered_source_steps(
        fence,
        "root post-publish fence acceptance",
        &[
            "!state.publication_requested",
            "state.postpublish_fenced",
            "state.postpublish_fence_hash.is_some()",
            "state.candidate_live",
            "verify_bound_dormant_candidate_gate(state.candidate.as_ref())?;",
            ".require_named_identity()?;",
            "require_v6_launchd_service_absent_root()?;",
            "require_no_capture_server_root()?;",
            "process_bsd_identity(pid)?",
            "fixed_guardian_state_hash()?.as_deref()",
            "verify_guardian_evidence(",
            "if observed != hash",
            "state.postpublish_fence_hash = Some(observed.clone());",
            "state.postpublish_fenced = true;",
            "POST_PUBLISH_DEFAULT_ROUTE_FENCE_PROVED",
            "LOCAL_ROOT_BROKER_POST_PUBLISH_FENCED",
        ],
    )?;
    let release = source_slice(
        body,
        "command == \"L1Ciab RELEASE_CANDIDATE_GATE\"",
        "command == \"L1Ciab PROBES_VERIFIED\"",
        "post-publish candidate release",
    )?;
    if !release.contains("|| !state.postpublish_fenced") {
        return Err("candidate release lost the post-publish fence gate".to_owned());
    }
    let probes = source_slice(
        body,
        "command == \"L1Ciab PROBES_VERIFIED\"",
        "command == \"L1Ciab CANDIDATE_STOPPED\"",
        "post-publish probe binding",
    )?;
    for required in [
        "&& state.postpublish_fenced",
        ".postpublish_fence_hash",
        "verify_guardian_post_publish_link(",
        "fence_hash != expected_fence_hash",
        "fixed_guardian_state_hash()?.as_deref()",
    ] {
        if !probes.contains(required) {
            return Err(format!("probe fence linkage changed: {required}"));
        }
    }
    let routes = source_slice(
        body,
        "command == \"L1Ciab ROUTES_REPAIRED\"",
        "command == \"L1Ciab ROLLBACK\"",
        "post-publish final route binding",
    )?;
    for required in [
        "&& state.postpublish_fenced",
        ".postpublish_fence_hash",
        "verify_guardian_post_publish_link(",
        "fence_hash != expected_fence_hash",
    ] {
        if !routes.contains(required) {
            return Err(format!("final fence linkage changed: {required}"));
        }
    }
    Ok(())
}

fn verify_post_publish_evidence_source_bodies(
    validator: &str,
    linker: &str,
) -> Result<(), String> {
    for required in [
        "import hashlib,json,sys",
        "type(c[k]) is int and 0<=c[k]<=2**64-1",
        "c['sequence']==c['inputNotifications']+c['outputNotifications']+c['systemOutputNotifications']",
        "hashlib.sha256(raw).hexdigest()",
        "preEpochBaselineArmed",
        "preEpochUIDMismatchOrReadFailure",
        "checkpoint(e)==v['listener']['postPublishEpochFingerprint']",
        "a==e and v['listener']['inputNotifications']==0",
    ] {
        if !validator.contains(required) {
            return Err(format!("guardian evidence validator lost: {required}"));
        }
    }
    for required in [
        "assert fe==le",
        "postPublishEpochFingerprint']==l['listener']['postPublishEpochFingerprint",
        "f['listener']['absoluteFinal']==fe",
        "l['listener']['outputNotifications']==0",
        "l['listener']['systemOutputNotifications']==0",
    ] {
        if !linker.contains(required) {
            return Err(format!("guardian evidence linker lost: {required}"));
        }
    }
    Ok(())
}

fn verify_post_publish_deadline_source_body(source: &str) -> Result<(), String> {
    for required in [
        "const POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS: u64 =\n    ROOT_BROKER_DEADMAN_SECONDS + POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS;",
        "const POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS: u64 =\n    ROOT_BROKER_DEADMAN_SECONDS + POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS;",
        "const POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS: u64 =\n    POST_PUBLISH_PARENT_SYNC_PRIMITIVE_SECONDS\n        + GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS\n        + GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS;",
        "const POST_PUBLISH_FENCE_PRIMITIVE_SECONDS: u64 = reviewed_post_publish_fence_minimum(",
        "POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS,",
        "POST_PUBLISH_PARENT_SYNC_PRIMITIVE_SECONDS,",
        "GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS,",
        "GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS,",
        "POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS,",
        "let post_publish_fence_wait = RootProtocolExpectedCommand::PostPublishFence.idle_seconds();",
        "let post_publish_fence_response = ROOT_BROKER_DEADMAN_SECONDS;",
        "+ post_publish_fence_wait\n        + post_publish_fence_response",
    ] {
        if !source.contains(required) {
            return Err(format!("post-publish fence deadline summand changed: {required}"));
        }
    }
    if POST_PUBLISH_FENCE_PRIMITIVE_SECONDS
        < POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS
            + POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS
            + POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS
    {
        return Err("post-publish fence primitive undercounts its runtime helpers".to_owned());
    }
    Ok(())
}

fn verify_post_publish_guardian_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let transaction = source_slice(
        source,
        "\nfn uid_proxy_transaction()",
        "\nfn uid_local_trial_guardian()",
        "post-publish UID transaction",
    )?;
    verify_post_publish_transaction_body(transaction)?;

    let broker = source_slice(
        source,
        "\nimpl GuardianBroker {",
        "\nfn detach_root_broker_session()",
        "guardian command allowlist",
    )?;
    if broker
        .matches("\"PING\" | \"CHECK\" | \"POST_PUBLISH_FENCE\" | \"RUN_VPIO\" | \"REPAIR\" | \"STOP\"")
        .count()
        != 2
    {
        return Err("guardian command allowlist lost POST_PUBLISH_FENCE".to_owned());
    }

    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "post-publish root protocol",
    )?;
    verify_post_publish_root_protocol_body(protocol)?;

    let validator = source_slice(
        source,
        "\nfn guardian_evidence_validation_program(",
        "\nfn verify_guardian_evidence(",
        "post-publish evidence validator",
    )?;
    let linker = source_slice(
        source,
        "\nfn verify_guardian_post_publish_link(",
        "\nfn verify_mirror_result(",
        "post-publish evidence linker",
    )?;
    verify_post_publish_evidence_source_bodies(validator, linker)?;
    verify_post_publish_deadline_source_body(source)?;

    for (label, mutant) in [
        (
            "missing-guardian-fence",
            transaction.replacen(
                "guardian.exchange_until(\n        \"POST_PUBLISH_FENCE\"",
                "guardian.exchange_until(\n        \"REMOVED_POST_PUBLISH_FENCE\"",
                1,
            ),
        ),
        (
            "missing-parent-fsync",
            transaction.replacen(
                "sync_parent_directory(&layout.guardian_post_publish_fence_result)?;",
                "",
                1,
            ),
        ),
        (
            "missing-local-validation",
            transaction.replacen(
                "let verified_post_publish_fence_hash = verify_guardian_evidence_until(",
                "let verified_post_publish_fence_hash = verify_guardian_evidence(",
                1,
            ),
        ),
        (
            "missing-hash-equality",
            transaction.replacen(
                "if post_publish_fence_hash != verified_post_publish_fence_hash",
                "if false",
                1,
            ),
        ),
        (
            "missing-root-bind",
            transaction.replacen(
                "L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}",
                "L1Ciab PING",
                1,
            ),
        ),
        (
            "nondeadline-local-hash",
            transaction.replacen(
                "stable_private_sha256_until(",
                "stable_private_sha256(",
                1,
            ),
        ),
        (
            "missing-local-reproof-reserve",
            transaction.replacen(
                "POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS,",
                "0,",
                1,
            ),
        ),
        (
            "underbounded-guardian-exchange",
            transaction.replacen(
                "post_publish_guardian_deadline,",
                "post_publish_guardian_deadline.checked_sub(Duration::from_secs(POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS)).unwrap(),",
                1,
            ),
        ),
        (
            "underbounded-root-exchange",
            transaction.replacen(
                "post_publish_fence_deadline,",
                "post_publish_fence_deadline.checked_sub(Duration::from_secs(POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS)).unwrap(),",
                1,
            ),
        ),
        (
            "nondeadline-root-bind",
            transaction.replacen("root.exchange_until(", "root.exchange_with_timeout(", 1),
        ),
    ] {
        if mutant == transaction || verify_post_publish_transaction_body(&mutant).is_ok() {
            return Err(format!("post-publish source test admitted {label} mutant"));
        }
    }
    let late_root_bind = swapped_source_steps(
        transaction,
        "L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}",
        "run_mirror_probe_until(mirror_probe_deadline)?;",
    );
    if late_root_bind == transaction
        || verify_post_publish_transaction_body(&late_root_bind).is_ok()
    {
        return Err("post-publish source test admitted mirror before root bind".to_owned());
    }
    let early_guardian_fence = swapped_source_steps(
        transaction,
        "\"L1Ciab PUBLISH\"",
        "\"POST_PUBLISH_FENCE\"",
    );
    if early_guardian_fence == transaction
        || verify_post_publish_transaction_body(&early_guardian_fence).is_ok()
    {
        return Err("post-publish source test admitted a fence before reload".to_owned());
    }
    let missing_root_state = protocol.replacen(
        "state.postpublish_fenced = true;",
        "state.postpublish_fenced = false;",
        1,
    );
    if missing_root_state == protocol
        || verify_post_publish_root_protocol_body(&missing_root_state).is_ok()
    {
        return Err("post-publish source test admitted an unstored root fence".to_owned());
    }
    let duplicate_root_fence = protocol.replacen(
        "|| state.postpublish_fenced",
        "|| false",
        1,
    );
    if duplicate_root_fence == protocol
        || verify_post_publish_root_protocol_body(&duplicate_root_fence).is_ok()
    {
        return Err("post-publish source test admitted a duplicate root fence".to_owned());
    }
    for (label, mutant) in [
        (
            "missing-callback-latch",
            validator.replacen(
                "preEpochUIDMismatchOrReadFailure",
                "ignoredPreEpochUIDMismatchOrReadFailure",
                1,
            ),
        ),
        (
            "missing-checkpoint-arithmetic",
            validator.replacen(
                "c['sequence']==c['inputNotifications']+c['outputNotifications']+c['systemOutputNotifications']",
                "True",
                1,
            ),
        ),
        (
            "missing-checkpoint-fingerprint",
            validator.replacen(
                "checkpoint(e)==v['listener']['postPublishEpochFingerprint']",
                "True",
                1,
            ),
        ),
        (
            "missing-exact-fence",
            validator.replacen(
                "a==e and v['listener']['inputNotifications']==0",
                "True",
                1,
            ),
        ),
    ] {
        if mutant == validator
            || verify_post_publish_evidence_source_bodies(&mutant, linker).is_ok()
        {
            return Err(format!("post-publish validator admitted {label} mutant"));
        }
    }
    let weak_link = linker.replacen(
        "postPublishEpochFingerprint']==l['listener']['postPublishEpochFingerprint",
        "ignoredPostPublishEpochFingerprint']==l['listener']['ignoredPostPublishEpochFingerprint",
        1,
    );
    if weak_link == linker
        || verify_post_publish_evidence_source_bodies(validator, &weak_link).is_ok()
    {
        return Err("post-publish linker admitted an unbound checkpoint fingerprint".to_owned());
    }
    let missing_deadline_summand = source.replacen(
        "+ post_publish_fence_wait\n        + post_publish_fence_response",
        "+ post_publish_fence_response",
        1,
    );
    if missing_deadline_summand == source
        || verify_post_publish_deadline_source_body(&missing_deadline_summand).is_ok()
    {
        return Err("post-publish source test admitted a missing deadline summand".to_owned());
    }
    Ok(())
}

fn verify_guardian_spawn_handoff_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let publisher = source_slice(
        source,
        "\nfn publish_guardian_spawned_on_root_capability(",
        "\nfn publish_guardian_reaped_on_root_capability(",
        "guardian spawn capability publisher",
    )?;
    for required in [
        "ROOT_LAUNCH_CAPABILITY_VERIFIED.get() != Some(&true)",
        "File::from_raw_fd(0)",
        "L1Ciab GUARDIAN_SPAWNED {pid}",
        "writer.flush()",
    ] {
        if publisher.matches(required).count() != 1 {
            return Err(format!("guardian spawn publisher contract changed: {required}"));
        }
    }
    let transaction = source_slice(
        source,
        "\nfn uid_proxy_transaction()",
        "\nfn uid_local_trial_guardian()",
        "guardian spawn capability transaction",
    )?;
    verify_ordered_source_steps(
        transaction,
        "guardian spawn capability transaction",
        &[
            "let mut guardian = spawn_persistent_guardian()?;",
            "let guardian_pid = guardian.child.id();",
            "publish_guardian_spawned_on_root_capability(guardian_pid)",
            "let transaction = (|| -> Result<(), String> {",
            "let mut root = RootClient::connect()?;",
            "let state_hash = stable_private_sha256(&layout.guardian_state)?;",
            "L1Ciab GUARDIAN_STATE {guardian_pid} {state_hash}",
        ],
    )?;
    if transaction.matches("publish_guardian_spawned_on_root_capability(").count() != 1 {
        return Err("guardian spawn capability is not published exactly once".to_owned());
    }
    let receiver = source_slice(
        source,
        "\nfn receive_guardian_spawned_capability_marker(",
        "\nfn receive_guardian_reaped_capability_marker(",
        "guardian spawn capability receiver",
    )?;
    verify_ordered_source_steps(
        receiver,
        "guardian spawn capability receiver",
        &[
            "strip_prefix(\"L1Ciab GUARDIAN_SPAWNED \")",
            "let start = verify_root_guardian_process(pid)?;",
            "let generation = process_bsd_identity(pid)?",
            "libc_getsid(pid as i32)",
            "state.guardian = Some((pid, start));",
            "state.guardian_generation = Some(generation);",
            "root_append_state(&format!(",
        ],
    )?;
    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "guardian spawn root protocol",
    )?;
    verify_ordered_source_steps(
        protocol,
        "guardian spawn root protocol",
        &[
            "root_send(&mut stream, \"LOCAL_ROOT_BROKER_READY\")?;",
            "receive_guardian_spawned_capability_marker(state, absolute_deadline)?;",
            "let responses = spawn_line_reader(",
            "command.strip_prefix(\"L1Ciab GUARDIAN_STATE \")",
            "state.guardian.is_none()",
            "let (pending_pid, pending_start) = state",
            "if pid != *pending_pid",
            "verify_guardian_evidence(",
            "Some(generation) != state.guardian_generation",
            "state.guardian_hash = Some(hash.to_owned());",
        ],
    )?;
    let guardian_state_branch = source_slice(
        protocol,
        "command.strip_prefix(\"L1Ciab GUARDIAN_STATE \")",
        "command == \"L1Ciab CANDIDATE_GATE\"",
        "guardian state completion",
    )?;
    if guardian_state_branch.contains("state.guardian = Some(")
        || guardian_state_branch.contains("state.guardian_generation = Some(")
    {
        return Err("fallible GUARDIAN_STATE validation can replace pending guardian ownership".to_owned());
    }
    let emergency = source_slice(
        source,
        "\nfn root_emergency_cleanup(",
        "\nfn spawn_line_reader<",
        "unbound guardian emergency proof",
    )?;
    verify_ordered_source_steps(
        emergency,
        "unbound guardian emergency proof",
        &[
            "let mut routes_satisfied = state.routes_repaired;",
            "wait_for_unbound_guardian_absence(guardian_quiescence_deadline)",
            "let guardian_state_bind_deadline = std::cmp::min(",
            "bind_guardian_state_hash_for_recovery(state, guardian_state_bind_deadline)",
            "require_no_guardian_route_artifacts_without_state()",
            "routes_satisfied = true;",
        ],
    )?;
    let missing_publish_mutant = transaction.replacen(
        "publish_guardian_spawned_on_root_capability(guardian_pid)",
        "Ok(())",
        1,
    );
    if missing_publish_mutant == transaction
        || verify_ordered_source_steps(
            &missing_publish_mutant,
            "guardian spawn capability transaction mutant",
            &[
                "let mut guardian = spawn_persistent_guardian()?;",
                "publish_guardian_spawned_on_root_capability(guardian_pid)",
                "let mut root = RootClient::connect()?;",
            ],
        )
        .is_ok()
    {
        return Err("guardian source test admitted an unreported spawned session".to_owned());
    }
    let late_store_mutant = swapped_source_steps(
        receiver,
        "state.guardian = Some((pid, start));",
        "root_append_state(&format!(",
    );
    if late_store_mutant == receiver
        || verify_ordered_source_steps(
            &late_store_mutant,
            "guardian pending store mutant",
            &[
                "state.guardian = Some((pid, start));",
                "state.guardian_generation = Some(generation);",
                "root_append_state(&format!(",
            ],
        )
        .is_ok()
    {
        return Err("guardian source test admitted journal failure before pending ownership".to_owned());
    }
    Ok(())
}

fn verify_guardian_finally_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let receiver = source_slice(
        source,
        "\nfn receive_guardian_reaped_capability_marker(",
        "\nfn stop_root_spawned_proxy(",
        "guardian capability receiver",
    )?;
    if receiver.matches("state.guardian_reaped_authenticated = true;").count() != 1 {
        return Err("guardian reap authentication has more than one setter".to_owned());
    }
    verify_ordered_source_steps(
        receiver,
        "guardian marker absolute deadline",
        &[
            "loop {",
            "remaining_phase_timeout(",
            "set_read_timeout(Some(timeout))",
            "capability.read(&mut byte)",
        ],
    )?;
    if receiver.matches("remaining_phase_timeout(").count() != 1 {
        return Err("guardian marker deadline is not recomputed for every byte".to_owned());
    }
    if receiver
        .matches("verify_guardian_evidence_until(")
        .count()
        != 1
        || !receiver.contains("guardian reap capability expired before authentication")
    {
        return Err("guardian marker authentication can overrun its evidence deadline".to_owned());
    }
    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "guardian root protocol",
    )?;
    if !protocol.contains("receive_guardian_reaped_capability_marker(state, absolute_deadline)?;")
        || protocol.contains("state.guardian_reaped_authenticated = true;")
    {
        return Err("normal guardian reap bypassed its root capability marker".to_owned());
    }
    let finish = source_slice(
        source,
        "\nfn finish_guardian(",
        "\nfn run_mirror_probe_until(",
        "guardian bounded finally",
    )?;
    verify_guardian_finish_body(finish)?;
    let finish_mutant = finish.replacen(
        "while Instant::now() < natural_deadline",
        "while Instant::now() < absolute_deadline",
        1,
    );
    if finish_mutant == finish || verify_guardian_finish_body(&finish_mutant).is_ok() {
        return Err("guardian source test admitted natural wait consuming forced cleanup".to_owned());
    }
    let proxy_stop = source_slice(
        source,
        "\nfn stop_root_spawned_proxy(",
        "\nfn root_emergency_cleanup(",
        "root proxy bounded cleanup",
    )?;
    verify_proxy_stop_deadline_body(proxy_stop)?;
    let proxy_mutant = proxy_stop.replacen(
        "Duration::from_secs(PROXY_STOP_PRIMITIVE_SECONDS)",
        "absolute_deadline.saturating_duration_since(Instant::now())",
        1,
    );
    if proxy_mutant == proxy_stop || verify_proxy_stop_deadline_body(&proxy_mutant).is_ok() {
        return Err("proxy source test admitted whole-emergency cleanup consumption".to_owned());
    }
    let emergency = source_slice(
        source,
        "\nfn root_emergency_cleanup(",
        "\nfn spawn_line_reader<",
        "guardian emergency fallback",
    )?;
    for required in [
        "let guardian_quiescence_deadline = std::cmp::min(",
        "Duration::from_secs(ROUTES_REPAIRED_PRIMITIVE_SECONDS)",
        "wait_for_tracked_guardian_generation_absence(\n                    state,\n                    guardian_quiescence_deadline,",
        "wait_for_unbound_guardian_absence(guardian_quiescence_deadline)",
        "let guardian_state_bind_deadline = std::cmp::min(",
        "Duration::from_secs(GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS)",
        "bind_guardian_state_hash_for_recovery(state, guardian_state_bind_deadline)",
        "root_resume_or_run_emergency_route_repair(",
        "EMERGENCY_ROUTES_REPAIRED_AFTER_GUARDIAN_ABSENCE",
    ] {
        if !emergency.contains(required) {
            return Err(format!("guardian emergency repair fallback changed: {required}"));
        }
    }
    let emergency_steps = [
        "let guardian_quiescence_deadline = std::cmp::min(",
        "wait_for_tracked_guardian_generation_absence(",
        "root_resume_or_run_emergency_route_repair(",
    ];
    verify_ordered_source_steps(emergency, "guardian emergency fallback", &emergency_steps)?;
    let emergency_mutant = swapped_source_steps(emergency, emergency_steps[0], emergency_steps[1]);
    if emergency_mutant == emergency
        || verify_ordered_source_steps(
            &emergency_mutant,
            "guardian emergency fallback",
            &emergency_steps,
        )
        .is_ok()
    {
        return Err("guardian source test admitted repair before generation/SID absence".to_owned());
    }
    let unbounded_guardian_wait_mutant = emergency.replacen(
        "wait_for_tracked_guardian_generation_absence(\n                    state,\n                    guardian_quiescence_deadline,",
        "wait_for_tracked_guardian_generation_absence(\n                    state,\n                    absolute_deadline,",
        1,
    );
    if unbounded_guardian_wait_mutant == emergency
        || verify_guardian_finally_emergency_deadline_body(&unbounded_guardian_wait_mutant).is_ok()
    {
        return Err("guardian source test admitted whole-emergency quiescence wait".to_owned());
    }
    let unbounded_guardian_bind_mutant = emergency.replacen(
        "bind_guardian_state_hash_for_recovery(state, guardian_state_bind_deadline)",
        "bind_guardian_state_hash_for_recovery(state, absolute_deadline)",
        1,
    );
    if unbounded_guardian_bind_mutant == emergency
        || verify_guardian_finally_emergency_deadline_body(&unbounded_guardian_bind_mutant).is_ok()
    {
        return Err("guardian source test admitted whole-emergency state binding".to_owned());
    }
    verify_guardian_finally_emergency_deadline_body(emergency)?;
    let repair = source_slice(
        source,
        "\nfn root_resume_or_run_emergency_route_repair(",
        "\nfn receive_guardian_reaped_capability_marker(",
        "resumable guardian emergency repair",
    )?;
    verify_resumable_guardian_repair_body(repair)?;
    let attempt_lifecycle = source_slice(
        source,
        "\n#[derive(Clone, Debug, Eq, PartialEq)]\nstruct GuardianRepairAttemptSnapshot",
        "\nfn receive_guardian_reaped_capability_marker(",
        "guardian repair attempt lifecycle",
    )?;
    verify_guardian_repair_attempt_lifecycle_body(attempt_lifecycle)?;
    let unsafe_partial_mutant = attempt_lifecycle.replacen(
        "metadata.len() > 1_048_576",
        "false",
        1,
    );
    if unsafe_partial_mutant == attempt_lifecycle
        || verify_guardian_repair_attempt_lifecycle_body(&unsafe_partial_mutant).is_ok()
    {
        return Err("guardian source test admitted an unbounded partial attempt".to_owned());
    }
    let unjournaled_clear_mutant = swapped_source_steps(
        attempt_lifecycle,
        "root_append_state(&format!(",
        "fs::remove_file(attempt)",
    );
    if unjournaled_clear_mutant == attempt_lifecycle
        || verify_guardian_repair_attempt_lifecycle_body(&unjournaled_clear_mutant).is_ok()
    {
        return Err("guardian source test admitted unlink before durable attempt summary".to_owned());
    }
    let poisoning_partial_mutant = attempt_lifecycle.replacen(
        "let digest = journal_and_clear_rejected_guardian_repair_attempt_until(\n                                attempt, deadline,\n                            )?;",
        "return Err(success_error);",
        1,
    );
    if poisoning_partial_mutant == attempt_lifecycle
        || verify_guardian_repair_attempt_lifecycle_body(&poisoning_partial_mutant).is_ok()
    {
        return Err("guardian source test admitted a partial attempt poisoning all retries".to_owned());
    }
    let unsynced_recovered_canonical_mutant = attempt_lifecycle.replacen(
        "\"attempt beside recovered published guardian repair result\",\n                            )?;\n                            sync_parent_directory(result)?;",
        "\"attempt beside recovered published guardian repair result\",\n                            )?;",
        1,
    );
    if unsynced_recovered_canonical_mutant == attempt_lifecycle
        || verify_guardian_repair_attempt_lifecycle_body(&unsynced_recovered_canonical_mutant)
            .is_ok()
    {
        return Err("guardian source test admitted recovered canonical evidence without parent fsync"
            .to_owned());
    }
    let uid_repair = source_slice(
        source,
        "\nfn uid_emergency_route_repair(",
        "\nfn uid_emergency_restore_v6(",
        "UID emergency repair attempt writer",
    )?;
    for required in [
        "require_absent_no_follow(\n        &layout.guardian_emergency_repair_result,",
        "require_absent_no_follow(\n        &layout.guardian_emergency_repair_attempt_result,",
        "let result = layout\n        .guardian_emergency_repair_attempt_result",
        "verify_guardian_evidence(\n        &layout.guardian_emergency_repair_attempt_result,",
    ] {
        if uid_repair.matches(required).count() != 1 {
            return Err(format!("UID guardian attempt output contract changed: {required}"));
        }
    }
    let rerun_existing_result_mutant = repair.replacen(
        "let operation = existing_success.is_none().then(|| {",
        "let operation = true.then(|| {",
        1,
    );
    if rerun_existing_result_mutant == repair
        || verify_resumable_guardian_repair_body(&rerun_existing_result_mutant).is_ok()
    {
        return Err("guardian source test retried a helper after exact durable evidence".to_owned());
    }
    let unbounded_route_mutant = repair.replacen(
        "GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS",
        "EMERGENCY_CLEANUP_ABSOLUTE_SECONDS",
        1,
    );
    if unbounded_route_mutant == repair
        || verify_resumable_guardian_repair_body(&unbounded_route_mutant).is_ok()
    {
        return Err("guardian source test admitted a whole-emergency route deadline".to_owned());
    }
    let missing_final_hash_reserve_mutant = repair.replacen(
        "Duration::from_secs(GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS)",
        "Duration::from_secs(0)",
        1,
    );
    if missing_final_hash_reserve_mutant == repair
        || verify_resumable_guardian_repair_body(&missing_final_hash_reserve_mutant).is_ok()
    {
        return Err("guardian source test admitted a missing final state-hash reserve".to_owned());
    }
    let unbound_absence = source_slice(
        source,
        "\nfn unbound_guardian_generations(",
        "\nfn wait_for_tracked_guardian_generation_absence(",
        "unbound guardian/VPIO quiescence",
    )?;
    verify_unbound_guardian_absence_body(unbound_absence)?;
    let missed_vpio_mutant = unbound_absence.replacen(
        "let is_vpio_child = path == Path::new(SEALED_VPIO_PROBE);",
        "let is_vpio_child = false;",
        1,
    );
    if missed_vpio_mutant == unbound_absence
        || verify_unbound_guardian_absence_body(&missed_vpio_mutant).is_ok()
    {
        return Err("guardian source test admitted an orphaned unbound VPIO child".to_owned());
    }
    let first_empty_unbound_mutant = unbound_absence.replacen(
        "consecutive_empty_scans >= 2",
        "consecutive_empty_scans >= 1",
        1,
    );
    if first_empty_unbound_mutant == unbound_absence
        || verify_unbound_guardian_absence_body(&first_empty_unbound_mutant).is_ok()
    {
        return Err("guardian source test admitted a one-scan unbound absence proof".to_owned());
    }
    let guardian_absence = source_slice(
        source,
        "\nfn wait_for_tracked_guardian_generation_absence(",
        "\nfn root_resume_or_run_emergency_route_repair(",
        "guardian generation/SID quiescence",
    )?;
    verify_guardian_absence_body(guardian_absence)?;
    let orphan_mutant = guardian_absence.replacen(
        "consecutive_empty_session_scans >= 2",
        "consecutive_empty_session_scans >= 1",
        1,
    );
    if orphan_mutant == guardian_absence
        || verify_guardian_absence_body(&orphan_mutant).is_ok()
    {
        return Err("guardian SID-quiescence orphan-descendant mutant was not falsifiable".to_owned());
    }
    let transaction = source_slice(
        source,
        "\nfn uid_proxy_transaction()",
        "\nfn uid_local_trial_guardian()",
        "guardian proxy finally",
    )?;
    if transaction.matches("finish_guardian(&mut guardian)").count() != 3
        || transaction.matches("publish_guardian_reaped_on_root_capability").count() != 3
    {
        return Err("UID proxy lost its explicit retained-guardian finally/marker path".to_owned());
    }
    let transaction_steps = [
        "finish_guardian(&mut guardian)",
        "publish_guardian_reaped_on_root_capability",
        "finish_guardian(&mut guardian)",
        "publish_guardian_reaped_on_root_capability",
        "finish_guardian(&mut guardian)",
        "publish_guardian_reaped_on_root_capability",
    ];
    verify_ordered_source_steps(transaction, "guardian proxy finally", &transaction_steps)?;
    let transaction_mutant = swapped_source_steps(
        transaction,
        transaction_steps[0],
        transaction_steps[1],
    );
    if transaction_mutant == transaction
        || verify_ordered_source_steps(
            &transaction_mutant,
            "guardian proxy finally",
            &transaction_steps,
        )
        .is_ok()
    {
        return Err("guardian source test admitted marker publication before sole reap".to_owned());
    }
    Ok(())
}

fn verify_mirror_json_deadline_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "mirror JSON absolute deadline",
        &[
            ".checked_duration_since(Instant::now())",
            ".checked_sub(Duration::from_secs(MIRROR_PROBE_TEARDOWN_SECONDS))",
            "Duration::from_secs(maximum_seconds)",
            "if !output.status.success() || Instant::now() >= deadline",
        ],
    )?;
    if body.contains("maximum_seconds + MIRROR_PROBE_TEARDOWN_SECONDS") {
        return Err("mirror JSON helper restored a zero-handoff full-reserve check".to_owned());
    }
    Ok(())
}

fn verify_mirror_probe_deadline_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "mirror probe full transitive deadline",
        &[
            "let entry_deadline = Instant::now()",
            "MIRROR_PROBE_PRIMITIVE_SECONDS",
            "if outer_deadline < entry_deadline",
            "let deadline = std::cmp::min(outer_deadline, entry_deadline);",
            "let stderr_write_deadline = deadline",
            "MIRROR_PROBE_JSON_PRIMITIVE_SECONDS",
            "let stdout_write_deadline = stderr_write_deadline",
            "MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS",
            "let execution_deadline = stdout_write_deadline",
            "MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS",
            "let hash_deadline = execution_deadline",
            "MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS",
            "let observed_hash = sha256_until(",
            "MIRROR_PROBE_HASH_SECONDS",
            "if observed_hash != MIRROR_PROBE_SHA256 || Instant::now() >= hash_deadline",
            "let execution_remaining = execution_deadline",
            ".checked_duration_since(Instant::now())",
            ".checked_sub(Duration::from_secs(MIRROR_PROBE_TEARDOWN_SECONDS))",
            "Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS)",
            "let output = bounded_output(",
            "if Instant::now() >= execution_deadline",
            "write_new_private_bytes(&layout.mirror_stdout, &output.stdout)?;",
            "if Instant::now() >= stdout_write_deadline",
            "write_new_private_bytes(&layout.mirror_stderr, &output.stderr)?;",
            "if Instant::now() >= stderr_write_deadline",
            "verify_mirror_result_until(&layout.mirror_result, deadline)?;",
            "if Instant::now() >= deadline",
        ],
    )?;
    if body.contains("require_hash(Path::new(SEALED_MIRROR_PROBE)")
        || body.contains("verify_mirror_result(&layout.mirror_result)")
        || body.matches("write_new_private_bytes(").count() != 2
    {
        return Err("mirror probe restored an unbounded transitive helper".to_owned());
    }
    Ok(())
}

fn verify_live_guardian_heartbeat_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "live guardian/root heartbeat reserve",
        &[
            "let local_deadline = std::cmp::min(",
            "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
            "let guardian_deadline = local_deadline",
            "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
            "let first_root_deadline = guardian_deadline",
            "LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS",
            "root.exchange_until(",
            "first_root_deadline,",
            "guardian.exchange_until(",
            "guardian_deadline,",
            "Duration::from_secs(LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS)",
            "if Instant::now() >= guardian_deadline",
            "root.exchange_until(",
            "local_deadline,",
            "if Instant::now() >= local_deadline",
        ],
    )?;
    if body.matches("root.exchange_until(").count() != 2
        || body.matches("guardian.exchange_until(").count() != 1
        || body.contains("root.ping()?")
        || body.contains("guardian.exchange(\"PING\"")
    {
        return Err("live guardian heartbeat lost its bracketed root keepalive".to_owned());
    }
    Ok(())
}

fn verify_live_arm_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "live-arm evidence and first heartbeat",
        &[
            "let health_deadline = deadline",
            "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
            "let evidence_deadline = health_deadline",
            "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
            "let journal_deadline = evidence_deadline",
            "LIVE_ARM_SINGLE_EVIDENCE_WRITE_PRIMITIVE_SECONDS",
            "append_journal(layout,",
            "if Instant::now() >= journal_deadline",
            "append_private_line(",
            "if Instant::now() >= evidence_deadline",
            "root.request_until(",
            "health_deadline,",
            "run_live_guardian_heartbeat_until(root, guardian, deadline)?;",
            "if Instant::now() >= deadline",
        ],
    )?;
    if body.matches("append_journal(").count() != 1
        || body.matches("append_private_line(").count() != 1
        || body.matches("root.request_until(").count() != 1
        || body.matches("run_live_guardian_heartbeat_until(").count() != 1
    {
        return Err("live-arm transition lost an exact evidence/health/heartbeat step".to_owned());
    }
    Ok(())
}

fn verify_root_global_deadline_graph_body(body: &str) -> Result<(), String> {
    for required in [
        "let gate_to_prestop_wait = RootProtocolExpectedCommand::PrestopFence.idle_seconds();",
        "let post_stop_ping_wait = RootProtocolExpectedCommand::PostStopPing.idle_seconds();",
        "let post_publish_fence_wait = RootProtocolExpectedCommand::PostPublishFence.idle_seconds();",
        "let post_fence_second_ping_wait = RootProtocolExpectedCommand::PostMirrorPing.idle_seconds();",
        "let probes_to_release_wait = RootProtocolExpectedCommand::CandidateRelease.idle_seconds();",
        "let live_arm = LIVE_ARM_PRIMITIVE_SECONDS;",
        "let trial_with_final_heartbeat = 600 + LIVE_ITERATION_OVERHANG_SECONDS;",
        "let guardian_reaped_transition = GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS;",
        "let complete_protocol_sum = guardian_lifetime_sum\n        + routes_repaired",
        "let stop_phase_sum = LIVE_ITERATION_OVERHANG_SECONDS\n        + candidate_stop\n        + guardian_reaped_transition",
        "|| complete_protocol_sum != 29_534",
        "|| root_lifecycle_ceiling != 72_209",
        "|| START_READY_SECONDS < UID_ADMISSION_SECONDS + start_phase_sum + 600",
        "|| STOP_COMPLETE_SECONDS < stop_phase_sum + 600",
    ] {
        if body.matches(required).count() != 1 {
            return Err(format!("root global deadline graph changed: {required}"));
        }
    }
    Ok(())
}

fn verify_root_idle_deadline_constants_body(body: &str) -> Result<(), String> {
    for required in [
        "const ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS: u64 = POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS;",
        "const MIRROR_PROBE_HASH_PRIMITIVE_SECONDS: u64 =\n    MIRROR_PROBE_HASH_SECONDS + MIRROR_PROBE_TEARDOWN_SECONDS;",
        "const MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS: u64 =\n    MIRROR_PROBE_EXECUTION_SECONDS + MIRROR_PROBE_TEARDOWN_SECONDS;",
        "const MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS: u64 =\n    2 * MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS;",
        "const MIRROR_PROBE_JSON_PRIMITIVE_SECONDS: u64 =\n    MIRROR_PROBE_JSON_SECONDS + MIRROR_PROBE_TEARDOWN_SECONDS;",
        "const MIRROR_PROBE_PRIMITIVE_SECONDS: u64 = reviewed_mirror_probe_minimum(\n    MIRROR_PROBE_HASH_PRIMITIVE_SECONDS,\n    MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS,\n    MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS,\n    MIRROR_PROBE_JSON_PRIMITIVE_SECONDS,\n);",
        "const MIRROR_PROBE_CALL_HANDOFF_SECONDS: u64 = 1;",
        "const MIRROR_PROBE_CALL_PRIMITIVE_SECONDS: u64 =\n    MIRROR_PROBE_CALL_HANDOFF_SECONDS + MIRROR_PROBE_PRIMITIVE_SECONDS;",
        "const LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS: u64 =\n    LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS + LIVE_GUARDIAN_TRANSCRIPT_PRIMITIVE_SECONDS;",
        "const LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS: u64 =\n    2 * LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS + LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS;",
        "const LIVE_ITERATION_OVERHANG_SECONDS: u64 =\n    LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS + LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS;",
        "const LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS: u64 =\n    2 * LIVE_ARM_SINGLE_EVIDENCE_WRITE_PRIMITIVE_SECONDS;",
        "const LIVE_ARM_PRIMITIVE_SECONDS: u64 =\n    LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS + LIVE_ITERATION_OVERHANG_SECONDS;",
        "const ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
        "const ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
        "const ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS\n        + POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS\n        + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
        "const ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS\n        + MIRROR_PROBE_CALL_PRIMITIVE_SECONDS\n        + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
        "const ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
        "const GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS: u64 = 5;",
        "const ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS: u64 = 2\n    * POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS\n    + GUARDIAN_FINISH_ABSOLUTE_SECONDS\n    + GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS\n    + 2 * ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
        "const GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS: u64 =\n    ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS + ROOT_BROKER_DEADMAN_SECONDS;",
    ] {
        if !body.contains(required) {
            return Err(format!("root next-command idle summand changed: {required}"));
        }
    }
    Ok(())
}

fn verify_root_protocol_expected_command_body(body: &str) -> Result<(), String> {
    for required in [
        "Self::PrestopFence => ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS",
        "Self::PostStopPing => ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS",
        "Self::PostPublishFence => ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS",
        "Self::PostMirrorPing => ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS",
        "Self::CandidateRelease => ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS",
        "Self::GuardianReaped => ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS,",
        "| Self::Live\n            | Self::RoutesRepaired",
        "Self::PrestopFence => command == \"L1Ciab PRESTOP_FENCE\",",
        "Self::PostPublishFence => command.starts_with(\"L1Ciab POST_PUBLISH_FENCE \"),",
        "Self::CandidateRelease => command == \"L1Ciab RELEASE_CANDIDATE_GATE\",",
        "Self::GuardianReaped => command.starts_with(\"L1Ciab GUARDIAN_REAPED \"),",
        "Self::Live => {\n                command == \"L1Ciab PING\"\n                    || command.starts_with(\"L1Ciab CANDIDATE_HEALTH \")\n                    || command == \"L1Ciab CANDIDATE_STOPPED\"\n            }",
        "Self::Publish => Self::PostPublishFence",
        "Self::PostPublishFence => Self::PostFencePing",
        "Self::PostFencePing => Self::PostMirrorPing",
        "Self::PostMirrorPing => Self::ProbesVerified",
        "Self::ProbesVerified => Self::CandidateRelease",
        "Self::CandidateRelease => Self::Live",
        "Self::Live if command == \"L1Ciab CANDIDATE_STOPPED\" => Self::GuardianReaped",
        "Self::Live => Self::Live",
    ] {
        if body.matches(required).count() != 1 {
            return Err(format!("root expected-command phase changed: {required}"));
        }
    }
    Ok(())
}

fn verify_root_protocol_idle_loop_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "root state-specific next-command deadline",
        &[
            "let mut expected_command = RootProtocolExpectedCommand::GuardianState;",
            "Duration::from_secs(expected_command.idle_seconds())",
            "responses.recv_timeout(timeout)",
            "if !expected_command.accepts(&command)",
            "root_send(&mut stream, &response)?;",
            "expected_command = expected_command.after(&command)?;",
        ],
    )?;
    if body.contains("Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),\n            remaining,") {
        return Err("root protocol restored its unconditional 75s receive timeout".to_owned());
    }
    Ok(())
}

fn verify_root_idle_transaction_body(body: &str) -> Result<(), String> {
    verify_ordered_source_steps(
        body,
        "root idle UID transaction linkage",
        &[
            "let mirror_probe_deadline = Instant::now()",
            ".checked_add(Duration::from_secs(MIRROR_PROBE_CALL_PRIMITIVE_SECONDS))",
            "run_mirror_probe_until(mirror_probe_deadline)?;",
            "let live_arm_deadline = Instant::now()",
            "LIVE_ARM_PRIMITIVE_SECONDS",
            "arm_live_trial_until(",
            "let heartbeat_deadline = Instant::now()",
            "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
            "run_live_guardian_heartbeat_until(",
            "let guardian_reaped_transition_deadline = Instant::now()",
            "GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS",
            "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline",
            "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
            "guardian.exchange(\"REPAIR\", \"GUARDIAN_BROKER_REPAIRED\")?;",
            "publish_guardian_reaped_on_root_capability(guardian_pid)?;",
            "if !guardian_outcome.diagnostics.is_empty()",
            "GUARDIAN_REAPED_WITH_DIAGNOSTICS {}",
            "if Instant::now() >= guardian_reaped_command_deadline",
            "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
            "guardian_reaped_transition_deadline,",
            "\"guardian-reaped root acknowledgement\"",
            "if Instant::now() >= guardian_reaped_transition_deadline",
        ],
    )?;
    for exact in [
        "run_mirror_probe_until(mirror_probe_deadline)?;",
        "arm_live_trial_until(",
        "run_live_guardian_heartbeat_until(",
        "publish_guardian_reaped_on_root_capability(guardian_pid)?;",
    ] {
        if body.matches(exact).count() != 1 {
            return Err(format!("root idle transaction exact step changed: {exact}"));
        }
    }
    Ok(())
}

fn verify_root_protocol_idle_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let constants = source_slice(
        source,
        "const ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS:",
        "const GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS:",
        "root next-command idle constants",
    )?;
    verify_root_idle_deadline_constants_body(constants)?;
    let mirror_json = source_slice(
        source,
        "\nfn verify_json_contract_until(",
        "\nfn mirror_result_contract_program(",
        "mirror JSON deadline helper",
    )?;
    verify_mirror_json_deadline_body(mirror_json)?;
    let mirror_probe = source_slice(
        source,
        "\nfn run_mirror_probe_until(",
        "\nfn run_live_guardian_heartbeat_until(",
        "mirror probe absolute deadline",
    )?;
    verify_mirror_probe_deadline_body(mirror_probe)?;
    let live_heartbeat = source_slice(
        source,
        "\nfn run_live_guardian_heartbeat_until(",
        "\nfn arm_live_trial_until(",
        "live guardian/root heartbeat",
    )?;
    verify_live_guardian_heartbeat_body(live_heartbeat)?;
    let live_arm = source_slice(
        source,
        "\nfn arm_live_trial_until(",
        "\nfn stop_request_present()",
        "live-arm evidence/health transition",
    )?;
    verify_live_arm_body(live_arm)?;
    let expected = source_slice(
        source,
        "\nenum RootProtocolExpectedCommand {",
        "\nfn root_protocol(",
        "root protocol expected-command model",
    )?;
    verify_root_protocol_expected_command_body(expected)?;
    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "root protocol state-specific idle loop",
    )?;
    verify_root_protocol_idle_loop_body(protocol)?;
    let transaction = source_slice(
        source,
        "\nfn uid_proxy_transaction()",
        "\nfn uid_local_trial_guardian()",
        "root idle UID transaction linkage",
    )?;
    verify_ordered_source_steps(
        transaction,
        "root idle UID transaction linkage",
        &[
            "let mirror_probe_deadline = Instant::now()",
            ".checked_add(Duration::from_secs(MIRROR_PROBE_CALL_PRIMITIVE_SECONDS))",
            "run_mirror_probe_until(mirror_probe_deadline)?;",
            "let live_arm_deadline = Instant::now()",
            "LIVE_ARM_PRIMITIVE_SECONDS",
            "arm_live_trial_until(",
            "let heartbeat_deadline = Instant::now()",
            "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
            "run_live_guardian_heartbeat_until(",
            "let guardian_reaped_transition_deadline = Instant::now()",
            "GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS",
            "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline",
            "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
            "guardian.exchange(\"REPAIR\", \"GUARDIAN_BROKER_REPAIRED\")?;",
            "publish_guardian_reaped_on_root_capability(guardian_pid)?;",
            "if !guardian_outcome.diagnostics.is_empty()",
            "GUARDIAN_REAPED_WITH_DIAGNOSTICS {}",
            "if Instant::now() >= guardian_reaped_command_deadline",
            "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
            "guardian_reaped_transition_deadline,",
            "\"guardian-reaped root acknowledgement\"",
            "if Instant::now() >= guardian_reaped_transition_deadline",
        ],
    )?;
    for exact in [
        "run_mirror_probe_until(mirror_probe_deadline)?;",
        "arm_live_trial_until(",
        "run_live_guardian_heartbeat_until(",
        "publish_guardian_reaped_on_root_capability(guardian_pid)?;",
    ] {
        if transaction.matches(exact).count() != 1 {
            return Err(format!("root idle transaction exact step changed: {exact}"));
        }
    }
    let global_graph = source_slice(
        source,
        "\nfn self_test()",
        "\nfn verify_root_broker_deadline_body(",
        "root global deadline graph",
    )?;
    verify_root_global_deadline_graph_body(global_graph)?;
    let root_deadline_constants = source_slice(
        source,
        "const ROOT_BROKER_DEADMAN_SECONDS:",
        "const ROOT_PROTOCOL_ABSOLUTE_SECONDS:",
        "root broker absolute ceiling constant",
    )?;
    if root_deadline_constants
        .matches("const ROOT_BROKER_ABSOLUTE_SECONDS: u64 = 73_000;")
        .count()
        != 1
    {
        return Err("root broker absolute ceiling changed from its reviewed 73,000s bound".to_owned());
    }

    for (label, token, replacement) in [
        (
            "prestop",
            "Self::PrestopFence => ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS",
            "Self::PrestopFence => ROOT_BROKER_DEADMAN_SECONDS",
        ),
        (
            "post-stop-ping",
            "Self::PostStopPing => ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS",
            "Self::PostStopPing => ROOT_BROKER_DEADMAN_SECONDS",
        ),
        (
            "post-publish",
            "Self::PostPublishFence => ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS",
            "Self::PostPublishFence => ROOT_BROKER_DEADMAN_SECONDS",
        ),
        (
            "second-ping",
            "Self::PostMirrorPing => ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS",
            "Self::PostMirrorPing => ROOT_BROKER_DEADMAN_SECONDS",
        ),
        (
            "candidate-release",
            "Self::CandidateRelease => ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS",
            "Self::CandidateRelease => ROOT_BROKER_DEADMAN_SECONDS",
        ),
        (
            "guardian-reaped",
            "Self::GuardianReaped => ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS,",
            "Self::GuardianReaped => ROOT_BROKER_DEADMAN_SECONDS,",
        ),
        (
            "prestop-ping-widening",
            "Self::PrestopFence => command == \"L1Ciab PRESTOP_FENCE\",",
            "Self::PrestopFence => command == \"L1Ciab PRESTOP_FENCE\" || command == \"L1Ciab PING\",",
        ),
        (
            "post-publish-ping-widening",
            "Self::PostPublishFence => command.starts_with(\"L1Ciab POST_PUBLISH_FENCE \"),",
            "Self::PostPublishFence => command.starts_with(\"L1Ciab POST_PUBLISH_FENCE \") || command == \"L1Ciab PING\",",
        ),
        (
            "candidate-release-ping-widening",
            "Self::CandidateRelease => command == \"L1Ciab RELEASE_CANDIDATE_GATE\",",
            "Self::CandidateRelease => command == \"L1Ciab RELEASE_CANDIDATE_GATE\" || command == \"L1Ciab PING\",",
        ),
        (
            "guardian-reaped-ping-widening",
            "Self::GuardianReaped => command.starts_with(\"L1Ciab GUARDIAN_REAPED \"),",
            "Self::GuardianReaped => command.starts_with(\"L1Ciab GUARDIAN_REAPED \") || command == \"L1Ciab PING\",",
        ),
    ] {
        let mutant = expected.replacen(token, replacement, 1);
        if mutant == expected || verify_root_protocol_expected_command_body(&mutant).is_ok() {
            return Err(format!("root idle source test admitted {label} mutant"));
        }
    }
    let extended_live = expected.replacen(
        "| Self::Live\n            | Self::RoutesRepaired",
        "| Self::RoutesRepaired",
        1,
    );
    if extended_live == expected
        || verify_root_protocol_expected_command_body(&extended_live).is_ok()
    {
        return Err("root idle source test admitted a non-75s live phase".to_owned());
    }
    for (label, mutant) in [
        (
            "unconditional-deadman",
            protocol.replacen(
                "Duration::from_secs(expected_command.idle_seconds())",
                "Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS)",
                1,
            ),
        ),
        (
            "missing-expected-command-guard",
            protocol.replacen("if !expected_command.accepts(&command)", "if false", 1),
        ),
        (
            "advance-before-response",
            swapped_source_steps(
                protocol,
                "root_send(&mut stream, &response)?;",
                "expected_command = expected_command.after(&command)?;",
            ),
        ),
    ] {
        if mutant == protocol || verify_root_protocol_idle_loop_body(&mutant).is_ok() {
            return Err(format!("root idle source test admitted {label} mutant"));
        }
    }
    for (label, mutant) in [
        (
            "nondeadline-mirror-hash",
            mirror_probe.replacen("sha256_until(", "sha256(", 1),
        ),
        (
            "raised-mirror-execution-timeout",
            mirror_probe.replacen(
                "Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS)",
                "Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS + 15)",
                1,
            ),
        ),
        (
            "missing-mirror-stdout-deadline",
            mirror_probe.replacen("if Instant::now() >= stdout_write_deadline", "if false", 1),
        ),
        (
            "missing-mirror-stderr-deadline",
            mirror_probe.replacen("if Instant::now() >= stderr_write_deadline", "if false", 1),
        ),
        (
            "nondeadline-mirror-validator",
            mirror_probe.replacen(
                "verify_mirror_result_until(&layout.mirror_result, deadline)?;",
                "verify_mirror_result(&layout.mirror_result)?;",
                1,
            ),
        ),
    ] {
        if mutant == mirror_probe || verify_mirror_probe_deadline_body(&mutant).is_ok() {
            return Err(format!("mirror source test admitted {label} mutant"));
        }
    }
    let raised_mirror_json_timeout = mirror_json.replacen(
        "Duration::from_secs(maximum_seconds)",
        "Duration::from_secs(maximum_seconds + 15)",
        1,
    );
    if raised_mirror_json_timeout == mirror_json
        || verify_mirror_json_deadline_body(&raised_mirror_json_timeout).is_ok()
    {
        return Err("mirror source test admitted a raised JSON timeout".to_owned());
    }
    let zero_handoff_mirror_json = mirror_json.replacen(
        "    let metadata = fs::symlink_metadata(path)",
        "    if deadline.saturating_duration_since(Instant::now()) < Duration::from_secs(maximum_seconds + MIRROR_PROBE_TEARDOWN_SECONDS) { return Err(format!(\"{label} lacks its process teardown reserve\")); }\n    let metadata = fs::symlink_metadata(path)",
        1,
    );
    if zero_handoff_mirror_json == mirror_json
        || verify_mirror_json_deadline_body(&zero_handoff_mirror_json).is_ok()
    {
        return Err("mirror source test admitted a zero-handoff JSON reserve check".to_owned());
    }
    for (label, mutant) in [
        (
            "unbounded-live-guardian",
            live_heartbeat.replacen("guardian.exchange_until(", "guardian.exchange(", 1),
        ),
        (
            "missing-live-final-root-reserve",
            live_heartbeat.replacen("LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS", "0", 1),
        ),
        (
            "raised-live-guardian-response",
            live_heartbeat.replacen(
                "LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS",
                "ROOT_BROKER_DEADMAN_SECONDS",
                1,
            ),
        ),
        (
            "missing-live-pre-root-ping",
            live_heartbeat.replacen("root.exchange_until(", "root.exchange_with_timeout(", 1),
        ),
        (
            "missing-live-post-root-ping",
            live_heartbeat.replacen("root.exchange_until(", "root.exchange_with_timeout(", 2),
        ),
    ] {
        if mutant == live_heartbeat || verify_live_guardian_heartbeat_body(&mutant).is_ok() {
            return Err(format!("live heartbeat source test admitted {label} mutant"));
        }
    }
    for (label, mutant) in [
        (
            "missing-live-arm-journal-deadline",
            live_arm.replacen("if Instant::now() >= journal_deadline", "if false", 1),
        ),
        (
            "missing-live-arm-result-deadline",
            live_arm.replacen("if Instant::now() >= evidence_deadline", "if false", 1),
        ),
        (
            "missing-live-arm-health",
            live_arm.replacen("root.request_until(", "root.request_with_timeout(", 1),
        ),
        (
            "missing-live-arm-heartbeat",
            live_arm.replacen(
                "run_live_guardian_heartbeat_until(root, guardian, deadline)?;",
                "",
                1,
            ),
        ),
    ] {
        if mutant == live_arm || verify_live_arm_body(&mutant).is_ok() {
            return Err(format!("live-arm source test admitted {label} mutant"));
        }
    }
    for (label, mutant) in [
        (
            "nondeadline-mirror-call",
            transaction.replacen(
                "run_mirror_probe_until(mirror_probe_deadline)?;",
                "run_mirror_probe()?;",
                1,
            ),
        ),
        (
            "missing-mirror-call-handoff",
            transaction.replacen(
                "MIRROR_PROBE_CALL_PRIMITIVE_SECONDS",
                "MIRROR_PROBE_PRIMITIVE_SECONDS",
                1,
            ),
        ),
        (
            "unlinked-live-heartbeat",
            transaction.replacen(
                "run_live_guardian_heartbeat_until(\n                &mut root,\n                &mut guardian,\n                heartbeat_deadline,\n            )?;",
                "guardian.exchange(\"PING\", \"GUARDIAN_BROKER_PONG\")?;",
                1,
            ),
        ),
        (
            "missing-live-arm",
            transaction.replacen("arm_live_trial_until(", "removed_live_arm(", 1),
        ),
        (
            "nondeadline-guardian-reaped-root-exchange",
            transaction.replacen(
                "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
                "root.exchange_with_timeout(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
                1,
            ),
        ),
        (
            "underbounded-guardian-reaped-root-exchange",
            transaction.replacen(
                "guardian_reaped_transition_deadline,",
                "guardian_reaped_command_deadline,",
                1,
            ),
        ),
        (
            "underreserved-guardian-reaped-latest-start",
            transaction.replacen(
                "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline\n        .checked_sub(Duration::from_secs(LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS))",
                "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline\n        .checked_sub(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS))",
                1,
            ),
        ),
    ] {
        if mutant == transaction || verify_root_idle_transaction_body(&mutant).is_ok() {
            return Err(format!("root idle transaction test admitted {label} mutant"));
        }
    }
    let late_guardian_transition_clock = swapped_source_steps(
        transaction,
        "let guardian_reaped_transition_deadline = Instant::now()",
        "guardian.exchange(\"REPAIR\", \"GUARDIAN_BROKER_REPAIRED\")?;",
    );
    if late_guardian_transition_clock == transaction
        || verify_root_idle_transaction_body(&late_guardian_transition_clock).is_ok()
    {
        return Err("root idle transaction admitted a late guardian-reaped clock".to_owned());
    }
    let late_guardian_diagnostics = swapped_source_steps(
        transaction,
        "if !guardian_outcome.diagnostics.is_empty()",
        "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
    );
    if late_guardian_diagnostics == transaction
        || verify_root_idle_transaction_body(&late_guardian_diagnostics).is_ok()
    {
        return Err(
            "root idle transaction admitted diagnostics in the RoutesRepaired gap".to_owned(),
        );
    }
    for (label, token) in [
        ("post-publish-local-summand", "+ POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS"),
        ("mirror-summand", "+ MIRROR_PROBE_PRIMITIVE_SECONDS"),
        ("mirror-call-handoff", "MIRROR_PROBE_CALL_HANDOFF_SECONDS +"),
        ("guardian-finish-summand", "+ GUARDIAN_FINISH_ABSOLUTE_SECONDS"),
        (
            "guardian-diagnostic-publication-summand",
            "+ GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS",
        ),
        ("mirror-hash-summand", "MIRROR_PROBE_HASH_PRIMITIVE_SECONDS,"),
        ("mirror-execution-summand", "MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS,"),
        ("mirror-write-summand", "MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS,"),
        ("mirror-json-summand", "MIRROR_PROBE_JSON_PRIMITIVE_SECONDS,"),
        ("live-heartbeat-root-summand", "2 * LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS"),
        ("live-health-summand", "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS + LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS"),
        ("live-arm-evidence-summand", "LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS + LIVE_ITERATION_OVERHANG_SECONDS"),
        ("guardian-reaped-response-summand", "ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS + ROOT_BROKER_DEADMAN_SECONDS"),
    ] {
        let mutant = constants.replacen(token, "", 1);
        if mutant == constants || verify_root_idle_deadline_constants_body(&mutant).is_ok() {
            return Err(format!("root idle source test admitted missing {label}"));
        }
    }
    for (label, token, replacement) in [
        (
            "global-gate-prestop-wait",
            "let gate_to_prestop_wait = RootProtocolExpectedCommand::PrestopFence.idle_seconds();",
            "let gate_to_prestop_wait = ROOT_BROKER_DEADMAN_SECONDS;",
        ),
        (
            "global-post-stop-wait",
            "let post_stop_ping_wait = RootProtocolExpectedCommand::PostStopPing.idle_seconds();",
            "let post_stop_ping_wait = ROOT_BROKER_DEADMAN_SECONDS;",
        ),
        (
            "global-post-publish-wait",
            "let post_publish_fence_wait = RootProtocolExpectedCommand::PostPublishFence.idle_seconds();",
            "let post_publish_fence_wait = ROOT_BROKER_DEADMAN_SECONDS;",
        ),
        (
            "global-post-mirror-wait",
            "let post_fence_second_ping_wait = RootProtocolExpectedCommand::PostMirrorPing.idle_seconds();",
            "let post_fence_second_ping_wait = ROOT_BROKER_DEADMAN_SECONDS;",
        ),
        (
            "global-release-wait",
            "let probes_to_release_wait = RootProtocolExpectedCommand::CandidateRelease.idle_seconds();",
            "let probes_to_release_wait = ROOT_BROKER_DEADMAN_SECONDS;",
        ),
        (
            "global-live-arm",
            "let live_arm = LIVE_ARM_PRIMITIVE_SECONDS;",
            "let live_arm = 0;",
        ),
        (
            "trial-live-health-overhang",
            "let trial_with_final_heartbeat = 600 + LIVE_ITERATION_OVERHANG_SECONDS;",
            "let trial_with_final_heartbeat = 600 + 2 * ROOT_BROKER_DEADMAN_SECONDS;",
        ),
        (
            "stop-live-health-overhang",
            "let stop_phase_sum = LIVE_ITERATION_OVERHANG_SECONDS",
            "let stop_phase_sum = 2 * ROOT_BROKER_DEADMAN_SECONDS",
        ),
        (
            "guardian-reaped-transition",
            "let guardian_reaped_transition = GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS;",
            "let guardian_reaped_transition = ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS;",
        ),
    ] {
        let mutant = global_graph.replacen(token, replacement, 1);
        if mutant == global_graph || verify_root_global_deadline_graph_body(&mutant).is_ok() {
            return Err(format!("root global deadline test admitted {label} mutant"));
        }
    }
    Ok(())
}

fn self_test() -> Result<(), String> {
    verify_root_broker_source_order()?;
    verify_root_protocol_idle_source_contract()?;
    verify_retry_preflight_source_contract()?;
    verify_sealed_pin_publication_source_order()?;
    verify_sealed_host_signature_resource_source_contract()?;
    verify_candidate_gate_diagnostics_source_contract()?;
    verify_root_accept_dead_proxy_source_contract()?;
    verify_coreaudio_restart_source_contract()?;
    verify_retained_session_source_contract()?;
    verify_emergency_cleanup_source_contract()?;
    verify_v6_restore_recovery_source_contract()?;
    verify_owned_session_lifecycle_source_contract()?;
    verify_runtime_lock_ownership_source_contract()?;
    verify_post_publish_guardian_source_contract()?;
    verify_guardian_spawn_handoff_source_contract()?;
    verify_guardian_finally_source_contract()?;
    verify_guardian_route_recovery_deadline_source_contract()?;
    if !guardian_repair_retry_model(
        false,
        &[
            GuardianRepairAttemptModel::Failed,
            GuardianRepairAttemptModel::Failed,
            GuardianRepairAttemptModel::Success,
        ],
    ) || !guardian_repair_retry_model(
        true,
        &[GuardianRepairAttemptModel::Partial, GuardianRepairAttemptModel::Success],
    ) || guardian_repair_retry_model(
        false,
        &[GuardianRepairAttemptModel::Failed, GuardianRepairAttemptModel::Partial],
    ) {
        return Err("guardian repair attempts do not converge across repeated/partial failures".to_owned());
    }
    let stages = [
        TrialStage::Prepared,
        TrialStage::CandidateGateBound,
        TrialStage::V6StopIntent,
        TrialStage::V6Stopped,
        TrialStage::PublishIntent,
        TrialStage::DriverRenamedBeforeJournal,
        TrialStage::DriverPublished,
        TrialStage::CoreAudioReloaded,
        TrialStage::ProbesVerified,
        TrialStage::CandidateSpawnedBeforeTracked,
        TrialStage::CandidateRunning,
        TrialStage::CandidateStopped,
        TrialStage::RoutesRepaired,
        TrialStage::DriverRestored,
        TrialStage::V6Restored,
    ];
    for stage in stages {
        let trace = rollback_from(stage);
        if let (Some(driver), Some(v6)) = (trace.driver_restored_at, trace.v6_restored_at) {
            if driver >= v6 {
                return Err(format!("driver rollback did not precede v6 restore at {stage:?}"));
            }
        }
        if let (Some(candidate), Some(driver)) =
            (trace.candidate_stopped_at, trace.driver_restored_at)
        {
            if candidate >= driver {
                return Err(format!("candidate stop did not precede driver rollback at {stage:?}"));
            }
        }
        if let (Some(absent), Some(routes)) =
            (trace.candidate_absent_at, trace.routes_repaired_at)
        {
            if absent >= routes {
                return Err(format!(
                    "candidate/lock absence did not precede route repair at {stage:?}"
                ));
            }
        }
        if let (Some(routes), Some(driver)) =
            (trace.routes_repaired_at, trace.driver_restored_at)
        {
            if routes >= driver {
                return Err(format!("route repair did not precede driver rollback at {stage:?}"));
            }
        }
    }
    if rollback_from(TrialStage::Prepared).events.len() != 0 {
        return Err("prepared-only rollback mutated modeled state".to_owned());
    }
    if rollback_from(TrialStage::CandidateGateBound).events
        != [
            "candidate-stopped",
            "candidate-and-shared-lock-proved-absent",
        ]
    {
        return Err("pre-destructive candidate gate recovery touched runtime state".to_owned());
    }
    if rollback_from(TrialStage::CandidateRunning).events
        != [
            "candidate-stopped",
            "candidate-and-shared-lock-proved-absent",
            "guardian-repaired-and-verified-all-default-selectors",
            "driver-restored-and-coreaudio-reloaded",
            "exact-v6-bootstrapped-and-verified",
        ]
    {
        return Err("full rollback event order changed".to_owned());
    }
    if rollback_from(TrialStage::V6Stopped).events
        != [
            "guardian-repaired-and-verified-all-default-selectors",
            "driver-restored-and-coreaudio-reloaded",
            "exact-v6-bootstrapped-and-verified",
        ]
    {
        return Err("v6-stop recovery no longer repairs routes before restore".to_owned());
    }
    if rollback_from(TrialStage::CandidateStopped).events
        != [
            "guardian-repaired-and-verified-all-default-selectors",
            "driver-restored-and-coreaudio-reloaded",
            "exact-v6-bootstrapped-and-verified",
        ]
        || rollback_from(TrialStage::RoutesRepaired).events
            != [
                "driver-restored-and-coreaudio-reloaded",
                "exact-v6-bootstrapped-and-verified",
            ]
        || rollback_from(TrialStage::DriverRestored).events
            != ["exact-v6-bootstrapped-and-verified"]
        || !rollback_from(TrialStage::V6Restored).events.is_empty()
    {
        return Err("terminal response-loss recovery replayed a completed stage".to_owned());
    }
    if rollback_from(TrialStage::DriverRenamedBeforeJournal)
        .driver_restored_at
        .is_none()
    {
        return Err("partial publication before journal was not rollback-eligible".to_owned());
    }
    for signal in ["TERM", "KILL"] {
        let recovery = rollback_from(TrialStage::CandidateRunning);
        if recovery.events.last() != Some(&"exact-v6-bootstrapped-and-verified") {
            return Err(format!("detached guardian recovery failed for group {signal}"));
        }
    }
    if proxy_can_cross_destructive_boundary(false, true)
        || proxy_can_cross_destructive_boundary(true, false)
        || !proxy_can_cross_destructive_boundary(true, true)
    {
        return Err("detached proxy arm gate accepted a pre-arm or mismatched identity".to_owned());
    }
    if candidate_gate_can_exec(false, true, true)
        || candidate_gate_can_exec(true, false, true)
        || candidate_gate_can_exec(true, true, false)
        || !candidate_gate_can_exec(true, true, true)
    {
        return Err("candidate gate crossed GO without the exact root-bound identity".to_owned());
    }
    if recovery_may_finalize_user_evidence(false, true, true, true, true, true, true)
        || recovery_may_finalize_user_evidence(true, false, true, true, true, true, true)
        || recovery_may_finalize_user_evidence(true, true, false, true, true, true, true)
        || recovery_may_finalize_user_evidence(true, true, true, false, true, true, true)
        || recovery_may_finalize_user_evidence(true, true, true, true, false, true, true)
        || recovery_may_finalize_user_evidence(true, true, true, true, true, false, true)
        || recovery_may_finalize_user_evidence(true, true, true, true, true, true, false)
        || !recovery_may_finalize_user_evidence(true, true, true, true, true, true, true)
    {
        return Err(
            "root recovery evidence finalization ignored its post-connect/postcondition fence"
                .to_owned(),
        );
    }
    if classify_start_result("") != StartResultObservation::Pending
        || classify_start_result(
            "LOCAL_MONO_TRIAL_READY candidate_pid=41 automatic_rollback=true\n",
        ) != StartResultObservation::Ready
        || classify_start_result(
            "LOCAL_MONO_TRIAL_READY candidate_pid=41 automatic_rollback=true\nLOCAL_MONO_TRIAL_FAILED simulated\n",
        ) != StartResultObservation::Failed
        || classify_start_result(
            "LOCAL_MONO_TRIAL_READY candidate_pid=41 automatic_rollback=true\nLOCAL_MONO_TRIAL_FAILED simulated\nLOCAL_MONO_TRIAL_ROLLED_BACK\n",
        ) != StartResultObservation::RolledBack
    {
        return Err("start waiter accepted stale READY over terminal recovery".to_owned());
    }
    if !start_ready_admission_model(
        StartResultObservation::Ready,
        true,
        true,
        StartResultObservation::Ready,
    ) || start_ready_admission_model(
        StartResultObservation::Ready,
        false,
        true,
        StartResultObservation::Ready,
    ) || start_ready_admission_model(
        StartResultObservation::Ready,
        true,
        false,
        StartResultObservation::Ready,
    ) || start_ready_admission_model(
        StartResultObservation::Ready,
        true,
        true,
        StartResultObservation::RolledBack,
    ) {
        return Err("start readiness fence accepted absent identity or adjacent rollback".to_owned());
    }
    if atomic_pointer_publication_model(false, true, true, true)
        || atomic_pointer_publication_model(true, false, true, true)
        || atomic_pointer_publication_model(true, true, false, true)
        || atomic_pointer_publication_model(true, true, true, false)
        || !atomic_pointer_publication_model(true, true, true, true)
    {
        return Err("active pointer publication admitted a partial or non-durable canonical file".to_owned());
    }
    let pointer_start = "Mon Aug 16 12:34:56 2026";
    let exact_pointer = format!(
        "schema=opensteamer.local-mono-trial-pointer.v1\ntrial_root={TRIAL_ROOT}\nstate=arming\nproxy_pid=41\nproxy_start={pointer_start}\nstate=armed\n"
    );
    if validate_active_pointer_text(&exact_pointer, 41, pointer_start).is_err()
        || validate_active_pointer_text(
            &exact_pointer.replace("proxy_pid=41", "proxy_pid=42"),
            41,
            pointer_start,
        )
        .is_ok()
        || validate_result_before_finalization("")?
        || validate_result_before_finalization(
            "LOCAL_MONO_TRIAL_FAILED simulated\nLOCAL_MONO_TRIAL_ROLLED_BACK\n",
        )? != true
        || validate_result_before_finalization(
            "LOCAL_MONO_TRIAL_ROLLED_BACK\nLOCAL_MONO_TRIAL_ROLLED_BACK\n",
        )
        .is_ok()
    {
        return Err("root-owned result/pointer finalization mutant was accepted".to_owned());
    }
    if candidate_absence_barrier_model(true, false, false)
        || candidate_absence_barrier_model(false, true, false)
        || !candidate_absence_barrier_model(true, true, false)
        || !candidate_absence_barrier_model(false, false, true)
    {
        return Err("candidate absence/shared-lock barrier accepted an unsafe rollback".to_owned());
    }
    if !candidate_stop_guard_retry_model(true, false, true)
        || candidate_stop_guard_retry_model(false, true, true)
        || candidate_stop_guard_retry_model(true, false, false)
    {
        return Err(
            "candidate quiescence did not persist across a transient guard failure".to_owned(),
        );
    }
    if guardian_fallback_quiescence_model(false, false, true, true)
        || guardian_fallback_quiescence_model(true, true, true, true)
        || guardian_fallback_quiescence_model(true, false, false, true)
        || guardian_fallback_quiescence_model(true, false, true, false)
        || !guardian_fallback_quiescence_model(true, false, true, true)
    {
        return Err(
            "guardian fallback accepted a live/reused leader or orphaned SID descendant"
                .to_owned(),
        );
    }
    let legitimate_host_text_mappings = [
        SEALED_HOST_EXECUTABLE,
        "/usr/lib/dyld",
        "/System/Library/Frameworks/CoreAudio.framework/CoreAudio",
        SEALED_FRAMEWORK_EXECUTABLE,
    ];
    if classify_candidate_primary_path(Path::new(SEALED_CONTROLLER))?
        != CandidatePhase::DormantGate
        || classify_candidate_primary_path(Path::new(SEALED_HOST_EXECUTABLE))?
            != CandidatePhase::LiveHost
        || classify_candidate_primary_path(Path::new("/usr/bin/python3")).is_ok()
        || classify_candidate_primary_path(Path::new("/usr/lib/dyld")).is_ok()
        || legitimate_host_text_mappings.len() < 4
    {
        return Err(
            "primary executable model accepted mmap forgery or rejected real-host mappings"
                .to_owned(),
        );
    }
    if root_launch_capability_model(501, 20, true, true, true)
        || root_launch_capability_model(0, 0, false, true, true)
        || root_launch_capability_model(0, 0, true, false, true)
        || root_launch_capability_model(0, 0, true, true, false)
        || !root_launch_capability_model(0, 0, true, true, true)
    {
        return Err("root launch capability model accepted a direct/replayed/forged helper".to_owned());
    }
    if imported_command_limit_for_mode(UID_ADMISSION_MODE, false)
        != Some(ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_limit_for_mode(UID_STOP_V6_MODE, false).is_some()
        || imported_command_limit_for_mode(UID_EMERGENCY_V6_MODE, false).is_some()
        || imported_command_limit_for_mode(UID_STOP_V6_MODE, true)
            != Some(RECOVERY_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_limit_for_mode(UID_EMERGENCY_V6_MODE, true)
            != Some(RECOVERY_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_limit_for_mode(UID_FINALIZE_EVIDENCE_MODE, false).is_some()
        || imported_command_limit_for_mode(UID_FINALIZE_EVIDENCE_MODE, true)
            != Some(ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_limit_for_mode(UID_VERIFY_CANDIDATE_MODE, true)
            != Some(CANDIDATE_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_limit_for_mode(UID_VERIFY_HAL_MODE, true)
            != Some(NO_IMPORTED_COMMAND_MAXIMUM)
    {
        return Err("imported-command mode/capability mapping changed".to_owned());
    }
    if root_peer_admission_model(41, 42, true, true, true)
        || root_peer_admission_model(41, 41, false, true, true)
        || root_peer_admission_model(41, 41, true, false, true)
        || root_peer_admission_model(41, 41, true, true, false)
        || !root_peer_admission_model(41, 41, true, true, true)
    {
        return Err("root broker admitted a same-uid process it did not spawn".to_owned());
    }
    if candidate_signal_identity_model(false, true, true, true, true, true)
        || candidate_signal_identity_model(true, false, true, true, true, true)
        || candidate_signal_identity_model(true, true, false, true, true, true)
        || candidate_signal_identity_model(true, true, true, false, true, true)
        || candidate_signal_identity_model(true, true, true, true, false, true)
        || candidate_signal_identity_model(true, true, true, true, true, false)
        || !candidate_signal_identity_model(true, true, true, true, true, true)
    {
        return Err(
            "candidate signal fence accepted missing ownership/SID or setsid escape".to_owned(),
        );
    }
    if CANDIDATE_HOST_NON_DAEMONIZING_AUDIT_SHA256 != CANDIDATE_HOST_SHA256
        || MIRROR_PROBE_NON_DAEMONIZING_AUDIT_SHA256 != MIRROR_PROBE_SHA256
        || VPIO_PROBE_NON_DAEMONIZING_AUDIT_SHA256 != VPIO_PROBE_SHA256
        || ROUTE_GUARDIAN_NON_DAEMONIZING_AUDIT_SHA256 != ROUTE_GUARDIAN_SHA256
    {
        return Err("owned-session binary changed without a non-daemonizing audit".to_owned());
    }
    if signature_contract_model(true, false, DEVELOPMENT_LEAF_SHA256)
        || signature_contract_model(false, true, DEVELOPMENT_LEAF_SHA256)
        || signature_contract_model(true, true, "wrong-leaf")
        || !signature_contract_model(true, true, DEVELOPMENT_LEAF_SHA256)
    {
        return Err("signature model accepted wrong architecture/entitlements/leaf state".to_owned());
    }
    if v6_restore_recovery_model(true, 1, true) != "drain-lock-bootstrap"
        || v6_restore_recovery_model(true, 0, true) != "bootstrap"
        || v6_restore_recovery_model(false, 1, true) != "wait-loaded-generation"
        || v6_restore_recovery_model(true, 1, false) != "reject"
    {
        return Err("v6 draining-generation restore convergence model changed".to_owned());
    }
    if emergency_retry_requires_v6_stop(true, true, false, true, true)
        || !emergency_retry_requires_v6_stop(true, false, false, true, true)
        || !emergency_retry_requires_v6_stop(true, true, true, true, true)
        || !emergency_retry_requires_v6_stop(true, true, false, false, true)
    {
        return Err(
            "post-restore evidence retry stopped or stranded the admitted v6 generation"
                .to_owned(),
        );
    }
    if uid_helper_identity_isolated(100, 101, 100, 501, 20, true)
        || uid_helper_identity_isolated(100, 100, 101, 501, 20, true)
        || uid_helper_identity_isolated(100, 100, 100, 0, 20, true)
        || uid_helper_identity_isolated(100, 100, 100, 501, 0, true)
        || uid_helper_identity_isolated(100, 100, 100, 501, 20, false)
        || !uid_helper_identity_isolated(100, 100, 100, 501, 20, true)
    {
        return Err("sealed UID helper isolation model accepted a regrouped child".to_owned());
    }
    if classify_absence_result(Some(std::io::ErrorKind::PermissionDenied)) != "operational-error"
        || classify_absence_result(Some(std::io::ErrorKind::NotFound)) != "absent"
    {
        return Err("driver absence check swallowed an operational error".to_owned());
    }
    let hung_started = Instant::now();
    let hung = bounded_output(
        Command::new("/bin/sh")
            .args(["-c", "/bin/sleep 10 & /bin/wait"])
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_millis(100),
        65_536,
        "hung-descendant rollback mutant",
    );
    if hung.is_ok() || hung_started.elapsed() > Duration::from_secs(4) {
        return Err("bounded command failed to kill/reap its hung descendant group".to_owned());
    }
    let ordinary = bounded_imported_command_output(
        Command::new("/usr/bin/python3")
            .args([
                "-I",
                "-S",
                "-c",
                "import os; print(os.getpid(), os.getpgrp(), os.getsid(0))",
            ])
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_secs(2),
        65_536,
        "ordinary imported-command isolation mutant",
    )?;
    let identity = String::from_utf8(ordinary.stdout)
        .map_err(|_| "ordinary imported-command identity is not UTF-8")?;
    let values = identity
        .split_ascii_whitespace()
        .map(|value| value.parse::<u32>().map_err(|_| "ordinary identity is malformed"))
        .collect::<Result<Vec<_>, _>>()?;
    if values.len() != 3 || values[0] != values[1] || values[0] == values[2] {
        return Err("ordinary imported command did not receive a fresh process group".to_owned());
    }
    let security_hung = bounded_imported_command_output(
        Command::new("/bin/sh")
            .args(["-c", "/bin/sleep 10 & /bin/wait"])
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_millis(100),
        65_536,
        "hung pairing-security descendant mutant",
    );
    if security_hung.is_ok() {
        return Err("pairing-security selector lost its ordinary timeout".to_owned());
    }
    if IMPORTED_COMMAND_COUNT.load(Ordering::SeqCst) != 2
        || std::mem::size_of::<DarwinSigInfo>() != 104
        || std::mem::size_of::<DarwinProcBsdInfo>() != 136
        || std::mem::offset_of!(DarwinProcBsdInfo, status) != 4
        || std::mem::offset_of!(DarwinProcBsdInfo, pid) != 12
        || std::mem::offset_of!(DarwinProcBsdInfo, uid) != 20
        || std::mem::offset_of!(DarwinProcBsdInfo, pgid) != 100
        || std::mem::offset_of!(DarwinProcBsdInfo, start_seconds) != 120
        || std::mem::offset_of!(DarwinProcBsdInfo, start_microseconds) != 128
        || DARWIN_SIGCHLD != 20
        || DARWIN_CLD_EXITED != 1
        || DARWIN_CLD_KILLED != 2
        || DARWIN_CLD_DUMPED != 3
        || ADMISSION_IMPORTED_COMMAND_MAXIMUM != 256
        || RECOVERY_IMPORTED_COMMAND_MAXIMUM < 3 * ADMISSION_IMPORTED_COMMAND_MAXIMUM + 32
        || !imported_command_index_allowed(1, ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        || !imported_command_index_allowed(256, ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_index_allowed(0, ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_index_allowed(257, ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        || !imported_command_index_allowed(800, RECOVERY_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_index_allowed(801, RECOVERY_IMPORTED_COMMAND_MAXIMUM)
        || !imported_command_index_allowed(32, CANDIDATE_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_index_allowed(33, CANDIDATE_IMPORTED_COMMAND_MAXIMUM)
        || imported_command_index_allowed(1, NO_IMPORTED_COMMAND_MAXIMUM)
        || !imported_command_index_allowed(
            HEALTHY_ADMISSION_IMPORTED_COMMAND_COUNT,
            ADMISSION_IMPORTED_COMMAND_MAXIMUM,
        )
        || imported_command_index_allowed(
            2 * HEALTHY_ADMISSION_IMPORTED_COMMAND_COUNT,
            ADMISSION_IMPORTED_COMMAND_MAXIMUM,
        )
    {
        return Err("imported-command runtime cap is not exact or falsifiable".to_owned());
    }
    let inherited = bounded_output_inherited_helper_group(
        Command::new("/usr/bin/true").env_clear().env("LC_ALL", "C"),
        Duration::from_secs(1),
        65_536,
        "inherited-helper-group smoke test",
    )?;
    if !inherited.status.success() {
        return Err("inherited-helper-group command did not preserve its supervisor".to_owned());
    }
    let mut regrouped = Command::new("/usr/bin/python3");
    regrouped
        .args([
            "-I",
            "-S",
            "-c",
            "import os,time\np=os.fork()\nif p==0:\n os.setpgid(0,0); time.sleep(10); os._exit(0)\nos.waitpid(p,0)",
        ])
        .env_clear()
        .env("LC_ALL", "C");
    unsafe {
        regrouped.pre_exec(|| {
            if libc_setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let regrouped_started = Instant::now();
    let regrouped_result = bounded_output_preconfigured_session(
        &mut regrouped,
        Duration::from_millis(100),
        65_536,
        "regrouped UID-helper descendant mutant",
    );
    if regrouped_result.is_ok() || regrouped_started.elapsed() > Duration::from_secs(4) {
        return Err("session supervisor failed to reap a regrouped helper descendant".to_owned());
    }
    for (phase, expected_command) in [
        (
            RootProtocolExpectedCommand::PrestopFence,
            "L1Ciab PRESTOP_FENCE",
        ),
        (
            RootProtocolExpectedCommand::PostPublishFence,
            "L1Ciab POST_PUBLISH_FENCE aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
        (
            RootProtocolExpectedCommand::CandidateRelease,
            "L1Ciab RELEASE_CANDIDATE_GATE",
        ),
        (
            RootProtocolExpectedCommand::GuardianReaped,
            "L1Ciab GUARDIAN_REAPED 123",
        ),
    ] {
        if !phase.accepts(expected_command) || phase.accepts("L1Ciab PING") {
            return Err(format!(
                "root expected-command phase {phase:?} admitted a PING or rejected its exact command"
            ));
        }
    }
    // Complete successful protocol sequence, starting when the authenticated proxy is accepted.
    // Each value is the enclosing bound for the adjacent root/guardian/probe phase. The nominal
    // 600s trial includes one final reviewed root/candidate/guardian iteration at its deadline.
    let guardian_bind = ROOT_GUARDIAN_BIND_RESPONSE_SECONDS;
    let gate_bind = ROOT_GATE_RESPONSE_SECONDS;
    let gate_to_prestop_wait = RootProtocolExpectedCommand::PrestopFence.idle_seconds();
    let prestop_response = ROOT_PRESTOP_RESPONSE_SECONDS;
    let stop_v6 = ROOT_STOP_RESPONSE_SECONDS;
    let post_stop_ping_wait = RootProtocolExpectedCommand::PostStopPing.idle_seconds();
    let post_stop_ping_response = ROOT_BROKER_DEADMAN_SECONDS;
    let publish = ROOT_PUBLISH_RESPONSE_SECONDS;
    let post_publish_fence_wait = RootProtocolExpectedCommand::PostPublishFence.idle_seconds();
    let post_publish_fence_response = ROOT_BROKER_DEADMAN_SECONDS;
    let post_fence_root_ping_response = ROOT_BROKER_DEADMAN_SECONDS;
    let post_fence_second_ping_wait = RootProtocolExpectedCommand::PostMirrorPing.idle_seconds();
    let post_mirror_ping_response = ROOT_BROKER_DEADMAN_SECONDS;
    let vpio_probe = RUN_FIXED_BOUND_SECONDS;
    let probes_verified = ROOT_PROBES_RESPONSE_SECONDS;
    let probes_to_release_wait = RootProtocolExpectedCommand::CandidateRelease.idle_seconds();
    let gate_release = ROOT_CANDIDATE_RESPONSE_SECONDS;
    let live_arm = LIVE_ARM_PRIMITIVE_SECONDS;
    let trial_with_final_heartbeat = 600 + LIVE_ITERATION_OVERHANG_SECONDS;
    let candidate_stop = ROOT_CANDIDATE_STOP_RESPONSE_SECONDS;
    let guardian_reaped_transition = GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS;
    let routes_repaired = ROOT_ROUTES_RESPONSE_SECONDS;
    let rollback = ROOT_ROLLBACK_RESPONSE_SECONDS;
    let restore_v6 = ROOT_RESTORE_RESPONSE_SECONDS;
    let complete = ROOT_BROKER_DEADMAN_SECONDS;
    let finalize_evidence = UID_FINALIZE_EVIDENCE_HELPER_SECONDS;
    let start_phase_sum = guardian_bind
        + gate_bind
        + gate_to_prestop_wait
        + prestop_response
        + stop_v6
        + post_stop_ping_wait
        + post_stop_ping_response
        + publish
        + post_publish_fence_wait
        + post_publish_fence_response
        + post_fence_root_ping_response
        + post_fence_second_ping_wait
        + post_mirror_ping_response
        + vpio_probe
        + probes_verified
        + probes_to_release_wait
        + gate_release
        + live_arm;
    let guardian_lifetime_sum = start_phase_sum
        + trial_with_final_heartbeat
        + candidate_stop
        + guardian_reaped_transition;
    let complete_protocol_sum = guardian_lifetime_sum
        + routes_repaired
        + rollback
        + restore_v6
        + complete
        + finalize_evidence;
    let root_lifecycle_ceiling = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        ROOT_SOCKET_SETUP_SECONDS,
        ROOT_PROXY_SPAWN_SECONDS,
        ROOT_ACCEPT_SECONDS,
        complete_protocol_sum,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle deadline arithmetic overflowed")?;
    let lifecycle_without_prepare = reviewed_root_lifecycle_ceiling(
        0,
        ROOT_SOCKET_SETUP_SECONDS,
        ROOT_PROXY_SPAWN_SECONDS,
        ROOT_ACCEPT_SECONDS,
        complete_protocol_sum,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle missing-prepare mutant overflowed")?;
    let lifecycle_without_socket_setup = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        0,
        ROOT_PROXY_SPAWN_SECONDS,
        ROOT_ACCEPT_SECONDS,
        complete_protocol_sum,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle missing-socket-setup mutant overflowed")?;
    let lifecycle_without_proxy_spawn = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        ROOT_SOCKET_SETUP_SECONDS,
        0,
        ROOT_ACCEPT_SECONDS,
        complete_protocol_sum,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle missing-proxy-spawn mutant overflowed")?;
    let lifecycle_without_accept = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        ROOT_SOCKET_SETUP_SECONDS,
        ROOT_PROXY_SPAWN_SECONDS,
        0,
        complete_protocol_sum,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle missing-accept mutant overflowed")?;
    let lifecycle_without_protocol = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        ROOT_SOCKET_SETUP_SECONDS,
        ROOT_PROXY_SPAWN_SECONDS,
        ROOT_ACCEPT_SECONDS,
        0,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle missing-protocol mutant overflowed")?;
    let lifecycle_without_emergency = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        ROOT_SOCKET_SETUP_SECONDS,
        ROOT_PROXY_SPAWN_SECONDS,
        ROOT_ACCEPT_SECONDS,
        complete_protocol_sum,
        0,
        ROOT_POST_COMPLETE_PROXY_SECONDS,
    )
    .ok_or("root lifecycle missing-emergency mutant overflowed")?;
    let lifecycle_without_post_complete_proxy = reviewed_root_lifecycle_ceiling(
        ROOT_PREPARE_SECONDS,
        ROOT_SOCKET_SETUP_SECONDS,
        ROOT_PROXY_SPAWN_SECONDS,
        ROOT_ACCEPT_SECONDS,
        complete_protocol_sum,
        EMERGENCY_CLEANUP_ABSOLUTE_SECONDS,
        0,
    )
    .ok_or("root lifecycle missing-post-complete-proxy mutant overflowed")?;
    // Once READY is published, STOP can overlap at most one complete reviewed live iteration.
    let stop_phase_sum = LIVE_ITERATION_OVERHANG_SECONDS
        + candidate_stop
        + guardian_reaped_transition
        + routes_repaired
        + rollback
        + restore_v6
        + complete
        + finalize_evidence;
    let maximum_guardian_silence = [
        ROOT_GUARDIAN_BIND_RESPONSE_SECONDS + ROOT_GATE_RESPONSE_SECONDS,
        ROOT_PRESTOP_RESPONSE_SECONDS + ROOT_STOP_RESPONSE_SECONDS,
        ROOT_PUBLISH_RESPONSE_SECONDS,
        ROOT_PROBES_RESPONSE_SECONDS,
        ROOT_CANDIDATE_RESPONSE_SECONDS + 20,
    ]
    .into_iter()
    .max()
    .ok_or("guardian silence phase table is empty")?;
    let expanded_json_evidence_seconds = GUARDIAN_EVIDENCE_HASH_SECONDS
        + 3
        + (GUARDIAN_EVIDENCE_JSON_SECONDS + 15)
        + 3;
    let expanded_json_success_seconds = GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
        + 2 * expanded_json_evidence_seconds;
    let expanded_json_rejection_seconds = GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
        + expanded_json_evidence_seconds
        + 2 * GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS;
    let expanded_json_recovered_seconds = GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
        + 3 * expanded_json_evidence_seconds;
    let expanded_json_reconciliation_seconds =
        reviewed_guardian_repair_reconciliation_maximum(
            expanded_json_evidence_seconds,
            GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS,
        );
    let expanded_json_reproof_seconds = GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
        + expanded_json_reconciliation_seconds;
    if GUARDIAN_IDLE_SECONDS < maximum_guardian_silence + 120
        || ROOT_PREPARE_SECONDS < ROOT_PREPARE_PRIMITIVE_SECONDS + 120
        || ROOT_PROXY_SPAWN_SECONDS < 60 + CANDIDATE_STOP_PRIMITIVE_SECONDS
        || PROXY_STOP_PRIMITIVE_SECONDS
            < GUARDIAN_NATURAL_REAP_SECONDS
                + GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS
                + PROXY_FORCED_CLEANUP_RESERVE_SECONDS
        || GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS
            < GUARDIAN_REPAIR_REPROOF_MINIMUM_SECONDS
        || GUARDIAN_REPAIR_RECONCILIATION_MAXIMUM_SECONDS != 48
        || GUARDIAN_REPAIR_REPROOF_MINIMUM_SECONDS != 81
        || GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS < expanded_json_reproof_seconds
        || GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_SECONDS
            < GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_MINIMUM_SECONDS
        || GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_MINIMUM_SECONDS != 81
        || expanded_json_recovered_seconds <= expanded_json_success_seconds
        || expanded_json_recovered_seconds <= expanded_json_rejection_seconds
        || reviewed_guardian_repair_reconciliation_maximum(
            expanded_json_evidence_seconds,
            GUARDIAN_REPAIR_ATTEMPT_HASH_PRIMITIVE_SECONDS,
        ) + GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS
            != expanded_json_recovered_seconds
        || GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS
            < GUARDIAN_RECOVERY_STATE_BIND_MINIMUM_SECONDS
        || GUARDIAN_RECOVERY_STATE_BIND_MINIMUM_SECONDS != 98
        || GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS
            != GUARDIAN_REPAIR_ATTEMPT_PREFLIGHT_SECONDS
                + UID_ROUTE_REPAIR_HELPER_SECONDS
                + UID_SEALED_TEARDOWN_RESERVE_SECONDS
                + GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS
        || GUARDIAN_ROUTE_RECOVERY_PRIMITIVE_SECONDS
            != GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS
                + GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS
        || CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS
            < CANDIDATE_CAPTURE_TOPOLOGY_MINIMUM_SECONDS
        || ROOT_PUBLISH_RESPONSE_SECONDS < PUBLISH_PRIMITIVE_SECONDS + 120
        || ROOT_GUARDIAN_BIND_RESPONSE_SECONDS < GUARDIAN_BIND_PRIMITIVE_SECONDS + 120
        || ROOT_PRESTOP_RESPONSE_SECONDS < PRESTOP_PRIMITIVE_SECONDS + 120
        || ROOT_CANDIDATE_STOP_RESPONSE_SECONDS < CANDIDATE_STOP_PRIMITIVE_SECONDS + 120
        || ROOT_ROUTES_RESPONSE_SECONDS < ROUTES_REPAIRED_PRIMITIVE_SECONDS + 120
        || ROOT_ROLLBACK_RESPONSE_SECONDS < ROLLBACK_PRIMITIVE_SECONDS + 120
        || UID_ADMISSION_SECONDS < UID_ADMISSION_PRIMITIVE_SECONDS + 120
        || UID_STOP_HELPER_SECONDS < UID_STOP_PRIMITIVE_SECONDS + 120
        || UID_RESTORE_HELPER_SECONDS < UID_RESTORE_PRIMITIVE_SECONDS + 120
        || UID_FINALIZE_EVIDENCE_HELPER_SECONDS
            < UID_FINALIZE_EVIDENCE_PRIMITIVE_SECONDS + 120
        || ROOT_STOP_RESPONSE_SECONDS < UID_STOP_HELPER_SECONDS + 120
        || ROOT_CANDIDATE_RESPONSE_SECONDS < UID_CANDIDATE_HELPER_SECONDS + 120
        || ROOT_RESTORE_RESPONSE_SECONDS < UID_RESTORE_HELPER_SECONDS + 120
        || ROOT_ACCEPT_SECONDS < UID_ADMISSION_SECONDS + 120
        || ROOT_STAGE_READY_SECONDS < ROOT_PREPARE_SECONDS + 120
        || UID_HAL_HELPER_SECONDS < 120
        || UID_ROUTE_REPAIR_HELPER_SECONDS < UID_HAL_HELPER_SECONDS + 120
        || GUARDIAN_MAXIMUM_SECONDS > GUARDIAN_SOURCE_MAXIMUM_SECONDS
        || GUARDIAN_MAXIMUM_SECONDS < guardian_lifetime_sum + 600
        || ROOT_BROKER_ABSOLUTE_SECONDS < complete_protocol_sum * 6 / 5
        || ROOT_PROTOCOL_ABSOLUTE_SECONDS < complete_protocol_sum
        || EMERGENCY_CLEANUP_ABSOLUTE_SECONDS < EMERGENCY_CLEANUP_PRIMITIVE_SECONDS
        || POST_PUBLISH_FENCE_PRIMITIVE_SECONDS != 214
        || MIRROR_PROBE_HASH_PRIMITIVE_SECONDS != 33
        || MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS != 33
        || MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS != 10
        || MIRROR_PROBE_JSON_PRIMITIVE_SECONDS != 13
        || MIRROR_PROBE_PRIMITIVE_SECONDS != 89
        || MIRROR_PROBE_CALL_HANDOFF_SECONDS != 1
        || MIRROR_PROBE_CALL_PRIMITIVE_SECONDS != 90
        || reviewed_mirror_probe_minimum(0, 33, 10, 13) >= MIRROR_PROBE_PRIMITIVE_SECONDS
        || reviewed_mirror_probe_minimum(33, 0, 10, 13) >= MIRROR_PROBE_PRIMITIVE_SECONDS
        || reviewed_mirror_probe_minimum(33, 33, 0, 13) >= MIRROR_PROBE_PRIMITIVE_SECONDS
        || reviewed_mirror_probe_minimum(33, 33, 10, 0) >= MIRROR_PROBE_PRIMITIVE_SECONDS
        || LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS != 65
        || LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS != 80
        || LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS != 225
        || LIVE_ITERATION_OVERHANG_SECONDS != 305
        || LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS != 10
        || LIVE_ARM_PRIMITIVE_SECONDS != 315
        || ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS != 85
        || ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS != 85
        || ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS != 139
        || ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS != 175
        || ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS != 85
        || ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS != 205
        || GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS != 280
        || complete_protocol_sum != 29_534
        || RootProtocolExpectedCommand::Live.idle_seconds() != ROOT_BROKER_DEADMAN_SECONDS
        || root_lifecycle_ceiling != 72_209
        || ROOT_BROKER_ABSOLUTE_SECONDS < root_lifecycle_ceiling
        || lifecycle_without_prepare >= root_lifecycle_ceiling
        || lifecycle_without_socket_setup >= root_lifecycle_ceiling
        || lifecycle_without_proxy_spawn >= root_lifecycle_ceiling
        || lifecycle_without_accept >= root_lifecycle_ceiling
        || lifecycle_without_protocol >= root_lifecycle_ceiling
        || lifecycle_without_emergency >= root_lifecycle_ceiling
        || lifecycle_without_post_complete_proxy >= root_lifecycle_ceiling
        || START_READY_SECONDS < UID_ADMISSION_SECONDS + start_phase_sum + 600
        || STOP_COMPLETE_SECONDS < stop_phase_sum + 600
    {
        return Err("phase/global deadline graph lost its strict nesting margins".to_owned());
    }
    println!(
        "LOCAL_MONO_TRIAL_SELF_TEST_OK cases=135 live_enabled={} artifact_root={ARTIFACT_ROOT}",
        live_release_enabled()
    );
    Ok(())
}

fn verify_root_broker_deadline_body(body: &str) -> Result<(), String> {
    let ordered = [
        "detach_root_broker_session()?;",
        "verify_root_controller_identity()?;",
        "let root_deadline = Instant::now() + Duration::from_secs(ROOT_BROKER_ABSOLUTE_SECONDS);",
        "let hold = root_prepare_transaction()?;",
        "assign fixed broker socket to uid501",
        "let (proxy_child, proxy_capability, proxy_start) = root_spawn_uid_proxy()?;",
        "let stream = root_accept_uid501_peer(",
        "if root_socket_identity()? != socket_identity {",
        "let protocol_deadline = std::cmp::min(",
        "root_protocol(stream, &mut state, protocol_deadline)",
        "stop_root_spawned_proxy(&mut state, 30, root_deadline)",
    ];
    let mut cursor = 0;
    for step in ordered {
        if body.matches(step).count() != 1 {
            return Err(format!("root lifecycle deadline step count changed: {step}"));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("root lifecycle deadline step moved: {step}"))?;
        cursor += offset + step.len();
    }
    Ok(())
}

fn verify_root_lifecycle_ceiling_body(body: &str) -> Result<(), String> {
    let ordered = [
        ") -> Option<u64> {\n    prepare_seconds",
        ".checked_add(socket_setup_seconds)?",
        ".checked_add(proxy_spawn_seconds)?",
        ".checked_add(accept_seconds)?",
        ".checked_add(protocol_seconds)?",
        ".checked_add(emergency_seconds)?",
        ".checked_add(post_complete_proxy_seconds)?",
        ".checked_mul(6)?",
        ".checked_add(4)?",
        ".checked_div(5)",
    ];
    let mut cursor = 0;
    for step in ordered {
        if body.matches(step).count() != 1 {
            return Err(format!("root lifecycle ceiling summand changed: {step}"));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("root lifecycle ceiling summand moved: {step}"))?;
        cursor += offset + step.len();
    }
    Ok(())
}

fn verify_root_protocol_shutdown_body(guard: &str, protocol: &str) -> Result<(), String> {
    if guard.matches("self.0.shutdown(Shutdown::Both)").count() != 1 {
        return Err("root protocol socket guard lost shutdown(Both)".to_owned());
    }
    verify_ordered_source_steps(
        protocol,
        "root protocol socket shutdown ownership",
        &[
            "set_write_timeout(Some(Duration::from_secs(FAST_PROCESS_BOUND_SECONDS)))",
            "let _shutdown = ProtocolSocketShutdown(",
            "root_send(&mut stream, \"LOCAL_ROOT_BROKER_READY\")?;",
            "receive_guardian_spawned_capability_marker(state, absolute_deadline)?;",
            "let responses = spawn_line_reader(",
        ],
    )?;
    if protocol.matches("let _shutdown = ProtocolSocketShutdown(").count() != 1 {
        return Err("root protocol does not own exactly one shutdown guard".to_owned());
    }
    Ok(())
}

fn verify_root_broker_source_order() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let broker = source_slice(
        source,
        "\nfn root_broker() -> Result<(), String> {",
        "\nfn write_new_private_bytes(",
        "root broker lifecycle deadline",
    )?;
    verify_root_broker_deadline_body(broker)?;
    let shutdown_guard = source_slice(
        source,
        "\nstruct ProtocolSocketShutdown(",
        "\nfn root_protocol(",
        "root protocol socket shutdown guard",
    )?;
    let protocol = source_slice(
        source,
        "\nfn root_protocol(",
        "\nfn root_broker()",
        "root protocol socket shutdown scope",
    )?;
    verify_root_protocol_shutdown_body(shutdown_guard, protocol)?;
    let leaked_reader_clone = protocol.replacen(
        "let _shutdown = ProtocolSocketShutdown(",
        "let _shutdown = (",
        1,
    );
    if leaked_reader_clone == protocol
        || verify_root_protocol_shutdown_body(shutdown_guard, &leaked_reader_clone).is_ok()
    {
        return Err("root protocol source test admitted a reader-clone EOF leak".to_owned());
    }
    let early_deadline_mutant = broker.replacen(
        "let hold = root_prepare_transaction()?;",
        "let protocol_deadline = std::cmp::min(root_deadline, Instant::now());\n    let hold = root_prepare_transaction()?;",
        1,
    );
    if early_deadline_mutant == broker
        || verify_root_broker_deadline_body(&early_deadline_mutant).is_ok()
    {
        return Err("root lifecycle source test admitted a pre-accept protocol deadline".to_owned());
    }

    let ceiling = source_slice(
        source,
        "\nfn reviewed_root_lifecycle_ceiling(",
        "\nfn signature_contract_model(",
        "root lifecycle ceiling arithmetic",
    )?;
    verify_root_lifecycle_ceiling_body(ceiling)?;
    for (label, mutant) in [
        (
            "missing-prepare",
            ceiling.replacen("\n    prepare_seconds\n", "\n    0\n", 1),
        ),
        (
            "missing-socket-setup",
            ceiling.replacen(".checked_add(socket_setup_seconds)?", "", 1),
        ),
        (
            "missing-proxy-spawn",
            ceiling.replacen(".checked_add(proxy_spawn_seconds)?", "", 1),
        ),
        (
            "missing-accept",
            ceiling.replacen(".checked_add(accept_seconds)?", "", 1),
        ),
        (
            "missing-protocol",
            ceiling.replacen(".checked_add(protocol_seconds)?", "", 1),
        ),
        (
            "missing-emergency",
            ceiling.replacen(".checked_add(emergency_seconds)?", "", 1),
        ),
        (
            "missing-post-complete-proxy",
            ceiling.replacen(".checked_add(post_complete_proxy_seconds)?", "", 1),
        ),
        (
            "floored-margin",
            ceiling.replacen(".checked_add(4)?", "", 1),
        ),
    ] {
        if mutant == ceiling || verify_root_lifecycle_ceiling_body(&mutant).is_ok() {
            return Err(format!("root lifecycle source test admitted {label} mutant"));
        }
    }
    Ok(())
}

fn verify_retry_preflight_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let declaration = "\nfn preflight(allow_known_user_residue: bool) -> Result<(), String> {\n";
    let start = source
        .find(declaration)
        .ok_or("retry preflight source declaration is absent")?
        + 1;
    let remainder = &source[start..];
    let end = remainder
        .find("\nfn verify_user_trial_stage() -> Result<(), String> {")
        .ok_or("retry preflight source boundary is absent")?;
    let body = &remainder[..end];
    let deferred_gate = "    if !allow_known_user_residue {\n        require_absent_no_follow(Path::new(TRIAL_ROOT), \"one-shot local trial evidence\")?;\n    }";
    if body.matches("allow_known_user_residue").count() != 2
        || body.matches(deferred_gate).count() != 1
        || body
            .matches("require_absent_no_follow(Path::new(TRIAL_ROOT), \"one-shot local trial evidence\")?;")
            .count()
            != 1
    {
        return Err("retry preflight conditional is no longer limited to fixed trial-root absence"
            .to_owned());
    }
    for required in [
        "require_hash(Path::new(HOST_EXECUTABLE), V6_HOST_SHA256)?;",
        "require_hash(Path::new(LEGACY_EXECUTABLE), LEGACY_HOST_SHA256)?;",
        "require_absent_no_follow(Path::new(PRODUCT_DRIVER), \"product driver baseline\")?;",
        "require_exact_signature(",
        "v7_controller::paired_v7::local_trial_verify_exact_v6_admission()",
        "require_healthy_admission_imported_count()?;",
    ] {
        if !body.contains(required) {
            return Err(format!("retry preflight lost shared gate: {required}"));
        }
    }
    for branch in [
        "\n        [_, mode] if mode == PREFLIGHT_MODE => match preflight(false) {\n",
        "\n        [_, mode] if mode == PREFLIGHT_KNOWN_FAILED_BOOTSTRAP_MODE => match preflight(true) {\n",
    ] {
        if source.matches(branch).count() != 1 {
            return Err(format!("retry preflight mode mapping changed: {branch}"));
        }
    }
    Ok(())
}

fn verify_sealed_pin_publication_source_order() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let start = source
        .find("\nfn root_prepare_transaction() -> Result<NodeIdentity, String> {\n")
        .ok_or("root transaction source declaration is absent")?
        + 1;
    let remainder = &source[start..];
    let end = remainder
        .find("\nfn rename_exclusive(source: &Path, destination: &Path) -> Result<(), String> {")
        .ok_or("root transaction source boundary is absent")?;
    let body = &remainder[..end];
    let ordered_steps = [
        "let pin_temporary = Path::new(ROOT_SEALED).join(\"controller.sha256.tmp\");",
        ".create_new(true)",
        ".write(true)",
        ".mode(0o600)",
        ".custom_flags(O_NOFOLLOW | O_CLOEXEC)",
        ".open(&pin_temporary)",
        "writeln!(pin, \"{controller_hash}\")",
        "pin.sync_all()",
        "pin.set_permissions(fs::Permissions::from_mode(0o444))",
        "pin.sync_all()",
        "require_root_regular(&pin_temporary, 0o444)?;",
        "drop(pin);",
        "fs::rename(&pin_temporary, SEALED_CONTROLLER_PIN)",
        "require_root_regular(Path::new(SEALED_CONTROLLER_PIN), 0o444)?;",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("sealed pin publication step is absent or reordered: {step}"))?;
        cursor += offset + step.len();
    }
    for (step, expected_count) in [
        ("let pin_temporary = Path::new(ROOT_SEALED).join(\"controller.sha256.tmp\");", 1),
        (".create_new(true)", 1),
        (".write(true)", 1),
        (".mode(0o600)", 1),
        (".custom_flags(O_NOFOLLOW | O_CLOEXEC)", 1),
        (".open(&pin_temporary)", 1),
        ("writeln!(pin, \"{controller_hash}\")", 1),
        ("pin.sync_all()", 2),
        ("pin.set_permissions(fs::Permissions::from_mode(0o444))", 1),
        ("require_root_regular(&pin_temporary, 0o444)?;", 1),
        ("drop(pin);", 1),
        ("fs::rename(&pin_temporary, SEALED_CONTROLLER_PIN)", 1),
        ("require_root_regular(Path::new(SEALED_CONTROLLER_PIN), 0o444)?;", 1),
    ] {
        let actual_count = body.matches(step).count();
        if actual_count != expected_count {
            return Err(format!(
                "sealed pin publication step count changed: {step} count={actual_count} expected={expected_count}"
            ));
        }
    }
    Ok(())
}

fn sealed_host_signature_resource_set_is_exact(resources: &[&str]) -> bool {
    resources
        == [
            "Contents/_CodeSignature/CodeResources",
            "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/_CodeSignature/CodeResources",
        ]
}

fn verify_sealed_host_signature_resource_helper_body(body: &str) -> Result<(), String> {
    let ordered_steps = [
        "if unsafe { libc_geteuid() } != 0 || bundle != Path::new(SEALED_HOST_APP) {",
        "require_root_directory(Path::new(ROOT_SEALED), 0o700)?;",
        "require_root_directory(bundle, 0o755)?;",
        "for relative in SEALED_HOST_SIGNATURE_RESOURCES {",
        "let path = bundle.join(relative);",
        ".read(true)",
        ".custom_flags(O_NOFOLLOW | O_CLOEXEC)",
        ".open(&path)",
        "let before = file.metadata()",
        "let named_before = fs::symlink_metadata(&path)",
        "|| before.mode() & 0o777 != 0o600",
        "|| before.dev() != named_before.dev()",
        "file.set_permissions(fs::Permissions::from_mode(0o444))",
        "file.sync_all()",
        "let after = file.metadata()",
        "let named_after = fs::symlink_metadata(&path)",
        "|| after.mode() & 0o777 != 0o444",
        "|| after.dev() != before.dev()",
        "|| after.dev() != named_after.dev()",
        "require_root_regular(&path, 0o444)?;",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        if body.matches(step).count() != 1 {
            return Err(format!(
                "sealed signature-resource publication step count changed: {step}"
            ));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!(
                "sealed signature-resource publication step is absent or reordered: {step}"
            ))?;
        cursor += offset + step.len();
    }
    for forbidden in [
        "driver_regular_files()",
        "read_dir(",
        "Command::new(",
        "run_fixed(",
        "chmod",
        "set_permissions(ROOT_SEALED",
    ] {
        if body.contains(forbidden) {
            return Err(format!(
                "sealed signature-resource publication broadened its scope: {forbidden}"
            ));
        }
    }
    if body.matches("file.set_permissions(").count() != 1
        || body.matches("for relative in SEALED_HOST_SIGNATURE_RESOURCES").count() != 1
    {
        return Err(
            "sealed signature-resource publication is no longer one exact fd operation"
                .to_owned(),
        );
    }
    Ok(())
}

fn verify_sealed_host_signature_resource_root_order(body: &str) -> Result<(), String> {
    let ordered_steps = [
        "copy_tree_root(&source_host, Path::new(SEALED_HOST_APP))?;",
        "if bundle_tree_sha256(Path::new(SEALED_HOST_APP), 0)? != CANDIDATE_HOST_TREE_SHA256 {",
        "require_hash(Path::new(SEALED_HOST_EXECUTABLE), CANDIDATE_HOST_SHA256)?;",
        "publish_sealed_host_signature_resources(Path::new(SEALED_HOST_APP))?;",
        "if bundle_tree_sha256(Path::new(SEALED_HOST_APP), 0)? != SEALED_CANDIDATE_HOST_TREE_SHA256 {",
        "require_exact_signature(\n        Path::new(SEALED_HOST_APP),",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        if body.matches(step).count() != 1 {
            return Err(format!(
                "sealed host normalization/root-proof step count changed: {step}"
            ));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!(
                "sealed host normalization/root-proof step is absent or reordered: {step}"
            ))?;
        cursor += offset + step.len();
    }
    Ok(())
}

fn verify_sealed_host_signature_resource_source_contract() -> Result<(), String> {
    let exact_resources = [
        "Contents/_CodeSignature/CodeResources",
        "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/_CodeSignature/CodeResources",
    ];
    let missing_resource = [exact_resources[0]];
    let duplicate_resource = [exact_resources[0], exact_resources[0]];
    let extra_resource = [exact_resources[0], exact_resources[1], "Contents/Info.plist"];
    if !sealed_host_signature_resource_set_is_exact(SEALED_HOST_SIGNATURE_RESOURCES)
        || SEALED_HOST_SIGNATURE_RESOURCES != exact_resources
        || sealed_host_signature_resource_set_is_exact(&missing_resource)
        || sealed_host_signature_resource_set_is_exact(&duplicate_resource)
        || sealed_host_signature_resource_set_is_exact(&extra_resource)
        || CANDIDATE_HOST_TREE_SHA256
            != "0d6f16b191c8009636530214dbfed8d7018e49efd792f90f7047e1b241e3100a"
        || SEALED_CANDIDATE_HOST_TREE_SHA256
            != "2005ab3a80a52117b2368ccf9c6b7f85e9b9c12689e468ab4b52c91e4b4c225e"
        || CANDIDATE_HOST_TREE_SHA256 == SEALED_CANDIDATE_HOST_TREE_SHA256
    {
        return Err(
            "source/sealed host-tree pins or exact signature-resource set changed".to_owned(),
        );
    }

    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let helper_start = source
        .find("\nfn publish_sealed_host_signature_resources(bundle: &Path) -> Result<(), String> {\n")
        .ok_or("sealed signature-resource publication helper is absent")?
        + 1;
    let helper_remainder = &source[helper_start..];
    let helper_end = helper_remainder
        .find("\nfn verify_no_acl_xattr_or_flags(root: &Path) -> Result<(), String> {")
        .ok_or("sealed signature-resource publication helper boundary is absent")?;
    let helper = &helper_remainder[..helper_end];
    verify_sealed_host_signature_resource_helper_body(helper)?;
    for (label, mutant) in [
        (
            "missing-fchmod",
            helper.replacen(
                "file.set_permissions(fs::Permissions::from_mode(0o444))",
                "Ok(())",
                1,
            ),
        ),
        (
            "broad-chmod",
            helper.replacen(
                "for relative in SEALED_HOST_SIGNATURE_RESOURCES",
                "for relative in driver_regular_files()",
                1,
            ),
        ),
        (
            "missing-post-proof",
            helper.replacen("require_root_regular(&path, 0o444)?;", "", 1),
        ),
    ] {
        if mutant == helper || verify_sealed_host_signature_resource_helper_body(&mutant).is_ok() {
            return Err(format!(
                "sealed signature-resource source test admitted its {label} mutant"
            ));
        }
    }

    let root_start = source
        .find("\nfn root_prepare_transaction() -> Result<NodeIdentity, String> {\n")
        .ok_or("root transaction source declaration is absent from sealed host contract")?
        + 1;
    let root_remainder = &source[root_start..];
    let root_end = root_remainder
        .find("\nfn rename_exclusive(source: &Path, destination: &Path) -> Result<(), String> {")
        .ok_or("root transaction source boundary is absent from sealed host contract")?;
    let root_body = &root_remainder[..root_end];
    verify_sealed_host_signature_resource_root_order(root_body)?;
    for (label, mutant) in [
        (
            "source-tree-pin-reuse",
            root_body.replacen(
                "SEALED_CANDIDATE_HOST_TREE_SHA256",
                "CANDIDATE_HOST_TREE_SHA256",
                1,
            ),
        ),
        (
            "missing-publication",
            root_body.replacen(
                "publish_sealed_host_signature_resources(Path::new(SEALED_HOST_APP))?;",
                "",
                1,
            ),
        ),
        (
            "missing-normalized-tree-proof",
            root_body.replacen(
                "if bundle_tree_sha256(Path::new(SEALED_HOST_APP), 0)? != SEALED_CANDIDATE_HOST_TREE_SHA256 {",
                "if false {",
                1,
            ),
        ),
    ] {
        if mutant == root_body
            || verify_sealed_host_signature_resource_root_order(&mutant).is_ok()
        {
            return Err(format!("sealed host source test admitted its {label} mutant"));
        }
    }
    Ok(())
}

fn verify_candidate_gate_spawn_diagnostics_body(body: &str) -> Result<(), String> {
    let ordered_steps = [
        ".stdout(Stdio::piped())",
        ".stderr(Stdio::piped());",
        "let stdout = match child.stdout.take() {",
        "let stderr = match child.stderr.take() {",
        "let lines = spawn_line_reader(stdout, 80, \"root-owned candidate gate response\");",
        "let stderr_receiver = spawn_bounded_byte_reader(",
        "let root_bound = lines.recv_timeout(Duration::from_secs(60));",
        "line == \"LOCAL_CANDIDATE_GATE_ROOT_BOUND\"",
        "\"failed before root-bound marker\"",
        "let ready = lines.recv_timeout(Duration::from_secs(ROOT_GATE_RESPONSE_SECONDS - 120));",
        "line == \"LOCAL_CANDIDATE_GATE_READY\"",
        "\"failed after root binding but before readiness\"",
        "let (start, phase) = match verify_root_candidate_or_gate(pid) {",
        "Ok((child, root_control, start))",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        if body.matches(step).count() != 1 {
            return Err(format!("candidate gate diagnostic step count changed: {step}"));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!(
                "candidate gate diagnostic step is absent or reordered: {step}"
            ))?;
        cursor += offset + step.len();
    }
    if body.contains(".stderr(Stdio::null())")
        || body.contains("did not authenticate its root channel")
        || body.matches("candidate_gate_failure_diagnostic(").count() != 3
        || body.matches("stderr_receiver,").count() != 3
        || body.matches("16_384").count() != 1
    {
        return Err("candidate gate diagnostic capture was removed or broadened".to_owned());
    }
    Ok(())
}

fn verify_candidate_gate_failure_diagnostic_body(body: &str) -> Result<(), String> {
    let ordered_steps = [
        "let cleanup = terminate_preconfigured_session(",
        "cleanup_deadline,",
        "let final_status = match &cleanup {",
        "Ok(outcome) => format!(\"{:?}\", outcome.status)",
        "Err(_) => \"<unreaped-retained-child>\".to_owned()",
        "stderr_receiver.recv_timeout(Duration::from_secs(2))",
        "final_status={final_status}",
        "stderr={stderr:?}",
        "cleanup={cleanup:?}",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        if body.matches(step).count() != 1 {
            return Err(format!("candidate gate failure diagnostic step count changed: {step}"));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!(
                "candidate gate failure diagnostic step is absent or reordered: {step}"
            ))?;
        cursor += offset + step.len();
    }
    if body.contains("child.wait()") || body.contains("child.try_wait()")
    {
        return Err(
            "candidate gate diagnostics can reap or block before bounded cleanup".to_owned(),
        );
    }
    Ok(())
}

fn verify_bounded_byte_reader_body(body: &str) -> Result<(), String> {
    let ordered_steps = [
        ".take((maximum + 1) as u64)",
        ".read_to_end(&mut bytes)",
        "if bytes.len() > maximum {",
        "Err(format!(\"{label} exceeded its byte bound\"))",
        "sender.send(result)",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        if body.matches(step).count() != 1 {
            return Err(format!("bounded diagnostic reader step count changed: {step}"));
        }
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!(
                "bounded diagnostic reader step is absent or reordered: {step}"
            ))?;
        cursor += offset + step.len();
    }
    Ok(())
}

fn verify_uid_candidate_gate_staged_marker_body(body: &str) -> Result<(), String> {
    let ordered_steps = [
        "verify_root_supervised_uid_helper()?;",
        "println!(\"LOCAL_CANDIDATE_GATE_ROOT_BOUND\");",
        "std::io::stdout().flush()",
        "if unsafe { libc_getpgid(pid as i32) } != pid as i32",
        "require_hash(Path::new(SEALED_HOST_EXECUTABLE), CANDIDATE_HOST_SHA256)?;",
        "require_exact_signature(",
        "println!(\"LOCAL_CANDIDATE_GATE_READY\");",
        "std::io::stdout().flush()",
        ".read_line(&mut command_line)",
    ];
    let mut cursor = 0;
    for step in ordered_steps {
        let offset = body[cursor..]
            .find(step)
            .ok_or_else(|| format!("UID candidate gate marker step is absent or reordered: {step}"))?;
        cursor += offset + step.len();
    }
    if body.matches("LOCAL_CANDIDATE_GATE_ROOT_BOUND").count() != 1
        || body.matches("LOCAL_CANDIDATE_GATE_READY").count() != 1
        || body.matches("std::io::stdout().flush()").count() != 2
    {
        return Err("UID candidate gate staged marker counts changed".to_owned());
    }
    Ok(())
}

fn verify_candidate_gate_diagnostics_source_contract() -> Result<(), String> {
    if 60 + (ROOT_GATE_RESPONSE_SECONDS - 120) != ROOT_GATE_RESPONSE_SECONDS - 60 {
        return Err("staged candidate gate markers changed the total readiness lifetime".to_owned());
    }
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let spawn_start = source
        .find("\nfn root_spawn_candidate_gate() -> Result<(OwnedSessionChild, UnixStream, String), String> {\n")
        .ok_or("candidate gate spawn source declaration is absent")?
        + 1;
    let spawn_remainder = &source[spawn_start..];
    let spawn_end = spawn_remainder
        .find("\nfn root_release_candidate_gate(state: &mut RootBrokerState) -> Result<u32, String> {")
        .ok_or("candidate gate spawn source boundary is absent")?;
    let spawn_body = &spawn_remainder[..spawn_end];
    verify_candidate_gate_spawn_diagnostics_body(spawn_body)?;
    for (label, mutant) in [
        (
            "discarded-stderr",
            spawn_body.replacen(".stderr(Stdio::piped());", ".stderr(Stdio::null());", 1),
        ),
        (
            "missing-root-bound-read",
            spawn_body.replacen(
                "let root_bound = lines.recv_timeout(Duration::from_secs(60));",
                "let root_bound = Ok(Ok(\"LOCAL_CANDIDATE_GATE_ROOT_BOUND\".to_owned()));",
                1,
            ),
        ),
        (
            "missing-pre-ready-diagnostic",
            spawn_body.replacen(
                "\"failed after root binding but before readiness\"",
                "\"failed\"",
                1,
            ),
        ),
    ] {
        if mutant == spawn_body || verify_candidate_gate_spawn_diagnostics_body(&mutant).is_ok() {
            return Err(format!("candidate gate source test admitted its {label} mutant"));
        }
    }

    let reader_start = source
        .find("\nfn spawn_bounded_byte_reader<R: Read + Send + 'static>(\n")
        .ok_or("bounded candidate-gate diagnostic reader is absent")?
        + 1;
    let reader_remainder = &source[reader_start..];
    let reader_end = reader_remainder
        .find("\nfn candidate_gate_failure_diagnostic(\n")
        .ok_or("bounded candidate-gate diagnostic reader boundary is absent")?;
    let reader = &reader_remainder[..reader_end];
    verify_bounded_byte_reader_body(reader)?;
    let unbounded_reader = reader.replacen(
        ".take((maximum + 1) as u64)",
        ".take(u64::MAX)",
        1,
    );
    if unbounded_reader == reader || verify_bounded_byte_reader_body(&unbounded_reader).is_ok() {
        return Err("candidate gate source test admitted an unbounded-stderr mutant".to_owned());
    }

    let diagnostic_start = source
        .find("\nfn candidate_gate_failure_diagnostic(\n")
        .ok_or("candidate gate failure diagnostic helper is absent")?
        + 1;
    let diagnostic_remainder = &source[diagnostic_start..];
    let diagnostic_end = diagnostic_remainder
        .find("\nstruct RootClient {")
        .ok_or("candidate gate failure diagnostic helper boundary is absent")?;
    let diagnostic = &diagnostic_remainder[..diagnostic_end];
    verify_candidate_gate_failure_diagnostic_body(diagnostic)?;
    for (label, mutant) in [
        (
            "reintroduced-post-cleanup-poll",
            diagnostic.replacen(
                "let final_status = match &cleanup {",
                "let _ = child.try_wait();\n    let final_status = match &cleanup {",
                1,
            ),
        ),
        (
            "missing-status",
            diagnostic.replacen("final_status={final_status}", "final_status=missing", 1),
        ),
    ] {
        if mutant == diagnostic
            || verify_candidate_gate_failure_diagnostic_body(&mutant).is_ok()
        {
            return Err(format!(
                "candidate gate failure diagnostic test admitted its {label} mutant"
            ));
        }
    }

    let gate_start = source
        .find("\nfn uid_candidate_gate() -> Result<(), String> {\n")
        .ok_or("UID candidate gate source declaration is absent")?
        + 1;
    let gate_remainder = &source[gate_start..];
    let gate_end = gate_remainder
        .find("\nfn finish_guardian(guardian: &mut GuardianBroker) -> Result<OwnedSessionTermination, String> {")
        .ok_or("UID candidate gate source boundary is absent")?;
    let gate = &gate_remainder[..gate_end];
    verify_uid_candidate_gate_staged_marker_body(gate)?;
    for (label, mutant) in [
        (
            "missing-root-bound-marker",
            gate.replacen("println!(\"LOCAL_CANDIDATE_GATE_ROOT_BOUND\");", "", 1),
        ),
        (
            "premature-ready-marker",
            gate.replacen(
                "println!(\"LOCAL_CANDIDATE_GATE_ROOT_BOUND\");",
                "println!(\"LOCAL_CANDIDATE_GATE_READY\");",
                1,
            ),
        ),
    ] {
        if mutant == gate || verify_uid_candidate_gate_staged_marker_body(&mutant).is_ok() {
            return Err(format!("UID candidate gate source test admitted its {label} mutant"));
        }
    }
    Ok(())
}

fn verify_root_accept_wait_body(body: &str) -> Result<(), String> {
    let loop_start = body
        .find("    loop {\n")
        .ok_or("root accept loop is absent")?;
    let accept_loop = &body[loop_start..];
    let identity_check = "verify_waiting_uid501_proxy_identity(\n            expected_child,\n            expected_pid,\n            expected_start,\n        )?;";
    let deadline_check = "if Instant::now() >= deadline {";
    let accept = "match listener.accept() {";
    let would_block = "Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {";
    let sleep = "thread::sleep(Duration::from_millis(50));";
    if accept_loop.matches(identity_check).count() != 1
        || accept_loop.matches(deadline_check).count() != 1
        || accept_loop.matches(accept).count() != 1
        || accept_loop.matches(would_block).count() != 1
        || accept_loop.matches(sleep).count() != 1
    {
        return Err("root accept loop identity/deadline steps changed".to_owned());
    }
    let identity_offset = accept_loop
        .find(identity_check)
        .ok_or("root accept wait identity check is absent")?;
    let deadline_offset = accept_loop
        .find(deadline_check)
        .ok_or("root accept wait deadline check is absent")?;
    let accept_offset = accept_loop
        .find(accept)
        .ok_or("root accept operation is absent")?;
    let would_block_offset = accept_loop
        .find(would_block)
        .ok_or("root accept WouldBlock branch is absent")?;
    let sleep_offset = accept_loop
        .find(sleep)
        .ok_or("root accept wait sleep is absent")?;
    if !(identity_offset < deadline_offset
        && deadline_offset < accept_offset
        && accept_offset < would_block_offset
        && would_block_offset < sleep_offset)
    {
        return Err("root accept no longer rejects a dead proxy before accepting or waiting"
            .to_owned());
    }
    Ok(())
}

fn verify_root_accept_dead_proxy_source_contract() -> Result<(), String> {
    let source = include_str!("opensteamer-host-local-mono-trial-controller.rs");
    let helper_start = source
        .find("\nfn verify_waiting_uid501_proxy_identity(\n")
        .ok_or("waiting proxy identity source declaration is absent")?
        + 1;
    let helper_remainder = &source[helper_start..];
    let helper_end = helper_remainder
        .find("\nfn root_accept_uid501_peer(\n")
        .ok_or("waiting proxy identity source boundary is absent")?;
    let helper = &helper_remainder[..helper_end];
    let mut helper_cursor = 0;
    for step in [
        "expected_child.id() != expected_pid",
        "retained_child_exited_without_reap(expected_child)?",
        "verify_root_sealed_controller_process(expected_pid)",
        "process_start_identity(expected_pid)",
        "observed_start != expected_start",
    ] {
        if helper.matches(step).count() != 1 {
            return Err(format!("waiting proxy identity step count changed: {step}"));
        }
        let offset = helper[helper_cursor..]
            .find(step)
            .ok_or_else(|| format!("waiting proxy identity step is absent or reordered: {step}"))?;
        helper_cursor += offset + step.len();
    }

    let start = source
        .find("\nfn root_accept_uid501_peer(\n")
        .ok_or("root accept source declaration is absent")?
        + 1;
    let remainder = &source[start..];
    let end = remainder
        .find("\nfn root_socket_identity() -> Result<(u64, u64), String> {")
        .ok_or("root accept source boundary is absent")?;
    let body = &remainder[..end];
    verify_root_accept_wait_body(body)?;

    let identity_check = "verify_waiting_uid501_proxy_identity(\n            expected_child,\n            expected_pid,\n            expected_start,\n        )?;";
    let dead_proxy_mutant = body.replacen(identity_check, "", 1);
    if dead_proxy_mutant == body || verify_root_accept_wait_body(&dead_proxy_mutant).is_ok() {
        return Err("root accept source test admitted a dead-proxy-before-connect mutant".to_owned());
    }

    let broker_start = source
        .find("\nfn root_broker() -> Result<(), String> {\n")
        .ok_or("root broker source declaration is absent from accept contract")?
        + 1;
    let broker_remainder = &source[broker_start..];
    let broker_end = broker_remainder
        .find("\nfn write_new_private_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {")
        .ok_or("root broker source boundary is absent from accept contract")?;
    let broker = &broker_remainder[..broker_end];
    let accept_propagation = "let stream = root_accept_uid501_peer(\n            &listener,\n            proxy_child,\n            proxy_pid,\n            &proxy_start,\n            capability,\n        )?;";
    let failure_cleanup = "Err(error) => {\n            let recovery = root_emergency_cleanup(&mut state, root_deadline);";
    if broker.matches(accept_propagation).count() != 1
        || broker.matches(failure_cleanup).count() != 1
    {
        return Err("root accept failure no longer propagates through emergency cleanup".to_owned());
    }
    Ok(())
}

fn proxy_can_cross_destructive_boundary(arm_durable: bool, exact_identity: bool) -> bool {
    arm_durable && exact_identity
}

fn candidate_gate_can_exec(root_bound: bool, go_received: bool, same_identity: bool) -> bool {
    root_bound && go_received && same_identity
}

fn root_launch_capability_model(
    peer_uid: u32,
    peer_gid: u32,
    exact_root_parent: bool,
    isolated_session: bool,
    one_use: bool,
) -> bool {
    peer_uid == 0 && peer_gid == 0 && exact_root_parent && isolated_session && one_use
}

fn root_peer_admission_model(
    expected_pid: u32,
    peer_pid: u32,
    primary_executable_exact: bool,
    start_identity_exact: bool,
    root_spawn_capability_retained: bool,
) -> bool {
    expected_pid > 0
        && peer_pid == expected_pid
        && primary_executable_exact
        && start_identity_exact
        && root_spawn_capability_retained
}

fn candidate_signal_identity_model(
    retained_child: bool,
    child_id_is_session: bool,
    supervisor_session_excluded: bool,
    member_generation_exact: bool,
    final_member_sid_exact: bool,
    pinned_binary_cannot_setsid: bool,
) -> bool {
    retained_child
        && child_id_is_session
        && supervisor_session_excluded
        && member_generation_exact
        && final_member_sid_exact
        && pinned_binary_cannot_setsid
}

fn reviewed_root_lifecycle_ceiling(
    prepare_seconds: u64,
    socket_setup_seconds: u64,
    proxy_spawn_seconds: u64,
    accept_seconds: u64,
    protocol_seconds: u64,
    emergency_seconds: u64,
    post_complete_proxy_seconds: u64,
) -> Option<u64> {
    prepare_seconds
        .checked_add(socket_setup_seconds)?
        .checked_add(proxy_spawn_seconds)?
        .checked_add(accept_seconds)?
        .checked_add(protocol_seconds)?
        .checked_add(emergency_seconds)?
        .checked_add(post_complete_proxy_seconds)?
        .checked_mul(6)?
        .checked_add(4)?
        .checked_div(5)
}

fn signature_contract_model(
    all_architectures_verified: bool,
    entitlements_empty: bool,
    embedded_leaf_sha256: &str,
) -> bool {
    all_architectures_verified
        && entitlements_empty
        && embedded_leaf_sha256 == DEVELOPMENT_LEAF_SHA256
}

fn v6_restore_recovery_model(
    service_absent: bool,
    capture_server_count: usize,
    sole_process_is_exact_v6: bool,
) -> &'static str {
    match (service_absent, capture_server_count, sole_process_is_exact_v6) {
        (true, 0, _) => "bootstrap",
        (true, 1, true) => "drain-lock-bootstrap",
        (false, 0, _) | (false, 1, true) => "wait-loaded-generation",
        _ => "reject",
    }
}

fn emergency_retry_requires_v6_stop(
    driver_restored: bool,
    v6_restored: bool,
    restore_may_have_begun: bool,
    runtime_lock_absent: bool,
    destructive_history: bool,
) -> bool {
    let restored_runtime_terminal = driver_restored
        && v6_restored
        && !restore_may_have_begun
        && runtime_lock_absent;
    !restored_runtime_terminal && destructive_history
}

fn uid_helper_identity_isolated(
    pid: u32,
    process_group: u32,
    session: u32,
    uid: u32,
    gid: u32,
    supplementary_groups_exact: bool,
) -> bool {
    pid > 0
        && process_group == pid
        && session == pid
        && uid == 501
        && gid == 20
        && supplementary_groups_exact
}

fn classify_absence_result(error: Option<std::io::ErrorKind>) -> &'static str {
    match error {
        None => "present",
        Some(std::io::ErrorKind::NotFound) => "absent",
        Some(_) => "operational-error",
    }
}

fn require_real_directory(path: &Path, expected_mode: u32) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(format!("not a real directory: {}", path.display()));
    }
    if metadata.uid() != 501 || metadata.mode() & 0o7777 != expected_mode {
        return Err(format!(
            "directory owner/mode mismatch: {} uid={} mode={:o}",
            path.display(),
            metadata.uid(),
            metadata.mode() & 0o7777
        ));
    }
    Ok(())
}

fn require_regular_file(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.nlink() != 1 {
        return Err(format!("unsafe regular file: {}", path.display()));
    }
    Ok(())
}

fn bounded_output(
    command: &mut Command,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
) -> Result<Output, String> {
    bounded_output_with_input_internal(
        command,
        None,
        timeout,
        maximum_output,
        label,
        ChildIsolation::FreshProcessGroup,
        false,
    )
}

fn bounded_output_with_input(
    command: &mut Command,
    input: Option<&[u8]>,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
) -> Result<Output, String> {
    bounded_output_with_input_internal(
        command,
        input,
        timeout,
        maximum_output,
        label,
        ChildIsolation::FreshProcessGroup,
        false,
    )
}

fn bounded_output_preconfigured_session(
    command: &mut Command,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
) -> Result<Output, String> {
    bounded_output_with_input_internal(
        command,
        None,
        timeout,
        maximum_output,
        label,
        ChildIsolation::PreconfiguredSession,
        false,
    )
}

fn bounded_output_preconfigured_session_with_configured_stdin(
    command: &mut Command,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
) -> Result<Output, String> {
    bounded_output_with_input_internal(
        command,
        None,
        timeout,
        maximum_output,
        label,
        ChildIsolation::PreconfiguredSession,
        true,
    )
}

pub(crate) fn bounded_output_inherited_helper_group(
    command: &mut Command,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
) -> Result<Output, String> {
    bounded_output_with_input_internal(
        command,
        None,
        timeout,
        maximum_output,
        label,
        ChildIsolation::InheritedHelperGroup,
        false,
    )
}

static ROOT_LAUNCH_CAPABILITY_VERIFIED: OnceLock<bool> = OnceLock::new();
static IMPORTED_COMMAND_COUNT: AtomicU64 = AtomicU64::new(0);
static IMPORTED_COMMAND_LIMIT: AtomicU64 =
    AtomicU64::new(ADMISSION_IMPORTED_COMMAND_MAXIMUM);

fn imported_command_index_allowed(index: u64, limit: u64) -> bool {
    (1..=limit).contains(&index)
}

fn configure_imported_command_limit(limit: u64) -> Result<(), String> {
    if !matches!(
        limit,
        ADMISSION_IMPORTED_COMMAND_MAXIMUM
            | RECOVERY_IMPORTED_COMMAND_MAXIMUM
            | CANDIDATE_IMPORTED_COMMAND_MAXIMUM
            | NO_IMPORTED_COMMAND_MAXIMUM
    ) || IMPORTED_COMMAND_COUNT.load(Ordering::SeqCst) != 0
    {
        return Err("imported-command limit changed after verifier execution".to_owned());
    }
    IMPORTED_COMMAND_LIMIT.store(limit, Ordering::SeqCst);
    Ok(())
}

fn imported_command_limit_for_mode(mode: &str, root_capability_verified: bool) -> Option<u64> {
    match mode {
        UID_ADMISSION_MODE => Some(ADMISSION_IMPORTED_COMMAND_MAXIMUM),
        UID_STOP_V6_MODE | UID_EMERGENCY_V6_MODE if root_capability_verified => {
            Some(RECOVERY_IMPORTED_COMMAND_MAXIMUM)
        }
        UID_FINALIZE_EVIDENCE_MODE if root_capability_verified => {
            Some(ADMISSION_IMPORTED_COMMAND_MAXIMUM)
        }
        UID_VERIFY_CANDIDATE_MODE if root_capability_verified => {
            Some(CANDIDATE_IMPORTED_COMMAND_MAXIMUM)
        }
        UID_VERIFY_HAL_MODE | UID_EMERGENCY_REPAIR_MODE if root_capability_verified => {
            Some(NO_IMPORTED_COMMAND_MAXIMUM)
        }
        _ => None,
    }
}

fn configure_imported_command_limit_for_mode(
    mode: &str,
    root_capability_verified: bool,
) -> Result<(), String> {
    let limit = imported_command_limit_for_mode(mode, root_capability_verified)
        .ok_or("imported-command mode lacks its required root capability")?;
    configure_imported_command_limit(limit)
}

fn require_healthy_admission_imported_count() -> Result<(), String> {
    let observed = IMPORTED_COMMAND_COUNT.load(Ordering::SeqCst);
    if IMPORTED_COMMAND_LIMIT.load(Ordering::SeqCst) != ADMISSION_IMPORTED_COMMAND_MAXIMUM
        || observed != HEALTHY_ADMISSION_IMPORTED_COMMAND_COUNT
    {
        return Err(format!(
            "exact admission imported-command count changed: observed={observed} expected={HEALTHY_ADMISSION_IMPORTED_COMMAND_COUNT}"
        ));
    }
    Ok(())
}

pub(crate) fn bounded_imported_command_output(
    command: &mut Command,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
) -> Result<Output, String> {
    let command_index = IMPORTED_COMMAND_COUNT.fetch_add(1, Ordering::SeqCst) + 1;
    let command_limit = IMPORTED_COMMAND_LIMIT.load(Ordering::SeqCst);
    if !imported_command_index_allowed(command_index, command_limit) {
        return Err(format!(
            "imported historical verifier exceeded its exact {}-command process cap",
            command_limit
        ));
    }
    if ROOT_LAUNCH_CAPABILITY_VERIFIED.get() == Some(&true) {
        bounded_output_inherited_helper_group(command, timeout, maximum_output, label)
    } else {
        bounded_output(command, timeout, maximum_output, label)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ChildIsolation {
    FreshProcessGroup,
    PreconfiguredSession,
    InheritedHelperGroup,
}

fn bounded_output_with_input_internal(
    command: &mut Command,
    input: Option<&[u8]>,
    timeout: Duration,
    maximum_output: usize,
    label: &str,
    isolation: ChildIsolation,
    stdin_configured: bool,
) -> Result<Output, String> {
    if !stdin_configured {
        command.stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });
    }
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    if isolation == ChildIsolation::FreshProcessGroup {
        command.process_group(0);
    }
    let child = command
        .spawn()
        .map_err(|error| format!("could not start {label}: {error}"))?;
    let mut child = if isolation == ChildIsolation::PreconfiguredSession {
        ManagedChild::Owned(OwnedSessionChild::new(child, label))
    } else {
        ManagedChild::Ordinary(child)
    };
    let execution_deadline = Instant::now() + timeout;
    let cleanup_deadline = execution_deadline + Duration::from_secs(3);
    let child_pid = child.id();
    let child_group = unsafe { libc_getpgid(child_pid as i32) };
    let child_session = unsafe { libc_getsid(child_pid as i32) };
    let expected_identity = match isolation {
        ChildIsolation::FreshProcessGroup => child_group == child_pid as i32,
        ChildIsolation::PreconfiguredSession => {
            child_group == child_pid as i32 && child_session == child_pid as i32
        }
        ChildIsolation::InheritedHelperGroup => {
            child_group == unsafe { libc_getpgrp() }
                && child_session == unsafe { libc_getsid(0) }
        }
    };
    if !expected_identity {
        if isolation == ChildIsolation::PreconfiguredSession {
            let cleanup = terminate_preconfigured_session(
                child.owned_mut()?,
                child_pid,
                label,
                cleanup_deadline,
            );
            return Err(format!(
                "{label} did not enter its required process group/session; cleanup={cleanup:?}"
            ));
        }
        let completed = child
            .try_wait()
            .map_err(|error| format!("could not inspect {label} process group: {error}"))?;
        if completed.is_none() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{label} did not enter its required process group/session"));
        }
    }
    if let Some(bytes) = input {
        let mut stdin = match child.stdin.take() {
            Some(value) => value,
            None => {
                let cleanup = if isolation == ChildIsolation::PreconfiguredSession {
                    format!(
                        "{:?}",
                        terminate_preconfigured_session(
                            child.owned_mut()?,
                            child_pid,
                            label,
                            cleanup_deadline,
                        )
                    )
                } else {
                    let _ = child.kill();
                    format!("wait={:?}", child.wait())
                };
                return Err(format!("{label} stdin unavailable; cleanup={cleanup}"));
            }
        };
        let bytes = bytes.to_vec();
        thread::spawn(move || {
            let _ = stdin.write_all(&bytes);
        });
    }
    let stdout = match child.stdout.take() {
        Some(value) => value,
        None => {
            let cleanup = if isolation == ChildIsolation::PreconfiguredSession {
                format!(
                    "{:?}",
                    terminate_preconfigured_session(
                        child.owned_mut()?,
                        child_pid,
                        label,
                        cleanup_deadline,
                    )
                )
            } else {
                let _ = child.kill();
                format!("wait={:?}", child.wait())
            };
            return Err(format!("{label} stdout unavailable; cleanup={cleanup}"));
        }
    };
    let stderr = match child.stderr.take() {
        Some(value) => value,
        None => {
            drop(stdout);
            let cleanup = if isolation == ChildIsolation::PreconfiguredSession {
                format!(
                    "{:?}",
                    terminate_preconfigured_session(
                        child.owned_mut()?,
                        child_pid,
                        label,
                        cleanup_deadline,
                    )
                )
            } else {
                let _ = child.kill();
                format!("wait={:?}", child.wait())
            };
            return Err(format!("{label} stderr unavailable; cleanup={cleanup}"));
        }
    };
    let drain = |mut input: Box<dyn Read + Send>| {
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = Read::by_ref(&mut input)
                .take((maximum_output + 1) as u64)
                .read_to_end(&mut bytes)
                .map(|_| bytes)
                .map_err(|error| error.to_string());
            let _ = sender.send(result);
        });
        receiver
    };
    let stdout_receiver = drain(Box::new(stdout));
    let stderr_receiver = drain(Box::new(stderr));
    let deadline = execution_deadline;
    let status = if isolation == ChildIsolation::PreconfiguredSession {
        loop {
            match owned_session_ready_to_reap(child.owned_mut()?, child_pid, cleanup_deadline) {
                Ok(true) => match reap_quiescent_owned_session(
                    child.owned_mut()?,
                    child_pid,
                    label,
                    cleanup_deadline,
                ) {
                    Ok(status) => break status,
                    Err(error) => {
                        let cleanup = terminate_preconfigured_session(
                            child.owned_mut()?,
                            child_pid,
                            label,
                            cleanup_deadline,
                        );
                        return Err(format!(
                            "{label} reap barrier failed: {error}; cleanup={cleanup:?}"
                        ));
                    }
                },
                Ok(false) => {}
                Err(error) => {
                    let cleanup = terminate_preconfigured_session(
                        child.owned_mut()?,
                        child_pid,
                        label,
                        cleanup_deadline,
                    );
                    return Err(format!(
                        "{label} session barrier failed: {error}; cleanup={cleanup:?}"
                    ));
                }
            }
            let leader_exited = match retained_child_exited_without_reap(child.owned_mut()?) {
                Ok(value) => value,
                Err(error) => {
                    let cleanup = terminate_preconfigured_session(
                        child.owned_mut()?,
                        child_pid,
                        label,
                        cleanup_deadline,
                    );
                    return Err(format!(
                        "{label} nonreaping exit proof failed: {error}; cleanup={cleanup:?}"
                    ));
                }
            };
            if leader_exited {
                let cleanup = terminate_preconfigured_session(
                    child.owned_mut()?,
                    child_pid,
                    label,
                    cleanup_deadline,
                );
                return Err(format!(
                    "{label} exited but its descendant session survived; cleanup={cleanup:?}"
                ));
            }
            if Instant::now() >= deadline {
                let cleanup = terminate_preconfigured_session(
                    child.owned_mut()?,
                    child_pid,
                    label,
                    cleanup_deadline,
                );
                return Err(format!(
                    "{label} exceeded its {}s deadline; cleanup={cleanup:?}",
                    timeout.as_secs()
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
    } else {
        loop {
            match child
                .try_wait()
                .map_err(|error| format!("could not poll {label}: {error}"))?
            {
                Some(status) => break status,
                None if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
                None => {
                    if isolation == ChildIsolation::InheritedHelperGroup {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(format!("{label} exceeded its {}s deadline", timeout.as_secs()));
                    }
                    unsafe { libc_kill(-(child_pid as i32), SIGTERM) };
                    let term_deadline = Instant::now() + Duration::from_millis(500);
                    while Instant::now() < term_deadline && process_group_exists(child_pid)? {
                        let _ = child.try_wait();
                        thread::sleep(Duration::from_millis(20));
                    }
                    if process_group_exists(child_pid)? {
                        unsafe { libc_kill(-(child_pid as i32), SIGKILL) };
                    }
                    let _ = child.wait();
                    let kill_deadline = Instant::now() + Duration::from_secs(2);
                    while Instant::now() < kill_deadline && process_group_exists(child_pid)? {
                        thread::sleep(Duration::from_millis(20));
                    }
                    if process_group_exists(child_pid)? {
                        return Err(format!("{label} timed out and its process group survived"));
                    }
                    return Err(format!("{label} exceeded its {}s deadline", timeout.as_secs()));
                }
            }
        }
    };
    if isolation == ChildIsolation::InheritedHelperGroup {
        let receive = |receiver: mpsc::Receiver<Result<Vec<u8>, String>>, stream: &str| {
            let bytes = receiver
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| format!("{label} {stream} did not drain"))??;
            if bytes.len() > maximum_output {
                return Err(format!("{label} {stream} exceeded its byte bound"));
            }
            Ok(bytes)
        };
        return Ok(Output {
            status,
            stdout: receive(stdout_receiver, "stdout")?,
            stderr: receive(stderr_receiver, "stderr")?,
        });
    }
    if isolation == ChildIsolation::FreshProcessGroup && process_group_exists(child_pid)? {
        unsafe { libc_kill(-(child_pid as i32), SIGTERM) };
        let term_deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < term_deadline && process_group_exists(child_pid)? {
            thread::sleep(Duration::from_millis(20));
        }
        if process_group_exists(child_pid)? {
            unsafe { libc_kill(-(child_pid as i32), SIGKILL) };
        }
        let kill_deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < kill_deadline && process_group_exists(child_pid)? {
            thread::sleep(Duration::from_millis(20));
        }
        if process_group_exists(child_pid)? {
            return Err(format!(
                "{label} exited but its descendant process group survived TERM/KILL"
            ));
        }
        return Err(format!("{label} left a descendant process group after exit"));
    }
    let receive = |receiver: mpsc::Receiver<Result<Vec<u8>, String>>, stream: &str| {
        let bytes = receiver
            .recv_timeout(Duration::from_secs(2))
            .map_err(|_| format!("{label} {stream} did not drain"))??;
        if bytes.len() > maximum_output {
            return Err(format!("{label} {stream} exceeded its byte bound"));
        }
        Ok(bytes)
    };
    Ok(Output {
        status,
        stdout: receive(stdout_receiver, "stdout")?,
        stderr: receive(stderr_receiver, "stderr")?,
    })
}

fn command_output(program: &str, arguments: &[&str]) -> Result<String, String> {
    let output = bounded_output(
        Command::new(program)
            .args(arguments)
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_secs(30),
        4 * 1_048_576,
        program,
    )?;
    if !output.status.success() {
        return Err(format!(
            "{program} failed with {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout)
        .map(|value| value.trim().to_owned())
        .map_err(|_| format!("{program} emitted non-UTF-8 output"))
}

fn sha256(path: &Path) -> Result<String, String> {
    require_regular_file(path)?;
    let text = command_output(
        "/usr/bin/shasum",
        &["-a", "256", path.to_str().ok_or("non-UTF-8 path")?],
    )?;
    let digest = text
        .split_ascii_whitespace()
        .next()
        .ok_or("shasum emitted no digest")?;
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("shasum digest was malformed".to_owned());
    }
    Ok(digest.to_ascii_lowercase())
}

fn require_hash(path: &Path, expected: &str) -> Result<(), String> {
    let actual = sha256(path)?;
    if actual != expected {
        return Err(format!(
            "SHA-256 mismatch for {}: {actual}, expected {expected}",
            path.display()
        ));
    }
    Ok(())
}

fn sha256_until(
    path: &Path,
    deadline: Instant,
    maximum_seconds: u64,
    label: &str,
) -> Result<String, String> {
    require_regular_file(path)?;
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or("deadline-aware SHA-256 proof expired")?;
    let timeout = remaining
        .checked_sub(Duration::from_secs(3))
        .map(|value| {
            std::cmp::min(
                value,
                Duration::from_secs(maximum_seconds),
            )
        })
        .filter(|value| !value.is_zero())
        .ok_or("deadline-aware SHA-256 proof lacks its process teardown reserve")?;
    let output = bounded_output(
        Command::new("/usr/bin/shasum")
            .args(["-a", "256", path.to_str().ok_or("non-UTF-8 path")?])
            .env_clear()
            .env("LC_ALL", "C"),
        timeout,
        65_536,
        label,
    )?;
    if !output.status.success() || !output.stderr.is_empty() {
        return Err(format!(
            "deadline-aware SHA-256 proof failed: status={:?} stderr={}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| "deadline-aware shasum output is not UTF-8")?;
    let line = text
        .strip_suffix('\n')
        .ok_or("deadline-aware shasum output lacks its final newline")?;
    let (digest, emitted_path) = line
        .split_once("  ")
        .ok_or("deadline-aware shasum output is malformed")?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || emitted_path != path.to_str().ok_or("non-UTF-8 path")?
    {
        return Err("deadline-aware shasum identity output changed".to_owned());
    }
    if Instant::now() >= deadline {
        return Err("deadline-aware SHA-256 proof exhausted its absolute deadline".to_owned());
    }
    Ok(digest.to_owned())
}

fn require_hash_until(path: &Path, expected: &str, deadline: Instant) -> Result<(), String> {
    let actual = sha256_until(
        path,
        deadline,
        CANDIDATE_MAPPING_HASH_BOUND_SECONDS,
        "deadline-aware exact process executable hash",
    )?;
    if actual != expected {
        return Err(format!(
            "deadline-aware SHA-256 mismatch for {}",
            path.display()
        ));
    }
    Ok(())
}

fn require_absent_no_follow(path: &Path, label: &str) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("could not prove {label} absent at {}: {error}", path.display())),
        Ok(metadata) => Err(format!(
            "{label} is present at {} (mode={:o} uid={} inode={})",
            path.display(),
            metadata.mode(),
            metadata.uid(),
            metadata.ino()
        )),
    }
}

#[derive(Clone, Debug)]
struct TrialLayout {
    journal: PathBuf,
    result: PathBuf,
    proxy_stdout: PathBuf,
    proxy_stderr: PathBuf,
    mirror_result: PathBuf,
    mirror_stdout: PathBuf,
    mirror_stderr: PathBuf,
    guardian_state: PathBuf,
    guardian_snapshot_result: PathBuf,
    guardian_fence_result: PathBuf,
    guardian_post_publish_fence_result: PathBuf,
    guardian_run_result: PathBuf,
    guardian_repair_result: PathBuf,
    guardian_emergency_repair_result: PathBuf,
    guardian_emergency_repair_attempt_result: PathBuf,
    guardian_final_result: PathBuf,
    guardian_stdout: PathBuf,
    guardian_stderr: PathBuf,
    vpio_stdout: PathBuf,
    vpio_stderr: PathBuf,
    candidate_stdout: PathBuf,
    candidate_stderr: PathBuf,
}

impl TrialLayout {
    fn fixed() -> Self {
        let root = Path::new(TRIAL_ROOT);
        let probes = Path::new(TRIAL_PROBES);
        Self {
            journal: root.join("journal.log"),
            result: root.join("result.txt"),
            proxy_stdout: root.join("uid-guardian.stdout"),
            proxy_stderr: root.join("uid-guardian.stderr"),
            mirror_result: probes.join("mirror-loopback.json"),
            mirror_stdout: probes.join("mirror-loopback.stdout"),
            mirror_stderr: probes.join("mirror-loopback.stderr"),
            guardian_state: probes.join("vpio-default-route-state.json"),
            guardian_snapshot_result: probes.join("vpio-guardian-snapshot.json"),
            guardian_fence_result: probes.join("vpio-guardian-prestop-fence.json"),
            guardian_post_publish_fence_result: probes
                .join("vpio-guardian-post-publish-fence.json"),
            guardian_run_result: probes.join("vpio-guardian-run.json"),
            guardian_repair_result: probes.join("vpio-guardian-repair.json"),
            guardian_emergency_repair_result: probes.join("vpio-guardian-emergency-repair.json"),
            guardian_emergency_repair_attempt_result: probes
                .join("vpio-guardian-emergency-repair.attempt.json"),
            guardian_final_result: probes.join("vpio-guardian-final.json"),
            guardian_stdout: probes.join("vpio-guardian.stdout"),
            guardian_stderr: probes.join("vpio-guardian.stderr"),
            vpio_stdout: probes.join("vpio.stdout"),
            vpio_stderr: probes.join("vpio.stderr"),
            candidate_stdout: root.join("candidate.stdout"),
            candidate_stderr: root.join("candidate.stderr"),
        }
    }
}

fn create_new_private(path: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    let descriptor = file.metadata().map_err(|error| error.to_string())?;
    let named = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if !descriptor.is_file()
        || descriptor.dev() != named.dev()
        || descriptor.ino() != named.ino()
        || descriptor.uid() != 501
        || descriptor.nlink() != 1
        || descriptor.mode() & 0o777 != 0o600
    {
        return Err(format!("new private file identity is unsafe: {}", path.display()));
    }
    Ok(file)
}

fn append_journal(layout: &TrialLayout, state: &str) -> Result<(), String> {
    if state.is_empty()
        || state.len() > 256
        || state.bytes().any(|byte| byte == b'\n' || byte == b'\r' || byte == 0)
    {
        return Err("journal state is malformed".to_owned());
    }
    let mut file = OpenOptions::new()
        .append(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(&layout.journal)
        .map_err(|error| format!("could not append local trial journal: {error}"))?;
    let before = file.metadata().map_err(|error| error.to_string())?;
    let named = fs::symlink_metadata(&layout.journal).map_err(|error| error.to_string())?;
    if before.dev() != named.dev()
        || before.ino() != named.ino()
        || before.uid() != 501
        || before.nlink() != 1
        || before.mode() & 0o777 != 0o600
    {
        return Err("local trial journal identity changed".to_owned());
    }
    writeln!(file, "STATE {state}").map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())
}

fn append_private_line(path: &Path, line: &str) -> Result<(), String> {
    if line.is_empty() || line.len() > 512 || line.contains(['\n', '\r', '\0']) {
        return Err("private status line is malformed".to_owned());
    }
    let mut file = OpenOptions::new()
        .append(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("could not append {}: {error}", path.display()))?;
    let descriptor = file.metadata().map_err(|error| error.to_string())?;
    let named = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if !descriptor.is_file()
        || descriptor.dev() != named.dev()
        || descriptor.ino() != named.ino()
        || descriptor.uid() != 501
        || descriptor.nlink() != 1
        || descriptor.mode() & 0o777 != 0o600
    {
        return Err("private status identity changed".to_owned());
    }
    writeln!(file, "{line}").map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())
}

fn stable_private_sha256(path: &Path) -> Result<String, String> {
    let before = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !before.is_file()
        || before.file_type().is_symlink()
        || before.uid() != 501
        || before.nlink() != 1
        || before.mode() & 0o777 != 0o600
    {
        return Err(format!("private evidence metadata is unsafe: {}", path.display()));
    }
    let digest = sha256(path)?;
    let after = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
    {
        return Err(format!("private evidence changed while hashing: {}", path.display()));
    }
    Ok(digest)
}

fn stable_private_sha256_until(path: &Path, deadline: Instant) -> Result<String, String> {
    let before = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !before.is_file()
        || before.file_type().is_symlink()
        || before.uid() != 501
        || before.nlink() != 1
        || before.mode() & 0o777 != 0o600
    {
        return Err(format!("private evidence metadata is unsafe: {}", path.display()));
    }
    let digest = sha256_until(
        path,
        deadline,
        COMMAND_BOUND_SECONDS,
        "deadline-aware private evidence hash",
    )?;
    let after = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if Instant::now() >= deadline
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
    {
        return Err(format!(
            "private evidence changed during deadline-aware hash: {}",
            path.display()
        ));
    }
    Ok(digest)
}

fn read_bounded_utf8(path: &Path, maximum: u64, owner: u32, mode: u32) -> Result<String, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != owner
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != mode
        || metadata.len() > maximum
    {
        return Err(format!("bounded input metadata is unsafe: {}", path.display()));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)
        .map_err(|error| error.to_string())?;
    let descriptor = file.metadata().map_err(|error| error.to_string())?;
    if descriptor.dev() != metadata.dev() || descriptor.ino() != metadata.ino() {
        return Err(format!("bounded input was replaced: {}", path.display()));
    }
    let mut bytes = Vec::with_capacity(descriptor.len() as usize);
    Read::by_ref(&mut file)
        .take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > maximum {
        return Err(format!("bounded input is too large: {}", path.display()));
    }
    let after = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if descriptor.dev() != after.dev()
        || descriptor.ino() != after.ino()
        || descriptor.len() != after.len()
    {
        return Err(format!("bounded input changed while reading: {}", path.display()));
    }
    String::from_utf8(bytes).map_err(|_| format!("input is not UTF-8: {}", path.display()))
}

fn sha256_bytes(bytes: &[u8]) -> Result<String, String> {
    let output = bounded_output_with_input(
        Command::new("/usr/bin/shasum")
            .args(["-a", "256"])
            .env_clear()
            .env("LC_ALL", "C"),
        Some(bytes),
        Duration::from_secs(30),
        65_536,
        "hash reviewed bytes",
    )?;
    if !output.status.success() {
        return Err(format!(
            "shasum of bytes failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "shasum output is not UTF-8")?;
    let digest = text.split_ascii_whitespace().next().ok_or("shasum emitted no digest")?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("shasum digest was malformed".to_owned());
    }
    Ok(digest.to_owned())
}

fn sha256_bytes_until(
    bytes: &[u8],
    deadline: Instant,
    maximum_seconds: u64,
    label: &str,
) -> Result<String, String> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or("deadline-aware byte hash expired")?;
    let timeout = remaining
        .checked_sub(Duration::from_secs(3))
        .map(|value| std::cmp::min(value, Duration::from_secs(maximum_seconds)))
        .filter(|value| !value.is_zero())
        .ok_or("deadline-aware byte hash lacks its process teardown reserve")?;
    let output = bounded_output_with_input(
        Command::new("/usr/bin/shasum")
            .args(["-a", "256"])
            .env_clear()
            .env("LC_ALL", "C"),
        Some(bytes),
        timeout,
        65_536,
        label,
    )?;
    if !output.status.success() || !output.stderr.is_empty() {
        return Err(format!(
            "deadline-aware byte hash failed: status={:?} stderr={}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| "deadline-aware byte hash output is not UTF-8")?;
    let digest = text
        .strip_suffix("  -\n")
        .ok_or("deadline-aware byte hash output changed")?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || Instant::now() >= deadline
    {
        return Err("deadline-aware byte hash digest/deadline changed".to_owned());
    }
    Ok(digest.to_owned())
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HashFileIdentity {
    device: u64,
    inode: u64,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

fn hash_file_identity(path: &Path) -> Result<HashFileIdentity, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect batch-hash input {}: {error}", path.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.nlink() != 1 {
        return Err(format!("unsafe batch-hash input: {}", path.display()));
    }
    Ok(HashFileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        length: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
    })
}

fn sha256_many(paths: &[PathBuf]) -> Result<Vec<String>, String> {
    if paths.is_empty() || paths.len() > 512 {
        return Err("batch hash file count is outside its reviewed bound".to_owned());
    }
    let mut identities = Vec::with_capacity(paths.len());
    for path in paths {
        let bytes = path.as_os_str().as_bytes();
        if bytes.contains(&0) || bytes.contains(&b'\n') || bytes.contains(&b'\r') || bytes.contains(&b'\\') {
            return Err(format!("batch hash path has unsafe output delimiters: {}", path.display()));
        }
        identities.push(hash_file_identity(path)?);
    }
    let output = bounded_output(
        Command::new("/usr/bin/shasum")
            .args(["-a", "256"])
            .args(paths)
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Duration::from_secs(BATCH_HASH_BOUND_SECONDS),
        4 * 1_048_576,
        "batch hash exact bundle files",
    )?;
    if !output.status.success() {
        return Err(format!(
            "batch bundle hash failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "batch hash output is not UTF-8")?;
    let lines = text.lines().collect::<Vec<_>>();
    if lines.len() != paths.len() {
        return Err("batch hash output count changed".to_owned());
    }
    let mut digests = Vec::with_capacity(paths.len());
    for (index, (line, path)) in lines.iter().zip(paths).enumerate() {
        let path_text = path.to_str().ok_or("batch hash path is not UTF-8")?;
        if line.len() != 66 + path_text.len()
            || line.as_bytes().get(64..66) != Some(b"  ")
            || line.get(66..) != Some(path_text)
        {
            return Err(format!("batch hash output path changed at index {index}"));
        }
        let digest = &line[..64];
        if !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(format!("batch hash digest is malformed at index {index}"));
        }
        digests.push(digest.to_owned());
    }
    for (path, before) in paths.iter().zip(&identities) {
        if hash_file_identity(path)? != *before {
            return Err(format!("batch-hash input changed while open: {}", path.display()));
        }
    }
    Ok(digests)
}

fn bundle_tree_sha256(root: &Path, expected_owner: u32) -> Result<String, String> {
    fn walk(
        root: &Path,
        relative: &Path,
        expected_owner: u32,
        manifest: &mut Vec<u8>,
        file_slots: &mut Vec<(usize, PathBuf)>,
    ) -> Result<(), String> {
        let absolute = if relative.as_os_str().is_empty() {
            root.to_path_buf()
        } else {
            root.join(relative)
        };
        let metadata = fs::symlink_metadata(&absolute)
            .map_err(|error| format!("could not inspect {}: {error}", absolute.display()))?;
        if metadata.uid() != expected_owner {
            return Err(format!("tree owner changed at {}", absolute.display()));
        }
        let relative_text = if relative.as_os_str().is_empty() {
            "."
        } else {
            relative.to_str().ok_or("tree path is not UTF-8")?
        };
        let mode = metadata.mode() & 0o777;
        if metadata.file_type().is_dir() {
            write!(manifest, "Directory|{mode:o}|{relative_text}\0")
                .map_err(|error| error.to_string())?;
            let mut children = fs::read_dir(&absolute)
                .map_err(|error| error.to_string())?
                .map(|entry| entry.map(|value| value.file_name()))
                .collect::<std::io::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?;
            children.sort();
            for child in children {
                if child.as_bytes().contains(&0) {
                    return Err("tree child contains NUL".to_owned());
                }
                walk(
                    root,
                    &relative.join(child),
                    expected_owner,
                    manifest,
                    file_slots,
                )?;
            }
        } else if metadata.file_type().is_file() {
            if metadata.nlink() != 1 {
                return Err(format!("tree contains a hard-linked file: {}", absolute.display()));
            }
            write!(manifest, "Regular File|{mode:o}|{relative_text}\0")
                .map_err(|error| error.to_string())?;
            let digest_offset = manifest.len();
            manifest.extend_from_slice(b"0000000000000000000000000000000000000000000000000000000000000000\0");
            file_slots.push((digest_offset, absolute));
        } else if metadata.file_type().is_symlink() {
            let target = fs::read_link(&absolute).map_err(|error| error.to_string())?;
            let target_text = target.to_str().ok_or("symlink target is not UTF-8")?;
            if target.is_absolute()
                || target.components().any(|component| component == std::path::Component::ParentDir)
            {
                return Err(format!("tree symlink target escapes: {}", absolute.display()));
            }
            write!(manifest, "Symbolic Link|{mode:o}|{relative_text}\0{target_text}\0")
                .map_err(|error| error.to_string())?;
        } else {
            return Err(format!("tree contains a special node: {}", absolute.display()));
        }
        Ok(())
    }

    let mut manifest = Vec::new();
    let mut file_slots = Vec::new();
    walk(
        root,
        Path::new(""),
        expected_owner,
        &mut manifest,
        &mut file_slots,
    )?;
    let paths = file_slots
        .iter()
        .map(|(_, path)| path.clone())
        .collect::<Vec<_>>();
    let digests = sha256_many(&paths)?;
    for ((offset, _), digest) in file_slots.iter().zip(digests) {
        manifest[*offset..*offset + 64].copy_from_slice(digest.as_bytes());
    }
    sha256_bytes(&manifest)
}

fn expected_driver_nodes() -> &'static [(&'static str, &'static str, u32)] {
    &[
        (".", "directory", 0o755),
        ("Contents", "directory", 0o755),
        ("Contents/Info.plist", "file", 0o644),
        ("Contents/MacOS", "directory", 0o755),
        (
            "Contents/MacOS/OpensteamerVirtualMicrophone",
            "file",
            0o755,
        ),
        ("Contents/Resources", "directory", 0o755),
        (
            "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
            "file",
            0o644,
        ),
        ("Contents/Resources/en.lproj", "directory", 0o755),
        (
            "Contents/Resources/en.lproj/Localizable.strings",
            "file",
            0o644,
        ),
        ("Contents/_CodeSignature", "directory", 0o755),
        ("Contents/_CodeSignature/CodeResources", "file", 0o644),
    ]
}

fn driver_regular_files() -> &'static [&'static str] {
    &[
        "Contents/Info.plist",
        "Contents/MacOS/OpensteamerVirtualMicrophone",
        "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
        "Contents/Resources/en.lproj/Localizable.strings",
        "Contents/_CodeSignature/CodeResources",
    ]
}

fn verify_driver_tree(bundle: &Path, expected_owner: u32) -> Result<(), String> {
    fn walk(
        root: &Path,
        relative: &Path,
        expected_owner: u32,
        output: &mut Vec<(String, String, u32)>,
    ) -> Result<(), String> {
        let absolute = if relative.as_os_str().is_empty() {
            root.to_path_buf()
        } else {
            root.join(relative)
        };
        let metadata = fs::symlink_metadata(&absolute)
            .map_err(|error| format!("could not inspect {}: {error}", absolute.display()))?;
        if metadata.uid() != expected_owner {
            return Err(format!("driver node owner changed: {}", absolute.display()));
        }
        let kind = if metadata.file_type().is_dir() {
            "directory"
        } else if metadata.file_type().is_file() && metadata.nlink() == 1 {
            "file"
        } else {
            "unexpected"
        };
        let display = if relative.as_os_str().is_empty() {
            ".".to_owned()
        } else {
            relative.to_str().ok_or("driver path is not UTF-8")?.to_owned()
        };
        output.push((display, kind.to_owned(), metadata.mode() & 0o777));
        if metadata.file_type().is_dir() {
            let mut children = fs::read_dir(&absolute)
                .map_err(|error| error.to_string())?
                .map(|entry| entry.map(|value| value.file_name()))
                .collect::<std::io::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?;
            children.sort();
            for child in children {
                walk(root, &relative.join(child), expected_owner, output)?;
            }
        }
        Ok(())
    }

    let mut actual = Vec::new();
    walk(bundle, Path::new(""), expected_owner, &mut actual)?;
    let expected: Vec<(String, String, u32)> = expected_driver_nodes()
        .iter()
        .map(|(path, kind, mode)| (path.to_string(), kind.to_string(), *mode))
        .collect();
    if actual != expected {
        return Err("driver lstat topology differs from its exact pin".to_owned());
    }
    let mut manifest = Vec::new();
    for (path, kind, mode) in &actual {
        let type_name = if kind == "directory" {
            "Directory"
        } else {
            "Regular File"
        };
        write!(manifest, "{type_name}|{mode:o}|{path}\0")
            .map_err(|error| error.to_string())?;
    }
    let driver_files = driver_regular_files()
        .iter()
        .map(|relative| bundle.join(relative))
        .collect::<Vec<_>>();
    let driver_digests = sha256_many(&driver_files)?;
    for (relative, digest) in driver_regular_files().iter().zip(&driver_digests) {
        write!(manifest, "{relative}\0{digest}\0").map_err(|error| error.to_string())?;
    }
    let actual_tree = sha256_bytes(&manifest)?;
    if actual_tree != CANDIDATE_DRIVER_TREE_SHA256 {
        return Err(format!(
            "driver tree hash changed: {actual_tree}, expected {CANDIDATE_DRIVER_TREE_SHA256}"
        ));
    }
    if driver_digests.get(1).map(String::as_str) != Some(CANDIDATE_DRIVER_SHA256) {
        return Err("driver executable hash changed inside the exact batch".to_owned());
    }
    Ok(())
}

fn create_private_signature_scratch() -> Result<PathBuf, String> {
    let parent = Path::new("/private/tmp");
    let parent_metadata = fs::symlink_metadata(parent)
        .map_err(|error| format!("could not inspect fixed signature scratch parent: {error}"))?;
    if !parent_metadata.is_dir()
        || parent_metadata.file_type().is_symlink()
        || parent_metadata.uid() != 0
        || parent_metadata.gid() != 0
        || parent_metadata.mode() & 0o7777 != 0o1777
    {
        return Err("fixed signature scratch parent metadata is unsafe".to_owned());
    }
    let pid = unsafe { libc_getpid() };
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "system clock predates the Unix epoch")?
        .as_nanos();
    for attempt in 0_u8..16 {
        let candidate = parent.join(format!(
            ".opensteamer-local-signature-{pid}-{epoch}-{attempt}"
        ));
        let create = fs::DirBuilder::new().mode(0o700).create(&candidate);
        match create {
            Ok(()) => {
                let metadata = fs::symlink_metadata(&candidate)
                    .map_err(|error| format!("could not inspect signature scratch: {error}"))?;
                if !metadata.is_dir()
                    || metadata.file_type().is_symlink()
                    || metadata.uid() != unsafe { libc_geteuid() }
                    || metadata.mode() & 0o7777 != 0o700
                {
                    return Err("new signature scratch metadata is unsafe".to_owned());
                }
                return Ok(candidate);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("could not create signature scratch: {error}")),
        }
    }
    Err("could not allocate a collision-absent signature scratch".to_owned())
}

fn require_embedded_leaf_certificate(bundle: &Path) -> Result<(), String> {
    let scratch = create_private_signature_scratch()?;
    let prefix = scratch.join("embedded-cert-");
    let extract_argument = format!(
        "--extract-certificates={}",
        prefix.to_str().ok_or("non-UTF-8 certificate prefix")?
    );
    let operation = (|| -> Result<(), String> {
        let output = bounded_output(
            Command::new("/usr/bin/codesign")
                .args([
                    "-d",
                    &extract_argument,
                    bundle.to_str().ok_or("non-UTF-8 bundle path")?,
                ])
                .env_clear()
                .env("LC_ALL", "C")
                .current_dir("/"),
            Duration::from_secs(30),
            1_048_576,
            "extract embedded signing certificate chain",
        )?;
        if !output.status.success() {
            return Err(format!(
                "could not extract embedded certificate for {}: {}",
                bundle.display(),
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        let mut entries = fs::read_dir(&scratch)
            .map_err(|error| format!("could not enumerate embedded certificates: {error}"))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("could not enumerate embedded certificates: {error}"))?;
        entries.sort_by_key(|entry| entry.file_name());
        if entries.is_empty() {
            return Err("codesign extracted no embedded certificate chain".to_owned());
        }
        for entry in &entries {
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| "embedded certificate filename is not UTF-8")?;
            let suffix = name
                .strip_prefix("embedded-cert-")
                .ok_or("codesign created an unexpected scratch entry")?;
            if suffix.is_empty() || !suffix.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err("codesign created a malformed certificate filename".to_owned());
            }
            let metadata = fs::symlink_metadata(entry.path())
                .map_err(|error| format!("could not inspect embedded certificate: {error}"))?;
            if !metadata.is_file()
                || metadata.file_type().is_symlink()
                || metadata.uid() != unsafe { libc_geteuid() }
                || metadata.nlink() != 1
            {
                return Err("embedded certificate scratch entry is unsafe".to_owned());
            }
        }
        let leaf = scratch.join("embedded-cert-0");
        let leaf_hash = sha256(&leaf)?;
        if leaf_hash != DEVELOPMENT_LEAF_SHA256 {
            return Err(format!(
                "embedded signing leaf SHA-256 changed: {leaf_hash}, expected {DEVELOPMENT_LEAF_SHA256}"
            ));
        }
        Ok(())
    })();
    let cleanup = (|| -> Result<(), String> {
        let entries = fs::read_dir(&scratch)
            .map_err(|error| format!("could not enumerate signature scratch for cleanup: {error}"))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("could not enumerate signature scratch for cleanup: {error}"))?;
        for entry in entries {
            let metadata = fs::symlink_metadata(entry.path())
                .map_err(|error| format!("could not inspect signature scratch cleanup entry: {error}"))?;
            if !metadata.is_file()
                || metadata.file_type().is_symlink()
                || metadata.uid() != unsafe { libc_geteuid() }
                || metadata.nlink() != 1
            {
                return Err("refused unsafe signature scratch cleanup".to_owned());
            }
            fs::remove_file(entry.path())
                .map_err(|error| format!("could not remove signature scratch entry: {error}"))?;
        }
        fs::remove_dir(&scratch)
            .map_err(|error| format!("could not remove signature scratch directory: {error}"))
    })();
    match (operation, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Err(operation_error), Err(cleanup_error)) => Err(format!(
            "{operation_error}; signature scratch cleanup also failed: {cleanup_error}"
        )),
    }
}

fn require_exact_signature(
    bundle: &Path,
    identifier: &str,
    expected_cdhash: &str,
    require_runtime: bool,
) -> Result<(), String> {
    command_output(
        "/usr/bin/codesign",
        &[
            "--verify",
            "--strict",
            "--all-architectures",
            bundle.to_str().ok_or("non-UTF-8 bundle path")?,
        ],
    )?;
    let details = bounded_output(
        Command::new("/usr/bin/codesign")
        .args([
            "-d",
            "--all-architectures",
            "--verbose=4",
            bundle.to_str().ok_or("non-UTF-8 bundle path")?,
        ])
        .env_clear()
        .env("LC_ALL", "C"),
        Duration::from_secs(30),
        1_048_576,
        "inspect code signature",
    )?;
    if !details.status.success() {
        return Err(format!("codesign metadata failed for {}", bundle.display()));
    }
    let text = String::from_utf8_lossy(&details.stderr);
    for needle in [
        format!("Identifier={identifier}"),
        format!("TeamIdentifier={TEAM_ID}"),
        format!("CDHash={expected_cdhash}"),
        "Authority=Apple Development: Ahmed Elamin (92LVX32M8K)".to_owned(),
    ] {
        if !text.lines().any(|line| line == needle) {
            return Err(format!("signature field missing for {}: {needle}", bundle.display()));
        }
    }
    if require_runtime && !text.contains("flags=0x10000(runtime)") {
        return Err(format!("hardened runtime flag missing for {}", bundle.display()));
    }
    let entitlements = bounded_output(
        Command::new("/usr/bin/codesign")
            .args([
                "-d",
                "--all-architectures",
                "--entitlements",
                "-",
                bundle.to_str().ok_or("non-UTF-8 bundle path")?,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Duration::from_secs(30),
        1_048_576,
        "inspect embedded entitlements",
    )?;
    if !entitlements.status.success() || !entitlements.stdout.is_empty() {
        return Err(format!("embedded entitlements are not empty for {}", bundle.display()));
    }
    let requirement = format!(
        "identifier \"{identifier}\" and anchor apple generic and certificate leaf[subject.OU] = \"{TEAM_ID}\" and certificate leaf = H\"{DEVELOPMENT_IDENTITY_SHA1}\""
    );
    command_output(
        "/usr/bin/codesign",
        &[
            "--verify",
            "--strict",
            "--all-architectures",
            &format!("-R={requirement}"),
            bundle.to_str().ok_or("non-UTF-8 bundle path")?,
        ],
    )?;
    require_embedded_leaf_certificate(bundle)
}

fn guardian_evidence_validation_program(
    expected_mode: &str,
    expect_removed: bool,
    require_exact_input: bool,
) -> String {
    let expect_post_publish = matches!(
        expected_mode,
        "broker-post-publish-fence" | "broker-run" | "broker-final"
    );
    let expect_pre_epoch = expected_mode.starts_with("broker-");
    format!(
        r#"import hashlib,json,sys
v=json.load(sys.stdin)
def checkpoint(c):
 assert set(c)=={{'sequence','inputNotifications','outputNotifications','systemOutputNotifications','overflowed'}}
 assert type(c['overflowed']) is bool
 for k in ['sequence','inputNotifications','outputNotifications','systemOutputNotifications']:
  assert type(c[k]) is int and 0<=c[k]<=2**64-1
 assert c['sequence']==c['inputNotifications']+c['outputNotifications']+c['systemOutputNotifications']
 raw=('sequence=%d\ninput=%d\noutput=%d\nsystem_output=%d\noverflowed=%d\n' % (c['sequence'],c['inputNotifications'],c['outputNotifications'],c['systemOutputNotifications'],1 if c['overflowed'] else 0)).encode()
 return hashlib.sha256(raw).hexdigest()
assert v['schema']=='opensteamer.v7-default-route-guardian.v1'
assert v['mode']=={expected_mode:?} and v['passed'] is True and v['baselineStable'] is True
assert v['outputsUnchanged'] is True and v['hiddenEndpointNeverDefault'] is True
assert v['virtualEndpointsNeverOutputDefault'] is True and v['failureCode']=='none'
assert v['listener']['removedAndDrained'] is {expect_removed_python}
assert v['listener']['countersMonotonic'] is True
assert v['listener']['preEpochBaselineArmed'] is {expect_pre_epoch_python}
assert v['listener']['preEpochUIDMismatchOrReadFailure'] is False
assert v['listener']['postPublishEpochEstablished'] is {expect_post_publish_python}
a=v['listener']['absoluteFinal']; e=v['listener']['postPublishEpoch']
assert checkpoint(a) and checkpoint(e)==v['listener']['postPublishEpochFingerprint']
assert a['overflowed'] is False and e['overflowed'] is False
assert v['listener']['finalSequence']==a['sequence']
assert all(a[k]>=e[k] for k in ['sequence','inputNotifications','outputNotifications','systemOutputNotifications'])
assert v['listener']['inputNotifications']==a['inputNotifications']-e['inputNotifications']
assert v['listener']['outputNotifications']==a['outputNotifications']-e['outputNotifications']
assert v['listener']['systemOutputNotifications']==a['systemOutputNotifications']-e['systemOutputNotifications']
assert (v['listener']['sequenceAtSnapshot']==e['sequence']) if {expect_post_publish_python} else all(e[k]==0 for k in ['sequence','inputNotifications','outputNotifications','systemOutputNotifications'])
assert v['listener']['outputNotifications']==0 and v['listener']['systemOutputNotifications']==0
assert (a==e and v['listener']['inputNotifications']==0) if v['mode']=='broker-post-publish-fence' else True
assert (v['inputRestored'] is True and v['newerInputChoicePreserved'] is False) if {require_exact_python} else (v['inputRestored'] is True or v['newerInputChoicePreserved'] is True)"#,
        expect_removed_python = if expect_removed { "True" } else { "False" },
        expect_pre_epoch_python = if expect_pre_epoch { "True" } else { "False" },
        expect_post_publish_python = if expect_post_publish { "True" } else { "False" },
        require_exact_python = if require_exact_input { "True" } else { "False" },
    )
}

fn verify_guardian_evidence(
    path: &Path,
    expected_mode: &str,
    expect_removed: bool,
    require_exact_input: bool,
) -> Result<String, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect guardian evidence: {error}"))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > 1_048_576
    {
        return Err("guardian evidence metadata is unsafe".to_owned());
    }
    let text = read_bounded_utf8(path, 1_048_576, 501, 0o600)?;
    let evidence_hash = sha256_bytes(text.as_bytes())?;
    let program = guardian_evidence_validation_program(
        expected_mode,
        expect_removed,
        require_exact_input,
    );
    let output = bounded_output_with_input(
        Command::new("/usr/bin/python3")
            .args(["-I", "-S", "-c", &program])
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Some(text.as_bytes()),
        Duration::from_secs(10),
        1_048_576,
        "guardian evidence validator",
    )?;
    if !output.status.success() {
        return Err(format!(
            "guardian evidence contract failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(evidence_hash)
}

fn verify_guardian_evidence_until(
    path: &Path,
    expected_mode: &str,
    expect_removed: bool,
    require_exact_input: bool,
    deadline: Instant,
) -> Result<String, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect guardian evidence: {error}"))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > 1_048_576
    {
        return Err("guardian evidence metadata is unsafe".to_owned());
    }
    let text = read_bounded_utf8(path, 1_048_576, 501, 0o600)?;
    let hash_deadline = deadline
        .checked_sub(Duration::from_secs(GUARDIAN_EVIDENCE_JSON_SECONDS + 3))
        .ok_or("guardian evidence deadline cannot reserve its JSON validator")?;
    let evidence_hash = sha256_bytes_until(
        text.as_bytes(),
        hash_deadline,
        GUARDIAN_EVIDENCE_HASH_SECONDS,
        "deadline-aware guardian evidence hash",
    )?;
    let program = guardian_evidence_validation_program(
        expected_mode,
        expect_removed,
        require_exact_input,
    );
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or("guardian evidence JSON deadline expired")?;
    let timeout = remaining
        .checked_sub(Duration::from_secs(3))
        .map(|value| {
            std::cmp::min(
                value,
                Duration::from_secs(GUARDIAN_EVIDENCE_JSON_SECONDS),
            )
        })
        .filter(|value| !value.is_zero())
        .ok_or("guardian evidence JSON validator lacks its teardown reserve")?;
    let output = bounded_output_with_input(
        Command::new("/usr/bin/python3")
            .args(["-I", "-S", "-c", &program])
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Some(text.as_bytes()),
        timeout,
        1_048_576,
        "deadline-aware guardian evidence validator",
    )?;
    if !output.status.success() || Instant::now() >= deadline {
        return Err(format!(
            "guardian evidence deadline contract failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(evidence_hash)
}

fn verify_guardian_post_publish_link(
    fence_path: &Path,
    later_path: &Path,
    later_mode: &str,
    later_removed: bool,
    require_exact_input: bool,
) -> Result<(String, String), String> {
    let fence_hash = verify_guardian_evidence(
        fence_path,
        "broker-post-publish-fence",
        false,
        true,
    )?;
    let later_hash = verify_guardian_evidence(
        later_path,
        later_mode,
        later_removed,
        require_exact_input,
    )?;
    let fence_text = read_bounded_utf8(fence_path, 1_048_576, 501, 0o600)?;
    let later_text = read_bounded_utf8(later_path, 1_048_576, 501, 0o600)?;
    if sha256_bytes(fence_text.as_bytes())? != fence_hash
        || sha256_bytes(later_text.as_bytes())? != later_hash
    {
        return Err("guardian post-publish evidence changed before linking".to_owned());
    }
    let mut joined = Vec::with_capacity(fence_text.len() + later_text.len() + 1);
    joined.extend_from_slice(fence_text.as_bytes());
    joined.push(0);
    joined.extend_from_slice(later_text.as_bytes());
    let program = r#"import json,sys
parts=sys.stdin.buffer.read().split(b'\0')
assert len(parts)==2
f=json.loads(parts[0]); l=json.loads(parts[1])
assert f['mode']=='broker-post-publish-fence'
assert l['mode']==sys.argv[1]
assert f['passed'] is True and l['passed'] is True
assert f['baselineInputFingerprint']==l['baselineInputFingerprint']
assert f['baselineOutputFingerprint']==l['baselineOutputFingerprint']
assert f['baselineSystemOutputFingerprint']==l['baselineSystemOutputFingerprint']
fe=f['listener']['postPublishEpoch']; le=l['listener']['postPublishEpoch']
assert fe==le
assert f['listener']['postPublishEpochFingerprint']==l['listener']['postPublishEpochFingerprint']
assert f['listener']['sequenceAtSnapshot']==fe['sequence']
assert f['listener']['finalSequence']==fe['sequence']
assert f['listener']['absoluteFinal']==fe
assert l['listener']['sequenceAtSnapshot']==fe['sequence']
assert l['listener']['postPublishEpochEstablished'] is True
assert l['listener']['countersMonotonic'] is True
assert l['listener']['outputNotifications']==0
assert l['listener']['systemOutputNotifications']==0"#;
    let output = bounded_output_with_input(
        Command::new("/usr/bin/python3")
            .args(["-I", "-S", "-c", program, later_mode])
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Some(&joined),
        Duration::from_secs(10),
        1_048_576,
        "guardian post-publish evidence linker",
    )?;
    if !output.status.success() {
        return Err(format!(
            "guardian post-publish evidence link failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    if verify_guardian_evidence(
        fence_path,
        "broker-post-publish-fence",
        false,
        true,
    )? != fence_hash
        || verify_guardian_evidence(
            later_path,
            later_mode,
            later_removed,
            require_exact_input,
        )? != later_hash
    {
        return Err("guardian post-publish evidence changed during linking".to_owned());
    }
    Ok((fence_hash, later_hash))
}

fn verify_json_contract(path: &Path, program: &str, label: &str) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {label}: {error}"))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > 1_048_576
    {
        return Err(format!("{label} metadata is unsafe"));
    }
    let text = read_bounded_utf8(path, 1_048_576, 501, 0o600)?;
    let rewritten = program.replace(
        "json.load(open(sys.argv[1],encoding='utf-8'))",
        "json.load(sys.stdin)",
    );
    if rewritten == program {
        return Err(format!("{label} validator did not use the reviewed stdin form"));
    }
    let output = bounded_output_with_input(
        Command::new("/usr/bin/python3")
            .args(["-I", "-S", "-c", &rewritten])
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Some(text.as_bytes()),
        Duration::from_secs(10),
        1_048_576,
        label,
    )?;
    if !output.status.success() {
        return Err(format!(
            "{label} contract failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

fn verify_json_contract_until(
    path: &Path,
    program: &str,
    label: &str,
    deadline: Instant,
    maximum_seconds: u64,
) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {label}: {error}"))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > 1_048_576
    {
        return Err(format!("{label} metadata is unsafe"));
    }
    let text = read_bounded_utf8(path, 1_048_576, 501, 0o600)?;
    let rewritten = program.replace(
        "json.load(open(sys.argv[1],encoding='utf-8'))",
        "json.load(sys.stdin)",
    );
    if rewritten == program {
        return Err(format!("{label} validator did not use the reviewed stdin form"));
    }
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or_else(|| format!("{label} absolute deadline expired"))?;
    let timeout = remaining
        .checked_sub(Duration::from_secs(MIRROR_PROBE_TEARDOWN_SECONDS))
        .map(|value| std::cmp::min(value, Duration::from_secs(maximum_seconds)))
        .filter(|value| !value.is_zero())
        .ok_or_else(|| format!("{label} lacks its process teardown reserve"))?;
    let output = bounded_output_with_input(
        Command::new("/usr/bin/python3")
            .args(["-I", "-S", "-c", &rewritten])
            .env_clear()
            .env("LC_ALL", "C")
            .current_dir("/"),
        Some(text.as_bytes()),
        timeout,
        1_048_576,
        label,
    )?;
    if !output.status.success() || Instant::now() >= deadline {
        return Err(format!(
            "{label} contract failed or exceeded its deadline: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

fn mirror_result_contract_program() -> &'static str {
    r#"import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
assert v['schema']=='opensteamer.virtual-microphone-mirror-loopback.v2'
assert v['status']=='passed' and v['mode']=='real' and v['realQueuePathImplemented'] is True
assert v['lifecycle']['requiredStartOrders']==['visible-first','hidden-first']
assert [x['startOrder'] for x in v['lifecycle']['cycles']]==['visible-first','hidden-first']
assert all(x['quiescentBefore'] and x['quiescentAfter'] and x['nearZeroSharedClock'] and x['timelinesAdvanced'] and x['queuesStoppedAndDisposed'] for x in v['lifecycle']['cycles'])
assert v['defaults']['inputBeforeAfterEqual'] and v['defaults']['outputBeforeAfterEqual'] and v['defaults']['systemOutputBeforeAfterEqual']
assert v['defaults']['notificationCount']==0 and not v['defaults']['mutated']
assert v['defaults']['hiddenEndpointNeverDefault'] and v['defaults']['virtualEndpointsNeverOutputDefault']
assert v['teardown']['cleanupEvidenceComplete'] and v['teardown']['callbackGatesDrained'] and v['teardown']['listenersRemoved'] and v['teardown']['contextsReleased']
assert v['failureCode']=='none' and v['failureReasons']==[]"#
}

fn verify_mirror_result(path: &Path) -> Result<(), String> {
    verify_json_contract(
        path,
        mirror_result_contract_program(),
        "mirror-loopback evidence",
    )
}

fn verify_mirror_result_until(path: &Path, deadline: Instant) -> Result<(), String> {
    verify_json_contract_until(
        path,
        mirror_result_contract_program(),
        "mirror-loopback evidence",
        deadline,
        MIRROR_PROBE_JSON_SECONDS,
    )
}

fn verify_public_vpio_result(path: &Path) -> Result<(), String> {
    let text = read_bounded_utf8(path, 1_048_576, 501, 0o600)?;
    if text.lines().count() != 1 {
        return Err("public VPIO evidence is not exactly one JSON line".to_owned());
    }
    verify_json_contract(
        path,
        r#"import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
assert v['schema']==1 and v['mode']=='live-opt-in' and v['claim']=='public-vpio-compatibility-only' and v['passed'] is True
assert v['failureMask']=='0000000000000000'
assert v['visibleInputChannels']==1 and v['visibleOutputChannels']==0
assert v['hiddenInputChannels']==0 and v['hiddenOutputChannels']==1
assert v['visibleNativeFormatExact'] and v['hiddenNativeFormatExact']
assert v['processedMicClientFormatExact'] and v['playoutClientFormatExact']
assert v['endpointTranslationStableBeforeCommit'] and v['endpointTranslationStableAfterStart']
assert v['outputDefaultsStableAndSafeBeforeGate'] and v['defaultsStableAndSafeAfterVPIOStart'] and v['outputDefaultsStableAndSafeAfterRun']
assert v['outputNotifications']==0 and v['systemOutputNotifications']==0 and v['unexpectedInputNotifications']==0
assert v['restorationOwnershipPreserved'] and v['restorationTargetRetranslatedFromUID'] and v['restorationSucceeded'] and v['finalDefaultInputMatchesSnapshot']
assert v['gatesClosedBeforeStop'] and v['callbacksStableAfterDrain'] and v['listenersRemoved'] and v['listenerCallbacksStableAfterRemoval']
assert v['publicVPIOProcessedMicUplinkValidated'] and v['publicVPIOStereoPlayoutRenderPathValidated']
assert not v['faceTimeUplinkClaimed'] and not v['localDownlinkAcousticsClaimed'] and not v['farEndDownlinkAcousticsClaimed']"#,
        "public VPIO evidence",
    )
}

fn require_identity() -> Result<(), String> {
    let identities = command_output("/usr/bin/security", &["find-identity", "-v", "-p", "codesigning"])?;
    let exact = identities
        .lines()
        .filter(|line| line.contains(DEVELOPMENT_IDENTITY_SHA1))
        .count();
    if exact != 1 || !identities.contains("Apple Development: Ahmed Elamin (92LVX32M8K)") {
        return Err("exact Apple Development identity is not uniquely available".to_owned());
    }
    let certificate = command_output(
        "/usr/bin/security",
        &[
            "find-certificate",
            "-a",
            "-c",
            "Apple Development: Ahmed Elamin (92LVX32M8K)",
            "-Z",
        ],
    )?;
    let expected_sha256 = format!("SHA-256 hash: {}", DEVELOPMENT_LEAF_SHA256.to_ascii_uppercase());
    let expected_sha1 = format!("SHA-1 hash: {DEVELOPMENT_IDENTITY_SHA1}");
    if certificate
        .lines()
        .filter(|line| *line == expected_sha256)
        .count()
        != 1
        || certificate
            .lines()
            .filter(|line| *line == expected_sha1)
            .count()
            != 1
    {
        return Err("Apple Development certificate leaf hashes changed".to_owned());
    }
    Ok(())
}

fn preflight(allow_known_user_residue: bool) -> Result<(), String> {
    if unsafe { libc_getuid() } != 501 {
        return Err("local trial preflight must run as uid 501".to_owned());
    }
    if Path::new(REPO).canonicalize().map_err(|error| error.to_string())?
        != PathBuf::from(REPO)
    {
        return Err("canonical repo path changed".to_owned());
    }
    require_real_directory(Path::new(ARTIFACT_ROOT), 0o700)?;
    require_hash(Path::new(HOST_EXECUTABLE), V6_HOST_SHA256)?;
    require_hash(Path::new(HOST_PLIST), V6_PLIST_SHA256)?;
    require_hash(Path::new(LEGACY_EXECUTABLE), LEGACY_HOST_SHA256)?;
    require_hash(Path::new(LEGACY_PLIST), LEGACY_PLIST_SHA256)?;
    if !Path::new(HOST_APP).is_dir() || !Path::new(LEGACY_APP).is_dir() {
        return Err("protected host app path is unavailable".to_owned());
    }
    require_absent_no_follow(Path::new(PRODUCT_DRIVER), "product driver baseline")?;
    if !allow_known_user_residue {
        require_absent_no_follow(Path::new(TRIAL_ROOT), "one-shot local trial evidence")?;
    }
    require_absent_no_follow(Path::new(ACTIVE_POINTER), "active local trial pointer")?;
    require_absent_no_follow(Path::new(ACTIVE_POINTER_TEMP), "active-pointer publication temp")?;
    let artifact = |relative: &str| Path::new(ARTIFACT_ROOT).join(relative);
    require_hash(&artifact(CANDIDATE_HOST_RELATIVE), CANDIDATE_HOST_SHA256)?;
    require_hash(
        &artifact(CANDIDATE_FRAMEWORK_RELATIVE),
        CANDIDATE_FRAMEWORK_SHA256,
    )?;
    if bundle_tree_sha256(&artifact(CANDIDATE_HOST_APP_RELATIVE), 501)?
        != CANDIDATE_HOST_TREE_SHA256
    {
        return Err("candidate host app tree differs from the sealed manifest pin".to_owned());
    }
    require_hash(&artifact(CANDIDATE_DRIVER_RELATIVE), CANDIDATE_DRIVER_SHA256)?;
    require_hash(&artifact(MIRROR_PROBE_RELATIVE), MIRROR_PROBE_SHA256)?;
    require_hash(&artifact(VPIO_PROBE_RELATIVE), VPIO_PROBE_SHA256)?;
    require_hash(Path::new(LIVE_PROCESS_VERIFIER), LIVE_PROCESS_VERIFIER_SHA256)?;
    let host_bundle = artifact(CANDIDATE_HOST_APP_RELATIVE);
    require_exact_signature(
        &host_bundle,
        "com.elamin.AudioStreamer.CaptureServer",
        CANDIDATE_HOST_CDHASH,
        false,
    )?;
    let driver_bundle = artifact("driver-output/OpensteamerVirtualMicrophone.driver");
    verify_driver_tree(&driver_bundle, 501)?;
    require_exact_signature(
        &driver_bundle,
        "com.elamin.opensteamer.VirtualMicrophoneDriver",
        CANDIDATE_DRIVER_CDHASH,
        true,
    )?;
    require_identity()?;
    v7_controller::paired_v7::local_trial_verify_exact_v6_admission()
        .map_err(|error| format!("exact committed v6 admission failed: {error}"))?;
    require_healthy_admission_imported_count()?;
    println!(
        "LOCAL_MONO_TRIAL_PREFLIGHT_OK live_enabled={} v6_sha256={V6_HOST_SHA256} candidate_sha256={CANDIDATE_HOST_SHA256} driver_sha256={CANDIDATE_DRIVER_SHA256}",
        live_release_enabled()
    );
    Ok(())
}

fn verify_user_trial_stage() -> Result<(), String> {
    for directory in [
        TRIAL_ROOT,
        TRIAL_RUN_ROOT,
        TRIAL_PROBES,
        "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging",
    ] {
        require_real_directory(Path::new(directory), 0o700)?;
    }
    let current = env::current_exe().map_err(|error| error.to_string())?;
    require_regular_file(&current)?;
    let controller_hash = sha256(&current)?;
    require_user_regular(Path::new(USER_CONTROLLER_STAGE), 0o500, &controller_hash)?;
    require_user_regular(Path::new(USER_GUARDIAN_STAGE), 0o500, ROUTE_GUARDIAN_SHA256)?;
    Ok(())
}

fn initialize_trial_evidence() -> Result<(), String> {
    verify_user_trial_stage()?;
    let layout = TrialLayout::fixed();
    for path in [
        &layout.journal,
        &layout.result,
        &layout.proxy_stdout,
        &layout.proxy_stderr,
        &layout.mirror_result,
        &layout.mirror_stdout,
        &layout.mirror_stderr,
        &layout.guardian_state,
        &layout.guardian_snapshot_result,
        &layout.guardian_fence_result,
        &layout.guardian_post_publish_fence_result,
        &layout.guardian_run_result,
        &layout.guardian_repair_result,
        &layout.guardian_emergency_repair_result,
        &layout.guardian_final_result,
        &layout.guardian_stdout,
        &layout.guardian_stderr,
        &layout.vpio_stdout,
        &layout.vpio_stderr,
        &layout.candidate_stdout,
        &layout.candidate_stderr,
    ] {
        require_absent_no_follow(path, "one-shot evidence output")?;
    }
    require_absent_no_follow(Path::new(ACTIVE_POINTER), "active local-trial pointer")?;
    require_absent_no_follow(Path::new(ACTIVE_POINTER_TEMP), "active-pointer publication temp")?;
    require_absent_no_follow(Path::new(STOP_REQUEST), "local-trial stop request")?;
    require_absent_no_follow(Path::new(PROXY_ARM), "detached proxy arm record")?;
    let mut journal = create_new_private(&layout.journal)?;
    writeln!(journal, "OPENSTEAMER_LOCAL_MONO_TRIAL_V1")
        .map_err(|error| error.to_string())?;
    journal.sync_all().map_err(|error| error.to_string())?;
    drop(journal);
    create_new_private(&layout.result)?.sync_all().map_err(|error| error.to_string())?;
    append_journal(&layout, "USER_STAGE_VERIFIED")
}

fn wait_for_root_sealed_stage() -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(ROOT_STAGE_READY_SECONDS);
    while Instant::now() < deadline {
        let ready = require_root_regular(Path::new(SEALED_CONTROLLER), 0o555)
            .and_then(|_| require_root_regular(Path::new(SEALED_GUARDIAN), 0o555))
            .and_then(|_| require_root_regular(Path::new(ROOT_PROXY_IDENTITY), 0o444))
            .and_then(|_| require_hash(Path::new(SEALED_GUARDIAN), ROUTE_GUARDIAN_SHA256))
            .is_ok();
        let socket_ready = fs::symlink_metadata(ROOT_BROKER_SOCKET)
            .map(|metadata| {
                metadata.file_type().is_socket()
                    && metadata.uid() == 501
                    && metadata.gid() == 20
                    && metadata.mode() & 0o777 == 0o600
            })
            .unwrap_or(false);
        if ready && socket_ready {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err("root broker sealed stage did not become ready".to_owned())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StartResultObservation {
    Pending,
    Ready,
    Failed,
    RolledBack,
}

fn classify_start_result(text: &str) -> StartResultObservation {
    if text.lines().any(|line| line == "LOCAL_MONO_TRIAL_ROLLED_BACK") {
        StartResultObservation::RolledBack
    } else if text
        .lines()
        .any(|line| line.starts_with("LOCAL_MONO_TRIAL_FAILED "))
    {
        StartResultObservation::Failed
    } else if text
        .lines()
        .any(|line| line.starts_with("LOCAL_MONO_TRIAL_READY "))
    {
        StartResultObservation::Ready
    } else {
        StartResultObservation::Pending
    }
}

fn start_ready_admission_model(
    initial: StartResultObservation,
    pointer_exact: bool,
    proxy_exact: bool,
    adjacent: StartResultObservation,
) -> bool {
    initial == StartResultObservation::Ready
        && pointer_exact
        && proxy_exact
        && adjacent == StartResultObservation::Ready
}

fn atomic_pointer_publication_model(
    temp_complete: bool,
    temp_synced: bool,
    exclusive_rename_complete: bool,
    parent_synced: bool,
) -> bool {
    temp_complete && temp_synced && exclusive_rename_complete && parent_synced
}

fn start_local_trial() -> Result<(), String> {
    if unsafe { libc_getuid() } != 501 || unsafe { libc_geteuid() } != 501 {
        return Err("local trial start requires real/effective uid501".to_owned());
    }
    initialize_trial_evidence()?;
    wait_for_root_sealed_stage()?;
    let (proxy_pid, proxy_start) = read_root_proxy_identity()?;
    verify_root_sealed_controller_process(proxy_pid)?;
    if process_start_identity(proxy_pid)? != proxy_start {
        return Err("root-owned UID proxy identity changed before arm".to_owned());
    }
    let mut pointer = create_new_private(Path::new(ACTIVE_POINTER_TEMP))?;
    writeln!(pointer, "schema=opensteamer.local-mono-trial-pointer.v1")
        .and_then(|_| writeln!(pointer, "trial_root={TRIAL_ROOT}"))
        .and_then(|_| writeln!(pointer, "state=arming"))
        .and_then(|_| writeln!(pointer, "proxy_pid={proxy_pid}"))
        .and_then(|_| writeln!(pointer, "proxy_start={proxy_start}"))
        .and_then(|_| writeln!(pointer, "state=armed"))
        .map_err(|error| error.to_string())?;
    pointer.sync_all().map_err(|error| error.to_string())?;
    let pointer_identity = pointer.metadata().map_err(|error| error.to_string())?;
    rename_exclusive(Path::new(ACTIVE_POINTER_TEMP), Path::new(ACTIVE_POINTER))?;
    let published = fs::symlink_metadata(ACTIVE_POINTER).map_err(|error| error.to_string())?;
    if published.file_type().is_symlink()
        || pointer_identity.dev() != published.dev()
        || pointer_identity.ino() != published.ino()
        || pointer_identity.len() != published.len()
    {
        return Err("atomic active-pointer publication changed inode".to_owned());
    }
    let published_text = read_bounded_utf8(Path::new(ACTIVE_POINTER), 4_096, 501, 0o600)?;
    validate_active_pointer_text(&published_text, proxy_pid, &proxy_start)?;
    sync_parent_directory(Path::new(ACTIVE_POINTER))?;
    drop(pointer);
    let arm_result = (|| -> Result<(), String> {
        let mut arm = create_new_private(Path::new(PROXY_ARM))?;
        writeln!(arm, "schema=opensteamer.local-mono-trial-proxy-arm.v1")
            .and_then(|_| writeln!(arm, "proxy_pid={proxy_pid}"))
            .and_then(|_| writeln!(arm, "proxy_start={proxy_start}"))
            .map_err(|error| error.to_string())?;
        arm.sync_all().map_err(|error| error.to_string())
    })();
    if let Err(error) = arm_result {
        return Err(format!("could not arm root-owned UID proxy: {error}"));
    }
    append_journal(&TrialLayout::fixed(), &format!("ROOT_OWNED_UID_PROXY pid={proxy_pid}"))?;
    let deadline = Instant::now() + Duration::from_secs(START_READY_SECONDS);
    while Instant::now() < deadline {
        let status = read_bounded_utf8(&TrialLayout::fixed().result, 16_384, 501, 0o600)?;
        match classify_start_result(&status) {
            StartResultObservation::RolledBack => {
                require_absent_no_follow(
                    Path::new(ACTIVE_POINTER),
                    "active pointer after pre-ready rollback",
                )?;
                return Err(format!("local trial rolled back before readiness:\n{status}"));
            }
            StartResultObservation::Failed => return Err(status),
            StartResultObservation::Ready => {
                let active = read_bounded_utf8(Path::new(ACTIVE_POINTER), 4_096, 501, 0o600)?;
                validate_active_pointer_text(&active, proxy_pid, &proxy_start)?;
                verify_root_sealed_controller_process(proxy_pid)?;
                if process_start_identity(proxy_pid)? != proxy_start {
                    return Err("root-owned UID proxy changed at readiness".to_owned());
                }
                let adjacent =
                    read_bounded_utf8(&TrialLayout::fixed().result, 16_384, 501, 0o600)?;
                if classify_start_result(&adjacent) == StartResultObservation::Ready {
                    println!("{adjacent}");
                    return Ok(());
                }
                continue;
            }
            StartResultObservation::Pending => {}
        }
        if unsafe { libc_kill(proxy_pid as i32, 0) } != 0 {
            return Err("detached UID proxy exited before readiness".to_owned());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err("local trial did not become ready within its start deadline".to_owned())
}

fn stop_local_trial() -> Result<(), String> {
    if unsafe { libc_getuid() } != 501 || unsafe { libc_geteuid() } != 501 {
        return Err("local trial stop requires real/effective uid501".to_owned());
    }
    let pointer = read_bounded_utf8(Path::new(ACTIVE_POINTER), 4_096, 501, 0o600)?;
    if !pointer.starts_with("schema=opensteamer.local-mono-trial-pointer.v1\n")
        || !pointer.contains(&format!("trial_root={TRIAL_ROOT}\n"))
    {
        return Err("active local-trial pointer is malformed".to_owned());
    }
    let mut request = create_new_private(Path::new(STOP_REQUEST))?;
    writeln!(request, "STOP_LOCAL_MONO_TRIAL_PREP_L1CIAB")
        .map_err(|error| error.to_string())?;
    request.sync_all().map_err(|error| error.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(STOP_COMPLETE_SECONDS);
    while Instant::now() < deadline {
        let status = read_bounded_utf8(&TrialLayout::fixed().result, 16_384, 501, 0o600)?;
        if status.lines().any(|line| line == "LOCAL_MONO_TRIAL_ROLLED_BACK") {
            require_absent_no_follow(Path::new(ACTIVE_POINTER), "active pointer after rollback")?;
            println!("LOCAL_MONO_TRIAL_STOP_OK exact_v6_restored=true");
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err("local trial rollback did not finish within its stop deadline".to_owned())
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NodeIdentity {
    present: bool,
    device: u64,
    inode: u64,
    kind: &'static str,
}

fn node_identity(path: &Path) -> Result<NodeIdentity, String> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(NodeIdentity {
            present: false,
            device: 0,
            inode: 0,
            kind: "absent",
        }),
        Err(error) => Err(format!("could not inspect {}: {error}", path.display())),
        Ok(metadata) => {
            let kind = if metadata.file_type().is_dir() {
                "directory"
            } else if metadata.file_type().is_file() {
                "file"
            } else if metadata.file_type().is_symlink() {
                "symlink"
            } else {
                "special"
            };
            Ok(NodeIdentity {
                present: true,
                device: metadata.dev(),
                inode: metadata.ino(),
                kind,
            })
        }
    }
}

fn require_root_directory(path: &Path, mode: u32) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.mode() & 0o777 != mode
    {
        return Err(format!("root directory metadata is unsafe: {}", path.display()));
    }
    Ok(())
}

fn require_root_regular(path: &Path, mode: u32) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != mode
    {
        return Err(format!("root file metadata is unsafe: {}", path.display()));
    }
    Ok(())
}

fn require_user_regular(path: &Path, mode: u32, expected_hash: &str) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != mode
    {
        return Err(format!("uid501 artifact metadata is unsafe: {}", path.display()));
    }
    require_hash(path, expected_hash)
}

fn verify_root_controller_identity() -> Result<String, String> {
    if unsafe { libc_geteuid() } != 0 {
        return Err("root broker requires effective UID 0".to_owned());
    }
    let executable = env::current_exe().map_err(|error| error.to_string())?;
    if executable != Path::new(ROOT_CONTROLLER) {
        return Err("root broker escaped the fixed root-owned controller path".to_owned());
    }
    require_root_regular(&executable, 0o500)?;
    require_root_regular(Path::new(ROOT_CONTROLLER_PIN), 0o400)?;
    let expected = read_bounded_utf8(Path::new(ROOT_CONTROLLER_PIN), 128, 0, 0o400)?;
    let expected = expected.trim_end_matches('\n');
    if expected.len() != 64
        || !expected
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("root controller pin file is malformed".to_owned());
    }
    let actual = sha256(&executable)?;
    if actual != expected {
        return Err("root controller bytes differ from the root-owned pin".to_owned());
    }
    require_root_directory(Path::new(ROOT_SUPPORT), 0o711)?;
    Ok(actual)
}

fn verify_sealed_uid_controller_identity() -> Result<(), String> {
    if unsafe { libc_geteuid() } != 501 || unsafe { libc_getuid() } != 501 {
        return Err("emergency recovery must run with real/effective UID 501".to_owned());
    }
    let executable = env::current_exe().map_err(|error| error.to_string())?;
    if executable != Path::new(SEALED_CONTROLLER) {
        return Err("emergency recovery escaped the fixed root-owned sealed controller".to_owned());
    }
    require_root_regular(&executable, 0o555)?;
    require_root_regular(Path::new(SEALED_CONTROLLER_PIN), 0o444)?;
    let expected = read_bounded_utf8(Path::new(SEALED_CONTROLLER_PIN), 128, 0, 0o444)?;
    if sha256(&executable)? != expected.trim_end_matches('\n') {
        return Err("sealed recovery controller bytes differ from their root pin".to_owned());
    }
    Ok(())
}

fn verify_root_broker_parent_mapping(pid: u32) -> Result<(), String> {
    // The root broker proves its own root-private binary pin before spawning this helper. From
    // uid501, bind that already-authenticated root peer to the exact non-user-readable primary
    // path and root-owned inode; no user-controlled mapped file or argv text participates.
    let first_path = process_executable_path(pid)?;
    require_root_regular(Path::new(ROOT_CONTROLLER), 0o500)?;
    let metadata = fs::symlink_metadata(ROOT_CONTROLLER).map_err(|error| error.to_string())?;
    if first_path != Path::new(ROOT_CONTROLLER)
        || metadata.dev() == 0
        || metadata.ino() == 0
        || process_executable_path(pid)? != Path::new(ROOT_CONTROLLER)
    {
        return Err("root capability parent primary executable changed".to_owned());
    }
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("root capability parent identity/session changed".to_owned());
    }
    Ok(())
}

fn verify_root_launch_capability() -> Result<(), String> {
    if ROOT_LAUNCH_CAPABILITY_VERIFIED.get() == Some(&true) {
        return Ok(());
    }
    let pid = unsafe { libc_getpid() } as u32;
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("root-launched UID helper is not its own session leader".to_owned());
    }
    let capability = std::mem::ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
    let metadata = capability
        .metadata()
        .map_err(|error| format!("root launch capability FD is unavailable: {error}"))?;
    if !metadata.file_type().is_socket() {
        return Err("root launch capability FD is not a socket".to_owned());
    }
    let mut peer_uid = u32::MAX;
    let mut peer_gid = u32::MAX;
    if unsafe { libc_getpeereid(0, &mut peer_uid, &mut peer_gid) } != 0
        || peer_uid != 0
        || peer_gid != 0
    {
        return Err("root launch capability peer credentials are not root:wheel".to_owned());
    }
    let mut peer_pid = 0_i32;
    let mut peer_size = std::mem::size_of::<i32>() as u32;
    if unsafe {
        libc_getsockopt(
            0,
            SOL_LOCAL,
            LOCAL_PEERPID,
            (&mut peer_pid as *mut i32).cast(),
            &mut peer_size,
        )
    } != 0
        || peer_size as usize != std::mem::size_of::<i32>()
        || peer_pid <= 0
        || unsafe { libc_getppid() } != peer_pid
    {
        return Err("root launch capability peer PID/parent binding failed".to_owned());
    }
    verify_root_broker_parent_mapping(peer_pid as u32)?;
    ROOT_LAUNCH_CAPABILITY_VERIFIED
        .set(true)
        .map_err(|_| "root launch capability state changed".to_owned())
}

fn verify_root_supervised_uid_helper() -> Result<(), String> {
    verify_sealed_uid_controller_identity()?;
    verify_root_launch_capability()
}

fn publish_guardian_spawned_on_root_capability(pid: u32) -> Result<(), String> {
    if ROOT_LAUNCH_CAPABILITY_VERIFIED.get() != Some(&true) || pid <= 1 {
        return Err("guardian spawn marker lacks its authenticated root capability".to_owned());
    }
    let capability = std::mem::ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
    let mut writer = &*capability;
    writeln!(writer, "L1Ciab GUARDIAN_SPAWNED {pid}")
        .and_then(|_| writer.flush())
        .map_err(|error| format!("could not publish guardian spawn capability marker: {error}"))
}

fn publish_guardian_reaped_on_root_capability(pid: u32) -> Result<(), String> {
    if ROOT_LAUNCH_CAPABILITY_VERIFIED.get() != Some(&true) || pid <= 1 {
        return Err("guardian reap marker lacks its authenticated root capability".to_owned());
    }
    let capability = std::mem::ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
    let mut writer = &*capability;
    writeln!(writer, "L1Ciab GUARDIAN_REAPED {pid}")
        .and_then(|_| writer.flush())
        .map_err(|error| format!("could not publish guardian reap capability marker: {error}"))
}

fn root_create_private(path: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("could not create root-private file {}: {error}", path.display()))?;
    require_root_regular(path, 0o600)?;
    let descriptor = file.metadata().map_err(|error| error.to_string())?;
    let named = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if descriptor.dev() != named.dev() || descriptor.ino() != named.ino() {
        return Err("root-private file was replaced during creation".to_owned());
    }
    Ok(file)
}

fn root_append_state(state: &str) -> Result<(), String> {
    if state.is_empty() || state.len() > 256 || state.contains(['\n', '\r', '\0']) {
        return Err("root state line is malformed".to_owned());
    }
    let journal = Path::new(ROOT_TRANSACTION).join("journal.log");
    require_root_regular(&journal, 0o600)?;
    let mut file = OpenOptions::new()
        .append(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(&journal)
        .map_err(|error| error.to_string())?;
    writeln!(file, "STATE {state}").map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())
}

fn run_fixed(program: &str, arguments: &[&str], label: &str) -> Result<String, String> {
    let output = bounded_output(
        Command::new(program)
            .args(arguments)
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        Duration::from_secs(RUN_FIXED_BOUND_SECONDS),
        4 * 1_048_576,
        label,
    )?;
    if !output.status.success() {
        return Err(format!(
            "could not {label}: status={:?} stdout={} stderr={}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout)
        .map(|value| value.trim().to_owned())
        .map_err(|_| format!("{label} emitted non-UTF-8 output"))
}

fn copy_tree_root(source: &Path, destination: &Path) -> Result<(), String> {
    run_fixed(
        "/usr/bin/ditto",
        &[
            "--norsrc",
            "--noextattr",
            "--noacl",
            "--noqtn",
            source.to_str().ok_or("non-UTF-8 copy source")?,
            destination.to_str().ok_or("non-UTF-8 copy destination")?,
        ],
        "copy exact bundle into root-owned storage",
    )?;
    run_fixed(
        "/usr/sbin/chown",
        &[
            "-R",
            "-h",
            "0:0",
            destination.to_str().ok_or("non-UTF-8 root copy")?,
        ],
        "root-own exact copied bundle",
    )?;
    verify_no_acl_xattr_or_flags(destination)?;
    Ok(())
}

fn publish_sealed_host_signature_resources(bundle: &Path) -> Result<(), String> {
    if unsafe { libc_geteuid() } != 0 || bundle != Path::new(SEALED_HOST_APP) {
        return Err("sealed signature resources require the exact root-owned host bundle".to_owned());
    }
    require_root_directory(Path::new(ROOT_SEALED), 0o700)?;
    require_root_directory(bundle, 0o755)?;
    for relative in SEALED_HOST_SIGNATURE_RESOURCES {
        let path = bundle.join(relative);
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NOFOLLOW | O_CLOEXEC)
            .open(&path)
            .map_err(|error| {
                format!("could not open sealed signature resource {}: {error}", path.display())
            })?;
        let before = file.metadata().map_err(|error| error.to_string())?;
        let named_before = fs::symlink_metadata(&path).map_err(|error| error.to_string())?;
        if !before.is_file()
            || before.uid() != 0
            || before.gid() != 0
            || before.nlink() != 1
            || before.mode() & 0o777 != 0o600
            || before.dev() != named_before.dev()
            || before.ino() != named_before.ino()
        {
            return Err(format!(
                "sealed signature resource pre-publication metadata changed: {}",
                path.display()
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o444))
            .map_err(|error| format!("could not publish {}: {error}", path.display()))?;
        file.sync_all()
            .map_err(|error| format!("could not sync {}: {error}", path.display()))?;
        let after = file.metadata().map_err(|error| error.to_string())?;
        let named_after = fs::symlink_metadata(&path).map_err(|error| error.to_string())?;
        if !after.is_file()
            || after.uid() != 0
            || after.gid() != 0
            || after.nlink() != 1
            || after.mode() & 0o777 != 0o444
            || after.dev() != before.dev()
            || after.ino() != before.ino()
            || after.dev() != named_after.dev()
            || after.ino() != named_after.ino()
        {
            return Err(format!(
                "sealed signature resource publication identity changed: {}",
                path.display()
            ));
        }
        require_root_regular(&path, 0o444)?;
    }
    Ok(())
}

fn verify_no_acl_xattr_or_flags(root: &Path) -> Result<(), String> {
    fn walk(path: &Path) -> Result<(), String> {
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| format!("could not inspect sealed metadata: {error}"))?;
        if metadata.st_flags() != 0 {
            return Err(format!("sealed node retains filesystem flags: {}", path.display()));
        }
        if metadata.file_type().is_dir() {
            let children = fs::read_dir(path)
                .map_err(|error| error.to_string())?
                .collect::<std::io::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?;
            for child in children {
                walk(&child.path())?;
            }
        }
        Ok(())
    }
    walk(root)?;
    let root_text = root.to_str().ok_or("non-UTF-8 sealed path")?;
    let xattrs = bounded_output(
        Command::new("/usr/bin/xattr")
            .args(["-lr", root_text])
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_secs(20),
        4 * 1_048_576,
        "prove sealed extended attributes absent",
    )?;
    if !xattrs.status.success() || !xattrs.stdout.is_empty() {
        return Err("sealed tree retains an extended attribute".to_owned());
    }
    let acl = bounded_output(
        Command::new("/bin/ls")
            .args(["-leR", root_text])
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_secs(20),
        4 * 1_048_576,
        "prove sealed ACLs absent",
    )?;
    if !acl.status.success() {
        return Err("could not inspect sealed ACLs".to_owned());
    }
    let listing = String::from_utf8(acl.stdout).map_err(|_| "ACL listing is not UTF-8")?;
    if listing.lines().any(|line| {
        let value = line.trim_start();
        value
            .split_once(':')
            .map(|(prefix, _)| !prefix.is_empty() && prefix.bytes().all(|byte| byte.is_ascii_digit()))
            .unwrap_or(false)
    }) {
        return Err("sealed tree retains an ACL entry".to_owned());
    }
    Ok(())
}

fn root_install_file(source: &Path, destination: &Path, mode: &str) -> Result<(), String> {
    run_fixed(
        "/usr/bin/install",
        &[
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            mode,
            source.to_str().ok_or("non-UTF-8 install source")?,
            destination.to_str().ok_or("non-UTF-8 install destination")?,
        ],
        "install exact root-owned file",
    )?;
    Ok(())
}

fn require_no_capture_server_root() -> Result<(), String> {
    let output = bounded_output(
        Command::new("/usr/bin/pgrep")
        .args(["-x", "CaptureServer"])
        .env_clear()
        .env("LC_ALL", "C"),
        Duration::from_secs(5),
        65_536,
        "inspect CaptureServer processes",
    )?;
    if output.status.code() == Some(1) && output.stdout.is_empty() {
        return Ok(());
    }
    if output.status.success() {
        return Err("root driver mutation refused while CaptureServer exists".to_owned());
    }
    Err(format!(
        "CaptureServer absence check failed operationally: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    ))
}

#[derive(Debug)]
struct SharedLockGuard {
    file: File,
    device: u64,
    inode: u64,
}

impl SharedLockGuard {
    fn require_named_identity(&self) -> Result<(), String> {
        let descriptor = self.file.metadata().map_err(|error| error.to_string())?;
        let named = fs::symlink_metadata(SHARED_LOCK).map_err(|error| error.to_string())?;
        if !descriptor.is_file()
            || named.file_type().is_symlink()
            || !named.is_file()
            || descriptor.dev() != self.device
            || descriptor.ino() != self.inode
            || named.dev() != self.device
            || named.ino() != self.inode
            || descriptor.uid() != 501
            || descriptor.gid() != 20
            || descriptor.nlink() != 1
            || descriptor.mode() & 0o777 != 0o600
            || named.uid() != 501
            || named.gid() != 20
            || named.nlink() != 1
            || named.mode() & 0o777 != 0o600
        {
            return Err("canonical shared lock named/descriptor identity changed".to_owned());
        }
        Ok(())
    }

    fn release(&mut self) -> Result<(), String> {
        self.require_named_identity()?;
        if unsafe { libc_flock(self.file.as_raw_fd(), LOCK_UN) } != 0 {
            return Err(format!(
                "could not release retained canonical shared lock: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }
}

fn acquire_shared_lock_unowned_root() -> Result<SharedLockGuard, String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(SHARED_LOCK)
        .map_err(|error| format!("could not open canonical shared lock: {error}"))?;
    let descriptor = file.metadata().map_err(|error| error.to_string())?;
    let named = fs::symlink_metadata(SHARED_LOCK).map_err(|error| error.to_string())?;
    if !descriptor.is_file()
        || descriptor.dev() != named.dev()
        || descriptor.ino() != named.ino()
        || descriptor.uid() != 501
        || descriptor.gid() != 20
        || descriptor.nlink() != 1
        || descriptor.mode() & 0o777 != 0o600
        || named.file_type().is_symlink()
        || !named.is_file()
        || named.uid() != 501
        || named.gid() != 20
        || named.nlink() != 1
        || named.mode() & 0o777 != 0o600
    {
        return Err("canonical shared lock metadata is unsafe".to_owned());
    }
    if unsafe { libc_flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(format!(
            "canonical shared lock is still owned: {}",
            std::io::Error::last_os_error()
        ));
    }
    let guard = SharedLockGuard {
        device: descriptor.dev(),
        inode: descriptor.ino(),
        file,
    };
    guard.require_named_identity()?;
    Ok(guard)
}

fn require_v6_launchd_service_absent_root() -> Result<(), String> {
    let target = format!("gui/501/{V6_LAUNCHD_LABEL}");
    let output = bounded_output(
        Command::new("/bin/launchctl")
            .args(["print", &target])
            .env_clear()
            .env("LC_ALL", "C"),
        Duration::from_secs(5),
        65_536,
        "prove exact-v6 launchd service absent as root",
    )?;
    let expected = format!(
        "Bad request.\nCould not find service \"{V6_LAUNCHD_LABEL}\" in domain for user gui: 501\n"
    );
    if output.status.code() != Some(113)
        || !output.stdout.is_empty()
        || output.stderr != expected.as_bytes()
    {
        return Err(format!(
            "root did not prove exact-v6 launchd service absence: status={:?} stdout={:?} stderr={:?}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}

fn acquire_runtime_mutation_guard_root() -> Result<SharedLockGuard, String> {
    require_v6_launchd_service_absent_root()?;
    let guard = acquire_shared_lock_unowned_root()?;
    require_v6_launchd_service_absent_root()?;
    require_no_capture_server_root()?;
    require_v6_launchd_service_absent_root()?;
    guard.require_named_identity()?;
    Ok(guard)
}

fn require_runtime_mutation_guard_barrier_root(
    guard: &SharedLockGuard,
) -> Result<(), String> {
    guard.require_named_identity()?;
    require_v6_launchd_service_absent_root()?;
    require_no_capture_server_root()?;
    require_v6_launchd_service_absent_root()?;
    guard.require_named_identity()
}

fn verify_probe_code_signature(path: &Path, identifier: &str, cdhash: &str) -> Result<(), String> {
    command_output(
        "/usr/bin/codesign",
        &["--verify", "--strict", path.to_str().ok_or("non-UTF-8 probe")?],
    )?;
    let details = bounded_output(
        Command::new("/usr/bin/codesign")
        .args(["-d", "--verbose=4", path.to_str().ok_or("non-UTF-8 probe")?])
        .env_clear()
        .env("LC_ALL", "C"),
        Duration::from_secs(30),
        1_048_576,
        "inspect probe code signature",
    )?;
    let text = String::from_utf8_lossy(&details.stderr);
    for needle in [
        format!("Identifier={identifier}"),
        format!("CDHash={cdhash}"),
        "TeamIdentifier=not set".to_owned(),
    ] {
        if !text.lines().any(|line| line == needle) {
            return Err(format!("probe signature field changed: {needle}"));
        }
    }
    Ok(())
}

fn root_prepare_transaction() -> Result<NodeIdentity, String> {
    let controller_hash = verify_root_controller_identity()?;
    require_absent_no_follow(Path::new(ROOT_TRANSACTION), "root local-trial transaction")?;
    require_absent_no_follow(Path::new(ROOT_SEALED), "root local-trial sealed stage")?;
    require_absent_no_follow(Path::new(PRODUCT_DRIVER), "canonical product driver")?;

    fs::create_dir(ROOT_TRANSACTION).map_err(|error| error.to_string())?;
    fs::set_permissions(ROOT_TRANSACTION, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    require_root_directory(Path::new(ROOT_TRANSACTION), 0o700)?;
    let mut journal = root_create_private(&Path::new(ROOT_TRANSACTION).join("journal.log"))?;
    writeln!(journal, "OPENSTEAMER_LOCAL_MONO_ROOT_TRANSACTION_V1")
        .map_err(|error| error.to_string())?;
    journal.sync_all().map_err(|error| error.to_string())?;

    fs::create_dir(ROOT_SEALED).map_err(|error| error.to_string())?;
    fs::set_permissions(ROOT_SEALED, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    require_root_directory(Path::new(ROOT_SEALED), 0o700)?;

    let artifact = |relative: &str| Path::new(ARTIFACT_ROOT).join(relative);
    require_real_directory(Path::new(ARTIFACT_ROOT), 0o700)?;
    let source_host = artifact(CANDIDATE_HOST_APP_RELATIVE);
    if bundle_tree_sha256(&source_host, 501)? != CANDIDATE_HOST_TREE_SHA256 {
        return Err("root re-verification rejected the candidate host tree".to_owned());
    }
    require_exact_signature(
        &source_host,
        "com.elamin.AudioStreamer.CaptureServer",
        CANDIDATE_HOST_CDHASH,
        false,
    )?;
    let source_driver = artifact("driver-output/OpensteamerVirtualMicrophone.driver");
    verify_driver_tree(&source_driver, 501)?;
    require_exact_signature(
        &source_driver,
        "com.elamin.opensteamer.VirtualMicrophoneDriver",
        CANDIDATE_DRIVER_CDHASH,
        true,
    )?;
    require_user_regular(&artifact(MIRROR_PROBE_RELATIVE), 0o700, MIRROR_PROBE_SHA256)?;
    require_user_regular(&artifact(VPIO_PROBE_RELATIVE), 0o755, VPIO_PROBE_SHA256)?;
    require_user_regular(Path::new(USER_GUARDIAN_STAGE), 0o500, ROUTE_GUARDIAN_SHA256)?;

    copy_tree_root(&source_host, Path::new(SEALED_HOST_APP))?;
    if bundle_tree_sha256(Path::new(SEALED_HOST_APP), 0)? != CANDIDATE_HOST_TREE_SHA256 {
        return Err("root-owned candidate host tree changed during sealing".to_owned());
    }
    require_hash(Path::new(SEALED_HOST_EXECUTABLE), CANDIDATE_HOST_SHA256)?;
    require_hash(
        Path::new(SEALED_FRAMEWORK_EXECUTABLE).canonicalize().map_err(|error| error.to_string())?.as_path(),
        CANDIDATE_FRAMEWORK_SHA256,
    )?;
    publish_sealed_host_signature_resources(Path::new(SEALED_HOST_APP))?;
    if bundle_tree_sha256(Path::new(SEALED_HOST_APP), 0)? != SEALED_CANDIDATE_HOST_TREE_SHA256 {
        return Err("normalized root-owned candidate host tree differs from its sealed pin".to_owned());
    }
    require_exact_signature(
        Path::new(SEALED_HOST_APP),
        "com.elamin.AudioStreamer.CaptureServer",
        CANDIDATE_HOST_CDHASH,
        false,
    )?;

    let driver_hold = Path::new(ROOT_TRANSACTION).join("OpensteamerVirtualMicrophone.driver.hold");
    copy_tree_root(&source_driver, &driver_hold)?;
    verify_driver_tree(&driver_hold, 0)?;
    require_exact_signature(
        &driver_hold,
        "com.elamin.opensteamer.VirtualMicrophoneDriver",
        CANDIDATE_DRIVER_CDHASH,
        true,
    )?;

    root_install_file(
        &artifact(MIRROR_PROBE_RELATIVE),
        Path::new(SEALED_MIRROR_PROBE),
        "0555",
    )?;
    root_install_file(
        &artifact(VPIO_PROBE_RELATIVE),
        Path::new(SEALED_VPIO_PROBE),
        "0555",
    )?;
    root_install_file(Path::new(USER_GUARDIAN_STAGE), Path::new(SEALED_GUARDIAN), "0555")?;
    root_install_file(Path::new(ROOT_CONTROLLER), Path::new(SEALED_CONTROLLER), "0555")?;
    let pin_temporary = Path::new(ROOT_SEALED).join("controller.sha256.tmp");
    let mut pin = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(&pin_temporary)
        .map_err(|error| error.to_string())?;
    writeln!(pin, "{controller_hash}").map_err(|error| error.to_string())?;
    pin.sync_all().map_err(|error| error.to_string())?;
    pin.set_permissions(fs::Permissions::from_mode(0o444))
        .map_err(|error| error.to_string())?;
    pin.sync_all().map_err(|error| error.to_string())?;
    require_root_regular(&pin_temporary, 0o444)?;
    drop(pin);
    fs::rename(&pin_temporary, SEALED_CONTROLLER_PIN).map_err(|error| error.to_string())?;
    require_root_regular(Path::new(SEALED_CONTROLLER_PIN), 0o444)?;

    require_hash(Path::new(SEALED_MIRROR_PROBE), MIRROR_PROBE_SHA256)?;
    require_hash(Path::new(SEALED_VPIO_PROBE), VPIO_PROBE_SHA256)?;
    require_hash(Path::new(SEALED_GUARDIAN), ROUTE_GUARDIAN_SHA256)?;
    require_hash(Path::new(SEALED_CONTROLLER), &controller_hash)?;
    verify_probe_code_signature(
        Path::new(SEALED_MIRROR_PROBE),
        "physical-blackhole-microphone-probe",
        "a936874c1d0c9fb01c5e876b09f1ad2e471b0ccd",
    )?;
    verify_probe_code_signature(
        Path::new(SEALED_VPIO_PROBE),
        "com.elamin.opensteamer.PublicVPIOProbe",
        "17ffaf9fa3b02e028db50994d560398722ae6354",
    )?;
    verify_no_acl_xattr_or_flags(Path::new(ROOT_SEALED))?;
    fs::set_permissions(ROOT_SEALED, fs::Permissions::from_mode(0o511))
        .map_err(|error| error.to_string())?;
    require_root_directory(Path::new(ROOT_SEALED), 0o511)?;

    let hold_identity = node_identity(&driver_hold)?;
    if !hold_identity.present || hold_identity.kind != "directory" {
        return Err("root driver hold identity is invalid".to_owned());
    }
    let mut identity_file = root_create_private(&Path::new(ROOT_TRANSACTION).join("driver.identity"))?;
    writeln!(identity_file, "device={}", hold_identity.device).map_err(|error| error.to_string())?;
    writeln!(identity_file, "inode={}", hold_identity.inode).map_err(|error| error.to_string())?;
    writeln!(identity_file, "tree_sha256={CANDIDATE_DRIVER_TREE_SHA256}")
        .map_err(|error| error.to_string())?;
    identity_file.sync_all().map_err(|error| error.to_string())?;
    require_absent_no_follow(Path::new(PRODUCT_DRIVER), "canonical product driver after prepare")?;
    root_append_state("PREPARED canonical_baseline=absent")?;
    Ok(hold_identity)
}

fn rename_exclusive(source: &Path, destination: &Path) -> Result<(), String> {
    let source_text = std::ffi::CString::new(source.as_os_str().as_bytes())
        .map_err(|_| "rename source contains NUL")?;
    let destination_text = std::ffi::CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| "rename destination contains NUL")?;
    let status = unsafe {
        libc_renameatx_np(
            AT_FDCWD,
            source_text.as_ptr(),
            AT_FDCWD,
            destination_text.as_ptr(),
            RENAME_EXCL,
        )
    };
    if status != 0 {
        return Err(format!(
            "exclusive rename {} -> {} failed: {}",
            source.display(),
            destination.display(),
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn sync_parent_directory(path: &Path) -> Result<(), String> {
    let parent = path.parent().ok_or("path has no parent directory")?;
    let named = fs::symlink_metadata(parent)
        .map_err(|error| format!("could not inspect parent directory: {error}"))?;
    if !named.is_dir() || named.file_type().is_symlink() {
        return Err("pointer parent is not a real directory".to_owned());
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(parent)
        .map_err(|error| format!("could not open pointer parent: {error}"))?;
    let descriptor = directory.metadata().map_err(|error| error.to_string())?;
    if !descriptor.is_dir()
        || descriptor.dev() != named.dev()
        || descriptor.ino() != named.ino()
    {
        return Err("pointer parent changed before fsync".to_owned());
    }
    directory
        .sync_all()
        .map_err(|error| format!("could not fsync pointer parent: {error}"))
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProcessGeneration {
    pid: u32,
    uid: u32,
    start_seconds: u64,
    start_microseconds: u64,
    executable: PathBuf,
}

fn remaining_phase_timeout(
    deadline: Instant,
    maximum: Duration,
    label: &str,
) -> Result<Duration, String> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or_else(|| format!("{label} absolute deadline expired"))?;
    if remaining.is_zero() {
        return Err(format!("{label} absolute deadline expired"));
    }
    Ok(std::cmp::min(remaining, maximum))
}

fn sleep_before_absolute_deadline(
    deadline: Instant,
    duration: Duration,
    label: &str,
) -> Result<(), String> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or_else(|| format!("{label} absolute deadline expired"))?;
    if remaining < duration {
        return Err(format!("{label} absolute deadline expired before bounded sleep"));
    }
    thread::sleep(duration);
    Ok(())
}

fn sleep_capped_by_absolute_deadline(deadline: Instant, duration: Duration) {
    let remaining = deadline.saturating_duration_since(Instant::now());
    let bounded = std::cmp::min(remaining, duration);
    if !bounded.is_zero() {
        thread::sleep(bounded);
    }
}

fn process_generation_for_pid_until(
    pid: u32,
    deadline: Instant,
) -> Result<Option<ProcessGeneration>, String> {
    if pid <= 1 || pid > i32::MAX as u32 {
        return Err("process generation PID is outside the positive process API".to_owned());
    }
    if Instant::now() >= deadline {
        return Err("process-generation proof absolute deadline expired".to_owned());
    }
    let Some(first) = process_bsd_identity(pid)? else {
        return Ok(None);
    };
    if !(1..=4).contains(&first.status) {
        return Err(format!(
            "process generation PID {pid} has unreviewed BSD status {}",
            first.status
        ));
    }
    let executable = match process_executable_path(pid) {
        Ok(path) => path,
        Err(error) => {
            let signal_probe = unsafe { libc_kill(pid as i32, 0) };
            if signal_probe != 0
                && std::io::Error::last_os_error().raw_os_error() == Some(3)
            {
                return Ok(None);
            }
            return Err(format!(
                "process-generation executable inspection failed for PID {pid}: {error}"
            ));
        }
    };
    let Some(second) = process_bsd_identity(pid)? else {
        return Ok(None);
    };
    if !(1..=4).contains(&second.status) || first != second {
        return Err("process generation changed during libproc proof".to_owned());
    }
    Ok(Some(ProcessGeneration {
        pid,
        uid: first.uid,
        start_seconds: first.start_seconds,
        start_microseconds: first.start_microseconds,
        executable,
    }))
}

fn coreaudiod_pids_until(deadline: Instant) -> Result<Vec<u32>, String> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or("coreaudiod enumeration absolute deadline expired")?;
    let command_timeout = remaining
        .checked_sub(Duration::from_secs(3))
        .map(|value| std::cmp::min(value, Duration::from_secs(2)))
        .filter(|value| !value.is_zero())
        .ok_or("coreaudiod enumeration lacks its process teardown reserve")?;
    let output = bounded_output(
        Command::new("/usr/bin/pgrep")
            .args(["-x", "coreaudiod"])
            .env_clear()
            .env("LC_ALL", "C"),
        command_timeout,
        65_536,
        "enumerate coreaudiod",
    )?;
    if output.status.code() == Some(1) && output.stdout.is_empty() {
        return Ok(Vec::new());
    }
    if !output.status.success() {
        return Err(format!(
            "coreaudiod enumeration failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| "coreaudiod enumeration is not UTF-8")?;
    text.lines()
        .map(|line| {
            line.parse::<u32>()
                .ok()
                .filter(|pid| *pid > 1 && *pid <= i32::MAX as u32)
                .ok_or_else(|| "coreaudiod enumeration emitted malformed PID".to_owned())
        })
        .collect()
}

fn coreaudiod_identity_until(deadline: Instant) -> Result<Option<ProcessGeneration>, String> {
    let pids = coreaudiod_pids_until(deadline)?;
    if pids.is_empty() {
        return Ok(None);
    }
    if pids.len() != 1 {
        return Err(format!(
            "transient coreaudiod topology: expected exactly one process, found {}",
            pids.len()
        ));
    }
    let pid = pids[0];
    let generation = process_generation_for_pid_until(pid, deadline)?.ok_or_else(|| {
        "transient coreaudiod topology: singleton disappeared during proof".to_owned()
    })?;
    if generation.uid != COREAUDIOD_UID
        || generation.executable != Path::new("/usr/sbin/coreaudiod")
    {
        return Err("coreaudiod PID/start/path/uid identity changed".to_owned());
    }
    if coreaudiod_pids_until(deadline)? != [pid] {
        return Err("transient coreaudiod topology: singleton changed during proof".to_owned());
    }
    if process_generation_for_pid_until(pid, deadline)?.as_ref() != Some(&generation) {
        return Err("transient coreaudiod topology: generation changed during proof".to_owned());
    }
    Ok(Some(generation))
}

fn wait_for_coreaudiod_generation_absence(
    before: &ProcessGeneration,
    deadline: Instant,
) -> Result<(), String> {
    loop {
        match process_bsd_identity(before.pid)? {
            None => return Ok(()),
            Some(observed)
                if observed.uid == before.uid
                    && observed.start_seconds == before.start_seconds
                    && observed.start_microseconds == before.start_microseconds =>
            {
                if !(1..=5).contains(&observed.status) {
                    return Err("old Core Audio generation has an unreviewed BSD status".to_owned());
                }
            }
            Some(_) => return Ok(()),
        }
        if Instant::now() >= deadline {
            return Err("old Core Audio generation did not become absent".to_owned());
        }
        sleep_before_absolute_deadline(
            deadline,
            Duration::from_millis(100),
            "old Core Audio generation absence",
        )?;
    }
}

fn settle_stable_coreaudiod_generation(
    deadline: Instant,
) -> Result<ProcessGeneration, String> {
    loop {
        match coreaudiod_identity_until(deadline) {
            Ok(Some(first)) => {
                sleep_before_absolute_deadline(
                    deadline,
                    Duration::from_millis(100),
                    "Core Audio generation settle",
                )?;
                match coreaudiod_identity_until(deadline) {
                    Ok(Some(second)) if second == first => return Ok(first),
                    Ok(_) => {}
                    Err(error) if error.starts_with("transient coreaudiod topology:") => {}
                    Err(error) => return Err(error),
                }
            }
            Ok(None) => {}
            Err(error) if error.starts_with("transient coreaudiod topology:") => {}
            Err(error) => return Err(error),
        }
        sleep_before_absolute_deadline(
            deadline,
            Duration::from_millis(100),
            "Core Audio stable-singleton wait",
        )?;
    }
}

fn wait_for_changed_coreaudiod_generation(
    before: &ProcessGeneration,
    deadline: Instant,
) -> Result<ProcessGeneration, String> {
    loop {
        match coreaudiod_identity_until(deadline) {
            Ok(Some(after)) if &after != before => {
                sleep_before_absolute_deadline(
                    deadline,
                    Duration::from_millis(100),
                    "changed Core Audio generation stability",
                )?;
                match coreaudiod_identity_until(deadline) {
                    Ok(Some(second)) if second == after => return Ok(after),
                    Ok(_) => {}
                    Err(error) if error.starts_with("transient coreaudiod topology:") => {}
                    Err(error) => return Err(error),
                }
            }
            Ok(_) => {}
            Err(error) if error.starts_with("transient coreaudiod topology:") => {}
            Err(error) => return Err(error),
        }
        if Instant::now() >= deadline {
            return Err(
                "Core Audio restart did not yield one stable exact changed generation".to_owned(),
            );
        }
        sleep_before_absolute_deadline(
            deadline,
            Duration::from_millis(100),
            "changed Core Audio generation wait",
        )?;
    }
}

fn reload_core_audio_root() -> Result<(), String> {
    if unsafe { libc_geteuid() } != 0 {
        return Err("Core Audio restart requires effective root".to_owned());
    }
    verify_root_controller_identity()?;
    let absolute_deadline =
        Instant::now() + Duration::from_secs(COREAUDIO_RESTART_ABSOLUTE_SECONDS);
    let before_first = settle_stable_coreaudiod_generation(absolute_deadline)?;
    sleep_before_absolute_deadline(
        absolute_deadline,
        Duration::from_millis(100),
        "Core Audio pre-signal identity",
    )?;
    let before_second = coreaudiod_identity_until(absolute_deadline)?
        .ok_or("coreaudiod disappeared before exact restart")?;
    if before_second != before_first {
        return Err("coreaudiod generation changed across pre-signal proofs".to_owned());
    }
    if Instant::now() >= absolute_deadline {
        return Err("Core Audio restart deadline expired immediately before SIGTERM".to_owned());
    }
    if unsafe { libc_kill(before_first.pid as i32, SIGTERM) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(3) {
            return Err(format!(
                "checked positive-PID Core Audio SIGTERM failed: {error}"
            ));
        }
    }
    wait_for_coreaudiod_generation_absence(&before_first, absolute_deadline)?;
    let after = wait_for_changed_coreaudiod_generation(&before_first, absolute_deadline)?;
    if after == before_first {
        return Err("Core Audio restart did not publish a changed exact generation".to_owned());
    }
    Ok(())
}

fn root_publish_driver(
    hold_identity: &NodeIdentity,
    runtime_lock: &SharedLockGuard,
) -> Result<(), String> {
    verify_root_controller_identity()?;
    require_no_capture_server_root()?;
    let hold = Path::new(ROOT_TRANSACTION).join("OpensteamerVirtualMicrophone.driver.hold");
    if node_identity(&hold)? != *hold_identity {
        return Err("root driver hold was replaced after preparation".to_owned());
    }
    verify_driver_tree(&hold, 0)?;
    require_exact_signature(
        &hold,
        "com.elamin.opensteamer.VirtualMicrophoneDriver",
        CANDIDATE_DRIVER_CDHASH,
        true,
    )?;
    require_absent_no_follow(Path::new(PRODUCT_DRIVER), "canonical product driver before publish")?;
    root_append_state("PUBLISH_INTENT")?;
    runtime_lock.require_named_identity()?;
    require_v6_launchd_service_absent_root()?;
    require_no_capture_server_root()?;
    require_v6_launchd_service_absent_root()?;
    runtime_lock.require_named_identity()?;
    rename_exclusive(&hold, Path::new(PRODUCT_DRIVER))?;
    runtime_lock.require_named_identity()?;
    require_v6_launchd_service_absent_root()?;
    root_append_state("DRIVER_PUBLISHED")?;
    if node_identity(Path::new(PRODUCT_DRIVER))? != *hold_identity {
        return Err("canonical driver inode differs from the prepared hold".to_owned());
    }
    verify_driver_tree(Path::new(PRODUCT_DRIVER), 0)?;
    require_exact_signature(
        Path::new(PRODUCT_DRIVER),
        "com.elamin.opensteamer.VirtualMicrophoneDriver",
        CANDIDATE_DRIVER_CDHASH,
        true,
    )?;
    require_runtime_mutation_guard_barrier_root(runtime_lock)?;
    reload_core_audio_root()?;
    require_runtime_mutation_guard_barrier_root(runtime_lock)?;
    root_append_state("COREAUDIO_RELOADED")?;
    Ok(())
}

fn root_restore_driver(
    hold_identity: &NodeIdentity,
    runtime_lock: Option<&SharedLockGuard>,
) -> Result<(), String> {
    verify_root_controller_identity()?;
    let transaction = Path::new(ROOT_TRANSACTION);
    let hold = transaction.join("OpensteamerVirtualMicrophone.driver.hold");
    let failed = transaction.join("OpensteamerVirtualMicrophone.driver.failed");
    let abandoned = transaction.join("OpensteamerVirtualMicrophone.driver.abandoned");
    let locations = [hold.as_path(), Path::new(PRODUCT_DRIVER), failed.as_path(), abandoned.as_path()];
    let observed = locations
        .iter()
        .map(|path| node_identity(path).map(|identity| (*path, identity)))
        .collect::<Result<Vec<_>, _>>()?;
    let matches: Vec<&Path> = observed
        .iter()
        .filter_map(|(path, identity)| (identity == hold_identity).then_some(*path))
        .collect();
    if matches.len() != 1 {
        return Err(format!(
            "root rollback found {} locations for the exact new driver inode",
            matches.len()
        ));
    }
    let location = matches[0];
    if location == Path::new(PRODUCT_DRIVER) || location == failed {
        // Only a canonical or previously published driver transition requires the host to be
        // absent. An unpublished hold may be retained wholly inside the root-private transaction
        // while the exact v6 host remains healthy.
        require_no_capture_server_root()?;
    }
    if location == Path::new(PRODUCT_DRIVER) {
        let runtime_lock = runtime_lock
            .ok_or("canonical driver rollback lacks the retained runtime-mutation lock")?;
        verify_driver_tree(location, 0)?;
        require_absent_no_follow(&failed, "failed-driver retention path")?;
        runtime_lock.require_named_identity()?;
        require_v6_launchd_service_absent_root()?;
        require_no_capture_server_root()?;
        require_v6_launchd_service_absent_root()?;
        runtime_lock.require_named_identity()?;
        rename_exclusive(location, &failed)?;
        runtime_lock.require_named_identity()?;
        require_v6_launchd_service_absent_root()?;
        root_append_state("DRIVER_REMOVED_FROM_CANONICAL")?;
    } else if location == hold {
        require_absent_no_follow(&abandoned, "abandoned driver hold")?;
        if let Some(runtime_lock) = runtime_lock {
            require_runtime_mutation_guard_barrier_root(runtime_lock)?;
        }
        rename_exclusive(&hold, &abandoned)?;
        if let Some(runtime_lock) = runtime_lock {
            runtime_lock.require_named_identity()?;
        }
        root_append_state("UNPUBLISHED_HOLD_ABANDONED")?;
    }
    require_absent_no_follow(Path::new(PRODUCT_DRIVER), "canonical product driver after rollback")?;
    root_append_state("DRIVER_ROLLBACK_COMPLETE prior=absent")?;
    Ok(())
}

fn root_driver_restored_postcondition(hold_identity: &NodeIdentity) -> Result<bool, String> {
    if node_identity(Path::new(PRODUCT_DRIVER))?.present {
        return Ok(false);
    }
    let transaction = Path::new(ROOT_TRANSACTION);
    let observed = [
        transaction.join("OpensteamerVirtualMicrophone.driver.hold"),
        transaction.join("OpensteamerVirtualMicrophone.driver.failed"),
        transaction.join("OpensteamerVirtualMicrophone.driver.abandoned"),
    ]
    .iter()
    .map(|path| node_identity(path))
    .collect::<Result<Vec<_>, _>>()?;
    Ok(observed
        .iter()
        .filter(|identity| *identity == hold_identity)
        .count()
        == 1)
}

fn root_restore_driver_reload_and_verify_hal(
    hold_identity: &NodeIdentity,
    runtime_lock: Option<&SharedLockGuard>,
) -> Result<RecoveryOperationOutcome, String> {
    let mut outcome = RecoveryOperationOutcome::default();
    let operation = root_restore_driver(hold_identity, runtime_lock);
    if !root_driver_restored_postcondition(hold_identity)? {
        return Err(format!(
            "driver physical rollback postcondition failed: {operation:?}"
        ));
    }
    let failed = Path::new(ROOT_TRANSACTION).join("OpensteamerVirtualMicrophone.driver.failed");
    let exact_driver_was_published = node_identity(&failed)? == *hold_identity;
    if exact_driver_was_published {
        let runtime_lock = runtime_lock
            .ok_or("published-driver recovery lacks the retained runtime-mutation lock")?;
        // The exact retained failed inode proves that this driver reached the canonical product
        // path, including a rename followed by a journal error. One strong synchronous generation
        // transition follows physical rollback; an intent-only hold never restarts Core Audio.
        require_runtime_mutation_guard_barrier_root(runtime_lock)?;
        reload_core_audio_root()?;
        require_runtime_mutation_guard_barrier_root(runtime_lock)?;
        if let Err(error) = root_append_state("ROLLBACK_COREAUDIO_RELOADED") {
            outcome.diagnostics.push(format!(
                "driver rollback Core Audio journal failed: {error}"
            ));
        }
        run_uid_sealed(UID_VERIFY_HAL_MODE, None)?;
        require_runtime_mutation_guard_barrier_root(runtime_lock)?;
    }
    if let Err(error) = operation {
        outcome.diagnostics.push(format!(
            "driver rollback operation recovered by exact postcondition: {error}"
        ));
        if let Err(journal_error) = root_append_state(&format!(
            "DRIVER_ROLLBACK_OPERATION_ERROR_RECOVERED_BY_POSTCONDITION {error}"
        )) {
            outcome.diagnostics.push(format!(
                "driver rollback recovery journal failed: {journal_error}"
            ));
        }
    }
    if let Err(error) = root_append_state("DRIVER_ROLLBACK_RELOAD_AND_PUBLIC_HAL_PROVED") {
        outcome
            .diagnostics
            .push(format!("driver rollback terminal journal failed: {error}"));
    }
    Ok(outcome)
}

fn process_start_identity(pid: u32) -> Result<String, String> {
    let output = bounded_output(
        Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .env_clear()
        .env("LC_ALL", "C"),
        Duration::from_secs(5),
        65_536,
        "inspect process start identity",
    )?;
    if !output.status.success() {
        return Err(format!("PID {pid} is unavailable"));
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "process start is not UTF-8")?;
    let value = text.trim().to_owned();
    if value.len() < 20 || value.contains(['\n', '\r']) {
        return Err("process start identity is malformed".to_owned());
    }
    Ok(value)
}

fn capture_server_pids() -> Result<Vec<u32>, String> {
    let output = bounded_output(
        Command::new("/usr/bin/pgrep")
        .args(["-x", "CaptureServer"])
        .env_clear()
        .env("LC_ALL", "C"),
        Duration::from_secs(5),
        65_536,
        "enumerate CaptureServer processes",
    )?;
    if output.status.code() == Some(1) && output.stdout.is_empty() {
        return Ok(Vec::new());
    }
    if !output.status.success() {
        return Err(format!(
            "CaptureServer enumeration failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "pgrep output is not UTF-8")?;
    text.lines()
        .map(|line| {
            line.parse::<u32>()
                .ok()
                .filter(|pid| *pid > 0)
                .ok_or_else(|| "pgrep emitted malformed PID".to_owned())
        })
        .collect()
}

fn capture_server_pids_until(deadline: Instant) -> Result<Vec<u32>, String> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or("CaptureServer enumeration absolute deadline expired")?;
    let timeout = remaining
        .checked_sub(Duration::from_secs(3))
        .map(|value| std::cmp::min(value, Duration::from_secs(FAST_PROCESS_BOUND_SECONDS)))
        .filter(|value| !value.is_zero())
        .ok_or("CaptureServer enumeration lacks its process teardown reserve")?;
    let output = bounded_output(
        Command::new("/usr/bin/pgrep")
            .args(["-x", "CaptureServer"])
            .env_clear()
            .env("LC_ALL", "C"),
        timeout,
        65_536,
        "enumerate CaptureServer processes before retained-Child reap",
    )?;
    if output.status.code() == Some(1) && output.stdout.is_empty() {
        return Ok(Vec::new());
    }
    if !output.status.success() {
        return Err(format!(
            "CaptureServer enumeration failed before retained-Child reap: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| "pre-reap CaptureServer enumeration is not UTF-8")?;
    text.lines()
        .map(|line| {
            line.parse::<u32>()
                .ok()
                .filter(|pid| *pid > 1 && *pid <= i32::MAX as u32)
                .ok_or_else(|| "pre-reap CaptureServer enumeration emitted malformed PID".to_owned())
        })
        .collect()
}

fn process_executable_path(pid: u32) -> Result<PathBuf, String> {
    let mut buffer = vec![0_u8; 4_096];
    let length = unsafe {
        libc_proc_pidpath(
            pid as i32,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
        )
    };
    if length <= 0 || length as usize >= buffer.len() {
        return Err(format!(
            "proc_pidpath could not resolve PID {pid}: {}",
            std::io::Error::last_os_error()
        ));
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .ok_or("proc_pidpath result was not NUL terminated")?;
    if end == 0 || end > length as usize {
        return Err("proc_pidpath returned a malformed path length".to_owned());
    }
    let value = std::str::from_utf8(&buffer[..end])
        .map_err(|_| "proc_pidpath returned a non-UTF-8 path")?;
    if !value.starts_with('/') || value.contains(['\n', '\r', '\0']) {
        return Err("proc_pidpath returned an unsafe path".to_owned());
    }
    Ok(PathBuf::from(value))
}

fn verify_exact_process_executable(
    pid: u32,
    expected_path: &Path,
    expected_owner: u32,
    expected_hash: &str,
) -> Result<(), String> {
    let first_path = process_executable_path(pid)?;
    if first_path != expected_path {
        return Err(format!(
            "PID {pid} primary executable changed: {}",
            first_path.display()
        ));
    }
    let before = fs::symlink_metadata(expected_path)
        .map_err(|error| format!("could not inspect primary executable: {error}"))?;
    if !before.is_file()
        || before.file_type().is_symlink()
        || before.uid() != expected_owner
        || before.nlink() != 1
        || before.dev() == 0
        || before.ino() == 0
        || before.mode() & 0o111 == 0
        || before.mode() & 0o022 != 0
    {
        return Err("primary executable named identity is unsafe".to_owned());
    }
    require_hash(expected_path, expected_hash)?;
    let after = fs::symlink_metadata(expected_path)
        .map_err(|error| format!("could not reinspect primary executable: {error}"))?;
    if before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
        || process_executable_path(pid)? != expected_path
    {
        return Err("primary executable changed during exact identity proof".to_owned());
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CandidatePhase {
    DormantGate,
    LiveHost,
}

fn classify_candidate_primary_path(path: &Path) -> Result<CandidatePhase, String> {
    if path == Path::new(SEALED_CONTROLLER) {
        Ok(CandidatePhase::DormantGate)
    } else if path == Path::new(SEALED_HOST_EXECUTABLE) {
        Ok(CandidatePhase::LiveHost)
    } else {
        Err(format!(
            "candidate primary executable is unreviewed: {}",
            path.display()
        ))
    }
}

fn verify_candidate_phase_capture_topology(
    pid: u32,
    phase: CandidatePhase,
) -> Result<(), String> {
    let capture_servers = capture_server_pids()?;
    match phase {
        CandidatePhase::DormantGate if capture_servers.is_empty() => Ok(()),
        CandidatePhase::DormantGate if capture_servers.len() == 1 => {
            verify_exact_v6_process_mapping(capture_servers[0])
        }
        CandidatePhase::LiveHost if capture_servers == [pid] => Ok(()),
        _ => Err("candidate gate/host CaptureServer topology changed".to_owned()),
    }
}

fn verify_root_candidate_or_gate(pid: u32) -> Result<(String, CandidatePhase), String> {
    let primary = process_executable_path(pid)?;
    let phase = classify_candidate_primary_path(&primary)?;
    let expected_hash = match phase {
        CandidatePhase::DormantGate => {
            require_root_regular(Path::new(SEALED_CONTROLLER_PIN), 0o444)?;
            read_bounded_utf8(Path::new(SEALED_CONTROLLER_PIN), 128, 0, 0o444)?
        }
        CandidatePhase::LiveHost => CANDIDATE_HOST_SHA256.to_owned(),
    };
    let expected_path = match phase {
        CandidatePhase::DormantGate => Path::new(SEALED_CONTROLLER),
        CandidatePhase::LiveHost => Path::new(SEALED_HOST_EXECUTABLE),
    };
    verify_exact_process_executable(pid, expected_path, 0, expected_hash.trim())?;
    verify_candidate_phase_capture_topology(pid, phase)?;
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("candidate is not the leader of its isolated process group/session".to_owned());
    }
    Ok((process_start_identity(pid)?, phase))
}

fn verify_root_candidate(pid: u32) -> Result<String, String> {
    let (start, phase) = verify_root_candidate_or_gate(pid)?;
    if phase != CandidatePhase::LiveHost {
        return Err("candidate gate has not execed the sealed host".to_owned());
    }
    Ok(start)
}

fn verify_tracked_candidate_identity(pid: u32, expected_start: &str) -> Result<(), String> {
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
        || process_start_identity(pid)? != expected_start
    {
        return Err("tracked candidate gate/host process identity changed".to_owned());
    }
    Ok(())
}

fn verify_exact_v6_process_mapping(pid: u32) -> Result<(), String> {
    verify_exact_process_executable(pid, Path::new(HOST_EXECUTABLE), 501, V6_HOST_SHA256)
}

fn verify_exact_v6_process_mapping_until(pid: u32, deadline: Instant) -> Result<(), String> {
    if Instant::now() >= deadline {
        return Err("exact-v6 process mapping deadline expired before identity proof".to_owned());
    }
    let expected_path = Path::new(HOST_EXECUTABLE);
    let first_path = process_executable_path(pid)?;
    if first_path != expected_path {
        return Err(format!(
            "PID {pid} exact-v6 executable changed: {}",
            first_path.display()
        ));
    }
    let before = fs::symlink_metadata(expected_path)
        .map_err(|error| format!("could not inspect exact-v6 executable: {error}"))?;
    if !before.is_file()
        || before.file_type().is_symlink()
        || before.uid() != 501
        || before.nlink() != 1
        || before.dev() == 0
        || before.ino() == 0
        || before.mode() & 0o111 == 0
        || before.mode() & 0o022 != 0
    {
        return Err("exact-v6 executable named identity is unsafe".to_owned());
    }
    require_hash_until(expected_path, V6_HOST_SHA256, deadline)?;
    let after = fs::symlink_metadata(expected_path)
        .map_err(|error| format!("could not reinspect exact-v6 executable: {error}"))?;
    if Instant::now() >= deadline
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
        || process_executable_path(pid)? != expected_path
    {
        return Err("exact-v6 executable changed during deadline-aware identity proof".to_owned());
    }
    Ok(())
}

fn verify_root_guardian_process(pid: u32) -> Result<String, String> {
    verify_exact_process_executable(pid, Path::new(SEALED_GUARDIAN), 0, ROUTE_GUARDIAN_SHA256)?;
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("persistent guardian is not the exact sealed new-session process".to_owned());
    }
    process_start_identity(pid)
}

fn process_group_exists(pid: u32) -> Result<bool, String> {
    let status = unsafe { libc_kill(-(pid as i32), 0) };
    if status == 0 {
        return Ok(true);
    }
    match std::io::Error::last_os_error().raw_os_error() {
        Some(3) => Ok(false),
        other => Err(format!("process-group existence probe failed: {other:?}")),
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct DarwinSigInfo {
    si_signo: i32,
    si_errno: i32,
    si_code: i32,
    si_pid: i32,
    si_uid: u32,
    si_status: i32,
    si_addr: *mut std::ffi::c_void,
    si_value: usize,
    si_band: i64,
    pad: [u64; 7],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct DarwinProcBsdInfo {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    reserved: u32,
    comm: [i8; 16],
    name: [i8; 32],
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    tty_device: u32,
    tty_pgid: u32,
    nice: i32,
    start_seconds: u64,
    start_microseconds: u64,
}

#[derive(Clone, Copy, Debug)]
struct SessionMemberIdentity {
    pid: u32,
    uid: u32,
    status: u32,
    pgid: u32,
    start_seconds: u64,
    start_microseconds: u64,
}

impl PartialEq for SessionMemberIdentity {
    fn eq(&self, other: &Self) -> bool {
        self.pid == other.pid
            && self.uid == other.uid
            && self.pgid == other.pgid
            && self.start_seconds == other.start_seconds
            && self.start_microseconds == other.start_microseconds
    }
}

impl Eq for SessionMemberIdentity {}

#[derive(Debug)]
struct OwnedSessionTermination {
    status: ExitStatus,
    diagnostics: Vec<String>,
}

#[derive(Debug)]
struct OwnedSessionChild {
    child: Child,
    session: u32,
    label: String,
    reaped: bool,
}

impl OwnedSessionChild {
    fn new(child: Child, label: &str) -> Self {
        let session = child.id();
        Self {
            child,
            session,
            label: label.to_owned(),
            reaped: false,
        }
    }

    fn id(&self) -> u32 {
        self.session
    }

    fn mark_reaped(&mut self) {
        self.reaped = true;
    }
}

impl std::ops::Deref for OwnedSessionChild {
    type Target = Child;

    fn deref(&self) -> &Self::Target {
        &self.child
    }
}

impl std::ops::DerefMut for OwnedSessionChild {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.child
    }
}

impl Drop for OwnedSessionChild {
    fn drop(&mut self) {
        if self.reaped {
            return;
        }
        // This is the final ownership backstop, not an ordinary recovery path. Explicit callers
        // use one reviewed absolute deadline and surface diagnostics. If one of those callers is
        // accidentally bypassed or returns with an unreaped session, retain the direct Child/PID
        // reservation and keep performing positive-PID SID sweeps until exact quiescence and the
        // sole reap. Silently dropping the only Child is never an allowed failure mode.
        loop {
            let deadline = Instant::now()
                + Duration::from_secs(OWNED_SESSION_TERMINATION_PRIMITIVE_SECONDS);
            match terminate_preconfigured_session(self, self.session, &self.label.clone(), deadline) {
                Ok(_) => return,
                Err(_) => thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

enum ManagedChild {
    Owned(OwnedSessionChild),
    Ordinary(Child),
}

impl ManagedChild {
    fn owned_mut(&mut self) -> Result<&mut OwnedSessionChild, String> {
        match self {
            Self::Owned(child) => Ok(child),
            Self::Ordinary(_) => Err("managed child is not a retained session".to_owned()),
        }
    }
}

impl std::ops::Deref for ManagedChild {
    type Target = Child;

    fn deref(&self) -> &Self::Target {
        match self {
            Self::Owned(child) => child,
            Self::Ordinary(child) => child,
        }
    }
}

impl std::ops::DerefMut for ManagedChild {
    fn deref_mut(&mut self) -> &mut Self::Target {
        match self {
            Self::Owned(child) => child,
            Self::Ordinary(child) => child,
        }
    }
}

#[derive(Debug, Default)]
struct RecoveryOperationOutcome {
    diagnostics: Vec<String>,
}

#[derive(Debug, Default)]
struct EmergencyErrors {
    entries: Vec<String>,
    dropped: usize,
}

impl EmergencyErrors {
    fn push(&mut self, label: &str, error: impl std::fmt::Display) {
        if self.entries.len() >= 32 {
            self.dropped += 1;
            return;
        }
        let sanitized = error.to_string().replace(['\n', '\r', '\0'], " ");
        let bounded = sanitized.chars().take(384).collect::<String>();
        self.entries.push(format!("{label}={bounded}"));
    }

    fn render(&self) -> String {
        let mut value = self.entries.join(" | ");
        if self.dropped != 0 {
            value.push_str(&format!(" | dropped={}", self.dropped));
        }
        value
    }
}

fn push_session_diagnostic(
    diagnostics: &mut Vec<String>,
    label: &str,
    error: impl std::fmt::Display,
) {
    if diagnostics.len() >= 16 {
        return;
    }
    let value = error
        .to_string()
        .replace(['\n', '\r', '\0'], " ")
        .chars()
        .take(320)
        .collect::<String>();
    diagnostics.push(format!("{label}={value}"));
}

fn getsid_exact_or_absent(pid: u32) -> Result<Option<u32>, String> {
    if pid == 0 || pid > i32::MAX as u32 {
        return Err("getsid PID is outside the positive process API".to_owned());
    }
    let observed = unsafe { libc_getsid(pid as i32) };
    if observed >= 0 {
        return Ok(Some(observed as u32));
    }
    match std::io::Error::last_os_error().raw_os_error() {
        Some(3) => Ok(None),
        other => Err(format!("getsid failed for PID {pid}: {other:?}")),
    }
}

fn process_bsd_identity(pid: u32) -> Result<Option<SessionMemberIdentity>, String> {
    if pid <= 1 || pid > i32::MAX as u32 {
        return Err("libproc PID is outside the positive process API".to_owned());
    }
    let mut info: DarwinProcBsdInfo = unsafe { std::mem::zeroed() };
    let expected_size = i32::try_from(std::mem::size_of::<DarwinProcBsdInfo>())
        .map_err(|_| "libproc identity buffer size overflowed")?;
    let observed_size = unsafe {
        libc_proc_pidinfo(
            pid as i32,
            3,
            0,
            (&mut info as *mut DarwinProcBsdInfo).cast(),
            expected_size,
        )
    };
    if observed_size == 0 {
        return match std::io::Error::last_os_error().raw_os_error() {
            Some(3) => Ok(None),
            other => Err(format!("libproc identity failed for PID {pid}: {other:?}")),
        };
    }
    if observed_size != expected_size
        || info.pid != pid
        || info.start_seconds == 0
        || info.start_microseconds >= 1_000_000
    {
        return Err(format!("libproc identity was malformed for PID {pid}"));
    }
    Ok(Some(SessionMemberIdentity {
        pid,
        uid: info.uid,
        status: info.status,
        pgid: info.pgid,
        start_seconds: info.start_seconds,
        start_microseconds: info.start_microseconds,
    }))
}

fn session_member_identities(
    session: u32,
    deadline: Instant,
) -> Result<Vec<SessionMemberIdentity>, String> {
    if session <= 1 || session > i32::MAX as u32 {
        return Err("session identity is outside the positive process API".to_owned());
    }
    if Instant::now() >= deadline {
        return Err("session enumeration absolute deadline expired".to_owned());
    }
    let mut storage = vec![0_i32; 131_072];
    let byte_count = storage
        .len()
        .checked_mul(std::mem::size_of::<i32>())
        .and_then(|value| i32::try_from(value).ok())
        .ok_or("process-list buffer size overflowed")?;
    let count = unsafe { libc_proc_listallpids(storage.as_mut_ptr().cast(), byte_count) };
    if count <= 0 || count as usize >= storage.len() {
        return Err("could not enumerate a bounded complete process list".to_owned());
    }
    let mut members = Vec::new();
    for raw_pid in storage.into_iter().take(count as usize).filter(|pid| *pid > 1) {
        if Instant::now() >= deadline {
            return Err("session enumeration absolute deadline expired".to_owned());
        }
        let pid = raw_pid as u32;
        if getsid_exact_or_absent(pid)? != Some(session) {
            continue;
        }
        let Some(first) = process_bsd_identity(pid)? else {
            continue;
        };
        if getsid_exact_or_absent(pid)? != Some(session) {
            continue;
        }
        let Some(second) = process_bsd_identity(pid)? else {
            continue;
        };
        if !(1..=5).contains(&first.status)
            || !(1..=5).contains(&second.status)
            || first != second
        {
            return Err(format!("session member PID {pid} changed during enumeration"));
        }
        members.push(first);
    }
    members.sort_unstable_by_key(|member| member.pid);
    members.dedup_by_key(|member| member.pid);
    Ok(members)
}

fn retained_child_exited_without_reap(child: &Child) -> Result<bool, String> {
    if child.id() <= 1 {
        return Err("retained Child PID is outside the positive process API".to_owned());
    }
    let mut interruptions = 0_u8;
    let (status, info) = loop {
        // Darwin may leave siginfo storage unspecified on EINTR. Reset every retry so a prior
        // partial event can never be mistaken for this nonreaping observation.
        let mut info: DarwinSigInfo = unsafe { std::mem::zeroed() };
        let observed = unsafe {
            libc_waitid(
                1,
                child.id(),
                &mut info,
                0x0000_0001 | 0x0000_0004 | 0x0000_0020,
            )
        };
        if observed == 0
            || std::io::Error::last_os_error().raw_os_error() != Some(4)
            || interruptions >= 3
        {
            break (observed, info);
        }
        interruptions += 1;
    };
    if status != 0 {
        return Err(format!(
            "nonreaping retained-Child waitid failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    if info.si_pid == 0 {
        return Ok(false);
    }
    if info.si_pid != child.id() as i32 {
        return Err("waitid returned a different retained Child identity".to_owned());
    }
    if info.si_signo != DARWIN_SIGCHLD
        || !matches!(
            info.si_code,
            DARWIN_CLD_EXITED | DARWIN_CLD_KILLED | DARWIN_CLD_DUMPED
        )
    {
        return Err("waitid returned an unreviewed retained-Child event".to_owned());
    }
    Ok(true)
}

fn supervising_session() -> Result<u32, String> {
    let observed = unsafe { libc_getsid(0) };
    if observed <= 1 {
        return Err(format!(
            "could not prove supervising session: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(observed as u32)
}

fn signal_session_members(
    session: u32,
    signal: i32,
    deadline: Instant,
) -> Result<(), String> {
    if !matches!(signal, SIGTERM | SIGKILL) {
        return Err("refused an unreviewed session signal".to_owned());
    }
    if supervising_session()? == session {
        return Err("refused to signal the supervising process's own session".to_owned());
    }
    let mut errors = Vec::new();
    let members = match session_member_identities(session, deadline) {
        Ok(value) => value,
        Err(error) => return Err(format!("session enumeration before signal failed: {error}")),
    };
    for member in members {
        if Instant::now() >= deadline {
            errors.push("session signal absolute deadline expired".to_owned());
            break;
        }
        let current = match process_bsd_identity(member.pid) {
            Ok(Some(value)) => value,
            Ok(None) => continue,
            Err(error) => {
                errors.push(format!(
                    "session member PID {} identity proof failed: {error}",
                    member.pid
                ));
                continue;
            }
        };
        if current.status == 5 {
            continue;
        }
        if !(1..=4).contains(&current.status) {
            errors.push(format!(
                "session member PID {} has unreviewed BSD status {}",
                member.pid, current.status
            ));
            continue;
        }
        if current != member {
            errors.push(format!(
                "session member PID {} changed before checked positive-PID signal",
                member.pid
            ));
            continue;
        }
        match getsid_exact_or_absent(member.pid) {
            Err(error) => {
                errors.push(error);
                continue;
            }
            Ok(None) => continue,
            Ok(Some(observed)) if observed != session => {
                errors.push(format!(
                    "session member PID {} left SID {session} before signal",
                    member.pid
                ));
                continue;
            }
            Ok(Some(_)) => {}
        }
        if Instant::now() >= deadline {
            errors.push(format!(
                "session signal deadline expired after final SID proof for PID {}",
                member.pid
            ));
            continue;
        }
        if unsafe { libc_kill(member.pid as i32, signal) } != 0 {
            match std::io::Error::last_os_error().raw_os_error() {
                Some(3) if matches!(getsid_exact_or_absent(member.pid), Ok(None)) => {}
                other => errors.push(format!(
                    "session signal failed for PID {}: {other:?}",
                    member.pid
                )),
            }
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join(" | "))
    }
}

fn terminate_preconfigured_session(
    child: &mut OwnedSessionChild,
    session: u32,
    label: &str,
    absolute_deadline: Instant,
) -> Result<OwnedSessionTermination, String> {
    if child.id() != session {
        return Err(format!("{label} retained Child identity changed"));
    }
    if supervising_session()? == session {
        return Err(format!("{label} session aliases its supervisor"));
    }
    let mut signal_errors = Vec::new();
    if let Err(error) = signal_session_members(session, SIGTERM, absolute_deadline) {
        push_session_diagnostic(&mut signal_errors, "TERM", error);
    }
    let kill_reserve = Duration::from_secs(2);
    let term_deadline = std::cmp::min(
        Instant::now() + Duration::from_millis(500),
        absolute_deadline
            .checked_sub(kill_reserve)
            .unwrap_or_else(Instant::now),
    );
    while Instant::now() < term_deadline {
        match owned_session_ready_to_reap(child, session, absolute_deadline) {
            Ok(true) => break,
            Ok(false) => {}
            Err(error) => {
                push_session_diagnostic(&mut signal_errors, "TERM_BARRIER", error);
                break;
            }
        }
        sleep_capped_by_absolute_deadline(term_deadline, Duration::from_millis(20));
    }
    // Always perform a fresh KILL sweep before the sole reap. If TERM already drained the
    // retained session this is an exact empty enumeration; otherwise it catches descendants
    // created by a TERM handler without relying on a stale PGID or PID.
    if let Err(error) = signal_session_members(session, SIGKILL, absolute_deadline) {
        push_session_diagnostic(&mut signal_errors, "KILL", error);
    }
    while Instant::now() < absolute_deadline {
        if let Err(error) = signal_session_members(session, SIGKILL, absolute_deadline) {
            push_session_diagnostic(&mut signal_errors, "KILL_SWEEP", error);
        }
        match owned_session_ready_to_reap(child, session, absolute_deadline) {
            Ok(true) => {
                let status = reap_quiescent_owned_session(child, session, label, absolute_deadline)?;
                return Ok(OwnedSessionTermination {
                    status,
                    diagnostics: signal_errors,
                });
            }
            Ok(false) => {}
            Err(error) => push_session_diagnostic(&mut signal_errors, "KILL_BARRIER", error),
        }
        sleep_capped_by_absolute_deadline(absolute_deadline, Duration::from_millis(20));
    }
    Err(format!("{label} session survived TERM/KILL"))
}

fn owned_session_ready_to_reap(
    child: &OwnedSessionChild,
    session: u32,
    deadline: Instant,
) -> Result<bool, String> {
    if child.id() != session {
        return Err("retained Child/session identity changed before reap barrier".to_owned());
    }
    if !retained_child_exited_without_reap(child)? {
        return Ok(false);
    }
    let first = session_member_identities(session, deadline)?;
    if first.iter().any(|member| member.pid != session) {
        return Ok(false);
    }
    if !retained_child_exited_without_reap(child)? {
        return Ok(false);
    }
    if Instant::now() >= deadline {
        return Err("retained session stable-empty deadline expired".to_owned());
    }
    thread::sleep(std::cmp::min(
        Duration::from_millis(5),
        deadline.saturating_duration_since(Instant::now()),
    ));
    let second = session_member_identities(session, deadline)?;
    if second.iter().any(|member| member.pid != session) {
        return Ok(false);
    }
    retained_child_exited_without_reap(child)
}

fn reap_quiescent_owned_session(
    child: &mut OwnedSessionChild,
    session: u32,
    label: &str,
    deadline: Instant,
) -> Result<ExitStatus, String> {
    if !owned_session_ready_to_reap(child, session, deadline)? {
        return Err(format!("{label} reap refused before exact session quiescence"));
    }
    let status = child
        .wait()
        .map_err(|error| format!("could not reap {label}: {error}"))?;
    child.mark_reaped();
    Ok(status)
}

fn prove_candidate_capture_topology_before_reap(
    child: &OwnedSessionChild,
    candidate_pid: u32,
    allow_exact_v6: bool,
    deadline: Instant,
) -> Result<(), String> {
    if child.id() != candidate_pid || !retained_child_exited_without_reap(child)? {
        return Err("candidate CaptureServer barrier lacks its exact exited retained Child".to_owned());
    }
    if deadline.saturating_duration_since(Instant::now())
        < Duration::from_secs(CANDIDATE_CAPTURE_TOPOLOGY_MINIMUM_SECONDS)
    {
        return Err("candidate CaptureServer barrier lacks its bounded topology reserve".to_owned());
    }
    let mut exact_v6_pid = None;
    for pass in 0..2 {
        let observed = capture_server_pids_until(deadline)?;
        if observed.contains(&candidate_pid) && !retained_child_exited_without_reap(child)? {
            return Err("candidate PID became live during pre-reap CaptureServer proof".to_owned());
        }
        let others = observed
            .into_iter()
            .filter(|pid| *pid != candidate_pid)
            .collect::<Vec<_>>();
        if allow_exact_v6 {
            if others.len() != 1 {
                return Err("pre-destructive candidate cleanup lost its sole exact-v6 host".to_owned());
            }
            verify_exact_v6_process_mapping_until(others[0], deadline)?;
            match exact_v6_pid {
                None => exact_v6_pid = Some(others[0]),
                Some(expected) if expected == others[0] => {}
                Some(_) => return Err("exact-v6 generation changed across candidate reap fence".to_owned()),
            }
        } else if !others.is_empty() {
            return Err(
                "unexpected non-candidate CaptureServer remained before candidate reap".to_owned(),
            );
        }
        if pass == 0 {
            sleep_capped_by_absolute_deadline(deadline, Duration::from_millis(5));
        }
    }
    Ok(())
}

fn finish_owned_candidate_stop(
    child: &mut OwnedSessionChild,
    session: u32,
    signal_errors: Vec<String>,
    deadline: Instant,
    allow_exact_v6: bool,
) -> Result<OwnedSessionTermination, String> {
    // Keep the unreaped direct Child as the authority for this numeric SID while proving the
    // global CaptureServer topology. No fallible process proof may follow the sole wait/reap.
    prove_candidate_capture_topology_before_reap(
        child,
        session,
        allow_exact_v6,
        deadline,
    )?;
    if !owned_session_ready_to_reap(child, session, deadline)? {
        return Err("candidate session was not stably empty before its sole reap".to_owned());
    }
    let status = reap_quiescent_owned_session(
        child,
        session,
        "root-owned candidate gate/host",
        deadline,
    )?;
    Ok(OwnedSessionTermination {
        status,
        diagnostics: signal_errors,
    })
}

fn stop_owned_candidate_root(
    child: &mut OwnedSessionChild,
    candidate: &(u32, String),
    allow_exact_v6: bool,
    caller_deadline: Instant,
) -> Result<OwnedSessionTermination, String> {
    let (pid, _expected_start) = candidate;
    if *pid <= 1 || child.id() != *pid {
        return Err("candidate retained Child/PID ownership changed".to_owned());
    }
    if supervising_session()? == *pid {
        return Err("candidate session aliases its root supervisor".to_owned());
    }
    let absolute_deadline = std::cmp::min(
        caller_deadline,
        Instant::now() + Duration::from_secs(CANDIDATE_STOP_PRIMITIVE_SECONDS),
    );
    let available = absolute_deadline
        .checked_duration_since(Instant::now())
        .filter(|value| {
            *value > Duration::from_secs(CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS)
        })
        .ok_or("candidate stop lacks its mandatory KILL/topology reserve")?;
    let _ = available;
    let signal_deadline = absolute_deadline
        .checked_sub(Duration::from_secs(
            CANDIDATE_CAPTURE_TOPOLOGY_PRIMITIVE_SECONDS,
        ))
        .ok_or("candidate stop lacks its pre-reap topology reserve")?;
    let mut signal_errors = Vec::new();
    match owned_session_ready_to_reap(child, *pid, signal_deadline) {
        Ok(true) => {
            return finish_owned_candidate_stop(
                child,
                *pid,
                signal_errors,
                absolute_deadline,
                allow_exact_v6,
            )
        }
        Ok(false) => {}
        Err(error) => push_session_diagnostic(&mut signal_errors, "INITIAL_BARRIER", error),
    }
    match retained_child_exited_without_reap(child) {
        Ok(_) => {}
        Err(error) => push_session_diagnostic(&mut signal_errors, "WAITID", error),
    }
    if let Err(error) = signal_session_members(*pid, SIGTERM, signal_deadline) {
        push_session_diagnostic(&mut signal_errors, "TERM", error);
    }
    let term_deadline = std::cmp::min(
        signal_deadline
            .checked_sub(Duration::from_secs(3))
            .unwrap_or_else(Instant::now),
        Instant::now() + Duration::from_secs(8),
    );
    while Instant::now() < term_deadline {
        match owned_session_ready_to_reap(child, *pid, signal_deadline) {
            Ok(true) => break,
            Ok(false) => {}
            Err(error) => {
                push_session_diagnostic(&mut signal_errors, "TERM_BARRIER", error);
                break;
            }
        }
        sleep_capped_by_absolute_deadline(term_deadline, Duration::from_millis(100));
    }
    if let Err(error) = signal_session_members(*pid, SIGKILL, signal_deadline) {
        push_session_diagnostic(&mut signal_errors, "KILL", error);
    }
    while Instant::now() < signal_deadline {
        if let Err(error) = signal_session_members(*pid, SIGKILL, signal_deadline) {
            push_session_diagnostic(&mut signal_errors, "KILL_SWEEP", error);
        }
        match owned_session_ready_to_reap(child, *pid, signal_deadline) {
            Ok(true) => {
                return finish_owned_candidate_stop(
                    child,
                    *pid,
                    signal_errors,
                    absolute_deadline,
                    allow_exact_v6,
                )
            }
            Ok(false) => {}
            Err(error) => push_session_diagnostic(&mut signal_errors, "KILL_BARRIER", error),
        }
        sleep_capped_by_absolute_deadline(signal_deadline, Duration::from_millis(100));
    }
    Err(format!(
        "exact retained candidate session survived checked positive-PID TERM/KILL; diagnostics={}",
        signal_errors.join(" | ")
    ))
}

fn run_uid_sealed_until(
    mode: &str,
    argument: Option<&str>,
    absolute_deadline: Instant,
) -> Result<(), String> {
    if unsafe { libc_geteuid() } != 0
        || !matches!(
            mode,
            UID_EMERGENCY_REPAIR_MODE
                | UID_EMERGENCY_V6_MODE
                | UID_FINALIZE_EVIDENCE_MODE
                | UID_VERIFY_HAL_MODE
                | UID_VERIFY_CANDIDATE_MODE
                | UID_STOP_V6_MODE
        )
    {
        return Err("root rejected an unreviewed sealed UID helper mode".to_owned());
    }
    let (root_capability, child_capability) = UnixStream::pair()
        .map_err(|error| format!("could not create root launch capability: {error}"))?;
    let child_capability_fd = child_capability.into_raw_fd();
    let mut command = Command::new(SEALED_CONTROLLER);
    command
        .arg(mode)
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(unsafe { Stdio::from_raw_fd(child_capability_fd) });
    if let Some(value) = argument {
        command.arg(value);
    }
    unsafe {
        command.pre_exec(|| {
            if libc_setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc_setgroups(AHMED_GROUPS.len() as i32, AHMED_GROUPS.as_ptr()) != 0
                || libc_setgid(20) != 0
                || libc_setuid(501) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let reviewed_timeout = match mode {
        UID_VERIFY_HAL_MODE => Duration::from_secs(UID_HAL_HELPER_SECONDS),
        UID_EMERGENCY_REPAIR_MODE => Duration::from_secs(UID_ROUTE_REPAIR_HELPER_SECONDS),
        UID_STOP_V6_MODE => Duration::from_secs(UID_STOP_HELPER_SECONDS),
        UID_EMERGENCY_V6_MODE => Duration::from_secs(UID_RESTORE_HELPER_SECONDS),
        UID_FINALIZE_EVIDENCE_MODE => {
            Duration::from_secs(UID_FINALIZE_EVIDENCE_HELPER_SECONDS)
        }
        UID_VERIFY_CANDIDATE_MODE => Duration::from_secs(UID_CANDIDATE_HELPER_SECONDS),
        _ => return Err("sealed UID helper mode has no reviewed phase budget".to_owned()),
    };
    let remaining = absolute_deadline
        .checked_duration_since(Instant::now())
        .ok_or("sealed UID helper absolute recovery deadline expired")?;
    let teardown_reserve = Duration::from_secs(UID_SEALED_TEARDOWN_RESERVE_SECONDS);
    let timeout = remaining
        .checked_sub(teardown_reserve)
        .map(|value| std::cmp::min(value, reviewed_timeout))
        .filter(|value| !value.is_zero())
        .ok_or("sealed UID helper lacks its retained-session teardown reserve")?;
    let output = bounded_output_preconfigured_session_with_configured_stdin(
        &mut command,
        timeout,
        1_048_576,
        "sealed UID501 recovery",
    )?;
    drop(root_capability);
    if !output.status.success() {
        return Err(format!(
            "sealed UID501 recovery failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

fn run_uid_sealed(mode: &str, argument: Option<&str>) -> Result<(), String> {
    let reviewed_seconds = match mode {
        UID_VERIFY_HAL_MODE => UID_HAL_HELPER_SECONDS,
        UID_EMERGENCY_REPAIR_MODE => UID_ROUTE_REPAIR_HELPER_SECONDS,
        UID_STOP_V6_MODE => UID_STOP_HELPER_SECONDS,
        UID_EMERGENCY_V6_MODE => UID_RESTORE_HELPER_SECONDS,
        UID_FINALIZE_EVIDENCE_MODE => UID_FINALIZE_EVIDENCE_HELPER_SECONDS,
        UID_VERIFY_CANDIDATE_MODE => UID_CANDIDATE_HELPER_SECONDS,
        _ => return Err("sealed UID helper mode has no reviewed phase budget".to_owned()),
    };
    run_uid_sealed_until(
        mode,
        argument,
        Instant::now()
            + Duration::from_secs(reviewed_seconds + UID_SEALED_TEARDOWN_RESERVE_SECONDS),
    )
}

fn run_bounded_uid_admission() -> Result<(), String> {
    let mut command = Command::new(SEALED_CONTROLLER);
    command
        .arg(UID_ADMISSION_MODE)
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .current_dir("/");
    unsafe {
        command.pre_exec(|| {
            if libc_setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let output = bounded_output_preconfigured_session(
        &mut command,
        Duration::from_secs(UID_ADMISSION_SECONDS),
        1_048_576,
        "bounded exact-v6 read-only admission",
    )?;
    if !output.status.success() {
        return Err(format!(
            "bounded exact-v6 admission failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

fn root_spawn_uid_proxy() -> Result<(OwnedSessionChild, UnixStream, String), String> {
    if unsafe { libc_geteuid() } != 0 {
        return Err("only the detached root broker may spawn the UID proxy".to_owned());
    }
    let (root_capability, child_capability) = UnixStream::pair()
        .map_err(|error| format!("could not create UID-proxy root capability: {error}"))?;
    let child_capability_fd = child_capability.into_raw_fd();
    let mut command = Command::new(SEALED_CONTROLLER);
    command
        .arg(UID_GUARDIAN_MODE)
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .current_dir("/")
        .stdin(unsafe { Stdio::from_raw_fd(child_capability_fd) })
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc_setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc_setgroups(AHMED_GROUPS.len() as i32, AHMED_GROUPS.as_ptr()) != 0
                || libc_setgid(20) != 0
                || libc_setuid(501) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command
        .spawn()
        .map_err(|error| format!("could not launch root-owned UID proxy: {error}"))?;
    let mut child = OwnedSessionChild::new(child, "root-owned UID proxy");
    let pid = child.id();
    let deadline = Instant::now() + Duration::from_secs(60);
    let cleanup_deadline = deadline + Duration::from_secs(CANDIDATE_STOP_PRIMITIVE_SECONDS);
    while Instant::now() < deadline {
        match retained_child_exited_without_reap(&child) {
            Ok(true) => {
                let cleanup =
                    terminate_preconfigured_session(&mut child, pid, "root-owned UID proxy", cleanup_deadline);
                return Err(format!(
                    "root-owned UID proxy exited before binding; cleanup={cleanup:?}"
                ));
            }
            Ok(false) => {}
            Err(error) => {
                let cleanup =
                    terminate_preconfigured_session(&mut child, pid, "root-owned UID proxy", cleanup_deadline);
                return Err(format!(
                    "root-owned UID proxy nonreaping proof failed: {error}; cleanup={cleanup:?}"
                ));
            }
        }
        if unsafe { libc_getpgid(pid as i32) } == pid as i32
            && unsafe { libc_getsid(pid as i32) } == pid as i32
            && verify_root_sealed_controller_process(pid).is_ok()
        {
            match process_start_identity(pid) {
                Ok(start) => return Ok((child, root_capability, start)),
                Err(_) if Instant::now() < deadline => {}
                Err(error) => {
                    let cleanup = terminate_preconfigured_session(
                        &mut child,
                        pid,
                        "root-owned UID proxy",
                        cleanup_deadline,
                    );
                    return Err(format!(
                        "root-owned UID proxy start identity failed: {error}; cleanup={cleanup:?}"
                    ));
                }
            }
        }
        sleep_capped_by_absolute_deadline(deadline, Duration::from_millis(50));
    }
    let cleanup = terminate_preconfigured_session(
        &mut child,
        pid,
        "root-owned UID proxy",
        cleanup_deadline,
    );
    Err(format!(
        "root-owned UID proxy did not establish its exact session; cleanup={cleanup:?}"
    ))
}

fn root_publish_proxy_identity(pid: u32, start: &str) -> Result<(), String> {
    if start.len() < 20 || start.contains(['\n', '\r', '\0']) {
        return Err("root-owned UID proxy start identity is malformed".to_owned());
    }
    let path = Path::new(ROOT_PROXY_IDENTITY);
    require_absent_no_follow(path, "root-owned UID proxy identity")?;
    let mut record = root_create_private(path)?;
    writeln!(record, "schema=opensteamer.local-mono-root-proxy.v1")
        .and_then(|_| writeln!(record, "proxy_pid={pid}"))
        .and_then(|_| writeln!(record, "proxy_start={start}"))
        .map_err(|error| error.to_string())?;
    record.sync_all().map_err(|error| error.to_string())?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o444))
        .map_err(|error| error.to_string())?;
    require_root_regular(path, 0o444)
}

fn read_root_proxy_identity() -> Result<(u32, String), String> {
    let text = read_bounded_utf8(Path::new(ROOT_PROXY_IDENTITY), 512, 0, 0o444)?;
    let lines = text.lines().collect::<Vec<_>>();
    if lines.len() != 3 || lines[0] != "schema=opensteamer.local-mono-root-proxy.v1" {
        return Err("root-owned UID proxy identity record is malformed".to_owned());
    }
    let pid = lines[1]
        .strip_prefix("proxy_pid=")
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|value| *value > 0)
        .ok_or("root-owned UID proxy PID is malformed")?;
    let start = lines[2]
        .strip_prefix("proxy_start=")
        .filter(|value| value.len() >= 20 && !value.contains(['\n', '\r', '\0']))
        .ok_or("root-owned UID proxy start identity is malformed")?;
    Ok((pid, start.to_owned()))
}

fn root_spawn_candidate_gate() -> Result<(OwnedSessionChild, UnixStream, String), String> {
    if unsafe { libc_geteuid() } != 0 {
        return Err("only the detached root broker may spawn the candidate gate".to_owned());
    }
    let (root_control, child_capability) = UnixStream::pair()
        .map_err(|error| format!("could not create candidate-gate root channel: {error}"))?;
    root_control
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| error.to_string())?;
    let child_capability_fd = child_capability.into_raw_fd();
    let mut command = Command::new(SEALED_CONTROLLER);
    command
        .arg(UID_CANDIDATE_GATE_MODE)
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .current_dir("/")
        .stdin(unsafe { Stdio::from_raw_fd(child_capability_fd) })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(|| {
            if libc_setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc_setgroups(AHMED_GROUPS.len() as i32, AHMED_GROUPS.as_ptr()) != 0
                || libc_setgid(20) != 0
                || libc_setuid(501) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command
        .spawn()
        .map_err(|error| format!("could not launch root-owned candidate gate: {error}"))?;
    let mut child = OwnedSessionChild::new(child, "root-owned candidate gate");
    let pid = child.id();
    let cleanup_deadline =
        Instant::now() + Duration::from_secs(ROOT_GATE_RESPONSE_SECONDS);
    let stdout = match child.stdout.take() {
        Some(value) => value,
        None => {
            let cleanup = terminate_preconfigured_session(
                &mut child,
                pid,
                "root-owned candidate gate",
                cleanup_deadline,
            );
            return Err(format!("candidate gate stdout unavailable; cleanup={cleanup:?}"));
        }
    };
    let stderr = match child.stderr.take() {
        Some(value) => value,
        None => {
            drop(root_control);
            let cleanup = terminate_preconfigured_session(
                &mut child,
                pid,
                "root-owned candidate gate",
                cleanup_deadline,
            );
            return Err(format!("candidate gate stderr unavailable; cleanup={cleanup:?}"));
        }
    };
    let lines = spawn_line_reader(stdout, 80, "root-owned candidate gate response");
    let stderr_receiver = spawn_bounded_byte_reader(
        stderr,
        16_384,
        "root-owned candidate gate stderr",
    );
    let root_bound = lines.recv_timeout(Duration::from_secs(60));
    match root_bound {
        Ok(Ok(line)) if line == "LOCAL_CANDIDATE_GATE_ROOT_BOUND" => {}
        other => {
            drop(root_control);
            return Err(candidate_gate_failure_diagnostic(
                &mut child,
                pid,
                stderr_receiver,
                "failed before root-bound marker",
                &format!("{other:?}"),
                cleanup_deadline,
            ));
        }
    }
    let ready = lines.recv_timeout(Duration::from_secs(ROOT_GATE_RESPONSE_SECONDS - 120));
    match ready {
        Ok(Ok(line)) if line == "LOCAL_CANDIDATE_GATE_READY" => {}
        other => {
            drop(root_control);
            return Err(candidate_gate_failure_diagnostic(
                &mut child,
                pid,
                stderr_receiver,
                "failed after root binding but before readiness",
                &format!("{other:?}"),
                cleanup_deadline,
            ));
        }
    }
    let (start, phase) = match verify_root_candidate_or_gate(pid) {
        Ok(value) => value,
        Err(error) => {
            drop(root_control);
            return Err(candidate_gate_failure_diagnostic(
                &mut child,
                pid,
                stderr_receiver,
                "failed exact post-readiness identity proof",
                &error,
                cleanup_deadline,
            ));
        }
    };
    if phase != CandidatePhase::DormantGate {
        drop(root_control);
        let cleanup = terminate_preconfigured_session(
            &mut child,
            pid,
            "root-owned candidate gate",
            cleanup_deadline,
        );
        return Err(format!("candidate gate was not dormant; cleanup={cleanup:?}"));
    }
    Ok((child, root_control, start))
}

fn root_release_candidate_gate(state: &mut RootBrokerState) -> Result<u32, String> {
    let (pid, expected_start) = state
        .candidate
        .clone()
        .ok_or("root-owned candidate gate is absent")?;
    verify_bound_dormant_candidate_gate(state.candidate.as_ref())?;
    let mut control = state
        .candidate_control
        .take()
        .ok_or("root-owned candidate gate channel is absent")?;
    writeln!(control, "GO_LOCAL_CANDIDATE_PREP_L1CIAB")
        .and_then(|_| control.flush())
        .map_err(|error| format!("could not release root-owned candidate gate: {error}"))?;
    drop(control);
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match verify_root_candidate(pid) {
            Ok(start) if start == expected_start => break,
            Ok(_) => return Err("candidate start identity changed across gate exec".to_owned()),
            Err(_) if Instant::now() < deadline => {
                let child = state
                    .candidate_child
                    .as_ref()
                    .ok_or("root-owned candidate Child was lost during gate exec")?;
                if child.id() != pid || retained_child_exited_without_reap(child)? {
                    return Err("candidate gate exited before sealed-host exec".to_owned());
                }
                verify_tracked_candidate_identity(pid, &expected_start)?;
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => {
                return Err(format!("candidate gate did not exec the sealed host: {error}"))
            }
        }
    }
    run_uid_sealed(UID_VERIFY_CANDIDATE_MODE, Some(&pid.to_string()))?;
    Ok(pid)
}

fn run_exact_sealed_guardian(arguments: &[&str]) -> Result<Output, String> {
    require_root_regular(Path::new(SEALED_GUARDIAN), 0o555)?;
    require_hash(Path::new(SEALED_GUARDIAN), ROUTE_GUARDIAN_SHA256)?;
    bounded_output(
        Command::new(SEALED_GUARDIAN)
            .args(arguments)
            .env_clear()
            .env("LC_ALL", "C")
            .env("HOME", "/Users/ahmed")
            .env("USER", "ahmed")
            .env("LOGNAME", "ahmed")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        Duration::from_secs(20),
        1_048_576,
        "exact sealed default-route guardian",
    )
}

fn verify_product_hal_absent_body() -> Result<(), String> {
    let output = run_exact_sealed_guardian(&["verify-product-absent"])?;
    if !output.status.success()
        || output.stdout != b"PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE\n"
        || !output.stderr.is_empty()
    {
        return Err(format!(
            "public HAL absence proof failed: status={:?} stdout={} stderr={}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}


fn uid_verify_product_hal_absent() -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    configure_imported_command_limit_for_mode(UID_VERIFY_HAL_MODE, true)?;
    verify_product_hal_absent_body()
}

fn uid_verify_exact_v6_admission() -> Result<(), String> {
    verify_sealed_uid_controller_identity()?;
    configure_imported_command_limit_for_mode(UID_ADMISSION_MODE, false)?;
    v7_controller::paired_v7::local_trial_verify_exact_v6_admission()?;
    require_healthy_admission_imported_count()
}

fn uid_emergency_route_repair(expected_state_hash: &str) -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    configure_imported_command_limit_for_mode(UID_EMERGENCY_REPAIR_MODE, true)?;
    if expected_state_hash.len() != 64
        || !expected_state_hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || fixed_guardian_state_hash()?.as_deref() != Some(expected_state_hash)
    {
        return Err("sealed route repair rejected its state hash".to_owned());
    }
    let layout = TrialLayout::fixed();
    require_absent_no_follow(
        &layout.guardian_emergency_repair_result,
        "published emergency route-repair result",
    )?;
    require_absent_no_follow(
        &layout.guardian_emergency_repair_attempt_result,
        "emergency route-repair attempt result",
    )?;
    let state = layout.guardian_state.to_str().ok_or("non-UTF-8 guardian state")?;
    let result = layout
        .guardian_emergency_repair_attempt_result
        .to_str()
        .ok_or("non-UTF-8 guardian repair attempt result")?;
    let output = run_exact_sealed_guardian(&[
        "repair",
        "--state",
        state,
        "--expected-state-sha256",
        expected_state_hash,
        "--result",
        result,
    ])?;
    if !output.status.success() || !output.stdout.is_empty() || !output.stderr.is_empty() {
        return Err(format!(
            "sealed route repair failed: status={:?} stderr={}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    verify_guardian_evidence(
        &layout.guardian_emergency_repair_attempt_result,
        "repair",
        true,
        false,
    )?;
    Ok(())
}

fn uid_emergency_restore_v6() -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    configure_imported_command_limit_for_mode(UID_EMERGENCY_V6_MODE, true)?;
    verify_product_hal_absent_body()?;
    v7_controller::paired_v7::local_trial_bootstrap_and_verify_exact_v6()
}

fn uid_stop_exact_v6() -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    configure_imported_command_limit_for_mode(UID_STOP_V6_MODE, true)?;
    v7_controller::paired_v7::local_trial_stop_exact_v6()
}

fn uid_verify_candidate_ready(pid_text: &str) -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    configure_imported_command_limit_for_mode(UID_VERIFY_CANDIDATE_MODE, true)?;
    let pid = pid_text
        .parse::<u32>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or("candidate readiness PID is malformed")?;
    v7_controller::paired_v7::local_trial_verify_candidate_generation(
        pid,
        Path::new(SEALED_HOST_EXECUTABLE),
    )
    .map(|_| ())
}

fn fixed_guardian_state_hash() -> Result<Option<String>, String> {
    match fs::symlink_metadata(&TrialLayout::fixed().guardian_state) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("could not inspect guardian state: {error}")),
        Ok(_) => stable_private_sha256(&TrialLayout::fixed().guardian_state).map(Some),
    }
}

fn bind_guardian_state_hash_for_recovery(
    state: &mut RootBrokerState,
    deadline: Instant,
) -> Result<Option<String>, String> {
    let observed = match fs::symlink_metadata(&TrialLayout::fixed().guardian_state) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(format!("could not inspect guardian recovery state: {error}")),
        Ok(_) => Some(stable_private_sha256_until(
            &TrialLayout::fixed().guardian_state,
            deadline,
        )?),
    };
    match (&state.guardian_hash, observed) {
        (Some(expected), Some(observed)) if *expected == observed => Ok(Some(observed)),
        (Some(_), _) => Err("capability-bound guardian state hash changed".to_owned()),
        (None, None) => Ok(None),
        (None, Some(observed)) => {
            verify_guardian_evidence_until(
                &TrialLayout::fixed().guardian_snapshot_result,
                "broker-snapshot",
                false,
                true,
                deadline,
            )?;
            if Instant::now() >= deadline {
                return Err("guardian recovery state bind exhausted its deadline".to_owned());
            }
            state.guardian_hash = Some(observed.clone());
            root_append_state(&format!(
                "GUARDIAN_STATE_RECOVERY_BOUND sha256={observed}"
            ))?;
            if Instant::now() >= deadline {
                return Err("guardian recovery state journal exceeded its deadline".to_owned());
            }
            Ok(Some(observed))
        }
    }
}

fn require_no_guardian_route_artifacts_without_state() -> Result<(), String> {
    let layout = TrialLayout::fixed();
    for (path, label) in [
        (&layout.guardian_snapshot_result, "guardian snapshot without state"),
        (&layout.guardian_fence_result, "guardian fence without state"),
        (
            &layout.guardian_post_publish_fence_result,
            "guardian post-publish fence without state",
        ),
        (&layout.guardian_run_result, "guardian run result without state"),
        (&layout.guardian_repair_result, "guardian repair result without state"),
        (&layout.guardian_final_result, "guardian final result without state"),
        (
            &layout.guardian_emergency_repair_result,
            "published emergency guardian repair without state",
        ),
        (
            &layout.guardian_emergency_repair_attempt_result,
            "emergency guardian repair attempt without state",
        ),
    ] {
        require_absent_no_follow(path, label)?;
    }
    Ok(())
}

#[derive(Debug)]
struct RootBrokerState {
    hold: NodeIdentity,
    runtime_lock: Option<SharedLockGuard>,
    proxy_child: Option<OwnedSessionChild>,
    proxy_capability: Option<UnixStream>,
    proxy_start: Option<String>,
    proxy_connected: bool,
    user_evidence_armed: bool,
    v6_stop_may_have_begun: bool,
    v6_stopped: bool,
    v6_restore_may_have_begun: bool,
    publication_requested: bool,
    guardian_hash: Option<String>,
    guardian: Option<(u32, String)>,
    guardian_generation: Option<SessionMemberIdentity>,
    guardian_reaped_authenticated: bool,
    prestop_fenced: bool,
    postpublish_fence_hash: Option<String>,
    postpublish_fenced: bool,
    probes_verified: bool,
    candidate: Option<(u32, String)>,
    candidate_child: Option<OwnedSessionChild>,
    candidate_control: Option<UnixStream>,
    candidate_live: bool,
    candidate_stopped: bool,
    routes_repaired: bool,
    driver_restored: bool,
    v6_restored: bool,
    evidence_finalized: bool,
    recovery_complete: bool,
}

impl Drop for RootBrokerState {
    fn drop(&mut self) {
        // Explicit protocol/emergency paths must normally clear these owners. This destructor is
        // the final fail-closed backstop. In incomplete state it must not close either retained
        // Child or the proxy capability before the accumulator has used them to quiesce the
        // candidate, proxy, and any capability-bound guardian SID.
        if self.recovery_complete {
            return;
        }
        // Never let an incomplete physical recovery fall out of ownership merely because one
        // reviewed emergency window ended. Each pass has its own hard bound and retains this
        // state's lock/identity capabilities; a later guardian exit or partial-v6 convergence
        // therefore re-enters the accumulator instead of silently closing the final guard.
        loop {
            let pass_deadline =
                Instant::now() + Duration::from_secs(EMERGENCY_CLEANUP_ABSOLUTE_SECONDS);
            let _ = root_emergency_cleanup(self, pass_deadline);
            if self.recovery_complete {
                return;
            }
            thread::sleep(Duration::from_secs(1));
        }
    }
}

fn recovery_may_finalize_user_evidence(
    accepted_or_exactly_armed: bool,
    proxy_scope_authenticated: bool,
    candidate_quiescent: bool,
    routes_repaired: bool,
    driver_restored: bool,
    v6_restored: bool,
    runtime_lock_released: bool,
) -> bool {
    accepted_or_exactly_armed
        && proxy_scope_authenticated
        && candidate_quiescent
        && routes_repaired
        && driver_restored
        && v6_restored
        && runtime_lock_released
}

fn candidate_absence_barrier_model(
    capture_server_absent: bool,
    shared_lock_unowned: bool,
    v6_already_restored: bool,
) -> bool {
    v6_already_restored || (capture_server_absent && shared_lock_unowned)
}

fn candidate_stop_guard_retry_model(
    session_quiescent: bool,
    first_guard_succeeds: bool,
    second_guard_succeeds: bool,
) -> bool {
    let candidate_stopped = session_quiescent;
    (candidate_stopped && first_guard_succeeds)
        || (candidate_stopped && second_guard_succeeds)
}

fn guardian_fallback_quiescence_model(
    leader_absent: bool,
    pid_reused: bool,
    first_sid_scan_empty: bool,
    second_sid_scan_empty: bool,
) -> bool {
    leader_absent && !pid_reused && first_sid_scan_empty && second_sid_scan_empty
}

fn unbound_guardian_generations(
    deadline: Instant,
) -> Result<Vec<SessionMemberIdentity>, String> {
    if unsafe { libc_geteuid() } != 0 || Instant::now() >= deadline {
        return Err("unbound guardian scan lacks root authority/deadline".to_owned());
    }
    let mut storage = vec![0_i32; 131_072];
    let byte_count = storage
        .len()
        .checked_mul(std::mem::size_of::<i32>())
        .and_then(|value| i32::try_from(value).ok())
        .ok_or("unbound guardian process-list buffer overflowed")?;
    let count = unsafe { libc_proc_listallpids(storage.as_mut_ptr().cast(), byte_count) };
    if count <= 0 || count as usize >= storage.len() {
        return Err("could not enumerate a complete process list for unbound guardian proof".to_owned());
    }
    let mut guardians = Vec::new();
    for raw_pid in storage.into_iter().take(count as usize).filter(|pid| *pid > 1) {
        if Instant::now() >= deadline {
            return Err("unbound guardian scan exhausted its deadline".to_owned());
        }
        let pid = raw_pid as u32;
        let Some(first) = process_bsd_identity(pid)? else {
            continue;
        };
        if first.uid != 501 {
            continue;
        }
        let path = match process_executable_path(pid) {
            Ok(value) => value,
            Err(error) => {
                if process_bsd_identity(pid)?.is_none() {
                    continue;
                }
                return Err(format!(
                    "could not classify live UID501 PID {pid} during unbound guardian proof: {error}"
                ));
            }
        };
        let is_guardian = path == Path::new(SEALED_GUARDIAN);
        let is_vpio_child = path == Path::new(SEALED_VPIO_PROBE);
        if !is_guardian && !is_vpio_child {
            continue;
        }
        let second = process_bsd_identity(pid)?
            .ok_or("sealed guardian-scope generation disappeared during unbound proof")?;
        if first != second
            || !(1..=5).contains(&second.status)
            || process_executable_path(pid)? != path
        {
            return Err("unbound sealed guardian scope changed identity during proof".to_owned());
        }
        if is_guardian
            && (second.pgid != pid || getsid_exact_or_absent(pid)? != Some(pid))
        {
            return Err("unbound sealed guardian changed its exact leader/session".to_owned());
        }
        if is_vpio_child && getsid_exact_or_absent(pid)?.is_none() {
            return Err("unbound sealed VPIO child lost its session during proof".to_owned());
        }
        guardians.push(second);
    }
    guardians.sort_unstable_by_key(|value| value.pid);
    guardians.dedup_by_key(|value| value.pid);
    Ok(guardians)
}

fn wait_for_unbound_guardian_absence(deadline: Instant) -> Result<(), String> {
    require_hash_until(
        Path::new(SEALED_GUARDIAN),
        ROUTE_GUARDIAN_SHA256,
        deadline,
    )?;
    require_hash_until(
        Path::new(SEALED_VPIO_PROBE),
        VPIO_PROBE_SHA256,
        deadline,
    )?;
    let mut consecutive_empty_scans = 0_u8;
    loop {
        if unbound_guardian_generations(deadline)?.is_empty() {
            consecutive_empty_scans += 1;
            if consecutive_empty_scans >= 2 {
                return Ok(());
            }
        } else {
            consecutive_empty_scans = 0;
        }
        if Instant::now() >= deadline {
            return Err("unbound sealed guardian/VPIO scope remained after proxy quiescence".to_owned());
        }
        sleep_capped_by_absolute_deadline(deadline, Duration::from_millis(50));
    }
}

fn wait_for_tracked_guardian_generation_absence(
    state: &RootBrokerState,
    caller_deadline: Instant,
) -> Result<(), String> {
    let expected = state
        .guardian_generation
        .ok_or("tracked guardian generation is absent")?;
    let tracked_pid = state
        .guardian
        .as_ref()
        .map(|value| value.0)
        .ok_or("tracked guardian PID is absent")?;
    if expected.pid != tracked_pid || expected.pgid != tracked_pid || expected.uid != 501 {
        return Err("tracked guardian generation was never its exact UID501 session leader".to_owned());
    }
    let mut consecutive_empty_session_scans = 0_u8;
    loop {
        match process_bsd_identity(tracked_pid)? {
            None => {
                let members = session_member_identities(tracked_pid, caller_deadline)?;
                match process_bsd_identity(tracked_pid)? {
                    None => {}
                    Some(observed) if observed != expected => {
                        return Err(
                            "tracked guardian PID was reused before its SID became quiescent"
                                .to_owned(),
                        )
                    }
                    Some(_) => {
                        consecutive_empty_session_scans = 0;
                        continue;
                    }
                }
                if members.is_empty() {
                    consecutive_empty_session_scans += 1;
                    if consecutive_empty_session_scans >= 2 {
                        return Ok(());
                    }
                } else {
                    consecutive_empty_session_scans = 0;
                }
            }
            Some(observed) if observed != expected => {
                return Err(
                    "tracked guardian PID was reused before exact generation absence".to_owned(),
                )
            }
            Some(observed) if (1..=5).contains(&observed.status) => {
                consecutive_empty_session_scans = 0;
            }
            Some(observed) => {
                return Err(format!(
                    "tracked guardian has unreviewed BSD status {}",
                    observed.status
                ))
            }
        }
        if Instant::now() >= caller_deadline {
            return Err(
                "tracked guardian generation/SID remained after proxy quiescence".to_owned(),
            );
        }
        sleep_capped_by_absolute_deadline(caller_deadline, Duration::from_millis(50));
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct GuardianRepairAttemptSnapshot {
    device: u64,
    inode: u64,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

fn inspect_safe_guardian_repair_attempt(
    path: &Path,
) -> Result<GuardianRepairAttemptSnapshot, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect guardian repair attempt: {error}"))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.gid() != 20
        || metadata.nlink() != 1
        || metadata.mode() & 0o7777 != 0o600
        || metadata.len() > 1_048_576
    {
        return Err("guardian repair attempt metadata is unsafe".to_owned());
    }
    Ok(GuardianRepairAttemptSnapshot {
        device: metadata.dev(),
        inode: metadata.ino(),
        length: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
    })
}

fn stable_guardian_repair_attempt_until(
    path: &Path,
    deadline: Instant,
) -> Result<(GuardianRepairAttemptSnapshot, String), String> {
    let before = inspect_safe_guardian_repair_attempt(path)?;
    let digest = sha256_until(
        path,
        deadline,
        GUARDIAN_EVIDENCE_HASH_SECONDS,
        "deadline-aware guardian repair attempt hash",
    )?;
    let after = inspect_safe_guardian_repair_attempt(path)?;
    if Instant::now() >= deadline || before != after {
        return Err("guardian repair attempt changed during validation".to_owned());
    }
    Ok((before, digest))
}

fn journal_and_clear_rejected_guardian_repair_attempt_until(
    attempt: &Path,
    deadline: Instant,
) -> Result<String, String> {
    let (before, digest) = stable_guardian_repair_attempt_until(attempt, deadline)?;
    root_append_state(&format!(
        "EMERGENCY_ROUTE_REPAIR_ATTEMPT_REJECTED sha256={digest} bytes={} inode={}",
        before.length, before.inode
    ))?;
    let (after, repeated_digest) = stable_guardian_repair_attempt_until(attempt, deadline)?;
    if Instant::now() >= deadline || before != after || digest != repeated_digest {
        return Err("guardian repair attempt changed after its durable rejection journal".to_owned());
    }
    fs::remove_file(attempt)
        .map_err(|error| format!("could not unlink rejected guardian repair attempt: {error}"))?;
    sync_parent_directory(attempt)?;
    require_absent_no_follow(attempt, "rejected guardian repair attempt after unlink")?;
    Ok(digest)
}

fn publish_successful_guardian_repair_attempt_until(
    attempt: &Path,
    result: &Path,
    deadline: Instant,
) -> Result<String, String> {
    require_absent_no_follow(result, "published emergency route-repair result")?;
    let before = inspect_safe_guardian_repair_attempt(attempt)?;
    let initial_hash = verify_guardian_evidence_until(
        attempt,
        "repair",
        true,
        false,
        deadline,
    )?;
    if Instant::now() >= deadline || inspect_safe_guardian_repair_attempt(attempt)? != before {
        return Err("successful guardian repair attempt changed before publication".to_owned());
    }
    rename_exclusive(attempt, result)?;
    sync_parent_directory(result)?;
    require_absent_no_follow(attempt, "guardian repair attempt after publication")?;
    if inspect_safe_guardian_repair_attempt(result)? != before {
        return Err("published guardian repair result changed identity".to_owned());
    }
    let published_hash = verify_guardian_evidence_until(
        result,
        "repair",
        true,
        false,
        deadline,
    )?;
    if Instant::now() >= deadline
        || published_hash != initial_hash
        || inspect_safe_guardian_repair_attempt(result)? != before
    {
        return Err("published guardian repair result changed during final proof".to_owned());
    }
    Ok(published_hash)
}

#[derive(Debug, Eq, PartialEq)]
enum GuardianRepairArtifactState {
    Absent,
    Published(String),
    RejectedAttemptCleared { success_error: String, digest: String },
}

fn reconcile_guardian_repair_artifacts_until(
    layout: &TrialLayout,
    deadline: Instant,
) -> Result<GuardianRepairArtifactState, String> {
    let result = &layout.guardian_emergency_repair_result;
    let attempt = &layout.guardian_emergency_repair_attempt_result;
    match fs::symlink_metadata(result) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "could not inspect published emergency route-repair result: {error}"
            ))
        }
        Ok(_) => {
            require_absent_no_follow(attempt, "attempt beside published guardian repair result")?;
            sync_parent_directory(result)?;
            return verify_guardian_evidence_until(result, "repair", true, false, deadline)
                .map(GuardianRepairArtifactState::Published);
        }
    }
    match fs::symlink_metadata(attempt) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(GuardianRepairArtifactState::Absent)
        }
        Err(error) => Err(format!(
            "could not inspect emergency route-repair attempt: {error}"
        )),
        Ok(_) => {
            match publish_successful_guardian_repair_attempt_until(attempt, result, deadline) {
                Ok(hash) => Ok(GuardianRepairArtifactState::Published(hash)),
                Err(success_error) => {
                    // A post-rename fsync/proof error is recoverable only through the exact
                    // success-only canonical result. Never unlink an ambiguous canonical node.
                    match fs::symlink_metadata(result) {
                        Ok(_) => {
                            require_absent_no_follow(
                                attempt,
                                "attempt beside recovered published guardian repair result",
                            )?;
                            sync_parent_directory(result)?;
                            verify_guardian_evidence_until(
                                result,
                                "repair",
                                true,
                                false,
                                deadline,
                            )
                            .map(GuardianRepairArtifactState::Published)
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                            let digest = journal_and_clear_rejected_guardian_repair_attempt_until(
                                attempt, deadline,
                            )?;
                            Ok(GuardianRepairArtifactState::RejectedAttemptCleared {
                                success_error,
                                digest,
                            })
                        }
                        Err(error) => Err(format!(
                            "could not inspect canonical result after failed publication: {error}"
                        )),
                    }
                }
            }
        }
    }
}

fn root_resume_or_run_emergency_route_repair(
    expected_state_hash: &str,
    deadline: Instant,
) -> Result<(), String> {
    let route_recovery_started = Instant::now();
    if deadline.saturating_duration_since(route_recovery_started)
        < Duration::from_secs(GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS)
    {
        return Err("emergency route recovery lacks its full primitive deadline".to_owned());
    }
    let route_recovery_deadline = std::cmp::min(
        deadline,
        route_recovery_started
            + Duration::from_secs(GUARDIAN_REPAIR_EXECUTION_PRIMITIVE_SECONDS),
    );
    let helper_deadline = route_recovery_deadline
        .checked_sub(Duration::from_secs(
            GUARDIAN_REPAIR_REPROOF_RESERVE_SECONDS,
        ))
        .ok_or("emergency route repair cannot reserve its evidence reproof")?;
    let evidence_deadline = route_recovery_deadline
        .checked_sub(Duration::from_secs(GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS))
        .ok_or("emergency route repair cannot reserve its final state hash")?;
    if stable_private_sha256_until(&TrialLayout::fixed().guardian_state, helper_deadline)?
        != expected_state_hash
    {
        return Err("guardian state changed before resumable emergency route repair".to_owned());
    }
    let layout = TrialLayout::fixed();
    let initial_artifacts = reconcile_guardian_repair_artifacts_until(&layout, helper_deadline)?;
    let existing_success = match initial_artifacts {
        GuardianRepairArtifactState::Published(hash) => Some(hash),
        GuardianRepairArtifactState::Absent => None,
        GuardianRepairArtifactState::RejectedAttemptCleared {
            success_error,
            digest,
        } => {
            let _ = root_append_state(&format!(
                "EMERGENCY_ROUTE_REPAIR_RETRY_AFTER_REJECTED_ATTEMPT sha256={digest} reason={}",
                success_error
                    .replace(['\n', '\r', '\0'], " ")
                    .chars()
                    .take(96)
                    .collect::<String>()
            ));
            None
        }
    };
    if existing_success.is_none()
        && helper_deadline.saturating_duration_since(Instant::now())
            < Duration::from_secs(
                UID_ROUTE_REPAIR_HELPER_SECONDS + UID_SEALED_TEARDOWN_RESERVE_SECONDS,
            )
    {
        return Err("emergency route repair preflight consumed its helper deadline reserve".to_owned());
    }
    let operation = existing_success.is_none().then(|| {
        run_uid_sealed_until(
            UID_EMERGENCY_REPAIR_MODE,
            Some(expected_state_hash),
            helper_deadline,
        )
    });
    let proof = match existing_success {
        Some(hash) => Ok(hash),
        None => match reconcile_guardian_repair_artifacts_until(&layout, evidence_deadline) {
            Ok(GuardianRepairArtifactState::Published(hash)) => Ok(hash),
            Ok(GuardianRepairArtifactState::Absent) => {
                Err("emergency route repair produced no attempt evidence".to_owned())
            }
            Ok(GuardianRepairArtifactState::RejectedAttemptCleared {
                success_error,
                digest,
            }) => Err(format!(
                "emergency route repair attempt was safely rejected and cleared for retry: sha256={digest}; success={success_error}"
            )),
            Err(error) => Err(error),
        },
    };
    if stable_private_sha256_until(&layout.guardian_state, route_recovery_deadline)?
        != expected_state_hash
    {
        return Err("guardian state changed during resumable emergency route repair".to_owned());
    }
    match (operation, proof) {
        (None, Ok(_)) | (Some(Ok(())), Ok(_)) => Ok(()),
        (Some(Err(operation_error)), Ok(_)) => {
            let _ = root_append_state(&format!(
                "EMERGENCY_ROUTE_REPAIR_OPERATION_ERROR_RECOVERED_BY_EVIDENCE {}",
                operation_error
                    .replace(['\n', '\r', '\0'], " ")
                    .chars()
                    .take(256)
                    .collect::<String>()
            ));
            Ok(())
        }
        (None, Err(proof_error)) => Err(format!(
            "existing emergency route-repair result is not exact: {proof_error}"
        )),
        (Some(Ok(())), Err(proof_error)) => Err(format!(
            "emergency route repair returned success without exact evidence: {proof_error}"
        )),
        (Some(Err(operation_error)), Err(proof_error)) => Err(format!(
            "emergency route repair failed: {operation_error}; evidence={proof_error}"
        )),
    }
}

fn receive_guardian_spawned_capability_marker(
    state: &mut RootBrokerState,
    absolute_deadline: Instant,
) -> Result<(), String> {
    if state.guardian.is_some()
        || state.guardian_generation.is_some()
        || state.guardian_hash.is_some()
        || state.v6_stop_may_have_begun
    {
        return Err("guardian spawn capability arrived out of sequence".to_owned());
    }
    let deadline = std::cmp::min(
        absolute_deadline,
        Instant::now() + Duration::from_secs(ROOT_GUARDIAN_BIND_RESPONSE_SECONDS),
    );
    let capability = state
        .proxy_capability
        .as_mut()
        .ok_or("guardian spawn capability channel is absent")?;
    let mut bytes = Vec::new();
    loop {
        if bytes.len() > 80 {
            return Err("guardian spawn capability marker exceeded its bound".to_owned());
        }
        let timeout = remaining_phase_timeout(
            deadline,
            Duration::from_secs(15),
            "guardian spawn capability marker",
        )?;
        capability
            .set_read_timeout(Some(timeout))
            .map_err(|error| error.to_string())?;
        let mut byte = [0_u8; 1];
        match capability.read(&mut byte) {
            Ok(0) => return Err("guardian spawn capability closed before its marker".to_owned()),
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) if matches!(byte[0], b'\r' | 0) => {
                return Err("guardian spawn capability marker contains a forbidden byte".to_owned())
            }
            Ok(_) => bytes.push(byte[0]),
            Err(error) => return Err(format!("guardian spawn capability read failed: {error}")),
        }
    }
    let text = String::from_utf8(bytes)
        .map_err(|_| "guardian spawn capability marker is not UTF-8")?;
    let pid = text
        .strip_prefix("L1Ciab GUARDIAN_SPAWNED ")
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|value| *value > 1 && *value <= i32::MAX as u32)
        .ok_or("guardian spawn capability marker is malformed")?;
    let start = verify_root_guardian_process(pid)?;
    let generation = process_bsd_identity(pid)?
        .filter(|value| {
            value.uid == 501
                && value.pgid == pid
                && (1..=4).contains(&value.status)
        })
        .ok_or("spawned guardian libproc generation is not an exact live UID501 leader")?;
    if Instant::now() >= deadline || unsafe { libc_getsid(pid as i32) } != pid as i32 {
        return Err("spawned guardian is not its exact live session before binding".to_owned());
    }
    // Store the authenticated pending generation before any journal or state/evidence proof can
    // fail. Every later proxy/emergency path must now prove this exact SID quiescent.
    state.guardian = Some((pid, start));
    state.guardian_generation = Some(generation);
    root_append_state(&format!(
        "GUARDIAN_SPAWN_CAPABILITY_AUTHENTICATED pid={pid}"
    ))?;
    Ok(())
}

fn receive_guardian_reaped_capability_marker(
    state: &mut RootBrokerState,
    deadline: Instant,
) -> Result<(), String> {
    if state.guardian_reaped_authenticated || state.guardian.is_none() {
        return Ok(());
    }
    let expected_pid = state
        .guardian
        .as_ref()
        .map(|value| value.0)
        .ok_or("guardian reap capability marker has no bound guardian")?;
    let capability = state
        .proxy_capability
        .as_mut()
        .ok_or("guardian reap capability channel is absent")?;
    let mut bytes = Vec::new();
    loop {
        if bytes.len() > 160 {
            return Err("guardian reap capability marker exceeded its bound".to_owned());
        }
        let timeout = remaining_phase_timeout(
            deadline,
            Duration::from_secs(15),
            "guardian reap capability marker",
        )?;
        capability
            .set_read_timeout(Some(timeout))
            .map_err(|error| error.to_string())?;
        let mut byte = [0_u8; 1];
        match capability.read(&mut byte) {
            Ok(0) => return Err("guardian reap capability closed before its marker".to_owned()),
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) if matches!(byte[0], b'\r' | 0) => {
                return Err("guardian reap capability marker contains a forbidden byte".to_owned())
            }
            Ok(_) => bytes.push(byte[0]),
            Err(error) => return Err(format!("guardian reap capability read failed: {error}")),
        }
    }
    let expected = format!("L1Ciab GUARDIAN_REAPED {expected_pid}");
    if bytes != expected.as_bytes() {
        return Err("guardian reap capability marker changed identity".to_owned());
    }
    verify_guardian_evidence_until(
        &TrialLayout::fixed().guardian_final_result,
        "broker-final",
        true,
        false,
        deadline,
    )?;
    if Instant::now() >= deadline {
        return Err("guardian reap capability expired before authentication".to_owned());
    }
    state.guardian_reaped_authenticated = true;
    if let Err(error) = root_append_state(&format!(
        "GUARDIAN_REAPED_CAPABILITY_AUTHENTICATED pid={expected_pid}"
    )) {
        return Err(format!(
            "guardian reap capability was proved but its journal failed: {error}"
        ));
    }
    Ok(())
}

fn stop_root_spawned_proxy(
    state: &mut RootBrokerState,
    graceful_seconds: u64,
    absolute_deadline: Instant,
) -> Result<(), String> {
    let phase_deadline = std::cmp::min(
        absolute_deadline,
        Instant::now() + Duration::from_secs(PROXY_STOP_PRIMITIVE_SECONDS),
    );
    let forced_cleanup_boundary = phase_deadline
        .checked_sub(Duration::from_secs(PROXY_FORCED_CLEANUP_RESERVE_SECONDS))
        .unwrap_or_else(Instant::now);
    let graceful_deadline = std::cmp::min(
        Instant::now() + Duration::from_secs(graceful_seconds),
        forced_cleanup_boundary,
    );
    let mut marker_diagnostic = None;
    if graceful_seconds != 0
        && state.guardian.is_some()
        && !state.guardian_reaped_authenticated
    {
        if let Err(error) = receive_guardian_reaped_capability_marker(state, graceful_deadline) {
            marker_diagnostic = Some(error);
        }
    }
    drop(state.proxy_capability.take());
    let Some(child) = state.proxy_child.as_mut() else {
        return marker_diagnostic.map_or(Ok(()), Err);
    };
    let pid = child.id();
    let expected_start = state.proxy_start.clone();
    let mut diagnostics = Vec::new();
    if expected_start.is_none() {
        push_session_diagnostic(
            &mut diagnostics,
            "TRACKED_IDENTITY",
            "root-owned UID proxy start identity is absent",
        );
    }
    let deadline = graceful_deadline;
    while Instant::now() < deadline {
        match owned_session_ready_to_reap(child, pid, phase_deadline) {
            Ok(true) => match reap_quiescent_owned_session(
                child,
                pid,
                "root-owned UID proxy",
                phase_deadline,
            ) {
                Ok(_) => {
                    state.proxy_child.take();
                    state.proxy_start.take();
                    return marker_diagnostic.map_or(Ok(()), Err);
                }
                Err(error) => {
                    push_session_diagnostic(&mut diagnostics, "NATURAL_REAP", error);
                    break;
                }
            },
            Ok(false) => {}
            Err(error) => {
                push_session_diagnostic(&mut diagnostics, "NATURAL_BARRIER", error);
                break;
            }
        }
        sleep_capped_by_absolute_deadline(deadline, Duration::from_millis(50));
    }
    match retained_child_exited_without_reap(child) {
        Ok(_) => {}
        Err(error) => push_session_diagnostic(&mut diagnostics, "WAITID", error),
    }
    let mut outcome = terminate_preconfigured_session(
        child,
        pid,
        "root-owned UID proxy",
        phase_deadline,
    )?;
    outcome.diagnostics.splice(0..0, diagnostics);
    state.proxy_child.take();
    state.proxy_start.take();
    if outcome.diagnostics.is_empty() && marker_diagnostic.is_none() {
        Ok(())
    } else {
        Err(format!(
            "root-owned UID proxy reached exact quiescence with diagnostics: {}{}",
            outcome.diagnostics.join(" | "),
            marker_diagnostic
                .map(|value| format!(" | guardian-marker={value}"))
                .unwrap_or_default()
        ))
    }
}

fn root_emergency_cleanup(
    state: &mut RootBrokerState,
    root_deadline: Instant,
) -> Result<(), String> {
    let absolute_deadline = std::cmp::min(
        root_deadline,
        Instant::now() + Duration::from_secs(EMERGENCY_CLEANUP_ABSOLUTE_SECONDS),
    );
    let mut errors = EmergencyErrors::default();
    let candidate_was_bound = state.candidate.is_some()
        || state.candidate_child.is_some()
        || state.candidate_live;
    let restored_runtime_terminal = state.driver_restored
        && state.v6_restored
        && !state.v6_restore_may_have_begun
        && state.runtime_lock.is_none();
    let offline_recovery_required = !restored_runtime_terminal
        && (state.v6_stop_may_have_begun
            || state.v6_stopped
            || state.v6_restore_may_have_begun
            || state.publication_requested
            || state.candidate_live);

    // Give the authenticated proxy enough time to run its retained-guardian finally path and
    // publish the post-reap capability marker. Any failure is recorded, not allowed to suppress
    // later independent physical postconditions.
    if let Err(error) = stop_root_spawned_proxy(state, 30, absolute_deadline) {
        errors.push("proxy-stop", error);
    }
    let proxy_quiescent = state.proxy_child.is_none();

    if offline_recovery_required
        && (!state.v6_stopped || state.v6_restore_may_have_begun)
    {
        match run_uid_sealed_until(UID_STOP_V6_MODE, None, absolute_deadline) {
            Ok(()) => {
                state.v6_stopped = true;
                state.v6_restore_may_have_begun = false;
            }
            Err(error) => errors.push("uid-v6-stop", error),
        }
    }

    drop(state.candidate_control.take());
    let mut candidate_session_quiescent = !candidate_was_bound;
    if candidate_was_bound && !state.candidate_stopped {
        let candidate = state.candidate.clone();
        match (state.candidate_child.as_mut(), candidate.as_ref()) {
            (Some(child), Some(identity)) => {
                match stop_owned_candidate_root(
                    child,
                    identity,
                    !offline_recovery_required,
                    absolute_deadline,
                ) {
                    Ok(outcome) => {
                        candidate_session_quiescent = true;
                        state.candidate_child.take();
                        for diagnostic in outcome.diagnostics {
                            errors.push("candidate-stop-diagnostic", diagnostic);
                        }
                    }
                    Err(error) => errors.push("candidate-stop", error),
                }
            }
            _ => errors.push(
                "candidate-ownership",
                "bound candidate lacks its unreaped direct Child/identity",
            ),
        }
    } else if state.candidate_stopped && state.candidate_child.is_none() {
        candidate_session_quiescent = true;
    }

    let mut runtime_gate_satisfied = !offline_recovery_required;
    if offline_recovery_required
        && state.v6_stopped
        && !state.v6_restore_may_have_begun
        && candidate_session_quiescent
    {
        if let Some(guard) = state.runtime_lock.as_ref() {
            match require_runtime_mutation_guard_barrier_root(guard) {
                Ok(()) => runtime_gate_satisfied = true,
                Err(error) => errors.push("retained-runtime-lock", error),
            }
        } else {
            match acquire_runtime_mutation_guard_root() {
                Ok(guard) => {
                    state.runtime_lock = Some(guard);
                    runtime_gate_satisfied = true;
                }
                Err(error) => errors.push("acquire-runtime-lock", error),
            }
        }
        if runtime_gate_satisfied {
            state.v6_stopped = true;
        }
    }
    // Session quiescence is durable independently of a transient runtime-lock/service proof.
    // A later accumulator pass may reacquire the mutation guard without needing the consumed
    // retained Child or ever rediscovering/signaling an unowned numeric PID.
    state.candidate_stopped = candidate_session_quiescent;

    let mut routes_satisfied = state.routes_repaired;
    if !routes_satisfied
        && proxy_quiescent
        && candidate_session_quiescent
        && runtime_gate_satisfied
    {
        let guardian_quiescence_deadline = std::cmp::min(
            absolute_deadline,
            Instant::now() + Duration::from_secs(ROUTES_REPAIRED_PRIMITIVE_SECONDS),
        );
        let guardian_quiescent = if state.guardian.is_some() {
            if state.guardian_reaped_authenticated {
                true
            } else {
                match wait_for_tracked_guardian_generation_absence(
                    state,
                    guardian_quiescence_deadline,
                ) {
                    Ok(()) => true,
                    Err(error) => {
                        errors.push("guardian-quiescence", error);
                        false
                    }
                }
            }
        } else {
            match wait_for_unbound_guardian_absence(guardian_quiescence_deadline) {
                Ok(()) => true,
                Err(error) => {
                    errors.push("unbound-guardian-quiescence", error);
                    false
                }
            }
        };
        if guardian_quiescent {
            let guardian_state_bind_deadline = std::cmp::min(
                absolute_deadline,
                Instant::now()
                    + Duration::from_secs(GUARDIAN_RECOVERY_STATE_BIND_PRIMITIVE_SECONDS),
            );
            match bind_guardian_state_hash_for_recovery(state, guardian_state_bind_deadline) {
                Ok(Some(expected_hash)) if state.guardian_reaped_authenticated => {
                    match verify_guardian_evidence_until(
                        &TrialLayout::fixed().guardian_final_result,
                        "broker-final",
                        true,
                        false,
                        guardian_state_bind_deadline,
                    ) {
                        Ok(_) => {
                            routes_satisfied = true;
                            state.routes_repaired = true;
                        }
                        Err(error) => errors.push("guardian-final-evidence", error),
                    }
                    match stable_private_sha256_until(
                        &TrialLayout::fixed().guardian_state,
                        guardian_state_bind_deadline,
                    ) {
                        Ok(observed) if observed == expected_hash => {}
                        Ok(_) => {
                            routes_satisfied = false;
                            state.routes_repaired = false;
                            errors.push(
                                "guardian-state",
                                "guardian state changed after final evidence",
                            );
                        }
                        Err(error) => {
                            routes_satisfied = false;
                            state.routes_repaired = false;
                            errors.push("guardian-state-reproof", error);
                        }
                    }
                }
                Ok(Some(expected_hash)) => {
                    match root_resume_or_run_emergency_route_repair(
                        &expected_hash,
                        absolute_deadline,
                    ) {
                        Ok(()) => {
                            routes_satisfied = true;
                            state.routes_repaired = true;
                            if let Err(error) = root_append_state(
                                "EMERGENCY_ROUTES_REPAIRED_AFTER_GUARDIAN_ABSENCE",
                            ) {
                                errors.push("emergency-route-repair-journal", error);
                            }
                        }
                        Err(error) => errors.push("emergency-route-repair", error),
                    }
                }
                Ok(None) if state.guardian.is_none() => {
                    match require_no_guardian_route_artifacts_without_state() {
                        Ok(()) => {
                            routes_satisfied = true;
                            state.routes_repaired = true;
                        }
                        Err(error) => errors.push("guardian-unbound-artifacts", error),
                    }
                }
                Ok(None) => errors.push(
                    "guardian-state",
                    "capability-bound guardian has no exact recovery state",
                ),
                Err(error) => errors.push("guardian-state", error),
            }
        }
    }

    if !state.driver_restored
        && proxy_quiescent
        && candidate_session_quiescent
        && runtime_gate_satisfied
        && routes_satisfied
    {
        let runtime_lock = state.runtime_lock.as_ref();
        match root_restore_driver_reload_and_verify_hal(&state.hold, runtime_lock) {
            Ok(outcome) => {
                state.driver_restored = true;
                for diagnostic in outcome.diagnostics {
                    errors.push("driver-recovery-diagnostic", diagnostic);
                }
            }
            Err(error) => errors.push("driver-recovery", error),
        }
    }

    let pointer_temp_absent = match remove_incomplete_active_pointer_temp_if_present() {
        Ok(()) => true,
        Err(error) => {
            errors.push("pointer-temp-cleanup", error);
            false
        }
    };
    if !state.proxy_connected && !state.user_evidence_armed {
        match exact_armed_user_evidence_present() {
            Ok(value) => state.user_evidence_armed = value,
            Err(error) => errors.push("armed-evidence-proof", error),
        }
    }
    let finalization_scope = state.proxy_connected || state.user_evidence_armed;

    if state.driver_restored && !state.v6_restored {
        let release_ready = if let Some(guard) = state.runtime_lock.as_ref() {
            match require_runtime_mutation_guard_barrier_root(guard) {
                Ok(()) => true,
                Err(error) => {
                    errors.push("pre-v6-restore-runtime-barrier", error);
                    false
                }
            }
        } else {
            !offline_recovery_required
        };
        if release_ready {
            state.v6_restore_may_have_begun = true;
            state.v6_stopped = false;
            if let Err(error) = root_append_state("EMERGENCY_V6_RESTORE_MAY_HAVE_BEGUN") {
                errors.push("v6-restore-intent-journal", error);
            }
            let mut release_succeeded = true;
            if let Some(guard) = state.runtime_lock.as_mut() {
                if let Err(error) = guard.release() {
                    errors.push("release-runtime-lock", error);
                    release_succeeded = false;
                } else {
                    state.runtime_lock.take();
                }
            }
            if release_succeeded && state.runtime_lock.is_none() {
                match run_uid_sealed_until(UID_EMERGENCY_V6_MODE, None, absolute_deadline) {
                    Ok(()) => {
                        state.v6_restored = true;
                        state.v6_restore_may_have_begun = false;
                        if let Err(error) = root_append_state("EXACT_V6_RESTORED_AND_VERIFIED") {
                            errors.push("v6-restore-journal", error);
                        }
                    }
                    Err(error) => errors.push("v6-restore", error),
                }
            }
        }
    }

    let finalization_gate = finalization_scope
        && proxy_quiescent
        && candidate_session_quiescent
        && runtime_gate_satisfied
        && routes_satisfied
        && state.driver_restored
        && state.v6_restored
        && !state.v6_restore_may_have_begun
        && state.runtime_lock.is_none();
    if finalization_gate && !state.evidence_finalized {
        match run_uid_sealed_until(UID_FINALIZE_EVIDENCE_MODE, None, absolute_deadline) {
            Ok(()) => {
                state.evidence_finalized = true;
                if let Err(error) = root_append_state("USER_ROLLBACK_EVIDENCE_FINALIZED") {
                    errors.push("evidence-finalization-journal", error);
                }
            }
            Err(error) => errors.push("evidence-finalization", error),
        }
    }

    let evidence_satisfied = !finalization_scope || state.evidence_finalized;
    let complete = proxy_quiescent
        && candidate_session_quiescent
        && runtime_gate_satisfied
        && routes_satisfied
        && state.driver_restored
        && state.v6_restored
        && !state.v6_restore_may_have_begun
        && evidence_satisfied
        && pointer_temp_absent
        && state.runtime_lock.is_none();
    if complete {
        state.recovery_complete = true;
        if let Err(error) = root_append_state("EMERGENCY_RECOVERY_COMPLETE") {
            errors.push("emergency-complete-journal", error);
        }
    } else if let Err(error) = root_append_state("EMERGENCY_RECOVERY_INCOMPLETE") {
        errors.push("emergency-incomplete-journal", error);
    }

    if complete && errors.entries.is_empty() {
        Ok(())
    } else if complete {
        Err(format!(
            "emergency recovery reached all terminal postconditions with diagnostics: {}",
            errors.render()
        ))
    } else {
        Err(format!(
            "emergency recovery incomplete: proxy={proxy_quiescent} candidate={candidate_session_quiescent} runtime={runtime_gate_satisfied} routes={routes_satisfied} driver={} v6={} evidence={evidence_satisfied} pointer_temp={pointer_temp_absent} lock_released={}; diagnostics={}",
            state.driver_restored,
            state.v6_restored,
            state.runtime_lock.is_none(),
            errors.render()
        ))
    }
}

fn spawn_line_reader<R: Read + Send + 'static>(
    input: R,
    maximum: usize,
    label: &'static str,
) -> mpsc::Receiver<Result<String, String>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut reader = BufReader::new(input);
        loop {
            let mut bytes = Vec::new();
            let read = match Read::by_ref(&mut reader)
                .take((maximum + 2) as u64)
                .read_until(b'\n', &mut bytes)
            {
                Ok(value) => value,
                Err(error) => {
                    let _ = sender.send(Err(format!("{label} read failed: {error}")));
                    return;
                }
            };
            if read == 0 {
                return;
            }
            if bytes.len() > maximum || !bytes.ends_with(b"\n") {
                let _ = sender.send(Err(format!("{label} exceeded its line bound")));
                return;
            }
            bytes.pop();
            if bytes.ends_with(b"\r") {
                bytes.pop();
            }
            match String::from_utf8(bytes) {
                Ok(line) => {
                    if sender.send(Ok(line)).is_err() {
                        return;
                    }
                }
                Err(_) => {
                    let _ = sender.send(Err(format!("{label} is not UTF-8")));
                    return;
                }
            }
        }
    });
    receiver
}

fn spawn_bounded_byte_reader<R: Read + Send + 'static>(
    mut input: R,
    maximum: usize,
    label: &'static str,
) -> mpsc::Receiver<Result<Vec<u8>, String>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = Read::by_ref(&mut input)
            .take((maximum + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("{label} read failed: {error}"))
            .and_then(|_| {
                if bytes.len() > maximum {
                    Err(format!("{label} exceeded its byte bound"))
                } else {
                    Ok(bytes)
                }
            });
        let _ = sender.send(result);
    });
    receiver
}

fn candidate_gate_failure_diagnostic(
    child: &mut OwnedSessionChild,
    pid: u32,
    stderr_receiver: mpsc::Receiver<Result<Vec<u8>, String>>,
    phase: &str,
    observation: &str,
    cleanup_deadline: Instant,
) -> String {
    let cleanup = terminate_preconfigured_session(
        child,
        pid,
        "root-owned candidate gate",
        cleanup_deadline,
    );
    let final_status = match &cleanup {
        Ok(outcome) => format!("{:?}", outcome.status),
        Err(_) => "<unreaped-retained-child>".to_owned(),
    };
    let stderr = match stderr_receiver.recv_timeout(Duration::from_secs(2)) {
        Ok(Ok(bytes)) => String::from_utf8_lossy(&bytes).trim().to_owned(),
        Ok(Err(error)) => format!("<unavailable: {error}>"),
        Err(error) => format!("<unavailable: {error}>"),
    };
    format!(
        "candidate gate {phase}: observation={observation} final_status={final_status} stderr={stderr:?} cleanup={cleanup:?}"
    )
}

struct RootClient {
    stream: UnixStream,
}

impl RootClient {
    fn connect() -> Result<Self, String> {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            match fs::symlink_metadata(ROOT_BROKER_SOCKET) {
                Ok(metadata)
                    if metadata.file_type().is_socket()
                        && metadata.uid() == 501
                        && metadata.gid() == 20
                        && metadata.mode() & 0o777 == 0o600 =>
                {
                    let stream = UnixStream::connect(ROOT_BROKER_SOCKET)
                        .map_err(|error| format!("could not connect root broker: {error}"))?;
                    stream
                        .set_read_timeout(Some(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS)))
                        .map_err(|error| error.to_string())?;
                    stream
                        .set_write_timeout(Some(Duration::from_secs(5)))
                        .map_err(|error| error.to_string())?;
                    let mut client = Self { stream };
                    client.expect("LOCAL_ROOT_BROKER_READY")?;
                    return Ok(client);
                }
                Ok(_) => return Err("root broker socket metadata is unsafe".to_owned()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    if Instant::now() >= deadline {
                        return Err("root broker socket did not become ready".to_owned());
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                Err(error) => return Err(format!("could not inspect root broker socket: {error}")),
            }
        }
    }

    fn read_line(&mut self) -> Result<String, String> {
        let mut bytes = Vec::new();
        loop {
            if bytes.len() > 160 {
                return Err("root broker response exceeded its line bound".to_owned());
            }
            let mut byte = [0_u8; 1];
            match self.stream.read(&mut byte) {
                Ok(0) => return Err("root broker closed its socket".to_owned()),
                Ok(_) if byte[0] == b'\n' => break,
                Ok(_) if byte[0] == b'\r' || byte[0] == 0 => {
                    return Err("root broker response contains a forbidden byte".to_owned())
                }
                Ok(_) => bytes.push(byte[0]),
                Err(error) => return Err(format!("root broker response failed: {error}")),
            }
        }
        String::from_utf8(bytes).map_err(|_| "root broker response is not UTF-8".to_owned())
    }

    fn expect(&mut self, expected: &str) -> Result<(), String> {
        let actual = self.read_line()?;
        if actual != expected {
            return Err(format!(
                "root broker response changed: got {actual:?}, expected {expected:?}"
            ));
        }
        Ok(())
    }

    fn exchange(&mut self, command: &str, expected: &str) -> Result<(), String> {
        self.exchange_with_timeout(
            command,
            expected,
            Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        )
    }

    fn exchange_with_timeout(
        &mut self,
        command: &str,
        expected: &str,
        timeout: Duration,
    ) -> Result<(), String> {
        let actual = self.request_with_timeout(command, timeout)?;
        if actual != expected {
            return Err(format!(
                "root broker response changed: got {actual:?}, expected {expected:?}"
            ));
        }
        Ok(())
    }

    fn request_with_timeout(
        &mut self,
        command: &str,
        timeout: Duration,
    ) -> Result<String, String> {
        if command.is_empty() || command.len() > 160 || command.contains(['\n', '\r', '\0']) {
            return Err("root broker command is malformed".to_owned());
        }
        self.stream
            .set_read_timeout(Some(timeout))
            .map_err(|error| error.to_string())?;
        writeln!(self.stream, "{command}").map_err(|error| error.to_string())?;
        self.stream.flush().map_err(|error| error.to_string())?;
        let result = self.read_line();
        self.stream
            .set_read_timeout(Some(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS)))
            .map_err(|error| error.to_string())?;
        result
    }

    fn request_until(
        &mut self,
        command: &str,
        deadline: Instant,
        maximum_response: Duration,
        label: &str,
    ) -> Result<String, String> {
        if command.is_empty() || command.len() > 160 || command.contains(['\n', '\r', '\0']) {
            return Err("root broker command is malformed".to_owned());
        }
        writeln!(self.stream, "{command}").map_err(|error| error.to_string())?;
        self.stream.flush().map_err(|error| error.to_string())?;
        let timeout = remaining_phase_timeout(deadline, maximum_response, label)?;
        self.stream
            .set_read_timeout(Some(timeout))
            .map_err(|error| error.to_string())?;
        let result = self.read_line();
        self.stream
            .set_read_timeout(Some(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS)))
            .map_err(|error| error.to_string())?;
        if Instant::now() >= deadline {
            return Err(format!("{label} absolute deadline expired"));
        }
        result
    }

    fn exchange_until(
        &mut self,
        command: &str,
        expected: &str,
        deadline: Instant,
        maximum_response: Duration,
        label: &str,
    ) -> Result<(), String> {
        let actual = self.request_until(command, deadline, maximum_response, label)?;
        if actual != expected {
            return Err(format!(
                "root broker response changed: got {actual:?}, expected {expected:?}"
            ));
        }
        Ok(())
    }

    fn ping(&mut self) -> Result<(), String> {
        self.exchange("L1Ciab PING", "LOCAL_ROOT_BROKER_PONG")
    }
}

struct GuardianBroker {
    child: OwnedSessionChild,
    input: Option<ChildStdin>,
    lines: mpsc::Receiver<Result<String, String>>,
    transcript: File,
    reaped: bool,
}

impl Drop for GuardianBroker {
    fn drop(&mut self) {
        if self.reaped {
            return;
        }
        drop(self.input.take());
        let pid = self.child.id();
        if terminate_preconfigured_session(
            &mut self.child,
            pid,
            "persistent guardian Drop cleanup",
            Instant::now() + Duration::from_secs(CANDIDATE_STOP_PRIMITIVE_SECONDS),
        )
        .is_ok()
        {
            self.reaped = true;
        }
    }
}

impl GuardianBroker {
    fn exchange(&mut self, command: &str, expected: &str) -> Result<(), String> {
        let timeout = if command == "RUN_VPIO" {
            Duration::from_secs(60)
        } else {
            Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS)
        };
        self.exchange_with_timeout(command, expected, timeout)
    }

    fn exchange_with_timeout(
        &mut self,
        command: &str,
        expected: &str,
        timeout: Duration,
    ) -> Result<(), String> {
        if !matches!(
            command,
            "PING" | "CHECK" | "POST_PUBLISH_FENCE" | "RUN_VPIO" | "REPAIR" | "STOP"
        ) {
            return Err("guardian command is not reviewed".to_owned());
        }
        let input = self.input.as_mut().ok_or("guardian stdin is closed")?;
        writeln!(input, "{command}").map_err(|error| error.to_string())?;
        input.flush().map_err(|error| error.to_string())?;
        let line = self
            .lines
            .recv_timeout(timeout)
            .map_err(|_| "guardian broker response deadline expired".to_owned())??;
        writeln!(self.transcript, "{line}").map_err(|error| error.to_string())?;
        self.transcript.sync_all().map_err(|error| error.to_string())?;
        if line != expected {
            return Err(format!(
                "guardian broker response changed: got {line:?}, expected {expected:?}"
            ));
        }
        Ok(())
    }

    fn exchange_until(
        &mut self,
        command: &str,
        expected: &str,
        deadline: Instant,
        maximum_response: Duration,
        label: &str,
    ) -> Result<(), String> {
        if !matches!(
            command,
            "PING" | "CHECK" | "POST_PUBLISH_FENCE" | "RUN_VPIO" | "REPAIR" | "STOP"
        ) {
            return Err("guardian command is not reviewed".to_owned());
        }
        let input = self.input.as_mut().ok_or("guardian stdin is closed")?;
        writeln!(input, "{command}").map_err(|error| error.to_string())?;
        input.flush().map_err(|error| error.to_string())?;
        let timeout = remaining_phase_timeout(deadline, maximum_response, label)?;
        let line = self
            .lines
            .recv_timeout(timeout)
            .map_err(|_| format!("{label} response deadline expired"))??;
        writeln!(self.transcript, "{line}").map_err(|error| error.to_string())?;
        self.transcript.sync_all().map_err(|error| error.to_string())?;
        if Instant::now() >= deadline {
            return Err(format!("{label} absolute deadline expired"));
        }
        if line != expected {
            return Err(format!(
                "guardian broker response changed: got {line:?}, expected {expected:?}"
            ));
        }
        Ok(())
    }
}

fn detach_root_broker_session() -> Result<(), String> {
    let pid = unsafe { libc_getpid() };
    let result = unsafe { libc_setsid() };
    if result < 0 && unsafe { libc_getsid(0) } != pid {
        return Err(format!(
            "root broker could not create a detached session: {}",
            std::io::Error::last_os_error()
        ));
    }
    if unsafe { libc_getpgrp() } != pid || unsafe { libc_getsid(0) } != pid {
        return Err("root broker is not its own process-group/session leader".to_owned());
    }
    Ok(())
}

fn verify_waiting_uid501_proxy_identity(
    expected_child: &OwnedSessionChild,
    expected_pid: u32,
    expected_start: &str,
) -> Result<(), String> {
    if expected_child.id() != expected_pid {
        return Err("root-owned UID proxy child PID changed before connecting".to_owned());
    }
    if retained_child_exited_without_reap(expected_child)? {
        return Err("root-owned UID proxy exited before connecting".to_owned());
    }
    verify_root_sealed_controller_process(expected_pid).map_err(|error| {
        format!("root-owned UID proxy exited or changed before connecting: {error}")
    })?;
    let observed_start = process_start_identity(expected_pid).map_err(|error| {
        format!("root-owned UID proxy exited or changed before connecting: {error}")
    })?;
    if observed_start != expected_start {
        return Err("root-owned UID proxy start identity changed before connecting".to_owned());
    }
    Ok(())
}

fn root_accept_uid501_peer(
    listener: &UnixListener,
    expected_child: &mut OwnedSessionChild,
    expected_pid: u32,
    expected_start: &str,
    root_capability: &UnixStream,
) -> Result<UnixStream, String> {
    let capability_file = std::mem::ManuallyDrop::new(unsafe {
        File::from_raw_fd(root_capability.as_raw_fd())
    });
    let capability_metadata = capability_file
        .metadata()
        .map_err(|error| format!("root-owned UID proxy capability is unavailable: {error}"))?;
    let mut capability_uid = u32::MAX;
    let mut capability_gid = u32::MAX;
    if unsafe {
        libc_getpeereid(
            root_capability.as_raw_fd(),
            &mut capability_uid,
            &mut capability_gid,
        )
    } != 0
        || !capability_metadata.file_type().is_socket()
        || capability_uid != 0
        || capability_gid != 0
    {
        return Err("root-owned UID proxy capability identity changed".to_owned());
    }
    listener
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(ROOT_ACCEPT_SECONDS);
    loop {
        verify_waiting_uid501_proxy_identity(
            expected_child,
            expected_pid,
            expected_start,
        )?;
        if Instant::now() >= deadline {
            return Err("root broker timed out waiting for its uid501 guardian".to_owned());
        }
        match listener.accept() {
            Ok((stream, _)) => {
                let mut uid = u32::MAX;
                let mut gid = u32::MAX;
                if unsafe { libc_getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0
                    || uid != 501
                {
                    continue;
                }
                let mut peer_pid: i32 = 0;
                let mut peer_size = std::mem::size_of::<i32>() as u32;
                if unsafe {
                    libc_getsockopt(
                        stream.as_raw_fd(),
                        SOL_LOCAL,
                        LOCAL_PEERPID,
                        (&mut peer_pid as *mut i32).cast(),
                        &mut peer_size,
                    )
                } != 0
                    || peer_size as usize != std::mem::size_of::<i32>()
                    || peer_pid <= 0
                {
                    continue;
                }
                let start_matches = process_start_identity(expected_pid)
                    .map(|value| value == expected_start)
                    .unwrap_or(false);
                if peer_pid as u32 != expected_pid
                    || verify_root_sealed_controller_process(expected_pid).is_err()
                    || !start_matches
                {
                    continue;
                }
                stream
                    .set_nonblocking(false)
                    .map_err(|error| error.to_string())?;
                return Ok(stream);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(format!("root broker accept failed: {error}")),
        }
    }
}

fn root_socket_identity() -> Result<(u64, u64), String> {
    let metadata = fs::symlink_metadata(ROOT_BROKER_SOCKET)
        .map_err(|error| format!("could not inspect root broker socket: {error}"))?;
    if !metadata.file_type().is_socket()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 501
        || metadata.gid() != 20
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
    {
        return Err("root broker socket metadata is unsafe".to_owned());
    }
    Ok((metadata.dev(), metadata.ino()))
}

fn verify_root_sealed_controller_process(pid: u32) -> Result<(), String> {
    require_root_regular(Path::new(SEALED_CONTROLLER_PIN), 0o444)?;
    let expected = read_bounded_utf8(Path::new(SEALED_CONTROLLER_PIN), 128, 0, 0o444)?;
    verify_exact_process_executable(pid, Path::new(SEALED_CONTROLLER), 0, expected.trim())?;
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("socket peer is not the exact sealed new-session controller".to_owned());
    }
    Ok(())
}

fn root_send(stream: &mut UnixStream, response: &str) -> Result<(), String> {
    if response.is_empty() || response.len() > 160 || response.contains(['\n', '\r', '\0']) {
        return Err("root broker response is malformed".to_owned());
    }
    writeln!(stream, "{response}").map_err(|error| error.to_string())?;
    stream.flush().map_err(|error| error.to_string())
}

fn verify_bound_dormant_candidate_gate(
    candidate: Option<&(u32, String)>,
) -> Result<(), String> {
    let (pid, expected_start) = candidate.ok_or("bound candidate gate is absent")?;
    let (observed_start, phase) = verify_root_candidate_or_gate(*pid)?;
    if phase != CandidatePhase::DormantGate || observed_start != *expected_start {
        return Err("bound candidate gate changed before the destructive boundary".to_owned());
    }
    Ok(())
}

struct ProtocolSocketShutdown(UnixStream);

impl Drop for ProtocolSocketShutdown {
    fn drop(&mut self) {
        let _ = self.0.shutdown(Shutdown::Both);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RootProtocolExpectedCommand {
    GuardianState,
    CandidateGate,
    PrestopFence,
    V6StopIntent,
    PostStopPing,
    Publish,
    PostPublishFence,
    PostFencePing,
    PostMirrorPing,
    ProbesVerified,
    CandidateRelease,
    Live,
    GuardianReaped,
    RoutesRepaired,
    Rollback,
    RestoreV6,
    Complete,
}

impl RootProtocolExpectedCommand {
    fn idle_seconds(self) -> u64 {
        match self {
            Self::PrestopFence => ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS,
            Self::PostStopPing => ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS,
            Self::PostPublishFence => ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS,
            Self::PostMirrorPing => ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS,
            Self::CandidateRelease => ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS,
            Self::GuardianReaped => ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS,
            Self::GuardianState
            | Self::CandidateGate
            | Self::V6StopIntent
            | Self::Publish
            | Self::PostFencePing
            | Self::ProbesVerified
            | Self::Live
            | Self::RoutesRepaired
            | Self::Rollback
            | Self::RestoreV6
            | Self::Complete => ROOT_BROKER_DEADMAN_SECONDS,
        }
    }

    fn accepts(self, command: &str) -> bool {
        match self {
            Self::GuardianState => command.starts_with("L1Ciab GUARDIAN_STATE "),
            Self::CandidateGate => command == "L1Ciab CANDIDATE_GATE",
            Self::PrestopFence => command == "L1Ciab PRESTOP_FENCE",
            Self::V6StopIntent => command == "L1Ciab V6_STOP_INTENT",
            Self::PostStopPing | Self::PostFencePing | Self::PostMirrorPing => {
                command == "L1Ciab PING"
            }
            Self::Publish => command == "L1Ciab PUBLISH",
            Self::PostPublishFence => command.starts_with("L1Ciab POST_PUBLISH_FENCE "),
            Self::ProbesVerified => command == "L1Ciab PROBES_VERIFIED",
            Self::CandidateRelease => command == "L1Ciab RELEASE_CANDIDATE_GATE",
            Self::Live => {
                command == "L1Ciab PING"
                    || command.starts_with("L1Ciab CANDIDATE_HEALTH ")
                    || command == "L1Ciab CANDIDATE_STOPPED"
            }
            Self::GuardianReaped => command.starts_with("L1Ciab GUARDIAN_REAPED "),
            Self::RoutesRepaired => command == "L1Ciab ROUTES_REPAIRED",
            Self::Rollback => command == "L1Ciab ROLLBACK",
            Self::RestoreV6 => command == "L1Ciab RESTORE_V6",
            Self::Complete => command == "L1Ciab COMPLETE",
        }
    }

    fn after(self, command: &str) -> Result<Self, String> {
        let next = match self {
            Self::GuardianState => Self::CandidateGate,
            Self::CandidateGate => Self::PrestopFence,
            Self::PrestopFence => Self::V6StopIntent,
            Self::V6StopIntent => Self::PostStopPing,
            Self::PostStopPing => Self::Publish,
            Self::Publish => Self::PostPublishFence,
            Self::PostPublishFence => Self::PostFencePing,
            Self::PostFencePing => Self::PostMirrorPing,
            Self::PostMirrorPing => Self::ProbesVerified,
            Self::ProbesVerified => Self::CandidateRelease,
            Self::CandidateRelease => Self::Live,
            Self::Live if command == "L1Ciab CANDIDATE_STOPPED" => Self::GuardianReaped,
            Self::Live => Self::Live,
            Self::GuardianReaped => Self::RoutesRepaired,
            Self::RoutesRepaired => Self::Rollback,
            Self::Rollback => Self::RestoreV6,
            Self::RestoreV6 => Self::Complete,
            Self::Complete => {
                return Err("root protocol cannot advance after COMPLETE".to_owned())
            }
        };
        Ok(next)
    }
}

fn root_protocol(
    mut stream: UnixStream,
    state: &mut RootBrokerState,
    absolute_deadline: Instant,
) -> Result<bool, String> {
    stream
        .set_write_timeout(Some(Duration::from_secs(FAST_PROCESS_BOUND_SECONDS)))
        .map_err(|error| format!("could not bound root protocol writes: {error}"))?;
    let _shutdown = ProtocolSocketShutdown(
        stream
            .try_clone()
            .map_err(|error| format!("could not retain root protocol shutdown handle: {error}"))?,
    );
    root_send(&mut stream, "LOCAL_ROOT_BROKER_READY")?;
    receive_guardian_spawned_capability_marker(state, absolute_deadline)?;
    let responses = spawn_line_reader(
        stream.try_clone().map_err(|error| error.to_string())?,
        160,
        "root broker socket command",
    );
    let mut expected_command = RootProtocolExpectedCommand::GuardianState;
    loop {
        let now = Instant::now();
        if now >= absolute_deadline {
            return Err("root broker absolute one-shot deadline expired".to_owned());
        }
        let remaining = absolute_deadline.saturating_duration_since(now);
        let timeout = std::cmp::min(
            Duration::from_secs(expected_command.idle_seconds()),
            remaining,
        );
        let command = match responses.recv_timeout(timeout) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => return Err(error),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                return Err("root broker heartbeat/deadline expired".to_owned())
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("root broker socket peer closed".to_owned())
            }
        };
        if !expected_command.accepts(&command) {
            return Err(format!(
                "root broker rejected command {command:?} while awaiting {expected_command:?}"
            ));
        }
        let response = if command == "L1Ciab PING" {
            "LOCAL_ROOT_BROKER_PONG".to_owned()
        } else if let Some(pid_text) = command.strip_prefix("L1Ciab GUARDIAN_REAPED ") {
            let pid = pid_text
                .parse::<u32>()
                .ok()
                .filter(|value| *value > 1)
                .ok_or("guardian-reaped PID is malformed")?;
            let tracked_pid = state
                .guardian
                .as_ref()
                .map(|value| value.0)
                .ok_or("guardian-reaped assertion has no bound guardian")?;
            if pid != tracked_pid
                || state.guardian_reaped_authenticated
                || !state.candidate_stopped
            {
                return Err("root broker rejected guardian-reaped sequence".to_owned());
            }
            receive_guardian_reaped_capability_marker(state, absolute_deadline)?;
            if !state.guardian_reaped_authenticated {
                return Err("root capability did not authenticate guardian reap".to_owned());
            }
            "LOCAL_ROOT_BROKER_GUARDIAN_REAPED".to_owned()
        } else if let Some(pid_text) = command.strip_prefix("L1Ciab CANDIDATE_HEALTH ") {
            let pid = pid_text
                .parse::<u32>()
                .ok()
                .filter(|value| *value > 1)
                .ok_or("candidate-health PID is malformed")?;
            let (tracked_pid, tracked_start) = state
                .candidate
                .as_ref()
                .ok_or("candidate-health request has no tracked identity")?;
            let child = state
                .candidate_child
                .as_ref()
                .ok_or("candidate-health request has no retained Child")?;
            if !state.candidate_live
                || pid != *tracked_pid
                || child.id() != pid
                || retained_child_exited_without_reap(child)?
                || verify_root_candidate(pid)? != *tracked_start
            {
                return Err("candidate-health retained-Child proof failed".to_owned());
            }
            format!("LOCAL_ROOT_BROKER_CANDIDATE_HEALTHY pid={pid}")
        } else if let Some(arguments) = command.strip_prefix("L1Ciab GUARDIAN_STATE ") {
            let fields: Vec<&str> = arguments.split(' ').collect();
            if fields.len() != 2
                || state.guardian_hash.is_some()
                || state.guardian.is_none()
                || state.guardian_generation.is_none()
                || state.v6_stopped
            {
                return Err("root broker rejected guardian binding sequence".to_owned());
            }
            let pid = fields[0]
                .parse::<u32>()
                .ok()
                .filter(|value| *value > 0)
                .ok_or("guardian PID is malformed")?;
            let hash = fields[1];
            let (pending_pid, pending_start) = state
                .guardian
                .as_ref()
                .ok_or("guardian state command has no capability-bound generation")?;
            if pid != *pending_pid {
                return Err("guardian state command changed its capability-bound PID".to_owned());
            }
            if hash.len() != 64 || fixed_guardian_state_hash()?.as_deref() != Some(hash) {
                return Err("root broker rejected guardian state hash".to_owned());
            }
            let _snapshot_hash = verify_guardian_evidence(
                &TrialLayout::fixed().guardian_snapshot_result,
                "broker-snapshot",
                false,
                true,
            )?;
            let start = verify_root_guardian_process(pid)?;
            let generation = process_bsd_identity(pid)?
                .filter(|value| {
                    value.uid == 501
                        && value.pgid == pid
                        && (1..=4).contains(&value.status)
                })
                .ok_or("guardian libproc generation is not an exact live UID501 session leader")?;
            if start != *pending_start
                || Some(generation) != state.guardian_generation
                || unsafe { libc_getsid(pid as i32) } != pid as i32
            {
                return Err("guardian generation is not its own exact session".to_owned());
            }
            state.guardian_hash = Some(hash.to_owned());
            root_append_state(&format!("GUARDIAN_STATE pid={pid} sha256={hash}"))?;
            "LOCAL_ROOT_BROKER_GUARDIAN_BOUND".to_owned()
        } else if command == "L1Ciab CANDIDATE_GATE" {
            if state.guardian_hash.is_none()
                || state.candidate.is_some()
                || state.candidate_child.is_some()
                || state.candidate_control.is_some()
                || state.prestop_fenced
                || state.v6_stop_may_have_begun
            {
                return Err("root broker rejected candidate-gate binding sequence".to_owned());
            }
            let (child, control, start) = root_spawn_candidate_gate()?;
            let pid = child.id();
            state.candidate = Some((pid, start));
            state.candidate_child = Some(child);
            state.candidate_control = Some(control);
            root_append_state(&format!("CANDIDATE_GATE_TRACKED pid={pid}"))?;
            format!("LOCAL_ROOT_BROKER_CANDIDATE_GATE_TRACKED pid={pid}")
        } else if command == "L1Ciab PRESTOP_FENCE"
            && state.guardian_hash.is_some()
            && state.candidate.is_some()
            && !state.v6_stopped
        {
            verify_bound_dormant_candidate_gate(state.candidate.as_ref())?;
            let (pid, start) = state.guardian.clone().ok_or("guardian identity is absent")?;
            if verify_root_guardian_process(pid)? != start {
                return Err("persistent guardian changed before pre-stop fence".to_owned());
            }
            let fence_hash = verify_guardian_evidence(
                &TrialLayout::fixed().guardian_fence_result,
                "broker-fence",
                false,
                true,
            )?;
            if fixed_guardian_state_hash()?.as_deref() != state.guardian_hash.as_deref() {
                return Err("guardian snapshot changed before pre-stop fence".to_owned());
            }
            state.prestop_fenced = true;
            root_append_state(&format!(
                "PRESTOP_DEFAULT_ROUTE_FENCE_PROVED sha256={fence_hash}"
            ))?;
            "LOCAL_ROOT_BROKER_PRESTOP_FENCED".to_owned()
        } else if command == "L1Ciab V6_STOP_INTENT"
            && state.prestop_fenced
            && state.candidate.is_some()
            && !state.v6_stop_may_have_begun
            && !state.v6_stopped
        {
            verify_bound_dormant_candidate_gate(state.candidate.as_ref())?;
            state.v6_stop_may_have_begun = true;
            root_append_state("V6_STOP_MAY_HAVE_BEGUN")?;
            run_uid_sealed(UID_STOP_V6_MODE, None)?;
            require_v6_launchd_service_absent_root()?;
            require_no_capture_server_root()?;
            state.runtime_lock = Some(acquire_runtime_mutation_guard_root()?);
            state.v6_stopped = true;
            root_append_state("V6_STOPPED")?;
            "LOCAL_ROOT_BROKER_V6_STOPPED".to_owned()
        } else if command == "L1Ciab PUBLISH"
            && state.v6_stopped
            && state.prestop_fenced
            && !state.publication_requested
        {
            state.publication_requested = true;
            let runtime_lock = state
                .runtime_lock
                .as_ref()
                .ok_or("root runtime-mutation lock is absent before publish")?;
            root_publish_driver(&state.hold, runtime_lock)?;
            "LOCAL_ROOT_BROKER_DRIVER_PUBLISHED_AND_RELOADED".to_owned()
        } else if let Some(hash) = command.strip_prefix("L1Ciab POST_PUBLISH_FENCE ") {
            if !state.v6_stopped
                || !state.prestop_fenced
                || !state.publication_requested
                || state.postpublish_fenced
                || state.postpublish_fence_hash.is_some()
                || state.candidate.is_none()
                || state.candidate_live
                || hash.len() != 64
                || !hash
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            {
                return Err("root broker rejected post-publish fence sequence".to_owned());
            }
            verify_bound_dormant_candidate_gate(state.candidate.as_ref())?;
            state
                .runtime_lock
                .as_ref()
                .ok_or("root runtime-mutation lock is absent at post-publish fence")?
                .require_named_identity()?;
            require_v6_launchd_service_absent_root()?;
            require_no_capture_server_root()?;
            let (pid, start) = state
                .guardian
                .clone()
                .ok_or("guardian identity is absent at post-publish fence")?;
            let generation = process_bsd_identity(pid)?
                .filter(|value| {
                    value.uid == 501
                        && value.pgid == pid
                        && (1..=4).contains(&value.status)
                })
                .ok_or("guardian generation changed at post-publish fence")?;
            if verify_root_guardian_process(pid)? != start
                || Some(generation) != state.guardian_generation
                || unsafe { libc_getsid(pid as i32) } != pid as i32
                || fixed_guardian_state_hash()?.as_deref()
                    != state.guardian_hash.as_deref()
            {
                return Err("guardian/state binding changed at post-publish fence".to_owned());
            }
            let observed = verify_guardian_evidence(
                &TrialLayout::fixed().guardian_post_publish_fence_result,
                "broker-post-publish-fence",
                false,
                true,
            )?;
            if observed != hash {
                return Err("guardian post-publish fence hash changed".to_owned());
            }
            state.postpublish_fence_hash = Some(observed.clone());
            state.postpublish_fenced = true;
            root_append_state(&format!(
                "POST_PUBLISH_DEFAULT_ROUTE_FENCE_PROVED sha256={observed}"
            ))?;
            "LOCAL_ROOT_BROKER_POST_PUBLISH_FENCED".to_owned()
        } else if command == "L1Ciab RELEASE_CANDIDATE_GATE" {
            if state.guardian_hash.is_none()
                || state.candidate_live
                || !state.v6_stopped
                || !state.publication_requested
                || !state.postpublish_fenced
                || !state.probes_verified
            {
                return Err("root broker rejected out-of-sequence candidate".to_owned());
            }
            let runtime_lock = state
                .runtime_lock
                .as_mut()
                .ok_or("root runtime-mutation lock is absent before candidate GO")?;
            require_runtime_mutation_guard_barrier_root(&runtime_lock)?;
            runtime_lock.release()?;
            state.runtime_lock.take();
            let pid = root_release_candidate_gate(state)?;
            state.candidate_live = true;
            root_append_state(&format!("CANDIDATE_LIVE_TRACKED pid={pid}"))?;
            format!("LOCAL_ROOT_BROKER_CANDIDATE_LIVE_TRACKED pid={pid}")
        } else if command == "L1Ciab PROBES_VERIFIED"
            && state.publication_requested
            && state.v6_stopped
            && state.postpublish_fenced
            && !state.probes_verified
            && state.candidate.is_some()
            && !state.candidate_live
        {
            require_v6_launchd_service_absent_root()?;
            require_no_capture_server_root()?;
            state
                .runtime_lock
                .as_ref()
                .ok_or("root runtime-mutation lock is absent during installed-driver probes")?
                .require_named_identity()?;
            verify_driver_tree(Path::new(PRODUCT_DRIVER), 0)?;
            require_exact_signature(
                Path::new(PRODUCT_DRIVER),
                "com.elamin.opensteamer.VirtualMicrophoneDriver",
                CANDIDATE_DRIVER_CDHASH,
                true,
            )?;
            let layout = TrialLayout::fixed();
            verify_mirror_result(&layout.mirror_result)?;
            let expected_fence_hash = state
                .postpublish_fence_hash
                .as_deref()
                .ok_or("post-publish fence hash is absent during probe proof")?;
            let (fence_hash, _guardian_run_hash) = verify_guardian_post_publish_link(
                &layout.guardian_post_publish_fence_result,
                &layout.guardian_run_result,
                "broker-run",
                false,
                true,
            )?;
            if fence_hash != expected_fence_hash
                || fixed_guardian_state_hash()?.as_deref()
                    != state.guardian_hash.as_deref()
            {
                return Err("post-publish guardian fence changed during probes".to_owned());
            }
            verify_public_vpio_result(&layout.vpio_stdout)?;
            state.probes_verified = true;
            root_append_state("INSTALLED_DRIVER_PROBES_VERIFIED")?;
            "LOCAL_ROOT_BROKER_PROBES_VERIFIED".to_owned()
        } else if command == "L1Ciab CANDIDATE_STOPPED"
            && state.v6_stopped
            && state.candidate_live
        {
            drop(state.candidate_control.take());
            let candidate = state
                .candidate
                .clone()
                .ok_or("tracked candidate identity is absent at normal stop")?;
            let child = state
                .candidate_child
                .as_mut()
                .ok_or("tracked candidate Child is absent at normal stop")?;
            let outcome = stop_owned_candidate_root(
                child,
                &candidate,
                false,
                absolute_deadline,
            )?;
            state.candidate_child.take();
            state.candidate_stopped = true;
            require_v6_launchd_service_absent_root()?;
            require_no_capture_server_root()?;
            state.runtime_lock = Some(acquire_runtime_mutation_guard_root()?);
            if !outcome.diagnostics.is_empty() {
                return Err(format!(
                    "candidate reached exact retained-session quiescence with diagnostics: {}",
                    outcome.diagnostics.join(" | ")
                ));
            }
            root_append_state("CANDIDATE_STOPPED_AND_LOCK_RELEASE_REQUESTED")?;
            "LOCAL_ROOT_BROKER_CANDIDATE_ABSENT".to_owned()
        } else if command == "L1Ciab ROUTES_REPAIRED"
            && state.candidate_stopped
            && state.guardian_reaped_authenticated
            && state.postpublish_fenced
        {
            let layout = TrialLayout::fixed();
            let expected_fence_hash = state
                .postpublish_fence_hash
                .as_deref()
                .ok_or("post-publish fence hash is absent at route repair")?;
            let (fence_hash, repair_hash) = verify_guardian_post_publish_link(
                &layout.guardian_post_publish_fence_result,
                &layout.guardian_final_result,
                "broker-final",
                true,
                false,
            )?;
            if fence_hash != expected_fence_hash {
                return Err("post-publish guardian fence changed at final repair".to_owned());
            }
            if fixed_guardian_state_hash()?.as_deref() != state.guardian_hash.as_deref() {
                return Err("guardian snapshot changed before final repair proof".to_owned());
            }
            state.routes_repaired = true;
            root_append_state(&format!(
                "ROUTES_REPAIRED_AND_GUARDIAN_EXITED sha256={repair_hash}"
            ))?;
            "LOCAL_ROOT_BROKER_ROUTES_REPAIRED".to_owned()
        } else if command == "L1Ciab ROLLBACK"
            && state.v6_stopped
            && state.candidate_stopped
            && state.routes_repaired
            && !state.driver_restored
        {
            let runtime_lock = state
                .runtime_lock
                .as_ref()
                .ok_or("root runtime-mutation lock is absent before rollback")?;
            root_restore_driver_reload_and_verify_hal(&state.hold, Some(runtime_lock))?;
            state.driver_restored = true;
            "LOCAL_ROOT_BROKER_DRIVER_ROLLED_BACK".to_owned()
        } else if command == "L1Ciab RESTORE_V6" && state.driver_restored {
            let runtime_lock = state
                .runtime_lock
                .as_mut()
                .ok_or("root runtime-mutation lock is absent before exact-v6 restore")?;
            require_runtime_mutation_guard_barrier_root(&runtime_lock)?;
            root_append_state("V6_RESTORE_MAY_HAVE_BEGUN")?;
            state.v6_restore_may_have_begun = true;
            state.v6_stopped = false;
            runtime_lock.release()?;
            state.runtime_lock.take();
            run_uid_sealed(UID_EMERGENCY_V6_MODE, None)?;
            state.v6_restored = true;
            state.v6_restore_may_have_begun = false;
            root_append_state("EXACT_V6_RESTORED_AND_VERIFIED")?;
            "LOCAL_ROOT_BROKER_V6_RESTORED".to_owned()
        } else if command == "L1Ciab COMPLETE"
            && state.candidate_stopped
            && state.routes_repaired
            && state.guardian_reaped_authenticated
            && state.driver_restored
            && state.v6_restored
            && !state.v6_restore_may_have_begun
            && state.runtime_lock.is_none()
        {
            if !recovery_may_finalize_user_evidence(
                state.proxy_connected,
                state.proxy_child.is_some(),
                state.candidate_stopped && state.candidate_child.is_none(),
                state.routes_repaired,
                state.driver_restored,
                state.v6_restored,
                state.runtime_lock.is_none(),
            ) {
                return Err("root broker refused user evidence before exact recovery".to_owned());
            }
            run_uid_sealed(UID_FINALIZE_EVIDENCE_MODE, None)?;
            state.evidence_finalized = true;
            root_append_state("USER_ROLLBACK_EVIDENCE_FINALIZED")?;
            root_append_state("TRIAL_COMPLETE")?;
            root_send(&mut stream, "LOCAL_ROOT_BROKER_COMPLETE")?;
            state.recovery_complete = true;
            return Ok(true);
        } else {
            return Err(format!("root broker rejected command {command:?}"));
        };
        root_send(&mut stream, &response)?;
        expected_command = expected_command.after(&command)?;
    }
}

fn root_broker() -> Result<(), String> {
    detach_root_broker_session()?;
    verify_root_controller_identity()?;
    let root_deadline = Instant::now() + Duration::from_secs(ROOT_BROKER_ABSOLUTE_SECONDS);
    let hold = root_prepare_transaction()?;
    let mut state = RootBrokerState {
        hold,
        runtime_lock: None,
        proxy_child: None,
        proxy_capability: None,
        proxy_start: None,
        proxy_connected: false,
        user_evidence_armed: false,
        v6_stop_may_have_begun: false,
        v6_stopped: false,
        v6_restore_may_have_begun: false,
        publication_requested: false,
        guardian_hash: None,
        guardian: None,
        guardian_generation: None,
        guardian_reaped_authenticated: false,
        prestop_fenced: false,
        postpublish_fence_hash: None,
        postpublish_fenced: false,
        probes_verified: false,
        candidate: None,
        candidate_child: None,
        candidate_control: None,
        candidate_live: false,
        candidate_stopped: false,
        routes_repaired: false,
        driver_restored: false,
        v6_restored: false,
        evidence_finalized: false,
        recovery_complete: false,
    };
    let run = (|| -> Result<bool, String> {
        require_absent_no_follow(Path::new(ROOT_BROKER_SOCKET), "root broker socket")?;
        let listener = UnixListener::bind(ROOT_BROKER_SOCKET)
            .map_err(|error| format!("could not bind root broker socket: {error}"))?;
        fs::set_permissions(ROOT_BROKER_SOCKET, fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
        run_fixed(
            "/usr/sbin/chown",
            &["501:20", ROOT_BROKER_SOCKET],
            "assign fixed broker socket to uid501",
        )?;
        let socket_identity = root_socket_identity()?;
        let (proxy_child, proxy_capability, proxy_start) = root_spawn_uid_proxy()?;
        let proxy_pid = proxy_child.id();
        state.proxy_child = Some(proxy_child);
        state.proxy_capability = Some(proxy_capability);
        state.proxy_start = Some(proxy_start.clone());
        root_publish_proxy_identity(proxy_pid, &proxy_start)?;
        let capability = state
            .proxy_capability
            .as_ref()
            .ok_or("root-owned UID proxy capability is absent")?;
        let proxy_child = state
            .proxy_child
            .as_mut()
            .ok_or("root-owned UID proxy child is absent")?;
        let stream = root_accept_uid501_peer(
            &listener,
            proxy_child,
            proxy_pid,
            &proxy_start,
            capability,
        )?;
        state.proxy_connected = true;
        state.user_evidence_armed = true;
        if root_socket_identity()? != socket_identity {
            return Err("root broker socket path changed during peer admission".to_owned());
        }
        // Preparation and authenticated peer admission have independent reviewed bounds. Start
        // the protocol clock only at the authenticated command boundary so they cannot consume
        // the complete protocol budget; the earlier root deadline still bounds the whole lifecycle.
        let protocol_deadline = std::cmp::min(
            root_deadline,
            Instant::now() + Duration::from_secs(ROOT_PROTOCOL_ABSOLUTE_SECONDS),
        );
        root_protocol(stream, &mut state, protocol_deadline)
    })();
    match run {
        Ok(true) => match stop_root_spawned_proxy(&mut state, 30, root_deadline) {
            Ok(()) => Ok(()),
            Err(error) if state.proxy_child.is_none() => {
                let _ = root_append_state(&format!(
                    "POST_COMPLETE_PROXY_QUIESCED_WITH_DIAGNOSTICS {}",
                    error.replace(['\n', '\r', '\0'], " ").chars().take(256).collect::<String>()
                ));
                Ok(())
            }
            Err(error) => Err(format!(
                "post-COMPLETE proxy remained retained for final Drop cleanup: {error}"
            )),
        },
        Ok(false) => {
            let recovery = root_emergency_cleanup(&mut state, root_deadline);
            Err(format!("root protocol ended without COMPLETE; recovery={recovery:?}"))
        }
        Err(error) => {
            let recovery = root_emergency_cleanup(&mut state, root_deadline);
            Err(format!("root protocol failed: {error}; recovery={recovery:?}"))
        }
    }
}

fn write_new_private_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > 4 * 1_048_576 {
        return Err("private process output exceeded its byte bound".to_owned());
    }
    let mut file = create_new_private(path)?;
    file.write_all(bytes).map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())
}

fn wait_for_proxy_arm() -> Result<(), String> {
    let pid = unsafe { libc_getpid() } as u32;
    let start = process_start_identity(pid)?;
    let deadline = Instant::now() + Duration::from_secs(300);
    while Instant::now() < deadline {
        match fs::symlink_metadata(PROXY_ARM) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                thread::sleep(Duration::from_millis(50));
                continue;
            }
            Err(error) => return Err(format!("could not inspect proxy arm record: {error}")),
            Ok(_) => {}
        }
        match read_bounded_utf8(Path::new(PROXY_ARM), 4_096, 501, 0o600) {
            Ok(value)
                if value
                    == format!(
                        "schema=opensteamer.local-mono-trial-proxy-arm.v1\nproxy_pid={pid}\nproxy_start={start}\n"
                    ) => {
                        let expected_pointer = format!(
                            "schema=opensteamer.local-mono-trial-pointer.v1\ntrial_root={TRIAL_ROOT}\nstate=arming\nproxy_pid={pid}\nproxy_start={start}\nstate=armed\n"
                        );
                        match read_bounded_utf8(Path::new(ACTIVE_POINTER), 4_096, 501, 0o600) {
                            Ok(pointer) if pointer == expected_pointer => return Ok(()),
                            Ok(_) => {
                                thread::sleep(Duration::from_millis(50));
                                continue;
                            }
                            Err(error) => return Err(error),
                        }
                    }
            Ok(_) => return Err("detached proxy arm record is malformed".to_owned()),
            Err(error) => return Err(error),
        }
    }
    Err("detached UID proxy was never durably armed".to_owned())
}

fn spawn_persistent_guardian() -> Result<GuardianBroker, String> {
    let layout = TrialLayout::fixed();
    require_hash(Path::new(SEALED_GUARDIAN), ROUTE_GUARDIAN_SHA256)?;
    require_hash(Path::new(SEALED_VPIO_PROBE), VPIO_PROBE_SHA256)?;
    let guardian_maximum = GUARDIAN_MAXIMUM_SECONDS.to_string();
    let transcript = create_new_private(&layout.guardian_stdout)?;
    let stderr = create_new_private(&layout.guardian_stderr)?;
    let mut command = Command::new(SEALED_GUARDIAN);
    command
        .args([
            "broker",
            "--child",
            SEALED_VPIO_PROBE,
            "--state",
            layout.guardian_state.to_str().ok_or("non-UTF-8 guardian state")?,
            "--snapshot-result",
            layout
                .guardian_snapshot_result
                .to_str()
                .ok_or("non-UTF-8 guardian snapshot result")?,
            "--run-result",
            layout
                .guardian_run_result
                .to_str()
                .ok_or("non-UTF-8 guardian run result")?,
            "--fence-result",
            layout
                .guardian_fence_result
                .to_str()
                .ok_or("non-UTF-8 guardian fence result")?,
            "--post-publish-fence-result",
            layout
                .guardian_post_publish_fence_result
                .to_str()
                .ok_or("non-UTF-8 guardian post-publish fence result")?,
            "--repair-result",
            layout
                .guardian_repair_result
                .to_str()
                .ok_or("non-UTF-8 guardian repair result")?,
            "--final-result",
            layout
                .guardian_final_result
                .to_str()
                .ok_or("non-UTF-8 guardian final result")?,
            "--child-stdout",
            layout.vpio_stdout.to_str().ok_or("non-UTF-8 VPIO stdout")?,
            "--child-stderr",
            layout.vpio_stderr.to_str().ok_or("non-UTF-8 VPIO stderr")?,
            "--timeout-seconds",
            "30",
            "--maximum-seconds",
            &guardian_maximum,
        ])
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(stderr));
    unsafe {
        command.pre_exec(|| {
            if libc_setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command
        .spawn()
        .map_err(|error| format!("could not spawn persistent guardian: {error}"))?;
    let mut child = OwnedSessionChild::new(child, "persistent guardian");
    let pid = child.id();
    let cleanup_deadline = Instant::now() + Duration::from_secs(30);
    let input = match child.stdin.take() {
        Some(value) => value,
        None => {
            let cleanup = terminate_preconfigured_session(
                &mut child,
                pid,
                "persistent guardian",
                cleanup_deadline,
            );
            return Err(format!("guardian stdin unavailable; cleanup={cleanup:?}"));
        }
    };
    let stdout = match child.stdout.take() {
        Some(value) => value,
        None => {
            drop(input);
            let cleanup = terminate_preconfigured_session(
                &mut child,
                pid,
                "persistent guardian",
                cleanup_deadline,
            );
            return Err(format!("guardian stdout unavailable; cleanup={cleanup:?}"));
        }
    };
    let lines = spawn_line_reader(stdout, 160, "persistent guardian response");
    let ready = match lines.recv_timeout(Duration::from_secs(15)) {
        Ok(Ok(value)) => value,
        other => {
            drop(input);
            let cleanup = terminate_preconfigured_session(
                &mut child,
                pid,
                "persistent guardian",
                cleanup_deadline,
            );
            return Err(format!(
                "persistent guardian readiness failed: {other:?}; cleanup={cleanup:?}"
            ));
        }
    };
    if ready != "GUARDIAN_BROKER_READY"
        || unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        drop(input);
        let cleanup = terminate_preconfigured_session(
            &mut child,
            pid,
            "persistent guardian",
            cleanup_deadline,
        );
        return Err(format!(
            "persistent guardian did not establish its exact session; cleanup={cleanup:?}"
        ));
    }
    let _start_identity = match process_start_identity(pid) {
        Ok(value) => value,
        Err(error) => {
            drop(input);
            let cleanup = terminate_preconfigured_session(
                &mut child,
                pid,
                "persistent guardian",
                cleanup_deadline,
            );
            return Err(format!(
                "persistent guardian start identity failed: {error}; cleanup={cleanup:?}"
            ));
        }
    };
    let mut guardian = GuardianBroker {
        child,
        input: Some(input),
        lines,
        transcript,
        reaped: false,
    };
    if let Err(error) = writeln!(guardian.transcript, "{ready}")
        .and_then(|_| guardian.transcript.sync_all())
    {
        let cleanup = finish_guardian(&mut guardian);
        return Err(format!(
            "persistent guardian transcript initialization failed: {error}; cleanup={cleanup:?}"
        ));
    }
    Ok(guardian)
}

fn uid_candidate_gate() -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    println!("LOCAL_CANDIDATE_GATE_ROOT_BOUND");
    std::io::stdout().flush().map_err(|error| error.to_string())?;
    let pid = unsafe { libc_getpid() } as u32;
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("candidate gate is not its own process-group/session leader".to_owned());
    }
    require_hash(Path::new(SEALED_HOST_EXECUTABLE), CANDIDATE_HOST_SHA256)?;
    require_exact_signature(
        Path::new(SEALED_HOST_APP),
        "com.elamin.AudioStreamer.CaptureServer",
        CANDIDATE_HOST_CDHASH,
        false,
    )?;
    println!("LOCAL_CANDIDATE_GATE_READY");
    std::io::stdout().flush().map_err(|error| error.to_string())?;
    let mut command_line = String::new();
    let read = std::io::stdin()
        .read_line(&mut command_line)
        .map_err(|error| format!("candidate gate command read failed: {error}"))?;
    if read == 0 {
        return Ok(());
    }
    if command_line != "GO_LOCAL_CANDIDATE_PREP_L1CIAB\n" {
        return Err("candidate gate rejected a malformed GO command".to_owned());
    }
    let layout = TrialLayout::fixed();
    let stdout = create_new_private(&layout.candidate_stdout)?;
    let stderr = create_new_private(&layout.candidate_stderr)?;
    let mut command = Command::new(SEALED_HOST_EXECUTABLE);
    command
        .args([
            "--worldwide",
            "--allow-remote-control",
            "--duration",
            "0",
            "--verbose",
            "--rendezvous-url",
            "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev",
        ])
        .env_clear()
        .env("LC_ALL", "C")
        .env("HOME", "/Users/ahmed")
        .env("USER", "ahmed")
        .env("LOGNAME", "ahmed")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("OSLogRateLimit", "64")
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    let error = command.exec();
    Err(format!("candidate gate could not exec the sealed host: {error}"))
}

fn finish_guardian(guardian: &mut GuardianBroker) -> Result<OwnedSessionTermination, String> {
    let pid = guardian.child.id();
    drop(guardian.input.take());
    let absolute_deadline =
        Instant::now() + Duration::from_secs(GUARDIAN_FINISH_ABSOLUTE_SECONDS);
    let natural_deadline = std::cmp::min(
        absolute_deadline,
        Instant::now() + Duration::from_secs(GUARDIAN_NATURAL_REAP_SECONDS),
    );
    let mut diagnostics = Vec::new();
    while Instant::now() < natural_deadline {
        match owned_session_ready_to_reap(&guardian.child, pid, absolute_deadline) {
            Ok(true) => match reap_quiescent_owned_session(
                &mut guardian.child,
                pid,
                "persistent guardian",
                absolute_deadline,
            ) {
                Ok(status) => {
                    guardian.reaped = true;
                    return Ok(OwnedSessionTermination {
                        status,
                        diagnostics,
                    });
                }
                Err(error) => push_session_diagnostic(
                    &mut diagnostics,
                    "NATURAL_REAP",
                    error,
                ),
            },
            Ok(false) => {}
            Err(error) => {
                push_session_diagnostic(&mut diagnostics, "NATURAL_BARRIER", error);
                break;
            }
        }
        sleep_capped_by_absolute_deadline(natural_deadline, Duration::from_millis(50));
    }
    match retained_child_exited_without_reap(&guardian.child) {
        Ok(_) => {}
        Err(error) => push_session_diagnostic(&mut diagnostics, "WAITID", error),
    }
    let mut outcome = terminate_preconfigured_session(
        &mut guardian.child,
        pid,
        "persistent guardian",
        absolute_deadline,
    )?;
    outcome.diagnostics.splice(0..0, diagnostics);
    guardian.reaped = true;
    Ok(outcome)
}

fn run_mirror_probe_until(outer_deadline: Instant) -> Result<(), String> {
    let entry_deadline = Instant::now()
        .checked_add(Duration::from_secs(MIRROR_PROBE_PRIMITIVE_SECONDS))
        .ok_or("mirror probe internal deadline overflowed")?;
    if outer_deadline < entry_deadline {
        return Err("mirror probe lacks its full transitive deadline reserve".to_owned());
    }
    let deadline = std::cmp::min(outer_deadline, entry_deadline);
    let layout = TrialLayout::fixed();
    let stderr_write_deadline = deadline
        .checked_sub(Duration::from_secs(MIRROR_PROBE_JSON_PRIMITIVE_SECONDS))
        .ok_or("mirror probe cannot reserve its JSON validation")?;
    let stdout_write_deadline = stderr_write_deadline
        .checked_sub(Duration::from_secs(
            MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS,
        ))
        .ok_or("mirror probe cannot reserve its stderr publication")?;
    let execution_deadline = stdout_write_deadline
        .checked_sub(Duration::from_secs(
            MIRROR_PROBE_SINGLE_OUTPUT_WRITE_PRIMITIVE_SECONDS,
        ))
        .ok_or("mirror probe cannot reserve its stdout publication")?;
    let hash_deadline = execution_deadline
        .checked_sub(Duration::from_secs(MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS))
        .ok_or("mirror probe cannot reserve its executable run")?;
    let observed_hash = sha256_until(
        Path::new(SEALED_MIRROR_PROBE),
        hash_deadline,
        MIRROR_PROBE_HASH_SECONDS,
        "deadline-aware sealed mirror probe hash",
    )?;
    if observed_hash != MIRROR_PROBE_SHA256 || Instant::now() >= hash_deadline {
        return Err("deadline-aware sealed mirror probe hash changed".to_owned());
    }
    let execution_remaining = execution_deadline
        .checked_duration_since(Instant::now())
        .ok_or("mirror probe execution deadline expired")?;
    let execution_timeout = execution_remaining
        .checked_sub(Duration::from_secs(MIRROR_PROBE_TEARDOWN_SECONDS))
        .map(|value| {
            std::cmp::min(
                value,
                Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS),
            )
        })
        .filter(|value| !value.is_zero())
        .ok_or("mirror probe lacks its process teardown reserve")?;
    let output = bounded_output(
        Command::new(SEALED_MIRROR_PROBE)
            .args([
                "mirror-loopback",
                "--nonce",
                "local-mono-prep-L1Ciab-mirror",
                "--required-headroom-seconds",
                "60",
                "--result",
                layout.mirror_result.to_str().ok_or("non-UTF-8 mirror result")?,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("HOME", "/Users/ahmed")
            .env("USER", "ahmed")
            .env("LOGNAME", "ahmed")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        execution_timeout,
        4 * 1_048_576,
        "installed-driver both-order mono loopback",
    )?;
    if Instant::now() >= execution_deadline {
        return Err("mirror probe exceeded its execution/teardown subdeadline".to_owned());
    }
    write_new_private_bytes(&layout.mirror_stdout, &output.stdout)?;
    if Instant::now() >= stdout_write_deadline {
        return Err("mirror stdout publication exceeded its subdeadline".to_owned());
    }
    write_new_private_bytes(&layout.mirror_stderr, &output.stderr)?;
    if Instant::now() >= stderr_write_deadline {
        return Err("mirror stderr publication exceeded its subdeadline".to_owned());
    }
    if !output.status.success() {
        return Err("installed-driver both-order mono loopback failed".to_owned());
    }
    verify_mirror_result_until(&layout.mirror_result, deadline)?;
    if Instant::now() >= deadline {
        return Err("mirror probe exhausted its absolute deadline".to_owned());
    }
    Ok(())
}

fn run_live_guardian_heartbeat_until(
    root: &mut RootClient,
    guardian: &mut GuardianBroker,
    outer_deadline: Instant,
) -> Result<(), String> {
    let local_deadline = std::cmp::min(
        outer_deadline,
        Instant::now()
            .checked_add(Duration::from_secs(
                LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS,
            ))
            .ok_or("live guardian/root heartbeat deadline overflowed")?,
    );
    let guardian_deadline = local_deadline
        .checked_sub(Duration::from_secs(LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS))
        .ok_or("live guardian heartbeat cannot reserve its final root exchange")?;
    let first_root_deadline = guardian_deadline
        .checked_sub(Duration::from_secs(LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS))
        .ok_or("live guardian heartbeat cannot reserve its guardian exchange")?;
    root.exchange_until(
        "L1Ciab PING",
        "LOCAL_ROOT_BROKER_PONG",
        first_root_deadline,
        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        "live pre-guardian root heartbeat",
    )?;
    guardian.exchange_until(
        "PING",
        "GUARDIAN_BROKER_PONG",
        guardian_deadline,
        Duration::from_secs(LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS),
        "live guardian heartbeat",
    )?;
    if Instant::now() >= guardian_deadline {
        return Err("live guardian heartbeat consumed the next root command reserve".to_owned());
    }
    root.exchange_until(
        "L1Ciab PING",
        "LOCAL_ROOT_BROKER_PONG",
        local_deadline,
        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        "live post-guardian root heartbeat",
    )?;
    if Instant::now() >= local_deadline {
        return Err("live guardian/root heartbeat exceeded its absolute deadline".to_owned());
    }
    Ok(())
}

fn arm_live_trial_until(
    layout: &TrialLayout,
    root: &mut RootClient,
    guardian: &mut GuardianBroker,
    candidate_pid: u32,
    deadline: Instant,
) -> Result<(), String> {
    let health_deadline = deadline
        .checked_sub(Duration::from_secs(
            LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS,
        ))
        .ok_or("live-arm transition cannot reserve its guardian/root heartbeat")?;
    let evidence_deadline = health_deadline
        .checked_sub(Duration::from_secs(LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS))
        .ok_or("live-arm transition cannot reserve its first candidate health exchange")?;
    let journal_deadline = evidence_deadline
        .checked_sub(Duration::from_secs(
            LIVE_ARM_SINGLE_EVIDENCE_WRITE_PRIMITIVE_SECONDS,
        ))
        .ok_or("live-arm transition cannot reserve its result publication")?;
    append_journal(layout, &format!("LOCAL_CANDIDATE_READY pid={candidate_pid}"))?;
    if Instant::now() >= journal_deadline {
        return Err("live-arm journal publication exceeded its subdeadline".to_owned());
    }
    append_private_line(
        &layout.result,
        &format!("LOCAL_MONO_TRIAL_READY candidate_pid={candidate_pid} automatic_rollback=true"),
    )?;
    if Instant::now() >= evidence_deadline {
        return Err("live-arm result publication exceeded its subdeadline".to_owned());
    }
    let response = root.request_until(
        &format!("L1Ciab CANDIDATE_HEALTH {candidate_pid}"),
        health_deadline,
        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        "live-arm candidate health",
    )?;
    if response != format!("LOCAL_ROOT_BROKER_CANDIDATE_HEALTHY pid={candidate_pid}") {
        return Err("root broker did not prove the retained candidate generation while arming live evidence".to_owned());
    }
    run_live_guardian_heartbeat_until(root, guardian, deadline)?;
    if Instant::now() >= deadline {
        return Err("live-arm transition exceeded its absolute deadline".to_owned());
    }
    Ok(())
}

fn stop_request_present() -> Result<bool, String> {
    match fs::symlink_metadata(STOP_REQUEST) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("could not inspect stop request: {error}")),
        Ok(_) => {
            let value = read_bounded_utf8(Path::new(STOP_REQUEST), 128, 501, 0o600)?;
            if value != "STOP_LOCAL_MONO_TRIAL_PREP_L1CIAB\n" {
                return Err("local-trial stop request is malformed".to_owned());
            }
            Ok(true)
        }
    }
}

fn validate_active_pointer_text(
    text: &str,
    expected_pid: u32,
    expected_start: &str,
) -> Result<(), String> {
    if !text.ends_with('\n') {
        return Err("active local-trial pointer is not newline terminated".to_owned());
    }
    let lines = text.lines().collect::<Vec<_>>();
    if lines.len() != 6
        || lines[0] != "schema=opensteamer.local-mono-trial-pointer.v1"
        || lines[1] != format!("trial_root={TRIAL_ROOT}")
        || lines[2] != "state=arming"
        || lines[3] != format!("proxy_pid={expected_pid}")
        || lines[4] != format!("proxy_start={expected_start}")
        || lines[5] != "state=armed"
    {
        return Err("active local-trial pointer does not bind the exact root-owned proxy".to_owned());
    }
    Ok(())
}

fn validate_result_before_finalization(text: &str) -> Result<bool, String> {
    if !text.is_empty() && !text.ends_with('\n') {
        return Err("local-trial result is not newline terminated".to_owned());
    }
    let mut ready_count = 0_u32;
    let mut failed_count = 0_u32;
    let mut rolled_back_count = 0_u32;
    for line in text.lines() {
        if let Some(candidate) = line
            .strip_prefix("LOCAL_MONO_TRIAL_READY candidate_pid=")
            .and_then(|value| value.strip_suffix(" automatic_rollback=true"))
        {
            let valid_pid = candidate
                .parse::<u32>()
                .ok()
                .is_some_and(|value| value > 0);
            if !valid_pid {
                return Err("local-trial result has a malformed ready PID".to_owned());
            }
            ready_count += 1;
        } else if let Some(error) = line.strip_prefix("LOCAL_MONO_TRIAL_FAILED ") {
            if error.is_empty()
                || line.len() > 512
                || error.bytes().any(|byte| byte == 0 || byte == b'\r' || byte == b'\n')
            {
                return Err("local-trial result has a malformed failure record".to_owned());
            }
            failed_count += 1;
        } else if line == "LOCAL_MONO_TRIAL_ROLLED_BACK" {
            rolled_back_count += 1;
        } else {
            return Err("local-trial result contains an unreviewed record".to_owned());
        }
    }
    if ready_count > 1 || failed_count > 1 || rolled_back_count > 1 {
        return Err("local-trial result contains duplicate terminal records".to_owned());
    }
    Ok(rolled_back_count == 1)
}

fn exact_armed_user_evidence_present() -> Result<bool, String> {
    match fs::symlink_metadata(ACTIVE_POINTER) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("could not inspect active local-trial pointer: {error}")),
        Ok(_) => {}
    }
    let (expected_pid, expected_start) = read_root_proxy_identity()?;
    let pointer = read_bounded_utf8(Path::new(ACTIVE_POINTER), 4_096, 501, 0o600)?;
    validate_active_pointer_text(&pointer, expected_pid, &expected_start)?;
    let result = read_bounded_utf8(&TrialLayout::fixed().result, 16_384, 501, 0o600)?;
    let _ = validate_result_before_finalization(&result)?;
    Ok(true)
}

fn remove_incomplete_active_pointer_temp_if_present() -> Result<(), String> {
    let path = Path::new(ACTIVE_POINTER_TEMP);
    let named = match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("could not inspect active-pointer temp: {error}")),
        Ok(metadata) => metadata,
    };
    if !named.is_file()
        || named.file_type().is_symlink()
        || named.uid() != 501
        || named.nlink() != 1
        || named.mode() & 0o777 != 0o600
    {
        return Err("active-pointer temp metadata is unsafe".to_owned());
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("could not open active-pointer temp: {error}"))?;
    let descriptor = file.metadata().map_err(|error| error.to_string())?;
    let adjacent = match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
        Ok(metadata) => metadata,
    };
    if descriptor.dev() != named.dev()
        || descriptor.ino() != named.ino()
        || adjacent.dev() != named.dev()
        || adjacent.ino() != named.ino()
        || adjacent.len() != named.len()
    {
        return Err("active-pointer temp changed before cleanup".to_owned());
    }
    drop(file);
    match fs::remove_file(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
        Ok(()) => {}
    }
    sync_parent_directory(path)?;
    require_absent_no_follow(path, "active-pointer temp after cleanup")
}

fn remove_exact_active_pointer_if_present() -> Result<(), String> {
    match fs::symlink_metadata(ACTIVE_POINTER) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("could not inspect active local-trial pointer: {error}")),
        Ok(_) => {}
    }
    let (expected_pid, expected_start) = read_root_proxy_identity()?;
    let before = fs::symlink_metadata(ACTIVE_POINTER).map_err(|error| error.to_string())?;
    let text = read_bounded_utf8(Path::new(ACTIVE_POINTER), 4_096, 501, 0o600)?;
    validate_active_pointer_text(&text, expected_pid, &expected_start)?;
    let adjacent = fs::symlink_metadata(ACTIVE_POINTER).map_err(|error| error.to_string())?;
    if before.dev() != adjacent.dev()
        || before.ino() != adjacent.ino()
        || before.len() != adjacent.len()
    {
        return Err("active local-trial pointer changed before removal".to_owned());
    }
    fs::remove_file(ACTIVE_POINTER).map_err(|error| error.to_string())?;
    sync_parent_directory(Path::new(ACTIVE_POINTER))?;
    require_absent_no_follow(Path::new(ACTIVE_POINTER), "active pointer after removal")
}

fn uid_finalize_local_trial_evidence() -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    configure_imported_command_limit_for_mode(UID_FINALIZE_EVIDENCE_MODE, true)?;
    require_absent_no_follow(Path::new(PRODUCT_DRIVER), "product driver before finalization")?;
    require_absent_no_follow(
        Path::new(ACTIVE_POINTER_TEMP),
        "active-pointer temp before finalization",
    )?;
    v7_controller::paired_v7::local_trial_verify_exact_v6_admission()?;
    require_healthy_admission_imported_count()?;
    let layout = TrialLayout::fixed();
    let result = read_bounded_utf8(&layout.result, 16_384, 501, 0o600)?;
    if !validate_result_before_finalization(&result)? {
        append_private_line(&layout.result, "LOCAL_MONO_TRIAL_ROLLED_BACK")?;
    }
    remove_exact_active_pointer_if_present()
}

fn uid_proxy_transaction() -> Result<(), String> {
    verify_root_supervised_uid_helper()?;
    let pid = unsafe { libc_getpid() } as u32;
    if unsafe { libc_getpgid(pid as i32) } != pid as i32
        || unsafe { libc_getsid(pid as i32) } != pid as i32
    {
        return Err("UID proxy is not its own process-group/session leader".to_owned());
    }
    wait_for_proxy_arm()?;
    run_bounded_uid_admission()?;
    let layout = TrialLayout::fixed();
    let mut guardian = spawn_persistent_guardian()?;
    let guardian_pid = guardian.child.id();
    if let Err(marker_error) = publish_guardian_spawned_on_root_capability(guardian_pid) {
        let cleanup = finish_guardian(&mut guardian);
        if cleanup.is_ok() {
            let _ = publish_guardian_reaped_on_root_capability(guardian_pid);
        }
        return Err(format!(
            "guardian spawn capability publication failed: {marker_error}; cleanup={cleanup:?}"
        ));
    }
    let transaction = (|| -> Result<(), String> {
    let mut root = RootClient::connect()?;
    let state_hash = stable_private_sha256(&layout.guardian_state)?;
    root.exchange_with_timeout(
        &format!("L1Ciab GUARDIAN_STATE {guardian_pid} {state_hash}"),
        "LOCAL_ROOT_BROKER_GUARDIAN_BOUND",
        Duration::from_secs(ROOT_GUARDIAN_BIND_RESPONSE_SECONDS),
    )?;
    let gate_response = root.request_with_timeout(
        "L1Ciab CANDIDATE_GATE",
        Duration::from_secs(ROOT_GATE_RESPONSE_SECONDS),
    )?;
    let candidate_pid = gate_response
        .strip_prefix("LOCAL_ROOT_BROKER_CANDIDATE_GATE_TRACKED pid=")
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|value| *value > 0)
        .ok_or("root broker returned a malformed candidate-gate identity")?;
    guardian.exchange("CHECK", "GUARDIAN_BROKER_CHECKED")?;
    root.exchange_with_timeout(
        "L1Ciab PRESTOP_FENCE",
        "LOCAL_ROOT_BROKER_PRESTOP_FENCED",
        Duration::from_secs(ROOT_PRESTOP_RESPONSE_SECONDS),
    )?;
    if stop_request_present()? {
        return Err("local trial was stopped before its destructive boundary".to_owned());
    }
    root.exchange_with_timeout(
        "L1Ciab V6_STOP_INTENT",
        "LOCAL_ROOT_BROKER_V6_STOPPED",
        Duration::from_secs(ROOT_STOP_RESPONSE_SECONDS),
    )?;
    guardian.exchange("PING", "GUARDIAN_BROKER_PONG")?;
    root.ping()?;
    root.exchange_with_timeout(
        "L1Ciab PUBLISH",
        "LOCAL_ROOT_BROKER_DRIVER_PUBLISHED_AND_RELOADED",
        Duration::from_secs(ROOT_PUBLISH_RESPONSE_SECONDS),
    )?;
    let post_publish_fence_deadline = Instant::now()
        .checked_add(Duration::from_secs(POST_PUBLISH_FENCE_PRIMITIVE_SECONDS))
        .ok_or("post-publish fence absolute deadline overflowed")?;
    let post_publish_local_deadline = post_publish_fence_deadline
        .checked_sub(Duration::from_secs(
            POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS,
        ))
        .ok_or("post-publish fence cannot reserve its root exchange")?;
    let post_publish_guardian_deadline = post_publish_local_deadline
        .checked_sub(Duration::from_secs(
            POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS,
        ))
        .ok_or("post-publish fence cannot reserve its local reproof")?;
    guardian.exchange_until(
        "POST_PUBLISH_FENCE",
        "GUARDIAN_BROKER_POST_PUBLISH_FENCED",
        post_publish_guardian_deadline,
        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        "post-publish guardian fence",
    )?;
    if Instant::now() >= post_publish_guardian_deadline {
        return Err("post-publish guardian fence exceeded its absolute subdeadline".to_owned());
    }
    let post_publish_evidence_deadline = post_publish_local_deadline
        .checked_sub(Duration::from_secs(
            GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS,
        ))
        .ok_or("post-publish fence cannot reserve its stable hash")?;
    let post_publish_parent_sync_deadline = post_publish_evidence_deadline
        .checked_sub(Duration::from_secs(GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS))
        .ok_or("post-publish fence cannot reserve its evidence validation")?;
    sync_parent_directory(&layout.guardian_post_publish_fence_result)?;
    if Instant::now() >= post_publish_parent_sync_deadline {
        return Err(
            "post-publish fence parent sync exceeded its absolute subdeadline".to_owned(),
        );
    }
    let verified_post_publish_fence_hash = verify_guardian_evidence_until(
        &layout.guardian_post_publish_fence_result,
        "broker-post-publish-fence",
        false,
        true,
        post_publish_evidence_deadline,
    )?;
    let post_publish_fence_hash = stable_private_sha256_until(
        &layout.guardian_post_publish_fence_result,
        post_publish_local_deadline,
    )?;
    if post_publish_fence_hash != verified_post_publish_fence_hash {
        return Err("guardian post-publish fence changed before root binding".to_owned());
    }
    root.exchange_until(
        &format!("L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}"),
        "LOCAL_ROOT_BROKER_POST_PUBLISH_FENCED",
        post_publish_fence_deadline,
        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        "post-publish root fence",
    )?;
    if Instant::now() >= post_publish_fence_deadline {
        return Err("post-publish root fence exceeded its absolute deadline".to_owned());
    }
    root.ping()?;
    guardian.exchange("PING", "GUARDIAN_BROKER_PONG")?;
    let mirror_probe_deadline = Instant::now()
        .checked_add(Duration::from_secs(MIRROR_PROBE_CALL_PRIMITIVE_SECONDS))
        .ok_or("mirror probe absolute deadline overflowed")?;
    run_mirror_probe_until(mirror_probe_deadline)?;
    root.ping()?;
    guardian.exchange("RUN_VPIO", "GUARDIAN_BROKER_VPIO_PASSED")?;
    root.exchange_with_timeout(
        "L1Ciab PROBES_VERIFIED",
        "LOCAL_ROOT_BROKER_PROBES_VERIFIED",
        Duration::from_secs(ROOT_PROBES_RESPONSE_SECONDS),
    )?;
    guardian.exchange("PING", "GUARDIAN_BROKER_PONG")?;

    let live_response = root.request_with_timeout(
        "L1Ciab RELEASE_CANDIDATE_GATE",
        Duration::from_secs(ROOT_CANDIDATE_RESPONSE_SECONDS),
    )?;
    if live_response != format!("LOCAL_ROOT_BROKER_CANDIDATE_LIVE_TRACKED pid={candidate_pid}") {
        return Err("root broker released a different candidate identity".to_owned());
    }
    let live_arm_deadline = Instant::now()
        .checked_add(Duration::from_secs(LIVE_ARM_PRIMITIVE_SECONDS))
        .ok_or("live-arm transition deadline overflowed")?;
    arm_live_trial_until(
        &layout,
        &mut root,
        &mut guardian,
        candidate_pid,
        live_arm_deadline,
    )?;

    let automatic_stop = Instant::now() + Duration::from_secs(600);
    let mut next_heartbeat = Instant::now() + Duration::from_secs(20);
    let mut next_candidate_health = Instant::now();
    while Instant::now() < automatic_stop {
        if stop_request_present()? {
            break;
        }
        if Instant::now() >= next_candidate_health {
            let response = root.request_with_timeout(
                &format!("L1Ciab CANDIDATE_HEALTH {candidate_pid}"),
                Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
            )?;
            if response != format!("LOCAL_ROOT_BROKER_CANDIDATE_HEALTHY pid={candidate_pid}") {
                return Err("root broker did not prove the retained candidate generation".to_owned());
            }
            next_candidate_health = Instant::now() + Duration::from_secs(1);
        }
        if Instant::now() >= next_heartbeat {
            let heartbeat_deadline = Instant::now()
                .checked_add(Duration::from_secs(
                    LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS,
                ))
                .ok_or("live heartbeat deadline overflowed")?;
            run_live_guardian_heartbeat_until(
                &mut root,
                &mut guardian,
                heartbeat_deadline,
            )?;
            next_heartbeat = Instant::now() + Duration::from_secs(20);
        }
        thread::sleep(Duration::from_millis(100));
    }

    root.exchange_with_timeout(
        "L1Ciab CANDIDATE_STOPPED",
        "LOCAL_ROOT_BROKER_CANDIDATE_ABSENT",
        Duration::from_secs(ROOT_CANDIDATE_STOP_RESPONSE_SECONDS),
    )?;
    let guardian_reaped_transition_deadline = Instant::now()
        .checked_add(Duration::from_secs(
            GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS,
        ))
        .ok_or("guardian-reaped transition deadline overflowed")?;
    let guardian_reaped_command_deadline = guardian_reaped_transition_deadline
        .checked_sub(Duration::from_secs(LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS))
        .ok_or("guardian-reaped transition cannot reserve its full root exchange")?;
    guardian.exchange("REPAIR", "GUARDIAN_BROKER_REPAIRED")?;
    guardian.exchange("STOP", "GUARDIAN_BROKER_STOPPED")?;
    let guardian_outcome = finish_guardian(&mut guardian)?;
    publish_guardian_reaped_on_root_capability(guardian_pid)?;
    if !guardian_outcome.diagnostics.is_empty() {
        append_journal(
            &layout,
            &format!(
                "GUARDIAN_REAPED_WITH_DIAGNOSTICS {}",
                guardian_outcome.diagnostics.join(" | ")
            ),
        )?;
    }
    if Instant::now() >= guardian_reaped_command_deadline {
        return Err("guardian-reaped transition consumed its root command/response reserve".to_owned());
    }
    root.exchange_until(
        &format!("L1Ciab GUARDIAN_REAPED {guardian_pid}"),
        "LOCAL_ROOT_BROKER_GUARDIAN_REAPED",
        guardian_reaped_transition_deadline,
        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),
        "guardian-reaped root acknowledgement",
    )?;
    if Instant::now() >= guardian_reaped_transition_deadline {
        return Err("guardian-reaped transition exceeded its absolute deadline".to_owned());
    }
    root.exchange_with_timeout(
        "L1Ciab ROUTES_REPAIRED",
        "LOCAL_ROOT_BROKER_ROUTES_REPAIRED",
        Duration::from_secs(ROOT_ROUTES_RESPONSE_SECONDS),
    )?;
    root.exchange_with_timeout(
        "L1Ciab ROLLBACK",
        "LOCAL_ROOT_BROKER_DRIVER_ROLLED_BACK",
        Duration::from_secs(ROOT_ROLLBACK_RESPONSE_SECONDS),
    )?;
    root.exchange_with_timeout(
        "L1Ciab RESTORE_V6",
        "LOCAL_ROOT_BROKER_V6_RESTORED",
        Duration::from_secs(ROOT_RESTORE_RESPONSE_SECONDS),
    )?;
    root.exchange_with_timeout(
        "L1Ciab COMPLETE",
        "LOCAL_ROOT_BROKER_COMPLETE",
        Duration::from_secs(UID_FINALIZE_EVIDENCE_HELPER_SECONDS + 120),
    )?;
    Ok(())
    })();
    if let Err(error) = transaction {
        if guardian.reaped {
            return Err(error);
        }
        let cleanup = finish_guardian(&mut guardian);
        if cleanup.is_ok() {
            let _ = publish_guardian_reaped_on_root_capability(guardian.child.id());
        }
        return Err(format!(
            "{error}; retained guardian finally cleanup={cleanup:?}"
        ));
    }
    Ok(())
}

fn uid_local_trial_guardian() -> Result<(), String> {
    let result = uid_proxy_transaction();
    if let Err(error) = &result {
        let safe = error.replace(['\n', '\r', '\0'], " ");
        let _ = append_private_line(
            &TrialLayout::fixed().result,
            &format!("LOCAL_MONO_TRIAL_FAILED {safe}"),
        );
    }
    result
}

unsafe extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
    #[link_name = "geteuid"]
    fn libc_geteuid() -> u32;
    #[link_name = "setgroups"]
    fn libc_setgroups(count: i32, groups: *const u32) -> i32;
    #[link_name = "setgid"]
    fn libc_setgid(gid: u32) -> i32;
    #[link_name = "setuid"]
    fn libc_setuid(uid: u32) -> i32;
    #[link_name = "renameatx_np"]
    fn libc_renameatx_np(
        from_fd: i32,
        from: *const std::ffi::c_char,
        to_fd: i32,
        to: *const std::ffi::c_char,
        flags: u32,
    ) -> i32;
    #[link_name = "kill"]
    fn libc_kill(pid: i32, signal: i32) -> i32;
    #[link_name = "getpid"]
    fn libc_getpid() -> i32;
    #[link_name = "getppid"]
    fn libc_getppid() -> i32;
    #[link_name = "setsid"]
    fn libc_setsid() -> i32;
    #[link_name = "getsid"]
    fn libc_getsid(pid: i32) -> i32;
    #[link_name = "getpgrp"]
    fn libc_getpgrp() -> i32;
    #[link_name = "getpgid"]
    fn libc_getpgid(pid: i32) -> i32;
    #[link_name = "getpeereid"]
    fn libc_getpeereid(socket: i32, uid: *mut u32, gid: *mut u32) -> i32;
    #[link_name = "getsockopt"]
    fn libc_getsockopt(
        socket: i32,
        level: i32,
        option_name: i32,
        option_value: *mut std::ffi::c_void,
        option_length: *mut u32,
    ) -> i32;
    #[link_name = "flock"]
    fn libc_flock(file_descriptor: i32, operation: i32) -> i32;
    #[link_name = "proc_listallpids"]
    fn libc_proc_listallpids(buffer: *mut std::ffi::c_void, buffer_size: i32) -> i32;
    #[link_name = "waitid"]
    fn libc_waitid(
        id_type: i32,
        id: u32,
        info: *mut DarwinSigInfo,
        options: i32,
    ) -> i32;
}

#[link(name = "proc")]
unsafe extern "C" {
    #[link_name = "proc_pidinfo"]
    fn libc_proc_pidinfo(
        pid: i32,
        flavor: i32,
        argument: u64,
        buffer: *mut std::ffi::c_void,
        buffer_size: i32,
    ) -> i32;
    #[link_name = "proc_pidpath"]
    fn libc_proc_pidpath(
        pid: i32,
        buffer: *mut std::ffi::c_void,
        buffer_size: u32,
    ) -> i32;
}

fn live_disabled(mode: &str) -> ExitCode {
    eprintln!(
        "{mode} is disabled: the detached uid501 guardian and root deadman rollback path are not yet release-audited"
    );
    ExitCode::from(EX_CONFIG)
}

fn live_release_enabled() -> bool {
    LIVE_RELEASE_STATUS == LIVE_RELEASE_READY
}

fn run_release_gated(mode: &str, operation: impl FnOnce() -> Result<(), String>) -> ExitCode {
    if !live_release_enabled() {
        return live_disabled(mode);
    }
    match operation() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{mode} failed closed: {error}");
            ExitCode::from(EX_SOFTWARE)
        }
    }
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: opensteamer-host-local-mono-trial-controller {SELF_TEST_MODE}|{PREFLIGHT_MODE}|{PREFLIGHT_KNOWN_FAILED_BOOTSTRAP_MODE}"
    );
    ExitCode::from(EX_USAGE)
}

fn main() -> ExitCode {
    let arguments: Vec<String> = env::args().collect();
    match arguments.as_slice() {
        [_, mode] if mode == SELF_TEST_MODE => match self_test() {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("LOCAL_MONO_TRIAL_SELF_TEST_FAILED: {error}");
                ExitCode::from(EX_SOFTWARE)
            }
        },
        [_, mode] if mode == PREFLIGHT_MODE => match preflight(false) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("LOCAL_MONO_TRIAL_PREFLIGHT_FAILED: {error}");
                ExitCode::from(EX_UNAVAILABLE)
            }
        },
        [_, mode] if mode == PREFLIGHT_KNOWN_FAILED_BOOTSTRAP_MODE => match preflight(true) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("LOCAL_MONO_TRIAL_PREFLIGHT_FAILED: {error}");
                ExitCode::from(EX_UNAVAILABLE)
            }
        },
        [_, mode] if mode == ROOT_MODE => run_release_gated(mode, root_broker),
        [_, mode] if mode == START_MODE => run_release_gated(mode, start_local_trial),
        [_, mode] if mode == STOP_MODE => run_release_gated(mode, stop_local_trial),
        [_, mode] if mode == UID_GUARDIAN_MODE => {
            run_release_gated(mode, uid_local_trial_guardian)
        }
        [_, mode] if mode == UID_ADMISSION_MODE => {
            run_release_gated(mode, uid_verify_exact_v6_admission)
        }
        [_, mode] if mode == UID_VERIFY_HAL_MODE => {
            run_release_gated(mode, uid_verify_product_hal_absent)
        }
        [_, mode] if mode == UID_EMERGENCY_V6_MODE => {
            run_release_gated(mode, uid_emergency_restore_v6)
        }
        [_, mode] if mode == UID_FINALIZE_EVIDENCE_MODE => {
            run_release_gated(mode, uid_finalize_local_trial_evidence)
        }
        [_, mode] if mode == UID_STOP_V6_MODE => {
            run_release_gated(mode, uid_stop_exact_v6)
        }
        [_, mode, pid] if mode == UID_VERIFY_CANDIDATE_MODE => {
            run_release_gated(mode, || uid_verify_candidate_ready(pid))
        }
        [_, mode] if mode == UID_CANDIDATE_GATE_MODE => {
            run_release_gated(mode, uid_candidate_gate)
        }
        [_, mode, state_hash] if mode == UID_EMERGENCY_REPAIR_MODE => {
            run_release_gated(mode, || uid_emergency_route_repair(state_hash))
        }
        [_, mode] if mode == UID_PRESTOP_REPAIR_MODE => live_disabled(mode),
        [_] => usage(),
        _ => {
            let _ = EX_NOINPUT;
            usage()
        }
    }
}
