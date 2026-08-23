import Foundation
import XCTest

final class V8HostUpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

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
        XCTAssertNotEqual(start.location, NSNotFound, "missing function start: \(beginning)")
        let tail = NSRange(location: start.location, length: nsSource.length - start.location)
        let finish = nsSource.range(of: ending, options: [], range: tail)
        XCTAssertNotEqual(finish.location, NSNotFound, "missing function end: \(ending)")
        return nsSource.substring(
            with: NSRange(location: start.location, length: finish.location - start.location)
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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

    func testV8UsesOnlyDisjointUnprivilegedHostNamespaces() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        let launcher = try source("macOS/scripts/update-opensteamer-host-paired-v8.sh")

        for token in [
            "const V8_UPDATE_ROOT: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v8\";",
            "const V8_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v8\";",
            #"const V8_JOURNAL_HEADER: &str = "OPENSTEAMER_PAIRED_HOST_UPDATE_V8";"#,
            #"const HIDDEN_INSTALL_PREFIX: &str = ".opensteamer-paired-v8-install-";"#,
            #"const V8_PREFLIGHT_MODE: &str = "--verify-paired-v8-host-update-preflight";"#,
            #"const V8_EXECUTE_MODE: &str = "--execute-authorized-paired-v8-host-update";"#,
            #"const V8_ROLLBACK_MODE: &str = "--rollback-authorized-paired-v8-host-update";"#,
        ] {
            XCTAssertTrue(controller.contains(token), "missing exact v8 contract: \(token)")
        }
        XCTAssertTrue(launcher.contains("This launcher has no privileged\n# route"))
        for forbidden in [
            "/usr/bin/sudo",
            "sudo -",
            "--root-driver",
            "--privileged",
            "/Library/Audio/Plug-Ins/HAL",
            "coreaudiod",
            "killall",
        ] {
            XCTAssertFalse(launcher.contains(forbidden), "launcher exposes forbidden route: \(forbidden)")
        }
    }

    func testReleaseProvenanceIsBoundToFrozenMicFixAndExactlyThreeNewFiles() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        XCTAssertTrue(
            controller.contains(#"const RELEASE_PIN_STATUS: &str = "PINNED_FINAL_REVIEW";"#)
        )
        XCTAssertFalse(
            controller.contains(#"const RELEASE_PIN_STATUS: &str = "PIN_AFTER_FINAL_REVIEW";"#)
        )
        XCTAssertTrue(
            controller.contains(
                "const EXPECTED_FUNCTIONAL_SOURCE_COMMIT: &str =\n        \"a4ec2f03a7d2cd7562b60e8ecc4ecaf54962008c\";"
            )
        )
        XCTAssertTrue(
            controller.contains(
                "const EXPECTED_FUNCTIONAL_SOURCE_TREE: &str =\n        \"56f3b98437a51a1c40d481b610b2315829c4c917\";"
            )
        )
        for path in [
            "macOS/Tests/CaptureServerTests/V8HostUpdateContractTests.swift",
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs",
            "macOS/scripts/update-opensteamer-host-paired-v8.sh",
        ] {
            XCTAssertEqual(occurrences(of: #"        "\#(path)","#, in: controller), 1)
        }

        let provenance = try functionBody(
            controller,
            beginningWith: "    fn verify_paired_v8_git_provenance(",
            endingBefore: "    fn require_authorized_provenance("
        )
        for token in [
            #"format!("{EXPECTED_FUNCTIONAL_SOURCE_COMMIT}^{{tree}}")"#,
            "functional_tree != EXPECTED_FUNCTIONAL_SOURCE_TREE",
            "REQUIRED_V7_PREDECESSOR_COMMIT,\n                EXPECTED_FUNCTIONAL_SOURCE_COMMIT,",
            "EXPECTED_FUNCTIONAL_SOURCE_COMMIT,\n                &commit,",
            #""--no-ext-diff""#,
            #""--no-renames""#,
            #""--name-status""#,
            #".map(|path| format!("A\t{path}"))"#,
            "actual_release_records != expected_release_records",
        ] {
            XCTAssertTrue(provenance.contains(token), "missing provenance gate: \(token)")
        }
        XCTAssertFalse(provenance.contains("--diff-filter=D"))
    }

    func testProvenanceEvidenceRecordsFrozenAndAuthorizedReleaseIdentities() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        let exporter = try functionBody(
            controller,
            beginningWith: "    fn export_v8_source(",
            endingBefore: "    fn build_and_verify_v8_staged_app("
        )
        assertOrdered(
            [
                "functional_source_commit={EXPECTED_FUNCTIONAL_SOURCE_COMMIT}",
                "functional_source_tree={EXPECTED_FUNCTIONAL_SOURCE_TREE}",
                #"writeln!(record, "release_commit={}", provenance.commit)?;"#,
                #"writeln!(record, "release_tree={}", provenance.tree)?;"#,
                #"writeln!(record, "commit={}", provenance.commit)?;"#,
                #"writeln!(record, "tree={}", provenance.tree)?;"#,
                #"writeln!(record, "upstream={}", provenance.upstream)?;"#,
                #"writeln!(record, "remote={}", provenance.remote)?;"#,
            ],
            in: exporter
        )
    }

    func testRetry4V7PredecessorAndCurrentRollbackPinsDriveDynamicSelfTest() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        for token in [
            #"/active-paired-host-update-v7-retry-4"#,
            #"paired-v7-update-retry-4-1787410812-36567-22c759df-9572-48b8-99f9-49cd96467e1f"#,
            #"61882730f61eba21c66333cc694e362931982402de74b2135436d17abd701d90"#,
            #"d2b74f0faf48f7f25d51c44f958aaa7aa7361c6cb7306a742c73e7f4fb85ef41"#,
            #"af2ad07715d8efe45ac8f8a355930e654441897e"#,
            #"3c017d9cf034cbc864fc19103a0919f296930f0752f8ecfedcb1c93fbbc9694d"#,
            #"9fd0d8ab7eb3d08ba52f89e4641e551c0a873ef9dcfc0644916f0533bdbd097b"#,
        ] {
            XCTAssertTrue(controller.contains(token), "missing retry4-v7 pin: \(token)")
        }
        let selfTest = try functionBody(
            controller,
            beginningWith: "    fn paired_v8_dynamic_self_test_in(",
            endingBefore: "    fn self_test_partial_install_hold_recovery("
        )
        for token in [
            #"directory.join("v7-retry4-pointer-fixture")"#,
            "pointer.write_all(COMMITTED_V7_EVIDENCE.as_bytes())?;",
            "sha256(&pointer_fixture)? != COMMITTED_V7_POINTER_SHA256",
            #"directory.join("v7-retry4-pinset-fixture")"#,
            "v7_retry4_pinset_bytes()",
            "COMMITTED_V7_RETRY4_PINSET_SHA256",
            "self_test_v7_current_oracle_pin_mutation(directory)?;",
        ] {
            XCTAssertTrue(selfTest.contains(token), "missing retry4 self-test gate: \(token)")
        }
        XCTAssertFalse(selfTest.contains("v5-pointer-fixture"))
        XCTAssertFalse(selfTest.contains("self_test_v5_oracle_pin_mutation"))
    }

    func testV5ReleasedReserveUsesEvidenceFilesystemAndRejectsPinMutants() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        XCTAssertFalse(controller.contains("COMMITTED_V5_RESERVE_DEVICE"))
        let verifier = try functionBody(
            controller,
            beginningWith: "    fn verify_committed_v5_baseline()",
            endingBefore: "    fn verify_committed_v6_baseline()"
        )
        let required = [
            "require_regular(&reserve, 0o600)?;",
            "let reserve_metadata = fs::symlink_metadata(&reserve)?;",
            "let evidence_metadata = fs::symlink_metadata(evidence)?;",
            "!reserve_metadata.file_type().is_file()",
            "reserve_metadata.file_type().is_symlink()",
            "reserve_metadata.uid() != USER_ID",
            "reserve_metadata.gid() != 20",
            "reserve_metadata.nlink() != 1",
            "reserve_metadata.permissions().mode() & 0o777 != 0o600",
            "reserve_metadata.st_flags() != 0",
            "reserve_metadata.dev() != evidence_metadata.dev()",
            "reserve_metadata.ino() != COMMITTED_V5_RESERVE_INODE",
            "reserve_metadata.len() != 0",
            "reserve_metadata.blocks() != 0",
        ]
        func hasReserveContract(_ candidate: String) -> Bool {
            required.allSatisfy(candidate.contains)
                && !candidate.contains("COMMITTED_V5_RESERVE_DEVICE")
        }
        XCTAssertTrue(hasReserveContract(verifier))

        let mutants = [
            verifier.replacingOccurrences(
                of: "reserve_metadata.dev() != evidence_metadata.dev()",
                with: "reserve_metadata.dev() != 16_777_230"
            ),
            verifier.replacingOccurrences(
                of: "            || reserve_metadata.st_flags() != 0\n",
                with: ""
            ),
            verifier.replacingOccurrences(
                of: "            || reserve_metadata.ino() != COMMITTED_V5_RESERVE_INODE\n",
                with: ""
            ),
            verifier.replacingOccurrences(
                of: "            || reserve_metadata.permissions().mode() & 0o777 != 0o600\n",
                with: ""
            ),
        ]
        for mutant in mutants {
            XCTAssertNotEqual(mutant, verifier)
            XCTAssertFalse(hasReserveContract(mutant), "v5 reserve mutant escaped contract")
        }
    }

    func testOuterRootAndDriverProofsPinExactMetadataIncludingBSDFlags() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        let outer = try functionBody(
            controller,
            beginningWith: "    fn read_v7_outer_root_snapshot()",
            endingBefore: "    fn verify_exact_v7_driver_bundle("
        )
        for token in [
            "parent_metadata.uid() != 0",
            "parent_metadata.gid() != 0",
            "parent_metadata.permissions().mode() & 0o777 != 0o755",
            "parent_metadata.st_flags() != 0",
            "parent_metadata.dev() != V7_PRODUCT_DRIVER_DEVICE",
            "parent_metadata.ino() != V7_ROOT_SUPPORT_PARENT_INODE",
            "parent_metadata.nlink() != 8",
            "parent_metadata.len() != 256",
            "(\"driver-transactions-v7\", 27_777_175_u64, 5_u64, 160_u64)",
            "(\"privileged-v7-v3\", 27_870_738, 5, 160)",
            "metadata.permissions().mode() & 0o777 != 0o700",
            "metadata.st_flags() != 0",
        ] {
            XCTAssertTrue(outer.contains(token), "missing exact outer-root pin: \(token)")
        }
        XCTAssertEqual(occurrences(of: "|| metadata.st_flags() != 0", in: outer), 1)

        let driver = try functionBody(
            controller,
            beginningWith: "    fn verify_exact_v7_driver_bundle(",
            endingBefore: "    fn sha256_bytes("
        )
        for token in [
            "metadata.st_flags() != 0",
            "V7_PRODUCT_DRIVER_TREE_SHA256",
            "V7_PRODUCT_DRIVER_EXECUTABLE_SHA256",
            #"command_output("/usr/bin/xattr""#,
            #"command_line("/usr/bin/lipo""#,
            "command_output(\n            \"/usr/bin/codesign\"",
            #""--verify", "--strict", "--all-architectures""#,
            #""--entitlements", ":-""#,
        ] {
            XCTAssertTrue(driver.contains(token), "missing driver identity proof: \(token)")
        }
        for forbidden in ["/usr/sbin/installer", "launchctl", "killall", "remove_dir_all(", "rename("] {
            XCTAssertFalse(driver.contains(forbidden), "driver verifier mutates runtime: \(forbidden)")
        }
    }

    func testCutoverAndRollbackReproveV7AroundEveryPublicationBoundary() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        let cutover = try functionBody(
            controller,
            beginningWith: "    fn perform_paired_v8_update(",
            endingBefore: "    fn rollback_existing_paired_v8_update("
        )
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "verify_v7_pointer_unchanged()?;", in: cutover),
            5
        )
        assertOrdered(
            [
                "verify_v7_pointer_unchanged()?;",
                "bootout_exact_new_job()?;",
                "verify_v7_pointer_unchanged()?;",
                "rename_exclusive(Path::new(NEW_APP), &layout.rollback_app)?;",
                "verify_current_baseline_app_at(&layout.rollback_app, false)?;",
                "rename_exclusive(&layout.install_hold, Path::new(NEW_APP))?;",
                "verify_v8_installed_matches_reference(layout)?;",
                "verify_v7_pointer_unchanged()?;",
            ],
            in: cutover
        )

        let rollback = try functionBody(
            controller,
            beginningWith: "    fn rollback_to_current_baseline(",
            endingBefore: "    fn v8_layout_from_existing("
        )
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "verify_v7_pointer_unchanged()?;", in: rollback),
            4
        )
        assertOrdered(
            [
                "archive_v8_install_hold_root(layout)?;",
                "verify_v7_pointer_unchanged()?;",
                "verify_isolated_pairing_items_present()?;",
                "verify_reviewed_launch_agent_unchanged()?;",
                "bootout_paired_v8_job_if_loaded(layout)?;",
            ],
            in: rollback
        )
        assertOrdered(
            [
                "verify_current_baseline_app_at(&layout.rollback_app, false)?;",
                "verify_v8_installed_matches_reference(layout)?;",
                "rename_exclusive(Path::new(NEW_APP), &layout.failed_app)?;",
                "require_path_absent(Path::new(NEW_APP), \"canonical app before baseline restore\")?;",
                "rename_exclusive(&layout.rollback_app, Path::new(NEW_APP))?;",
                "verify_current_baseline_app_at(Path::new(NEW_APP), true)?;",
                "verify_current_baseline_oracle_pins()?;",
                "verify_v7_pointer_unchanged()?;",
            ],
            in: rollback
        )
    }

    func testOperationalCutoverHasNoDriverReloadProbeOrRootTransactionRoute() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        let cutover = try functionBody(
            controller,
            beginningWith: "    fn execute_paired_v8_update(",
            endingBefore: "    fn export_v8_source("
        )
        for forbidden in [
            "V7_PRODUCT_DRIVER",
            "V7_ROOT_SUPPORT_PARENT",
            "V7_ROOT_TRANSACTION_PARENT",
            "/Library/Audio/Plug-Ins/HAL",
            "/usr/bin/sudo",
            "coreaudiod",
            "reload_core_audio",
            "physical-virtual-microphone-probe",
            "driver-transaction-record",
        ] {
            XCTAssertFalse(cutover.contains(forbidden), "operational flow contains forbidden route: \(forbidden)")
        }
        XCTAssertTrue(cutover.contains("verify_committed_v7_baseline()?;"))
        XCTAssertTrue(cutover.contains("verify_v7_pointer_unchanged()?;"))
    }

    func testLauncherFailsClosedAndBuildsTwinBFromExactAbsoluteSource() throws {
        let launcher = try source("macOS/scripts/update-opensteamer-host-paired-v8.sh")
        for token in [
            "RELEASE_PIN_STATUS='PINNED_FINAL_REVIEW'",
            "EXPECTED_SOURCE_SHA256='9ca05ff323a7412256df2395418a82ff61d09dd83869747b92c233489926a46b'",
            "EXPECTED_BINARY_SHA256='a233400d68f58adcf3a0aa11037634cc6e8c970b07e5e1e59248b771793a576a'",
            #"[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ]"#,
            #"*PIN_AFTER_FINAL_REVIEW*)"#,
            #"BUILD_ROOT_A=$(/usr/bin/mktemp -d "$BUILD_PARENT/.paired-v8-controller-build-a.XXXXXX")"#,
            #"BUILD_ROOT_B=$(/usr/bin/mktemp -d "$BUILD_PARENT/.paired-v8-controller-build-b.XXXXXX")"#,
            #"--remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-paired-v8""#,
            #"--remap-path-prefix "$build_root=/reviewed/opensteamer-paired-v8-build""#,
            #""$SOURCE" -o "$controller""#,
            #"CONTROLLER_A="$BUILD_ROOT_A/controller""#,
            #"CONTROLLER_B="$BUILD_ROOT_B/controller""#,
            #"/usr/bin/cmp -s "$CONTROLLER_A" "$CONTROLLER_B""#,
            #"CONTROLLER_BINARY_SHA256=$(/usr/bin/shasum -a 256 "$CONTROLLER_B""#,
        ] {
            XCTAssertTrue(launcher.contains(token), "missing launcher gate: \(token)")
        }
        XCTAssertFalse(launcher.contains("='PIN_AFTER_FINAL_REVIEW'"))
        assertOrdered(
            [
                #"[ "$RELEASE_PIN_STATUS" = 'PINNED_FINAL_REVIEW' ]"#,
                #"[ "$(/usr/bin/id -u)" = 501 ]"#,
                #"BUILD_ROOT_A=$(/usr/bin/mktemp"#,
                #"prepare_included_source "$BUILD_ROOT_A""#,
                #"compile_controller "$BUILD_ROOT_A""#,
                #"compile_controller "$BUILD_ROOT_B""#,
                #"/usr/bin/cmp -s "$CONTROLLER_A" "$CONTROLLER_B""#,
            ],
            in: launcher
        )
    }

    func testLegacyAndPairingGuardsRemainAtPreStopCutoverAndRollbackBoundaries() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"
        )
        XCTAssertTrue(
            controller.contains(
                #"const ISOLATED_PAIRING_IDENTITY_ACCOUNT: &str = "worldwide-host-identity-v1";"#
            )
        )
        XCTAssertTrue(
            controller.contains(
                #"const ISOLATED_PAIRING_VIEWER_ACCOUNT: &str = "worldwide-paired-viewer-v1";"#
            )
        )
        let cutover = try functionBody(
            controller,
            beginningWith: "    fn perform_paired_v8_update(",
            endingBefore: "    fn rollback_existing_paired_v8_update("
        )
        let rollback = try functionBody(
            controller,
            beginningWith: "    fn rollback_to_current_baseline(",
            endingBefore: "    fn v8_layout_from_existing("
        )
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "verify_isolated_pairing_items_present()?;", in: cutover),
            5
        )
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "verify_isolated_pairing_items_present()?;", in: rollback),
            3
        )
        XCTAssertTrue(cutover.contains("verify_protected_legacy_absent()?;"))
        XCTAssertTrue(rollback.contains("verify_protected_legacy_absent()?;"))
    }
}
