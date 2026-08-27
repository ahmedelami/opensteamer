import CryptoKit
import Foundation
import XCTest

final class DiagnosticDriverV7UpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let controllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v7-update-controller.rs"
    private let launcherPath = "macOS/scripts/update-opensteamer-diagnostic-driver-v7.sh"

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

    func testV7NamespacesModesAndDedicatedReleaseCheckoutAreExact() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let freshConstants = try functionBody(
            controller,
            beginningWith: "const PREFLIGHT_MODE:",
            endingBefore: "const RETAINED_V1_DEVICE:"
        )
        for token in [
            #"const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v7-update-preflight";"#,
            #"const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v7-update";"#,
            #"const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v7-update";"#,
            #"const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v7-update";"#,
            #"const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v7-update";"#,
            #"const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v7-update";"#,
            #"const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v7-update";"#,
            #"const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V7";"#,
            #"const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V7";"#,
            "/diagnostic-driver-updates-v7", "/active-diagnostic-driver-update-v7",
            "/diagnostic-driver-update-v7.lock", "/diagnostic-driver-controllers-v7",
            "/diagnostic-driver-bootstrap-v7.txt", "/diagnostic-driver-probes-v7",
        ] {
            XCTAssertTrue(freshConstants.contains(token), "missing fresh V7 token: \(token)")
        }
        for version in 1 ... 6 {
            for staleToken in [
                "diagnostic-driver-updates-v\(version)",
                "active-diagnostic-driver-update-v\(version)",
                "diagnostic-driver-update-v\(version).lock",
                "diagnostic-driver-controllers-v\(version)",
                "diagnostic-driver-bootstrap-v\(version).txt",
                "diagnostic-driver-probes-v\(version)",
            ] {
                XCTAssertFalse(
                    freshConstants.localizedCaseInsensitiveContains(staleToken),
                    "fresh V7 constants retain stale namespace: \(staleToken)"
                )
            }
        }

        let repo = "/Users/ahmed/Documents/Codex/opensteamer-diagnostic-v3"
        XCTAssertTrue(controller.contains(#"const EXPECTED_REPO: &str = "\#(repo)";"#))
        XCTAssertTrue(launcher.contains("EXPECTED_REPO='\(repo)'"))
        XCTAssertTrue(controller.contains(
            #"const EXPECTED_RELEASE_BRANCH: &str = "fix/diagnostic-driver-v7-current-host";"#
        ))
        XCTAssertTrue(controller.contains(
            #"const EXPECTED_UPDATER_BASE_COMMIT: &str = "696e77924902191fc09bb7792df7113dd6a1138b";"#
        ))
        XCTAssertTrue(controller.contains(
            #"const EXPECTED_UPDATER_BASE_TREE: &str = "158a9d10056afb8aa04da65c539f91e75e26e1ab";"#
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
                            "UID501_V21_BOUNDARY_MODE", "UID501_RETAINED_V3_BOUNDARY_MODE",
                            "UID501_RETAINED_V4_BOUNDARY_MODE",
                            "UID501_RETAINED_V5_BOUNDARY_MODE",
                            "UID501_RETAINED_V6_BOUNDARY_MODE",
                            "UID501_DISPLAY_SNAPSHOT_MODE", "UID501_DISPLAY_RESTORE_MODE"] {
            XCTAssertFalse(publicDispatch.contains(privateMode), "launcher exposes \(privateMode)")
        }
    }

    func testCurrentV21HostOldDriverCandidateAndRetainedV8PinsStaySeparate() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const HOST_EXECUTABLE_SHA256: &str =",
            #""26b9e45bed5d33d8f9a78e848a4b9fe6c9a8e0dfd10784c569e47c5532e3a64d""#,
            "const HOST_EXECUTABLE_SIZE: u64 = 7_123_616;",
            "const HOST_INFO_PLIST_SHA256: &str =",
            #""3c017d9cf034cbc864fc19103a0919f296930f0752f8ecfedcb1c93fbbc9694d""#,
            "const HOST_INFO_PLIST_SIZE: u64 = 1_477;",
            #"const HOST_PLIST_SHA256: &str = "aebb2e1fdb680bca9c5df06d2ef5a35275e852b08b9c305ecfe80b11b8c9848e";"#,
            "const HOST_PLIST_SIZE: u64 = 1_180;", "const HOST_ARGUMENTS: [&str; 8] = [",
            #""--virtual-phone-display""#,
            "const APPLICATIONS_NLINK: u64 = 38;",
            #""cfa32cd5dd2fe535aa899ac5aefaeaf06c9039843e43181c8e2fb64774d183bc""#,
            #""f5bfda9a6060a6d2c730c4882274763a4351dd46""#,
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
            endingBefore: "fn require_exact_v21_record("
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

    func testCurrentV21ReleaseBoundaryPinsEvidenceToolsAndRollbackApp() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            #"const UID501_V21_BOUNDARY_MODE: &str = "--uid501-verify-current-v21-release-boundary";"#,
            #""a9eab1b18f68c11bde41cd827413c683a92fb6347368f297d997788b74ece315""#,
            #""11d53e77fa3cc210ee001712b9ed891a298cb95f""#,
            #""d7209c1f5a28a6f117da46e2a653909007009633""#,
            #""a9a60ead3edf9ec93023fd072b63c7af16c4d338b6edc0b8934f5ebb189a7102""#,
            #""a5092ae26e46838bd3e5346b54f7a83b52bd23e1b756de7d43c5ba0cef21f97e""#,
            #""bd3041662b7ba29736b8cda3694dbd93b8181b60009a9a99f4742f7f557b3d9e""#,
            #""aa0942189f867158160a242231039320c8ab289e""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing v21 boundary pin: \(exactPin)")
        }

        let evidenceFiles = try functionBody(
            controller,
            beginningWith: "fn verify_current_v21_evidence_files(",
            endingBefore: "fn verify_current_v21_release_boundary("
        )
        for toolHash in [
            "0beb8e96aabd059ee5f108dfd05d7d5d99fa52b58f56ab942a31ee8efd33f528",
            "9a29148a58b91c6ac13281b3cc1915922bdadd00ab09b3267271e5925d52fb64",
            "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745",
            "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41",
            "6f78c8c165798485b2c7ae32f40d945407936a4c726d48f8f8fe4517cc868631",
            "c99df9a42b15f6b255f15d4d7674fc1a2145b73b85a4763097e830172c284e03",
            "a2202cbf416b5e04b3b81f33cca59572d60ae20fa858fff2539fddf87c978e4f",
        ] {
            XCTAssertTrue(evidenceFiles.contains(toolHash), "missing v21 tool pin: \(toolHash)")
        }
        XCTAssertEqual(
            evidenceFiles.components(separatedBy: #"require_no_acl_or_xattrs(&path)?"#).count - 1,
            1
        )
        XCTAssertTrue(evidenceFiles.contains("current v21 evidence changed"))

        let boundary = try functionBody(
            controller,
            beginningWith: "fn verify_current_v21_release_boundary(",
            endingBefore: "fn launchctl_print("
        )
        assertOrdered([
            "V21_POINTER_SHA256", "verify_current_v21_evidence_files()?",
            #"journal.ends_with("STATE COMMITTED\n")"#, #""result=success""#,
            #""selected_mode=603x1312@603x1312 60.00Hz""#,
            "V21_CANDIDATE_COMMIT", "V21_CANDIDATE_TREE", "V21_INSTALL_HOLD",
            "capture_uid501_host_bundle_manifest_at(Path::new(", "V21_ROLLBACK_APP",
            "V21_ROLLBACK_BUNDLE_MANIFEST_SHA256", "V21_ROLLBACK_EXECUTABLE_SHA256",
            "V21_ROLLBACK_FRAMEWORK_SHA256", "V21_ROLLBACK_CDHASH",
            "verify_current_v21_evidence_files()?",
        ], in: boundary)
    }

    func testRetainedV1ThroughV6SourcesAndEvidenceRemainImmutable() throws {
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
            "macOS/scripts/opensteamer-diagnostic-driver-v3-update-controller.rs":
                "352f0b27bd6406f6ceb1e15fb8b206f684b9b880b9d6085e4d7abc7c3560fb61",
            "macOS/scripts/update-opensteamer-diagnostic-driver-v3.sh":
                "884e2d2ce907644c0b324c8649220f55cb72e42d84e9a3fb2589426f2144bfa9",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV3UpdateContractTests.swift":
                "1d7859a89c40ed9d5e368514fa697aabd33831b3e95a2ab5ef1440c3f1c0fd23",
            "macOS/scripts/opensteamer-diagnostic-driver-v4-update-controller.rs":
                "add5f4d5bafc66fa09c7e72078b036448d74b3f684b3f191e4ba85b1d28ea2fe",
            "macOS/scripts/update-opensteamer-diagnostic-driver-v4.sh":
                "3e8d088ec908b96a088d47c748f44f74704c6717ab2f5535524cb5b5a226dcdb",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV4UpdateContractTests.swift":
                "4f3a539d137335faf8c2b261cbec7c852d6ee7dfbf05d705667f22006fa7499f",
            "macOS/scripts/opensteamer-diagnostic-driver-v5-update-controller.rs":
                "bfb0d05711a75384321f7c0b61c21144068e5ad3a6c85e33ff34f4fdc52f889a",
            "macOS/scripts/update-opensteamer-diagnostic-driver-v5.sh":
                "c3367c85faefe32ba39e623d67097876f6c00aea516a1d66ebc40713f65780cf",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV5UpdateContractTests.swift":
                "bd7eaa09e71c25c2d6ad6b7046e4cb7ce2326160b1bbfd2c3b1732af99816361",
            "macOS/scripts/opensteamer-diagnostic-driver-v6-update-controller.rs":
                "e09e2df3b0e6c1d0aa774ded78fcc9fd7dbdc2a37dfa35e84983cf1135b50cc0",
            "macOS/scripts/update-opensteamer-diagnostic-driver-v6.sh":
                "993e66af77de12357d3fcfe3c673bc9779d16ead71b6156907fe60ead67d4955",
            "macOS/Tests/CaptureServerTests/DiagnosticDriverV6UpdateContractTests.swift":
                "666e5a6ff56a9cce9ed525f9b6d27e208e38d69aaae86b9865ff8d3c0cdef989",
        ]
        for (path, expectedHash) in expectedSourceHashes {
            XCTAssertEqual(sha256Hex(try source(path)), expectedHash, "retained source changed: \(path)")
        }

        let controller = try source(controllerPath)
        for version in ["v1", "v2", "v3", "v4", "v5", "v6"] {
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
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v3_root_prestop_attempt()?").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v4_root_prestop_attempt(&retained_v4_root_lock)?").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?").count - 1,
            2
        )
        assertOrdered([
            "let retained_v4_root_lock = acquire_retained_v4_root_update_lock()?",
            "let retained_v5_root_lock = acquire_retained_v5_root_update_lock()?",
            "let retained_v6_root_lock = acquire_retained_v6_root_update_lock()?",
            "verify_retained_v4_root_prestop_attempt(&retained_v4_root_lock)?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?",
            "let initial = verify_live_current_host()?",
            "write_root_pointer(&layout)?",
            "verify_retained_v4_root_prestop_attempt(&retained_v4_root_lock)?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?",
            "write_root_state_tracked(",
        ], in: rootTransaction)
        let preflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "verify_retained_v8_evidence()?", "verify_current_v21_release_boundary()?",
            "uid501_verify_retained_v3_root_partial()?", "uid501_verify_retained_v4_root_partial()?",
            "uid501_verify_retained_v5_root_rolled_back()?",
            "uid501_verify_retained_v6_root_rolled_back()?",
            "verify_live_current_host()?",
            "verify_retained_v1_user_prestop_attempt(retained_v1_lock)?",
            "verify_retained_v2_user_prestop_attempt(retained_v2_lock)?",
            "verify_retained_v3_user_prestop_attempt(retained_v3_lock)?",
            "verify_retained_v4_user_prestop_attempt(retained_v4_lock)?",
            "verify_retained_v5_user_prestop_attempt(retained_v5_lock)?",
            "verify_retained_v6_user_rolled_back(retained_v6_lock)?",
        ], in: preflight)
    }

    func testRetainedV4UserTombstoneIsExactAndDescriptorRevalidatedTwice() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            #"const UID501_RETAINED_V4_BOUNDARY_MODE: &str = "--uid501-verify-retained-v4-partial-boundary";"#,
            #"const RETAINED_V4_NONCE: &str = "faac8c963d2a665f35efa1c50a6703bf";"#,
            "const RETAINED_V4_USER_UPDATE_ROOT_INODE: u64 = 29_375_719;",
            "const RETAINED_V4_USER_UPDATE_LOCK_INODE: u64 = 29_375_713;",
            "const RETAINED_V4_USER_ACTIVE_POINTER_INODE: u64 = 29_375_725;",
            #""f40fed284ed26b5af48891e87b61568d7b8617b059078ca4b488958f0873c8d0""#,
            "const RETAINED_V4_EVIDENCE_INODE: u64 = 29_375_720;",
            "const RETAINED_V4_PROBES_INODE: u64 = 29_375_721;",
            "const RETAINED_V4_READER_INODE: u64 = 29_375_722;",
            "const RETAINED_V4_REQUEST_INODE: u64 = 29_375_724;",
            "const RETAINED_V4_JOURNAL_INODE: u64 = 29_375_726;",
            "const RETAINED_V4_CONTROLLER_PIN_INODE: u64 = 29_375_733;",
            "const RETAINED_V4_CONTROLLER_IDENTITY_INODE: u64 = 29_375_734;",
            "const RETAINED_V4_RESULT_INODE: u64 = 29_375_782;",
            #""5bf98124a9ed94b429c174827490b9771b73ad976603eae4073037adfaa53195""#,
            #""fff13de5bcbf031cd7e1bac015c0c47e0b2fbbafae04fd5c2f3a20eebbac318b""#,
            #""36de0896aec59a2f4689f4662f71ce2427d435422658db44df6e79533a97ba4f""#,
            #""d44647f203b841b70ff910c07369868f8a99133b9cbec4d943464e2a82631e55""#,
            #""1325723eac1161c758958c24405a4885eae4d67904eaa1dc1a4d1a2866fd3462""#,
            #""01eb0f2cacf47df31ccbd95c5b22f77e4e5987401c80d41f0bba066e37e2fd62""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V4 user pin: \(exactPin)")
        }

        let payload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v4_descriptor_graph("
        )
        assertOrdered([
            "require_retained_descriptor_children(", "&graph.update_root",
            "RETAINED_V4_EVIDENCE_LEAF.as_bytes()",
            "require_retained_descriptor_children(", "&graph.evidence",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#, #"b"journal.log""#,
            #"b"opensteamer-diagnostic-snapshot-reader""#, #"b"probes""#,
            #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V4_USER_ACTIVE_POINTER_SHA256", "RETAINED_V4_JOURNAL_SHA256",
            "RETAINED_V4_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V4_CONTROLLER_PIN_SHA256", "RETAINED_V4_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V4_RESULT_SHA256",
        ], in: payload)

        let descriptorRevalidation = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_descriptor_graph(",
            endingBefore: "fn verify_retained_v4_user_prestop_attempt_once("
        )
        assertOrdered([
            "let before = retained_v4_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v4_descriptor_graph_payload(graph)?",
            "let middle = retained_v4_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v4_descriptor_graph_payload(graph)?",
            "let after = retained_v4_descriptor_graph_identities(graph, held_lock)?",
            "before != middle || middle != after",
        ], in: descriptorRevalidation)

        let oneAttempt = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_user_prestop_attempt_once(",
            endingBefore: "fn verify_retained_v4_user_prestop_attempt("
        )
        assertOrdered([
            "let first = open_retained_v4_descriptor_graph()?",
            "let first_identities = verify_retained_v4_descriptor_graph(&first, held_lock)?",
            "let second = open_retained_v4_descriptor_graph()?",
            "let second_identities = verify_retained_v4_descriptor_graph(&second, held_lock)?",
            "first.support_ancestry != second.support_ancestry",
            "first_identities != second_identities",
        ], in: oneAttempt)

        let doubleAttempt = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_user_prestop_attempt(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "let first_guard = verify_retained_v4_user_prestop_attempt_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "let second_guard = verify_retained_v4_user_prestop_attempt_once(held_lock)?",
            "verify_retained_v4_descriptor_graph(&first_guard, held_lock)?",
            "verify_retained_v4_descriptor_graph(&second_guard, held_lock)?",
            "first_guard.support_ancestry != second_guard.support_ancestry",
        ], in: doubleAttempt)
    }

    func testRetainedV4RootTombstonePinsEveryPartialNode() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const RETAINED_V4_ROOT_BOOTSTRAP_LOCATOR_INODE: u64 = 29_375_727;",
            "const RETAINED_V4_ROOT_CONTROLLER_PARENT_INODE: u64 = 29_375_728;",
            "const RETAINED_V4_ROOT_TRANSACTION_SUPPORT_INODE: u64 = 29_375_729;",
            "const RETAINED_V4_ROOT_RECOVERY_CONTROLLER_INODE: u64 = 29_375_730;",
            "const RETAINED_V4_ROOT_RECOVERY_CONTROLLER_PIN_INODE: u64 = 29_375_731;",
            "const RETAINED_V4_ROOT_TRANSACTION_CONTROLLER_INODE: u64 = 29_375_732;",
            "const RETAINED_V4_ROOT_TRANSACTION_PIN_INODE: u64 = 29_375_735;",
            "const RETAINED_V4_ROOT_TRANSACTION_IDENTITY_INODE: u64 = 29_375_736;",
            "const RETAINED_V4_ROOT_TRANSACTION_REQUEST_INODE: u64 = 29_375_737;",
            "const RETAINED_V4_ROOT_UPDATE_LOCK_INODE: u64 = 29_375_764;",
            "const RETAINED_V4_ROOT_UPDATE_ROOT_INODE: u64 = 29_375_766;",
            "const RETAINED_V4_ROOT_TRANSACTION_INODE: u64 = 29_375_767;",
            "const RETAINED_V4_ROOT_PRIOR_PARENT_INODE: u64 = 29_375_768;",
            "const RETAINED_V4_ROOT_CANDIDATE_PARENT_INODE: u64 = 29_375_769;",
            "const RETAINED_V4_ROOT_FAILED_PARENT_INODE: u64 = 29_375_770;",
            "const RETAINED_V4_ROOT_PROBES_INODE: u64 = 29_375_771;",
            "const RETAINED_V4_ROOT_SEALED_REQUEST_INODE: u64 = 29_375_772;",
            "const RETAINED_V4_ROOT_JOURNAL_INODE: u64 = 29_375_773;",
            "const RETAINED_V4_ROOT_ACTIVE_POINTER_INODE: u64 = 29_375_774;",
            "const RETAINED_V4_ROOT_CANDIDATE_BUNDLE_INODE: u64 = 29_375_775;",
            "const RETAINED_V4_ROOT_CANDIDATE_CONTENTS_INODE: u64 = 29_375_776;",
            "const RETAINED_V4_ROOT_CANDIDATE_MACOS_INODE: u64 = 29_375_777;",
            "const RETAINED_V4_ROOT_CANDIDATE_RESOURCES_INODE: u64 = 29_375_778;",
            "const RETAINED_V4_ROOT_CANDIDATE_LOCALE_INODE: u64 = 29_375_779;",
            "const RETAINED_V4_ROOT_CANDIDATE_SIGNATURE_INODE: u64 = 29_375_780;",
            "const RETAINED_V4_ROOT_CANDIDATE_INFO_INODE: u64 = 29_375_781;",
            #""81a8dba107ad2ac2f4f3d51315349962c863c37af0c861226a7b27b2aca1ad10""#,
            #""592c4bb4ae878777c91501452e9542655b3331873bfca6a638c56f34e0cc0cec""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V4 root pin: \(exactPin)")
        }

        let rootIdentity = try functionBody(
            controller,
            beginningWith: "fn retained_v4_root_node_identity(",
            endingBefore: "fn acquire_retained_v4_root_update_lock("
        )
        assertOrdered([
            "if restricted_uid501", #"sudo_fixed("#,
            #""/usr/bin/stat""#, #""%d%n%i%n%u%n%g%n%Lp%n%z%n%l%n%f%n%HT""#,
            "parse_sudo_root_stat_identity(output, path, is_directory)?",
            "sudo_root_require_no_acl_or_xattrs(path)?", "identity",
            "fs::symlink_metadata(path)?", "metadata.file_type().is_symlink()",
            "require_no_acl_or_xattrs(path)?", "identity_from_metadata(&metadata)",
            "validate_retained_v4_root_identity(identity, inode, links, length, mode, label)",
        ], in: rootIdentity)

        let rootLock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v4_root_update_lock(",
            endingBefore: "fn collect_retained_v4_root_node_identities("
        )
        assertOrdered([
            "Path::new(RETAINED_V4_ROOT_UPDATE_LOCK)",
            ".custom_flags(O_NOFOLLOW | O_CLOEXEC)", ".open(path)?",
            "RETAINED_V4_ROOT_UPDATE_LOCK_INODE",
            "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "retained_v4_root_node_identity(",
            "RETAINED_V4_ROOT_UPDATE_LOCK_INODE",
            "identity_from_metadata(&file.metadata()?)",
            "if opened != named || opened != held", "Ok(file)",
        ], in: rootLock)

        let collectedNodes = try functionBody(
            controller,
            beginningWith: "fn collect_retained_v4_root_node_identities(",
            endingBefore: "fn require_retained_v4_root_children("
        )
        XCTAssertEqual(collectedNodes.components(separatedBy: "        node(").count - 1, 26)
        for inodePin in [
            "RETAINED_V4_ROOT_BOOTSTRAP_LOCATOR_INODE",
            "RETAINED_V4_ROOT_CONTROLLER_PARENT_INODE",
            "RETAINED_V4_ROOT_TRANSACTION_SUPPORT_INODE",
            "RETAINED_V4_ROOT_RECOVERY_CONTROLLER_INODE",
            "RETAINED_V4_ROOT_RECOVERY_CONTROLLER_PIN_INODE",
            "RETAINED_V4_ROOT_TRANSACTION_CONTROLLER_INODE",
            "RETAINED_V4_ROOT_TRANSACTION_PIN_INODE",
            "RETAINED_V4_ROOT_TRANSACTION_IDENTITY_INODE",
            "RETAINED_V4_ROOT_TRANSACTION_REQUEST_INODE",
            "RETAINED_V4_ROOT_UPDATE_LOCK_INODE",
            "RETAINED_V4_ROOT_UPDATE_ROOT_INODE", "RETAINED_V4_ROOT_TRANSACTION_INODE",
            "RETAINED_V4_ROOT_PRIOR_PARENT_INODE", "RETAINED_V4_ROOT_CANDIDATE_PARENT_INODE",
            "RETAINED_V4_ROOT_FAILED_PARENT_INODE", "RETAINED_V4_ROOT_PROBES_INODE",
            "RETAINED_V4_ROOT_SEALED_REQUEST_INODE", "RETAINED_V4_ROOT_JOURNAL_INODE",
            "RETAINED_V4_ROOT_ACTIVE_POINTER_INODE", "RETAINED_V4_ROOT_CANDIDATE_BUNDLE_INODE",
            "RETAINED_V4_ROOT_CANDIDATE_CONTENTS_INODE", "RETAINED_V4_ROOT_CANDIDATE_MACOS_INODE",
            "RETAINED_V4_ROOT_CANDIDATE_RESOURCES_INODE", "RETAINED_V4_ROOT_CANDIDATE_LOCALE_INODE",
            "RETAINED_V4_ROOT_CANDIDATE_SIGNATURE_INODE", "RETAINED_V4_ROOT_CANDIDATE_INFO_INODE",
        ] {
            XCTAssertTrue(collectedNodes.contains(inodePin), "V4 root graph omits \(inodePin)")
        }

        let graphOnce = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_root_graph_once(",
            endingBefore: "fn uid501_verify_retained_v4_root_partial("
        )
        assertOrdered([
            "collect_retained_v4_root_node_identities(restricted_uid501, held_root_lock)?",
            "let child_sets = [", "RETAINED_V4_ROOT_CONTROLLER_PARENT",
            "RETAINED_V4_ROOT_TRANSACTION_SUPPORT", "RETAINED_V4_ROOT_UPDATE_ROOT",
            "RETAINED_V4_ROOT_TRANSACTION", "RETAINED_V4_ROOT_PRIOR_PARENT",
            "RETAINED_V4_ROOT_CANDIDATE_PARENT", "RETAINED_V4_ROOT_FAILED_PARENT",
            "RETAINED_V4_ROOT_PROBES", "RETAINED_V4_ROOT_CANDIDATE_BUNDLE",
            "RETAINED_V4_ROOT_CANDIDATE_CONTENTS", "RETAINED_V4_ROOT_CANDIDATE_MACOS",
            "RETAINED_V4_ROOT_CANDIDATE_RESOURCES", "RETAINED_V4_ROOT_CANDIDATE_LOCALE",
            "RETAINED_V4_ROOT_CANDIDATE_SIGNATURE",
            "for (path, expected, label) in child_sets",
            "let mut absent = vec![", "RETAINED_V4_ROOT_ACTIVE_POINTER_PENDING",
            "RETAINED_V4_ROOT_PROBE_PARENT", #"join("result.txt")"#, #"join("state.txt")"#,
            #"join(".state-PRESTOP_ABORTED.pending")"#, #"join("journal.log.pending")"#,
            #"join("prestop-abort-journal.txt")"#, #"join("rollback-reserve.bin")"#,
            #"join("recovery-result.txt")"#, #"join("bootstrap-abort-result.txt")"#,
            "require_retained_v4_root_absent(path, restricted_uid501)?",
            "let digests = verify_retained_v4_root_payload(restricted_uid501)?",
            "collect_retained_v4_root_node_identities(restricted_uid501, held_root_lock)?",
            "if before != after",
        ], in: graphOnce)

        let restrictedProof = try functionBody(
            controller,
            beginningWith: "fn uid501_verify_retained_v4_root_partial(",
            endingBefore: "fn verify_retained_v4_root_prestop_attempt("
        )
        assertOrdered([
            "let first = verify_retained_v4_root_graph_once(true, None)?",
            "thread::sleep(Duration::from_millis(50))",
            "let second = verify_retained_v4_root_graph_once(true, None)?",
            "if first != second", "Ok(second)",
        ], in: restrictedProof)

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_root_prestop_attempt(",
            endingBefore: "fn verify_prebuilt_diagnostic_reader("
        )
        assertOrdered([
            "let first = verify_retained_v4_root_graph_once(false, Some(held_root_lock))?",
            "thread::sleep(Duration::from_millis(50))",
            "let second = verify_retained_v4_root_graph_once(false, Some(held_root_lock))?",
            "if first != second", "Ok(second)",
        ], in: rootProof)

        let rootPayload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v4_root_payload(",
            endingBefore: "fn verify_retained_v4_root_graph_once("
        )
        for payloadPin in [
            "RETAINED_V4_REQUEST_SHA256", "RETAINED_V4_CONTROLLER_PIN_SHA256",
            "RETAINED_V4_CONTROLLER_IDENTITY_SHA256", "RETAINED_V4_ROOT_JOURNAL_SHA256",
            "RETAINED_V4_ROOT_ACTIVE_POINTER_SHA256", "RETAINED_V4_CONTROLLER_SHA256",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ] {
            XCTAssertTrue(rootPayload.contains(payloadPin), "V4 root payload omits \(payloadPin)")
        }
    }

    func testRetainedV4GuardsAreHeldThroughPreflightAndRootDispatch() throws {
        let controller = try source(controllerPath)
        XCTAssertTrue(controller.contains("retained_v1_v2_v3_v4_v5_v6=immutable"))
        XCTAssertFalse(controller.contains("retained_v1_v2_v3_v4_v5=immutable"))

        let dispatch = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        assertOrdered([
            "mode == UID501_RETAINED_V4_BOUNDARY_MODE",
            "acquire_retained_v4_user_update_lock()?",
            "uid501_verify_retained_v4_root_partial()?",
            "verify_retained_v4_user_prestop_attempt(&retained_v4_lock)?",
            #"println!("OPENSTEAMER_RETAINED_V4_PARTIAL_BOUNDARY_OK")"#,
        ], in: dispatch)

        let lock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v4_user_update_lock(",
            endingBefore: "fn acquire_root_update_lock("
        )
        assertOrdered([
            "Path::new(RETAINED_V4_USER_UPDATE_LOCK)",
            "openat_component_walk_with_final_flags(path, O_RDWR)?",
            "RETAINED_V4_USER_UPDATE_LOCK_INODE", "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "openat_component_walk_with_final_flags(path, O_RDWR)?",
            "RETAINED_V4_USER_UPDATE_LOCK_INODE",
            "identity_from_metadata(&opened) != identity_from_metadata(&named)",
            "identity_from_metadata(&opened) != identity_from_metadata(&reopened)",
            "before_ancestry != after_ancestry", "Ok(file)",
        ], in: lock)

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "let retained_v4_lock = acquire_retained_v4_user_update_lock()?",
            "_initial_retained_v4_guard", "&retained_v4_lock",
            "final_retained_v4_guard", "&retained_v4_lock",
            "let dispatch_retained_v4_guard =",
            "verify_retained_v4_user_prestop_attempt_once(&retained_v4_lock)?",
            "verify_retained_v4_descriptor_graph(&final_retained_v4_guard, &retained_v4_lock)?",
            "verify_retained_v4_descriptor_graph(&dispatch_retained_v4_guard, &retained_v4_lock)?",
            "final_retained_v4_guard.support_ancestry != dispatch_retained_v4_guard.support_ancestry",
            "final_v4_guard_identities != dispatch_v4_guard_identities",
            #""retained v1/v2/v3/v4/v5/v6 descriptor guard changed immediately before root dispatch""#,
            "run_sudo_helper(&root_controller, ROOT_MODE",
        ], in: execute)
    }

    func testRetainedV5RolledBackUserGraphIsExactAndDescriptorStable() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            #"const UID501_RETAINED_V5_BOUNDARY_MODE: &str = "--uid501-verify-retained-v5-rolled-back-boundary";"#,
            #"const RETAINED_V5_NONCE: &str = "8077f2789342053436141b14a41bc236";"#,
            "const RETAINED_V5_USER_UPDATE_ROOT_INODE: u64 = 29_407_438;",
            "const RETAINED_V5_USER_UPDATE_LOCK_INODE: u64 = 29_407_406;",
            "const RETAINED_V5_USER_ACTIVE_POINTER_INODE: u64 = 29_407_457;",
            "const RETAINED_V5_EVIDENCE_INODE: u64 = 29_407_439;",
            "const RETAINED_V5_PROBES_INODE: u64 = 29_407_440;",
            "const RETAINED_V5_READER_INODE: u64 = 29_407_442;",
            "const RETAINED_V5_REQUEST_INODE: u64 = 29_407_456;",
            "const RETAINED_V5_JOURNAL_INODE: u64 = 29_407_458;",
            "const RETAINED_V5_CONTROLLER_PIN_INODE: u64 = 29_407_535;",
            "const RETAINED_V5_CONTROLLER_IDENTITY_INODE: u64 = 29_407_536;",
            "const RETAINED_V5_RESULT_INODE: u64 = 29_407_896;",
            #""bc89ec2de70f49be03d027a28ff08439381485f01bfb03dd757a3e50b7d444ee""#,
            #""4e0e58666c4af6422def0be8b1afbcbc9d7c74d1cde3a4f4653e72a3672c7c60""#,
            #""2f898cad464f252af69cb762d8aac530fcf9a81c533c6a99c147a119d34ce3ad""#,
            #""495c1b87608f0bc2db19af5be75ef7c1e1ba909a0defaa20f8fc82dd8a2e586a""#,
            #""cd82412e4a747c309ebd6bf90e9154a1d75253bdaddcbdf3f6c8dd71864c63fb""#,
            #""12df5adffec3427f651ab2822ff266616a038d11264a58b714890db92163bf50""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V5 user pin: \(exactPin)")
        }

        let identities = try functionBody(
            controller,
            beginningWith: "fn retained_v5_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v5_descriptor_graph_payload("
        )
        XCTAssertEqual(identities.components(separatedBy: "            &graph.").count - 1, 11)
        assertOrdered([
            "RETAINED_V5_USER_UPDATE_ROOT_INODE", "RETAINED_V5_EVIDENCE_INODE",
            "RETAINED_V5_PROBES_INODE", "RETAINED_V5_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V5_JOURNAL_INODE", "RETAINED_V5_REQUEST_INODE",
            "RETAINED_V5_READER_INODE", "RETAINED_V5_CONTROLLER_PIN_INODE",
            "RETAINED_V5_CONTROLLER_IDENTITY_INODE", "RETAINED_V5_RESULT_INODE",
            "RETAINED_V5_USER_UPDATE_LOCK_INODE",
            "identity_from_metadata(&held_metadata)",
            "identities.last() != Some(&held_identity)",
        ], in: identities)

        let payload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v5_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v5_descriptor_graph("
        )
        assertOrdered([
            "require_retained_descriptor_children(", "&graph.update_root",
            "RETAINED_V5_EVIDENCE_LEAF.as_bytes()",
            "require_retained_descriptor_children(", "&graph.evidence",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#, #"b"journal.log""#,
            #"b"opensteamer-diagnostic-snapshot-reader""#, #"b"probes""#,
            #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V5_USER_ACTIVE_POINTER_PENDING",
            "RETAINED_V5_USER_ACTIVE_POINTER_SHA256", "RETAINED_V5_JOURNAL_SHA256",
            "RETAINED_V5_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V5_CONTROLLER_PIN_SHA256", "RETAINED_V5_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V5_RESULT_SHA256",
        ], in: payload)

        let descriptorRevalidation = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v5_descriptor_graph(",
            endingBefore: "fn verify_retained_v5_user_prestop_attempt_once("
        )
        assertOrdered([
            "let before = retained_v5_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v5_descriptor_graph_payload(graph)?",
            "let middle = retained_v5_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v5_descriptor_graph_payload(graph)?",
            "let after = retained_v5_descriptor_graph_identities(graph, held_lock)?",
            "before != middle || middle != after",
        ], in: descriptorRevalidation)

        let doubleAttempt = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v5_user_prestop_attempt(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "let first = verify_retained_v5_user_prestop_attempt_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "let second = verify_retained_v5_user_prestop_attempt_once(held_lock)?",
            "verify_retained_v5_descriptor_graph(&first, held_lock)?",
            "verify_retained_v5_descriptor_graph(&second, held_lock)?",
            "first.support_ancestry != second.support_ancestry",
        ], in: doubleAttempt)

        let dispatch = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        assertOrdered([
            "mode == UID501_RETAINED_V5_BOUNDARY_MODE",
            "acquire_retained_v5_user_update_lock()?",
            "uid501_verify_retained_v5_root_rolled_back()?",
            "verify_retained_v5_user_prestop_attempt(&retained_v5_lock)?",
            #"println!("OPENSTEAMER_RETAINED_V5_ROLLED_BACK_BOUNDARY_OK")"#,
        ], in: dispatch)
    }

    func testRetainedV5RootGraphPinsAll38RolledBackNodes() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const RETAINED_V5_ROOT_UPDATE_LOCK_INODE: u64 = 29_407_568;",
            #""5d750ab3a79608f41e61548fced5f32c4f3e7eb6a51e9ac7a39eebacadeea3b3""#,
            #""65b6577f569e2f171d2a18f71fc2598284dbf5095d759ed268454df1810471f0""#,
            #""947fe37843bb34370f9c94440fe362f9e2f57695bf0f0dccca68acbe723617e5""#,
            #""75c936bc7a6c5bdc33c5a2a06f617ece21edea4ca1dfe95dfb853f52acc40f88""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V5 root pin: \(exactPin)")
        }

        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v5_root_node_specs(",
            endingBefore: "fn validate_retained_v5_root_identity("
        )
        XCTAssertEqual(rootSpecs.components(separatedBy: "        file(").count - 1, 22)
        XCTAssertEqual(rootSpecs.components(separatedBy: "        directory(").count - 1, 16)
        for inodePin in [
            "29_407_517", "29_407_529", "29_407_530", "29_407_540", "29_407_534",
            "29_407_539", "29_407_537", "29_407_531", "29_407_532", "29_407_705",
            "29_407_706", "29_407_707", "29_407_708", "29_407_654", "29_407_655",
            "29_407_657", "29_407_658", "29_407_667", "29_407_668", "29_407_691",
            "29_407_669", "29_407_693", "29_407_672", "29_407_698", "29_407_674",
            "29_407_699", "29_407_675", "29_407_700", "29_407_893", "29_407_656",
            "29_407_659", "29_407_805", "29_407_895", "29_407_728", "29_407_660",
            "29_407_894", "29_407_662", "RETAINED_V5_ROOT_UPDATE_LOCK_INODE",
        ] {
            XCTAssertTrue(rootSpecs.contains(inodePin), "V5 root graph omits \(inodePin)")
        }
        for digestPin in [
            "RETAINED_V5_REQUEST_SHA256", "RETAINED_V5_CONTROLLER_SHA256",
            "RETAINED_V5_CONTROLLER_PIN_SHA256", "RETAINED_V5_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V5_ROOT_JOURNAL_SHA256", "RETAINED_V5_ROOT_RESULT_SHA256",
            "RETAINED_V5_ROOT_STATE_SHA256", "RETAINED_V5_ROOT_ACTIVE_POINTER_SHA256",
            "644dea67f195b5ff5c0199cbed26f9bee33246edc22ecf5895931d194c96c061",
            "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ] {
            XCTAssertTrue(rootSpecs.contains(digestPin), "V5 root graph omits \(digestPin)")
        }

        let rootLock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v5_root_update_lock(",
            endingBefore: "fn collect_retained_v5_root_node_identities("
        )
        assertOrdered([
            "spec.path == Path::new(RETAINED_V5_ROOT_UPDATE_LOCK)",
            ".custom_flags(O_NOFOLLOW | O_CLOEXEC)", ".open(&spec.path)?",
            "validate_retained_v5_root_identity(identity_from_metadata(&file.metadata()?), &spec)?",
            "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "retained_v5_root_node_identity(&spec, false)?",
            "identity_from_metadata(&file.metadata()?)", "opened != named || named != held",
            "Ok(file)",
        ], in: rootLock)

        let graphOnce = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v5_root_graph_once(",
            endingBefore: "fn uid501_verify_retained_v5_root_rolled_back("
        )
        assertOrdered([
            "let specs = retained_v5_root_node_specs()", "if specs.len() != 38",
            "collect_retained_v5_root_node_identities(restricted_uid501, held_root_lock)?",
            "let child_sets = vec![", "controller parent", "transaction controller support",
            "probe parent", "probe transaction", "root update root", "root transaction",
            "candidate-stage parent", "prior-driver parent", "transaction probes",
            "failed-driver parent", "failed candidate bundle", "failed candidate Contents",
            "failed candidate MacOS", "failed candidate Resources", "failed candidate locale",
            "failed candidate signature", "for (path, expected, label) in child_sets",
            "RETAINED_V5_ROOT_ACTIVE_POINTER_PENDING", "for spec in &specs",
            "hash_retained_v4_root_file(&spec.path, restricted_uid501)?",
            "collect_retained_v5_root_node_identities(restricted_uid501, held_root_lock)?",
            "if before != after",
        ], in: graphOnce)

        let restrictedProof = try functionBody(
            controller,
            beginningWith: "fn uid501_verify_retained_v5_root_rolled_back(",
            endingBefore: "fn verify_retained_v5_root_rolled_back("
        )
        assertOrdered([
            "verify_retained_v5_root_graph_once(true, None)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v5_root_graph_once(true, None)?", "if first != second", "Ok(second)",
        ], in: restrictedProof)

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v5_root_rolled_back(",
            endingBefore: "fn verify_prebuilt_diagnostic_reader("
        )
        assertOrdered([
            "verify_retained_v5_root_graph_once(false, Some(held_root_lock))?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v5_root_graph_once(false, Some(held_root_lock))?",
            "if first != second", "Ok(second)",
        ], in: rootProof)
    }

    func testRetainedV5LocksSpanForwardAndSealedRecoveryLifetimes() throws {
        let controller = try source(controllerPath)

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v1_user_update_lock()?", "acquire_retained_v2_user_update_lock()?",
            "acquire_retained_v3_user_update_lock()?", "acquire_retained_v4_user_update_lock()?",
            "acquire_retained_v5_user_update_lock()?", "let _lock = acquire_user_update_lock()?",
            "verify_retained_v5_user_prestop_attempt_once(&retained_v5_lock)?",
            "verify_retained_v5_descriptor_graph(&dispatch_retained_v5_guard, &retained_v5_lock)?",
            "run_sudo_helper(&root_controller, ROOT_MODE",
            "verify_retained_v5_user_prestop_attempt_once(&retained_v5_lock)?",
            #""retained v5 user boundary changed across root dispatch""#,
        ], in: execute)

        let rootEntrypoint = try functionBody(
            controller,
            beginningWith: "fn root_authorized_update(",
            endingBefore: "fn write_user_result("
        )
        assertOrdered([
            "let _root_lock = acquire_root_update_lock()?",
            "let host = perform_root_transaction(request_path)?",
            "DIAGNOSTIC_DRIVER_V7_UPDATE_COMMITTED",
        ], in: rootEntrypoint)

        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "let retained_v4_root_lock = acquire_retained_v4_root_update_lock()?",
            "let retained_v5_root_lock = acquire_retained_v5_root_update_lock()?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?",
            "let initial = verify_live_current_host()?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?",
            "write_root_state_tracked(", "let outcome = match transaction",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)? != retained_v5",
            #""retained v5 root boundary changed across the V7 cutover/rollback""#,
            "outcome",
        ], in: rootTransaction)
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?").count - 1,
            3
        )

        let publicRollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn complete_root_recovery("
        )
        assertOrdered([
            "let retained_v5_lock = acquire_retained_v5_user_update_lock()?",
            "uid501_verify_retained_v5_root_rolled_back()?",
            "verify_retained_v5_user_prestop_attempt(&retained_v5_lock)?",
            "let _lock = acquire_user_update_lock()?",
            "verify_retained_v5_user_prestop_attempt_once(&retained_v5_lock)?",
            "run_sudo_helper(", "ROOT_SEALED_ROLLBACK_MODE",
            "verify_retained_v5_user_prestop_attempt_once(&retained_v5_lock)?",
            #""retained v5 user boundary changed across sealed root recovery""#,
        ], in: publicRollback)

        let sealedRecovery = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn require_self_test_rejection<"
        )
        assertOrdered([
            "let _root_lock = acquire_root_update_lock()?",
            "let retained_v4_root_lock = acquire_retained_v4_root_update_lock()?",
            "let retained_v5_root_lock = acquire_retained_v5_root_update_lock()?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)?",
            "reconcile_root_pointer_for_recovery(&locator_request)?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)? != retained_v5",
            "finalize_sealed_bootstrap_without_root_pointer(&fixed_digest)",
            "parse_sealed_root_request(&layout.recovery_request)?",
            "verify_retained_v5_root_rolled_back(&retained_v5_root_lock)? != retained_v5",
            "complete_root_recovery(request, layout)",
        ], in: sealedRecovery)

        let journalFields = try functionBody(
            controller,
            beginningWith: "fn root_authenticated_journal_fields(",
            endingBefore: "fn perform_root_transaction("
        )
        assertOrdered([
            #""retained_v5_journal_sha256""#, "RETAINED_V5_JOURNAL_SHA256",
            #""retained_v5_root_journal_sha256""#, "RETAINED_V5_ROOT_JOURNAL_SHA256",
            #""retained_v5_locator_device""#, "retained_v5.nodes[0].device",
            #""retained_v5_locator_inode""#, "retained_v5.nodes[0].inode",
            #""retained_v5_request_sha256""#, "RETAINED_V5_REQUEST_SHA256",
        ], in: journalFields)
    }

    func testRetainedV6RolledBackUserGraphIsExactAndDescriptorStable() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            #"const UID501_RETAINED_V6_BOUNDARY_MODE: &str = "--uid501-verify-retained-v6-rolled-back-boundary";"#,
            #"const RETAINED_V6_NONCE: &str = "50ba13dc76fc5f8f7cb25b830dd5700e";"#,
            "const RETAINED_V6_USER_UPDATE_ROOT_INODE: u64 = 29_444_456;",
            "const RETAINED_V6_USER_UPDATE_LOCK_INODE: u64 = 29_444_437;",
            "const RETAINED_V6_USER_ACTIVE_POINTER_INODE: u64 = 29_444_462;",
            "const RETAINED_V6_EVIDENCE_INODE: u64 = 29_444_457;",
            "const RETAINED_V6_PROBES_INODE: u64 = 29_444_458;",
            "const RETAINED_V6_READER_INODE: u64 = 29_444_459;",
            "const RETAINED_V6_REQUEST_INODE: u64 = 29_444_461;",
            "const RETAINED_V6_JOURNAL_INODE: u64 = 29_444_463;",
            "const RETAINED_V6_CONTROLLER_PIN_INODE: u64 = 29_444_477;",
            "const RETAINED_V6_CONTROLLER_IDENTITY_INODE: u64 = 29_444_478;",
            "const RETAINED_V6_RESULT_INODE: u64 = 29_445_253;",
            #""7acad0941c20791f0d58dcc76d3d6f85b169363bc8d96e0ebc697220aa239db9""#,
            #""09299997e249591ca23af6d23c5c22f926c7d678d2c6419df32e8ede694af967""#,
            #""9db2eb7aec4d18441fc9a5cb5d9dc1720c2edcf1dee09020e394419b315b029a""#,
            #""aa7c9c7a5d4522f69a3a481377d314ae85f1e4bcfb6be1e335572693efd8df5b""#,
            #""5ebb4d6024ef1ab02ac4cd91772a3f9cee71685701442b1d4c3c7c0ce45ada16""#,
            #""1e4bdd2cba9ff627083cbaa96982a45d5a6195d0efe6993b7aa237f1e5ea30e9""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V6 user pin: \(exactPin)")
        }

        let identities = try functionBody(
            controller,
            beginningWith: "fn retained_v6_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v6_descriptor_graph_payload("
        )
        XCTAssertEqual(identities.components(separatedBy: "            &graph.").count - 1, 11)
        assertOrdered([
            "RETAINED_V6_USER_UPDATE_ROOT_INODE", "RETAINED_V6_EVIDENCE_INODE",
            "RETAINED_V6_PROBES_INODE", "RETAINED_V6_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V6_JOURNAL_INODE", "RETAINED_V6_REQUEST_INODE",
            "RETAINED_V6_READER_INODE", "RETAINED_V6_CONTROLLER_PIN_INODE",
            "RETAINED_V6_CONTROLLER_IDENTITY_INODE", "RETAINED_V6_RESULT_INODE",
            "RETAINED_V6_USER_UPDATE_LOCK_INODE",
            "identity_from_metadata(&held_metadata)",
            "identities.last() != Some(&held_identity)",
        ], in: identities)

        let payload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v6_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v6_descriptor_graph("
        )
        assertOrdered([
            "require_retained_descriptor_children(", "&graph.update_root",
            "RETAINED_V6_EVIDENCE_LEAF.as_bytes()",
            "require_retained_descriptor_children(", "&graph.evidence",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#, #"b"journal.log""#,
            #"b"opensteamer-diagnostic-snapshot-reader""#, #"b"probes""#,
            #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V6_USER_ACTIVE_POINTER_PENDING",
            "RETAINED_V6_USER_ACTIVE_POINTER_SHA256", "RETAINED_V6_JOURNAL_SHA256",
            "RETAINED_V6_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V6_CONTROLLER_PIN_SHA256", "RETAINED_V6_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V6_RESULT_SHA256",
        ], in: payload)

        let descriptorRevalidation = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v6_descriptor_graph(",
            endingBefore: "fn verify_retained_v6_user_rolled_back_once("
        )
        assertOrdered([
            "let before = retained_v6_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v6_descriptor_graph_payload(graph)?",
            "let middle = retained_v6_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v6_descriptor_graph_payload(graph)?",
            "let after = retained_v6_descriptor_graph_identities(graph, held_lock)?",
            "before != middle || middle != after",
        ], in: descriptorRevalidation)

        let doubleAttempt = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v6_user_rolled_back(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "let first = verify_retained_v6_user_rolled_back_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "let second = verify_retained_v6_user_rolled_back_once(held_lock)?",
            "verify_retained_v6_descriptor_graph(&first, held_lock)?",
            "verify_retained_v6_descriptor_graph(&second, held_lock)?",
            "first.support_ancestry != second.support_ancestry",
        ], in: doubleAttempt)

        let dispatch = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        assertOrdered([
            "mode == UID501_RETAINED_V6_BOUNDARY_MODE",
            "acquire_retained_v6_user_update_lock()?",
            "uid501_verify_retained_v6_root_rolled_back()?",
            "verify_retained_v6_user_rolled_back(&retained_v6_lock)?",
            #"println!("OPENSTEAMER_RETAINED_V6_ROLLED_BACK_BOUNDARY_OK")"#,
        ], in: dispatch)
    }

    func testRetainedV6RootGraphPinsAll37RolledBackNodes() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const RETAINED_V6_ROOT_UPDATE_LOCK_INODE: u64 = 29_444_506;",
            #""096f9824643ddb94a43abe4b672a3db06f99e733274336650b199be6b3f18e57""#,
            #""57b5022112da320067ff6b7ef7d301a31ca1e9b99de64e34ba2b4b31ebfaa4b2""#,
            #""a296c00b581e69571129afbbb7ffb1fa780bdbdd46d46b11c994e59c245e9441""#,
            #""e12815ed09e6a1e7812f74f191bb948c05a390ce802e842177133c06f639180d""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V6 root pin: \(exactPin)")
        }

        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v6_root_node_specs(",
            endingBefore: "fn validate_retained_v6_root_identity("
        )
        XCTAssertEqual(rootSpecs.components(separatedBy: "        file(").count - 1, 21)
        XCTAssertEqual(rootSpecs.components(separatedBy: "        directory(").count - 1, 16)
        for inodePin in [
            "29_444_464", "29_444_465", "29_444_466", "29_444_481", "29_444_476",
            "29_444_480", "29_444_479", "29_444_467", "29_444_475", "29_444_632",
            "29_444_633", "29_444_634", "29_444_635", "29_444_513", "29_444_514",
            "29_444_516", "29_444_517", "29_444_620", "29_444_621", "29_444_626",
            "29_444_622", "29_444_627", "29_444_623", "29_444_628", "29_444_624",
            "29_444_629", "29_444_625", "29_444_631", "29_445_229", "29_444_515",
            "29_444_518", "29_445_231", "29_444_900", "29_444_520", "29_445_230",
            "29_444_522", "RETAINED_V6_ROOT_UPDATE_LOCK_INODE",
        ] {
            XCTAssertTrue(rootSpecs.contains(inodePin), "V6 root graph omits \(inodePin)")
        }
        for digestPin in [
            "RETAINED_V6_REQUEST_SHA256", "RETAINED_V6_CONTROLLER_SHA256",
            "RETAINED_V6_CONTROLLER_PIN_SHA256", "RETAINED_V6_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V6_ROOT_JOURNAL_SHA256", "RETAINED_V6_ROOT_RESULT_SHA256",
            "RETAINED_V6_ROOT_STATE_SHA256", "RETAINED_V6_ROOT_ACTIVE_POINTER_SHA256",
            "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ] {
            XCTAssertTrue(rootSpecs.contains(digestPin), "V6 root graph omits \(digestPin)")
        }

        let rootLock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v6_root_update_lock(",
            endingBefore: "fn collect_retained_v6_root_node_identities("
        )
        assertOrdered([
            "spec.path == Path::new(RETAINED_V6_ROOT_UPDATE_LOCK)",
            ".custom_flags(O_NOFOLLOW | O_CLOEXEC)", ".open(&spec.path)?",
            "validate_retained_v6_root_identity(identity_from_metadata(&file.metadata()?), &spec)?",
            "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "retained_v6_root_node_identity(&spec, false)?",
            "identity_from_metadata(&file.metadata()?)", "opened != named || named != held",
            "Ok(file)",
        ], in: rootLock)

        let graphOnce = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v6_root_graph_once(",
            endingBefore: "fn uid501_verify_retained_v6_root_rolled_back("
        )
        assertOrdered([
            "let specs = retained_v6_root_node_specs()", "if specs.len() != 37",
            "collect_retained_v6_root_node_identities(restricted_uid501, held_root_lock)?",
            "let child_sets = vec![", "controller parent", "transaction controller support",
            "probe parent", "probe transaction", "root update root", "root transaction",
            "candidate-stage parent", "prior-driver parent", "transaction probes",
            "failed-driver parent", "failed candidate bundle", "failed candidate Contents",
            "failed candidate MacOS", "failed candidate Resources", "failed candidate locale",
            "failed candidate signature", "for (path, expected, label) in child_sets",
            "RETAINED_V6_ROOT_ACTIVE_POINTER_PENDING", "for spec in &specs",
            "hash_retained_v4_root_file(&spec.path, restricted_uid501)?",
            "collect_retained_v6_root_node_identities(restricted_uid501, held_root_lock)?",
            "if before != after",
        ], in: graphOnce)
        XCTAssertFalse(rootSpecs.contains("osds-before-mirror.json"))

        let restrictedProof = try functionBody(
            controller,
            beginningWith: "fn uid501_verify_retained_v6_root_rolled_back(",
            endingBefore: "fn verify_retained_v6_root_rolled_back("
        )
        assertOrdered([
            "verify_retained_v6_root_graph_once(true, None)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v6_root_graph_once(true, None)?", "if first != second", "Ok(second)",
        ], in: restrictedProof)

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v6_root_rolled_back(",
            endingBefore: "fn verify_prebuilt_diagnostic_reader("
        )
        assertOrdered([
            "verify_retained_v6_root_graph_once(false, Some(held_root_lock))?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v6_root_graph_once(false, Some(held_root_lock))?",
            "if first != second", "Ok(second)",
        ], in: rootProof)
    }

    func testRetainedV6LocksSpanForwardAndSealedRecoveryLifetimes() throws {
        let controller = try source(controllerPath)

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v1_user_update_lock()?", "acquire_retained_v2_user_update_lock()?",
            "acquire_retained_v3_user_update_lock()?", "acquire_retained_v4_user_update_lock()?",
            "acquire_retained_v5_user_update_lock()?",
            "acquire_retained_v6_user_update_lock()?", "let _lock = acquire_user_update_lock()?",
            "verify_retained_v6_user_rolled_back_once(&retained_v6_lock)?",
            "verify_retained_v6_descriptor_graph(&dispatch_retained_v6_guard, &retained_v6_lock)?",
            "run_sudo_helper(&root_controller, ROOT_MODE",
            "verify_retained_v6_user_rolled_back_once(&retained_v6_lock)?",
            #""retained v6 user boundary changed across root dispatch""#,
        ], in: execute)

        let rootEntrypoint = try functionBody(
            controller,
            beginningWith: "fn root_authorized_update(",
            endingBefore: "fn write_user_result("
        )
        assertOrdered([
            "let _root_lock = acquire_root_update_lock()?",
            "let host = perform_root_transaction(request_path)?",
            "DIAGNOSTIC_DRIVER_V7_UPDATE_COMMITTED",
        ], in: rootEntrypoint)

        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "let retained_v4_root_lock = acquire_retained_v4_root_update_lock()?",
            "let retained_v5_root_lock = acquire_retained_v5_root_update_lock()?",
            "let retained_v6_root_lock = acquire_retained_v6_root_update_lock()?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?",
            "let initial = verify_live_current_host()?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?",
            "write_root_state_tracked(", "let outcome = match transaction",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)? != retained_v6",
            #""retained v6 root boundary changed across the V7 cutover/rollback""#,
            "outcome",
        ], in: rootTransaction)
        XCTAssertGreaterThanOrEqual(
            rootTransaction.components(separatedBy: "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?").count - 1,
            3
        )

        let publicRollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn complete_root_recovery("
        )
        assertOrdered([
            "let retained_v5_lock = acquire_retained_v5_user_update_lock()?",
            "let retained_v6_lock = acquire_retained_v6_user_update_lock()?",
            "uid501_verify_retained_v5_root_rolled_back()?",
            "uid501_verify_retained_v6_root_rolled_back()?",
            "verify_retained_v5_user_prestop_attempt(&retained_v5_lock)?",
            "verify_retained_v6_user_rolled_back(&retained_v6_lock)?",
            "let _lock = acquire_user_update_lock()?",
            "verify_retained_v6_user_rolled_back_once(&retained_v6_lock)?",
            "run_sudo_helper(", "ROOT_SEALED_ROLLBACK_MODE",
            "verify_retained_v6_user_rolled_back_once(&retained_v6_lock)?",
            #""retained v6 user boundary changed across sealed root recovery""#,
        ], in: publicRollback)

        let sealedRecovery = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn require_self_test_rejection<"
        )
        assertOrdered([
            "let _root_lock = acquire_root_update_lock()?",
            "let retained_v4_root_lock = acquire_retained_v4_root_update_lock()?",
            "let retained_v5_root_lock = acquire_retained_v5_root_update_lock()?",
            "let retained_v6_root_lock = acquire_retained_v6_root_update_lock()?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)?",
            "reconcile_root_pointer_for_recovery(&locator_request)?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)? != retained_v6",
            "finalize_sealed_bootstrap_without_root_pointer(&fixed_digest)?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)? != retained_v6",
            "parse_sealed_root_request(&layout.recovery_request)?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)? != retained_v6",
            "complete_root_recovery(request, layout)?",
            "verify_retained_v6_root_rolled_back(&retained_v6_root_lock)? != retained_v6",
        ], in: sealedRecovery)

        let journalFields = try functionBody(
            controller,
            beginningWith: "fn root_authenticated_journal_fields(",
            endingBefore: "fn perform_root_transaction("
        )
        assertOrdered([
            #""retained_v6_journal_sha256""#, "RETAINED_V6_JOURNAL_SHA256",
            #""retained_v6_root_journal_sha256""#, "RETAINED_V6_ROOT_JOURNAL_SHA256",
            #""retained_v6_locator_device""#, "retained_v6.nodes[0].device",
            #""retained_v6_locator_inode""#, "retained_v6.nodes[0].inode",
            #""retained_v6_request_sha256""#, "RETAINED_V6_REQUEST_SHA256",
        ], in: journalFields)
    }

    func testPassiveSnapshotAllowsRegisteredAndRetiredIdleClientsOnly() throws {
        let controller = try source(controllerPath)
        let validator = try functionBody(
            controller,
            beginningWith: "fn validate_registered_only_idle_driver_slots(",
            endingBefore: "fn validate_passive_snapshot_json("
        )
        assertOrdered([
            #"json_u64(object, "driverRegisteredCount")?"#,
            #"json_hex_u64(object, "driverRegisteredSlotBitmap")?"#,
            #"json_hex_u64(object, "driverStartedSlotBitmap")?"#,
            "registered > capacity.saturating_sub(DIAGNOSTIC_MINIMUM_IDLE_SLOT_HEADROOM)",
            "started_bitmap != 0", "add_attempts != add_count", "remove_attempts != remove_count",
            "current_registration_count != Some(registered)",
            "let mut seen_slot_bitmap = 0_u64", "if seen_slot_bitmap & bit != 0",
            "seen_slot_bitmap |= bit", "match flags", "DIAGNOSTIC_REGISTERED_ONLY_FLAGS =>",
            "lease_session != 0", "lease_seed != 0", "derived_bitmap |= bit",
            "0 =>", "registration_ticks != 0", "transition_ticks == 0", "device != 0",
            "client != 0", "process != 0", "endpoint != 0",
            "generation_sum != Some(add_count)", "derived_bitmap != registered_bitmap",
            "derived_registered != registered", "derived_visible != visible_registered",
            "derived_hidden != hidden_registered",
        ], in: validator)

        let snapshot = try functionBody(
            controller,
            beginningWith: "fn validate_passive_snapshot_json(",
            endingBefore: "fn validate_mirror_loopback_json("
        )
        assertOrdered([
            #"let zero_counts = ["#,
            #""activeClientCount""#, #""driverStartedCount""#, #""anchorHostTicks""#,
            #"json_string_is(object, "driverStartedSlotBitmap", "0000000000000000")"#,
            #"json_array(object, "coreClientSlots")?.is_empty()"#,
            "validate_registered_only_idle_driver_slots(object)?", "Ok(generation)",
        ], in: snapshot)
        XCTAssertFalse(snapshot.contains(#""driverRegisteredCount""#))
        XCTAssertFalse(snapshot.contains(#""driverRegisteredSlotBitmap""#))

        let fixtures = try functionBody(
            controller,
            beginningWith: "let passive_json = format!(",
            endingBefore: "let mirror_json ="
        )
        for fixture in [
            "registered-only fixture", "registered-plus-retired fixture", "retired-only fixture",
            "registered count mismatch", "registered bitmap mismatch", "registered slot started leak",
            "registered slot lease leak", "duplicate registered slot", "failed registration attempt",
            "duplicate retired slot", "retired slot retained live device",
            "impossible retired generation history", "failed removal attempt",
        ] {
            XCTAssertTrue(fixtures.contains(fixture), "missing passive validator fixture: \(fixture)")
        }
    }

    func testRestrictedRootMetadataProofIsPrivilegedAndIdentityStable() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let privilegedProbe = try functionBody(
            controller,
            beginningWith: "fn sudo_root_require_no_acl_or_xattrs(",
            endingBefore: "fn uid501_restricted_root_directory_identity("
        )
        assertOrdered([
            #"sudo_fixed(&["/bin/ls", "-lde@", path_text(path)?]"#,
            #"require_success(&listing, "inspect restricted root artifact ACL")?"#,
            #"sudo_fixed(&["/usr/bin/xattr", path_text(path)?]"#,
            #"require_success(&xattrs, "inspect restricted root artifact xattrs")?"#,
            "!xattrs.stdout.is_empty() || !xattrs.stderr.is_empty()",
        ], in: privilegedProbe)

        let identityProof = try functionBody(
            controller,
            beginningWith: "fn uid501_restricted_root_directory_identity(",
            endingBefore: "fn require_uid501_restricted_root_directory_identity("
        )
        assertOrdered([
            "getuid() } != USER_ID", "geteuid() } != USER_ID",
            "let before = require_directory(path, ROOT_ID, ROOT_ID, mode)?",
            "let before_identity = root_directory_identity_from_metadata(&before)",
            "sudo_root_require_no_acl_or_xattrs(path)?",
            "let after = require_directory(path, ROOT_ID, ROOT_ID, mode)?",
            "let after_identity = root_directory_identity_from_metadata(&after)",
            "before_identity != after_identity", "Ok(after_identity)",
        ], in: identityProof)

        let stage = try functionBody(
            controller,
            beginningWith: "fn stage_root_owned_controller(",
            endingBefore: "fn verify_root_controller_identity("
        )
        XCTAssertEqual(
            stage.components(separatedBy:
                "let controller_parent_identity = uid501_restricted_root_directory_identity("
            ).count - 1,
            1
        )
        XCTAssertEqual(
            stage.components(separatedBy:
                "uid501_restricted_root_directory_identity(&support, ROOT_SEALED_TRAVERSE_MODE)?"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            stage.components(separatedBy: "require_uid501_restricted_root_directory_identity(").count - 1,
            2
        )
        XCTAssertFalse(stage.contains(
            "let controller_parent_identity = root_directory_identity("
        ))
        XCTAssertFalse(stage.contains(
            "let controller_support_identity = root_directory_identity("
        ))
        XCTAssertGreaterThanOrEqual(stage.components(separatedBy: #""0711""#).count - 1, 2)

        let retainedV3Boundary = try functionBody(
            controller,
            beginningWith: "fn uid501_verify_retained_v3_root_partial(",
            endingBefore: "fn verify_retained_v3_root_prestop_attempt("
        )
        assertOrdered([
            "sudo_root_require_no_acl_or_xattrs(locator_path)?",
            "uid501_restricted_root_directory_identity(",
            #"sudo_fixed("#,
            #"&["/bin/ls", "-A1", RETAINED_V3_ROOT_CONTROLLER_PARENT]"#,
            "require_retained_v3_root_namespaces_absent()?",
            "uid501_restricted_root_directory_identity(",
        ], in: retainedV3Boundary)

        XCTAssertTrue(launcher.contains(
            #"PARTIAL_DIRECTORY_XATTRS=$(/usr/bin/sudo -n -- /usr/bin/xattr "$PARTIAL_DIRECTORY") || exit 1"#
        ))
        XCTAssertTrue(launcher.contains(
            #"PARTIAL_NODE_XATTRS=$(/usr/bin/sudo -n -- /usr/bin/xattr "$PARTIAL_NODE") || exit 1"#
        ))
        XCTAssertTrue(launcher.contains(
            #"SEALED_NODE_XATTRS=$(/usr/bin/sudo -n -- /usr/bin/xattr "$SEALED_NODE") || {"#
        ))
        XCTAssertFalse(launcher.contains(#"[ -z "$(/usr/bin/xattr "$PARTIAL_DIRECTORY")" ]"#))
        XCTAssertFalse(launcher.contains(#"[ -z "$(/usr/bin/xattr "$PARTIAL_NODE")" ]"#))
        XCTAssertFalse(launcher.contains(#"[ -z "$(/usr/bin/xattr "$SEALED_NODE")" ]"#))
    }

    func testUID501DisplaySnapshotRestoreAndSixCapabilityMappingsAreExact() throws {
        let controller = try source(controllerPath)
        for mode in [
            #"const UID501_DISPLAY_SNAPSHOT_MODE: &str = "--uid501-current-virtual-display-snapshot";"#,
            #"const UID501_DISPLAY_RESTORE_MODE: &str = "--uid501-restore-current-virtual-display";"#,
        ] {
            XCTAssertTrue(controller.contains(mode))
        }
        for selectedPin in [
            "const CURRENT_VIRTUAL_DISPLAY_LOGICAL_WIDTH: usize = 720;",
            "const CURRENT_VIRTUAL_DISPLAY_LOGICAL_HEIGHT: usize = 1_280;",
            "const CURRENT_VIRTUAL_DISPLAY_PIXEL_WIDTH: usize = 720;",
            "const CURRENT_VIRTUAL_DISPLAY_PIXEL_HEIGHT: usize = 1_280;",
        ] {
            XCTAssertTrue(controller.contains(selectedPin), "missing selected current mode pin")
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
            XCTAssertTrue(mappings.contains(mapping), "missing capability mapping: \(mapping)")
        }
        XCTAssertTrue(controller.contains("six required capability mappings"))

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
        XCTAssertTrue(controller.contains(#""selected=720:1280:720:1280:60000""#))
        XCTAssertTrue(controller.contains(#""virtual-display snapshot target substitution""#))
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

    func testDescriptorPublicationStartsPrivateThenPublishesTheExactFinalMode() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let entrypoint = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        assertOrdered([
            "unsafe { umask(0o077) };", "let arguments = env::args().collect::<Vec<_>>()",
            "match arguments.as_slice()",
        ], in: entrypoint)
        XCTAssertTrue(launcher.contains("set -eu\numask 077"))

        let allowedModes = try functionBody(
            controller,
            beginningWith: "fn private_file_publication_mode_is_allowed(",
            endingBefore: "fn create_private_file("
        )
        for mode in ["0o400", "0o444", "0o500", "0o555", "0o600", "0o644", "0o700", "0o755"] {
            XCTAssertTrue(allowedModes.contains(mode), "publication mode is not allowlisted: \(mode)")
        }

        let creation = try functionBody(
            controller,
            beginningWith: "fn create_private_file(",
            endingBefore: "fn write_new_private("
        )
        assertOrdered([
            "private_file_publication_mode_is_allowed(final_mode)",
            ".create_new(true)", ".read(true)", ".write(true)",
            ".mode(0o600)", ".custom_flags(O_NOFOLLOW | O_CLOEXEC)", ".open(path)?",
            "let metadata = file.metadata()?", "metadata.uid() != uid", "metadata.gid() != gid",
            "metadata.nlink() != 1", "metadata.permissions().mode() & 0o7777 != 0o600",
            "metadata.st_flags() != 0", "Ok(file)",
        ], in: creation)
        XCTAssertFalse(creation.contains(".mode(final_mode)"))

        let publication = try functionBody(
            controller,
            beginningWith: "fn write_new_private(",
            endingBefore: "fn random_nonce("
        )
        assertOrdered([
            "create_private_file(path, uid, gid, final_mode)?",
            "file.write_all(bytes)?", "file.sync_all()?",
            "fchmod(file.as_raw_fd(), final_mode)", "file.sync_all()?",
            "let held = file.metadata()?", "let named = fs::symlink_metadata(path)?",
            "!named.file_type().is_file()", "named.file_type().is_symlink()",
            "held.dev() != named.dev()", "held.ino() != named.ino()",
            "held.uid() != uid", "held.gid() != gid", "held.nlink() != 1",
            "held.permissions().mode() & 0o7777 != final_mode", "held.st_flags() != 0",
            "identity_from_metadata(&held) != identity_from_metadata(&named)",
            "fsync_parent(path)",
        ], in: publication)
    }

    func testRealUmask077CreationAndFinalPublicationModeMatrix() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-v7-mode-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let helperSource = temporaryRoot.appendingPathComponent("mode-matrix.c")
        let helperBinary = temporaryRoot.appendingPathComponent("mode-matrix")
        let helperProgram = #"""
        #include <fcntl.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/stat.h>
        #include <sys/types.h>
        #include <unistd.h>

        static void path_for(char *path, size_t capacity, const char *root, const char *leaf) {
            int count = snprintf(path, capacity, "%s/%s", root, leaf);
            if (count < 0 || (size_t)count >= capacity) exit(10);
        }

        static void raw_creation(const char *root, const char *leaf, mode_t requested, mode_t expected) {
            char path[1024];
            path_for(path, sizeof(path), root, leaf);
            int descriptor = open(path, O_CREAT | O_EXCL | O_RDWR, requested);
            if (descriptor < 0) exit(11);
            struct stat metadata;
            if (fstat(descriptor, &metadata) != 0 || (metadata.st_mode & 0777) != expected) exit(12);
            if (close(descriptor) != 0) exit(13);
            printf("raw-%04o=%04o\n", (unsigned)requested, (unsigned)expected);
        }

        static void publish(const char *root, mode_t final_mode) {
            char leaf[32];
            char path[1024];
            int count = snprintf(leaf, sizeof(leaf), "final-%04o", (unsigned)final_mode);
            if (count < 0 || (size_t)count >= sizeof(leaf)) exit(20);
            path_for(path, sizeof(path), root, leaf);
            int descriptor = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
            if (descriptor < 0) exit(21);
            struct stat created;
            if (fstat(descriptor, &created) != 0 || (created.st_mode & 0777) != 0600) exit(22);
            if (write(descriptor, "x", 1) != 1 || fsync(descriptor) != 0) exit(23);
            if (fchmod(descriptor, final_mode) != 0 || fsync(descriptor) != 0) exit(24);
            struct stat held;
            struct stat named;
            if (fstat(descriptor, &held) != 0 || lstat(path, &named) != 0) exit(25);
            if (!S_ISREG(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino
                || held.st_nlink != 1 || (held.st_mode & 0777) != final_mode
                || (named.st_mode & 0777) != final_mode) exit(26);
            if (close(descriptor) != 0) exit(27);
            printf("final-%04o=%04o\n", (unsigned)final_mode, (unsigned)final_mode);
        }

        int main(int argc, char **argv) {
            if (argc != 2) return 2;
            umask(0077);
            raw_creation(argv[1], "raw-request-0644", 0644, 0600);
            raw_creation(argv[1], "raw-request-0755", 0755, 0700);
            raw_creation(argv[1], "raw-request-0555", 0555, 0500);
            const mode_t modes[] = {0400, 0500, 0555, 0600, 0644, 0755};
            for (size_t index = 0; index < sizeof(modes) / sizeof(modes[0]); ++index) {
                publish(argv[1], modes[index]);
            }
            return 0;
        }
        """#
        try helperProgram.write(to: helperSource, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [
            "-std=c17", "-Wall", "-Wextra", "-Werror",
            helperSource.path, "-o", helperBinary.path,
        ]
        let compileError = Pipe()
        compile.standardError = compileError
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(
            compile.terminationStatus,
            0,
            String(decoding: compileError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        guard compile.terminationStatus == 0 else { return }

        let run = Process()
        run.executableURL = helperBinary
        run.arguments = [temporaryRoot.path]
        let output = Pipe()
        let runError = Pipe()
        run.standardOutput = output
        run.standardError = runError
        try run.run()
        run.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: runError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(run.terminationStatus, 0, stderr)
        XCTAssertEqual(
            stdout,
            """
            raw-0644=0600
            raw-0755=0700
            raw-0555=0500
            final-0400=0400
            final-0500=0500
            final-0555=0555
            final-0600=0600
            final-0644=0644
            final-0755=0755

            """
        )
    }

    func testRootStagingFailureIsTerminalizedWhileTheHostIsStillPreserved() throws {
        let controller = try source(controllerPath)
        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "let initial = verify_live_current_host()?",
            "let baseline_route = stable_route_snapshot()?",
            "let baseline_coreaudio = stable_coreaudio_generation()?",
            "let authenticated_fields = root_authenticated_journal_fields(",
            "&initial", "&baseline_coreaudio",
            "journal.record(UpdateState::Authenticated, &authenticated_fields)?",
            "write_root_state(", "UpdateState::Authenticated", "&initial", "Some(&baseline_route)",
            "verify_live_current_host()? != initial",
            "stable_coreaudio_generation()? != baseline_coreaudio",
            "stable_route_snapshot()? != baseline_route",
            "match stage_root_artifacts(&layout, &request)",
        ], in: transaction)
        let stagingBoundary = try functionBody(
            transaction,
            beginningWith: "let (reader, both_order) = match stage_root_artifacts(",
            endingBefore: "verify_root_bootstrap_locator(&request)?;"
        )
        assertOrdered([
            "match stage_root_artifacts(&layout, &request)",
            "Ok(staged) => staged", "Err(stage_error) =>",
            "finalize_prestop_preserving_exact_baseline(",
            "&layout", "&mut journal", "&initial", "&baseline_coreaudio", "&baseline_route",
            "Ok(()) => stage_error", "Err(finalization_error)",
            "root artifact staging failed and pre-stop finalization failed",
        ], in: stagingBoundary)
        XCTAssertFalse(stagingBoundary.contains("parse_optional_root_state"))
        XCTAssertFalse(stagingBoundary.contains("finalize_prestop_preserving_host"))
        XCTAssertFalse(stagingBoundary.contains("stop_exact_current_host"))

        let finalizer = try functionBody(
            controller,
            beginningWith: "fn finalize_prestop_preserving_host(",
            endingBefore: "fn finalize_prestop_preserving_exact_baseline("
        )
        assertOrdered([
            "release_discovered_prestop_reserve(layout)",
            "verify_installed_v7_driver()?",
            "require_absent(&layout.prior_driver", "require_absent(&layout.failed_driver",
            "let host = verify_live_current_host()?", "verify_pairing_metadata_only()?",
            "journal.reconcile()?", "UpdateState::PrestopAborted",
            "write_root_state(", "UpdateState::PrestopAborted", "write_root_result(",
            #""prestop-aborted;host=preserved;routes={}""#,
        ], in: finalizer)
        XCTAssertFalse(finalizer.contains("stop_exact_current_host"))

        let exactBaselineFinalizer = try functionBody(
            controller,
            beginningWith: "fn finalize_prestop_preserving_exact_baseline(",
            endingBefore: "fn repair_committed_terminal_state("
        )
        assertOrdered([
            "let durable = parse_optional_root_state(layout)?",
            "match durable.as_ref()",
            "Some((UpdateState::Authenticated, durable_host, Some(durable_route), reserve))",
            "durable_host == initial", "durable_route == baseline_route", "reserve.is_none()",
            #""pre-stop durable state is not bound to the original live baseline""#,
            "verify_live_current_host()? != *initial",
            "stable_coreaudio_generation()? != *baseline_coreaudio",
            "stable_route_snapshot()? != *baseline_route",
            "finalize_prestop_preserving_host(layout, journal, durable)?",
            "outcome.host != *initial", "!outcome.routes_unchanged",
            "verify_live_current_host()? != *initial",
            "stable_coreaudio_generation()? != *baseline_coreaudio",
            "stable_route_snapshot()? != *baseline_route",
            #""original host/CoreAudio/route baseline changed during pre-stop finalization""#,
        ], in: exactBaselineFinalizer)
    }

    func testPostReloadRouteRetryIsTypedBoundedAndCandidateOnly() throws {
        let controller = try source(controllerPath)
        XCTAssertTrue(controller.contains(
            #"const AUDIO_HARDWARE_BAD_OBJECT_ERROR: i32 = i32::from_be_bytes(*b"!obj");"#
        ))
        XCTAssertTrue(controller.contains("AUDIO_HARDWARE_BAD_OBJECT_ERROR != 560_947_818"))
        XCTAssertTrue(controller.contains("const POST_RELOAD_ROUTE_MAX_ATTEMPTS: usize = 12;"))
        XCTAssertTrue(controller.contains(
            "const POST_RELOAD_ROUTE_TIMEOUT: Duration = Duration::from_secs(15);"
        ))

        let classifier = try functionBody(
            controller,
            beginningWith: "fn classify_device_uid_status(",
            endingBefore: "fn audio_default_device("
        )
        assertOrdered([
            "if status == 0", "DeviceUidStatusClass::Success",
            "status == AUDIO_HARDWARE_BAD_OBJECT_ERROR",
            "DeviceUidStatusClass::TransientBadObject", "DeviceUidStatusClass::Fatal",
        ], in: classifier)

        let uidRead = try functionBody(
            controller,
            beginningWith: "fn audio_device_uid_classified(",
            endingBefore: "fn route_capture_failure("
        )
        assertOrdered([
            "AudioObjectGetPropertyData(", "match classify_device_uid_status(status)",
            "DeviceUidStatusClass::TransientBadObject", "RouteCaptureFailure::TransientBadObject",
            "DeviceUidStatusClass::Fatal", "RouteCaptureFailure::Fatal",
            "DeviceUidStatusClass::Success", "if size !=", "value.is_null()",
            "CFStringGetCString(", #""device UID is not bounded UTF-8""#,
            "String::from_utf8(bytes)", #""device UID is not UTF-8""#,
        ], in: uidRead)

        let classifiedCapture = try functionBody(
            controller,
            beginningWith: "fn capture_route_snapshot_classified(",
            endingBefore: "fn stable_route_snapshot("
        )
        assertOrdered([
            "audio_default_device(SELECTOR_DEFAULT_INPUT).map_err(RouteCaptureFailure::Fatal)",
            "audio_default_device(SELECTOR_DEFAULT_OUTPUT).map_err(RouteCaptureFailure::Fatal)",
            "audio_default_device(SELECTOR_DEFAULT_SYSTEM_OUTPUT)",
            ".map_err(RouteCaptureFailure::Fatal)",
            "require_route_roles(RouteSnapshot {",
            "input_uid: audio_device_uid_classified(input)?",
            "output_uid: audio_device_uid_classified(output)?",
            "system_output_uid: audio_device_uid_classified(system_output)?",
            ".map_err(RouteCaptureFailure::Fatal)",
        ], in: classifiedCapture)

        let reducer = try functionBody(
            controller,
            beginningWith: "fn advance_post_reload_route_proof(",
            endingBefore: "fn evaluate_post_reload_route_observations("
        )
        assertOrdered([
            "PostReloadRouteObservation::TransientBadObject", "*previous_complete = None",
            "PostReloadRouteObservation::Complete(current)",
            "if current != *authenticated_baseline", "return Err(",
            #""complete post-reload route snapshot differs from authenticated baseline""#,
            "match previous_complete", "Some(previous) if *previous == current",
            "PostReloadRouteProofProgress::Proven", "None =>",
            "*previous_complete = Some(current)",
        ], in: reducer)

        let boundedReader = try functionBody(
            controller,
            beginningWith: "fn read_coreaudio_generation_before(",
            endingBefore: "fn stable_coreaudio_generation_before("
        )
        XCTAssertEqual(
            boundedReader.components(separatedBy: "remaining_before_post_reload_deadline(deadline)?").count - 1,
            4
        )
        for token in ["/bin/launchctl", "/bin/ps", "/usr/bin/pgrep",
                      "process_start_with_timeout("] {
            XCTAssertTrue(boundedReader.contains(token), "unbounded generation child: \(token)")
        }
        XCTAssertFalse(boundedReader.contains("COMMAND_TIMEOUT"))

        let proof = try functionBody(
            controller,
            beginningWith: "fn prove_post_reload_routes(",
            endingBefore: "fn coreaudio_restart_successor_is_exact("
        )
        assertOrdered([
            ".checked_add(POST_RELOAD_ROUTE_TIMEOUT)",
            #""post-reload route deadline overflowed""#,
            "for attempt in 1..=POST_RELOAD_ROUTE_MAX_ATTEMPTS",
            "post_reload_route_attempt_is_within_bounds(",
            "deadline.checked_duration_since(Instant::now())",
            "let before = stable_coreaudio_generation_before(deadline)?",
            "post_reload_generation_bracket_is_exact(expected_coreaudio, &before, &before)",
            "let capture = capture_route_snapshot_classified()",
            "let after = stable_coreaudio_generation_before(deadline)?",
            "post_reload_generation_bracket_is_exact(expected_coreaudio, &before, &after)",
            "let observation = match capture",
            "Ok(snapshot) => PostReloadRouteObservation::Complete(snapshot)",
            "Err(RouteCaptureFailure::TransientBadObject { .. })",
            "PostReloadRouteObservation::TransientBadObject",
            "Err(RouteCaptureFailure::Fatal(error)) => return Err(error)",
            "advance_post_reload_route_proof(",
            "deadline.checked_duration_since(Instant::now())",
            "PostReloadRouteProofProgress::Proven", "return Ok(())",
            "if attempt == POST_RELOAD_ROUTE_MAX_ATTEMPTS", "break",
            "thread::sleep(std::cmp::min(POST_RELOAD_ROUTE_RETRY_INTERVAL, remaining))",
        ], in: proof)

        let genericStable = try functionBody(
            controller,
            beginningWith: "fn stable_route_snapshot(",
            endingBefore: "fn advance_post_reload_route_proof("
        )
        assertOrdered([
            "let first = capture_route_snapshot()?",
            "thread::sleep(Duration::from_millis(250))",
            "let second = capture_route_snapshot()?", "if first != second", "return Err(",
        ], in: genericStable)
        XCTAssertFalse(genericStable.contains("TransientBadObject"))

        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "let (old_coreaudio, new_coreaudio) = reload_coreaudio_exact(&baseline_coreaudio)?",
            "prove_post_reload_routes(&new_coreaudio, &baseline_route)?",
            "journal.record(", "UpdateState::CoreAudioReloaded",
        ], in: transaction)
        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        XCTAssertFalse(rollback.contains("prove_post_reload_routes"))
        XCTAssertEqual(controller.components(separatedBy: "prove_post_reload_routes(").count - 1, 2)

        for hostileToken in [
            "post-reload Core Audio generation bracket accepted drift",
            "post-reload route attempt cap/deadline model is not fail-closed",
            "post-reload route proof accepted a bounded incomplete sequence",
            "route_b_input", "route_b_output", "route_b_system",
            "complete {label} route mismatch", "hostile prior complete route state",
        ] {
            XCTAssertTrue(controller.contains(hostileToken), "missing hostile route case: \(hostileToken)")
        }
    }

    func testLockOwnershipProbeAcceptsOnlyTheSealedControllerBasenames() throws {
        let controller = try source(controllerPath)
        let commandName = try functionBody(
            controller,
            beginningWith: "fn current_lock_probe_command_name(",
            endingBefore: "fn prove_lock_held_by_local("
        )
        assertOrdered([
            "env::current_exe()?", ".file_name()", ".and_then(OsStr::to_str)",
            #"matches!(name, "controller" | "recovery-controller")"#,
            "Ok(name.to_owned())",
        ], in: commandName)

        let lockProof = try functionBody(
            controller,
            beginningWith: "fn prove_lock_held_by_local(",
            endingBefore: "fn prove_lock_held_by("
        )
        assertOrdered([
            "let controller_pid = std::process::id()",
            "let controller_uid = unsafe { geteuid() }",
            "let controller_command = current_lock_probe_command_name()?",
            "let exact_controller = *opener_pid == controller_pid",
            "command == &controller_command", "*uid == controller_uid",
        ], in: lockProof)
        XCTAssertFalse(lockProof.contains(#"command == "controller""#))
    }

    func testLauncherHasFreshV7PinsAndPureSelfTestOnly() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let sourcePin = shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: launcher)
        let binaryPin = shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: launcher)
        XCTAssertEqual(shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher), "PINNED_FINAL_REVIEW")
        XCTAssertEqual(sourcePin, sha256Hex(controller))
        XCTAssertEqual(sourcePin?.count, 64)
        XCTAssertEqual(binaryPin?.count, 64)
        XCTAssertNotEqual(sourcePin, "e09e2df3b0e6c1d0aa774ded78fcc9fd7dbdc2a37dfa35e84983cf1135b50cc0")
        XCTAssertNotEqual(binaryPin, "34c9e3be35106640a4cae66efd0d67897c59d748effa63b2466f2d58c3cf2726")
        XCTAssertTrue(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v7"))
        XCTAssertFalse(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v2"))
        XCTAssertFalse(launcher.contains(#"if [ "$MODE" != "$SELF_TEST_MODE" ]; then"#))
        XCTAssertTrue(launcher.contains(
            #"[ "$CONTROLLER_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ] || {"#
        ))
    }

    func testPureControllerSelfTestPassesWithoutLiveModes() throws {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent(launcherPath)
        process.arguments = ["--self-test-diagnostic-driver-v7-update"]
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
        XCTAssertEqual(output, "DIAGNOSTIC_DRIVER_V7_SELF_TEST_OK tests=112\n")
        XCTAssertEqual(error, "")
    }
}
