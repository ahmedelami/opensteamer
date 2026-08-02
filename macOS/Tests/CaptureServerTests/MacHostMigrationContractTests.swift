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
                "EXPECTED_CONTROLLER_BINARY_SHA256='bedf56fb4530098c2e7637fd08aa5aa17eafc2848c93a80b80c40e42ae722097'"
            )
        )
        XCTAssertTrue(source.contains("fresh controller binary differs from the reviewed reproducible postimage"))
        XCTAssertTrue(source.contains("--self-test-reviewed-controller-build"))
        XCTAssertTrue(source.contains("SOURCE_COPY=\"$BUILD_DIR/opensteamer-host-migration-controller.rs\""))
        XCTAssertTrue(source.contains("copy_companion_script"))
        XCTAssertTrue(source.contains("verify_private_companion_script"))
        XCTAssertTrue(source.contains("EXPECTED_BUILD_SCRIPT_SHA256"))
        XCTAssertTrue(source.contains("EXPECTED_DEPLOYMENT_VERIFIER_SHA256"))
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
            "OPENSTEAMER_MIGRATION_JOURNAL_V11",
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
            "include_bytes!(\"verify-mac-host-deployment.sh\")",
            "verify_embedded_verifier_hashes",
            "require_new_runtime_absent",
            "require_precutover_disk_headroom",
        ] {
            XCTAssertTrue(controller.contains(required), "Controller lacks \(required)")
        }
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
        XCTAssertTrue(deploymentVerifier.contains("EXPECTED_GENERATION_NONCE"))
        XCTAssertTrue(deploymentVerifier.contains("validate_generation_record"))

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
