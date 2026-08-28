import CryptoKit
import Foundation
import XCTest

final class DiagnosticDriverV17UpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let controllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v17-update-controller.rs"
    private let launcherPath = "macOS/scripts/update-opensteamer-diagnostic-driver-v17.sh"
    private let retainedV15SourcePath =
        "macOS/scripts/opensteamer-diagnostic-driver-v15-update-controller.rs"
    private let retainedV15LauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v15.sh"
    private let retainedV15ContractPath =
        "macOS/Tests/CaptureServerTests/DiagnosticDriverV15UpdateContractTests.swift"
    private let probeSourcePath =
        "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"

    private func url(_ relativePath: String) -> URL {
        repositoryRoot.appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    private func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func functionBody(
        _ source: String,
        beginningWith beginning: String,
        endingBefore ending: String
    ) throws -> String {
        let nsSource = source as NSString
        let start = nsSource.range(of: beginning)
        guard start.location != NSNotFound else {
            XCTFail("missing function start: \(beginning)")
            return ""
        }
        let tail = NSRange(location: start.location, length: nsSource.length - start.location)
        let finish = nsSource.range(of: ending, options: [], range: tail)
        guard finish.location != NSNotFound else {
            XCTFail("missing function end: \(ending)")
            return ""
        }
        return nsSource.substring(
            with: NSRange(location: start.location, length: finish.location - start.location)
        )
    }

    private func assertOrdered(
        _ tokens: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var remainder = source[source.startIndex...]
        for token in tokens {
            guard let range = remainder.range(of: token) else {
                XCTFail("missing ordered token: \(token)", file: file, line: line)
                return
            }
            remainder = remainder[range.upperBound...]
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func shellSingleQuotedValue(_ name: String, in source: String) -> String? {
        let prefix = "\(name)='"
        guard let start = source.range(of: prefix) else { return nil }
        let tail = source[start.upperBound...]
        guard let end = tail.firstIndex(of: "'") else { return nil }
        return String(tail[..<end])
    }

    private func run(_ executable: URL, arguments: [String]) throws -> (
        status: Int32,
        stdout: String,
        stderr: String
    ) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    func testV17FreshNamespacesProvenanceAndCandidateAreExact() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let freshConstants = try functionBody(
            controller,
            beginningWith: "const PREFLIGHT_MODE:",
            endingBefore: "const RETAINED_V1_DEVICE:"
        )

        for token in [
            #"const EXPECTED_RELEASE_BRANCH: &str = "fix/diagnostic-driver-v17-airplay-stabilization";"#,
            #"const EXPECTED_CANDIDATE_SOURCE_BRANCH: &str ="#,
            #""fix/diagnostic-driver-v15-running-notification";"#,
            #"const EXPECTED_UPDATER_BASE_COMMIT: &str = "a71f969894caa23dd0f6c960786ba3fcae2c74c6";"#,
            #"const EXPECTED_UPDATER_BASE_TREE: &str = "ab3cf18569f2e4d7a70e5a641a60e677935d48f3";"#,
            #"const EXPECTED_SOURCE_COMMIT: &str = "4dab9b98c375e0b3fc7691547040799c4476d8a5";"#,
            #"const EXPECTED_SOURCE_TREE: &str = "901cb00c5cf897376ea0957b45027b6ef297063c";"#,
            #"const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v17-update-preflight";"#,
            #"const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v17-update";"#,
            #"const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v17-update";"#,
            #"const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v17-update";"#,
            #"const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v17-update";"#,
            #"const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v17-update";"#,
            #"const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v17-update";"#,
            #"const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V17";"#,
            #"const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V17";"#,
            "/diagnostic-driver-updates-v17",
            "/active-diagnostic-driver-update-v17",
            "/diagnostic-driver-update-v17.lock",
            "/diagnostic-driver-controllers-v17",
            "/diagnostic-driver-bootstrap-v17.txt",
            "/diagnostic-driver-probes-v17",
        ] {
            XCTAssertTrue(freshConstants.contains(token), "missing fresh V17 token: \(token)")
        }
        for stale in [
            "/diagnostic-driver-updates-v15",
            "/active-diagnostic-driver-update-v15",
            "/diagnostic-driver-update-v15.lock",
            "/diagnostic-driver-controllers-v15",
            "/diagnostic-driver-bootstrap-v15.txt",
            "/diagnostic-driver-probes-v15",
        ] {
            XCTAssertFalse(freshConstants.contains(stale), "V17 reuses a V15 namespace: \(stale)")
        }

        for token in [
            "reviewed-driver-candidates-v17/production-driver-v8",
            "OpensteamerVirtualMicrophone-v8.pkg",
            "schema=opensteamer.production-driver-candidate.v8",
            "47bdd09631023407b97a5f162710b72972fe3162fdc3dcd42b7eaaec13cf7129",
            "50159158687cffabebc3b182b514349139eddac1d6b57fcd92c9395d3fb73558",
            "1520821a1299c7bee6bee2161edbbf590a4343167367885f2edf9bf2865a2685",
            "25cd7a39366f0bfcd491cc1509f3f0c79ebe716899342d8feaa8ff9feb57ac4a",
            "4021696842E07336784376884D24969D9A94654A54F5B0C5C8FBC3C8C5D599AE",
            "4b03e56d-93e9-4989-a65b-c5ee282c13dc",
        ] {
            XCTAssertTrue(controller.contains(token), "missing V17 candidate pin: \(token)")
        }
        XCTAssertFalse(controller.contains("reviewed-driver-candidates-v15/production-driver-v8"))
        let verifyCandidate = try functionBody(
            controller,
            beginningWith: "fn verify_candidate()",
            endingBefore: "fn verify_installed_v7_driver("
        )
        XCTAssertTrue(verifyCandidate.contains(
            "format!(\"source_branch={EXPECTED_CANDIDATE_SOURCE_BRANCH}\")"
        ))
        let probeConstants = try functionBody(
            controller,
            beginningWith: "const BOTH_ORDER_PROBE_PARENT: &str =",
            endingBefore: "const BOTH_ORDER_PROBE_SHA256: &str ="
        )
        assertOrdered(
            [
                "const BOTH_ORDER_PROBE_PARENT: &str =",
                "/reviewed-diagnostic-probes-v17\";",
                "const BOTH_ORDER_PROBE: &str =",
                "/reviewed-diagnostic-probes-v17/physical-virtual-microphone-probe\";",
            ],
            in: probeConstants
        )
        XCTAssertFalse(controller.contains("reviewed-diagnostic-probes-v15/physical-virtual-microphone-probe"))
        XCTAssertTrue(controller.contains(
            "retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11_v12_v13_v14_v15_v16=immutable"
        ))
        XCTAssertTrue(controller.contains("namespaces=fresh"))

        let publicDispatch = try functionBody(
            launcher,
            beginningWith: "case \"$MODE\" in",
            endingBefore: "esac"
        )
        for mode in ["$SELF_TEST_MODE", "$PREFLIGHT_MODE", "$EXECUTE_MODE", "$ROLLBACK_MODE"] {
            XCTAssertTrue(publicDispatch.contains(mode), "launcher omits public mode \(mode)")
        }
        for privateMode in ["ROOT_MODE", "ROOT_ROLLBACK_MODE", "ROOT_SEALED_ROLLBACK_MODE"] {
            XCTAssertFalse(publicDispatch.contains(privateMode), "launcher exposes \(privateMode)")
        }
        let rollbackBlock = try functionBody(
            launcher,
            beginningWith: #"if [ "$MODE" = "$ROLLBACK_MODE" ]; then"#,
            endingBefore: #"[ -f "$SOURCE" ]"#
        )
        assertOrdered(
            [
                #"RECOVERY_OUTPUT=$("$ROOT_RECOVERY_CONTROLLER" "$ROLLBACK_MODE" "$EXPECTED_REPO")"#,
                #"/usr/bin/printf '%s\n' "$RECOVERY_OUTPUT""#,
                "exit 0",
            ],
            in: rollbackBlock
        )
        assertOrdered(
            [
                #"if [ "$MODE" = "$ROLLBACK_MODE" ]; then"#,
                #"[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ]"#,
            ],
            in: launcher
        )
    }

    func testLauncherIsFailClosedUntilDeterministicTwinPinsAreFinal() throws {
        let launcher = try source(launcherPath)
        let status = try XCTUnwrap(shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher))
        let sourcePin = try XCTUnwrap(shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: launcher))
        let binaryPin = try XCTUnwrap(shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: launcher))
        let zeroPin = String(repeating: "0", count: 64)

        switch status {
        case "PENDING_FINAL_REVIEW":
            XCTAssertEqual(sourcePin, zeroPin)
            XCTAssertEqual(binaryPin, zeroPin)
        case "PINNED_FINAL_REVIEW":
            for pin in [sourcePin, binaryPin] {
                XCTAssertEqual(pin.count, 64)
                XCTAssertNotEqual(pin, zeroPin)
                XCTAssertNotNil(pin.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
            }
        default:
            XCTFail("unknown launcher release-pin state: \(status)")
        }

        assertOrdered(
            [
                #"[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ]"#,
                #"[ "$(/usr/bin/shasum -a 256 "$SOURCE""#,
                #"[ -f "$RUSTC" ]"#,
                #"BUILD_ROOT_A=$(/usr/bin/mktemp -d"#,
                "compile_controller \"$BUILD_ROOT_A\"",
                "compile_controller \"$BUILD_ROOT_B\"",
                #"/usr/bin/cmp -s "$CONTROLLER_A" "$CONTROLLER_B""#,
                #"[ "$CONTROLLER_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ]"#,
                #""$CONTROLLER_B" "$@""#,
            ],
            in: launcher
        )
        XCTAssertTrue(launcher.contains(
            "BUILD_PARENT='/Volumes/t7/opensteamer-diagnostic-driver-v17-controller-builds'"
        ))
        XCTAssertTrue(launcher.contains("--edition=2021 -D warnings -C opt-level=2"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url(launcherPath).path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o755)
    }

    func testCurrent720SelectionIsReviewedWithoutExpandingRequiredCapabilities() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let requiredModes = try functionBody(
            controller,
            beginningWith: "fn required_current_virtual_display_modes()",
            endingBefore: "fn reviewed_current_virtual_display_selected_modes()"
        )
        let selectedModes = try functionBody(
            controller,
            beginningWith: "fn reviewed_current_virtual_display_selected_modes()",
            endingBefore: "fn selected_virtual_display_mode("
        )
        let fixedCapabilities =
            "1080:1920:1080:1920:60000,603:1311:1206:2622:60000,"
            + "540:1170:1080:2340:60000,540:960:1080:1920:60000,"
            + "414:896:828:1792:60000,750:1334:750:1334:60000"

        XCTAssertFalse(requiredModes.contains("logical_width: 720"))
        XCTAssertTrue(selectedModes.contains("logical_width: 720"))
        XCTAssertTrue(selectedModes.contains("logical_height: 1_280"))
        XCTAssertTrue(selectedModes.contains("pixel_width: 720"))
        XCTAssertTrue(selectedModes.contains("pixel_height: 1_280"))
        XCTAssertTrue(launcher.contains(
            #"[ "$LOCATOR_DISPLAY_CAPABILITIES" = '\#(fixedCapabilities)' ]"#
        ))
        XCTAssertTrue(launcher.contains(
            "750:1334:750:1334:60000|720:1280:720:1280:60000)"
        ))
        XCTAssertFalse(launcher.contains("\(fixedCapabilities),720:1280:720:1280:60000"))
    }

    func testCandidateExecutableSizeIsSharedByPreflightAndRootStaging() throws {
        let controller = try source(controllerPath)
        let preflightReads = try functionBody(
            controller,
            beginningWith: "fn verify_root_staging_static_source_reads()",
            endingBefore: "fn verify_generated_root_staging_reader("
        )
        let rootStaging = try functionBody(
            controller,
            beginningWith: "fn stage_normalized_candidate_driver(",
            endingBefore: "fn stage_root_artifacts("
        )
        let executableTuple = [
            "\"Contents/MacOS/OpensteamerVirtualMicrophone\"",
            "0o755",
            "CANDIDATE_DRIVER_EXECUTABLE_SIZE",
            "CANDIDATE_DRIVER_EXECUTABLE_SHA256",
        ]

        XCTAssertTrue(controller.contains(
            "const CANDIDATE_DRIVER_EXECUTABLE_SIZE: u64 = 170_400;"
        ))
        assertOrdered(executableTuple, in: preflightReads)
        assertOrdered(executableTuple, in: rootStaging)
        XCTAssertFalse(preflightReads.contains("170_432"))
        XCTAssertFalse(rootStaging.contains("170_432"))
    }

    func testV17PinsExactV15ReleaseBytesAndTerminalPrestopAbortedEvidence() throws {
        let controller = try source(controllerPath)
        let retainedFiles: [(String, Int, String)] = [
            (
                retainedV15SourcePath,
                1_387_240,
                "9ff0804df86911a4b9d206cb9dfb6c6e91611f0e23cebd031192db7a1b3100d1"
            ),
            (
                retainedV15LauncherPath,
                18_713,
                "63ac68a31a6755a7784f02a39f9830ee2593adbaed127fa8201842dc13b69c40"
            ),
            (
                retainedV15ContractPath,
                33_248,
                "3acca7e3ac9610f6151bb405048ef0c4840c9d7cb79171463b19bb209528b1e6"
            ),
            (
                probeSourcePath,
                388_802,
                "2cd52ef094b2e90ccf166626de36b5deb1179f6d4e0eed40b2223ac52343566c"
            ),
        ]
        for (path, size, digest) in retainedFiles {
            let bytes = try data(path)
            XCTAssertEqual(bytes.count, size, "retained V15 size changed: \(path)")
            XCTAssertEqual(sha256Hex(bytes), digest, "retained V15 bytes changed: \(path)")
        }

        for token in [
            "const RETAINED_V15_NONCE: &str = \"90dea54bdbab5f5cc53ed26214dbc7a4\";",
            "const RETAINED_V15_SOURCE_COMMIT: &str = \"9dc0c9f370df8a6149df9f7831be444a31f12bab\";",
            "const RETAINED_V15_SOURCE_TREE: &str = \"07c9ff2726391cd7387738e1295db9a6be2595e0\";",
            "const RETAINED_V15_SOURCE_SIZE: u64 = 1_387_240;",
            "const RETAINED_V15_LAUNCHER_SIZE: u64 = 18_713;",
            "const RETAINED_V15_CONTRACT_TEST_SIZE: u64 = 33_248;",
            "const RETAINED_V15_PROBE_SOURCE_SIZE: u64 = 388_802;",
            "const RETAINED_V15_CONTROLLER_BINARY_SIZE: u64 = 3_945_304;",
            "const RETAINED_V15_USER_UPDATE_ROOT_INODE: u64 = 29_890_440;",
            "const RETAINED_V15_USER_UPDATE_LOCK_INODE: u64 = 29_889_186;",
            "const RETAINED_V15_ROOT_UPDATE_LOCK_INODE: u64 = 29_890_688;",
            "3397e5833c1430d7549f6fb61ddcc2037de22cf05327c1a73ec024e889987d00",
            "90a4c6031ead40c4877065845b47282a978eadee6154cd93f5f9bfaac6a915b9",
            "bc5851809c36f4a0e959f74e88997d3d79e6cc83399e9ea08ce030b19442115c",
            "58d56c081710a092ea91bdf607b7ea0b057b8a0e6048eb5d9a8bdd7174e9e012",
            "391a67a6721d100ae5ce9ae3d07ebf89bd988a13900e3f0d03f38d063f472502",
            "aa7ddee0216987b53a24757bb99230179ac268131ab65b3a2b938c391fc4465d",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_STATE_V15",
            "state=PRESTOP_ABORTED",
            "status=rolled-back",
            "detail=prestop-aborted;host=preserved;routes=unchanged",
            "rollback_reserve=unavailable",
            "retained v15 root manifest does not contain exactly 28 nodes",
        ] {
            XCTAssertTrue(controller.contains(token), "missing V15 terminal evidence pin: \(token)")
        }
        XCTAssertTrue(controller.contains("specs.len() != 28"))
    }

    func testRetainedV15PinsCompleteUserAndPartialRootGraphs() throws {
        let controller = try source(controllerPath)
        let userGraph = try functionBody(
            controller,
            beginningWith: "fn retained_v15_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v15_descriptor_graph_payload("
        )
        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v15_root_node_specs()",
            endingBefore: "fn validate_retained_v15_root_identity("
        )
        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v15_root_graph_once(",
            endingBefore: "fn uid501_verify_retained_v15_root_prestop_aborted("
        )

        for token in [
            "RETAINED_V15_USER_UPDATE_ROOT_INODE",
            "RETAINED_V15_EVIDENCE_INODE",
            "RETAINED_V15_PROBES_INODE",
            "RETAINED_V15_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V15_JOURNAL_INODE",
            "RETAINED_V15_REQUEST_INODE",
            "RETAINED_V15_READER_INODE",
            "RETAINED_V15_CONTROLLER_PIN_INODE",
            "RETAINED_V15_CONTROLLER_IDENTITY_INODE",
            "RETAINED_V15_RESULT_INODE",
            "RETAINED_V15_USER_UPDATE_LOCK_INODE",
        ] {
            XCTAssertTrue(userGraph.contains(token), "V15 user graph omits \(token)")
        }
        XCTAssertTrue(userGraph.contains("let specs = ["))
        XCTAssertTrue(userGraph.contains("identities.push(held_identity)"))

        for inode in [
            "29_890_449", "29_890_451", "29_890_452", "29_890_453", "29_890_456",
            "29_890_457", "29_890_460", "29_890_461", "29_890_462", "29_890_831",
            "29_890_823", "29_890_824", "29_890_825", "29_890_826", "29_890_827",
            "29_890_828", "29_890_829", "29_890_834", "29_890_835", "29_890_836",
            "29_890_837", "29_890_838", "29_890_839", "29_890_840", "29_890_957",
            "29_890_958", "29_890_963",
        ] {
            XCTAssertTrue(rootSpecs.contains(inode), "V15 root graph omits inode \(inode)")
        }
        XCTAssertTrue(rootSpecs.contains("RETAINED_V15_ROOT_UPDATE_LOCK_INODE"))
        XCTAssertFalse(rootSpecs.contains("macos.join(\"OpensteamerVirtualMicrophone\")"))
        XCTAssertEqual(
            sha256Hex(Data(rootSpecs.utf8)),
            "fe0820552298f2fe63edb68ecc9e604a1a9ccd404f0fdd24e622b0ae1495e644"
        )
        assertOrdered(
            ["contents.join(\"MacOS\")", "vec![]", "staged candidate MacOS"],
            in: rootProof
        )
        XCTAssertTrue(rootProof.contains("PathBuf::from(RETAINED_V15_ROOT_PROBE_PARENT)"))
        XCTAssertTrue(rootProof.contains("specs.len() != 28"))
        XCTAssertTrue(rootProof.contains("STATE PRESTOP_ABORTED"))
    }

    func testV15GuardsCoverPreflightExecutionRollbackAndRootRecovery() throws {
        let controller = try source(controllerPath)
        let preflight = try functionBody(
            controller,
            beginningWith: "fn preflight(",
            endingBefore: "fn build_diagnostic_reader("
        )
        let completePreflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        for token in [
            "verify_retained_v15_release_files(&repo)?",
            "uid501_verify_retained_v15_root_prestop_aborted()?",
            "verify_retained_v15_user_prestop_aborted(retained_v15_lock)?",
        ] {
            XCTAssertTrue(completePreflight.contains(token), "V15 preflight guard absent: \(token)")
        }
        XCTAssertTrue(preflight.contains("acquire_retained_v15_user_update_lock()?"))
        XCTAssertTrue(preflight.contains("verify_complete_preflight("))

        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        XCTAssertTrue(rootTransaction.contains("acquire_retained_v15_root_update_lock()?"))
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "verify_retained_v15_root_prestop_aborted", in: rootTransaction),
            3
        )

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn root_rollback_authorized_update("
        )
        let rootRollback = try functionBody(
            controller,
            beginningWith: "fn root_rollback_authorized_update(",
            endingBefore: "fn root_sealed_rollback_authorized_update("
        )
        let sealedRollback = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn validate_sudo_supervisor_self_test_marker("
        )
        XCTAssertTrue(execute.contains("acquire_retained_v15_user_update_lock()?"))
        XCTAssertTrue(execute.contains("verify_complete_preflight("))
        XCTAssertTrue(execute.contains("verify_retained_v15_user_prestop_aborted_once"))
        XCTAssertTrue(rollback.contains("acquire_retained_v15_user_update_lock()?"))
        XCTAssertTrue(rollback.contains("verify_retained_v15_user_prestop_aborted"))
        XCTAssertTrue(rollback.contains("uid501_verify_retained_v15_root_prestop_aborted()?"))
        XCTAssertTrue(rootRollback.contains("mutable user-request rollback is retired"))
        XCTAssertFalse(rootRollback.contains("run_sudo_helper"))
        XCTAssertTrue(sealedRollback.contains("acquire_retained_v15_root_update_lock()?"))
        XCTAssertTrue(sealedRollback.contains("verify_retained_v15_root_prestop_aborted"))
    }

    func testPostProbeRouteProofIsDistinctAndOrderedBeforeDriverValidated() throws {
        let controller = try source(controllerPath)
        for token in [
            #"const POST_RELOAD_ROUTE_TRANSCRIPT_NAME: &str = "post-reload-route-proof.log";"#,
            #"const POST_PROBE_ROUTE_TRANSCRIPT_NAME: &str = "post-probe-route-proof.log";"#,
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase={}",
            "RouteProofPhase::PostReload",
            "RouteProofPhase::PostProbe",
            ".create_new(true)",
        ] {
            XCTAssertTrue(controller.contains(token), "missing phase-labelled route proof: \(token)")
        }

        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered(
            [
                "journal.record(\n                UpdateState::CoreAudioReloaded",
                "RouteProofPhase::PostReload",
                "let driver_generation = run_passive_driver_validation",
                "RouteProofPhase::PostProbe",
                "UpdateState::DriverValidated",
                "restart_exact_current_host",
                "UpdateState::ReadyVerified",
                "release_rollback_reserve_descriptor",
            ],
            in: transaction
        )

        let passive = try functionBody(
            controller,
            beginningWith: "fn run_passive_driver_validation(",
            endingBefore: "// BOUNDED_NATIVE_JSON_VALIDATOR"
        )
        assertOrdered(
            [
                "read_passive_snapshot_json",
                "run_both_order_with_root_held_result",
                "write_new_private",
                "verify_mirror_loopback_result",
                "read_passive_snapshot_json",
                "validate_post_loopback_causal_delta",
            ],
            in: passive
        )
    }

    func testRepeatedFreshHelpersSettleWithoutHALAndTimeoutIsTerminal() throws {
        let controller = try source(controllerPath)
        for token in [
            "const POST_RELOAD_ROUTE_TIMEOUT: Duration = Duration::from_secs(25);",
            "const HAL_CHILD_TIMEOUT: Duration = Duration::from_secs(3);",
            "const BOTH_ORDER_PROBE_TIMEOUT: Duration = Duration::from_secs(120);",
            "const POST_RELOAD_AFTER_GENERATION_RESERVE: Duration = Duration::from_secs(2);",
            "const HAL_CHILD_TIMEOUT_CLEANUP_BUDGET: Duration = Duration::from_secs(1);",
            "const AIRPLAY_ONLY_QUIESCENCE_TIMEOUT: Duration = Duration::from_secs(180);",
            "const AIRPLAY_ONLY_QUIESCENCE_MINIMUM_AGE: Duration = Duration::from_secs(90);",
            "const AIRPLAY_ONLY_QUIESCENCE_REQUIRED_WINDOWS: usize = 10;",
            "const AIRPLAY_ONLY_QUIESCENCE_MAX_CPU_CENTISECONDS: u64 = 10;",
            "const NO_HAL_QUIESCENCE_TIMEOUT: Duration = Duration::from_secs(180);",
            "const NO_HAL_QUIESCENCE_REQUIRED_WINDOWS: usize = 20;",
            "const NO_HAL_QUIESCENCE_MAX_COMBINED_CPU_CENTISECONDS: u64 = 25;",
            "const SUDO_TRANSACTION_TIMEOUT: Duration = Duration::from_secs(7_800);",
            "const SUDO_RECOVERY_TIMEOUT: Duration = Duration::from_secs(3_600);",
            "const SUPERVISOR_TRANSACTION_COMMAND_ALLOWANCE: u64 = 36;",
            "const SUPERVISOR_RECOVERY_COMMAND_ALLOWANCE: u64 = 24;",
        ] {
            XCTAssertTrue(controller.contains(token), "missing route timing contract: \(token)")
        }

        let supervisorBudget = try functionBody(
            controller,
            beginningWith: "fn stabilized_reload_budget_seconds(",
            endingBefore: "fn self_test_post_bootstrap_pre_lock_recovery_admission("
        )
        for token in [
            "AIRPLAY_ROTATION_TIMEOUT",
            "AIRPLAY_ONLY_QUIESCENCE_TIMEOUT",
            "COREAUDIO_TIMEOUT",
            "NO_HAL_QUIESCENCE_TIMEOUT",
            "POST_RELOAD_ROUTE_TIMEOUT",
            "BOTH_ORDER_PROBE_TIMEOUT",
            "HOST_TIMEOUT",
            "SUPERVISOR_TRANSACTION_COMMAND_ALLOWANCE",
            "SUPERVISOR_RECOVERY_COMMAND_ALLOWANCE",
            "sealed_recovery_budget_seconds",
            "root_transaction_budget_seconds",
            "SUDO_RECOVERY_TIMEOUT.as_secs() < required_recovery_seconds",
            "SUDO_TRANSACTION_TIMEOUT.as_secs() < required_transaction_seconds",
            "stabilized_reload_budget_seconds(false) != 540",
            "stabilized_reload_budget_seconds(true) != 720",
            "required_recovery_seconds != 2_870",
            "required_transaction_seconds != 7_050",
        ] {
            XCTAssertTrue(supervisorBudget.contains(token), "missing supervisor budget term: \(token)")
        }

        let reducer = try functionBody(
            controller,
            beginningWith: "fn advance_post_reload_route_helper_outcome(",
            endingBefore: "fn evaluate_post_reload_route_observations("
        )
        XCTAssertTrue(reducer.contains("FreshRouteHelperOutcome::TimedOut => Err"))
        XCTAssertTrue(reducer.contains("stable route proof is terminally unproved"))
        XCTAssertTrue(reducer.contains("FreshRouteHelperOutcome::NotRun(error) => Err(error)"))

        let freshRouteLauncher = try functionBody(
            controller,
            beginningWith: "fn run_uid501_fresh_route_helper(",
            endingBefore: "fn classify_fresh_route_helper_execution("
        )
        XCTAssertEqual(
            occurrences(of: "BoundedHalChildExecution::NotLaunched", in: freshRouteLauncher),
            2
        )
        XCTAssertFalse(freshRouteLauncher.contains("env::current_exe()?"))
        XCTAssertFalse(freshRouteLauncher.contains("path_text(&executable)?"))

        let classifier = try functionBody(
            controller,
            beginningWith: "fn classify_fresh_route_helper_outcome(",
            endingBefore: "fn validate_fresh_route_helper_outcome_for_transcript("
        )
        XCTAssertTrue(classifier.contains(
            "Ok(BoundedHalChildExecution::NotLaunched(error)) => FreshRouteHelperOutcome::NotRun(error)"
        ))
        let outcomeImplementation = try functionBody(
            controller,
            beginningWith: "impl FreshRouteHelperOutcome {",
            endingBefore: "#[derive(Clone, Copy, Debug, Eq, PartialEq)]\nenum PostReloadRouteProofProgress"
        )
        XCTAssertTrue(outcomeImplementation.contains(#"Self::NotRun(_) => "not-run""#))

        let settle = try functionBody(
            controller,
            beginningWith: "fn settle_after_complete_route_without_hal(",
            endingBefore: "fn prove_post_reload_routes("
        )
        XCTAssertTrue(settle.contains("prove_no_hal_quiescence_until"))
        XCTAssertTrue(settle.contains("expected_airplay"))
        XCTAssertTrue(settle.contains("generation_deadline"))
        XCTAssertFalse(settle.contains("run_uid501_fresh_route_helper"))
        XCTAssertFalse(settle.contains("capture_route_snapshot"))

        let proof = try functionBody(
            controller,
            beginningWith: "fn prove_post_reload_routes(",
            endingBefore: "fn coreaudio_restart_successor_is_exact("
        )
        XCTAssertTrue(proof.contains("for attempt in 1..=POST_RELOAD_ROUTE_MAX_ATTEMPTS"))
        XCTAssertTrue(proof.contains("prove_no_hal_quiescence_until"))
        XCTAssertTrue(proof.contains("read_airplay_helper_generation_before"))
        XCTAssertTrue(proof.contains("airplay_generation_bracket_is_exact"))
        XCTAssertEqual(
            occurrences(of: "if !post_reload_route_attempt_is_within_bounds(", in: proof),
            3
        )
        XCTAssertTrue(proof.contains("FreshRouteHelperOutcome::NotRun(_) => {}"))
        assertOrdered(
            [
                "let helper_completion_limit = deadline",
                "\"before-generation\",\n            \"exact\"",
                "if !post_reload_route_attempt_is_within_bounds(",
                "\"helper\",\n                \"not-run\"",
                "hal_child_timeout_preserving_after_generation_reserve(deadline)",
                "run_uid501_fresh_route_helper(\n            helper_timeout,\n            Some(helper_completion_limit)",
                "validate_fresh_route_helper_outcome_for_transcript",
                "let outcome_token = outcome.transcript_token();",
                "\"helper\",\n            outcome_token",
                "if let Some(detail) = helper_not_run_detail.as_deref() {\n            let primary_error",
                "\"after-generation\",\n                \"not-run\"",
                "finish_post_reload_route_transcript(&mut transcript, \"failed\"",
                "return Err",
                "if let Some(detail) = helper_fatal_detail.as_deref()",
                "\"after-generation\",\n                \"not-run\"",
                "finish_post_reload_route_transcript(&mut transcript, \"fatal\"",
                "return Err",
                "let after = match read_coreaudio_generation_before(deadline)",
                "\"after-generation\",\n            \"exact\"",
                "FreshRouteHelperOutcome::TimedOut",
                "finish_post_reload_route_transcript(&mut transcript, \"failed\"",
                "return Err",
                "advance_post_reload_route_helper_outcome",
            ],
            in: proof
        )
        XCTAssertTrue(proof.contains("if helper_was_complete"))
        XCTAssertTrue(proof.contains("settle_after_complete_route_without_hal"))
        XCTAssertTrue(controller.contains("HAL helper setup delay moved its absolute completion limit"))
        XCTAssertTrue(controller.contains("HAL helper exact cleanup-only boundary"))
    }

    func testRouteTranscriptGrammarMakesTimeoutFatalChangeAndNoLaunchTerminal() throws {
        let controller = try source(controllerPath)
        let parser = try functionBody(
            controller,
            beginningWith: "fn parse_post_reload_route_transcript(",
            endingBefore: "fn create_post_reload_route_transcript("
        )
        for token in [
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase=post-reload",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase=post-probe",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase=old-driver-rehearsal",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase=post-host",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase=rollback-pre-host",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V17 phase=rollback-post-host",
            "let mut required_terminal_result: Option<&'static str> = None;",
            "route transcript continued after a terminal attempt outcome",
            "helper_outcome == Some(\"timed-out\")",
            "before_outcome == Some(\"not-run\")",
            "helper_outcome == Some(\"not-run\")",
            "Some(\"fatal\")",
            "Some(\"failed\")",
        ] {
            XCTAssertTrue(parser.contains(token), "missing terminal transcript rule: \(token)")
        }
        XCTAssertTrue(parser.contains("line.contains(\"uid\")"))
        XCTAssertTrue(parser.contains("counts[2] != 0"))

        for fixture in [
            "canonical_no_launch_after_generation_transcript",
            "canonical_no_launch_before_generation_transcript",
            "timeout_then_proven_transcript",
            "timeout_then_later_failed_transcript",
            "fatal_then_later_fatal_transcript",
            "changed_then_later_fatal_transcript",
            "not_run_then_later_failed_transcript",
            "complete fresh route snapshot differs from authenticated baseline",
            "consecutive complete fresh route snapshots differ",
            "baseline mismatch was not classified fatal before transcript append",
        ] {
            XCTAssertTrue(controller.contains(fixture), "missing transcript mutant: \(fixture)")
        }
    }

    func testAquaAndDirectChildrenHaveBoundedArmedContainmentAndNonblockingPipes() throws {
        let controller = try source(controllerPath)
        let guardBody = try functionBody(
            controller,
            beginningWith: "struct ArmedHalChildProcessGroup",
            endingBefore: "#[derive(Default)]\nstruct BoundedNonblockingPipeCapture"
        )
        for token in [
            "cleanup_deadline: Instant",
            "impl Drop for ArmedHalChildProcessGroup",
            "signal_process_group(SIGTERM)",
            "signal_process_group(SIGKILL)",
            "self.child.try_wait()",
            "terminate_and_reap_within_reserved_budget",
            "disarm_after_confirmed_completion",
            "hard_contain_after_reserved_budget",
            "while self.armed",
            "hard SIGKILL containment completed before control returned",
        ] {
            XCTAssertTrue(guardBody.contains(token), "missing armed containment rule: \(token)")
        }

        let aqua = try functionBody(
            controller,
            beginningWith: "fn bounded_aqua_uid501_hal_output_in_directory(",
            endingBefore: "fn bounded_direct_uid501_audio_output_in_directory("
        )
        let direct = try functionBody(
            controller,
            beginningWith: "fn bounded_direct_uid501_audio_output_in_directory(",
            endingBefore: "fn require_completed_hal_child("
        )
        for (body, label) in [(aqua, "Aqua"), (direct, "direct")] {
            assertOrdered(
                [
                    "child_deadline",
                    "command.spawn()",
                    "ArmedHalChildProcessGroup::new(child, completion_deadline)",
                    "let execution = (|| -> Result<BoundedHalChildExecution>",
                    "configure_nonblocking_pipe",
                    "drain_nonblocking_pipe",
                    "match execution",
                    "Err(primary) => match guarded_child",
                ],
                in: body
            )
            XCTAssertEqual(
                occurrences(of: "terminate_and_reap_within_reserved_budget", in: body),
                4,
                label
            )
            XCTAssertTrue(body.contains("Ok(result) if !guarded_child.armed => Ok(result)"), label)
            XCTAssertFalse(body.contains("thread::spawn"), label)
            XCTAssertFalse(body.contains(".join()"), label)
        }
        XCTAssertTrue(aqua.contains("completion_limit: Option<Instant>"))
        XCTAssertTrue(aqua.contains("bounded_hal_child_deadlines(timeout, completion_limit)"))
        XCTAssertTrue(aqua.contains(
            "let pre_spawn_setup = (|| -> Result<(BoundedHalChildDeadlines, Vec<String>)>"
        ))
        XCTAssertEqual(
            occurrences(of: "BoundedHalChildExecution::NotLaunched", in: aqua),
            3
        )
        assertOrdered(
            [
                "let pre_spawn_setup",
                "bounded_hal_child_deadlines(timeout, completion_limit)",
                "if Instant::now() >= child_deadline",
                "Aqua HAL child setup exhausted its child budget before spawn",
                "let child = match command.spawn()",
                "cannot execute Aqua UID501 HAL child",
                "ArmedHalChildProcessGroup::new(child, completion_deadline)",
            ],
            in: aqua
        )
        XCTAssertTrue(controller.contains(
            "HAL child cleanup budget cannot fit before its absolute completion limit"
        ))

        let requireCompleted = try functionBody(
            controller,
            beginningWith: "fn require_completed_hal_child(",
            endingBefore: "fn prove_same_responsibility_uid501_microphone_authorization("
        )
        XCTAssertTrue(requireCompleted.contains(
            "BoundedHalChildExecution::NotLaunched(error) => Err(error)"
        ))
        XCTAssertFalse(requireCompleted.contains("could not launch within its child/cleanup budget"))
    }

    func testAirPlayRotationAndNoHALQuiescenceGateAreExactAndOrdered() throws {
        let controller = try source(controllerPath)

        let parser = try functionBody(
            controller,
            beginningWith: "fn parse_airplay_helper_launch_state(",
            endingBefore: "fn read_airplay_helper_generation_before("
        )
        for token in [
            "system/com.apple.AirPlayXPCHelper = {",
            "/System/Library/LaunchDaemons/com.apple.AirPlayXPCHelper.plist",
            "LaunchDaemon",
            "/usr/libexec/AirPlayXPCHelper",
            #"Some("system")"#,
            "AirPlayXPCHelper run count is absent",
            "AirPlayXPCHelper PID is absent",
        ] {
            XCTAssertTrue(parser.contains(token), "missing exact AirPlay parser token: \(token)")
        }

        let generation = try functionBody(
            controller,
            beginningWith: "fn read_airplay_helper_generation_before(",
            endingBefore: "fn read_airplay_helper_generation("
        )
        for token in [
            "pid_text.as_str()",
            #""/usr/libexec/AirPlayXPCHelper""#,
            #"["-x", "AirPlayXPCHelper"]"#,
            "process_start_with_timeout",
            "AirPlayXPCHelper process set is not exact",
        ] {
            XCTAssertTrue(generation.contains(token), "missing AirPlay generation proof: \(token)")
        }

        let rotation = try functionBody(
            controller,
            beginningWith: "fn rotate_airplay_helper_exact(",
            endingBefore: "fn stabilized_coreaudio_reload("
        )
        assertOrdered(
            [
                "capture_server_processes",
                "stable_coreaudio_generation",
                "stable_airplay_helper_generation",
                "kill(before.pid as i32, SIGTERM)",
                "read_coreaudio_generation_before",
                "read_airplay_helper_generation_before",
                "airplay_restart_successor_is_exact",
                "kill(before.pid as i32, 0)",
            ],
            in: rotation
        )
        XCTAssertTrue(rotation.contains("after.runs > before.runs.saturating_add(1)"))
        XCTAssertTrue(rotation.contains("old AirPlayXPCHelper PID did not disappear exactly"))
        XCTAssertFalse(rotation.contains("run_uid501_fresh_route_helper"))
        XCTAssertFalse(rotation.contains("AudioObjectGetPropertyData"))

        let airPlayOnlyQuiescence = try functionBody(
            controller,
            beginningWith: "fn prove_airplay_only_quiescence(",
            endingBefore: "fn combined_audio_cpu_centiseconds_before("
        )
        for token in [
            "AIRPLAY_ONLY_QUIESCENCE_MINIMUM_AGE",
            "AIRPLAY_ONLY_QUIESCENCE_TIMEOUT",
            "AIRPLAY_ONLY_QUIESCENCE_REQUIRED_WINDOWS",
            "AIRPLAY_ONLY_QUIESCENCE_MAX_CPU_CENTISECONDS",
            "read_exact_process_cpu_centiseconds_before",
            "read_coreaudio_generation_before",
            "read_airplay_helper_generation_before",
            "capture_server_processes",
            "HOST_AIRPLAY_HELPER_UNSETTLED",
        ] {
            XCTAssertTrue(
                airPlayOnlyQuiescence.contains(token),
                "missing AirPlay-only gate token: \(token)"
            )
        }
        XCTAssertFalse(airPlayOnlyQuiescence.contains("run_uid501_fresh_route_helper"))
        XCTAssertFalse(airPlayOnlyQuiescence.contains("AudioObjectGetPropertyData"))

        let quiescence = try functionBody(
            controller,
            beginningWith: "fn prove_no_hal_quiescence_until(",
            endingBefore: "fn prove_no_hal_quiescence("
        )
        for token in [
            "combined_audio_cpu_centiseconds_before",
            "read_coreaudio_generation_before",
            "read_airplay_helper_generation_before",
            "NO_HAL_QUIESCENCE_SAMPLE_INTERVAL",
            "NO_HAL_QUIESCENCE_MAX_COMBINED_CPU_CENTISECONDS",
            "HOST_COREAUDIO_WEDGED",
            "quiet_windows = 0",
        ] {
            XCTAssertTrue(quiescence.contains(token), "missing no-HAL gate token: \(token)")
        }
        XCTAssertFalse(quiescence.contains("run_uid501_fresh_route_helper"))
        XCTAssertFalse(quiescence.contains("AudioObjectGetPropertyData"))

        let stabilizedReload = try functionBody(
            controller,
            beginningWith: "fn stabilized_coreaudio_reload(",
            endingBefore: "fn canonical_repo("
        )
        assertOrdered(
            [
                "rotate_airplay_helper_exact",
                "prove_airplay_only_quiescence",
                "if require_pre_reload_quiescence",
                "prove_no_hal_quiescence(expected_coreaudio",
                "reload_coreaudio_exact",
                "prove_no_hal_quiescence(&new_coreaudio",
            ],
            in: stabilizedReload
        )

        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered(
            [
                "stop_exact_current_host",
                "stabilized_coreaudio_reload(&baseline_coreaudio, false)",
                "RouteProofPhase::OldDriverRehearsal",
                "publish_candidate_driver",
                "stabilized_coreaudio_reload(&rehearsed_coreaudio, true)",
                "RouteProofPhase::PostReload",
                "RouteProofPhase::PostProbe",
                "restart_exact_current_host",
                "prove_no_hal_quiescence(&new_coreaudio, &new_airplay)",
                "RouteProofPhase::PostHost",
            ],
            in: transaction
        )
        let beforePublication = transaction.components(separatedBy: "publish_candidate_driver").first ?? ""
        XCTAssertFalse(beforePublication.contains("stable_fresh_route_snapshot_for_generation"))

        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        assertOrdered(
            [
                "verify_installed_v7_driver",
                "stabilized_coreaudio_reload(&current, false)",
                "RouteProofPhase::RollbackPreHost",
                "restart_or_recover_exact_current_host",
                "RouteProofPhase::RollbackPostHost",
            ],
            in: rollback
        )
        XCTAssertTrue(rollback.contains("RollbackRouteStatus::Unchanged"))
        XCTAssertTrue(rollback.contains("Err(route_error)"))
        XCTAssertTrue(rollback.contains("RollbackRouteStatus::Unproved"))
        XCTAssertTrue(rollback.contains("unattended rollback must not strand"))
        let fallbackStart = try XCTUnwrap(rollback.range(of: "Err(route_error)"))
        let fallbackEnd = try XCTUnwrap(
            rollback.range(of: "// Publish HOST_REBOOTSTRAPPED", range: fallbackStart.upperBound..<rollback.endIndex)
        )
        let fallback = String(rollback[fallbackStart.lowerBound..<fallbackEnd.lowerBound])
        XCTAssertTrue(fallback.contains("restart_or_recover_exact_current_host(initial)"))
        XCTAssertFalse(fallback.contains("restore_and_verify_live_current_host"))
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "restart_or_recover_exact_current_host(initial)", in: rollback),
            4
        )
        XCTAssertFalse(rollback.contains("restore_and_verify_live_current_host"))

        let terminalRepair = try functionBody(
            controller,
            beginningWith: "fn repair_committed_terminal_state(",
            endingBefore: "fn report_prestop_aborted_terminal("
        )
        XCTAssertEqual(
            occurrences(of: "restart_or_recover_exact_current_host(&initial)", in: terminalRepair),
            2
        )
        XCTAssertFalse(terminalRepair.contains("restore_and_verify_live_current_host"))

        let retrySlots = try functionBody(
            controller,
            beginningWith: "fn route_transcript_recovery_name(",
            endingBefore: "fn create_post_reload_route_transcript("
        )
        XCTAssertTrue(controller.contains("const ROUTE_TRANSCRIPT_RECOVERY_SLOTS: usize = 4;"))
        XCTAssertTrue(retrySlots.contains("slot >= ROUTE_TRANSCRIPT_RECOVERY_SLOTS"))
        XCTAssertTrue(retrySlots.contains(#"format!("{stem}.retry-{slot}.log")"#))
        let transcriptCreation = try functionBody(
            controller,
            beginningWith: "fn create_post_reload_route_transcript(",
            endingBefore: "fn append_post_reload_route_transcript("
        )
        XCTAssertTrue(transcriptCreation.contains(
            "for slot in 0..ROUTE_TRANSCRIPT_RECOVERY_SLOTS"
        ))
        XCTAssertTrue(transcriptCreation.contains("retained route transcript phase changed"))
        XCTAssertTrue(transcriptCreation.contains("route transcript recovery slots are exhausted"))
    }

    func testRetainedV16RolledBackEvidenceAuthenticatesRecoveryBaseline() throws {
        let controller = try source(controllerPath)
        for token in [
            #"const RETAINED_V16_NONCE: &str = "5735c1a816a9fc0737daf8b95895373d";"#,
            #"const RETAINED_V16_ROOT_STATE_SHA256: &str ="#,
            #""4e7743ffef8077a7813eda137c08034e85ac5c340c287c028d5286c2e1c574e2""#,
            "const RETAINED_V16_USER_UPDATE_LOCK: &str =",
            "const RETAINED_V16_ROOT_UPDATE_LOCK: &str =",
            "const RETAINED_V16_USER_UPDATE_LOCK_INODE: u64 = 29_920_494;",
            "const RETAINED_V16_ROOT_UPDATE_LOCK_INODE: u64 = 29_921_989;",
            "acquire_retained_v16_user_update_lock()?;",
            "acquire_retained_v16_root_update_lock()?;",
            "verify_retained_v16_user_rolled_back_evidence(&retained_v16_lock)?;",
            "verify_retained_v16_root_rolled_back_evidence(&retained_v16_root_lock)?;",
            "verify_retained_v16_root_controller_graph()?;",
            "retained V16 root transaction",
            "RETAINED_V16_CONTROLLER_BINARY_SIZE",
            "state=ROLLED_BACK",
            "input_uid=BlackHole2ch_UID",
            "output_uid=BuiltInSpeakerDevice",
            "system_output_uid=BuiltInSpeakerDevice",
            "retained_v16_authenticated_route_snapshot",
        ] {
            XCTAssertTrue(controller.contains(token), "missing retained V16 recovery token: \(token)")
        }
        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered(
            [
                "verify_retained_v16_root_rolled_back_evidence",
                "let baseline_coreaudio = stable_coreaudio_generation",
                "let baseline_route = retained_v16_authenticated_route_snapshot",
                "stop_exact_current_host",
                "stabilized_coreaudio_reload(&baseline_coreaudio, false)",
                "RouteProofPhase::OldDriverRehearsal",
            ],
            in: transaction
        )
        let dispatchPosition = try XCTUnwrap(controller.range(of: "let output = run_sudo_helper("))
        let postDispatch = String(controller[dispatchPosition.lowerBound...])
        XCTAssertTrue(postDispatch.contains(
            "verify_retained_v16_user_rolled_back_evidence(&retained_v16_lock)?;"
        ))

        let preflight = try functionBody(
            controller,
            beginningWith: "fn preflight(",
            endingBefore: "fn build_diagnostic_reader("
        )
        XCTAssertEqual(
            occurrences(of: "acquire_retained_v16_user_update_lock()?", in: preflight),
            1
        )
        assertOrdered(
            [
                "acquire_retained_v16_user_update_lock()?",
                "verify_complete_preflight(",
            ],
            in: preflight
        )

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        XCTAssertEqual(
            occurrences(of: "acquire_retained_v16_user_update_lock()?", in: execute),
            1
        )
        assertOrdered(
            [
                "acquire_retained_v16_user_update_lock()?",
                "verify_complete_preflight(",
                "let output = run_sudo_helper(",
                "verify_retained_v16_user_rolled_back_evidence(&retained_v16_lock)?;",
            ],
            in: execute
        )

        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn root_rollback_authorized_update("
        )
        XCTAssertEqual(
            occurrences(of: "acquire_retained_v16_user_update_lock()?", in: rollback),
            1
        )
        assertOrdered(
            [
                "acquire_retained_v16_user_update_lock()?",
                "verify_retained_v16_user_rolled_back_evidence(&retained_v16_lock)?;",
                "let output = run_sudo_helper(",
                "verify_retained_v16_user_rolled_back_evidence(&retained_v16_lock)?;",
            ],
            in: rollback
        )

        XCTAssertEqual(
            occurrences(of: "acquire_retained_v16_root_update_lock()?", in: transaction),
            1
        )
        assertOrdered(
            [
                "acquire_retained_v16_root_update_lock()?",
                "verify_retained_v16_root_rolled_back_evidence(&retained_v16_root_lock)?;",
                "stop_exact_current_host",
                "verify_retained_v16_root_rolled_back_evidence(&retained_v16_root_lock)?;",
            ],
            in: transaction
        )
        XCTAssertGreaterThanOrEqual(
            occurrences(
                of: "verify_retained_v16_root_rolled_back_evidence(&retained_v16_root_lock)?;",
                in: transaction
            ),
            3
        )

        let sealedRollback = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn validate_sudo_supervisor_self_test_marker("
        )
        XCTAssertEqual(
            occurrences(of: "acquire_retained_v16_root_update_lock()?", in: sealedRollback),
            1
        )
        assertOrdered(
            [
                "acquire_retained_v16_root_update_lock()?",
                "verify_retained_v16_root_rolled_back_evidence(&retained_v16_root_lock)?;",
                "complete_root_recovery",
                "verify_retained_v16_root_rolled_back_evidence(&retained_v16_root_lock)?;",
            ],
            in: sealedRollback
        )
    }

    func testV17ControllerCompilesWithReleaseEditionAndPureSelfTestPasses() throws {
        let rustc = URL(fileURLWithPath: "/opt/homebrew/Cellar/rust/1.97.1/bin/rustc")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: rustc.path))
        let buildRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-v17-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: buildRoot) }
        let binary = buildRoot.appendingPathComponent("controller")
        let compile = try run(
            rustc,
            arguments: [
                "--edition=2021",
                "-D", "warnings",
                url(controllerPath).path,
                "-o", binary.path,
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.stderr)
        XCTAssertEqual(compile.stdout, "")

        let selfTest = try run(
            binary,
            arguments: ["--self-test-diagnostic-driver-v17-update"]
        )
        XCTAssertEqual(selfTest.status, 0, selfTest.stderr)
        XCTAssertEqual(selfTest.stderr, "")
        XCTAssertEqual(selfTest.stdout, "DIAGNOSTIC_DRIVER_V17_SELF_TEST_OK tests=139\n")
    }
}
