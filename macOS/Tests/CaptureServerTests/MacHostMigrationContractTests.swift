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
                result.standardError.contains("immediate child"),
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
                "EXPECTED_CONTROLLER_BINARY_SHA256='ce4622b1792957b23d69681d2af5c190ca73e1343f62d476dd33872c314efc2e'"
            )
        )
        XCTAssertTrue(source.contains("fresh controller binary differs from the reviewed reproducible postimage"))
        XCTAssertTrue(source.contains("--self-test-reviewed-controller-build"))
        XCTAssertTrue(source.contains("--verify-reviewed-prior-retry-state"))
        XCTAssertTrue(source.contains(".controller-build-v15.XXXXXX"))
        XCTAssertTrue(source.contains("SOURCE_COPY=\"$BUILD_DIR/opensteamer-host-migration-controller.rs\""))
        XCTAssertTrue(source.contains("copy_companion_script"))
        XCTAssertTrue(source.contains("verify_private_companion_script"))
        XCTAssertTrue(source.contains("EXPECTED_BUILD_SCRIPT_SHA256"))
        XCTAssertTrue(source.contains("EXPECTED_DEPLOYMENT_VERIFIER_SHA256"))
        XCTAssertTrue(
            source.contains(
                "EXPECTED_DEPLOYMENT_VERIFIER_SHA256='1a972c52ad5be2dc10547d1f8666946f6031386e4cfa7daf4b35e2720316576a'"
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
            "const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(60)",
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
            "const ACTIVE_TRANSACTION_NAME: &str = \"active-migration-v15\";",
            "const ACTIVE_TRANSACTION_PENDING_NAME: &str = \".active-migration-v15.pending\";",
            "const ACTIVE_TRANSACTION_FINALIZING_NAME: &str = \".active-migration-v15.finalizing\";",
            "const ACTIVE_TRANSACTION_LINEARIZED_NAME: &str = \".active-migration-v15.linearized\";",
            "const JOURNAL_VERSION: &str = \"OPENSTEAMER_MIGRATION_JOURNAL_V15\";",
            "const FAKE_JOURNAL_VERSION: &str = \"OPENSTEAMER_FAKE_MIGRATION_JOURNAL_V15\";",
            "const V15_EVIDENCE_PATH: &str",
            "parse_v15_active_record",
            "v15 active pointer selects unreviewed evidence",
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
            "migration-v14-after-v13-1785637636-18044",
            "migration-v15-after-v14-1785637636-18044",
            "--verify-reviewed-prior-retry-state",
            "prior_fields.extend(prior_v13.journal_fields());",
            "prior_fields.extend(prior_v14.journal_fields());",
            "PRIOR_RETRY_STATE_OK v9=v10=v11=v12=v13=v14 legacy=sole-ready v15=absent",
            ".opensteamer-disabled-v15-{tag}",
            ".org.example.opensteamer.worldwide.plist.disabled-v15-{tag}",
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
            "const V15_EVIDENCE_PATH: &str = \"/Users/ahmed/Library/Application Support/opensteamer/migrations/migration-v15-after-v14-1785637636-18044\";",
            "b\"zsh:299: no such file or directory: /bin/cmp\\nopensteamer host deployment verification failed: reviewed LaunchAgent bytes differ from checked-in contract\\n\"",
        ]
        for anchor in exactPriorV14Anchors {
            XCTAssertTrue(controller.contains(anchor), "Controller lacks exact v14 anchor \(anchor)")
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
                    "            )"
            ),
            "All six exact historical guards are not passed into the v15 transaction."
        )
        XCTAssertTrue(
            controller.contains(
                "    prior_v13: PriorV13RetryGuard,\n" +
                    "    prior_v14: PriorV14RetryGuard,\n" +
                    ") -> Result<()> {"
            ),
            "The exact prior-v14 guard is not owned by v15 startup."
        )
        XCTAssertTrue(
            controller.contains(
                "            &prior_v13,\n" +
                    "            &prior_v14,\n" +
                    "        )"
            ),
            "The exact prior-v14 guard is not threaded into the v15 transaction."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "prior_v14: &'a PriorV14RetryGuard,"
            ).count - 1,
            2,
            "The exact prior-v14 guard is not retained by the real backend and constructor."
        )
        XCTAssertTrue(
            controller.contains(
                "    prior_v13: &PriorV13RetryGuard,\n" +
                    "    prior_v14: &PriorV14RetryGuard,\n" +
                    ") -> Result<()> {"
            ),
            "The exact prior-v14 guard is not part of the transaction contract."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "validate_prior_v14_rolledback_retry(private_root)?;"
            ).count - 1,
            2,
            "The exact prior-v14 guard is not acquired by both preflight and execution."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v11.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v11 tombstone is not revalidated throughout v15 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v12.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v12 tombstone is not revalidated throughout v15 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v13.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v13 tombstone is not revalidated throughout v15 startup."
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: "prior_v14.revalidate(private_root)?;").count - 1,
            3,
            "The prior-v14 tombstone is not revalidated throughout v15 startup."
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
            "The 2 GiB fresh-attempt gate must run before v15 creates its evidence tree."
        )
        XCTAssertTrue(
            controller.contains(
                "    let output = run_pinned_script_until(\n" +
                    "        verifiers,\n" +
                    "        &verifiers.deployment,\n" +
                    "        &arguments,\n" +
                    "        Some(&layout.source_export),\n" +
                    "        &environment,\n" +
                    "        deadline_after(DEPLOYMENT_VERIFIER_TIMEOUT)?,\n" +
                    "    )?;"
            ),
            "The production deployment oracle is not wired to its dedicated bounded deadline."
        )
        XCTAssertFalse(controller.contains("Path::new(\"/bin/chflags\")"))
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
        XCTAssertTrue(deploymentVerifier.contains("STABILITY_SAMPLES=44"))
        XCTAssertTrue(deploymentVerifier.contains("STABILITY_SAMPLE_DELAY=0.25"))
        XCTAssertTrue(
            deploymentVerifier.contains(
                "shared-lock proof failed during continuous sample"
            )
        )
        XCTAssertTrue(deploymentVerifier.contains("--self-test-disabled-parser"))
        XCTAssertTrue(deploymentVerifier.contains("--self-test-zsh-runtime"))
        XCTAssertTrue(deploymentVerifier.contains("EXPECTED_GENERATION_NONCE"))
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
