import Foundation
import XCTest

/// Executes the Rust controller's shared transition engine against both its deterministic fake
/// backend and its guarded disposable real-filesystem/real-command adapter. The adapter rejects
/// live paths and never touches launchd, /Applications, the live runtime lock, or devices.
final class MacHostMigrationContractTests: XCTestCase {
    private struct ProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var diagnostic: String {
            "status=\(status)\nstdout:\n\(standardOutput)\nstderr:\n\(standardError)"
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testControllerCompilesWithWarningsDeniedAndExecutableRecoveryMatrixPasses() throws {
        let binary = try compileController()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }

        let cases = [
            "all",
            "crash",
            "faults",
            "rollback",
            "readiness",
            "concurrency",
            "journal",
            "publication",
            "disable",
            "committed",
            "active-pointer",
            "side-effects",
            "parsers",
            "zsh-verifiers",
            "generation-race",
            "deadlines",
            "modes",
            "real-adapter",
        ]
        for testCase in cases {
            let result = try run(
                executable: binary,
                arguments: ["--self-test", testCase]
            )
            XCTAssertEqual(result.status, 0, "Self-test \(testCase) failed.\n\(result.diagnostic)")
            XCTAssertEqual(
                result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                "SELF_TEST_OK \(testCase)",
                result.diagnostic
            )
        }
    }

