import CryptoKit
import Foundation
import XCTest

final class DiagnosticDriverV1UpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let controllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v1-update-controller.rs"
    private let launcherPath = "macOS/scripts/update-opensteamer-diagnostic-driver-v1.sh"

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

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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

    func testNamespacesAreFreshDisjointAndModesAreNarrow() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        for token in [
            #"const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v1-update-preflight";"#,
            #"const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v1-update";"#,
            #"const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v1-update";"#,
            #"const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v1-update";"#,
            #"const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v1-update";"#,
            #"const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v1-update";"#,
            #"const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v1-update";"#,
            #"const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V1";"#,
            #"const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V1";"#,
            "/Users/ahmed/Library/Application Support/opensteamer/diagnostic-driver-updates-v1",
            "/Users/ahmed/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1",
            "/Library/Application Support/opensteamer/diagnostic-driver-updates-v1",
            "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1",
            "/Library/Application Support/opensteamer/active-diagnostic-driver-update-v1.pending",
            "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1",
            "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v1/recovery-controller",
            "/Library/Application Support/opensteamer/diagnostic-driver-bootstrap-v1.txt",
            "/Library/Application Support/opensteamer/diagnostic-driver-probes-v1",
            "const ROOT_PRIVATE_MODE: u32 = 0o700;",
            "const ROOT_SEALED_TRAVERSE_MODE: u32 = 0o711;",
            "const ROOT_SEALED_EXECUTABLE_MODE: u32 = 0o555;",
            "const ROOT_SEALED_RECORD_MODE: u32 = 0o444;",
        ] {
            XCTAssertTrue(controller.contains(token), "missing exact namespace/mode: \(token)")
        }
        for mode in [
            "--verify-diagnostic-driver-v1-update-preflight",
            "--execute-authorized-diagnostic-driver-v1-update",
            "--rollback-authorized-diagnostic-driver-v1-update",
            "--self-test-diagnostic-driver-v1-update",
        ] {
            XCTAssertTrue(launcher.contains(mode), "launcher omits public mode: \(mode)")
        }
        XCTAssertFalse(launcher.contains("--root-authorized-diagnostic-driver-v1-update"))
        XCTAssertFalse(launcher.contains("--root-rollback-diagnostic-driver-v1-update"))
        XCTAssertTrue(launcher.contains("--root-sealed-rollback-diagnostic-driver-v1-update"))
        XCTAssertTrue(controller.contains("Path::new(ROOT_PROBE_PARENT).starts_with(ROOT_UPDATE_ROOT)"))
        XCTAssertTrue(controller.contains("Path::new(ROOT_CONTROLLER_PARENT).starts_with(ROOT_UPDATE_ROOT)"))
    }

    func testExactCandidateV8AndInstalledV7PinsAreFrozen() throws {
        let controller = try source(controllerPath)
        for pin in [
            "fe05e4f8f1e80b143af5a4b0e366160e52a1e14e",
            "cafe008bf0b645014aaabefe4c50246595aa2378",
            "955c73ee07ee71b666c2200b273a5f285da493538aaa37062575c4510790dc3e",
            "56354cb2ff7c02f33fdaa552965ee7eee916152a86f353f718834aae6a80b5af",
            "10ce8ca0e798215b593400095e80c931ca9c1fa055e79551ad6c940beb0bcba2",
            "f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49",
            "ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866",
            "c37c82d8d4e62e387aadc556d0073fad80c752d96040bc2215e6088d8620c93a",
            "84bfc68a9bf808936e60c80dbd8a02f601f54fe248c3f1f8de0b095142401dba",
            "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d",
            "9f801306c944d2ea021fd1e65650714dd3c0c788e3b521dc927875dd9c3f004d",
            "6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded",
            "b344eb24cde4ab1881b065e2ef0aa208aef12dbdd31fea7259eabc5ad5b6abaf",
        ] {
            XCTAssertTrue(controller.contains(pin), "missing exact baseline pin: \(pin)")
        }
        for identity in [
            "paired-v8-update-1787440868-72401-446ca31d-a524-4c6f-a19c-f207e96d6eb9",
            "com.elamin.opensteamer.VirtualMicrophoneDriver",
            "com.elamin.opensteamer.virtual-microphone.input",
            "com.elamin.opensteamer.virtual-microphone.writer",
            "const INSTALLED_DRIVER_DEVICE: u64 = 16_777_229;",
            "const INSTALLED_DRIVER_INODE: u64 = 27_877_539;",
        ] {
            XCTAssertTrue(controller.contains(identity), "missing installed identity: \(identity)")
        }
    }

    func testAuthorizationBindsFreshPushedMainWhileCandidateProvenanceStaysFe05() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let provenance = try functionBody(
            controller,
            beginningWith: "fn verify_git_provenance(",
            endingBefore: "fn verify_reader_inputs("
        )
        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        XCTAssertTrue(launcher.contains("<authorized-updater-release-commit> <authorized-updater-release-tree>"))
        XCTAssertFalse(launcher.contains("$EXPECTED_REPO fe05e4f8f1e80b143af5a4b0e366160e52a1e14e"))
        for token in [
            #"&format!("{EXPECTED_SOURCE_COMMIT}^{{tree}}")"#,
            "candidate_tree != EXPECTED_SOURCE_TREE",
            #"branch != "main""#,
            #""ls-remote""#,
            "remote != format!(\"{commit}\\t{remote_ref}\")",
        ] {
            XCTAssertTrue(provenance.contains(token), "missing pushed-release proof: \(token)")
        }
        assertOrdered(
            [
                "verify_complete_preflight(repo, true)?",
                "commit != authorized_commit || tree != authorized_tree",
                "stage_root_owned_controller(",
                "verify_complete_preflight(repo, false)?",
                "final_commit != commit || final_tree != tree || final_host != initial",
                "run_sudo_helper(&root_controller, ROOT_MODE, Some(&root_bootstrap_request))?",
            ],
            in: execute
        )
    }

    func testPreflightIsReadOnlyAndDoesNotCreateEvidence() throws {
        let controller = try source(controllerPath)
        let complete = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        let preflight = try functionBody(
            controller,
            beginningWith: "fn preflight(",
            endingBefore: "fn build_diagnostic_reader("
        )
        assertOrdered(
            [
                "canonical_repo(repo)?",
                "verify_git_provenance(&repo)?",
                "verify_candidate()?",
                "verify_installed_v7_driver()?",
                "verify_live_v8_host()?",
                "verify_pairing_metadata_only()?",
                "verify_reader_inputs(&repo)?",
                "require_fresh_namespaces()?",
            ],
            in: complete
        )
        for forbidden in [
            "create_user_layout", "ensure_root_update_layout", "write_new_private",
            "stage_root_owned_controller", "sudo_fixed", "run_sudo_helper",
            "stop_exact_v8_host", "reload_coreaudio_exact", "publish_candidate_driver",
        ] {
            XCTAssertFalse(complete.contains(forbidden), "preflight calls mutator: \(forbidden)")
            XCTAssertFalse(preflight.contains(forbidden), "public preflight calls mutator: \(forbidden)")
        }
        XCTAssertTrue(preflight.contains("stable_coreaudio_generation()?"))
        XCTAssertTrue(preflight.contains("DIAGNOSTIC_DRIVER_V1_PREFLIGHT_OK"))
    }

    func testNoInstallerRouteSetterPhoneOrPairingSecretSurface() throws {
        let controller = try source(controllerPath)
        for forbidden in [
            "AudioObjectSetPropertyData", "AudioDeviceSetProperty", "/usr/sbin/installer",
            "default-route-guardian", "public-vpio", "SwitchAudioSource", "devicectl",
            "simctl", "MobileDevice", "TestFlight", "delete-generic-password",
            "add-generic-password", "dump-keychain",
        ] {
            XCTAssertFalse(controller.contains(forbidden), "forbidden mutation surface: \(forbidden)")
        }
        let pairing = try functionBody(
            controller,
            beginningWith: "fn verify_pairing_metadata_only(",
            endingBefore: "fn process_start("
        )
        let nullRunner = try functionBody(
            controller,
            beginningWith: "fn bounded_null_status(",
            endingBefore: "fn require_success("
        )
        for token in [
            #""/usr/bin/security""#,
            #""find-generic-password""#,
            #""-s""#,
            "PAIRING_SERVICE",
            #""-a""#,
            "account",
            "bounded_null_status(",
        ] {
            XCTAssertTrue(pairing.contains(token), "missing metadata-only proof: \(token)")
        }
        XCTAssertFalse(pairing.contains(#""-w""#))
        XCTAssertFalse(pairing.contains(#""-g""#))
        assertOrdered(
            [
                ".stdin(Stdio::null())",
                ".stdout(Stdio::null())",
                ".stderr(Stdio::null())",
            ],
            in: nullRunner
        )
        XCTAssertFalse(controller.contains("--reset-worldwide-pairing"))
        XCTAssertTrue(controller.contains("const HOST_ARGUMENTS: [&str; 7]"))
        for exactArgument in [
            #""--worldwide""#, #""--allow-remote-control""#, #""--duration""#,
            #""0""#, #""--verbose""#, #""--rendezvous-url""#,
        ] {
            XCTAssertTrue(controller.contains(exactArgument))
        }
    }

    func testDefaultRoutesAreReadOnlyStableInvariants() throws {
        let controller = try source(controllerPath)
        let routeReader = try functionBody(
            controller,
            beginningWith: "fn audio_default_device(",
            endingBefore: "fn read_coreaudio_generation("
        )
        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        let rollbackRoute = try functionBody(
            controller,
            beginningWith: "fn rollback_routes_match(",
            endingBefore: "fn finalize_prestop_preserving_host("
        )
        let recovery = try functionBody(
            controller,
            beginningWith: "fn complete_root_recovery(",
            endingBefore: "fn read_root_active_layout("
        )
        XCTAssertTrue(routeReader.contains("AudioObjectGetPropertyData"))
        XCTAssertFalse(routeReader.contains("SetProperty"))
        XCTAssertTrue(routeReader.contains("let first = capture_route_snapshot()?;"))
        XCTAssertTrue(routeReader.contains("let second = capture_route_snapshot()?;"))
        XCTAssertTrue(routeReader.contains("if first != second"))
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "stable_route_snapshot()? != baseline_route", in: transaction),
            3
        )
        XCTAssertFalse(transaction.contains("VPIO_PROBE"))
        XCTAssertFalse(transaction.contains("DEFAULT_ROUTE_GUARDIAN"))
        XCTAssertTrue(rollbackRoute.contains("baseline.is_some_and"))
        XCTAssertTrue(rollbackRoute.contains("stable_route_snapshot().is_ok_and"))
        XCTAssertFalse(rollbackRoute.contains("stable_route_snapshot()?"))
        assertOrdered(
            [
                "let route_status = if outcome.routes_unchanged",
                #""unchanged""#,
                #""drifted""#,
                "write_root_recovery_result(",
                "routes={route_status}",
            ],
            in: recovery
        )
        XCTAssertFalse(recovery.contains("routes=unchanged legacy=protected\","))
    }

    func testRootOwnedControllerIsSealedBeforeEitherSudoHelperMode() throws {
        let controller = try source(controllerPath)
        let staging = try functionBody(
            controller,
            beginningWith: "fn stage_root_owned_controller(",
            endingBefore: "fn verify_root_controller_identity("
        )
        let identity = try functionBody(
            controller,
            beginningWith: "fn verify_root_controller_identity(",
            endingBefore: "fn verify_fixed_root_recovery_controller("
        )
        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn complete_root_recovery("
        )
        let retiredMutableRollback = try functionBody(
            controller,
            beginningWith: "fn root_rollback_authorized_update(",
            endingBefore: "fn require_pointerless_partial_root_layout("
        )
        assertOrdered(
            [
                "root_directory_identity(Path::new(ROOT_SUPPORT), 0o755)?",
                "Path::new(ROOT_BOOTSTRAP_LOCATOR)",
                "bootstrap_request_bytes",
                #""0711""#,
                "root_directory_identity(Path::new(ROOT_CONTROLLER_PARENT), ROOT_SEALED_TRAVERSE_MODE)?",
                "root_directory_identity(&support, ROOT_SEALED_TRAVERSE_MODE)?",
                "Path::new(ROOT_RECOVERY_CONTROLLER)",
                "Path::new(ROOT_RECOVERY_CONTROLLER_PIN)",
                "&controller",
                "sha256(&controller)? != digest || sha256(&controller)? != digest",
                "ROOT_SEALED_RECORD_MODE",
                "require_sealed_regular(\n        Path::new(ROOT_RECOVERY_CONTROLLER),",
                "require_sealed_regular(Path::new(ROOT_BOOTSTRAP_LOCATOR), ROOT_SEALED_RECORD_MODE)?",
                "require_root_directory_identity(Path::new(ROOT_SUPPORT)",
            ],
            in: staging
        )
        for token in [
            "geteuid() } != ROOT_ID",
            #"env::var("SUDO_UID").ok().as_deref() != Some("501")"#,
            #"env::var("SUDO_GID").ok().as_deref() != Some("20")"#,
            #"env::var("SUDO_USER").ok().as_deref() != Some("ahmed")"#,
            "env::current_exe()? != request.root_controller",
            "require_sealed_regular(&request.root_controller, ROOT_SEALED_EXECUTABLE_MODE)?",
            "sha256(&request.root_controller)? != request.controller_sha256",
            #""bootstrap-request.txt""#,
        ] {
            XCTAssertTrue(identity.contains(token), "missing root identity proof: \(token)")
        }
        XCTAssertTrue(execute.contains("run_sudo_helper(&root_controller, ROOT_MODE, Some(&root_bootstrap_request))?"))
        XCTAssertTrue(rollback.contains("Path::new(ROOT_RECOVERY_CONTROLLER)"))
        XCTAssertTrue(rollback.contains("ROOT_SEALED_ROLLBACK_MODE"))
        XCTAssertTrue(rollback.contains("run_sudo_helper("))
        XCTAssertTrue(retiredMutableRollback.contains("mutable user-request rollback is retired"))
        XCTAssertFalse(retiredMutableRollback.contains("run_sudo_helper("))
        XCTAssertFalse(execute.contains("run_sudo_helper(&controller_source"))
        XCTAssertFalse(execute.contains("run_sudo_helper(&layout.reader"))
    }

    func testFixedRecoveryEntrypointIsSealedAndRunsBeforeToolchainChecks() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let recovery = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn require_self_test_rejection<"
        )
        let fixedIdentity = try functionBody(
            controller,
            beginningWith: "fn verify_fixed_root_recovery_controller(",
            endingBefore: "fn run_sudo_helper("
        )
        let launcherRecovery = try functionBody(
            launcher,
            beginningWith: #"if [ "$MODE" = "$ROLLBACK_MODE" ]; then"#,
            endingBefore: #"[ -f "$SOURCE" ]"#
        )
        assertOrdered(
            [
                "verify_fixed_root_recovery_controller()?",
                "acquire_root_update_lock()?",
                "ROOT_BOOTSTRAP_LOCATOR",
                "reconcile_root_pointer_for_recovery(&locator_request)?",
                "finalize_sealed_bootstrap_without_root_pointer(&fixed_digest)",
                "parse_sealed_root_request(&layout.recovery_request)?",
                "verify_sealed_transaction_controller(&request)?",
                "verify_root_bootstrap_locator(&request)?",
                "capture_root_transaction_ancestry(",
                "revalidate_root_transaction_ancestry(&ancestry)?",
                "complete_root_recovery(request, layout)",
            ],
            in: recovery
        )
        for token in [
            "env::current_exe()? != Path::new(ROOT_RECOVERY_CONTROLLER)",
            "require_sealed_directory(Path::new(ROOT_CONTROLLER_PARENT), ROOT_SEALED_TRAVERSE_MODE)?",
            "ROOT_SEALED_EXECUTABLE_MODE",
            "ROOT_SEALED_RECORD_MODE",
            "sha256(Path::new(ROOT_RECOVERY_CONTROLLER))? != digest",
        ] {
            XCTAssertTrue(fixedIdentity.contains(token), "fixed recovery identity omits \(token)")
        }
        assertOrdered(
            [
                "0:0:755", "0:0:711", "0:0:1:555", "0:0:1:444",
                #"/bin/ls -lde@ "$SEALED_NODE""#,
                #"/usr/bin/xattr "$SEALED_NODE""#,
                #"/usr/bin/sudo -n -- "$ROOT_RECOVERY_CONTROLLER" "$ROOT_SEALED_ROLLBACK_MODE""#,
            ],
            in: launcherRecovery
        )
        XCTAssertFalse(launcherRecovery.contains("$SOURCE"))
        XCTAssertFalse(launcherRecovery.contains("$RUSTC"))
        XCTAssertFalse(launcherRecovery.contains("compile_controller"))
        XCTAssertFalse(launcherRecovery.contains("$USER_ACTIVE_POINTER/root-request.txt"))
    }

    func testPartialBootstrapAndAtomicRootPointerRecoveryPreserveHost() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let pointerModel = try functionBody(
            controller,
            beginningWith: "fn classify_root_pointer_bytes(",
            endingBefore: "fn write_root_state("
        )
        let pointerless = try functionBody(
            controller,
            beginningWith: "fn require_pointerless_partial_root_layout(",
            endingBefore: "fn root_sealed_rollback_authorized_update("
        )
        let launcherRecovery = try functionBody(
            launcher,
            beginningWith: #"if [ "$MODE" = "$ROLLBACK_MODE" ]; then"#,
            endingBefore: #"[ -f "$SOURCE" ]"#
        )
        for token in [
            "Some(bytes) if bytes == expected", "Some(bytes) if expected.starts_with(bytes)",
            "root active-pointer image is not an exact crash prefix",
            "RootPointerImage::Complete, RootPointerImage::Absent",
            "RootPointerImage::Absent, RootPointerImage::Complete",
            "RootPointerRecoveryAction::PreserveHost",
            "write_new_private(pending, &bytes, ROOT_ID, ROOT_ID, 0o600)?",
            "rename_exclusive(pending, canonical)?", "fsync_parent(canonical)?",
        ] {
            XCTAssertTrue(pointerModel.contains(token), "root pointer model omits \(token)")
        }
        assertOrdered(
            [
                "verify_installed_v7_driver()?", "require_legacy_disabled_and_absent()?",
                "verify_live_v8_host()?", "verify_pairing_metadata_only()?",
                "require_pointerless_partial_root_layout(&layout, &request)?",
                "UpdateState::PrestopAborted", "write_root_recovery_result(",
                #""sealed-bootstrap-finalized-before-root-pointer""#,
                #""bootstrap-abort-result.txt""#,
            ],
            in: pointerless
        )
        for forbidden in [
            "stop_exact_v8_host", "stop_v8_host_for_rollback", "reload_coreaudio_exact",
            "publish_candidate_driver", "rename_exclusive(canonical",
        ] {
            XCTAssertFalse(pointerless.contains(forbidden), "pointerless pre-stop recovery mutates runtime: \(forbidden)")
        }
        for token in [
            #"[ ! -e "$ROOT_ACTIVE_POINTER" ]"#, "LOCATOR_READY=0", "FIXED_READY=0",
            "0:0:1:400", "0:0:1:444", "0:0:1:500", "0:0:1:555",
            "DIAGNOSTIC_DRIVER_V1_BOOTSTRAP_INCOMPLETE_HOST_PRESERVED root_pointer=absent",
            "exit 75",
        ] {
            XCTAssertTrue(launcherRecovery.contains(token), "launcher partial-bootstrap guard omits \(token)")
        }
        XCTAssertTrue(controller.contains("atomic root-pointer recovery matrix failed"))
        XCTAssertTrue(controller.contains("root pointer unrelated bytes"))
        XCTAssertTrue(controller.contains("complete root pointer with partial pending image"))
    }

    func testUserWritableInputsCrossPrivilegeBoundaryAsPinnedBytesOnly() throws {
        let controller = try source(controllerPath)
        let bounded = try functionBody(
            controller,
            beginningWith: "fn bounded_output_in_directory(",
            endingBefore: "fn bounded_null_status("
        )
        let helper = try functionBody(
            controller,
            beginningWith: "fn uid501_openat_read_helper(",
            endingBefore: "fn read_uid501_openat_bytes("
        )
        let pinnedRead = try functionBody(
            controller,
            beginningWith: "fn read_uid501_openat_bytes(",
            endingBefore: "fn openat_child("
        )
        let rootStream = try functionBody(
            controller,
            beginningWith: "fn sudo_stream_root_file(",
            endingBefore: "fn stage_root_owned_controller("
        )
        let staging = try functionBody(
            controller,
            beginningWith: "fn stage_root_owned_controller(",
            endingBefore: "fn verify_root_controller_identity("
        )
        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered(
            [
                "openat_component_walk(path)?",
                "let before = file.metadata()?",
                "read_to_end(&mut bytes)?",
                "let after = file.metadata()?",
                "openat_component_walk(path)?",
                "before_ancestry != after_ancestry",
                "sha256_bytes(&bytes)",
            ],
            in: helper
        )
        assertOrdered(
            ["fchdir(directory_descriptor)", "setgroups(", "setgid(USER_GROUP)", "setuid(USER_ID)"],
            in: bounded
        )
        XCTAssertTrue(bounded.contains(".env_clear()"))
        XCTAssertTrue(pinnedRead.contains("env::current_exe()?"))
        XCTAssertTrue(pinnedRead.contains("UID501_PINNED_READ_MODE"))
        XCTAssertTrue(pinnedRead.contains("UID501_GENERATED_READ_MODE"))
        XCTAssertTrue(pinnedRead.contains("bounded_output(path_text(&executable)?, &arguments, COMMAND_TIMEOUT, true)?"))
        XCTAssertFalse(helper.contains("/bin/cat"))
        XCTAssertFalse(helper.contains("/usr/bin/stat"))
        XCTAssertFalse(pinnedRead.contains("/bin/cat"))
        XCTAssertFalse(pinnedRead.contains("/usr/bin/stat"))
        XCTAssertTrue(rootStream.contains("bytes.len() > 16 * 1_048_576"))
        XCTAssertTrue(rootStream.contains(#".args(["-n", "--", "/usr/bin/tee", path_text(destination)?])"#))
        XCTAssertTrue(rootStream.contains("stdin.write_all(bytes)?"))
        XCTAssertTrue(rootStream.contains("sudo_root_sha256(destination)? != expected"))
        XCTAssertTrue(rootStream.contains("require_sealed_regular(destination, published_mode)?"))
        XCTAssertTrue(staging.contains("controller_bytes: &[u8]"))
        XCTAssertTrue(staging.contains("bootstrap_request_bytes: &[u8]"))
        XCTAssertFalse(staging.contains("path_text(source)"))
        XCTAssertTrue(controller.contains("read_uid501_openat_bytes(&source.join(relative)"))
        XCTAssertTrue(rootTransaction.contains("parse_bootstrap_root_request(request_path)?"))
        XCTAssertFalse(rootTransaction.contains("parse_root_request(request_path)"))
        XCTAssertFalse(rootTransaction.contains("verify_user_request_evidence"))
    }

    func testACLXattrAncestryAndNativeJSONGatesCoverPrivilegedArtifacts() throws {
        let controller = try source(controllerPath)
        let extendedMetadata = try functionBody(
            controller,
            beginningWith: "fn require_no_acl_or_xattrs(",
            endingBefore: "fn require_sealed_regular("
        )
        let ancestry = try functionBody(
            controller,
            beginningWith: "fn capture_root_transaction_ancestry(",
            endingBefore: "fn revalidate_root_transaction_ancestry("
        )
        let snapshot = try functionBody(
            controller,
            beginningWith: "fn read_passive_snapshot(",
            endingBefore: "fn verify_mirror_loopback_result("
        )
        let mirror = try functionBody(
            controller,
            beginningWith: "fn verify_mirror_loopback_result(",
            endingBefore: "fn restart_exact_v8_host("
        )
        for token in [
            #"&["-lde@", path_text(path)?]"#,
            "lines.len() != 1",
            "ls_mode_has_forbidden_extended_metadata(mode)",
            #""/usr/bin/xattr""#,
            "!xattrs.stdout.is_empty() || !xattrs.stderr.is_empty()",
        ] {
            XCTAssertTrue(extendedMetadata.contains(token), "ACL/xattr gate omits \(token)")
        }
        for token in [
            "PathBuf::from(ROOT_SUPPORT)", "PathBuf::from(ROOT_CONTROLLER_PARENT)",
            "controller_support.to_path_buf()", "PathBuf::from(ROOT_UPDATE_ROOT)",
            "layout.root.clone()", "PathBuf::from(ROOT_PROBE_PARENT)",
            "root_directory_identity(&path, mode)?", "identity.device != support_device",
        ] {
            XCTAssertTrue(ancestry.contains(token), "root ancestry seal omits \(token)")
        }
        XCTAssertTrue(controller.contains("ROOT_ANCESTRY_ACL_XATTR_SEAL"))
        XCTAssertTrue(controller.contains("BOUNDED_NATIVE_JSON_VALIDATOR"))
        XCTAssertTrue(controller.contains("if depth > 32 || self.nodes > 16_384"))
        XCTAssertTrue(controller.contains("JSON object key is duplicated"))
        XCTAssertTrue(snapshot.contains("validate_passive_snapshot_json(reader_text.as_bytes())"))
        XCTAssertTrue(mirror.contains("validate_mirror_loopback_json(bytes)"))
        XCTAssertFalse(controller.contains("/usr/bin/python3"))
        XCTAssertFalse(controller.contains("PYTHONPATH"))
        XCTAssertTrue(controller.contains("POSIX_ACL_FORBIDDEN"))
    }

    func testStrictHostCoreAudioAndLockOwnershipIdentitiesAreBracketed() throws {
        let controller = try source(controllerPath)
        let hostParser = try functionBody(
            controller,
            beginningWith: "fn parse_host_launch_state(",
            endingBefore: "fn read_host_launch_state("
        )
        let soloHost = try functionBody(
            controller,
            beginningWith: "fn require_solo_v8_host(",
            endingBefore: "fn read_generation_lock("
        )
        let coreAudio = try functionBody(
            controller,
            beginningWith: "fn read_coreaudio_generation(",
            endingBefore: "fn stable_coreaudio_generation("
        )
        let lockProof = try functionBody(
            controller,
            beginningWith: "fn prove_lock_held_by_local(",
            endingBefore: "fn prove_lock_held_by("
        )
        let lsofMetadata = try functionBody(
            controller,
            beginningWith: "fn require_pinned_lsof_metadata(",
            endingBefore: "fn require_pinned_lsof("
        )
        let lsofProof = try functionBody(
            controller,
            beginningWith: "fn require_pinned_lsof(",
            endingBefore: "fn lock_openers("
        )
        for token in [
            "path.as_deref() != Some(HOST_PLIST)", #"job_type.as_deref() != Some("LaunchAgent")"#,
            #"state.as_deref() != Some("running")"#, "program.as_deref() != Some(HOST_EXECUTABLE)",
            "arguments != expected_arguments",
        ] {
            XCTAssertTrue(hostParser.contains(token), "host parser omits \(token)")
        }
        for token in [
            "processes.len() != 1", "processes[0].1 != USER_ID",
            "processes[0].2 != HOST_EXECUTABLE", #"fields[1] != "1""#,
            "fields[3] != USER_GROUP.to_string()", "fields[4..].join(\" \") != expected_command",
        ] {
            XCTAssertTrue(soloHost.contains(token), "solo-host proof omits \(token)")
        }
        XCTAssertTrue(coreAudio.contains(#"[pid_text.as_str(), "1", "202", "202", "/usr/sbin/coreaudiod"]"#))
        XCTAssertTrue(coreAudio.contains(#"&["-x", "coreaudiod"]"#))
        XCTAssertTrue(coreAudio.contains("pgrep != pid_text"))
        XCTAssertEqual(occurrences(of: "lock_openers()?", in: lockProof), 2)
        XCTAssertEqual(occurrences(of: "require_expected_lock_contention(&file)?", in: lockProof), 2)
        assertOrdered(
            [
                "read_generation_lock_local(pid)?", "let initial_openers = lock_openers()?",
                "open_exact_host_lock(expected_device, expected_inode)?",
                "require_expected_lock_contention(&file)?", "openat_component_walk(Path::new(HOST_LOCK))?",
                "let bracketed_openers = lock_openers()?", "exact_controller",
                "require_expected_lock_contention(&file)?", "read_generation_lock_local(pid)?",
            ],
            in: lockProof
        )
        XCTAssertTrue(controller.contains("if sha256(path)? != LSOF_SHA256"))
        XCTAssertTrue(controller.contains(#"&["-n", "-Fpcufa", "--", HOST_LOCK]"#))
        for token in [
            "metadata.uid() != ROOT_ID", "metadata.gid() != ROOT_ID", "metadata.nlink() != 1",
            "metadata.permissions().mode() & 0o7777 != 0o755", "metadata.len() != LSOF_SIZE",
            "metadata.st_flags() != LSOF_FLAGS",
        ] {
            XCTAssertTrue(lsofMetadata.contains(token), "lsof metadata proof omits \(token)")
        }
        XCTAssertTrue(controller.contains("const LSOF_SIZE: u64 = 307_600;"))
        XCTAssertTrue(controller.contains("const LSOF_FLAGS: u32 = 524_320;"))
        XCTAssertEqual(occurrences(of: "require_pinned_lsof_metadata(path)?", in: lsofProof), 2)
        assertOrdered(
            ["let before = require_pinned_lsof_metadata(path)?", "sha256(path)? != LSOF_SHA256",
             "let after = require_pinned_lsof_metadata(path)?", "before.dev() != after.dev()"],
            in: lsofProof
        )
    }

    func testFullV8HostBundleUsesDroppedUIDDescriptorManifest() throws {
        let controller = try source(controllerPath)
        let runtime = try functionBody(
            controller,
            beginningWith: "fn verify_installed_v8_runtime_bytes(",
            endingBefore: "fn verify_v8_evidence_and_host_bytes("
        )
        let walk = try functionBody(
            controller,
            beginningWith: "fn walk_host_bundle_directory(",
            endingBefore: "fn capture_uid501_host_bundle_manifest("
        )
        let capture = try functionBody(
            controller,
            beginningWith: "fn capture_uid501_host_bundle_manifest(",
            endingBefore: "fn uid501_host_bundle_manifest_helper("
        )
        let verify = try functionBody(
            controller,
            beginningWith: "fn verify_uid501_host_bundle_manifest(",
            endingBefore: "fn create_root_driver_directory("
        )
        let compareReference = try functionBody(
            controller,
            beginningWith: "fn compare_tree_metadata(",
            endingBefore: "fn code_hash("
        )
        XCTAssertTrue(runtime.contains("verify_uid501_host_bundle_manifest()?"))
        XCTAssertTrue(capture.contains("getuid() } != USER_ID || unsafe { geteuid() } != USER_ID"))
        XCTAssertTrue(capture.contains("openat_component_walk_with_final_flags(Path::new(HOST_APP), O_RDONLY | O_DIRECTORY)?"))
        XCTAssertTrue(capture.contains("OPENSTEAMER_V8_HOST_BUNDLE_FD_MANIFEST_V1"))
        XCTAssertTrue(capture.contains("walk_host_bundle_directory(&root, \".\""))
        for token in [
            "depth > 16", "*nodes > 512", "list_directory_fd(directory)?",
            "openat_child(directory, name, O_RDONLY)", "openat_child(directory, name, O_SYMLINK)",
            "descriptor_xattrs(&child)?", "readlinkat_exact(directory, name)?",
            "sha256_bytes(&bytes)?", "identity_from_metadata(&before)",
            "descriptor_xattrs(&child)? != child_xattrs_before",
            "list_directory_fd(directory)? != names_before",
        ] {
            XCTAssertTrue(walk.contains(token), "host FD walk omits \(token)")
        }
        for token in ["flistxattr(", "fgetxattr(", "fdopendir(", "readdir(", "readlinkat("] {
            XCTAssertTrue(controller.contains(token), "host manifest omits descriptor primitive \(token)")
        }
        XCTAssertTrue(verify.contains("&[UID501_HOST_MANIFEST_MODE]"))
        XCTAssertTrue(verify.contains("true,"))
        XCTAssertTrue(verify.contains("sha256_bytes(&output.stdout)? != HOST_BUNDLE_MANIFEST_SHA256"))
        XCTAssertFalse(compareReference.contains("/usr/bin/diff"))
        for token in [
            "if left_nodes != right_nodes", "for node in &left_nodes", "if node.1 != 2",
            "Path::new(OsStr::from_bytes(&node.0))", #""/usr/bin/cmp""#, #"&["-s""#,
            "require_success(&comparison, \"compare exact v8 host file\")",
            "!comparison.stdout.is_empty() || !comparison.stderr.is_empty()",
        ] {
            XCTAssertTrue(compareReference.contains(token), "host reference comparison omits \(token)")
        }
    }

    func testForwardOrderAndSameHostRestartContract() throws {
        let controller = try source(controllerPath)
        let publication = try functionBody(
            controller,
            beginningWith: "fn publish_candidate_driver(",
            endingBefore: "fn run_passive_driver_validation("
        )
        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered(
            [
                "rename_exclusive(Path::new(PRODUCT_DRIVER), &layout.prior_driver)?",
                "UpdateState::PriorDriverRetained",
                "rename_exclusive(&layout.candidate_stage, Path::new(PRODUCT_DRIVER))?",
                "UpdateState::CandidatePublished",
            ],
            in: publication
        )
        for hostArtifact in ["HOST_APP", "HOST_EXECUTABLE", "HOST_PLIST", "LEGACY_APP", "LEGACY_PLIST"] {
            XCTAssertFalse(
                publication.contains(hostArtifact),
                "driver publication can address protected host artifact: \(hostArtifact)"
            )
        }
        assertOrdered(
            [
                "UpdateState::HostStopInitiated", "stop_exact_v8_host(&initial)?",
                "UpdateState::HostStopped", "publish_candidate_driver(&layout, &mut journal)?",
                "reload_coreaudio_exact(&baseline_coreaudio)?", "UpdateState::CoreAudioReloaded",
                "run_passive_driver_validation(&reader, &both_order, &request)?",
                "UpdateState::DriverValidated", "restart_exact_v8_host(&initial)?",
                "UpdateState::HostBootstrapped", "verify_pairing_metadata_only()?",
                "UpdateState::ReadyVerified", "UpdateState::Committed",
            ],
            in: transaction
        )
        let restart = try functionBody(
            controller,
            beginningWith: "fn restart_exact_v8_host(",
            endingBefore: "fn stop_v8_host_for_rollback("
        )
        XCTAssertTrue(restart.contains(#"&["bootstrap", &domain, HOST_PLIST]"#))
        XCTAssertTrue(restart.contains("verify_installed_v8_runtime_bytes()?"))
        XCTAssertTrue(restart.contains("generation.runs == 1"))
        for mutator in ["fs::rename", "fs::copy", "fs::remove", "/usr/bin/ditto", "/usr/bin/install"] {
            XCTAssertFalse(restart.contains(mutator), "host restart mutates host artifact")
        }
    }

    func testCoreAudioReplacementIsBaselineBoundExactlyOneAndAllowsSameSecond() throws {
        let controller = try source(controllerPath)
        let successor = try functionBody(
            controller,
            beginningWith: "fn coreaudio_restart_successor_is_exact(",
            endingBefore: "fn reload_coreaudio_exact("
        )
        let reload = try functionBody(
            controller,
            beginningWith: "fn reload_coreaudio_exact(",
            endingBefore: "fn canonical_repo("
        )
        assertOrdered(
            [
                "capture_server_processes()?.is_empty()", "let before = stable_coreaudio_generation()?",
                "if &before != expected",
                "kill(before.pid as i32, SIGTERM)",
                "coreaudio_restart_successor_is_exact(&before, &after)",
                "read_coreaudio_generation()? != after",
            ],
            in: reload
        )
        XCTAssertFalse(reload.contains("killall"))
        XCTAssertTrue(reload.contains("after.runs > before.runs.saturating_add(1)"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "capture_server_processes()?.is_empty()", in: reload), 2)
        XCTAssertTrue(successor.contains("after.pid != before.pid"))
        XCTAssertTrue(successor.contains("after.runs == before.runs.saturating_add(1)"))
        XCTAssertFalse(successor.contains("process_start"))
        XCTAssertTrue(controller.contains("same-second exact Core Audio successor was rejected"))
    }

    func testRollbackReserveHeadroomAndZeroBlockReleaseAreDurable() throws {
        let controller = try source(controllerPath)
        let allocate = try functionBody(
            controller,
            beginningWith: "fn allocate_rollback_reserve(",
            endingBefore: "fn release_discovered_prestop_reserve("
        )
        let release = try functionBody(
            controller,
            beginningWith: "fn release_rollback_reserve(",
            endingBefore: "enum RootPointerImage"
        )
        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        XCTAssertTrue(controller.contains("zero-length rollback reserve still owns allocated blocks"))
        XCTAssertTrue(controller.contains("MINIMUM_PRESTOP_AVAILABLE_BYTES.saturating_add(ROLLBACK_RESERVE_BYTES)"))
        assertOrdered(
            [
                "available_bytes_on_transaction_filesystem(layout)?",
                "prestop_headroom_is_sufficient(before, false)",
                "create_private_file(&layout.rollback_reserve",
                "while written < ROLLBACK_RESERVE_BYTES", "file.sync_all()?",
                "rollback_reserve_released(metadata.len(), allocated)",
                "prestop_headroom_is_sufficient(after, true)",
            ],
            in: allocate
        )
        for token in [
            "before.dev() != expected.device", "file.set_len(0)?", "file.sync_all()?",
            "after.len() != 0", "after.blocks().checked_mul(512).unwrap_or(u64::MAX) != 0",
        ] {
            XCTAssertTrue(release.contains(token), "reserve release omits \(token)")
        }
        assertOrdered(
            [
                "allocate_rollback_reserve(&layout)?",
                "available_bytes_on_transaction_filesystem(&layout)?",
                "prestop_headroom_is_sufficient(available_bytes, true)",
                "write_root_state(\n        &layout,\n        UpdateState::HostStopInitiated",
                "reserve_device", "reserve_inode", "reserve_bytes",
                "stop_exact_v8_host(&initial)?",
            ],
            in: transaction
        )
        XCTAssertTrue(controller.contains("rollback reserve/headroom boundary model failed"))
    }

    func testTwoStructuralOsDSReadsAndExactV7MirrorJSON() throws {
        let controller = try source(controllerPath)
        let validation = try functionBody(
            controller,
            beginningWith: "fn run_passive_driver_validation(",
            endingBefore: "fn read_passive_snapshot("
        )
        let snapshot = try functionBody(
            controller,
            beginningWith: "fn validate_passive_snapshot_json(",
            endingBefore: "fn validate_mirror_loopback_json("
        )
        let mirror = try functionBody(
            controller,
            beginningWith: "fn validate_mirror_loopback_json(",
            endingBefore: "fn read_passive_snapshot("
        )
        XCTAssertEqual(occurrences(of: "read_passive_snapshot(", in: validation), 2)
        assertOrdered(
            [
                "osds-before-mirror.json", "run_both_order_with_root_held_result(",
                "write_new_private(&root_result", "verify_mirror_loopback_result(&result_bytes)?",
                "osds-after-mirror.json",
                "if first != second",
            ],
            in: validation
        )
        for assertion in [
            #"json_u64(object, "readerSchema")? != 1"#,
            #"json_string_is(object, "mode", "read-once")"#,
            #""read-only-virtual-driver-diagnostic-snapshot""#,
            #"json_bool_is(object, "endpointReadsCoherent", true)"#,
            #"json_u64(object, "snapshotStructSize")? != 8_608"#,
            "generation == 0",
            #"json_bool_is(object, "allDeclaredInvariantsHold", true)"#,
            #"json_bool_is(object, "timelineActive", false)"#,
            #"json_array(object, "driverClientSlots")?.is_empty()"#,
        ] {
            XCTAssertTrue(snapshot.contains(assertion), "missing osDS assertion: \(assertion)")
        }
        for assertion in [
            "opensteamer.virtual-microphone-mirror-loopback.v2",
            #"json_string_is(object, "status", "passed")"#,
            #"json_string_is(object, "mode", "real-dual-audioqueue")"#,
            #"&["visible-first", "hidden-first"]"#,
            #"json_u64(defaults, "notificationCount")? != 0"#,
            #"json_bool_is(defaults, "mutated", false)"#,
            #""hiddenEndpointNeverDefault""#, #""virtualEndpointsNeverOutputDefault""#,
            #""cleanupEvidenceComplete""#, #""failureCode""#, #""failureReasons""#,
        ] {
            XCTAssertTrue(mirror.contains(assertion), "missing v7 mirror assertion: \(assertion)")
        }
    }

    func testBothOrderResultIsUID501ProducedThenDescriptorSealedByRoot() throws {
        let controller = try source(controllerPath)
        let result = try functionBody(
            controller,
            beginningWith: "fn run_both_order_with_root_held_result(",
            endingBefore: "fn run_passive_driver_validation("
        )
        XCTAssertTrue(controller.contains("ROOT_HELD_BOTH_ORDER_RESULT"))
        assertOrdered(
            [
                "ROOT_PRIVATE_MODE", "fchown(directory.as_raw_fd(), USER_ID, USER_GROUP)",
                "bounded_output_in_directory(", #""both-order.json""#,
                "fchown(descriptor, ROOT_ID, ROOT_ID)", "fchmod(descriptor, ROOT_PRIVATE_MODE)",
                "root_directory_identity(&drop_directory, ROOT_PRIVATE_MODE)?",
                "openat(", "O_RDONLY | O_NOFOLLOW | O_CLOEXEC",
                "produced.uid() != USER_ID", "fchown(result.as_raw_fd(), ROOT_ID, ROOT_ID)",
                "fchmod(result.as_raw_fd(), 0o600)", "identity_from_metadata(&sealed_result)",
                "read_to_end(&mut bytes)?",
            ],
            in: result
        )
        XCTAssertTrue(result.contains("produced.len() > MAX_OUTPUT_BYTES as u64"))
        XCTAssertTrue(result.contains("require_no_acl_or_xattrs(&drop_directory.join(\"both-order.json\"))?"))
    }

    func testRollbackRestoresReloadsThenRebootsAndCanResume() throws {
        let controller = try source(controllerPath)
        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        assertOrdered(
            [
                "UpdateState::RollbackStarted",
                "rename_exclusive(canonical, &layout.failed_driver)?",
                "UpdateState::FailedDriverArchived",
                "rename_exclusive(&layout.prior_driver, canonical)?",
                "verify_installed_v7_driver()?",
                "UpdateState::PriorDriverRestored",
                "UpdateState::RollbackCoreAudioReloadInitiated",
                "old_pid", "old_runs",
                "exact_fields_for_state(UpdateState::RollbackCoreAudioReloadInitiated)?",
                "reload_coreaudio_exact(&current)?.1",
                "UpdateState::RollbackCoreAudioReloaded",
                "restart_exact_v8_host(initial)?",
                "UpdateState::HostRebootstrapped",
                "UpdateState::RolledBack",
            ],
            in: rollback
        )
        XCTAssertTrue(rollback.contains("RollbackResumeAction::FinalizePreservingHost"))
        XCTAssertTrue(rollback.contains("RollbackResumeAction::AlreadyComplete"))
        XCTAssertTrue(rollback.contains("RollbackResumeAction::Refuse"))
        XCTAssertTrue(rollback.contains("current.pid != old_pid && current.runs == old_runs.saturating_add(1)"))
        XCTAssertTrue(rollback.contains("rollback_routes_match(baseline_route)"))
    }

    func testJournalAtomicStateAndTerminalFailureCoherence() throws {
        let controller = try source(controllerPath)
        let transitions = try functionBody(
            controller,
            beginningWith: "fn valid_transition(",
            endingBefore: "impl Journal {"
        )
        let journal = try functionBody(
            controller,
            beginningWith: "impl Journal {",
            endingBefore: "fn create_user_layout("
        )
        let parser = try functionBody(
            controller,
            beginningWith: "fn parse_journal_text(",
            endingBefore: "impl Journal {"
        )
        let stateWriter = try functionBody(
            controller,
            beginningWith: "fn write_root_state(",
            endingBefore: "fn parse_root_state("
        )
        let failure = try functionBody(
            controller,
            beginningWith: "fn journal_rollback_failure(",
            endingBefore: "enum RollbackResumeAction"
        )
        XCTAssertFalse(transitions.contains("(_, CriticalFailure)"))
        XCTAssertFalse(transitions.contains("(Committed, CriticalFailure)"))
        XCTAssertFalse(transitions.contains("(RolledBack, CriticalFailure)"))
        for token in [
            "self.reconcile()?", "require_absent(&pending", "write_new_private(&pending",
            "fs::rename(&pending, &self.path)?", "fsync_parent(&self.path)?",
            "classify_pending_journal_snapshot(", "PendingJournalAction::Discard",
            "PendingJournalAction::Promote", "fn effective_state_with_pending",
        ] {
            XCTAssertTrue(journal.contains(token), "journal lacks gate: \(token)")
        }
        for token in [
            "validate_journal_fields(header, parsed, &fields)?",
            "valid_transition(previous, parsed)",
            "journal does not begin at BEGUN",
            "journal header/termination changed",
            "journal field is empty or duplicated",
        ] {
            XCTAssertTrue(parser.contains(token), "journal parser lacks gate: \(token)")
        }
        assertOrdered(
            [
                #"format!(".state-{}.pending", state.token())"#,
                "create_private_file(&pending, ROOT_ID, ROOT_ID, 0o600)?",
                "file.sync_all()?", "fs::rename(&pending, &layout.state)?",
                "fsync_parent(&layout.state)?",
                "read_bounded_utf8(&layout.state, 8_192)? != bytes",
            ],
            in: stateWriter
        )
        XCTAssertTrue(failure.contains("UpdateState::Committed"))
        XCTAssertTrue(failure.contains("UpdateState::RolledBack"))
        XCTAssertTrue(failure.contains("UpdateState::PrestopAborted"))
        XCTAssertTrue(failure.contains("journal.record(UpdateState::CriticalFailure, &[]).is_err()"))
        XCTAssertTrue(failure.contains("Never publish a state image that is ahead of the durable journal"))
        XCTAssertTrue(failure.contains("critical_failure_state_publication_is_authorized("))
        XCTAssertTrue(failure.contains("return"))
    }

    func testEffectivePendingStateDrivesPrestopAndTerminalRecoveryPlans() throws {
        let controller = try source(controllerPath)
        let plan = try functionBody(
            controller,
            beginningWith: "fn root_recovery_plan(",
            endingBefore: "struct RollbackOutcome"
        )
        let prestop = try functionBody(
            controller,
            beginningWith: "fn finalize_prestop_preserving_host(",
            endingBefore: "fn repair_committed_terminal_state("
        )
        let recovery = try functionBody(
            controller,
            beginningWith: "fn complete_root_recovery(",
            endingBefore: "fn read_root_active_layout("
        )
        for token in [
            "(Begun, None)", "(Authenticated, Some(Authenticated))",
            "(Authenticated, Some(HostStopInitiated)) => ResumeRollback",
            "(Committed, Some(ReadyVerified)) => RepairCommittedState",
            "(Committed, Some(Committed)) => ReportCommitted",
            "(RolledBack, Some(HostRebootstrapped)) => RepairRolledBackState",
            "(PrestopAborted, Some(PrestopAborted)) => ReportPrestopAborted",
            "_ => Reject",
        ] {
            XCTAssertTrue(plan.contains(token), "root recovery plan omits \(token)")
        }
        assertOrdered(
            [
                "Journal::open(", "parse_optional_root_state(&layout)?",
                "journal.effective_state_with_pending()?",
                "root_recovery_plan(effective_journal",
                "RootRecoveryPlan::PrestopPreserveHost",
                "RootRecoveryPlan::RepairCommittedState",
                "RootRecoveryPlan::RepairRolledBackState",
                "RootRecoveryPlan::ResumeRollback",
                "remove_stale_root_state_pending_files(&layout)?",
                "write_root_recovery_result(",
            ],
            in: recovery
        )
        for token in [
            "verify_installed_v7_driver()?", "verify_live_v8_host()?",
            "journal.record(UpdateState::PrestopAborted, &[])?",
            "write_root_state(\n        layout,\n        UpdateState::PrestopAborted",
        ] {
            XCTAssertTrue(prestop.contains(token), "pre-stop preservation omits \(token)")
        }
        XCTAssertFalse(prestop.contains("stop_exact_v8_host"))
        XCTAssertFalse(prestop.contains("reload_coreaudio_exact"))
        XCTAssertFalse(prestop.contains("publish_candidate_driver"))
        XCTAssertTrue(controller.contains("failed journal publication could advance root state"))
        XCTAssertTrue(controller.contains("terminal/finalize-only rollback model is unsafe"))
    }

    func testRootRecoveryOutcomeIsImmutableAndUserResultIsCreateOnce() throws {
        let controller = try source(controllerPath)
        let rootResult = try functionBody(
            controller,
            beginningWith: "fn write_root_recovery_result(",
            endingBefore: "fn perform_root_transaction("
        )
        let userResult = try functionBody(
            controller,
            beginningWith: "fn write_user_result(",
            endingBefore: "fn publish_user_pointer("
        )
        let createOnce = try functionBody(
            controller,
            beginningWith: "fn create_private_file(",
            endingBefore: "fn write_new_private("
        )
        for token in [
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_RECOVERY_RESULT_V1",
            "fs::symlink_metadata(&layout.recovery_result)",
            "write_new_private(",
            "outcome={outcome}",
            "ROOT_ID",
            "immutable root recovery result conflicts with the final outcome",
        ] {
            XCTAssertTrue(rootResult.contains(token), "root recovery result omits \(token)")
        }
        XCTAssertFalse(rootResult.contains("fs::remove_file"))
        XCTAssertFalse(rootResult.contains("fs::rename"))
        for token in [
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_RESULT_V1",
            "status={status}",
            "write_new_private(&layout.result",
            "USER_ID",
            "USER_GROUP",
        ] {
            XCTAssertTrue(userResult.contains(token), "user result omits \(token)")
        }
        XCTAssertTrue(createOnce.contains(".create_new(true)"))
        XCTAssertTrue(createOnce.contains("O_NOFOLLOW | O_CLOEXEC"))
        XCTAssertFalse(userResult.contains("fs::remove_file"))
        XCTAssertFalse(userResult.contains("fs::rename"))
    }

    func testHostileParserStateAndResumeFixturesRemainInPureSelfTest() throws {
        let controller = try source(controllerPath)
        guard let start = controller.range(of: "fn self_test() -> Result<()> {") else {
            return XCTFail("missing pure controller self-test")
        }
        let selfTest = String(controller[start.lowerBound...])
        for fixture in [
            "request duplicate key",
            "request missing key",
            "request unknown extra key",
            "request truncation",
            "request evidence traversal",
            "root state duplicate key",
            "root state truncation",
            "journal duplicate field",
            "journal skipped transition",
            "journal reordered transition",
            "valid divergent pending journal",
            "pending journal with two successors",
            "rollback reload intent without exact baseline runs",
            "atomic root-pointer recovery matrix failed",
            "root pointer unrelated bytes",
            "passive JSON duplicate key",
            "both-order JSON default mutation",
            "same-second exact Core Audio successor",
            "rollback reserve/headroom boundary model",
            "impossible ahead/divergent journal-state pair",
            "HostRebootstrapped",
            "Committed",
            "RolledBack",
            "DIAGNOSTIC_DRIVER_V1_SELF_TEST_OK tests=105",
        ] {
            XCTAssertTrue(
                selfTest.localizedCaseInsensitiveContains(fixture),
                "pure self-test omits hostile fixture: \(fixture)"
            )
        }
    }

    func testLauncherIsDeterministicAndFailClosedUntilFinalPins() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        for token in [
            "EXPECTED_RUSTC_SHA256=", "EXPECTED_RUSTC_DRIVER_SHA256=", "BUILD_ROOT_A=",
            "BUILD_ROOT_B=", "/usr/bin/cmp -s", "--remap-path-prefix",
            "CONTROLLER_BINARY_SHA256=", "changed after deterministic compilation",
        ] {
            XCTAssertTrue(launcher.contains(token), "launcher lacks deterministic gate: \(token)")
        }
        let status = shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher)
        let sourcePin = shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: launcher)
        let binaryPin = shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: launcher)
        switch status {
        case "PIN_AFTER_FINAL_REVIEW":
            XCTAssertEqual(sourcePin, "PIN_AFTER_FINAL_REVIEW_SOURCE_SHA256")
            XCTAssertEqual(binaryPin, "PIN_AFTER_FINAL_REVIEW_BINARY_SHA256")
            XCTAssertTrue(launcher.contains("intentionally unrunnable until final review"))
        case "PINNED_FINAL_REVIEW":
            XCTAssertEqual(sourcePin, sha256Hex(controller))
            XCTAssertEqual(sourcePin?.count, 64)
            XCTAssertEqual(binaryPin?.count, 64)
            XCTAssertFalse(launcher.contains("PIN_AFTER_FINAL_REVIEW_"))
        default:
            XCTFail("launcher is neither safely disabled nor finally pinned")
        }
    }

    func testPureControllerSelfTestPassesWithoutLiveModes() throws {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent(launcherPath)
        process.arguments = ["--self-test-diagnostic-driver-v1-update"]
        process.currentDirectoryURL = repositoryRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let error = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertEqual(output, "DIAGNOSTIC_DRIVER_V1_SELF_TEST_OK tests=105\n")
        XCTAssertEqual(output.split(separator: "\n").count, 1)
        XCTAssertTrue(output.hasSuffix("\n"))
        XCTAssertEqual(error, "")
    }
}
