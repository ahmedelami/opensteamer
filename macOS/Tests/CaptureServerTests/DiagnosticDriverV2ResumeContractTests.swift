import CryptoKit
import Foundation
import XCTest

/// Behavioral and architectural contracts for the one exact retained V2 resume.
///
/// The production Rust self-test owns implementation-level hostile fixtures. These Swift tests
/// deliberately avoid copying function bodies or depending on statement order: they pin the
/// authorization inputs, constrain the executable surfaces, and run the pure Rust behavior.
final class DiagnosticDriverV2ResumeContractTests: XCTestCase {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let stagerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v2-resume-stager.rs"
    private let launcherPath = "macOS/scripts/resume-opensteamer-diagnostic-driver-v2.sh"
    private let originalControllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v2-update-controller.rs"
    private let originalLauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v2.sh"

    private let cleanEnvironment = [
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func sha256Hex(_ source: String) -> String {
        sha256Hex(Data(source.utf8))
    }

    private func firstCapture(_ pattern: String, in source: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: searchRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        return String(source[range])
    }

    private func rustStringConstant(_ name: String, in source: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstCapture(
            "(?s)\\bconst\\s+\(escaped)\\s*:\\s*&str\\s*=\\s*\"([^\"]*)\"\\s*;",
            in: source
        )
    }

    private func rustConstantExpression(_ name: String, in source: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstCapture(
            "(?m)^const\\s+\(escaped)\\s*:[^=]+?=\\s*([^;]+);",
            in: source
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shellSingleQuotedValue(_ name: String, in source: String) -> String? {
        let prefix = "\(name)='"
        guard let start = source.range(of: prefix) else { return nil }
        let tail = source[start.upperBound...]
        guard let end = tail.firstIndex(of: "'") else { return nil }
        return String(tail[..<end])
    }

    private func declaredFunctions(in source: String) -> Set<String> {
        declarationNames(pattern: #"(?m)^fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#, source: source)
    }

    private func declaredTypes(in source: String) -> Set<String> {
        declarationNames(
            pattern: #"(?m)^(?:struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)\b"#,
            source: source
        )
    }

    private func declaredConstants(in source: String) -> Set<String> {
        declarationNames(
            pattern: #"(?m)^const\s+([A-Za-z_][A-Za-z0-9_]*)\b"#,
            source: source
        )
    }

    private func declarationNames(pattern: String, source: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(expression.matches(in: source, range: searchRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }

    private func assertContains(
        _ tokens: [String],
        in source: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for token in tokens {
            XCTAssertTrue(
                source.contains(token),
                "\(context) is missing: \(token)",
                file: file,
                line: line
            )
        }
    }

    private func assertDeclares(
        _ required: [String],
        in declarations: Set<String>,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for name in required {
            XCTAssertTrue(
                declarations.contains(name),
                "\(context) omits declaration: \(name)",
                file: file,
                line: line
            )
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func isLowerHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(
                decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            stderr: String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    func testExactReviewedPinsAndNarrowPublicModes() throws {
        let stager = try source(stagerPath)
        let launcher = try source(launcherPath)
        let originalController = try source(originalControllerPath)
        let originalLauncher = try source(originalLauncherPath)

        let originalSourceDigest =
            "4df37ebcb2634ea1fed78165cc530ea8cb739fe1e9b59744010e2b64b922c98b"
        let originalBinaryDigest =
            "da55bc73f7143ffe6f09516c84c70532c18d37af53da0e12c00fb79924926201"
        XCTAssertEqual(sha256Hex(originalController), originalSourceDigest)
        XCTAssertEqual(
            shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: originalLauncher),
            originalSourceDigest
        )
        XCTAssertEqual(
            shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: originalLauncher),
            originalBinaryDigest
        )
        XCTAssertEqual(
            shellSingleQuotedValue("ORIGINAL_SOURCE_SHA256", in: launcher),
            originalSourceDigest
        )
        XCTAssertEqual(
            shellSingleQuotedValue("ORIGINAL_BINARY_SHA256", in: launcher),
            originalBinaryDigest
        )

        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_ORIGINAL_SOURCE_SHA256", in: stager),
            originalSourceDigest
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_ORIGINAL_CONTROLLER_SHA256", in: stager),
            originalBinaryDigest
        )
        XCTAssertEqual(
            rustConstantExpression("RETAINED_V2_ORIGINAL_CONTROLLER_SIZE", in: stager),
            "1_622_120"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_NONCE", in: stager),
            "ea5a600cf397995156907bc1609b68d6"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_RELEASE_COMMIT", in: stager),
            "eb1463d28fa84d9b768dfc4f17e2e4466c9f3f87"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_RELEASE_TREE", in: stager),
            "1258ff5f31c183bdc75bc4cc7734aae72d94bdf1"
        )
        XCTAssertEqual(
            rustStringConstant("DIAGNOSTIC_READER_SHA256", in: stager),
            "6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded"
        )

        let modes = [
            ("RESUME_PREFLIGHT_MODE", "PREFLIGHT_MODE", "--verify-diagnostic-driver-v2-resume-preflight"),
            ("RESUME_EXECUTE_MODE", "EXECUTE_MODE", "--execute-authorized-diagnostic-driver-v2-resume"),
            ("RESUME_SELF_TEST_MODE", "SELF_TEST_MODE", "--self-test-diagnostic-driver-v2-resume"),
        ]
        for (rustName, shellName, value) in modes {
            XCTAssertEqual(rustStringConstant(rustName, in: stager), value)
            XCTAssertEqual(shellSingleQuotedValue(shellName, in: launcher), value)
        }

        let functions = declaredFunctions(in: stager)
        assertDeclares(
            ["real_main", "verify_resume_preflight", "execute_authorized_resume", "self_test"],
            in: functions,
            context: "resume entrypoints"
        )
        let inheritedMutators: Set<String> = [
            "execute_authorized_update", "rollback_authorized_update",
            "root_authorized_update", "root_rollback_authorized_update",
            "perform_root_transaction", "rollback_root_transaction",
            "stage_normalized_candidate_driver", "publish_candidate_driver",
            "reload_coreaudio_exact", "stop_exact_v8_host", "restart_exact_v8_host",
        ]
        XCTAssertTrue(
            functions.intersection(inheritedMutators).isEmpty,
            "resume stager declares a generic/inherited updater mutation"
        )
        let v3Namespace = ["diagnostic-driver-", "v3"].joined()
        XCTAssertFalse(stager.localizedCaseInsensitiveContains(v3Namespace))
        XCTAssertFalse(launcher.localizedCaseInsensitiveContains(v3Namespace))
        XCTAssertFalse(stager.contains("#![allow(dead_code)]"))
    }

    func testLauncherDeterministicallyBuildsAndSealsAUID501OnlyStager() throws {
        let launcher = try source(launcherPath)

        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh\n"))
        assertContains(
            [
                "set -eu", "umask 077", "export LC_ALL=C",
                "[ \"$(/usr/bin/id -u)\" = 501 ]",
                "EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'",
                "EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'",
                "EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'",
                "BUILD_ANCESTOR='/Users/ahmed/Library/Caches'",
                "BUILD_PARENT='/Users/ahmed/Library/Caches/opensteamer-diagnostic-driver-v2-resume-builds'",
                "'501:20:700:0:Directory'",
                "BUILD_ROOT_A=$(/usr/bin/mktemp -d \"$BUILD_PARENT/.resume-a.XXXXXX\")",
                "BUILD_ROOT_B=$(/usr/bin/mktemp -d \"$BUILD_PARENT/.resume-b.XXXXXX\")",
                "--edition=2021 -D warnings -C opt-level=2",
                "--remap-path-prefix",
                "\"$ORIGINAL_SOURCE\" -o \"$build_root/controller\"",
                "/bin/mv \"$build_root/controller\" \"$build_root/original-controller\"",
                "/usr/bin/cmp -s \"$BUILD_ROOT_A/resume-stager\" \"$BUILD_ROOT_B/resume-stager\"",
                "/usr/bin/cmp -s \"$BUILD_ROOT_A/original-controller\" \"$BUILD_ROOT_B/original-controller\"",
                "SEALED_STAGER_PREFIX='resume-stager-'",
                "-o root -g wheel -m 0400",
                "/bin/chmod 0555 \"$SEALED_STAGER_PATH\"",
                "OPENSTEAMER_RESUME_STAGER_SEALED_PATH=\"$SEALED_STAGER_PATH\"",
                "/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            in: launcher,
            context: "deterministic sealed launcher"
        )
        XCTAssertEqual(occurrences(of: "--edition=2021 -D warnings -C opt-level=2", in: launcher), 2)
        XCTAssertEqual(occurrences(of: "/usr/bin/cmp -s", in: launcher), 2)
        XCTAssertEqual(occurrences(of: "/usr/bin/sudo", in: launcher), 1)
        XCTAssertFalse(launcher.contains("sudo_constant \"$SEALED_STAGER_PATH\""))
        XCTAssertFalse(launcher.contains("eval "))
        XCTAssertFalse(launcher.contains("sh -c"))
        XCTAssertFalse(launcher.contains("bash -c"))

        assertContains(
            [
                "\"$SELF_TEST_MODE\")\n        /usr/bin/env -i",
                "\"$PREFLIGHT_MODE\")\n        publish_sealed_stager",
                "\"$EXECUTE_MODE\")\n        publish_sealed_stager",
            ],
            in: launcher,
            context: "mode-specific sealed publication"
        )
    }

    func testRetainedV1V2GraphsStayLockedAndMinimalPostAnchorsRemainExact() throws {
        let stager = try source(stagerPath)
        let functions = declaredFunctions(in: stager)
        let types = declaredTypes(in: stager)
        let constants = declaredConstants(in: stager)

        XCTAssertEqual(
            rustStringConstant("RETAINED_V1_USER_ACTIVE_POINTER_SHA256", in: stager),
            "0dbb83c4ce3fbba0cb851365b1ea9fa98f2ab356f2b182ab02552cb538d571ea"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V1_JOURNAL_SHA256", in: stager),
            "7e488883f3069b7dd86ad82e46c70a7b40ca7d1a5458d10f6d3b17291e048504"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V1_REQUEST_SHA256", in: stager),
            "b5a56144453a12fa5b6b65c14baab56a8947319804f8bc1a7934fb99869a2baf"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_USER_ACTIVE_POINTER_SHA256", in: stager),
            "9a4aa07cab19e0abe07d10e5486f88c86bacf9d377ad5c4a771270bc0e3999a6"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_JOURNAL_SHA256", in: stager),
            "0e535de861063877ac88ebbaa48092a8d519046115d574a5e6d429110fae30cc"
        )
        XCTAssertEqual(
            rustStringConstant("RETAINED_V2_REQUEST_SHA256", in: stager),
            "6193d1d942fcc7e4b3da2ca0c7dfbc3e75b4c6b4ebb8cda1ca639a7ba70294ac"
        )

        assertDeclares(
            [
                "RetainedV1DescriptorGraph", "RetainedV2DescriptorGraph",
                "RetainedAttemptGuards", "RetainedGraphProof",
            ],
            in: types,
            context: "retained graph types"
        )
        assertDeclares(
            [
                "acquire_retained_v1_lock", "acquire_retained_v2_lock",
                "acquire_retained_attempt_guards", "open_retained_v1_descriptor_graph",
                "open_retained_v2_descriptor_graph", "verify_retained_v1_descriptor_graph",
                "verify_retained_v2_descriptor_graph", "prove_retained_graphs",
                "verify_retained_v1_root_attestation", "verify_privileged_partial_root_stage",
                "verify_resume_stage_complete", "verify_post_completion_anchors",
            ],
            in: functions,
            context: "held retained graph proof"
        )
        assertContains(
            [
                "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
                "openat_component_walk_with_final_flags",
                "require_exact_child_names_fd",
                "held/named lock identity differs",
                "retained V1/V2 evidence changed across root completion",
                "sealed controller/recovery root stage changed across completion",
                "held original V2 controller after completion",
            ],
            in: stager,
            context: "descriptor-held retained graph boundary"
        )
        XCTAssertFalse(stager.contains("LOCK_UN"))

        for name in [
            "RETAINED_V1_ROOT_UPDATE_ROOT", "RETAINED_V1_ROOT_ACTIVE_POINTER",
            "RETAINED_V1_ROOT_ACTIVE_POINTER_PENDING", "RETAINED_V1_ROOT_UPDATE_LOCK",
            "RETAINED_V1_ROOT_CONTROLLER_PARENT", "RETAINED_V1_ROOT_PROBE_PARENT",
        ] {
            XCTAssertTrue(constants.contains(name), "missing exact V1 root-absence anchor: \(name)")
        }

        // The authorized post-check is intentionally the minimal retained graph/stage/intent
        // proof. It must not grow an unused duplicate terminal journal/state parser surface.
        for abandonedConstant in [
            "ROOT_TRANSACTION", "ROOT_TRANSACTION_JOURNAL", "ROOT_TRANSACTION_STATE",
            "ROOT_TRANSACTION_RESULT", "ROOT_TRANSACTION_RECOVERY",
            "ROOT_TRANSACTION_ROLLBACK_RESERVE",
        ] {
            XCTAssertFalse(constants.contains(abandonedConstant), "abandoned terminal constant returned")
        }
        for abandonedFunction in [
            "read_terminal_root_record", "verify_terminal_root_directory",
            "verify_terminal_empty_root_file", "verify_terminal_root_attestation",
        ] {
            XCTAssertFalse(functions.contains(abandonedFunction), "abandoned terminal parser returned")
        }
    }

    func testPrivilegedSurfaceIsOneTypedClosedSudoRunnerWithoutAShell() throws {
        let stager = try source(stagerPath)
        let functions = declaredFunctions(in: stager)
        let types = declaredTypes(in: stager)

        assertDeclares(["SudoAction", "SudoInvocation"], in: types, context: "typed sudo surface")
        assertDeclares(
            ["sudo_invocation", "run_sudo_constant_argv"],
            in: functions,
            context: "single sudo runner"
        )
        XCTAssertEqual(occurrences(of: "Command::new(\"/usr/bin/sudo\")", in: stager), 1)
        for forbiddenRunner in ["run_sudo", "sudo_fixed", "sudo_command", "sudo_dynamic"] {
            XCTAssertFalse(functions.contains(forbiddenRunner), "generic sudo runner declared")
        }
        for shellConstructor in [
            "Command::new(\"/bin/sh\")", "Command::new(\"/bin/zsh\")",
            "Command::new(\"/bin/bash\")", "Command::new(\"sh\")",
        ] {
            XCTAssertFalse(stager.contains(shellConstructor), "sudo surface can reach a shell")
        }
        assertContains(
            [
                "enum SudoAction {", "Stat(RootPath)", "List(RootPath)",
                "Acl(RootPath)", "Xattr(RootPath)", "Cat(RootPath)",
                "CreateSupportDirectory", "CreatePending(RootArtifact)",
                "StreamPending(RootArtifact)", "SealPending(RootArtifact)",
                "PublishPending(RootArtifact)", "DispatchOriginal", "RecoverSealed",
                "typed sudo action/input contract is inconsistent",
                "typed sudo action escaped the closed argv allowlist",
                ".arg(\"-n\")", ".arg(\"--\")", ".env_clear()",
                "read_pipe_bounded(stdout, MAX_OUTPUT_BYTES)",
                "read_pipe_bounded(stderr, MAX_OUTPUT_BYTES)",
            ],
            in: stager,
            context: "closed bounded sudo actions"
        )
    }

    func testExactStagingDurableIntentAndAmbiguityConvergeThroughRecovery() throws {
        let stager = try source(stagerPath)
        let functions = declaredFunctions(in: stager)
        let types = declaredTypes(in: stager)

        assertDeclares(
            [
                "RootArtifact", "RootPath", "ResumeStagePrefix", "RootStageProof",
                "ResumeDisposition", "RootStateObservation",
            ],
            in: types,
            context: "staging and recovery types"
        )
        assertDeclares(
            [
                "classify_stage_child_observation", "classify_resume_stage_prefix",
                "verify_privileged_partial_root_stage", "stage_original_v2_root_controller",
                "verify_transaction_support_complete", "verify_resume_stage_complete",
                "publish_resume_dispatch_intent", "verify_resume_dispatch_intent",
                "classify_dispatch_observation", "durable_intent_allows_forward_dispatch",
                "dispatch_original_v2_controller_once", "recover_from_resume_dispatch_intent",
                "dispatch_or_recover_after_durable_intent", "original_controller_path_is_allowed",
            ],
            in: functions,
            context: "exact staging/recovery behavior"
        )
        XCTAssertEqual(
            rustStringConstant("RESUME_DISPATCH_INTENT_HEADER", in: stager),
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_V2_RESUME_DISPATCH_INTENT_V1"
        )
        XCTAssertEqual(
            rustConstantExpression("RESUME_DISPATCH_INTENT_SIZE", in: stager),
            "261"
        )
        XCTAssertEqual(
            rustStringConstant("RESUME_DISPATCH_INTENT_SHA256", in: stager),
            "0bea593bb494b132204a898129ba62e3cc0ba12998fbcb1ed9e2b29671c8d9d2"
        )
        XCTAssertEqual(
            rustStringConstant("ORIGINAL_V2_ROOT_MODE", in: stager),
            "--root-authorized-diagnostic-driver-v2-update"
        )
        XCTAssertEqual(
            rustStringConstant("ORIGINAL_V2_ROOT_SEALED_RECOVERY_MODE", in: stager),
            "--root-sealed-rollback-diagnostic-driver-v2-update"
        )
        XCTAssertEqual(
            rustStringConstant("ORIGINAL_BUILD_PARENT", in: stager),
            "/Users/ahmed/Library/Caches/opensteamer-diagnostic-driver-v2-resume-builds"
        )
        assertContains(
            [
                "TransactionController", "TransactionPin", "TransactionIdentity",
                "TransactionBootstrap", "RecoveryController", "RecoveryPin",
                "DispatchIntent", "RootStateObservation::Ambiguous",
                "durable intent/root state requires sealed recovery",
                "canonical and pending resume dispatch intents coexist",
                "durably sync complete transaction support",
                "durably sync fixed recovery pair",
                "parent.parent() == Some(Path::new(ORIGINAL_BUILD_PARENT))",
                "name.starts_with(\".resume-b.\") && name.len() == 16",
                "path.file_name() == Some(OsStr::new(\"original-controller\"))",
            ],
            in: stager,
            context: "exact monotonic staging and recovery convergence"
        )
    }

    func testRootCompletionCorrelatesMarkerPIDRunsAndPostLivePolicy() throws {
        let stager = try source(stagerPath)
        let functions = declaredFunctions(in: stager)
        let types = declaredTypes(in: stager)

        assertDeclares(
            [
                "RootOutcome", "RootCompletionEntrypoint", "RootCompletion",
                "HostGeneration", "CoreAudioGeneration", "RouteSnapshot",
            ],
            in: types,
            context: "root/live completion types"
        )
        assertDeclares(
            [
                "parse_root_success_marker", "root_completion_matches_live_host",
                "verify_post_dispatch_live", "host_transition_allowed",
                "coreaudio_transition_allowed", "retained_terminal_coreaudio_is_exact",
                "prove_lock_sole_host_opener", "stable_route_snapshot",
                "require_exact_fresh_routes", "verify_pairing_metadata_only",
                "require_legacy_disabled_and_absent",
            ],
            in: functions,
            context: "root marker and live post-policy"
        )
        assertContains(
            [
                "Committed", "RolledBack", "PrestopAborted",
                "Forward", "PointerBackedRecovery", "PointerlessPrestop",
                "host_pid: u32", "host_runs: Option<u64>",
                "DIAGNOSTIC_DRIVER_V2_UPDATE_COMMITTED",
                "DIAGNOSTIC_DRIVER_V2_ROOT_RECOVERY_COMMITTED",
                "DIAGNOSTIC_DRIVER_V2_ROOT_ROLLBACK_COMPLETE",
                "DIAGNOSTIC_DRIVER_V2_ROOT_PRESTOP_ABORTED",
                "terminal live host PID/runs differ from the exact root marker",
                "routes/pairing/protected legacy invariant changed",
                "post-dispatch installed-driver proof is inconsistent",
            ],
            in: stager,
            context: "terminal root/live correlation"
        )

        XCTAssertEqual(rustConstantExpression("FRESH_HOST_PID", in: stager), "98_080")
        XCTAssertEqual(rustConstantExpression("FRESH_HOST_RUNS", in: stager), "1")
        XCTAssertEqual(rustConstantExpression("FRESH_COREAUDIO_PID", in: stager), "2_621")
        XCTAssertEqual(rustConstantExpression("FRESH_COREAUDIO_RUNS", in: stager), "5")
        XCTAssertEqual(rustStringConstant("FRESH_INPUT_UID", in: stager), "BlackHole2ch_UID")
        XCTAssertEqual(rustStringConstant("FRESH_OUTPUT_UID", in: stager), "BuiltInSpeakerDevice")

        XCTAssertEqual(
            rustStringConstant("PAIRING_SERVICE", in: stager),
            "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"
        )
        assertContains(
            [
                "worldwide-host-identity-v1", "worldwide-paired-viewer-v1",
                "fbd7bd69d3ee3e7a91416427a44365cde6199ccee62eaf4f619f9d12ee7aa9d6",
                "751ae04bb168ae92472b0b3d31066d371b95c34fe62a7df374e3449f5a7be7a5",
                "find-generic-password",
                "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer",
                "com.elamin.audiostreamer.worldwide",
                "1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc",
                "419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730",
            ],
            in: stager,
            context: "pairing and protected legacy read-only pins"
        )

        let protectedLegacyPairing = [
            "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing", ".v1",
        ].joined()
        let protectedHiddenRecoveryApp = [
            "/Applications/.audio", "streamer-failed-20260720-102747-44276/",
            "AudioStreamer Host.app",
        ].joined()
        let routeMutationAPI = ["AudioObjectSet", "PropertyData"].joined()
        let pairingResetMode = ["--reset-worldwide-", "pairing"].joined()
        let installerPath = ["/usr/sbin/", "installer"].joined()
        for forbidden in [
            protectedLegacyPairing, protectedHiddenRecoveryApp, routeMutationAPI,
            pairingResetMode, installerPath, "delete-generic-password", "add-generic-password",
        ] {
            XCTAssertFalse(stager.contains(forbidden), "protected/mutation boundary escaped: \(forbidden)")
        }
    }

    func testGitProvenanceIsPinnedCleanAndBounded() throws {
        let stager = try source(stagerPath)
        let functions = declaredFunctions(in: stager)

        XCTAssertEqual(
            rustStringConstant("EXPECTED_REPO", in: stager),
            "/Users/ahmed/Documents/Codex/opensteamer"
        )
        XCTAssertEqual(
            rustStringConstant("EXPECTED_REMOTE", in: stager),
            "https://github.com/ahmedelami/opensteamer.git"
        )
        XCTAssertEqual(rustConstantExpression("MAX_OUTPUT_BYTES", in: stager), "8 * 1_048_576")
        XCTAssertEqual(
            rustConstantExpression("COMMAND_TIMEOUT", in: stager),
            "Duration::from_secs(60)"
        )
        assertDeclares(
            ["canonical_repo", "bounded_git_output", "git", "verify_git_provenance"],
            in: functions,
            context: "bounded git provenance"
        )
        assertContains(
            [
                "Command::new(\"/usr/bin/git\")", "core.fsmonitor=false",
                "core.hooksPath=/dev/null", "GIT_OPTIONAL_LOCKS", ".env_clear()",
                "bounded git command timed out", "bounded git output exceeded limit",
                "rev-parse\", \"--is-inside-work-tree", "rev-parse\", \"--show-toplevel",
                "branch\", \"--show-current", "rev-parse\", \"HEAD^{tree}",
                "rev-parse\", \"main", "rev-parse\", \"origin/main",
                "remote\", \"get-url\", \"origin",
                "status\", \"--porcelain=v1\", \"--untracked-files=all",
                "repository is not exact clean pushed main",
            ],
            in: stager,
            context: "clean pushed-main git proof"
        )
        XCTAssertFalse(stager.contains(".output()?"))
        XCTAssertFalse(stager.contains(".output()."))
    }

    func testPureBehavioralSelfTestPassesAllHostileFixtures() throws {
        let stager = try source(stagerPath)
        assertContains(
            [
                "root-wrong-owner-rejected", "root-wrong-mode-rejected",
                "root-wrong-inode-rejected", "root-acl-xattr-rejected",
                "stage-out-of-order-artifact-rejected",
                "stage-canonical-pending-collision-rejected",
                "stage-early-abort-result-rejected", "intent-collision-rejected",
                "durable-intent-forward-convergence-policy",
                "fresh-recovery-driver-state-policy",
                "root-marker-host-pid-runs-accepted",
                "root-marker-host-pid-runs-mismatch-rejected",
                "pointerless-marker-requires-retained-host-generation",
                "host-successor-rejects-lock-inode-change",
                "terminal-rerun-host-idempotence-policy",
                "coreaudio-outcome-transition-policy",
                "terminal-coreaudio-absolute-counts-accepted",
                "terminal-coreaudio-unrelated-generation-rejected",
                "recovery-post-route-policy", "pairing-metadata-digest-pins",
                "single-sudo-runner-site", "no-route-mutation-api",
                "no-protected-legacy-pairing-service", "no-protected-hidden-recovery-app",
            ],
            in: stager,
            context: "executed pure hostile fixture matrix"
        )

        let launcher = try source(launcherPath)
        guard let rustcPath = shellSingleQuotedValue("RUSTC", in: launcher),
              let rustcSysroot = shellSingleQuotedValue("RUSTC_SYSROOT", in: launcher)
        else {
            XCTFail("launcher omits the reviewed Rust toolchain")
            return
        }
        XCTAssertEqual(rustcPath, "/opt/homebrew/Cellar/rust/1.97.1/bin/rustc")
        XCTAssertEqual(rustcSysroot, "/opt/homebrew/Cellar/rust/1.97.1")

        let buildParent = URL(
            fileURLWithPath: "/Volumes/t7/opensteamer-diagnostic-driver-v2-resume-contract-tests",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: buildParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let buildRoot = buildParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: buildRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: buildRoot) }

        let binary = buildRoot.appendingPathComponent("resume-stager")
        let compile = try runProcess(
            executable: URL(fileURLWithPath: rustcPath),
            arguments: [
                "--edition=2021", "-D", "warnings", "-C", "opt-level=2",
                "--sysroot", rustcSysroot,
                "--remap-path-prefix",
                "\(repositoryRoot.path)=/reviewed/opensteamer-diagnostic-driver-v2-resume",
                repositoryRoot.appendingPathComponent(stagerPath).path,
                "-o", binary.path,
            ],
            environment: cleanEnvironment
        )
        guard compile.status == 0 else {
            XCTFail("warning-clean pure stager compile failed: \(compile.stderr)")
            return
        }
        XCTAssertEqual(compile.stdout, "")
        XCTAssertEqual(compile.stderr, "")

        let result = try runProcess(
            executable: binary,
            arguments: ["--self-test-diagnostic-driver-v2-resume"],
            environment: cleanEnvironment
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "DIAGNOSTIC_DRIVER_V2_RESUME_SELF_TEST_OK tests=97\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testLauncherSelfTestIsDynamicallyFailClosedOrRunsOnlyPureMode() throws {
        let launcher = try source(launcherPath)
        let launcherURL = repositoryRoot.appendingPathComponent(launcherPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcherURL.path))

        let status = shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher)
        let sourcePin = shellSingleQuotedValue("EXPECTED_STAGER_SOURCE_SHA256", in: launcher)
        let binaryPin = shellSingleQuotedValue("EXPECTED_STAGER_BINARY_SHA256", in: launcher)
        let result = try runProcess(
            executable: launcherURL,
            arguments: ["--self-test-diagnostic-driver-v2-resume"],
            environment: cleanEnvironment
        )

        switch status {
        case "UNPINNED_REVIEW_REQUIRED":
            XCTAssertEqual(sourcePin, "")
            XCTAssertEqual(binaryPin, "")
            XCTAssertEqual(result.status, 78)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(
                result.stderr,
                "diagnostic-driver resume is intentionally unrunnable until final review\n"
            )
        case "PINNED_FINAL_REVIEW":
            XCTAssertEqual(sourcePin, sha256Hex(try source(stagerPath)))
            XCTAssertTrue(isLowerHex(binaryPin ?? "", length: 64))
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(
                result.stdout,
                "DIAGNOSTIC_DRIVER_V2_RESUME_SELF_TEST_OK tests=97\n"
            )
            XCTAssertEqual(result.stderr, "")
        default:
            XCTFail("resume launcher is neither explicitly unpinned nor finally pinned")
        }
    }
}