    func testControllerRejectsMalformedLockProbeWithoutTouchingRuntime() throws {
        let binary = try compileController()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let result = try run(
            executable: binary,
            arguments: ["--probe-lock", "/var/tmp", "/var/tmp/not-an-immediate-child/lock", "0"]
        )
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.standardError.contains("expected lock-holder PID must be positive") ||
                result.standardError.contains("canonical shared runtime and lock"),
            result.diagnostic
        )
    }

    func testLauncherAlwaysBuildsFreshControllerWithPinnedCompilerAndNoExecutableCache() throws {
        let launcher = repositoryRoot.appendingPathComponent(
            "macOS/scripts/migrate-opensteamer-host.sh"
        )
        let source = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(source.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(source.contains("TRUSTED_RUSTC_LINK='/opt/homebrew/bin/rustc'"))
        XCTAssertTrue(
            source.contains(
                "TRUSTED_RUSTC_CANONICAL='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'"
            )
        )
        XCTAssertTrue(
            source.contains(
                "EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'"
            )
        )
        XCTAssertTrue(
            source.contains(
                "EXPECTED_RUSTC_CDHASH_FULL='d57b3f82fa576b65e91de0fb90358f766425c35e794feec402416bb666a5008e'"
            )
        )
        XCTAssertTrue(source.contains("mktemp -d"))
        XCTAssertTrue(source.contains("--edition=2021 -D warnings"))
        XCTAssertTrue(source.contains("/bin/ln \"$BINARY_BUILD\" \"$BINARY\""))
        XCTAssertTrue(source.contains("OPENSTEAMER_MIGRATION_CONTROLLER_BINARY"))
        XCTAssertTrue(source.contains("OPENSTEAMER_MIGRATION_RUSTC_CDHASH_FULL"))
        XCTAssertTrue(source.contains("PINNED_RUSTC=\"$BUILD_DIR/rustc\""))
        XCTAssertTrue(source.contains("TRUSTED_RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'"))
        XCTAssertTrue(source.contains("DYLD_LIBRARY_PATH=\"$PINNED_RUSTC_LIB\""))
        XCTAssertTrue(source.contains("--sysroot \"$TRUSTED_RUSTC_SYSROOT\""))
        XCTAssertTrue(
            source.contains("--remap-path-prefix \"$BUILD_DIR=$REVIEWED_BUILD_PREFIX\"")
        )
        XCTAssertTrue(
            source.contains(
                "EXPECTED_CONTROLLER_BINARY_SHA256='6214dbcf6c5aadcb5b4a5b9240c59f900ac45ee42e3c73bd1a7f0e223a3961fa'"
            )
        )
        XCTAssertTrue(source.contains("fresh controller binary differs from the reviewed reproducible postimage"))
        XCTAssertTrue(source.contains("--self-test-reviewed-controller-build"))
        XCTAssertTrue(source.contains("--verify-reviewed-prior-retry-state"))
        XCTAssertTrue(source.contains(".controller-build-v20.XXXXXX"))
        XCTAssertTrue(source.contains("SOURCE_COPY=\"$BUILD_DIR/opensteamer-host-migration-controller.rs\""))
        XCTAssertTrue(source.contains("copy_companion_script"))
        XCTAssertTrue(source.contains("verify_private_companion_script"))
        XCTAssertTrue(source.contains("EXPECTED_BUILD_SCRIPT_SHA256"))
        XCTAssertTrue(source.contains("EXPECTED_DEPLOYMENT_VERIFIER_SHA256"))
        XCTAssertTrue(
            source.contains(
                "EXPECTED_DEPLOYMENT_VERIFIER_SHA256='6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de'"
            )
        )
        XCTAssertTrue(source.contains("--self-test-cdhash-parser"))
        XCTAssertTrue(source.contains("CandidateCDHashFull sha256="))
        XCTAssertFalse(source.contains("CDHashFull="))
        let controllerSource = repositoryRoot.appendingPathComponent(
            "macOS/scripts/opensteamer-host-migration-controller.rs"
        )
        let sourceHashResult = try run(
            executable: URL(fileURLWithPath: "/usr/bin/shasum"),
            arguments: ["-a", "256", controllerSource.path]
        )
        XCTAssertEqual(sourceHashResult.status, 0, sourceHashResult.diagnostic)
        let sourceHash = try XCTUnwrap(
            sourceHashResult.standardOutput.split(whereSeparator: \.isWhitespace).first.map(String.init)
        )
        XCTAssertTrue(
            source.contains("EXPECTED_CONTROLLER_SOURCE_SHA256='\(sourceHash)'"),
            "Launcher source attestation is stale."
        )
        XCTAssertFalse(source.contains("controller-cache"))
        XCTAssertFalse(source.contains("command -v rustc"))
        XCTAssertFalse(source.contains("/Users/ahmed/.rustup/"))
        XCTAssertFalse(source.contains("/Users/ahmed/.cargo/bin/rustc"))
        XCTAssertFalse(source.contains("exec \"$BINARY\""))
        XCTAssertFalse(source.contains("launchctl bootout"))
        XCTAssertFalse(source.contains("launchctl bootstrap"))
        let legacyAppPath = "/Applications/Audio" + "Streamer Host.app"
        XCTAssertFalse(source.contains(legacyAppPath))

        let syntax = try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-n", launcher.path]
        )
        XCTAssertEqual(syntax.status, 0, syntax.diagnostic)
    }

    func testPostV20UpdaterHasPinnedCrashRecoverableJournalAndSafeSelfTest() throws {
        let controller = repositoryRoot.appendingPathComponent(
            "macOS/scripts/opensteamer-host-post-v20-update-controller.rs"
        )
        let launcher = repositoryRoot.appendingPathComponent(
            "macOS/scripts/update-opensteamer-host-post-v20.sh"
        )
        let controllerSource = try String(contentsOf: controller, encoding: .utf8)
        let launcherSource = try String(contentsOf: launcher, encoding: .utf8)

        for required in [
            "file.set_len(complete_length as u64)?;",
            "journal recovery accepted an incomplete final record",
            "journal recovery accepted a malformed complete record",
            "journal validation failure changed durable bytes",
            "poisoned journal allowed a later mutation",
            "post-v20 transaction lock allowed concurrent ownership",
            "journal_field_schema",
            "retired-active-pointer.txt",
            "rolled-back update pointer retirement was not durable",
            "rolled-back-recovered",
            "ensure_rolled_back_result",
            "rename_replacing(&pending, path)",
            "rolled-back result recovery did not atomically replace prior success",
            "exact retained staged host survived bounded SIGKILL wait",
            "staged rollback process topology self-test failed",
            "filename-aware shasum parser self-test failed",
            "parse_shasum_output",
            ".arg(\"--reset-worldwide-pairing\")",
            "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1",
            "staged pairing namespace is not isolated",
            "const OFFLINE_LEGACY_REFERENCE_MODE: u32 = 0o500;",
            "Path::new(OFFLINE_LEGACY_REFERENCE),\n        OFFLINE_LEGACY_REFERENCE_MODE,",
        ] {
            XCTAssertTrue(controllerSource.contains(required), "Post-v20 controller lacks \(required)")
        }
        XCTAssertFalse(controllerSource.contains("delete-generic-password"))

        let sourceHashResult = try run(
            executable: URL(fileURLWithPath: "/usr/bin/shasum"),
            arguments: ["-a", "256", controller.path]
        )
        XCTAssertEqual(sourceHashResult.status, 0, sourceHashResult.diagnostic)
        let sourceHash = try XCTUnwrap(
            sourceHashResult.standardOutput.split(whereSeparator: \.isWhitespace).first.map(String.init)
        )
        XCTAssertTrue(
            launcherSource.contains("EXPECTED_SOURCE_SHA256='\(sourceHash)'"),
            "Post-v20 launcher source attestation is stale."
        )

        let syntax = try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-n", launcher.path]
        )
        XCTAssertEqual(syntax.status, 0, syntax.diagnostic)

        let selfTest = try run(
            executable: launcher,
            arguments: ["--self-test-post-v20-host-update"]
        )
        XCTAssertEqual(selfTest.status, 0, selfTest.diagnostic)
        XCTAssertEqual(
            selfTest.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "SELF_TEST_OK post-v20-host-update-controller",
            selfTest.diagnostic
        )
    }

    func testMigrationSourcesContainNoForbiddenRuntimeAndUseExclusivePublicationAndDurableDisable() throws {
        let relativePaths = [
            "macOS/scripts/migrate-opensteamer-host.sh",
            "macOS/scripts/opensteamer-host-migration-controller.rs",
            "macOS/scripts/build-opensteamer-host-app.sh",
            "macOS/scripts/verify-mac-host-bundle.sh",
            "macOS/scripts/verify-mac-host-launch-state.sh",
            "macOS/scripts/verify-mac-host-deployment.sh",
            "macOS/scripts/verify-live-mac-host-process.sh",
            "macOS/Sources/CaptureServer/WorldwideHostProcessLock.swift",
            "macOS/Tests/CaptureServerTests/WorldwideHostProcessLockTests.swift",
            "macOS/Tests/CaptureServerTests/MacHostDeploymentContractTests.swift",
            "macOS/Tests/CaptureServerTests/MacHostBundleIdentityTests.swift",
            "macOS/Tests/CaptureServerTests/MacHostMigrationContractTests.swift",
        ]
        let forbiddenRuntime = "py" + "thon"
        for relative in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.lowercased().contains(forbiddenRuntime),
                "Rust-only migration target contains a forbidden scripting-runtime reference: \(relative)"
            )
        }

        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/opensteamer-host-migration-controller.rs"
            ),
            encoding: .utf8
        )
        for required in [
            "renameatx_np",
            "RENAME_EXCL_VALUE",
            "struct PinnedDirectory",
            "openat(",
            "O_EXCL_VALUE",
            "launchctl {action} legacy service",
            "print-disabled",
            "State::LegacyDisabled",
            "State::LegacyReenabled",
            "verify_committed_runtime",
            "drive_forward",
            "ForwardEffect::PublishApp",
            "ForwardEffect::PublishPlist",
            "drive_rollback",
            "RollbackOperation::ArchiveEvidence",
            "drive_committed_recovery",
            "CommittedRecoveryOperation::ObserveFreshMarker",
            "drive_active_pointer",
            "ActivePointerOperation::PublishPending",
            "State::CommittedRecoveryReady",
            "REVIEWED_RUSTC_SHA256",
            "REVIEWED_RUSTC_CDHASH_FULL",
            "FORWARD_PLAN",
            "FakeBackend",
            "journal truncation recovery",
            "exclusive publication overwrote",
            "pinned directory accepted pathname replacement",
            "LaunchGeneration",
            "process_start_identity",
            "parse_generation_record",
            "CheckpointGenerationLog",
            "checkpoint_prelaunch_log",
            "revalidate_log_checkpoint",
            "wait_for_exact_legacy_readiness",
            "self_test_generation_race",
            "self_test_command_deadlines",
            "self_test_directory_modes",
            "self_test_real_adapter",
            "assert_disposable_adapter_root",
            "O_NONBLOCK_VALUE",
            "Instant::now()",
            "setpgid",
            "terminate_process_group_and_reap",
            "set_pipe_nonblocking",
            "drain_nonblocking",
            "MAX_DRAIN_BYTES_PER_POLL",
            "canonical_command_timeout_error",
            "const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(60)",
            "const LEGACY_READINESS_TIMEOUT: Duration = DEFAULT_COMMAND_TIMEOUT",
            "const DEPLOYMENT_VERIFIER_TIMEOUT: Duration = Duration::from_secs(3 * 60)",
            "wait_for_exact_legacy_readiness_until",
            "revalidate_commit_fields",
            "CommitRacePoint::AfterVerifyEffect",
            "CommitRacePoint::DuringFieldCapture",
            "CommitRacePoint::AfterRevalidationBeforeDurableWrite",
            "CommitRacePoint::ImmediatelyAfterDurableWrite",
            "CommitRacePoint::BeforeRetainedActivePointerValidation",
            "EffectPhase::AfterCommitRevalidationBeforeDurableWrite",
            "EffectPhase::BeforeRetainedActivePointerValidation",
            "before_retained_active_pointer_validation",
            "RetainedActivePointerPhase::AfterInitialPointerValidation",
            "RetainedActivePointerPhase::AfterCommittedGenerationProof",
            "RetainedActivePointerPhase::AfterFinalPointerValidation",
            "verify_retained_active_pointer_after_commit",
            "durable COMMITTED journal record is the sole commit point",
            "self_test_final_generation_active_pointer_boundary",
            "const ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v20\";",
            "const ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v20.pending\";",
            "const ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v20.finalizing\";",
            "const ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v20.linearized\";",
            "const JOURNAL_VERSION: &str = \"OPENSTEAMER_MIGRATION_JOURNAL_V20\";",
            "const FAKE_JOURNAL_VERSION: &str = \"OPENSTEAMER_FAKE_MIGRATION_JOURNAL_V20\";",
            "const V20_EVIDENCE_PATH: &str",
            "parse_v20_active_record",
            "v20 active pointer selects unreviewed evidence",
            "InspectionTransactionLock",
            "inspect_active_pointer_read_only",
            "expected_online_marker_for_generation",
            "read_bounded_log_suffix_until",
            "wait_for_online_marker_for_generation_until",
            "revalidate_until",
            "readiness_deadline: Option<Instant>",
            "DEPLOYMENT_VERIFIER_REQUIRED_SYSTEM_COMMANDS",
            "verify_deployment_verifier_system_commands",
            "prove_generation_lock_held_only_by_until(expected, deadline)",
            "active-migration-v16",
            "active-migration-v15",
            "active-migration-v14",
            "active-migration-v13",
            "active-migration-v12",
            "active-migration-v11",
            "active-migration-v10",
            "active-migration-v9",
            "validate_prior_v9_prestop_retry",
            "PRIOR_PRESTOP_JOURNAL",
            "PRIOR_EVIDENCE_PATH",
            "PRIOR_SOURCE_ARCHIVE_SHA256",
            "PriorV9RetryGuard",
            "require_exact_directory_entries",
            "verify_chflags_tool",
            "Path::new(\"/usr/bin/chflags\")",
            "fn open_applications()",
            "directory_write_policy_allows",
            "validate_prior_v10_rolledback_retry",
            "validate_prior_v10_rolledback_records",
            "PriorV10RetryGuard",
            "PRIOR_V10_FINAL_JOURNAL",
            "PRIOR_V10_FINAL_JOURNAL_SHA256",
            "validate_prior_v11_rolledback_retry",
            "validate_prior_v11_rolledback_records",
            "PriorV11RetryGuard",
            "require_prior_retry_residues_absent",
            "require_all_prior_retry_residues_absent",
            "PRIOR_V11_FINAL_JOURNAL",
            "PRIOR_V11_FINAL_JOURNAL_SHA256",
            "PRIOR_V11_ROLLBACK_RESERVE_INODE",
            "validate_prior_v12_rolledback_retry",
            "validate_prior_v12_rolledback_records",
            "PriorV12RetryGuard",
            "PRIOR_V12_FINAL_JOURNAL",
            "PRIOR_V12_FINAL_JOURNAL_SHA256",
            "PRIOR_V12_ROLLBACK_RESERVE_INODE",
            "PRIOR_V12_STAGED_APP_MANIFEST_SHA256",
            "validate_prior_v13_rolledback_retry",
            "validate_prior_v13_rolledback_records",
            "PriorV13RetryGuard",
            "PRIOR_V13_FINAL_JOURNAL",
            "PRIOR_V13_FINAL_JOURNAL_SHA256",
            "PRIOR_V13_DEPLOYMENT_STDERR_SHA256",
            "PRIOR_V13_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V13_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V13_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v14_rolledback_retry",
            "validate_prior_v14_rolledback_records",
            "PriorV14RetryGuard",
            "PRIOR_V14_ACTIVE_TRANSACTION_NAME",
            "PRIOR_V14_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V14_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V14_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "PRIOR_V14_EVIDENCE_PATH",
            "PRIOR_V14_ACTIVE_RECORD",
            "PRIOR_V14_ACTIVE_SHA256",
            "PRIOR_V14_SOURCE_COMMIT",
            "PRIOR_V14_SOURCE_TREE",
            "PRIOR_V14_FINAL_JOURNAL",
            "PRIOR_V14_FINAL_JOURNAL_SHA256",
            "PRIOR_V14_FINAL_RESULT",
            "PRIOR_V14_FINAL_RESULT_SHA256",
            "PRIOR_V14_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V14_SOURCE_ARCHIVE_SHA256",
            "PRIOR_V14_PROVENANCE",
            "PRIOR_V14_PROVENANCE_SHA256",
            "PRIOR_V14_LEGACY_MANIFEST_SHA256",
            "PRIOR_V14_LEGACY_XATTRS_SHA256",
            "PRIOR_V14_STAGED_HASHES_SHA256",
            "PRIOR_V14_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V14_BUILD_STDOUT_SHA256",
            "PRIOR_V14_BUILD_STDERR_SHA256",
            "PRIOR_V14_DEPLOYMENT_STDOUT_SHA256",
            "PRIOR_V14_DEPLOYMENT_STDERR_SHA256",
            "PRIOR_V14_DEPLOYMENT_STDERR",
            "PRIOR_V14_ROLLBACK_RESERVE_SHA256",
            "PRIOR_V14_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V14_ROLLBACK_RESERVE_INODE",
            "PRIOR_V14_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V14_STAGED_PLIST_SHA256",
            "PRIOR_V14_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V14_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V14_STAGED_APP_XATTRS_SHA256",
            "PRIOR_V14_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v15_rolledback_retry",
            "validate_prior_v15_rolledback_records",
            "PriorV15RetryGuard",
            "PRIOR_V15_ACTIVE_TRANSACTION_NAME",
            "PRIOR_V15_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V15_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V15_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "PRIOR_V15_EVIDENCE_PATH",
            "PRIOR_V15_ACTIVE_RECORD",
            "PRIOR_V15_ACTIVE_SHA256",
            "PRIOR_V15_SOURCE_COMMIT",
            "PRIOR_V15_SOURCE_TREE",
            "PRIOR_V15_FINAL_JOURNAL_SIZE",
            "PRIOR_V15_FINAL_JOURNAL_SHA256",
            "PRIOR_V15_FINAL_RESULT",
            "PRIOR_V15_FINAL_RESULT_SHA256",
            "PRIOR_V15_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V15_SOURCE_ARCHIVE_SHA256",
            "PRIOR_V15_PROVENANCE",
            "PRIOR_V15_PROVENANCE_SHA256",
            "PRIOR_V15_LEGACY_MANIFEST_SHA256",
            "PRIOR_V15_LEGACY_XATTRS_SHA256",
            "PRIOR_V15_STAGED_HASHES_SHA256",
            "PRIOR_V15_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V15_BUILD_STDOUT_SHA256",
            "PRIOR_V15_BUILD_STDERR_SHA256",
            "PRIOR_V15_ROLLBACK_RESERVE_SHA256",
            "PRIOR_V15_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V15_ROLLBACK_RESERVE_INODE",
            "PRIOR_V15_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V15_STAGED_PLIST_SHA256",
            "PRIOR_V15_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V15_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V15_STAGED_APP_XATTRS_SHA256",
            "PRIOR_V15_FAILED_APP_XATTRS_SHA256",
            "require_prior_v15_deployment_records_absent",
            "validate_prior_v16_rolledback_retry",
            "validate_prior_v16_rolledback_records",
            "PriorV16RetryGuard",
            "PRIOR_V16_ACTIVE_TRANSACTION_NAME",
            "PRIOR_V16_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V16_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V16_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "PRIOR_V16_EVIDENCE_PATH",
            "PRIOR_V16_ACTIVE_RECORD",
            "PRIOR_V16_ACTIVE_SHA256",
            "PRIOR_V16_SOURCE_COMMIT",
            "PRIOR_V16_SOURCE_TREE",
            "PRIOR_V16_FINAL_JOURNAL_SIZE",
            "PRIOR_V16_FINAL_JOURNAL_LINES",
            "PRIOR_V16_FINAL_JOURNAL_SHA256",
            "PRIOR_V16_FINAL_RESULT",
            "PRIOR_V16_FINAL_RESULT_SHA256",
            "PRIOR_V16_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V16_SOURCE_ARCHIVE_SHA256",
            "PRIOR_V16_PROVENANCE",
            "PRIOR_V16_PROVENANCE_SHA256",
            "PRIOR_V16_LEGACY_MANIFEST_SHA256",
            "PRIOR_V16_LEGACY_XATTRS_SHA256",
            "PRIOR_V16_STAGED_HASHES_SHA256",
            "PRIOR_V16_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V16_BUILD_STDOUT_SHA256",
            "PRIOR_V16_BUILD_STDERR_SHA256",
            "PRIOR_V16_DEPLOYMENT_STDOUT_SHA256",
            "PRIOR_V16_DEPLOYMENT_STDERR_SHA256",
            "PRIOR_V16_ROLLBACK_RESERVE_SHA256",
            "PRIOR_V16_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V16_ROLLBACK_RESERVE_INODE",
            "PRIOR_V16_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V16_STAGED_PLIST_SHA256",
            "PRIOR_V16_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V16_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V16_STAGED_APP_XATTRS_SHA256",
            "PRIOR_V16_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v17_rolledback_retry",
            "validate_prior_v17_rolledback_records",
            "PriorV17RetryGuard",
            "PRIOR_V17_ACTIVE_TRANSACTION_NAME",
            "PRIOR_V17_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V17_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V17_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "PRIOR_V17_EVIDENCE_PATH",
            "PRIOR_V17_ACTIVE_RECORD",
            "PRIOR_V17_ACTIVE_SHA256",
            "PRIOR_V17_SOURCE_COMMIT",
            "PRIOR_V17_SOURCE_TREE",
            "PRIOR_V17_FINAL_JOURNAL_SIZE",
            "PRIOR_V17_FINAL_JOURNAL_LINES",
            "PRIOR_V17_FINAL_JOURNAL_SHA256",
            "PRIOR_V17_FINAL_RESULT",
            "PRIOR_V17_FINAL_RESULT_SHA256",
            "PRIOR_V17_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V17_SOURCE_ARCHIVE_SHA256",
            "PRIOR_V17_PROVENANCE",
            "PRIOR_V17_PROVENANCE_SHA256",
            "PRIOR_V17_LEGACY_MANIFEST_SHA256",
            "PRIOR_V17_LEGACY_XATTRS_SHA256",
            "PRIOR_V17_STAGED_HASHES_SHA256",
            "PRIOR_V17_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V17_BUILD_STDOUT_SHA256",
            "PRIOR_V17_BUILD_STDERR_SHA256",
            "PRIOR_V17_DEPLOYMENT_STDOUT_SHA256",
            "PRIOR_V17_DEPLOYMENT_STDERR_SHA256",
            "PRIOR_V17_ROLLBACK_RESERVE_SHA256",
            "PRIOR_V17_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V17_ROLLBACK_RESERVE_INODE",
            "PRIOR_V17_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V17_STAGED_PLIST_SHA256",
            "PRIOR_V17_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V17_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V17_STAGED_APP_XATTRS_SHA256",
            "PRIOR_V17_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v18_rolledback_retry",
            "validate_prior_v18_rolledback_records",
            "PriorV18RetryGuard",
            "PRIOR_V18_ACTIVE_TRANSACTION_NAME",
            "PRIOR_V18_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V18_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V18_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "PRIOR_V18_EVIDENCE_PATH",
            "PRIOR_V18_ACTIVE_RECORD",
            "PRIOR_V18_ACTIVE_SHA256",
            "PRIOR_V18_SOURCE_COMMIT",
            "PRIOR_V18_SOURCE_TREE",
            "PRIOR_V18_FINAL_JOURNAL_SIZE",
            "PRIOR_V18_FINAL_JOURNAL_LINES",
            "PRIOR_V18_FINAL_JOURNAL_SHA256",
            "PRIOR_V18_FINAL_RESULT",
            "PRIOR_V18_FINAL_RESULT_SHA256",
            "PRIOR_V18_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V18_SOURCE_ARCHIVE_SHA256",
            "PRIOR_V18_PROVENANCE",
            "PRIOR_V18_PROVENANCE_SHA256",
            "PRIOR_V18_LEGACY_MANIFEST_SHA256",
            "PRIOR_V18_LEGACY_XATTRS_SHA256",
            "PRIOR_V18_STAGED_HASHES_SHA256",
            "PRIOR_V18_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V18_BUILD_STDOUT_SHA256",
            "PRIOR_V18_BUILD_STDERR_SHA256",
            "PRIOR_V18_DEPLOYMENT_STDOUT_SHA256",
            "PRIOR_V18_DEPLOYMENT_STDERR_SHA256",
            "PRIOR_V18_ROLLBACK_RESERVE_SHA256",
            "PRIOR_V18_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V18_ROLLBACK_RESERVE_INODE",
            "PRIOR_V18_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V18_STAGED_PLIST_SHA256",
            "PRIOR_V18_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V18_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V18_STAGED_APP_XATTRS_SHA256",
            "PRIOR_V18_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v19_rolledback_retry",
            "validate_prior_v19_rolledback_records",
            "PriorV19RetryGuard",
            "PRIOR_V19_ACTIVE_TRANSACTION_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "PRIOR_V19_EVIDENCE_PATH",
            "PRIOR_V19_ACTIVE_RECORD",
            "PRIOR_V19_ACTIVE_SHA256",
            "PRIOR_V19_SOURCE_COMMIT",
            "PRIOR_V19_SOURCE_TREE",
            "PRIOR_V19_FINAL_JOURNAL_SIZE",
            "PRIOR_V19_FINAL_JOURNAL_LINES",
            "PRIOR_V19_FINAL_JOURNAL_SHA256",
            "PRIOR_V19_PRECUTOVER_JOURNAL_LINE",
            "PRIOR_V19_NEW_BOOTSTRAPPED_JOURNAL_LINE",
            "PRIOR_V19_ROLLBACK_JOURNAL_TAIL",
            "PRIOR_V19_FORBIDDEN_JOURNAL_STATES",
            "PRIOR_V19_FINAL_RESULT",
            "PRIOR_V19_FINAL_RESULT_SHA256",
            "PRIOR_V19_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V19_SOURCE_ARCHIVE_SHA256",
            "PRIOR_V19_PROVENANCE",
            "PRIOR_V19_PROVENANCE_SHA256",
            "PRIOR_V19_LEGACY_MANIFEST_SHA256",
            "PRIOR_V19_LEGACY_XATTRS_SHA256",
            "PRIOR_V19_STAGED_HASHES_SHA256",
            "PRIOR_V19_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V19_BUILD_STDOUT_SHA256",
            "PRIOR_V19_BUILD_STDERR_SHA256",
            "PRIOR_V19_ROLLBACK_RESERVE_SHA256",
            "PRIOR_V19_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V19_ROLLBACK_RESERVE_INODE",
            "PRIOR_V19_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V19_STAGED_PLIST_SHA256",
            "PRIOR_V19_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V19_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V19_STAGED_APP_XATTRS_SHA256",
            "PRIOR_V19_FAILED_APP_XATTRS_SHA256",
            "require_prior_v19_deployment_records_absent",
            "migration-v14-after-v13-1785637636-18044",
            "migration-v15-after-v14-1785637636-18044",
            "migration-v16-after-v15-1785637636-18044",
            "migration-v17-after-v16-1785637636-18044",
            "migration-v18-after-v17-1785637636-18044",
            "migration-v19-after-v18-1785637636-18044",
            "migration-v20-after-v19-1785637636-18044",
            "--verify-reviewed-prior-retry-state",
            "prior_fields.extend(prior_v13.journal_fields());",
            "prior_fields.extend(prior_v14.journal_fields());",
            "prior_fields.extend(prior_v15.journal_fields());",
            "prior_fields.extend(prior_v16.journal_fields());",
            "prior_fields.extend(prior_v17.journal_fields());",
            "prior_fields.extend(prior_v18.journal_fields());",
            "prior_fields.extend(prior_v19.journal_fields());",
            "PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14=v15=v16=v17=v18=v19 legacy=sole-ready v20=absent",
            ".opensteamer-disabled-v20-{tag}",
            ".org.example.opensteamer.worldwide.plist.disabled-v20-{tag}",
            "CutoverPreflight",
            "CutoverParentIdentities",
            "require_cutover_hidden_paths_absent",
            "prove_write_execute_and_sync",
            "PinnedSystemTool",
            "DITTO_SHA256",
            "validate_logs_precutover",
            "RollbackReserve",
            "ROLLBACK_RESERVE_BYTES",
            "F_PREALLOCATE_VALUE",
            "release_rollback_reserve",
            "PinnedVerifierSet",
            "run_pinned_script",
            "DEPLOYMENT_VERIFIER_TIMEOUT",
            "run_pinned_script_until",
            "verify_deployment_with_prefix_until",
            "include_bytes!(\"verify-mac-host-deployment.sh\")",
            "verify_embedded_verifier_hashes",
            "--self-test-zsh-runtime",
            "deployment zsh-runtime self-test",
            "self_test_embedded_zsh_verifiers",
            "symlink_target_manifest",
            "require_new_runtime_absent",
            "require_precutover_disk_headroom",
            "require_fresh_retry_disk_headroom",
            "const MINIMUM_FRESH_RETRY_AVAILABLE_BYTES: u64 = 2 * 1024 * 1024 * 1024",
        ] {
            XCTAssertTrue(controller.contains(required), "Controller lacks \(required)")
        }
        let exactPriorV14Anchors = [
            "const PRIOR_V14_ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v14\";",
            "const PRIOR_V14_ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v14.pending\";",
            "const PRIOR_V14_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v14.finalizing\";",
            "const PRIOR_V14_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v14.linearized\";",
            "const PRIOR_V14_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v14-after-v13-1785637636-18044\";",
            "const PRIOR_V14_ACTIVE_RECORD: &[u8] = b\"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v14-after-v13-1785637636-18044\\n\";",
            "const PRIOR_V14_ACTIVE_SHA256: &str =\n" +
                "    \"81c54f55aae42bf60e949ae386d028b44eef2823910ce21be855ebbb299e64b6\";",
            "const PRIOR_V14_SOURCE_COMMIT: &str = \"c2d8470f6fac0eac07ff1355e984d57e3f330b74\";",
            "const PRIOR_V14_SOURCE_TREE: &str = \"90b55c6a6f5619f5be9489b52481a719a4732883\";",
            "const PRIOR_V14_FINAL_JOURNAL_SHA256: &str =\n" +
                "    \"8e4554721ae554be868bf9a094ecb5eb34cdec4e7c132f6bfd9235bca677c609\";",
            "const PRIOR_V14_FINAL_RESULT_SHA256: &str =\n" +
                "    \"434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301\";",
            "const PRIOR_V14_SOURCE_ARCHIVE_SIZE: u64 = 6_512_640;",
            "const PRIOR_V14_SOURCE_ARCHIVE_SHA256: &str =\n" +
                "    \"6bdea9203b0dca4034a064e026761a368158646bec6f1667525da8e933bebb49\";",
            "const PRIOR_V14_PROVENANCE_SHA256: &str =\n" +
                "    \"4f2dd2eaaf60685a045dbd2f14cff2ab73922c5feec755e2660de28fe8cbb317\";",
            "const PRIOR_V14_LEGACY_MANIFEST_SHA256: &str =\n" +
                "    \"2bdaddf99c5101a8f994d3916b44a66f6c8fcbd3c0cda1b3ae44694263d6971f\";",
            "const PRIOR_V14_LEGACY_XATTRS_SHA256: &str =\n" +
                "    \"cc69a330ffd8dcb92e45bfa1b2f7163f749b2c1875bc2ead51f9ed50dd252ea8\";",
            "const PRIOR_V14_STAGED_HASHES_SHA256: &str =\n" +
                "    \"cf4baa1022bae387df8794b48fbad30cd36c59c7df8752535786186dcfbd76ec\";",
            "const PRIOR_V14_SOURCE_EXPORT_MANIFEST_SHA256: &str =\n" +
                "    \"6c3e135002158bdb086e0fd1ee42c9320c4f6aa7de15bb04571cd73a22b56d01\";",
            "const PRIOR_V14_BUILD_STDOUT_SHA256: &str =\n" +
                "    \"cc9d1a65daaf4f447e17793ee0e832a6650050842ab6a78270a9f6d8e5afc51d\";",
            "const PRIOR_V14_BUILD_STDERR_SHA256: &str =\n" +
                "    \"1070762c8c7a17274da8f8b30e25f091517006dba3f12a6c509420e4ae895092\";",
            "const PRIOR_V14_DEPLOYMENT_STDOUT_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V14_DEPLOYMENT_STDERR_SHA256: &str =\n" +
                "    \"773249b110c0a8f6b7a2b44ab0507be4f0fd3c2ff280bf412b21edde4c9ac1a9\";",
            "const PRIOR_V14_ROLLBACK_RESERVE_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V14_ROLLBACK_RESERVE_DEVICE: u64 = 16_777_230;",
            "const PRIOR_V14_ROLLBACK_RESERVE_INODE: u64 = 20_913_894;",
            "const PRIOR_V14_STAGED_EXECUTABLE_SHA256: &str =\n" +
                "    \"8dee75c83aff33509e5f08263db57ee1d7b23238d8f14072286b25262ed6e4a3\";",
            "const PRIOR_V14_STAGED_PLIST_SHA256: &str =\n" +
                "    \"7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550\";",
            "const PRIOR_V14_STAGED_APP_MANIFEST_SHA256: &str =\n" +
                "    \"88a444a2eaeef3d416ee7cf02f972eb1bcead144b09df18ed8edf4940765e2fc\";",
            "const PRIOR_V14_SYMLINK_TARGET_MANIFEST_SHA256: &str =\n" +
                "    \"ab17b5de2703ca8b990a315bb816165d6d6bdb898e2b7b6d8c9d59147cbd8fec\";",
            "const PRIOR_V14_STAGED_APP_XATTRS_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V14_FAILED_APP_XATTRS_SHA256: &str =\n" +
                "    \"b3803dc3d49417c1f401ee004179d08fed3de6471fee88d51ca743c910fffa56\";",
            "const V20_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044\";",
            "b\"zsh:299: no such file or directory: /bin/cmp\\nopensteamer host deployment verification failed: reviewed LaunchAgent bytes differ from checked-in contract\\n\"",
        ]
        for anchor in exactPriorV14Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v14 anchor \(anchor)")
        }
        let exactPriorV15Anchors = [
            "const PRIOR_V15_ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v15\";",
            "const PRIOR_V15_ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v15.pending\";",
            "const PRIOR_V15_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v15.finalizing\";",
            "const PRIOR_V15_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v15.linearized\";",
            "const PRIOR_V15_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v15-after-v14-1785637636-18044\";",
            "const PRIOR_V15_ACTIVE_RECORD: &[u8] = b\"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v15-after-v14-1785637636-18044\\n\";",
            "const PRIOR_V15_ACTIVE_SHA256: &str =\n" +
                "    \"a1aa94936aa8d5f994597525a08569eb487ed2931487f3741e4d5421a3058513\";",
            "const PRIOR_V15_SOURCE_COMMIT: &str = \"26869215b5c8c69037652c8feb2db0371ef13648\";",
            "const PRIOR_V15_SOURCE_TREE: &str = \"2ff47b6b082d78108447c0ea0a7bf2e213e06310\";",
            "const PRIOR_V15_FINAL_JOURNAL_SIZE: usize = 5_412;",
            "const PRIOR_V15_FINAL_JOURNAL_LINES: usize = 20;",
            "const PRIOR_V15_FINAL_JOURNAL_SHA256: &str =\n" +
                "    \"a812bca76e799ad4b2727b6c6d8c20d84875c787541bea8c1a9a343b5ad07dcc\";",
            "const PRIOR_V15_PRECUTOVER_JOURNAL_LINE: &[u8] = b\"STATE PRECUTOVER_VERIFIED applications_device=16777230 applications_inode=4982341 launch_agents_device=16777230 launch_agents_inode=474668 precutover_available_bytes=3092496384 rollback_reserve_device=16777230 rollback_reserve_inode=20973550 rollback_reserve_bytes=8388608\\n\";",
            "const PRIOR_V15_GENERATION_JOURNAL_LINE: &[u8] = b\"STATE NEW_PID_OBSERVED log_offset=1364 log_device=16777230 log_inode=20570513 pid=5692 runs=1 process_start=Sun%20Aug%20%202%2002%3A55%3A33%202026 nonce=9f297b53abe1b9bab9e2403c61cc4c980cabeb71ba4f6883a1dd21e949ae0f9d lock_device=16777230 lock_inode=10835208\\n\";",
            "const PRIOR_V15_ROLLBACK_JOURNAL_TAIL: &[u8] = b\"STATE ROLLBACK_STARTED legacy_disable_was_journaled=true rollback_mode=FullRestore\\nSTATE NEW_STOPPED\\nSTATE NEW_DESTINATIONS_CLEARED\\nSTATE LEGACY_REENABLED\\nSTATE LEGACY_BOOTSTRAPPED\\nSTATE LEGACY_RECOVERED\\nSTATE ROLLED_BACK\\n\";",
            "const PRIOR_V15_FINAL_RESULT_SHA256: &str =\n" +
                "    \"434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301\";",
            "b\"result=rolled-back\\nlegacy_launchd_disabled=false\\nphysical_iphone_e2e=unavailable-not-claimed\\n\"",
            "const PRIOR_V15_SOURCE_ARCHIVE_SIZE: u64 = 6_563_840;",
            "const PRIOR_V15_SOURCE_ARCHIVE_SHA256: &str =\n" +
                "    \"9794a0894ea873e257fc3c6198ea6321ee1790f5ae5de80a4a698202c3e3883a\";",
            "const PRIOR_V15_PROVENANCE_SHA256: &str =\n" +
                "    \"d16716934018f9ff0b9d1206d6ed43e4596e0596dd3e226a99fac7df9c208261\";",
            "package_resolved_sha256=161213e9507513e41f0acba0d7439fcf633b9d03d78c22b1e4b15fa9f83a01d9",
            "const PRIOR_V15_LEGACY_MANIFEST_SHA256: &str =\n" +
                "    \"2bdaddf99c5101a8f994d3916b44a66f6c8fcbd3c0cda1b3ae44694263d6971f\";",
            "const PRIOR_V15_LEGACY_XATTRS_SHA256: &str =\n" +
                "    \"cc69a330ffd8dcb92e45bfa1b2f7163f749b2c1875bc2ead51f9ed50dd252ea8\";",
            "const PRIOR_V15_STAGED_HASHES_SHA256: &str =\n" +
                "    \"19ed36c5ebe84e60073ed2131878c1b29df8d13a96672780d988a7b86d176db5\";",
            "const PRIOR_V15_SOURCE_EXPORT_MANIFEST_SHA256: &str =\n" +
                "    \"223bd97483d6e099b32944c9ef6852ccc7d8d728a88e0d309527fb5dcc03a423\";",
            "const PRIOR_V15_BUILD_STDOUT_SHA256: &str =\n" +
                "    \"0aec7683266cfdb610b252b1b2f99a42081adcfc4c0cc3d4f01b6326a187f001\";",
            "const PRIOR_V15_BUILD_STDERR_SHA256: &str =\n" +
                "    \"8992a64260fba0c4f0da055fcd10d142f94b50fbef81bb82287ff896e3b8efda\";",
            "const PRIOR_V15_ROLLBACK_RESERVE_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V15_ROLLBACK_RESERVE_DEVICE: u64 = 16_777_230;",
            "const PRIOR_V15_ROLLBACK_RESERVE_INODE: u64 = 20_973_550;",
            "const PRIOR_V15_STAGED_EXECUTABLE_SHA256: &str =\n" +
                "    \"8bee73df6693c7ca31ebcdec1f1cf9bb3b30e60e1577da0b4f8a6dbc2a64730f\";",
            "const PRIOR_V15_STAGED_PLIST_SHA256: &str =\n" +
                "    \"7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550\";",
            "const PRIOR_V15_STAGED_APP_MANIFEST_SHA256: &str =\n" +
                "    \"1db07ebbc53b1f2bc6a7bfbb1be9fcd258f008e10ab4147c8b72bafdfd983494\";",
            "const PRIOR_V15_SYMLINK_TARGET_MANIFEST_SHA256: &str =\n" +
                "    \"ab17b5de2703ca8b990a315bb816165d6d6bdb898e2b7b6d8c9d59147cbd8fec\";",
            "const PRIOR_V15_STAGED_APP_XATTRS_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V15_FAILED_APP_XATTRS_SHA256: &str =\n" +
                "    \"760fdf730af579fa4b0b89a349babb39743944bf9e10b88cc513a263d23cb8b3\";",
            "const V20_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044\";",
        ]
        for anchor in exactPriorV15Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v15 anchor \(anchor)")
        }
        let exactPriorV16Anchors = [
            "const PRIOR_V16_ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v16\";",
            "const PRIOR_V16_ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v16.pending\";",
            "const PRIOR_V16_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v16.finalizing\";",
            "const PRIOR_V16_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v16.linearized\";",
            "const PRIOR_V16_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v16-after-v15-1785637636-18044\";",
            "const PRIOR_V16_ACTIVE_RECORD: &[u8] = b\"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v16-after-v15-1785637636-18044\\n\";",
            "const PRIOR_V16_ACTIVE_SHA256: &str =\n" +
                "    \"aaf2d32335687c997d8f623324c1dbb5a00855464ff2f110a2f94eb8bb97c15b\";",
            "const PRIOR_V16_SOURCE_COMMIT: &str = \"625941d4fc1f2f4d6254df57ee897c71c88f399d\";",
            "const PRIOR_V16_SOURCE_TREE: &str = \"3507c97c3b5be7e11a9ffab6c686d615f5a96506\";",
            "const PRIOR_V16_FINAL_JOURNAL_SIZE: usize = 6_194;",
            "const PRIOR_V16_FINAL_JOURNAL_LINES: usize = 20;",
            "const PRIOR_V16_FINAL_JOURNAL_SHA256: &str =\n" +
                "    \"a95a7c0a23f8bc50a0a7270d616e75dac0b72aee2ab4676fa8d3b4be6288fbfb\";",
            "const PRIOR_V16_GENERATION_JOURNAL_LINE: &[u8] = b\"STATE NEW_PID_OBSERVED log_offset=1364 log_device=16777230 log_inode=20570513 pid=17632 runs=1 process_start=Sun%20Aug%20%202%2012%3A26%3A54%202026 nonce=88445fa1c01ac2168e9b0e58994f43e44393da7d4a955e82c02df16e7390cd6f lock_device=16777230 lock_inode=10835208\\n\";",
            "const PRIOR_V16_ROLLBACK_JOURNAL_TAIL: &[u8] = b\"STATE ROLLBACK_STARTED legacy_disable_was_journaled=true rollback_mode=FullRestore\\nSTATE NEW_STOPPED\\nSTATE NEW_DESTINATIONS_CLEARED\\nSTATE LEGACY_REENABLED\\nSTATE LEGACY_BOOTSTRAPPED\\nSTATE LEGACY_RECOVERED\\nSTATE ROLLED_BACK\\n\";",
            "const PRIOR_V16_FINAL_RESULT_SHA256: &str =\n" +
                "    \"434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301\";",
            "const PRIOR_V16_SOURCE_ARCHIVE_SIZE: u64 = 6_635_520;",
            "const PRIOR_V16_SOURCE_ARCHIVE_SHA256: &str =\n" +
                "    \"2e3ade684c280e2263deb520412093d24b85f25a96dc6db14973a3d56388e864\";",
            "const PRIOR_V16_PROVENANCE_SHA256: &str =\n" +
                "    \"d722f6589eb0834c64b0866bda7034994f83e0266b1cd8d62d8e3541a07aa9ae\";",
            "const PRIOR_V16_STAGED_HASHES_SHA256: &str =\n" +
                "    \"63cd1b9df9e78f06737ed41a94f1c524d34c991cf5328144d6c2151690b6ac8c\";",
            "const PRIOR_V16_SOURCE_EXPORT_MANIFEST_SHA256: &str =\n" +
                "    \"9973e8739a4f2280dcd7557a636e270e4211d3401ab09502fdadf55b99bfdab2\";",
            "const PRIOR_V16_BUILD_STDOUT_SHA256: &str =\n" +
                "    \"70e7a699f1e6ace9818610e88c85cc6d698ef1a3c788c1d55731124ea2e39f60\";",
            "const PRIOR_V16_BUILD_STDERR_SHA256: &str =\n" +
                "    \"84c65dbca95845cb511b10069bbef94d8818a09b3b0845ea639df0077977e05b\";",
            "const PRIOR_V16_DEPLOYMENT_STDOUT_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V16_DEPLOYMENT_STDOUT_SIZE: usize = 0;",
            "const PRIOR_V16_DEPLOYMENT_STDERR_SHA256: &str =\n" +
                "    \"b71cb31d6ff97ce941f65798ee357fcff8c9af922589b1a30d74dbe0071102c0\";",
            "const PRIOR_V16_DEPLOYMENT_STDERR_SIZE: usize = 2_218;",
            "const PRIOR_V16_DEPLOYMENT_STDERR_TAIL: &[u8] = b\"verify-mac-host-bundle: app bundle contains extended attributes: /Applications/opensteamer Host.app: com.apple.macl: \\n\";",
            "const PRIOR_V16_ROLLBACK_RESERVE_INODE: u64 = 21_315_340;",
            "const PRIOR_V16_STAGED_EXECUTABLE_SHA256: &str =\n" +
                "    \"95b00603881bc06d7c0acf25cf2f359ae177608da6ffa876a62976ec904350f1\";",
            "const PRIOR_V16_STAGED_APP_MANIFEST_SHA256: &str =\n" +
                "    \"f68ef887af0ac97f8302e42ff40e9cf793881f08938bcf0e8b9a430133f62839\";",
            "const PRIOR_V16_STAGED_APP_XATTRS_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V16_FAILED_APP_XATTRS_SHA256: &str =\n" +
                "    \"fc476ba38a5da85548cfbb83d758b4bbc41e2585495c55fb3344a6908b7ccee6\";",
            "const V20_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044\";",
        ]
        for anchor in exactPriorV16Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v16 anchor \(anchor)")
        }
        let exactPriorV17Anchors = [
            "const PRIOR_V17_ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v17\";",
            "const PRIOR_V17_ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v17.pending\";",
            "const PRIOR_V17_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v17.finalizing\";",
            "const PRIOR_V17_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v17.linearized\";",
            "const PRIOR_V17_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v17-after-v16-1785637636-18044\";",
            "const PRIOR_V17_ACTIVE_RECORD: &[u8] = b\"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v17-after-v16-1785637636-18044\\n\";",
            "const PRIOR_V17_ACTIVE_SHA256: &str =\n" +
                "    \"c67386bd19193e913f7116cc179ec44e1768ef077103f51a897e0774324f765a\";",
            "const PRIOR_V17_SOURCE_COMMIT: &str = \"bd23d6b7bf9328a383f1d6c8da152754b915eeb5\";",
            "const PRIOR_V17_SOURCE_TREE: &str = \"6b536450d997f14b356680c080328cbdced77e67\";",
            "const PRIOR_V17_FINAL_JOURNAL_SIZE: usize = 7_075;",
            "const PRIOR_V17_FINAL_JOURNAL_LINES: usize = 20;",
            "const PRIOR_V17_FINAL_JOURNAL_SHA256: &str =\n" +
                "    \"9f66fbd1aff49313ce1528d25290dbb032f720fc79c2e04c509ae230704151d1\";",
            "const PRIOR_V17_PRECUTOVER_JOURNAL_LINE: &[u8] = b\"STATE PRECUTOVER_VERIFIED applications_device=16777230 applications_inode=4982341 launch_agents_device=16777230 launch_agents_inode=474668 precutover_available_bytes=1951039488 rollback_reserve_device=16777230 rollback_reserve_inode=21489839 rollback_reserve_bytes=8388608\\n\";",
            "const PRIOR_V17_GENERATION_JOURNAL_LINE: &[u8] = b\"STATE NEW_PID_OBSERVED log_offset=1705 log_device=16777230 log_inode=20570513 pid=93486 runs=1 process_start=Sun%20Aug%20%202%2015%3A04%3A57%202026 nonce=f69ef6518ac1c0fd57652c02fcc3284fc7a700708b9754a48f256dbb17f12450 lock_device=16777230 lock_inode=10835208\\n\";",
            "const PRIOR_V17_ROLLBACK_JOURNAL_TAIL: &[u8] = b\"STATE ROLLBACK_STARTED legacy_disable_was_journaled=true rollback_mode=FullRestore\\nSTATE NEW_STOPPED\\nSTATE NEW_DESTINATIONS_CLEARED\\nSTATE LEGACY_REENABLED\\nSTATE LEGACY_BOOTSTRAPPED\\nSTATE LEGACY_RECOVERED\\nSTATE ROLLED_BACK\\n\";",
            "const PRIOR_V17_FINAL_RESULT: &[u8] = b\"result=rolled-back\\nlegacy_launchd_disabled=false\\nphysical_iphone_e2e=unavailable-not-claimed\\n\";",
            "const PRIOR_V17_FINAL_RESULT_SHA256: &str =\n" +
                "    \"434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301\";",
            "const PRIOR_V17_SOURCE_ARCHIVE_SIZE: u64 = 6_717_440;",
            "const PRIOR_V17_SOURCE_ARCHIVE_SHA256: &str =\n" +
                "    \"b1422da32cba1ab7716def3f11f8e2177584a7d8b4f8f893848ea4f6c0651a16\";",
            "const PRIOR_V17_PROVENANCE_SHA256: &str =\n" +
                "    \"91057613a91cc1d4ae8dc681548e9960fe0de599bbc9acbe110cbe0f12ccb049\";",
            "const PRIOR_V17_PROVENANCE: &[u8] = br#\"commit=bd23d6b7bf9328a383f1d6c8da152754b915eeb5\n" +
                "tree=6b536450d997f14b356680c080328cbdced77e67\n" +
                "remote=https://github.com/ahmedelami/opensteamer.git\n" +
                "upstream=origin/agent/auto-select-iphone-microphone\n" +
                "source_archive_sha256=b1422da32cba1ab7716def3f11f8e2177584a7d8b4f8f893848ea4f6c0651a16\n" +
                "package_resolved_sha256=161213e9507513e41f0acba0d7439fcf633b9d03d78c22b1e4b15fa9f83a01d9\n" +
                "\"#;",
            "const PRIOR_V17_LEGACY_MANIFEST_SHA256: &str =\n" +
                "    \"2bdaddf99c5101a8f994d3916b44a66f6c8fcbd3c0cda1b3ae44694263d6971f\";",
            "const PRIOR_V17_LEGACY_XATTRS_SHA256: &str =\n" +
                "    \"cc69a330ffd8dcb92e45bfa1b2f7163f749b2c1875bc2ead51f9ed50dd252ea8\";",
            "const PRIOR_V17_STAGED_HASHES_SHA256: &str =\n" +
                "    \"8da8b4480925deaf1d92f4a2945d3775b297f8e96ffa1f38dffda765b44b9e56\";",
            "const PRIOR_V17_SOURCE_EXPORT_MANIFEST_SHA256: &str =\n" +
                "    \"29bfd8e679ade3541b8edd46c10d4144d7ec082709b6152500c519240a988834\";",
            "const PRIOR_V17_BUILD_STDOUT_SHA256: &str =\n" +
                "    \"a32f0113756c8671e8def69c80edbe324fc5c1f140a0820a926cb72efd9ae157\";",
            "const PRIOR_V17_BUILD_STDOUT_SIZE: usize = 884;",
            "const PRIOR_V17_BUILD_STDERR_SHA256: &str =\n" +
                "    \"e8665003dd7aec095f28b350b8bf324c84800547028920a905e8e13f7550518a\";",
            "const PRIOR_V17_BUILD_STDERR_SIZE: usize = 3_557;",
            "const PRIOR_V17_DEPLOYMENT_STDOUT_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V17_DEPLOYMENT_STDOUT_SIZE: usize = 0;",
            "const PRIOR_V17_DEPLOYMENT_STDERR_SHA256: &str =\n" +
                "    \"11a704463fb667082b2e50bf5877a24d728c0ee7e3b0a48d7686224091262254\";",
            "const PRIOR_V17_DEPLOYMENT_STDERR_SIZE: usize = 4_546;",
            "const PRIOR_V17_DEPLOYMENT_STDERR_TAIL: &[u8] = b\"diff: /Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Versions/Current: Directory loop detected\\n\";",
            "const PRIOR_V17_ROLLBACK_RESERVE_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V17_ROLLBACK_RESERVE_DEVICE: u64 = 16_777_230;",
            "const PRIOR_V17_ROLLBACK_RESERVE_INODE: u64 = 21_489_839;",
            "const PRIOR_V17_STAGED_EXECUTABLE_SHA256: &str =\n" +
                "    \"859c7c0e7f6432dbafceb50aa6670f3ad39f407d64bccde0707a652890b8ec9a\";",
            "const PRIOR_V17_STAGED_PLIST_SHA256: &str =\n" +
                "    \"7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550\";",
            "const PRIOR_V17_STAGED_APP_MANIFEST_SHA256: &str =\n" +
                "    \"9bb263af1b974a643759e1f726b70ff6f949e10466b1484e0e13adcec5454388\";",
            "const PRIOR_V17_SYMLINK_TARGET_MANIFEST_SHA256: &str =\n" +
                "    \"ab17b5de2703ca8b990a315bb816165d6d6bdb898e2b7b6d8c9d59147cbd8fec\";",
            "const PRIOR_V17_STAGED_APP_XATTRS_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V17_FAILED_APP_XATTRS_SHA256: &str =\n" +
                "    \"4820785b28b99a603cd21d3fd62b8173af84ee7e51231f7586a944f4be21cdfc\";",
            "const V20_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044\";",
        ]
        for anchor in exactPriorV17Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v17 anchor \(anchor)")
        }
        let priorV17RecordValidation = try sourceSection(
            controller,
            from: "fn validate_prior_v17_rolledback_records(",
            to: "struct PriorV17RetryGuard"
        )
        for required in [
            "journal.len() != PRIOR_V17_FINAL_JOURNAL_SIZE",
            "PRIOR_V17_FINAL_JOURNAL_LINES",
            "sha256_bytes(journal)? != PRIOR_V17_FINAL_JOURNAL_SHA256",
            "b\"OPENSTEAMER_MIGRATION_JOURNAL_V17\\n\"",
            "PRIOR_V17_PRECUTOVER_JOURNAL_LINE",
            "PRIOR_V17_GENERATION_JOURNAL_LINE",
            "PRIOR_V17_ROLLBACK_JOURNAL_TAIL",
            "result != PRIOR_V17_FINAL_RESULT",
            "sha256_bytes(result)? != PRIOR_V17_FINAL_RESULT_SHA256",
            "provenance != PRIOR_V17_PROVENANCE",
            "sha256_bytes(provenance)? != PRIOR_V17_PROVENANCE_SHA256",
            "deployment_stdout.len() != PRIOR_V17_DEPLOYMENT_STDOUT_SIZE",
            "sha256_bytes(deployment_stdout)? != PRIOR_V17_DEPLOYMENT_STDOUT_SHA256",
            "deployment_stderr.len() != PRIOR_V17_DEPLOYMENT_STDERR_SIZE",
            "sha256_bytes(deployment_stderr)? != PRIOR_V17_DEPLOYMENT_STDERR_SHA256",
            "deployment_stderr.ends_with(PRIOR_V17_DEPLOYMENT_STDERR_TAIL)",
            "status-141 full rollback",
            "codesign/awk SIGPIPE failure",
        ] {
            XCTAssertTrue(
                priorV17RecordValidation.contains(required),
                "The exact v17 status-141 rollback validator lacks \(required)"
            )
        }
        let priorV17Guard = try sourceSection(
            controller,
            from: "impl PriorV17RetryGuard {",
            to: "fn validate_prior_v17_rolledback_retry("
        )
        for required in [
            "PRIOR_V17_ACTIVE_RECORD", "PRIOR_V17_ACTIVE_SHA256",
            "PRIOR_V17_LEGACY_MANIFEST_SHA256", "PRIOR_V17_LEGACY_XATTRS_SHA256",
            "PRIOR_V17_STAGED_HASHES_SHA256", "PRIOR_V17_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V17_BUILD_STDOUT_SHA256", "PRIOR_V17_BUILD_STDERR_SHA256",
            "PRIOR_V17_ROLLBACK_RESERVE_SHA256", "PRIOR_V17_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V17_ROLLBACK_RESERVE_INODE", "PRIOR_V17_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V17_SOURCE_ARCHIVE_SHA256", "PRIOR_V17_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V17_STAGED_PLIST_SHA256", "PRIOR_V17_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V17_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V17_STAGED_APP_XATTRS_SHA256", "PRIOR_V17_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v17_rolledback_records(",
            "PRIOR_V17_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V17_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V17_ACTIVE_TRANSACTION_LINEARIZED_NAME",
        ] {
            XCTAssertTrue(priorV17Guard.contains(required), "The exact v17 guard lacks \(required)")
        }
        let exactPriorV18Anchors = [
            "const PRIOR_V18_ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v18\";",
            "const PRIOR_V18_ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v18.pending\";",
            "const PRIOR_V18_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v18.finalizing\";",
            "const PRIOR_V18_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v18.linearized\";",
            "const PRIOR_V18_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v18-after-v17-1785637636-18044\";",
            "const PRIOR_V18_ACTIVE_RECORD: &[u8] = b\"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v18-after-v17-1785637636-18044\\n\";",
            "const PRIOR_V18_ACTIVE_SHA256: &str =\n" +
                "    \"3fd6a39f84d620a203fd75f306184356bdbfe9546d6fa45d6d19f91cb4976144\";",
            "const PRIOR_V18_SOURCE_COMMIT: &str = \"ff02ca6ba192b27fd1cd22e807c8d42900084f74\";",
            "const PRIOR_V18_SOURCE_TREE: &str = \"fb56a78b685453901ec0ff8af2fccd446d63ea18\";",
            "const PRIOR_V18_FINAL_JOURNAL_SIZE: usize = 7_956;",
            "const PRIOR_V18_FINAL_JOURNAL_LINES: usize = 20;",
            "const PRIOR_V18_FINAL_JOURNAL_SHA256: &str =\n" +
                "    \"bd28126eaae9112af24eccc75f8c18fcb5b43da2e0a4eda3f40169bbed12e55d\";",
            "const PRIOR_V18_PRECUTOVER_JOURNAL_LINE: &[u8] = b\"STATE PRECUTOVER_VERIFIED applications_device=16777230 applications_inode=4982341 launch_agents_device=16777230 launch_agents_inode=474668 precutover_available_bytes=2137174016 rollback_reserve_device=16777230 rollback_reserve_inode=21550474 rollback_reserve_bytes=8388608\\n\";",
            "const PRIOR_V18_GENERATION_JOURNAL_LINE: &[u8] = b\"STATE NEW_PID_OBSERVED log_offset=2127 log_device=16777230 log_inode=20570513 pid=53809 runs=1 process_start=Sun%20Aug%20%202%2016%3A35%3A42%202026 nonce=511ac5970b1235bd964bfffb97cf5dd66d975cdfccbfbd8992eb7d76ec5f7aad lock_device=16777230 lock_inode=10835208\\n\";",
            "const PRIOR_V18_ROLLBACK_JOURNAL_TAIL: &[u8] = b\"STATE ROLLBACK_STARTED legacy_disable_was_journaled=true rollback_mode=FullRestore\\nSTATE NEW_STOPPED\\nSTATE NEW_DESTINATIONS_CLEARED\\nSTATE LEGACY_REENABLED\\nSTATE LEGACY_BOOTSTRAPPED\\nSTATE LEGACY_RECOVERED\\nSTATE ROLLED_BACK\\n\";",
            "const PRIOR_V18_FINAL_RESULT: &[u8] = b\"result=rolled-back\\nlegacy_launchd_disabled=false\\nphysical_iphone_e2e=unavailable-not-claimed\\n\";",
            "const PRIOR_V18_FINAL_RESULT_SHA256: &str =\n" +
                "    \"434dea611969ea91d8b873bffe42e4a149f329641fe5111e898b86d66fc3d301\";",
            "const PRIOR_V18_SOURCE_ARCHIVE_SIZE: u64 = 6_778_880;",
            "const PRIOR_V18_SOURCE_ARCHIVE_SHA256: &str =\n" +
                "    \"ea8ec3d76daa2effb4e6a955240adcc0acd9b5c24b083365218657ebb4a09a13\";",
            "const PRIOR_V18_PROVENANCE_SHA256: &str =\n" +
                "    \"b727f2a085d15722096c999d2e169ae966eb63db6eeef14a7a290808d390f261\";",
            "const PRIOR_V18_LEGACY_MANIFEST_SHA256: &str =\n" +
                "    \"2bdaddf99c5101a8f994d3916b44a66f6c8fcbd3c0cda1b3ae44694263d6971f\";",
            "const PRIOR_V18_LEGACY_XATTRS_SHA256: &str =\n" +
                "    \"cc69a330ffd8dcb92e45bfa1b2f7163f749b2c1875bc2ead51f9ed50dd252ea8\";",
            "const PRIOR_V18_STAGED_HASHES_SHA256: &str =\n" +
                "    \"c8b60437ac4f874a0737397aeba46e6d0f293221f328ec76140203ec44c93049\";",
            "const PRIOR_V18_SOURCE_EXPORT_MANIFEST_SHA256: &str =\n" +
                "    \"ae135979c73b639f38fa68cacd7d5872504eb8e2b71f009c22241f3fd13b8784\";",
            "const PRIOR_V18_BUILD_STDOUT_SHA256: &str =\n" +
                "    \"ee780990dc1e984eb393adaea97d44bef45e9969c48ed46b65de5e8e59094b27\";",
            "const PRIOR_V18_BUILD_STDOUT_SIZE: usize = 884;",
            "const PRIOR_V18_BUILD_STDERR_SHA256: &str =\n" +
                "    \"0888d0bb55cc4c902ea469d322bf01f71a7f69805d2d3ae987997365505bd372\";",
            "const PRIOR_V18_BUILD_STDERR_SIZE: usize = 3_557;",
            "const PRIOR_V18_DEPLOYMENT_STDOUT_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V18_DEPLOYMENT_STDOUT_SIZE: usize = 0;",
            "const PRIOR_V18_DEPLOYMENT_STDERR_SHA256: &str =\n" +
                "    \"59a06b517d0adb1223bd725fa323ab837d52e2dcd925e6b282941ff9d1f8acf1\";",
            "const PRIOR_V18_DEPLOYMENT_STDERR_SIZE: usize = 4_884;",
            "const PRIOR_V18_DEPLOYMENT_STDERR_TAIL: &[u8] = b\"opensteamer host deployment verification failed: process start identity differs from the controller-observed generation\\n\";",
            "const PRIOR_V18_ROLLBACK_RESERVE_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V18_ROLLBACK_RESERVE_DEVICE: u64 = 16_777_230;",
            "const PRIOR_V18_ROLLBACK_RESERVE_INODE: u64 = 21_550_474;",
            "const PRIOR_V18_STAGED_EXECUTABLE_SHA256: &str =\n" +
                "    \"ff5540bfe78306d0b8142bd40ef18dff32f04c05de82b5a95dad57cef849c2d8\";",
            "const PRIOR_V18_STAGED_PLIST_SHA256: &str =\n" +
                "    \"7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550\";",
            "const PRIOR_V18_STAGED_APP_MANIFEST_SHA256: &str =\n" +
                "    \"13ad8276dcdbe8bc669fec7da3346ce84253d9857e21bf9bf31ac89f987fc193\";",
            "const PRIOR_V18_SYMLINK_TARGET_MANIFEST_SHA256: &str =\n" +
                "    \"ab17b5de2703ca8b990a315bb816165d6d6bdb898e2b7b6d8c9d59147cbd8fec\";",
            "const PRIOR_V18_STAGED_APP_XATTRS_SHA256: &str =\n" +
                "    \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const PRIOR_V18_FAILED_APP_XATTRS_SHA256: &str =\n" +
                "    \"b0c2e579015f38205979cf3ca99db2274e246a47b01f99c2f9cd46ef340c3f99\";",
            "const V20_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044\";",
        ]
        for anchor in exactPriorV18Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v18 anchor \(anchor)")
        }
        let priorV18RecordValidation = try sourceSection(
            controller,
            from: "fn validate_prior_v18_rolledback_records(",
            to: "struct PriorV18RetryGuard"
        )
        for required in [
            "journal != PRIOR_V18_FINAL_JOURNAL_FIXTURE",
            "journal.len() != PRIOR_V18_FINAL_JOURNAL_SIZE",
            "PRIOR_V18_FINAL_JOURNAL_LINES",
            "sha256_bytes(journal)? != PRIOR_V18_FINAL_JOURNAL_SHA256",
            "PRIOR_V18_PRECUTOVER_JOURNAL_LINE",
            "PRIOR_V18_GENERATION_JOURNAL_LINE",
            "PRIOR_V18_ROLLBACK_JOURNAL_TAIL",
            "result != PRIOR_V18_FINAL_RESULT",
            "sha256_bytes(result)? != PRIOR_V18_FINAL_RESULT_SHA256",
            "provenance != PRIOR_V18_PROVENANCE",
            "sha256_bytes(provenance)? != PRIOR_V18_PROVENANCE_SHA256",
            "deployment_stdout.len() != PRIOR_V18_DEPLOYMENT_STDOUT_SIZE",
            "sha256_bytes(deployment_stdout)? != PRIOR_V18_DEPLOYMENT_STDOUT_SHA256",
            "deployment_stderr != PRIOR_V18_DEPLOYMENT_STDERR_FIXTURE",
            "deployment_stderr.len() != PRIOR_V18_DEPLOYMENT_STDERR_SIZE",
            "sha256_bytes(deployment_stderr)? != PRIOR_V18_DEPLOYMENT_STDERR_SHA256",
            "deployment_stderr.ends_with(PRIOR_V18_DEPLOYMENT_STDERR_TAIL)",
            "trailing-ps-padding full rollback",
            "trailing ps lstart padding mismatch failure",
        ] {
            XCTAssertTrue(
                priorV18RecordValidation.contains(required),
                "The exact v18 process-start-padding rollback validator lacks \(required)"
            )
        }
        let priorV18Guard = try sourceSection(
            controller,
            from: "impl PriorV18RetryGuard {",
            to: "fn validate_prior_v18_rolledback_retry("
        )
        for required in [
            "PRIOR_V18_ACTIVE_RECORD", "PRIOR_V18_ACTIVE_SHA256",
            "PRIOR_V18_LEGACY_MANIFEST_SHA256", "PRIOR_V18_LEGACY_XATTRS_SHA256",
            "PRIOR_V18_STAGED_HASHES_SHA256", "PRIOR_V18_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V18_BUILD_STDOUT_SHA256", "PRIOR_V18_BUILD_STDERR_SHA256",
            "PRIOR_V18_DEPLOYMENT_STDERR_SHA256",
            "PRIOR_V18_ROLLBACK_RESERVE_SHA256", "PRIOR_V18_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V18_ROLLBACK_RESERVE_INODE", "PRIOR_V18_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V18_SOURCE_ARCHIVE_SHA256", "PRIOR_V18_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V18_STAGED_PLIST_SHA256", "PRIOR_V18_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V18_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V18_STAGED_APP_XATTRS_SHA256", "PRIOR_V18_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v18_rolledback_records(",
            "PRIOR_V18_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V18_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V18_ACTIVE_TRANSACTION_LINEARIZED_NAME",
        ] {
            XCTAssertTrue(priorV18Guard.contains(required), "The exact v18 guard lacks \(required)")
        }
        let exactPriorV19Anchors = [
            "const PRIOR_V19_ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v19\";",
            "const PRIOR_V19_ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v19.pending\";",
            "const PRIOR_V19_ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v19.finalizing\";",
            "const PRIOR_V19_ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v19.linearized\";",
            "const PRIOR_V19_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v19-after-v18-1785637636-18044\";",
            "const PRIOR_V19_ACTIVE_RECORD: &[u8] = b\"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v19-after-v18-1785637636-18044\\n\";",
            "9cdfaec20cc9d021e740a01eab6d23b4a3b6d594b86b94ea38bfaf27ee0895a5",
            "const PRIOR_V19_SOURCE_COMMIT: &str = \"ad8fc9550aafc8f396f0ed2763cf6bf2ead2065d\";",
            "const PRIOR_V19_SOURCE_TREE: &str = \"2c54cd942f402ba329d4da56a8e44ff474ebecce\";",
            "const PRIOR_V19_FINAL_JOURNAL_SIZE: usize = 8_577;",
            "const PRIOR_V19_FINAL_JOURNAL_LINES: usize = 19;",
            "76bfe35484cce970e33fe4dbfcfeab7cebf6f0877b38608805b5daaabbff1248",
            "rollback_reserve_inode=21610566",
            "const PRIOR_V19_NEW_BOOTSTRAPPED_JOURNAL_LINE: &[u8] = b\"STATE NEW_BOOTSTRAPPED\\n\";",
            "const PRIOR_V19_SOURCE_ARCHIVE_SIZE: u64 = 6_860_800;",
            "be65913f6ece9d3823be85458507e4dcc0d07885a78d3f62228b474e3058a57d",
            "9eca722ba0af8832de0eb154745447669865799d95546a5c7f8b2313be37e96a",
            "24acd59fff88632fe2686bdc1ac6077ebd1b7120482ed8bb1bca94c8ab57ef9b",
            "4a17e36549f35643588e45fa5810b99a75f75db19c473f38200aaffc1e8bd293",
            "df0cc65f41aca53e3cf44309c9b2eb405cabaae49ce70fcc1b2a67101082023d",
            "1099f10440ea8fb91a78cdc204bcd83bea9b53ee45aa0fcfc015ea0803273789",
            "const PRIOR_V19_ROLLBACK_RESERVE_INODE: u64 = 21_610_566;",
            "116d482fd058d6548b694da67fadde280a27d742b8bf8cb5be386963395510e7",
            "39f84781f035d29253ca5c515e58aa124330e965f3491c2bcde65fe9234c4f00",
            "8048a92d04b7928f760bf40d646e11d72dc9b42549fb95131116ac2874dfd511",
            "const V20_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v20-after-v19-1785637636-18044\";",
        ]
        for anchor in exactPriorV19Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v19 anchor \(anchor)")
        }
        let priorV19RecordValidation = try sourceSection(
            controller,
            from: "fn validate_prior_v19_rolledback_records(",
            to: "fn require_prior_v19_deployment_records_absent("
        )
        for required in [
            "journal.len() != PRIOR_V19_FINAL_JOURNAL_SIZE",
            "PRIOR_V19_FINAL_JOURNAL_LINES",
            "sha256_bytes(journal)? != PRIOR_V19_FINAL_JOURNAL_SHA256",
            "OPENSTEAMER_MIGRATION_JOURNAL_V19",
            "PRIOR_V19_PRECUTOVER_JOURNAL_LINE",
            "PRIOR_V19_NEW_BOOTSTRAPPED_JOURNAL_LINE",
            "PRIOR_V19_ROLLBACK_JOURNAL_TAIL",
            "PRIOR_V19_FORBIDDEN_JOURNAL_STATES",
            "result != PRIOR_V19_FINAL_RESULT",
            "provenance != PRIOR_V19_PROVENANCE",
        ] {
            XCTAssertTrue(
                priorV19RecordValidation.contains(required),
                "The exact v19 pre-generation rollback validator lacks \(required)"
            )
        }
        let priorV19Guard = try sourceSection(
            controller,
            from: "impl PriorV19RetryGuard {",
            to: "fn validate_prior_v19_rolledback_retry("
        )
        for required in [
            "PRIOR_V19_ACTIVE_RECORD", "PRIOR_V19_ACTIVE_SHA256",
            "PRIOR_V19_LEGACY_MANIFEST_SHA256", "PRIOR_V19_LEGACY_XATTRS_SHA256",
            "PRIOR_V19_STAGED_HASHES_SHA256", "PRIOR_V19_SOURCE_EXPORT_MANIFEST_SHA256",
            "PRIOR_V19_BUILD_STDOUT_SHA256", "PRIOR_V19_BUILD_STDERR_SHA256",
            "PRIOR_V19_ROLLBACK_RESERVE_SHA256", "PRIOR_V19_ROLLBACK_RESERVE_DEVICE",
            "PRIOR_V19_ROLLBACK_RESERVE_INODE", "PRIOR_V19_SOURCE_ARCHIVE_SIZE",
            "PRIOR_V19_SOURCE_ARCHIVE_SHA256", "PRIOR_V19_STAGED_EXECUTABLE_SHA256",
            "PRIOR_V19_STAGED_PLIST_SHA256", "PRIOR_V19_STAGED_APP_MANIFEST_SHA256",
            "PRIOR_V19_SYMLINK_TARGET_MANIFEST_SHA256",
            "PRIOR_V19_STAGED_APP_XATTRS_SHA256", "PRIOR_V19_FAILED_APP_XATTRS_SHA256",
            "validate_prior_v19_rolledback_records(",
            "require_prior_v19_deployment_records_absent",
            "PRIOR_V19_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_LINEARIZED_NAME",
        ] {
            XCTAssertTrue(priorV19Guard.contains(required), "The exact v19 guard lacks \(required)")
        }
        let aggregateResidueGuard = try sourceSection(
            controller,
            from: "fn require_all_prior_retry_residues_absent(",
            to: "struct PriorV9RetryGuard"
        )
        for version in 9...19 {
            XCTAssertTrue(
                aggregateResidueGuard.contains("\"v\(version)\""),
                "Aggregate historical residue proof omits v\(version)."
            )
        }
        for required in [
            "PRIOR_V19_ACTIVE_TRANSACTION_PENDING_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_FINALIZING_NAME",
            "PRIOR_V19_ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "Path::new(PRIOR_V19_EVIDENCE_PATH)",
        ] {
            XCTAssertTrue(
                aggregateResidueGuard.contains(required),
                "Aggregate historical residue proof lacks \(required)"
            )
        }
        let v20RollbackHiddenPaths = try sourceSection(
            controller,
            from: "fn rollback_hidden_paths(",
            to: "fn clear_new_live_destinations("
        )
        for required in [
            ".opensteamer-disabled-v20-{tag}",
            ".org.example.opensteamer.worldwide.plist.disabled-v20-{tag}",
            "layout.install_app_hold()?",
            "layout.install_plist_hold()?",
        ] {
            XCTAssertTrue(
                v20RollbackHiddenPaths.contains(required),
                "The v20 rollback namespace lacks \(required)"
            )
        }
        XCTAssertTrue(
            controller.contains(
                "            start_new(\n" +
                    "                repo,\n" +
                    "                private_root,\n" +
                    "                prior_v9,\n" +
                    "                prior_v10,\n" +
                    "                prior_v11,\n" +
                    "                prior_v12,\n" +
                    "                prior_v13,\n" +
                    "                prior_v14,\n" +
                    "                prior_v15,\n" +
                    "                prior_v16,\n" +
                    "                prior_v17,\n" +
                    "                prior_v18,\n" +
                    "                prior_v19,\n" +
                    "            )"
            ),
            "All eleven exact historical guards are not passed into the v20 transaction."
        )
        XCTAssertTrue(
            controller.contains(
                "    prior_v17: PriorV17RetryGuard,\n" +
                    "    prior_v18: PriorV18RetryGuard,\n" +
                    "    prior_v19: PriorV19RetryGuard,\n" +
                    ") -> Result<()> {"
            ),
            "The exact prior-v19 guard is not owned by v20 startup."
        )
        for (name, type) in [
            ("prior_v9", "PriorV9RetryGuard"),
            ("prior_v10", "PriorV10RetryGuard"),
            ("prior_v11", "PriorV11RetryGuard"),
            ("prior_v12", "PriorV12RetryGuard"),
            ("prior_v13", "PriorV13RetryGuard"),
            ("prior_v14", "PriorV14RetryGuard"),
            ("prior_v15", "PriorV15RetryGuard"),
            ("prior_v16", "PriorV16RetryGuard"),
            ("prior_v17", "PriorV17RetryGuard"),
            ("prior_v18", "PriorV18RetryGuard"),
            ("prior_v19", "PriorV19RetryGuard"),
        ] {
            XCTAssertGreaterThanOrEqual(
                controller.components(separatedBy: "\(name): &'a \(type),").count - 1,
                2,
                "Historical guard \(name) is not retained by the real backend and constructor."
            )
            XCTAssertTrue(
                controller.contains("\(name): &\(type),"),
                "Historical guard \(name) is not threaded through the transaction contract."
            )
        }
        XCTAssertTrue(
            controller.contains(
                "            &prior_v17,\n" +
                    "            &prior_v18,\n" +
                    "            &prior_v19,\n" +
                    "        )"
            ),
            "The exact prior-v19 guard is not threaded into the v20 transaction."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "prior_v19: &'a PriorV19RetryGuard,"
            ).count - 1,
            2,
            "The exact prior-v19 guard is not retained by the real backend and constructor."
        )
        XCTAssertTrue(
            controller.contains(
                "    prior_v17: &PriorV17RetryGuard,\n" +
                    "    prior_v18: &PriorV18RetryGuard,\n" +
                    "    prior_v19: &PriorV19RetryGuard,\n" +
                    ") -> Result<()> {"
            ),
            "The exact prior-v19 guard is not part of the transaction contract."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "validate_prior_v19_rolledback_retry(private_root)?;"
            ).count - 1,
            2,
            "The exact prior-v19 guard is not acquired by both preflight and execution."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v9.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v9 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v10.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v10 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v11.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v11 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v12.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v12 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v13.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v13 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v14.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v14 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v15.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v15 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v16.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v16 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v17.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v17 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v18.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v18 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v19.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v19 tombstone is not revalidated throughout v20 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v9.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v9 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v10.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v10 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v11.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v11 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v12.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v12 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v13.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v13 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v14.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v14 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v15.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v15 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v16.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v16 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v17.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v17 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v18.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v18 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.prior_v19.revalidate(self.private_root)?;"
            ).count - 1,
            2,
            "The prior-v19 tombstone is not revalidated at both legacy stop boundaries."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "require_all_prior_retry_residues_absent(self.private_root)?;"
            ).count - 1,
            2,
            "Historical pointer and cutover residues lack a final aggregate stop-boundary check."
        )
        XCTAssertTrue(
            controller.contains(
                ") -> Result<()> {\n    require_fresh_retry_disk_headroom()?;\n" +
                    "    let layout = Layout::create(repo)?;"
            ),
            "The 2 GiB fresh-attempt gate must run before v20 creates its evidence tree."
        )
        XCTAssertTrue(
            controller.contains(
                "let readiness_deadline = deadline_after(DEPLOYMENT_VERIFIER_TIMEOUT)?;"
            ) &&
                controller.contains("self.readiness_deadline = Some(readiness_deadline);") &&
                controller.contains("verify_deployment_with_prefix_until(") &&
                controller.contains("        deadline,\n    )"),
            "The whole production deployment proof does not share one absolute deadline."
        )
        let forwardCommitRevalidation = try sourceSection(
            controller,
            from: "fn revalidate_commit_fields(&mut self, fields: &[(String, String)]) -> Result<()> {\n" +
                "        let expected_fields",
            to: "fn after_commit_revalidation_before_durable_write"
        )
        XCTAssertTrue(forwardCommitRevalidation.contains("self.readiness_deadline.ok_or_else"))
        XCTAssertFalse(
            forwardCommitRevalidation.contains("deadline_after("),
            "Final forward COMMIT acceptance must not manufacture a fresh deadline."
        )
        let committedRetainedPointerRevalidation = try sourceSection(
            controller,
            from: "fn revalidate_current_generation_for_retained_pointer(&self) -> Result<()> {",
            to: "impl CommittedRecoveryBackend for RealCommittedRecoveryBackend"
        )
        XCTAssertTrue(
            committedRetainedPointerRevalidation.contains("self.readiness_deadline.ok_or_else")
        )
        XCTAssertFalse(
            committedRetainedPointerRevalidation.contains("deadline_after("),
            "Committed-recovery retained-pointer acceptance must reuse its READY deadline."
        )
        let generationRevalidation = try sourceSection(
            controller,
            from: "fn verify_launch_generation_until(",
            to: "fn verify_launch_generation("
        )
        XCTAssertTrue(
            generationRevalidation.contains(
                "prove_generation_lock_held_only_by_until(expected, deadline)?;"
            ),
            "Final generation acceptance must prove that the expected PID still holds the lock."
        )
        let lockHolderProof = try sourceSection(
            controller,
            from: "fn prove_lock_held_only_by_once(",
            to: "fn prove_lock_held_only_by_until("
        )
        XCTAssertTrue(lockHolderProof.contains("openers_after_probe"))
        XCTAssertTrue(lockHolderProof.contains("openers_after_reprobe"))
        XCTAssertTrue(lockHolderProof.contains("expected_openers_after_probe"))
        XCTAssertTrue(
            lockHolderProof.contains(
                "shared advisory lock became acquirable after holder attribution"
            )
        )
        XCTAssertGreaterThanOrEqual(
            lockHolderProof.components(separatedBy: "lsof_openers_until(").count - 1,
            3,
            "Lock ownership must be re-read after both failed contention probes."
        )
        let lockHolderRetry = try sourceSection(
            controller,
            from: "fn prove_lock_held_only_by_until(",
            to: "fn prove_generation_lock_held_only_by_until("
        )
        XCTAssertTrue(lockHolderRetry.contains("LOCK_OPENER_SETTLE_ATTEMPTS"))
        XCTAssertTrue(lockHolderRetry.contains("TransientReaders"))
        XCTAssertTrue(lockHolderRetry.contains("sleep_before_lock_proof_retry(deadline)?"))
        let lockProbeCLI = try sourceSection(
            controller,
            from: "fn probe_lock_cli(",
            to: "fn parse_lsof_openers("
        )
        XCTAssertTrue(lockProbeCLI.contains("runtime != Path::new(LOCK_DIRECTORY)"))
        XCTAssertTrue(lockProbeCLI.contains("lock_path != Path::new(LOCK_FILE)"))
        XCTAssertTrue(
            lockProbeCLI.contains(
                "prove_lock_held_only_by_until(expected_pid, deadline_after(DEFAULT_COMMAND_TIMEOUT)?)?;"
            ),
            "The deployed verifier CLI must reuse the reviewed two-probe lock proof."
        )
        XCTAssertFalse(lockProbeCLI.contains("open_existing_regular"))
        XCTAssertFalse(lockProbeCLI.contains("lsof_holders("))
        let lsofParser = try sourceSection(
            controller,
            from: "fn parse_lsof_openers(",
            to: "fn validate_logs_precutover()"
        )
        XCTAssertTrue(lsofParser.contains("LockFileAccessMode::Read"))
        XCTAssertTrue(lsofParser.contains("LockFileAccessMode::Write"))
        XCTAssertTrue(lsofParser.contains("LockFileAccessMode::ReadWrite"))
        XCTAssertTrue(lsofParser.contains(#"OsStr::new("-F")"#))
        XCTAssertTrue(lsofParser.contains(#"OsStr::new("paf")"#))
        XCTAssertFalse(lsofParser.contains(#"OsStr::new("-t")"#))
        let generationLockProof = try sourceSection(
            controller,
            from: "fn prove_generation_lock_held_only_by_until(",
            to: "fn prove_lock_acquirable_until("
        )
        XCTAssertTrue(generationLockProof.contains("read_generation_record()?"))
        XCTAssertGreaterThanOrEqual(
            generationLockProof.components(
                separatedBy: "prove_lock_held_only_by_until(expected.pid, deadline)?;"
            ).count - 1,
            2,
            "Generation-record revalidation must be bracketed by exact holder proofs."
        )
        let retainedPointerAcceptance = try sourceSection(
            controller,
            from: "fn verify_retained_active_pointer_after_commit<P, H>(",
            to: "fn entry_exists("
        )
        XCTAssertTrue(retainedPointerAcceptance.contains("deadline: Instant"))
        XCTAssertGreaterThanOrEqual(
            retainedPointerAcceptance.components(
                separatedBy: "require_before_deadline(deadline, \"retained active-pointer acceptance\")"
            ).count - 1,
            4,
            "Every retained-pointer acceptance boundary must stay inside the READY deadline."
        )
        XCTAssertFalse(retainedPointerAcceptance.contains("deadline_after("))
        XCTAssertTrue(controller.contains("retained-active-expired-deadline"))
        let preflight = try sourceSection(
            controller,
            from: "fn verify_prior_retry_state_cli()",
            to: "fn execute("
        )
        XCTAssertTrue(preflight.contains("verify_deployment_verifier_system_commands()?;"))
        XCTAssertTrue(controller.contains("(\"/bin/dd\", 0o755)"))
        XCTAssertTrue(controller.contains("(\"/bin/ps\", 0o4755)"))
        XCTAssertTrue(controller.contains("(\"/usr/bin/stat\", 0o755)"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.checkpoint = Some(checkpoint_prelaunch_log()?);\n" +
                    "                bootstrap_exact_plist(Path::new(NEW_PLIST))"
            ).count - 1,
            2,
            "Both real bootstrap adapters must capture the prelaunch checkpoint and bootstrap " +
                "adjacently, without a hook or command between them."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.world.marker_generation = Some(self.world.generation);"
            ).count - 1,
            2,
            "Forward and committed-recovery fakes must model a marker emitted immediately at bootstrap."
        )
        let drainStart = try XCTUnwrap(controller.range(of: "fn drain_nonblocking"))
        let drainEnd = try XCTUnwrap(
            controller.range(
                of: "fn terminate_process_group_and_reap",
                range: drainStart.upperBound..<controller.endIndex
            )
        )
        let drainImplementation = String(controller[drainStart.lowerBound..<drainEnd.lowerBound])
        XCTAssertTrue(drainImplementation.contains("MAX_DRAIN_BYTES_PER_POLL"))
        XCTAssertFalse(
            drainImplementation.contains("deadline") || drainImplementation.contains("Instant"),
            "Pipe drains must be deadline-neutral; only the outer runner classifies expiry."
        )
        XCTAssertTrue(controller.contains("const MAX_DRAIN_BYTES_PER_POLL: usize = 64 * 1024;"))
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "canonical_command_timeout_error(").count - 1,
            3,
            "All command-runner timeout branches must use one canonical diagnostic."
        )
        for regression in [
            "deadline-edge",
            "output-flood",
            "inherited-pipe",
            "total-deployment-deadline",
            "fast-marker",
        ] {
            XCTAssertTrue(
                controller.contains(regression),
                "Controller lacks the \(regression) regression model."
            )
        }
        let deploymentUntilStart = try XCTUnwrap(
            controller.range(of: "fn verify_deployment_with_prefix_until(")
        )
        let deploymentUntilEnd = try XCTUnwrap(
            controller.range(
                of: "#[derive(Clone, Copy, Debug, Eq, PartialEq)]\nenum EffectPhase",
                range: deploymentUntilStart.upperBound..<controller.endIndex
            )
        )
        let deploymentUntil = String(
            controller[deploymentUntilStart.lowerBound..<deploymentUntilEnd.lowerBound]
        )
        XCTAssertTrue(deploymentUntil.contains("deadline: Instant"))
        XCTAssertFalse(
            deploymentUntil.contains("deadline_after("),
            "Nested deployment steps must not reset the one 180-second deadline."
        )
        XCTAssertFalse(controller.contains("PRIOR_V15_DEPLOYMENT_STDOUT_SHA256"))
        XCTAssertFalse(controller.contains("PRIOR_V15_DEPLOYMENT_STDERR_SHA256"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "require_prior_v15_deployment_records_absent("
            ).count - 1,
            4,
            "The v15 guard must acquire and repeatedly revalidate absence of both deployment records."
        )
        let deploymentAbsenceStart = try XCTUnwrap(
            controller.range(of: "fn require_prior_v15_deployment_records_absent(")
        )
        let deploymentAbsenceEnd = try XCTUnwrap(
            controller.range(
                of: "struct PriorV15RetryGuard",
                range: deploymentAbsenceStart.upperBound..<controller.endIndex
            )
        )
        let deploymentAbsenceGuard = String(
            controller[deploymentAbsenceStart.lowerBound..<deploymentAbsenceEnd.lowerBound]
        )
        XCTAssertTrue(deploymentAbsenceGuard.contains("\"deployment.stdout\""))
        XCTAssertTrue(deploymentAbsenceGuard.contains("\"deployment.stderr\""))
        XCTAssertFalse(controller.contains("Path::new(\"/bin/chflags\")"))
        XCTAssertFalse(
            controller.contains("Duration::from_secs(15)"),
            "Cold deep-signature validation has exceeded 15 seconds on the deployment Mac."
        )
        XCTAssertFalse(controller.contains("fs::rename(&install_hold, NEW_APP)"))
        XCTAssertFalse(controller.contains("fs::rename(&plist_hold, NEW_PLIST)"))
        XCTAssertFalse(controller.contains("fs::rename(LEGACY_APP"))
        XCTAssertFalse(controller.contains("fs::remove_file(LEGACY_PLIST"))
        let protectedRecoveryPrefix = "/Applications/.audio" + "streamer-"
        XCTAssertFalse(controller.contains(protectedRecoveryPrefix))
        XCTAssertFalse(controller.contains("unlinkat("))
        XCTAssertFalse(controller.contains("publish_active_pointer_linearization"))
        XCTAssertFalse(controller.contains("clear_active("))
        XCTAssertFalse(controller.contains("finalize_active_pointer_with_generation_proof"))
    }

    func testV20DocumentationPinsTheCommittedCutover() throws {
        let migrationGuide = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HOST_MIGRATION.md"),
            encoding: .utf8
        )
        let protectedRuntimeGuide = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "USER_PROTECTED_LEGACY_RUNTIME.md"
            ),
            encoding: .utf8
        )
        let exactPreflightOutput =
            "PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14=v15=v16=v17=v18=v19 " +
            "legacy=sole-ready v20=absent"

        for required in [
            "The current controller owns the version-20 active-pointer and journal namespace.",
            "version 19 was byte-for-byte the reviewed transient-lock-opener rollback below",
            "The version-20 design adds an exact eleventh historical guard",
            "PID-only `lsof` interpretation",
            "bounded restart of the complete lock-path",
            "validates all eleven historical",
            exactPreflightOutput,
            "The authorized version-20 transaction committed successfully",
            "authorization is consumed.",
            "migrate-opensteamer-host.sh --verify-reviewed-prior-retry-state",
        ] {
            XCTAssertTrue(migrationGuide.contains(required), "Migration guide lacks \(required)")
        }
        for required in [
            "During the second lock-contention probe",
            "Controller version 20 committed successfully.",
            "eleventh historical guard pins that complete version-19 rollback",
            "strictly and completely parses",
            "transient read-only opener",
            "all version-9",
            "through version-19 tombstones",
            exactPreflightOutput,
            "The version-20 authorization is consumed.",
        ] {
            XCTAssertTrue(
                protectedRuntimeGuide.contains(required),
                "Protected-runtime guide lacks \(required)"
            )
        }
    }

    func testProductionReadinessMarkerUsesHeldLockGenerationIdentity() throws {
        let main = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/CaptureServerMain.swift"
            ),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideHostCoordinator.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(main.contains("availabilityMarkerProcessIdentifier:"))
        XCTAssertTrue(main.contains("ProcessInfo.processInfo.processIdentifier"))
        XCTAssertTrue(main.contains("availabilityMarkerGenerationNonce:"))
        XCTAssertTrue(main.contains("worldwideHostProcessLock.generationNonce"))
        XCTAssertTrue(
            coordinator.contains(
                "Worldwide paired-device availability is online \" +"
            )
        )
        XCTAssertTrue(coordinator.contains("pid=\\(availabilityMarkerProcessIdentifier)"))
        XCTAssertTrue(coordinator.contains("nonce=\\(availabilityMarkerGenerationNonce)"))
    }

    func testV20PreflightReadinessDeadlineAndInstalledMACLContracts() throws {
        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/opensteamer-host-migration-controller.rs"
            ),
            encoding: .utf8
        )
        let deploymentVerifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-deployment.sh"
            ),
            encoding: .utf8
        )
        let bundleVerifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-bundle.sh"
            ),
            encoding: .utf8
        )

        let preflight = try sourceSection(
            controller,
            from: "fn verify_prior_retry_state_cli()",
            to: "fn execute("
        )
        XCTAssertTrue(preflight.contains("InspectionTransactionLock::acquire()?"))
        XCTAssertTrue(preflight.contains("inspect_active_pointer_read_only(private_root)?"))
        for version in 9...19 {
            let validator = version == 9
                ? "validate_prior_v9_prestop_retry(private_root)?;"
                : "validate_prior_v\(version)_rolledback_retry(private_root)?;"
            XCTAssertTrue(
                preflight.contains(validator),
                "Read-only v20 preflight does not acquire the exact v\(version) guard."
            )
            XCTAssertTrue(
                preflight.contains("prior_v\(version).revalidate(private_root)?;"),
                "Read-only v20 preflight does not revalidate the exact v\(version) guard."
            )
        }
        XCTAssertTrue(preflight.contains("require_all_prior_retry_residues_absent(private_root)?;"))
        XCTAssertTrue(preflight.contains("require_fresh_retry_disk_headroom()?;"))
        XCTAssertTrue(preflight.contains("entry_exists(Path::new(V20_EVIDENCE_PATH))?"))
        XCTAssertTrue(
            preflight.contains(
                "PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14=v15=v16=v17=v18=v19 " +
                    "legacy=sole-ready v20=absent"
            )
        )
        let finalAcceptanceSequence = [
            "prior_v19.revalidate(private_root)?;",
            "require_all_prior_retry_residues_absent(private_root)?;",
            "require_fresh_retry_disk_headroom()?;",
            "let acceptance_deadline = deadline_after(LEGACY_READINESS_TIMEOUT)?;",
            "prove_new_host_absent_during_rollback_until(acceptance_deadline)?;",
            "verify_legacy_static_until(acceptance_deadline)?;",
            "verify_legacy_disabled_until(false, acceptance_deadline)?;",
            "wait_for_exact_legacy_readiness_until(acceptance_deadline)?;",
            "if entry_exists(Path::new(V20_EVIDENCE_PATH))? {",
            "require_before_deadline(acceptance_deadline, \"prior-retry preflight acceptance\")?;",
            "println!(",
            "\"PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14=v15=v16=v17=v18=v19 " +
                "legacy=sole-ready v20=absent\"",
        ]
        var acceptanceCursor = preflight.startIndex
        for required in finalAcceptanceSequence {
            let range = try XCTUnwrap(
                preflight.range(of: required, range: acceptanceCursor..<preflight.endIndex),
                "Final v20 preflight acceptance sequence lacks \(required)"
            )
            acceptanceCursor = range.upperBound
        }
        XCTAssertEqual(
            preflight.components(separatedBy: "deadline_after(LEGACY_READINESS_TIMEOUT)?").count - 1,
            1,
            "Final preflight acceptance must use one newly-created shared legacy deadline."
        )
        for forbidden in [
            "recover_active_pointer(", "rename_exclusive(", "write_active(",
            "create_new_regular(", "set_len(", "write_all(", "remove_file(",
        ] {
            XCTAssertFalse(preflight.contains(forbidden), "Read-only preflight contains \(forbidden)")
        }
        let pointerInspection = try sourceSection(
            controller,
            from: "fn inspect_active_pointer_read_only(",
            to: "fn recover_active_pointer("
        )
        for required in [
            "ACTIVE_TRANSACTION_NAME", "ACTIVE_TRANSACTION_PENDING_NAME",
            "ACTIVE_TRANSACTION_FINALIZING_NAME", "ACTIVE_TRANSACTION_LINEARIZED_NAME",
            "parse_v20_active_record",
        ] {
            XCTAssertTrue(pointerInspection.contains(required))
        }
        for forbidden in [
            "rename_exclusive(", "create_new_regular(", "remove_file(",
            "set_len(", "write_all(",
        ] {
            XCTAssertFalse(
                pointerInspection.contains(forbidden),
                "Pointer inspection must retain exact residue: \(forbidden)"
            )
        }

        XCTAssertTrue(controller.contains("expected_online_marker_for_generation"))
        XCTAssertFalse(controller.contains("line.contains(ONLINE_MARKER"))
        XCTAssertTrue(controller.contains("read_bounded_log_suffix_until"))
        let markerWait = try sourceSection(
            controller,
            from: "fn wait_for_online_marker_for_generation_until(",
            to: "fn verify_code_identity_until("
        )
        XCTAssertTrue(markerWait.contains("read_bounded_log_suffix_until"))
        XCTAssertFalse(markerWait.contains("read_to_string"))
        XCTAssertTrue(deploymentVerifier.contains("MAX_READINESS_LOG_SUFFIX_BYTES"))
        XCTAssertTrue(deploymentVerifier.contains("LOG_SUFFIX_BYTES"))
        XCTAssertTrue(deploymentVerifier.contains("count=\"$LOG_READ_LIMIT\""))
        XCTAssertTrue(
            deploymentVerifier.contains("post-start log suffix exceeds the bounded readiness limit")
        )

        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "readiness_deadline: Option<Instant>").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "self.readiness_deadline = Some(readiness_deadline);"
            ).count - 1,
            2
        )
        XCTAssertTrue(controller.contains("fn revalidate_until(&self, deadline: Instant)"))
        XCTAssertTrue(controller.contains("wait_for_online_marker_for_generation_until("))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "require_marker_after_checkpoint_until("
            ).count - 1,
            4
        )
        let deploymentProof = try sourceSection(
            controller,
            from: "fn verify_deployment_with_prefix_until(",
            to: "#[derive(Clone, Copy, Debug, Eq, PartialEq)]\nenum EffectPhase"
        )
        XCTAssertTrue(deploymentProof.contains("deadline: Instant"))
        XCTAssertTrue(deploymentProof.contains("run_pinned_script_until("))
        XCTAssertFalse(deploymentProof.contains("deadline_after("))

        for required in [
            "INSTALLED_RUNTIME_APP_PATH=\"/Applications/opensteamer Host.app\"",
            "XATTR_POLICY=\"strict\"", "XATTR_POLICY=\"installed-runtime\"",
            "--installed-runtime is restricted to", "EXPECTED_RUNTIME_XATTR=\"$APP_PATH: com.apple.macl\"",
            "${#MACL_HEX} -eq 144", "\"$MACL_HEX\" != *[!0]*", "XATTRS_AFTER",
            "APP_ROOT_DEVICE_INODE", "verify_xattr_policy", "/usr/bin/xattr -rs",
            "INITIAL_XATTR_POLICY_SNAPSHOT",
            "app root or extended-attribute policy changed during signature verification",
            "installed app contains unreviewed extended attributes",
            "installed app com.apple.macl is not exactly 72 NUL bytes",
        ] {
            XCTAssertTrue(bundleVerifier.contains(required), "Bundle verifier lacks \(required)")
        }
        XCTAssertEqual(
            deploymentVerifier.components(
                separatedBy: "run_bundle_verifier --installed-runtime"
            ).count - 1,
            1,
            "Installed-runtime MACL mode must be used exactly once."
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "run_bundle_verifier \"$BUILD_APP_DIR\" \"$EXPECTED_TEAM_ID\""
            ),
            "The staged bundle must remain on the strict xattr-free verifier path."
        )
        XCTAssertTrue(
            controller.contains(
                "OsStr::new(\"--installed-runtime\"),\n            OsStr::new(NEW_APP)"
            ),
            "Installed-destination verification must select canonical MACL mode."
        )
    }

    func testShellVerifiersParseAndLintWithoutExecutingMigration() throws {
        let zshScripts = [
            "macOS/scripts/build-opensteamer-host-app.sh",
            "macOS/scripts/verify-mac-host-bundle.sh",
            "macOS/scripts/verify-mac-host-launch-state.sh",
            "macOS/scripts/verify-mac-host-deployment.sh",
            "macOS/scripts/verify-live-mac-host-process.sh",
        ]
        for relative in zshScripts {
            let path = repositoryRoot.appendingPathComponent(relative)
            let syntax = try run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-n", path.path]
            )
            XCTAssertEqual(syntax.status, 0, "Syntax failed for \(relative).\n\(syntax.diagnostic)")
        }

        let deploymentVerifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-deployment.sh"
            ),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/opensteamer-host-migration-controller.rs"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(deploymentVerifier.contains("STABILITY_SAMPLES=44"))
        XCTAssertTrue(deploymentVerifier.contains("STABILITY_SAMPLE_DELAY=0.25"))
        XCTAssertTrue(
            deploymentVerifier.contains(
                "shared-lock proof failed during continuous sample"
            )
        )
        XCTAssertTrue(deploymentVerifier.contains("--self-test-disabled-parser"))
        XCTAssertTrue(deploymentVerifier.contains("--self-test-zsh-runtime"))
        XCTAssertTrue(
            deploymentVerifier.contains(
                "/usr/bin/codesign -dv --verbose=4 \"$1\" 2>&1 | parse_code_hash"
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "Consume the complete producer stream before deciding validity"
            )
        )
        XCTAssertTrue(deploymentVerifier.contains("can SIGPIPE codesign under zsh pipefail"))
        XCTAssertTrue(
            deploymentVerifier.contains(
                "full-consuming CDHash parser rejected a large stream with pipeline status"
            )
        )
        XCTAssertTrue(deploymentVerifier.contains("if (records != 1 || malformed) exit 65"))
        XCTAssertTrue(deploymentVerifier.contains("for (line=0; line < 65536; line++)"))
        XCTAssertTrue(deploymentVerifier.contains("CDHash parser accepted duplicate hashes"))
        XCTAssertTrue(deploymentVerifier.contains("CDHash parser accepted a malformed hash"))
        XCTAssertTrue(deploymentVerifier.contains("CDHash parser accepted a missing hash"))
        XCTAssertTrue(deploymentVerifier.contains("parse_manifest_unsigned_value pid"))
        XCTAssertTrue(deploymentVerifier.contains("parse_manifest_unsigned_value runs"))
        XCTAssertTrue(deploymentVerifier.contains("parse_process_start_identity"))
        XCTAssertTrue(deploymentVerifier.contains("`ps -o lstart=`"))
        XCTAssertTrue(deploymentVerifier.contains("`str::trim`"))
        XCTAssertTrue(
            deploymentVerifier.contains(#"sub(/^[[:space:]]+/, "", value)"#)
        )
        XCTAssertTrue(
            deploymentVerifier.contains(#"sub(/[[:space:]]+$/, "", value)"#)
        )
        XCTAssertTrue(deploymentVerifier.contains("function valid_process_start(value"))
        XCTAssertGreaterThanOrEqual(
            deploymentVerifier.components(
                separatedBy: "if (records != 1 || malformed) exit 65"
            ).count - 1,
            3,
            "Each strict single-record parser must reject malformed input."
        )
        XCTAssertTrue(deploymentVerifier.contains("expected_start=\"Sun Aug  2 16:35:42 2026\""))
        XCTAssertTrue(
            deploymentVerifier.contains(
                "full-consuming process-start parser rejected padded output"
            )
        )
        XCTAssertTrue(deploymentVerifier.contains("process-start parser returned"))
        XCTAssertTrue(
            deploymentVerifier.contains("process-start parser accepted multiple nonempty records")
        )
        XCTAssertTrue(deploymentVerifier.contains("process-start parser accepted a missing record"))
        XCTAssertTrue(deploymentVerifier.contains("process-start parser accepted a malformed record"))
        XCTAssertTrue(
            deploymentVerifier.contains("process-start parser accepted an out-of-range record")
        )
        XCTAssertTrue(controller.contains("fn valid_process_start_identity(value: &str) -> bool"))
        XCTAssertTrue(
            controller.contains(
                "process start identity is not one canonical C-locale lstart record"
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "process-start parser pipeline accepted output from a failed producer"
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "could not read PID start identity during the continuous proof"
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "expected process start identity is not canonically normalized"
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                #"start_one="$(/bin/ps -p "$pid_one" -o lstart= 2>/dev/null \"#
            ),
            "The initial live process-start read must be separately error checked."
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                #"start_two="$(/bin/ps -p "$pid_two" -o lstart= 2>/dev/null \"#
            ),
            "The stability-loop process-start read must be separately error checked."
        )
        XCTAssertFalse(
            deploymentVerifier.contains(
                #"$1 == "CDHash" {print tolower($2); exit}"#
            )
        )
        XCTAssertFalse(
            deploymentVerifier.contains(
                #"awk -F= '$1 == "CDHash" {print tolower($2); exit}'"#
            ),
            "The v17 status-141 early-exit CDHash parser must not return."
        )
        XCTAssertFalse(
            deploymentVerifier.contains(#"$1 == "pid" {print $2; exit}"#)
        )
        XCTAssertFalse(
            deploymentVerifier.contains(#"$1 == "runs" {print $2; exit}"#)
        )
        XCTAssertTrue(deploymentVerifier.contains("EXPECTED_GENERATION_NONCE"))
        XCTAssertTrue(
            deploymentVerifier.contains(
                "ONLINE_MARKER_PREFIX=\"[info] Worldwide paired-device availability is online\""
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "EXPECTED_ONLINE_MARKER=\"$ONLINE_MARKER_PREFIX pid=$EXPECTED_PID nonce=$EXPECTED_GENERATION_NONCE\""
            )
        )
        XCTAssertTrue(
            deploymentVerifier.contains(
                "contains_exact_line \"$LOG_SUFFIX\" \"$EXPECTED_ONLINE_MARKER\""
            )
        )
        XCTAssertFalse(deploymentVerifier.contains("grep -Fxq"))
        XCTAssertTrue(deploymentVerifier.contains("/usr/bin/grep -Fx -- \"$expected\" >/dev/null"))
        XCTAssertTrue(deploymentVerifier.contains("${(l:262144::x:)padding}"))
        XCTAssertTrue(deploymentVerifier.contains("run_bundle_verifier --installed-runtime"))
        XCTAssertEqual(
            deploymentVerifier.components(
                separatedBy: "run_bundle_verifier --installed-runtime"
            ).count - 1,
            1,
            "The relaxed xattr policy must be used only for the canonical installed-app check."
        )
        XCTAssertTrue(deploymentVerifier.contains("validate_generation_record"))
        XCTAssertTrue(deploymentVerifier.contains("local state_path=\"$1\""))
        let expectedSystemCommands: Set<String> = [
            "/bin/dd",
            "/bin/kill",
            "/bin/launchctl",
            "/bin/ps",
            "/bin/rm",
            "/bin/sleep",
            "/bin/zsh",
            "/usr/bin/awk",
            "/usr/bin/cmp",
            "/usr/bin/codesign",
            "/usr/bin/diff",
            "/usr/bin/dirname",
            "/usr/bin/grep",
            "/usr/bin/mktemp",
            "/usr/bin/shasum",
            "/usr/bin/stat",
        ]
        let declarationRegex = try NSRegularExpression(
            pattern: #"(?s)readonly -a REQUIRED_SYSTEM_COMMANDS=\(\n(.*?)\n\)"#
        )
        let declarationRange = NSRange(
            deploymentVerifier.startIndex..<deploymentVerifier.endIndex,
            in: deploymentVerifier
        )
        let declarationMatch = try XCTUnwrap(
            declarationRegex.firstMatch(
                in: deploymentVerifier,
                range: declarationRange
            )
        )
        let declaredCommandsRange = try XCTUnwrap(
            Range(declarationMatch.range(at: 1), in: deploymentVerifier)
        )
        let declaredSystemCommands = Set(
            deploymentVerifier[declaredCommandsRange]
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )
        XCTAssertEqual(declaredSystemCommands, expectedSystemCommands)
        let controllerCommandsRegex = try NSRegularExpression(
            pattern: #"(?s)const DEPLOYMENT_VERIFIER_REQUIRED_SYSTEM_COMMANDS: &\[\(&str, u32\)\] = &\[\n(.*?)\n\];"#
        )
        let controllerRange = NSRange(controller.startIndex..<controller.endIndex, in: controller)
        let controllerCommandsMatch = try XCTUnwrap(
            controllerCommandsRegex.firstMatch(in: controller, range: controllerRange)
        )
        let controllerCommandsRange = try XCTUnwrap(
            Range(controllerCommandsMatch.range(at: 1), in: controller)
        )
        let controllerCommandsSection = String(controller[controllerCommandsRange])
        let controllerCommandRegex = try NSRegularExpression(
            pattern: #"\(\"([^\"]+)\", 0o[0-7]+\)"#
        )
        let controllerSectionRange = NSRange(
            controllerCommandsSection.startIndex..<controllerCommandsSection.endIndex,
            in: controllerCommandsSection
        )
        let controllerSystemCommands = Set(
            controllerCommandRegex.matches(
                in: controllerCommandsSection,
                range: controllerSectionRange
            ).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: controllerCommandsSection) else {
                    return nil
                }
                return String(controllerCommandsSection[range])
            }
        )
        XCTAssertEqual(
            controllerSystemCommands,
            expectedSystemCommands,
            "The Rust read-only preflight command gate diverged from the deployment verifier."
        )
        let executableLiteralRegex = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.-])(/(?:(?:usr/)?s?bin|usr/libexec)/[A-Za-z0-9_.+-]+)"#
        )
        let executableLiterals = Set(
            executableLiteralRegex.matches(in: deploymentVerifier, range: declarationRange)
                .compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: deploymentVerifier) else {
                        return nil
                    }
                    return String(deploymentVerifier[range])
                }
        )
        XCTAssertFalse(executableLiterals.contains("/bin/cmp"))
        XCTAssertFalse(executableLiterals.contains("/usr/bin/dd"))
        XCTAssertEqual(
            executableLiterals,
            expectedSystemCommands,
            "The deployment verifier's absolute command literals and pre-cutover command gate diverged."
        )
        for command in expectedSystemCommands {
            let resourceValues = try URL(fileURLWithPath: command).resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            XCTAssertEqual(resourceValues.isRegularFile, true, "Missing system command: \(command)")
            XCTAssertEqual(resourceValues.isSymbolicLink, false, "Redirected system command: \(command)")
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: command),
                "Non-executable system command: \(command)"
            )
        }
        let forbiddenZshSpecialDeclaration = #"(?m)^[\t ]*(?:local|typeset|integer|float)[^\n#]*(?:^|[\t ])(?:status|pipestatus|path|PATH|UID|EUID|GID|EGID|PPID|TTYIDLE|LINENO|ARGC|funcstack|functrace)(?:[\t =]|$)"#
        XCTAssertNil(
            deploymentVerifier.range(
                of: forbiddenZshSpecialDeclaration,
                options: .regularExpression
            ),
            "Deployment verifier declares a zsh special parameter as a local."
        )

        let disabledParser = try run(
            executable: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-deployment.sh"
            ),
            arguments: ["--self-test-disabled-parser"]
        )
        XCTAssertEqual(disabledParser.status, 0, disabledParser.diagnostic)
        XCTAssertEqual(
            disabledParser.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "SELF_TEST_OK disabled-parser",
            disabledParser.diagnostic
        )
        let deploymentVerifierPath = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-mac-host-deployment.sh"
        )
        let zshRuntime = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-c",
                deploymentVerifier,
                deploymentVerifierPath.path,
                "--self-test-zsh-runtime",
            ]
        )
        XCTAssertEqual(zshRuntime.status, 0, zshRuntime.diagnostic)
        XCTAssertEqual(zshRuntime.standardError, "", zshRuntime.diagnostic)
        XCTAssertEqual(
            zshRuntime.standardOutput,
            "SELF_TEST_OK zsh-runtime\n",
            zshRuntime.diagnostic
        )
        let launchParser = try run(
            executable: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-launch-state.sh"
            ),
            arguments: ["--self-test-launch-parser"]
        )
        XCTAssertEqual(launchParser.status, 0, launchParser.diagnostic)
        XCTAssertEqual(
            launchParser.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "SELF_TEST_OK launch-parser",
            launchParser.diagnostic
        )

        let launchAgent = repositoryRoot.appendingPathComponent(
            "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
        )
        let plistLint = try run(
            executable: URL(fileURLWithPath: "/usr/bin/plutil"),
            arguments: ["-lint", launchAgent.path]
        )
        XCTAssertEqual(plistLint.status, 0, plistLint.diagnostic)
    }

    private func sourceSection(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "Missing section start: \(start)")
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex),
            "Missing section end: \(end)"
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func compileController() throws -> URL {
        let temporaryRoot = makeTemporaryDirectory(prefix: "controller-build")
        let source = repositoryRoot.appendingPathComponent(
            "macOS/scripts/opensteamer-host-migration-controller.rs"
        )
        let binary = temporaryRoot.appendingPathComponent("controller")
        let compile = try run(
            executable: URL(
                fileURLWithPath: "/opt/homebrew/Cellar/rust/1.97.1/bin/rustc"
            ),
            arguments: [
                "--edition=2021",
                "-D",
                "warnings",
                "-C",
                "opt-level=1",
                source.path,
                "-o",
                binary.path,
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.diagnostic)

        let testBinary = temporaryRoot.appendingPathComponent("controller-tests")
        let testCompile = try run(
            executable: URL(
                fileURLWithPath: "/opt/homebrew/Cellar/rust/1.97.1/bin/rustc"
            ),
            arguments: [
                "--edition=2021",
                "-D",
                "warnings",
                "--test",
                source.path,
                "-o",
                testBinary.path,
            ]
        )
        XCTAssertEqual(testCompile.status, 0, testCompile.diagnostic)
        return binary
    }

    private func makeTemporaryDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-\(prefix)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        let directory = makeTemporaryDirectory(prefix: "process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: stdoutURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: stderrURL.path, contents: nil))
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }
}
