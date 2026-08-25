import CryptoKit
import Foundation
import XCTest

final class DiagnosticDriverV3UpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let controllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v3-update-controller.rs"
    private let launcherPath = "macOS/scripts/update-opensteamer-diagnostic-driver-v3.sh"

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
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

    private func sha256Hex(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func shellSingleQuotedValue(_ name: String, in source: String) -> String? {
        let prefix = "\(name)='"
        guard let start = source.range(of: prefix) else { return nil }
        let tail = source[start.upperBound...]
        guard let end = tail.firstIndex(of: "'") else { return nil }
        return String(tail[..<end])
    }

    func testV3NamespacesModesAndDedicatedReleaseCheckoutAreExact() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let freshConstants = try functionBody(
            controller,
            beginningWith: "const PREFLIGHT_MODE:",
            endingBefore: "const RETAINED_V1_DEVICE:"
        )
        for token in [
            #"const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v3-update-preflight";"#,
            #"const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v3-update";"#,
            #"const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v3-update";"#,
            #"const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v3-update";"#,
            #"const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v3-update";"#,
            #"const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v3-update";"#,
            #"const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v3-update";"#,
            #"const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V3";"#,
            #"const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V3";"#,
            "/diagnostic-driver-updates-v3", "/active-diagnostic-driver-update-v3",
            "/diagnostic-driver-update-v3.lock", "/diagnostic-driver-controllers-v3",
            "/diagnostic-driver-bootstrap-v3.txt", "/diagnostic-driver-probes-v3",
        ] {
            XCTAssertTrue(freshConstants.contains(token), "missing fresh V3 token: \(token)")
        }
        XCTAssertFalse(freshConstants.localizedCaseInsensitiveContains("v2"))

        let repo = "/Users/ahmed/Documents/Codex/opensteamer-diagnostic-v3"
        XCTAssertTrue(controller.contains(#"const EXPECTED_REPO: &str = "\#(repo)";"#))
        XCTAssertTrue(launcher.contains("EXPECTED_REPO='\(repo)'"))
        XCTAssertTrue(controller.contains(
            #"const EXPECTED_RELEASE_BRANCH: &str = "fix/diagnostic-driver-v3-current-host";"#
        ))
        let provenance = try functionBody(
            controller,
            beginningWith: "fn verify_git_provenance(",
            endingBefore: "fn verify_reader_inputs("
        )
        assertOrdered([
            #"&format!("{EXPECTED_UPDATER_BASE_COMMIT}^{{tree}}")"#,
            #""merge-base""#, "EXPECTED_UPDATER_BASE_COMMIT",
            #"&format!("{EXPECTED_SOURCE_COMMIT}^{{tree}}")"#,
            #"branch != EXPECTED_RELEASE_BRANCH"#, #"let remote_ref = format!("refs/heads/{branch}")"#,
            #"remote != format!("{commit}\t{remote_ref}")"#,
        ], in: provenance)

        let publicDispatch = try functionBody(
            launcher,
            beginningWith: "case \"$MODE\" in",
            endingBefore: "esac"
        )
        for mode in ["$SELF_TEST_MODE", "$PREFLIGHT_MODE", "$EXECUTE_MODE", "$ROLLBACK_MODE"] {
            XCTAssertTrue(publicDispatch.contains(mode), "launcher omits public mode \(mode)")
        }
        for privateMode in ["ROOT_MODE", "ROOT_ROLLBACK_MODE", "ROOT_SEALED_ROLLBACK_MODE",
                            "UID501_DISPLAY_SNAPSHOT_MODE", "UID501_DISPLAY_RESTORE_MODE"] {
            XCTAssertFalse(publicDispatch.contains(privateMode), "launcher exposes \(privateMode)")
        }
    }

    func testCurrentHostOldDriverCandidateAndRetainedV8PinsStaySeparate() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const HOST_EXECUTABLE_SHA256: &str =",
            #""7c8af9bebb748083020762ffca4511eee3445f97f817f29d6fc28d275471496a""#,
            "const HOST_EXECUTABLE_SIZE: u64 = 6_688_032;",
            "const HOST_INFO_PLIST_SHA256: &str =",
            #""3c017d9cf034cbc864fc19103a0919f296930f0752f8ecfedcb1c93fbbc9694d""#,
            "const HOST_INFO_PLIST_SIZE: u64 = 1_477;",
            #"const HOST_PLIST_SHA256: &str = "aebb2e1fdb680bca9c5df06d2ef5a35275e852b08b9c305ecfe80b11b8c9848e";"#,
            "const HOST_PLIST_SIZE: u64 = 1_180;", "const HOST_ARGUMENTS: [&str; 8] = [",
            #""--virtual-phone-display""#,
            #""f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49""#,
            #""ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866""#,
            "const INSTALLED_DRIVER_DEVICE: u64 = 16_777_229;",
            "const INSTALLED_DRIVER_INODE: u64 = 27_877_539;",
            "/reviewed-driver-candidates-v9/production-driver-v7",
            #""c37c82d8d4e62e387aadc556d0073fad80c752d96040bc2215e6088d8620c93a""#,
            #""84bfc68a9bf808936e60c80dbd8a02f601f54fe248c3f1f8de0b095142401dba""#,
            #""35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d""#,
            #""9f801306c944d2ea021fd1e65650714dd3c0c788e3b521dc927875dd9c3f004d""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing current/driver pin: \(exactPin)")
        }

        let current = try functionBody(
            controller,
            beginningWith: "fn verify_installed_current_host_bytes(",
            endingBefore: "fn verify_retained_v8_evidence("
        )
        let history = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v8_evidence(",
            endingBefore: "fn launchctl_print("
        )
        XCTAssertTrue(current.contains("verify_uid501_host_bundle_manifest()?"))
        XCTAssertTrue(current.contains("HOST_EXECUTABLE_SHA256"))
        XCTAssertTrue(current.contains("HOST_INFO_PLIST_SHA256"))
        XCTAssertTrue(current.contains("HOST_PLIST_SHA256"))
        XCTAssertFalse(current.contains("V8_EVIDENCE"))
        XCTAssertTrue(history.contains("V8_POINTER_SHA256"))
        XCTAssertTrue(history.contains("V8_JOURNAL_SHA256"))
        XCTAssertTrue(history.contains("deployment-reference/opensteamer Host.app"))
        XCTAssertFalse(history.contains("HOST_EXECUTABLE_SHA256"))
    }

    func testRetainedV1AndV2SourcesAndEvidenceRemainImmutable() throws {
        let expectedSourceHashes = [
            "macOS/scripts/opensteamer-diagnostic-driver-v1-update-controller.rs":
                "0a9125e53dce0ee87b76fc83543319064608a8c9b0a8947644e90bf570198e72",
            "macOS/scripts/update-opensteamer-diagnostic-driver-v1.sh":
                "025a7c2641bbaf56f2b7348eac1dd61e171828a19829050dd14e738e0a70f08d",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV1UpdateContractTests.swift":
                "5a20684124f2b227e9741bf67dfe5c8f2e87c7556bb7705034154d25944cc5bd",
            "macOS/scripts/opensteamer-diagnostic-driver-v2-update-controller.rs":
                "4df37ebcb2634ea1fed78165cc530ea8cb739fe1e9b59744010e2b64b922c98b",
            "macOS/scripts/update-opensteamer-diagnostic-driver-v2.sh":
                "3d3ccccee91f1be6b445a05fffae668091702b1771956ede3d8f499d4882f36b",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV2UpdateContractTests.swift":
                "6484143742397c1191ca6fa88ca2932846ad94c526e873acb60a0d15dd3b3dfb",
            "macOS/scripts/opensteamer-diagnostic-driver-v2-resume-stager.rs":
                "dd13167a6aec87f48af5eaacd0317c37df01ffadfb838ddcbfb6962b47904c4d",
            "macOS/scripts/resume-opensteamer-diagnostic-driver-v2.sh":
                "788b5102d34c9ff6c7193042cea3143feaeda94f78b8be18fb4b6c3ff7a18e30",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV2ResumeContractTests.swift":
                "29c2c2925e017508724728bff38c9e4804c37d1b472a5f5ff00391265c609f5d",
        ]
        for (path, expectedHash) in expectedSourceHashes {
            XCTAssertEqual(sha256Hex(try source(path)), expectedHash, "retained source changed: \(path)")
        }

        let controller = try source(controllerPath)
        for version in ["v1", "v2"] {
            let upper = version.uppercased()
            let payload = try functionBody(
                controller,
                beginningWith: "fn verify_retained_\(version)_descriptor_graph_payload(",
                endingBefore: "fn verify_retained_\(version)_descriptor_graph("
            )
            for pin in ["RETAINED_\(upper)_USER_ACTIVE_POINTER_SHA256",
                        "RETAINED_\(upper)_JOURNAL_SHA256", "RETAINED_\(upper)_REQUEST_SHA256",
                        "DIAGNOSTIC_READER_SHA256"] {
                XCTAssertTrue(payload.contains(pin), "\(version) payload omits \(pin)")
            }
        }
        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v1_root_prestop_attempt()?").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v2_root_prestop_attempt()?").count - 1,
            2
        )
        let preflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "verify_retained_v8_evidence()?", "verify_live_current_host()?",
            "verify_retained_v1_user_prestop_attempt(retained_v1_lock)?",
            "verify_retained_v2_user_prestop_attempt(retained_v2_lock)?",
        ], in: preflight)
    }

    func testUID501DisplaySnapshotRestoreAndSixV11MappingsAreExact() throws {
        let controller = try source(controllerPath)
        for mode in [
            #"const UID501_DISPLAY_SNAPSHOT_MODE: &str = "--uid501-current-virtual-display-snapshot";"#,
            #"const UID501_DISPLAY_RESTORE_MODE: &str = "--uid501-restore-current-virtual-display";"#,
        ] {
            XCTAssertTrue(controller.contains(mode))
        }
        let dispatch = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        for mode in ["UID501_DISPLAY_SNAPSHOT_MODE", "UID501_DISPLAY_RESTORE_MODE"] {
            XCTAssertTrue(dispatch.contains(#"[_, mode] if mode == \#(mode)"#))
        }
        XCTAssertGreaterThanOrEqual(
            dispatch.components(separatedBy: "require_uid501_display_helper_identity()?").count - 1,
            2
        )

        let mappings = try functionBody(
            controller,
            beginningWith: "fn required_current_virtual_display_modes(",
            endingBefore: "fn normalize_display_refresh_millihertz("
        )
        for mapping in [
            "mode(1_080, 1_920, 1_080, 1_920)", "mode(603, 1_311, 1_206, 2_622)",
            "mode(540, 1_170, 1_080, 2_340)", "mode(540, 960, 1_080, 1_920)",
            "mode(414, 896, 828, 1_792)", "mode(750, 1_334, 750, 1_334)",
        ] {
            XCTAssertTrue(mappings.contains(mapping), "missing V11 mapping: \(mapping)")
        }
        XCTAssertTrue(controller.contains("six required v11 mappings"))

        let duplicateModes = try functionBody(
            controller,
            beginningWith: "fn copy_current_virtual_display_modes_with_duplicates(",
            endingBefore: "fn capture_current_virtual_display_topology_local("
        )
        assertOrdered([
            "kCGDisplayShowDuplicateLowResolutionModes", "kCFBooleanTrue", "CFDictionaryCreate(",
            "keys.as_ptr()", "values.as_ptr()", "1,", "CGDisplayCopyAllDisplayModes(display, options)",
            "CFRelease(options)",
        ], in: duplicateModes)
        let topologyCapture = try functionBody(
            controller,
            beginningWith: "fn capture_current_virtual_display_topology_local(",
            endingBefore: "fn current_virtual_display_selected_mode_is_exact("
        )
        assertOrdered([
            "let restore_target = pinned_current_virtual_display_selection()",
            "let mut raw_restore_target_matches = 0_usize",
            "if identity == restore_target",
            "raw_restore_target_matches += 1",
            "if raw_restore_target_matches != 1",
        ], in: topologyCapture)
        XCTAssertTrue(controller.contains("const DISPLAY_CONFIGURATION_FOR_SESSION: u32 = 1;"))
        XCTAssertTrue(controller.contains(
            "CGCompleteDisplayConfiguration(configuration, DISPLAY_CONFIGURATION_FOR_SESSION)"
        ))
        let restoration = try functionBody(
            controller,
            beginningWith: "fn apply_pinned_current_virtual_display_mode_local(",
            endingBefore: "fn restore_pinned_current_virtual_display_mode_after_host_restart("
        )
        assertOrdered([
            "CGGetOnlineDisplayList(",
            "CGDisplayVendorNumber(displays[0]) } != CURRENT_VIRTUAL_DISPLAY_VENDOR",
            "CGDisplayModelNumber(displays[0]) } != CURRENT_VIRTUAL_DISPLAY_PRODUCT",
            "CGDisplaySerialNumber(displays[0]) } != CURRENT_VIRTUAL_DISPLAY_SERIAL",
            "CGConfigureDisplayWithDisplayMode(",
        ], in: restoration)
    }

    func testRestartRollbackAndRecoveryRestoreBeforeFullHostVerification() throws {
        let controller = try source(controllerPath)
        XCTAssertFalse(controller.contains("env::vars("))
        XCTAssertFalse(controller.contains("env::vars_os("))
        XCTAssertFalse(controller.contains("environment.len()"))

        let restore = try functionBody(
            controller,
            beginningWith: "fn restore_and_verify_live_current_host(",
            endingBefore: "#[repr(C)]"
        )
        assertOrdered([
            "verify_live_current_host_generation_only()?",
            "restore_pinned_current_virtual_display_mode_after_host_restart()?",
            "verify_live_current_host()? != generation",
        ], in: restore)

        let restart = try functionBody(
            controller,
            beginningWith: "fn restart_exact_current_host(",
            endingBefore: "fn stop_current_host_for_rollback("
        )
        assertOrdered([
            #"&["bootstrap", &domain, HOST_PLIST]"#,
            "verify_live_current_host_generation_only()",
            "restore_pinned_current_virtual_display_mode_after_host_restart()?",
            "verify_live_current_host()? != generation",
        ], in: restart)

        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        XCTAssertTrue(rollback.contains("restart_or_recover_exact_current_host(initial)?"))
        XCTAssertTrue(rollback.contains("restore_and_verify_live_current_host()?"))
        let idempotentRestart = try functionBody(
            controller,
            beginningWith: "fn restart_or_recover_exact_current_host(",
            endingBefore: "fn stop_current_host_for_rollback("
        )
        assertOrdered([
            "verify_live_current_host_generation_only()",
            "replacement_current_host_generation_is_exact(initial, &generation)",
            "restore_pinned_current_virtual_display_mode_after_host_restart()?",
            "verify_live_current_host()? != generation",
            "service_absent && process_absent",
            "restart_exact_current_host(initial)",
        ], in: idempotentRestart)
        for function in ["repair_committed_terminal_state", "repair_rolled_back_terminal_state"] {
            let body = try functionBody(
                controller,
                beginningWith: "fn \(function)(",
                endingBefore: function == "repair_committed_terminal_state"
                    ? "fn repair_rolled_back_terminal_state("
                    : "fn report_prestop_aborted_terminal("
            )
            assertOrdered([
                "restore_and_verify_live_current_host()?", "verify_pairing_metadata_only()?",
            ], in: body)
        }
    }

    func testLauncherHasFreshV3PinsAndPureSelfTestOnly() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let sourcePin = shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: launcher)
        let binaryPin = shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: launcher)
        XCTAssertEqual(shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher), "PINNED_FINAL_REVIEW")
        XCTAssertEqual(sourcePin, sha256Hex(controller))
        XCTAssertEqual(sourcePin?.count, 64)
        XCTAssertEqual(binaryPin?.count, 64)
        XCTAssertNotEqual(sourcePin, "4df37ebcb2634ea1fed78165cc530ea8cb739fe1e9b59744010e2b64b922c98b")
        XCTAssertNotEqual(binaryPin, "da55bc73f7143ffe6f09516c84c70532c18d37af53da0e12c00fb79924926201")
        XCTAssertTrue(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v3"))
        XCTAssertFalse(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v2"))
    }

    func testPureControllerSelfTestPassesWithoutLiveModes() throws {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent(launcherPath)
        process.arguments = ["--self-test-diagnostic-driver-v3-update"]
        process.currentDirectoryURL = repositoryRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertEqual(output, "DIAGNOSTIC_DRIVER_V3_SELF_TEST_OK tests=112\n")
        XCTAssertEqual(error, "")
    }
}
