import CryptoKit
import Darwin
import Foundation
import XCTest

final class DiagnosticDriverV12UpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let controllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v12-update-controller.rs"
    private let launcherPath = "macOS/scripts/update-opensteamer-diagnostic-driver-v12.sh"
    private let retainedV8SourcePath =
        "macOS/scripts/opensteamer-diagnostic-driver-v8-update-controller.rs"
    private let retainedV8LauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v8.sh"
    private let retainedV8ContractPath =
        "macOS/Tests/CaptureServerTests/DiagnosticDriverV8UpdateContractTests.swift"
    private let retainedV9SourcePath =
        "macOS/scripts/opensteamer-diagnostic-driver-v9-update-controller.rs"
    private let retainedV9LauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v9.sh"
    private let retainedV9ContractPath =
        "macOS/Tests/CaptureServerTests/DiagnosticDriverV9UpdateContractTests.swift"
    private let retainedV10SourcePath =
        "macOS/scripts/opensteamer-diagnostic-driver-v10-update-controller.rs"
    private let retainedV10LauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v10.sh"
    private let retainedV10ContractPath =
        "macOS/Tests/CaptureServerTests/DiagnosticDriverV10UpdateContractTests.swift"
    private let retainedV11SourcePath =
        "macOS/scripts/opensteamer-diagnostic-driver-v11-update-controller.rs"
    private let retainedV11LauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v11.sh"
    private let retainedV11ContractPath =
        "macOS/Tests/CaptureServerTests/DiagnosticDriverV11UpdateContractTests.swift"
    private let probeSourcePath =
        "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"
    private let v12ProbePath =
        "/Volumes/t7/opensteamer-diagnostic-driver-v12-probe-build/physical-virtual-microphone-probe"

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func sha256Hex(_ source: String) -> String {
        sha256Hex(Data(source.utf8))
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

    func testV12UsesFreshNamespaceAndRetainsExactV8ReleaseBytes() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let freshConstants = try functionBody(
            controller,
            beginningWith: "const PREFLIGHT_MODE:",
            endingBefore: "const RETAINED_V1_DEVICE:"
        )
        for token in [
            #"const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v12-update-preflight";"#,
            #"const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v12-update";"#,
            #"const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v12-update";"#,
            #"const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v12-update";"#,
            #"const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v12-update";"#,
            #"const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v12-update";"#,
            #"const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v12-update";"#,
            #"const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V12";"#,
            #"const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V12";"#,
            "/diagnostic-driver-updates-v12", "/active-diagnostic-driver-update-v12",
            "/diagnostic-driver-update-v12.lock", "/diagnostic-driver-controllers-v12",
            "/diagnostic-driver-bootstrap-v12.txt", "/diagnostic-driver-probes-v12",
        ] {
            XCTAssertTrue(freshConstants.contains(token), "missing fresh V12 token: \(token)")
        }
        XCTAssertFalse(freshConstants.contains("diagnostic-driver-v8-host-lock"))
        for candidate in [
            #"const CANDIDATE_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v12/production-driver-v7";"#,
            #"const CANDIDATE_DRIVER: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v12/production-driver-v7/OpensteamerVirtualMicrophone.driver";"#,
            #"const CANDIDATE_PACKAGE: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v12/production-driver-v7/OpensteamerVirtualMicrophone-v7.pkg";"#,
            #"const CANDIDATE_MANIFEST: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v12/production-driver-v7/candidate-manifest.txt";"#,
        ] {
            XCTAssertTrue(controller.contains(candidate), "missing fresh V12 candidate path: \(candidate)")
        }
        XCTAssertFalse(controller.contains("reviewed-driver-candidates-v11/production-driver-v7"))
        XCTAssertTrue(controller.contains(
            "DIAGNOSTIC_DRIVER_V12_PREFLIGHT_OK host_pid={} host_runs={} display_mode={} coreaudiod_pid={} coreaudiod_runs={} installed_driver={}:{} candidate_commit={} candidate_tree={} release_commit={} release_tree={} pairing=metadata-only legacy=protected retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11=immutable reader=passive both_order=no-default-mutation namespaces=fresh"
        ))
        XCTAssertTrue(controller.contains(
            "DIAGNOSTIC_DRIVER_V12_UPDATE_COMMITTED host_pid={} host_runs={} display_mode={} pairing=preserved routes=unchanged legacy=protected retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11=immutable namespaces=fresh"
        ))
        XCTAssertTrue(controller.contains(
            "DIAGNOSTIC_DRIVER_V12_UPDATE_COMPLETE evidence={} host_pid={} display_mode={} pairing=preserved routes=unchanged legacy=protected retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11=immutable namespaces=fresh"
        ))

        let retainedFiles: [(String, Int, String)] = [
            (
                retainedV8SourcePath,
                727_136,
                "d35f3e4082608c0323efd9c868100318566d418975244478e0f88b3812772229"
            ),
            (
                retainedV8LauncherPath,
                17_603,
                "580a9351729c30d3d7b8faa9b0b70e00344c2066007264f01e7b742065332db2"
            ),
            (
                retainedV8ContractPath,
                138_360,
                "103aa64ecb965f66237f1a15731acbec99d33fc47e879c0b30d95b97fe012c79"
            ),
        ]
        for (path, size, digest) in retainedFiles {
            let bytes = try data(path)
            XCTAssertEqual(bytes.count, size, "retained V8 file size changed: \(path)")
            XCTAssertEqual(sha256Hex(bytes), digest, "retained V8 file bytes changed: \(path)")
        }

        for pin in [
            "const RETAINED_V8_SOURCE_SIZE: u64 = 727_136;",
            "const RETAINED_V8_SOURCE_SHA256: &str =",
            #""d35f3e4082608c0323efd9c868100318566d418975244478e0f88b3812772229""#,
            "const RETAINED_V8_LAUNCHER_SIZE: u64 = 17_603;",
            "const RETAINED_V8_LAUNCHER_SHA256: &str =",
            #""580a9351729c30d3d7b8faa9b0b70e00344c2066007264f01e7b742065332db2""#,
            "const RETAINED_V8_CONTRACT_TEST_SIZE: u64 = 138_360;",
            "const RETAINED_V8_CONTRACT_TEST_SHA256: &str =",
            #""103aa64ecb965f66237f1a15731acbec99d33fc47e879c0b30d95b97fe012c79""#,
            "const RETAINED_V8_CONTROLLER_BINARY_SHA256: &str =",
            #""da20b7efb3fd8399a4c73e9f1e056969799116e5254b4e3f773fdd985aa73fed""#,
            #"const RETAINED_V8_SOURCE_COMMIT: &str = "06ce81d649707023900d180f422e94175438613a";"#,
            #"const RETAINED_V8_SOURCE_TREE: &str = "f2eed67ec095293da5dbf530829d66d2cd0e238b";"#,
        ] {
            XCTAssertTrue(controller.contains(pin), "missing immutable V8 release pin: \(pin)")
        }

        let retainedRelease = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v8_release_files(",
            endingBefore: "// The terminal V8 attempt is an immutable predecessor"
        )
        assertOrdered([
            "RETAINED_V8_SOURCE_SIZE", "RETAINED_V8_SOURCE_SHA256",
            "RETAINED_V8_LAUNCHER_SIZE", "RETAINED_V8_LAUNCHER_SHA256",
            "RETAINED_V8_CONTRACT_TEST_SIZE", "RETAINED_V8_CONTRACT_TEST_SHA256",
            #"&format!("{RETAINED_V8_SOURCE_COMMIT}^{{tree}}")"#,
            "tree != RETAINED_V8_SOURCE_TREE", "for (relative, size, mode, digest, label) in specs",
            "require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "require_no_acl_or_xattrs(&path)?", "before.len() != size", "sha256(&path)? != digest",
            "let object = format!(\"{RETAINED_V8_SOURCE_COMMIT}:{relative}\")",
            #""show""#, "sha256_bytes(&output.stdout)? != digest",
            "let after = require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "identity_from_metadata(&before) != identity_from_metadata(&after)",
        ], in: retainedRelease)

        let completePreflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "let repo = canonical_repo(repo)?", "verify_git_provenance(&repo)?",
            "verify_retained_v8_release_files(&repo)?", "verify_candidate()?",
            "uid501_verify_retained_v8_root_rolled_back()?",
            "verify_retained_v8_user_rolled_back(retained_v8_lock)?",
        ], in: completePreflight)

        let publicDispatch = try functionBody(
            launcher,
            beginningWith: "case \"$MODE\" in",
            endingBefore: "esac"
        )
        for mode in ["$SELF_TEST_MODE", "$PREFLIGHT_MODE", "$EXECUTE_MODE", "$ROLLBACK_MODE"] {
            XCTAssertTrue(publicDispatch.contains(mode), "launcher omits public mode \(mode)")
        }
        for privateMode in [
            "ROOT_MODE", "ROOT_ROLLBACK_MODE", "ROOT_SEALED_ROLLBACK_MODE",
            "AQUA_UID501_HAL_EXEC_MODE", "UID501_FRESH_ROUTE_MODE",
            "UID501_RETAINED_V8_BOUNDARY_MODE",
        ] {
            XCTAssertFalse(publicDispatch.contains(privateMode), "launcher exposes \(privateMode)")
        }
    }

    func testV12RetainsExactV9ReleaseBytesAndVerifiesThemBeforeTheCandidate() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let retainedFiles: [(String, Int, String)] = [
            (
                retainedV9SourcePath,
                954_511,
                "ef81f61d59d2524c76efdc01465c9584cbf5b6dbd1876435fdaefeaba7d2e57b"
            ),
            (
                retainedV9LauncherPath,
                18_668,
                "5f78279d472f13ced2a675f84efb9f6042d8c1b76b1062e8bd326bf0157eb9b2"
            ),
            (
                retainedV9ContractPath,
                141_217,
                "4fca98ae8529b8d99a425b6a63c2a9f1512328e3f4b261f55f7e1c96f10fb3a6"
            ),
        ]
        for (path, size, digest) in retainedFiles {
            let bytes = try data(path)
            XCTAssertEqual(bytes.count, size, "retained V9 file size changed: \(path)")
            XCTAssertEqual(sha256Hex(bytes), digest, "retained V9 file bytes changed: \(path)")
        }

        for pin in [
            #"const RETAINED_V9_SOURCE_COMMIT: &str = "0db5ac7a9f456db2997c373e1f8ddaf0916dfadd";"#,
            #"const RETAINED_V9_SOURCE_TREE: &str = "20a2b8ac96e1da37f45edd2ebca41dba73d24978";"#,
            "const RETAINED_V9_SOURCE_SIZE: u64 = 954_511;",
            "const RETAINED_V9_SOURCE_SHA256: &str =",
            #""ef81f61d59d2524c76efdc01465c9584cbf5b6dbd1876435fdaefeaba7d2e57b""#,
            "const RETAINED_V9_LAUNCHER_SIZE: u64 = 18_668;",
            "const RETAINED_V9_LAUNCHER_SHA256: &str =",
            #""5f78279d472f13ced2a675f84efb9f6042d8c1b76b1062e8bd326bf0157eb9b2""#,
            "const RETAINED_V9_CONTRACT_TEST_SIZE: u64 = 141_217;",
            "const RETAINED_V9_CONTRACT_TEST_SHA256: &str =",
            #""4fca98ae8529b8d99a425b6a63c2a9f1512328e3f4b261f55f7e1c96f10fb3a6""#,
            "const RETAINED_V9_CONTROLLER_BINARY_SIZE: u64 = 3_006_856;",
            "const RETAINED_V9_CONTROLLER_BINARY_SHA256: &str =",
            #""c17f32f809c8203ca748c55940211bc02cfbb5c5e0918f822a2030137a93ba99""#,
        ] {
            XCTAssertTrue(controller.contains(pin), "missing immutable V9 release pin: \(pin)")
        }

        let retainedRelease = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v9_release_files(",
            endingBefore: "// V9 failed before the host-stop boundary"
        )
        assertOrdered([
            #""macOS/scripts/opensteamer-diagnostic-driver-v9-update-controller.rs""#,
            "RETAINED_V9_SOURCE_SIZE", "RETAINED_V9_SOURCE_SHA256",
            #""macOS/scripts/update-opensteamer-diagnostic-driver-v9.sh""#,
            "RETAINED_V9_LAUNCHER_SIZE", "RETAINED_V9_LAUNCHER_SHA256",
            #""macOS/Tests/CaptureServerTests/DiagnosticDriverV9UpdateContractTests.swift""#,
            "RETAINED_V9_CONTRACT_TEST_SIZE", "RETAINED_V9_CONTRACT_TEST_SHA256",
            #"&format!("{RETAINED_V9_SOURCE_COMMIT}^{{tree}}")"#,
            "tree != RETAINED_V9_SOURCE_TREE",
            "for (relative, size, mode, digest, label) in specs",
            "require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "require_no_acl_or_xattrs(&path)?",
            "before.len() != size", "sha256(&path)? != digest",
            "let object = format!(\"{RETAINED_V9_SOURCE_COMMIT}:{relative}\")",
            #""show""#, "output.stdout.len() as u64 != size",
            "sha256_bytes(&output.stdout)? != digest",
            "let after = require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "identity_from_metadata(&before) != identity_from_metadata(&after)",
        ], in: retainedRelease)

        let completePreflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "let repo = canonical_repo(repo)?",
            "verify_git_provenance(&repo)?",
            "verify_retained_v8_release_files(&repo)?",
            "verify_retained_v9_release_files(&repo)?",
            "verify_candidate()?",
            "uid501_verify_retained_v8_root_rolled_back()?",
            "uid501_verify_retained_v9_root_prestop_attempt()?",
            "verify_retained_v8_user_rolled_back(retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt(retained_v9_lock)?",
        ], in: completePreflight)

        let publicDispatch = try functionBody(
            launcher,
            beginningWith: "case \"$MODE\" in",
            endingBefore: "esac"
        )
        XCTAssertFalse(publicDispatch.contains("UID501_RETAINED_V9_BOUNDARY_MODE"))
    }

    func testRetainedV8UserGraphPinsAllElevenTerminalNodes() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            #"const UID501_RETAINED_V8_BOUNDARY_MODE: &str = "--uid501-verify-retained-v8-rolled-back-boundary";"#,
            #"const RETAINED_V8_NONCE: &str = "03c20d6752c481db1bc7543fd9cbbbf8";"#,
            "const RETAINED_V8_USER_UPDATE_ROOT_INODE: u64 = 29_507_063;",
            "const RETAINED_V8_USER_UPDATE_LOCK_INODE: u64 = 29_507_043;",
            "const RETAINED_V8_USER_ACTIVE_POINTER_INODE: u64 = 29_507_069;",
            "const RETAINED_V8_EVIDENCE_INODE: u64 = 29_507_064;",
            "const RETAINED_V8_PROBES_INODE: u64 = 29_507_065;",
            "const RETAINED_V8_READER_INODE: u64 = 29_507_066;",
            "const RETAINED_V8_REQUEST_INODE: u64 = 29_507_068;",
            "const RETAINED_V8_JOURNAL_INODE: u64 = 29_507_070;",
            "const RETAINED_V8_CONTROLLER_PIN_INODE: u64 = 29_507_077;",
            "const RETAINED_V8_CONTROLLER_IDENTITY_INODE: u64 = 29_507_078;",
            "const RETAINED_V8_RESULT_INODE: u64 = 29_507_700;",
            #""cc1eccf8d01dfef79bec2a90b1723cec9cc51bed49f4206db8e2580e332120c5""#,
            #""08d04d4a9d1c7ec30d8fc9c49257af154d5cd6395d046b398c93d912423797b6""#,
            #""f33eee1cbcf504ca69ac10420ca65d9ac743f626b5ae726a705cd67a86d471e0""#,
            #""6462855cc4e5a24718b0bc65d67cbbeeeb93afbe2d12dae60c7204598a3c69cf""#,
            #""3785a5ab0b329479bbc79e1a9e570667c45ff795d2803341f8b2b4d063bf7c80""#,
            #""91aa54cebb5f0dd72b3d2eee0cdc4a87fc0670cd5907d117c320cd0b01d2063e""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V8 user pin: \(exactPin)")
        }

        let openGraph = try functionBody(
            controller,
            beginningWith: "fn open_retained_v8_descriptor_graph(",
            endingBefore: "fn retained_v8_descriptor_graph_identities("
        )
        XCTAssertTrue(openGraph.contains(#"b"diagnostic-driver-update-v8.lock""#))
        XCTAssertFalse(openGraph.contains(#"b"diagnostic-driver-update-v12.lock""#))

        let identities = try functionBody(
            controller,
            beginningWith: "fn retained_v8_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v8_descriptor_graph_payload("
        )
        XCTAssertEqual(occurrences(of: "            &graph.", in: identities), 11)
        assertOrdered([
            "RETAINED_V8_USER_UPDATE_ROOT_INODE", "RETAINED_V8_EVIDENCE_INODE",
            "RETAINED_V8_PROBES_INODE", "RETAINED_V8_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V8_JOURNAL_INODE", "RETAINED_V8_REQUEST_INODE",
            "RETAINED_V8_READER_INODE", "RETAINED_V8_CONTROLLER_PIN_INODE",
            "RETAINED_V8_CONTROLLER_IDENTITY_INODE", "RETAINED_V8_RESULT_INODE",
            "RETAINED_V8_USER_UPDATE_LOCK_INODE", "identity_from_metadata(&held_metadata)",
            "identities.last() != Some(&held_identity)",
        ], in: identities)
        for metadataTuple in [
            "RETAINED_V8_USER_UPDATE_ROOT_INODE,\n            3,\n            96,\n            0o700",
            "RETAINED_V8_EVIDENCE_INODE,\n            9,\n            288,\n            0o700",
            "RETAINED_V8_PROBES_INODE,\n            2,\n            64,\n            0o700",
            "RETAINED_V8_USER_ACTIVE_POINTER_INODE,\n            1,\n            format!(\"{RETAINED_V8_EVIDENCE}\\n\").len() as u64,\n            0o600",
            "RETAINED_V8_JOURNAL_INODE,\n            1,\n            RETAINED_V8_JOURNAL_TEXT.len() as u64,\n            0o600",
            "RETAINED_V8_REQUEST_INODE,\n            1,\n            RETAINED_V8_REQUEST_TEXT.len() as u64,\n            0o400",
            "RETAINED_V8_READER_INODE,\n            1,\n            DIAGNOSTIC_READER_SIZE,\n            0o755",
            "RETAINED_V8_CONTROLLER_PIN_INODE,\n            1,\n            65,\n            0o400",
            "RETAINED_V8_CONTROLLER_IDENTITY_INODE,\n            1,\n            RETAINED_V8_CONTROLLER_IDENTITY_TEXT.len() as u64,\n            0o400",
            "RETAINED_V8_RESULT_INODE,\n            1,\n            RETAINED_V8_RESULT_TEXT.len() as u64,\n            0o600",
            "RETAINED_V8_USER_UPDATE_LOCK_INODE,\n            1,\n            0,\n            0o600",
        ] {
            XCTAssertTrue(identities.contains(metadataTuple), "V8 user graph omits \(metadataTuple)")
        }

        let descriptorValidation = try functionBody(
            controller,
            beginningWith: "fn require_retained_descriptor(",
            endingBefore: "fn require_retained_support_descriptor("
        )
        assertOrdered([
            "file.metadata()?", "metadata.file_type().is_dir()",
            "metadata.file_type().is_file()", "metadata.file_type().is_symlink()",
            "metadata.uid() != USER_ID", "metadata.gid() != USER_GROUP",
            "metadata.permissions().mode() & 0o7777 != mode", "metadata.st_flags() != 0",
            "metadata.dev() != RETAINED_V1_DEVICE", "metadata.ino() != inode",
            "metadata.nlink() != links", "metadata.len() != length",
            "require_descriptor_no_acl_or_xattrs(file, label)?",
        ], in: descriptorValidation)

        let payload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v8_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v8_descriptor_graph("
        )
        assertOrdered([
            "require_retained_descriptor_children(", "&graph.update_root",
            "RETAINED_V8_EVIDENCE_LEAF.as_bytes()",
            "require_retained_descriptor_children(", "&graph.evidence",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#, #"b"journal.log""#,
            #"b"opensteamer-diagnostic-snapshot-reader""#, #"b"probes""#,
            #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V8_USER_ACTIVE_POINTER_PENDING",
            "RETAINED_V8_USER_ACTIVE_POINTER_SHA256", "RETAINED_V8_JOURNAL_SHA256",
            "RETAINED_V8_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V8_CONTROLLER_PIN_SHA256", "RETAINED_V8_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V8_RESULT_SHA256",
        ], in: payload)

        let doubleProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v8_user_rolled_back(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "verify_retained_v8_user_rolled_back_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v8_user_rolled_back_once(held_lock)?",
            "verify_retained_v8_descriptor_graph(&first, held_lock)?",
            "verify_retained_v8_descriptor_graph(&second, held_lock)?",
            "first.support_ancestry != second.support_ancestry",
        ], in: doubleProof)
    }

    func testRetainedV8RootGraphPinsAllThirtySevenTerminalNodes() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const RETAINED_V8_ROOT_UPDATE_LOCK_INODE: u64 = 29_507_191;",
            #""ed8ec6dcdb3831e93666b4521d32288d034cbaf57e30d0fcdf62fc9c4389824d""#,
            #""a0ab3e3b699ebb17e56af46055dd75ddd5573a12e7b2f36c2ebd0cd90fcb69dd""#,
            #""4035535365863bba64c98d32669dbd474197071b5d16c402b712f7d2511c7021""#,
            #""25a7b469996a6a229ee7ef1676bbfc14d5a970248091365ef57e54cfcb59cbae""#,
            #""b344eb24cde4ab1881b065e2ef0aa208aef12dbdd31fea7259eabc5ad5b6abaf""#,
            #""35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d""#,
            #""6e2fa0980cd27498ffe1075bcd439e61fcb0b6d38827ca2dadc3a7d6872e84e1""#,
            #""63202ae6ab294069b6f77114f0cce8f35531bbb75355f1d96c8db68f949acdc5""#,
            #""4798181065dbb851f0de518be396d6d4f8a465158923adf16bbf91bcb826a166""#,
            #""92c1b53f174dd64d1835fa9b2ecbddd84eac815ad43bbe231090d214b1cc9731""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V8 root pin: \(exactPin)")
        }

        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v8_root_node_specs(",
            endingBefore: "fn validate_retained_v8_root_identity("
        )
        XCTAssertEqual(occurrences(of: "        file(", in: rootSpecs), 21)
        XCTAssertEqual(occurrences(of: "        directory(", in: rootSpecs), 16)
        XCTAssertEqual(occurrences(of: "RETAINED_V8_CONTROLLER_BINARY_SHA256", in: rootSpecs), 2)
        for inodePin in [
            "29_507_071", "29_507_072", "29_507_073", "29_507_081", "29_507_076",
            "29_507_080", "29_507_079", "29_507_074", "29_507_075", "29_507_375",
            "29_507_376", "29_507_377", "29_507_378", "29_507_348", "29_507_352",
            "29_507_354", "29_507_355", "29_507_364", "29_507_365", "29_507_370",
            "29_507_366", "29_507_371", "29_507_367", "29_507_372", "29_507_368",
            "29_507_373", "29_507_369", "29_507_374", "29_507_651", "29_507_353",
            "29_507_357", "29_507_653", "29_507_469", "29_507_358", "29_507_652",
            "29_507_360", "RETAINED_V8_ROOT_UPDATE_LOCK_INODE",
        ] {
            XCTAssertTrue(rootSpecs.contains(inodePin), "V8 root graph omits \(inodePin)")
        }
        for metadataTuple in [
            "29_507_071,\n            670,\n            0o444",
            "29_507_072,\n            5,\n            160,\n            0o711",
            "29_507_073,\n            6,\n            192,\n            0o711",
            "29_507_081,\n            670,\n            0o444",
            "29_507_076,\n            2_410_568,\n            0o555",
            "29_507_080,\n            265,\n            0o444",
            "29_507_079,\n            65,\n            0o444",
            "29_507_074,\n            2_410_568,\n            0o555",
            "29_507_075,\n            65,\n            0o444",
            "29_507_375,\n            3,\n            96,\n            0o711",
            "29_507_376,\n            4,\n            128,\n            0o711",
            "29_507_377,\n            118_832,\n            0o555",
            "29_507_378,\n            1_096_944,\n            0o555",
            "29_507_348,\n            3,\n            96,\n            0o700",
            "29_507_352,\n            11,\n            352,\n            0o700",
            "29_507_354,\n            2,\n            64,\n            0o700",
            "29_507_355,\n            3,\n            96,\n            0o700",
            "29_507_364,\n            3,\n            96,\n            0o755",
            "29_507_365,\n            6,\n            192,\n            0o755",
            "29_507_370,\n            1_165,\n            0o644",
            "29_507_366,\n            3,\n            96,\n            0o755",
            "29_507_371,\n            170_432,\n            0o755",
            "29_507_367,\n            4,\n            128,\n            0o755",
            "29_507_372,\n            1_053,\n            0o644",
            "29_507_368,\n            3,\n            96,\n            0o755",
            "29_507_373,\n            202,\n            0o644",
            "29_507_369,\n            3,\n            96,\n            0o755",
            "29_507_374,\n            2_841,\n            0o644",
            "29_507_651,\n            2_937,\n            0o600",
            "29_507_353,\n            2,\n            64,\n            0o700",
            "29_507_357,\n            2,\n            64,\n            0o700",
            "29_507_653,\n            150,\n            0o600",
            "29_507_469,\n            0,\n            0o600",
            "29_507_358,\n            670,\n            0o400",
            "29_507_652,\n            527,\n            0o600",
            "29_507_360,\n            115,\n            0o600",
            "RETAINED_V8_ROOT_UPDATE_LOCK_INODE,\n            0,\n            0o600",
        ] {
            XCTAssertTrue(rootSpecs.contains(metadataTuple), "V8 root metadata omits \(metadataTuple)")
        }
        for digestPin in [
            "RETAINED_V8_REQUEST_SHA256", "RETAINED_V8_CONTROLLER_BINARY_SHA256",
            "RETAINED_V8_CONTROLLER_PIN_SHA256", "RETAINED_V8_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V8_ROOT_JOURNAL_SHA256", "RETAINED_V8_ROOT_RESULT_SHA256",
            "RETAINED_V8_ROOT_STATE_SHA256", "RETAINED_V8_ROOT_ACTIVE_POINTER_SHA256",
            "DIAGNOSTIC_READER_SHA256",
            "b344eb24cde4ab1881b065e2ef0aa208aef12dbdd31fea7259eabc5ad5b6abaf",
            "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ] {
            XCTAssertTrue(rootSpecs.contains(digestPin), "V8 root graph omits \(digestPin)")
        }

        let rootValidator = try functionBody(
            controller,
            beginningWith: "fn validate_retained_v8_root_identity(",
            endingBefore: "fn retained_v8_root_node_identity("
        )
        assertOrdered([
            "identity.device != RETAINED_V1_DEVICE", "identity.inode != spec.inode",
            "identity.uid != ROOT_ID", "identity.gid != ROOT_ID", "identity.mode != spec.mode",
            "identity.length != spec.length", "identity.links != spec.links",
            "identity.flags != 0", "return Err(", "Ok(identity)",
        ], in: rootValidator)

        let rootNodeRead = try functionBody(
            controller,
            beginningWith: "fn retained_v8_root_node_identity(",
            endingBefore: "fn acquire_retained_v8_root_update_lock("
        )
        assertOrdered([
            "if restricted_uid501", "sudo_fixed(", #""/usr/bin/stat""#,
            "sudo_root_require_no_acl_or_xattrs(&spec.path)?", "else",
            "fs::symlink_metadata(&spec.path)?", "metadata.file_type().is_symlink()",
            "require_no_acl_or_xattrs(&spec.path)?", "validate_retained_v8_root_identity(identity, spec)",
        ], in: rootNodeRead)

        let rootLock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v8_root_update_lock(",
            endingBefore: "fn collect_retained_v8_root_node_identities("
        )
        assertOrdered([
            "spec.path == Path::new(RETAINED_V8_ROOT_UPDATE_LOCK)",
            ".custom_flags(O_NOFOLLOW | O_CLOEXEC)", ".open(&spec.path)?",
            "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "retained_v8_root_node_identity(&spec, false)?", "opened != named || named != held",
            "Ok(file)",
        ], in: rootLock)

        let graphOnce = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v8_root_graph_once(",
            endingBefore: "fn uid501_verify_retained_v8_root_rolled_back("
        )
        assertOrdered([
            "let specs = retained_v8_root_node_specs()", "if specs.len() != 37",
            "collect_retained_v8_root_node_identities(restricted_uid501, held_root_lock)?",
            "let child_sets = vec![", "controller parent", "transaction controller support",
            "probe parent", "probe transaction", "root update root", "root transaction",
            "candidate-stage parent", "prior-driver parent", "transaction probes",
            "failed-driver parent", "failed candidate bundle", "failed candidate Contents",
            "failed candidate MacOS", "failed candidate Resources", "failed candidate locale",
            "failed candidate signature", "for (path, expected, label) in child_sets",
            "RETAINED_V8_ROOT_ACTIVE_POINTER_PENDING", "for spec in &specs",
            "hash_retained_v4_root_file(&spec.path, restricted_uid501)?",
            "collect_retained_v8_root_node_identities(restricted_uid501, held_root_lock)?",
            "if before != after",
        ], in: graphOnce)
    }

    func testRetainedV9UID501BoundaryAndUserGraphPinTheExactPrestopResidue() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            #"const UID501_RETAINED_V9_BOUNDARY_MODE: &str = "--uid501-verify-retained-v9-prestop-boundary";"#,
            #"const RETAINED_V9_NONCE: &str = "01fa65de0ff8e7699237db5be854ceb6";"#,
            "const RETAINED_V9_USER_UPDATE_ROOT_INODE: u64 = 29_628_333;",
            "const RETAINED_V9_USER_UPDATE_LOCK_INODE: u64 = 29_626_037;",
            "const RETAINED_V9_USER_ACTIVE_POINTER_INODE: u64 = 29_628_339;",
            "const RETAINED_V9_EVIDENCE_INODE: u64 = 29_628_334;",
            "const RETAINED_V9_PROBES_INODE: u64 = 29_628_335;",
            "const RETAINED_V9_READER_INODE: u64 = 29_628_336;",
            "const RETAINED_V9_REQUEST_INODE: u64 = 29_628_338;",
            "const RETAINED_V9_JOURNAL_INODE: u64 = 29_628_340;",
            "const RETAINED_V9_CONTROLLER_PIN_INODE: u64 = 29_628_347;",
            "const RETAINED_V9_CONTROLLER_IDENTITY_INODE: u64 = 29_628_348;",
            "const RETAINED_V9_RESULT_INODE: u64 = 29_628_468;",
            #""858fc7f721c6ac158769b1308c6af8265fe1a8194d1c2e70c591aebc1dbbfbe4""#,
            #""b0d09927a22097c3329591f27b5c422141c96bb2c021438cba9800211d5ae545""#,
            #""6332710fa8054b302cf70be86adba465132e47c1048e4e17e89ed3974f6a34ed""#,
            #""662a53a8de7a844589d472034a04594e7619654ed1e81e3f4843181f70a71c63""#,
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V9 user pin: \(exactPin)")
        }

        let dispatch = try functionBody(
            controller,
            beginningWith: "[_, mode] if mode == UID501_RETAINED_V9_BOUNDARY_MODE",
            endingBefore: "[_, mode, current_directory, program, arguments @ ..]"
        )
        assertOrdered([
            "acquire_retained_v9_user_update_lock()?",
            "uid501_verify_retained_v9_root_prestop_attempt()?",
            "verify_retained_v9_user_prestop_attempt(&retained_v9_lock)?",
            "OPENSTEAMER_RETAINED_V9_PRESTOP_BOUNDARY_OK",
        ], in: dispatch)

        let openGraph = try functionBody(
            controller,
            beginningWith: "fn open_retained_v9_descriptor_graph(",
            endingBefore: "fn retained_v9_descriptor_graph_identities("
        )
        assertOrdered([
            "openat_component_walk_with_final_flags(Path::new(USER_SUPPORT)",
            "RETAINED_V9_USER_UPDATE_ROOT",
            "RETAINED_V9_EVIDENCE_LEAF.as_bytes()",
            #"b"probes""#, "RETAINED_V9_USER_ACTIVE_POINTER",
            #"b"journal.log""#, #"b"root-request.txt""#,
            #"b"opensteamer-diagnostic-snapshot-reader""#,
            #"b"controller.sha256""#, #"b"controller-identity.txt""#,
            #"b"result.txt""#, #"b"diagnostic-driver-update-v9.lock""#,
        ], in: openGraph)

        let identities = try functionBody(
            controller,
            beginningWith: "fn retained_v9_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v9_descriptor_graph_payload("
        )
        for pin in [
            "RETAINED_V9_USER_UPDATE_ROOT_INODE", "RETAINED_V9_EVIDENCE_INODE",
            "RETAINED_V9_PROBES_INODE", "RETAINED_V9_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V9_JOURNAL_INODE", "RETAINED_V9_REQUEST_INODE",
            "RETAINED_V9_READER_INODE", "RETAINED_V9_CONTROLLER_PIN_INODE",
            "RETAINED_V9_CONTROLLER_IDENTITY_INODE", "RETAINED_V9_RESULT_INODE",
            "RETAINED_V9_USER_UPDATE_LOCK_INODE",
            "format!(\"{RETAINED_V9_EVIDENCE}\\n\").len() as u64",
            "RETAINED_V9_JOURNAL_TEXT.len() as u64",
            "RETAINED_V9_REQUEST_TEXT.len() as u64",
            "DIAGNOSTIC_READER_SIZE", "identity_from_metadata(&held)",
            "identities.last() != Some(&held_identity)",
        ] {
            XCTAssertTrue(identities.contains(pin), "retained V9 identity graph omits: \(pin)")
        }
        XCTAssertEqual(occurrences(of: "&graph.", in: identities), 12)

        let payload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v9_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v9_descriptor_graph("
        )
        assertOrdered([
            "RETAINED_V9_EVIDENCE_LEAF.as_bytes()",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#,
            #"b"journal.log""#, #"b"opensteamer-diagnostic-snapshot-reader""#,
            #"b"probes""#, #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V9_USER_ACTIVE_POINTER_PENDING",
            "journal.log.pending", "recovery-result.txt",
            "pointer != format!(\"{RETAINED_V9_EVIDENCE}\\n\").as_bytes()",
            "journal != RETAINED_V9_JOURNAL_TEXT.as_bytes()",
            "request != RETAINED_V9_REQUEST_TEXT.as_bytes()",
            "pin != format!(\"{RETAINED_V9_CONTROLLER_BINARY_SHA256}\\n\").as_bytes()",
            "identity != RETAINED_V9_CONTROLLER_IDENTITY_TEXT.as_bytes()",
            "result != RETAINED_V9_RESULT_TEXT.as_bytes()",
            "RETAINED_V9_USER_ACTIVE_POINTER_SHA256", "RETAINED_V9_JOURNAL_SHA256",
            "RETAINED_V9_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V9_CONTROLLER_PIN_SHA256", "RETAINED_V9_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V9_RESULT_SHA256",
        ], in: payload)

        let proof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v9_descriptor_graph(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "retained_v9_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v9_descriptor_graph_payload(graph)?",
            "retained_v9_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v9_descriptor_graph_payload(graph)?",
            "retained_v9_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v9_user_prestop_attempt_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v9_user_prestop_attempt_once(held_lock)?",
        ], in: proof)

        let userLock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v9_user_update_lock(",
            endingBefore: "fn acquire_root_update_lock("
        )
        assertOrdered([
            "openat_component_walk_with_final_flags(path, O_RDWR)?",
            "RETAINED_V9_USER_UPDATE_LOCK_INODE",
            "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "openat_component_walk_with_final_flags(path, O_RDWR)?",
            "identity_from_metadata(&opened) != identity_from_metadata(&named)",
            "identity_from_metadata(&opened) != identity_from_metadata(&reopened)",
            "before_ancestry != after_ancestry",
        ], in: userLock)

        let retainedUserImplementation = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v9_release_files(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        for forbidden in [
            "write_new_private(", "write_atomic_replace(", "fs::remove_file(",
            "fs::remove_dir(", ".create(true)", ".truncate(true)",
        ] {
            XCTAssertFalse(
                retainedUserImplementation.contains(forbidden),
                "retained V9 user/release proof gained a mutation surface: \(forbidden)"
            )
        }
    }

    func testRetainedV9RootGraphAndLockPinEveryKnownNodeAndAbsence() throws {
        let controller = try source(controllerPath)
        for exactPin in [
            "const RETAINED_V9_ROOT_BOOTSTRAP_LOCATOR_INODE: u64 = 29_628_341;",
            "const RETAINED_V9_ROOT_CONTROLLER_PARENT_INODE: u64 = 29_628_342;",
            "const RETAINED_V9_ROOT_TRANSACTION_SUPPORT_INODE: u64 = 29_628_343;",
            "const RETAINED_V9_ROOT_RECOVERY_CONTROLLER_INODE: u64 = 29_628_344;",
            "const RETAINED_V9_ROOT_RECOVERY_CONTROLLER_PIN_INODE: u64 = 29_628_345;",
            "const RETAINED_V9_ROOT_TRANSACTION_CONTROLLER_INODE: u64 = 29_628_346;",
            "const RETAINED_V9_ROOT_TRANSACTION_PIN_INODE: u64 = 29_628_349;",
            "const RETAINED_V9_ROOT_TRANSACTION_IDENTITY_INODE: u64 = 29_628_350;",
            "const RETAINED_V9_ROOT_TRANSACTION_REQUEST_INODE: u64 = 29_628_351;",
            "const RETAINED_V9_ROOT_UPDATE_LOCK_INODE: u64 = 29_628_394;",
        ] {
            XCTAssertTrue(controller.contains(exactPin), "missing retained V9 root pin: \(exactPin)")
        }

        let rootLock = try functionBody(
            controller,
            beginningWith: "fn acquire_retained_v9_root_update_lock(",
            endingBefore: "fn collect_retained_v9_root_node_identities("
        )
        assertOrdered([
            "geteuid() } != ROOT_ID", "RETAINED_V9_ROOT_UPDATE_LOCK",
            ".custom_flags(O_NOFOLLOW | O_CLOEXEC)", ".open(path)?",
            "RETAINED_V9_ROOT_UPDATE_LOCK_INODE",
            "flock(file.as_raw_fd(), LOCK_EX | LOCK_NB)",
            "retained_v4_root_node_identity(", "retained v9 named root update lock",
            "identity_from_metadata(&file.metadata()?)", "opened != named || opened != held",
        ], in: rootLock)

        let identities = try functionBody(
            controller,
            beginningWith: "fn collect_retained_v9_root_node_identities(",
            endingBefore: "fn verify_retained_v9_root_payload("
        )
        for pin in [
            "RETAINED_V9_ROOT_BOOTSTRAP_LOCATOR_INODE",
            "RETAINED_V9_ROOT_CONTROLLER_PARENT_INODE",
            "RETAINED_V9_ROOT_TRANSACTION_SUPPORT_INODE",
            "RETAINED_V9_ROOT_RECOVERY_CONTROLLER_INODE",
            "RETAINED_V9_ROOT_RECOVERY_CONTROLLER_PIN_INODE",
            "RETAINED_V9_ROOT_TRANSACTION_CONTROLLER_INODE",
            "RETAINED_V9_ROOT_TRANSACTION_PIN_INODE",
            "RETAINED_V9_ROOT_TRANSACTION_IDENTITY_INODE",
            "RETAINED_V9_ROOT_TRANSACTION_REQUEST_INODE",
            "RETAINED_V9_ROOT_UPDATE_LOCK_INODE",
            "RETAINED_V9_CONTROLLER_BINARY_SIZE", "RETAINED_V9_REQUEST_TEXT.len() as u64",
            "(true, None)", "(false, Some(held_lock))", "held != identities[9]",
        ] {
            XCTAssertTrue(identities.contains(pin), "retained V9 root identity graph omits: \(pin)")
        }
        XCTAssertEqual(occurrences(of: "node(RETAINED_V9_", in: identities), 10)

        let payload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v9_root_payload(",
            endingBefore: "fn verify_retained_v9_root_graph_once("
        )
        assertOrdered([
            "controller-{RETAINED_V9_NONCE}",
            "RETAINED_V9_ROOT_CONTROLLER_PARENT",
            #""recovery-controller""#, #""recovery-controller.sha256""#,
            "RETAINED_V9_ROOT_TRANSACTION_SUPPORT",
            #""bootstrap-request.txt""#, #""controller""#,
            #""controller-identity.txt""#, #""controller.sha256""#,
            "RETAINED_V9_ROOT_ACTIVE_POINTER", "RETAINED_V9_ROOT_ACTIVE_POINTER_PENDING",
            "RETAINED_V9_ROOT_UPDATE_ROOT", "RETAINED_V9_ROOT_PROBE_PARENT",
            "RETAINED_V9_ROOT_BOOTSTRAP_LOCATOR", "RETAINED_V9_REQUEST_SHA256",
            "RETAINED_V9_ROOT_RECOVERY_CONTROLLER_PIN", "RETAINED_V9_CONTROLLER_PIN_SHA256",
            "RETAINED_V9_ROOT_TRANSACTION_PIN", "RETAINED_V9_CONTROLLER_PIN_SHA256",
            "RETAINED_V9_ROOT_TRANSACTION_IDENTITY", "RETAINED_V9_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V9_ROOT_TRANSACTION_REQUEST", "RETAINED_V9_REQUEST_SHA256",
            "RETAINED_V9_ROOT_UPDATE_LOCK", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "RETAINED_V9_ROOT_RECOVERY_CONTROLLER",
            "RETAINED_V9_ROOT_TRANSACTION_CONTROLLER",
            "digest != RETAINED_V9_CONTROLLER_BINARY_SHA256",
        ], in: payload)

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v9_root_graph_once(",
            endingBefore: "fn verify_prebuilt_diagnostic_reader("
        )
        assertOrdered([
            "collect_retained_v9_root_node_identities(restricted_uid501, held_root_lock)?",
            "verify_retained_v9_root_payload(restricted_uid501)?",
            "collect_retained_v9_root_node_identities(restricted_uid501, held_root_lock)?",
            "if before != after",
            "fn uid501_verify_retained_v9_root_prestop_attempt()",
            "verify_retained_v9_root_graph_once(true, None)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v9_root_graph_once(true, None)?",
            "fn verify_retained_v9_root_prestop_attempt(",
            "verify_retained_v9_root_graph_once(false, Some(held_root_lock))?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v9_root_graph_once(false, Some(held_root_lock))?",
        ], in: rootProof)
        for forbidden in [
            "write_new_private(", "write_atomic_replace(", "fs::remove_file(",
            "fs::remove_dir(", ".create(true)", ".truncate(true)",
        ] {
            XCTAssertFalse(
                rootProof.contains(forbidden),
                "retained V9 root proof gained a mutation surface: \(forbidden)"
            )
        }
    }

    func testRetainedV10ReleaseUserAndRootGraphsAreExactAndImmutable() throws {
        let controller = try source(controllerPath)
        let retainedFiles: [(String, Int, String)] = [
            (
                retainedV10SourcePath,
                997_051,
                "51f9da8faf0eb8d0cd5657254d869dd469c0a9a20d1e2fe6d37e510af42792a3"
            ),
            (
                retainedV10LauncherPath,
                18_689,
                "dc7e0d62118c04e66e33e20caa1e820e355002f321e5fd93daeeabc4e970edb7"
            ),
            (
                retainedV10ContractPath,
                167_111,
                "6294abb7aa47625e4bf87a3c56845a4327d6dabedddc6b002be0ecf6b8205a98"
            ),
        ]
        for (path, size, digest) in retainedFiles {
            let bytes = try data(path)
            XCTAssertEqual(bytes.count, size, "retained V10 file size changed: \(path)")
            XCTAssertEqual(sha256Hex(bytes), digest, "retained V10 file bytes changed: \(path)")
        }

        for pin in [
            #"const RETAINED_V10_SOURCE_COMMIT: &str = "52ce23a2a0a9a90aac18d8d0d6b0c6442d22596b";"#,
            #"const RETAINED_V10_SOURCE_TREE: &str = "5b4fec82645c5454fc57807e80af071be6263424";"#,
            "const RETAINED_V10_SOURCE_SIZE: u64 = 997_051;",
            #""51f9da8faf0eb8d0cd5657254d869dd469c0a9a20d1e2fe6d37e510af42792a3""#,
            "const RETAINED_V10_LAUNCHER_SIZE: u64 = 18_689;",
            #""dc7e0d62118c04e66e33e20caa1e820e355002f321e5fd93daeeabc4e970edb7""#,
            "const RETAINED_V10_CONTRACT_TEST_SIZE: u64 = 167_111;",
            #""6294abb7aa47625e4bf87a3c56845a4327d6dabedddc6b002be0ecf6b8205a98""#,
            "const RETAINED_V10_CONTROLLER_BINARY_SIZE: u64 = 3_121_848;",
            #""536564440b694d90351f094c5a0ce7d8181b6fae46456608cce223e9be049924""#,
        ] {
            XCTAssertTrue(controller.contains(pin), "missing immutable V10 pin: \(pin)")
        }

        let release = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v10_release_files(",
            endingBefore: "// V10 rolled back after its terminal audio-probe timeout"
        )
        assertOrdered([
            "RETAINED_V10_SOURCE_SIZE", "RETAINED_V10_SOURCE_SHA256",
            "RETAINED_V10_LAUNCHER_SIZE", "RETAINED_V10_LAUNCHER_SHA256",
            "RETAINED_V10_CONTRACT_TEST_SIZE", "RETAINED_V10_CONTRACT_TEST_SHA256",
            #"&format!("{RETAINED_V10_SOURCE_COMMIT}^{{tree}}")"#,
            "tree != RETAINED_V10_SOURCE_TREE", "for (relative, size, mode, digest, label) in specs",
            "require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "require_no_acl_or_xattrs(&path)?", "before.len() != size", "sha256(&path)? != digest",
            #"let object = format!("{RETAINED_V10_SOURCE_COMMIT}:{relative}")"#,
            #"&["show", &object]"#, "sha256_bytes(&output.stdout)? != digest",
            "identity_from_metadata(&before) != identity_from_metadata(&after)",
        ], in: release)

        let preflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "verify_retained_v8_release_files(&repo)?",
            "verify_retained_v9_release_files(&repo)?",
            "verify_retained_v10_release_files(&repo)?",
            "verify_candidate()?",
        ], in: preflight)

        let userIdentities = try functionBody(
            controller,
            beginningWith: "fn retained_v10_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v10_descriptor_graph_payload("
        )
        for token in [
            "RETAINED_V10_USER_UPDATE_ROOT_INODE", "RETAINED_V10_EVIDENCE_INODE",
            "RETAINED_V10_PROBES_INODE", "RETAINED_V10_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V10_JOURNAL_INODE", "RETAINED_V10_REQUEST_INODE",
            "RETAINED_V10_READER_INODE", "RETAINED_V10_CONTROLLER_PIN_INODE",
            "RETAINED_V10_CONTROLLER_IDENTITY_INODE", "RETAINED_V10_RESULT_INODE",
            "RETAINED_V10_USER_UPDATE_LOCK_INODE", "identity_from_metadata(&held)",
            "identities.last() != Some(&held_identity)",
        ] {
            XCTAssertTrue(userIdentities.contains(token), "V10 user identity graph omits \(token)")
        }
        XCTAssertEqual(occurrences(of: "(&graph.", in: userIdentities), 12)

        let userPayload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v10_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v10_descriptor_graph("
        )
        assertOrdered([
            "RETAINED_V10_EVIDENCE_LEAF.as_bytes()",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#,
            #"b"journal.log""#, #"b"opensteamer-diagnostic-snapshot-reader""#,
            #"b"probes""#, #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V10_USER_ACTIVE_POINTER_PENDING",
            #"pointer != format!("{RETAINED_V10_EVIDENCE}\n").as_bytes()"#,
            "journal != RETAINED_V10_JOURNAL_TEXT.as_bytes()",
            "request != RETAINED_V10_REQUEST_TEXT.as_bytes()",
            #"pin != format!("{RETAINED_V10_CONTROLLER_BINARY_SHA256}\n").as_bytes()"#,
            "identity != RETAINED_V10_CONTROLLER_IDENTITY_TEXT.as_bytes()",
            "result != RETAINED_V10_RESULT_TEXT.as_bytes()",
            "RETAINED_V10_USER_ACTIVE_POINTER_SHA256", "RETAINED_V10_JOURNAL_SHA256",
            "RETAINED_V10_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V10_CONTROLLER_PIN_SHA256", "RETAINED_V10_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V10_RESULT_SHA256",
        ], in: userPayload)

        let userProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v10_descriptor_graph(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "retained_v10_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v10_descriptor_graph_payload(graph)?",
            "retained_v10_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v10_descriptor_graph_payload(graph)?",
            "retained_v10_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v10_user_rolled_back_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v10_user_rolled_back_once(held_lock)?",
        ], in: userProof)

        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v10_root_node_specs()",
            endingBefore: "fn validate_retained_v10_root_identity("
        )
        XCTAssertEqual(occurrences(of: "        file(", in: rootSpecs), 23)
        XCTAssertEqual(occurrences(of: "        directory(", in: rootSpecs), 17)
        for token in [
            "29_658_583", "29_658_584", "29_658_585", "29_658_586", "29_658_587",
            "29_658_588", "29_658_591", "29_658_592", "29_658_593", "29_658_964",
            "29_658_956", "29_658_957", "29_658_958", "29_658_959", "29_658_960",
            "29_658_961", "29_658_962", "29_658_987", "29_658_988", "29_658_989",
            "29_658_990", "29_658_991", "29_658_992", "29_658_993", "29_658_994",
            "29_658_995", "29_658_996", "29_658_997", "29_658_998", "29_658_999",
            "29_659_000", "29_659_001", "29_659_106", "29_659_176", "29_659_195",
            "29_659_196", "29_661_653", "29_661_654", "29_661_655",
            "RETAINED_V10_ROOT_UPDATE_LOCK_INODE", "RETAINED_V10_ROOT_ACTIVE_POINTER_SHA256",
            "RETAINED_V10_ROOT_JOURNAL_SHA256", "RETAINED_V10_ROOT_STATE_SHA256",
            "RETAINED_V10_ROOT_RESULT_SHA256", "RETAINED_V10_POST_RELOAD_ROUTE_SHA256",
            "RETAINED_V10_OSDS_BEFORE_SHA256", "RETAINED_V10_PROBE_SHA256",
            "RETAINED_V10_PROBE_SIZE",
        ] {
            XCTAssertTrue(rootSpecs.contains(token), "V10 root manifest omits \(token)")
        }

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v10_root_graph_once(",
            endingBefore: "// Root-side V11 proof pins"
        )
        assertOrdered([
            "if specs.len() != 40", "collect_retained_v10_root_node_identities",
            "let child_sets = vec![", "for (path, expected, label) in child_sets",
            "require_retained_v4_root_children", "RETAINED_V10_ROOT_ACTIVE_POINTER_PENDING",
            #"transaction.join("journal.log.pending")"#,
            #"transaction.join("prestop-abort-journal.txt")"#,
            #"transaction.join("recovery-result.txt")"#,
            #"transaction.join("probes/osds-after-mirror.json")"#,
            #"transaction.join("probes/both-order-result-drop/both-order.json")"#,
            "require_retained_v4_root_absent", "hash_retained_v4_root_file",
            "collect_retained_v10_root_node_identities", "if before != after",
            "fn uid501_verify_retained_v10_root_rolled_back()",
            "verify_retained_v10_root_graph_once(true, None)?",
            "fn verify_retained_v10_root_rolled_back(",
            "verify_retained_v10_root_graph_once(false, Some(held_root_lock))?",
        ], in: rootProof)
        XCTAssertEqual(occurrences(of: #"], ""#, in: rootProof), 17)

        for immutableProof in [release, userProof, rootProof] {
            for forbidden in [
                "write_new_private(", "write_atomic_replace(", "fs::remove_file(",
                "fs::remove_dir(", ".create(true)", ".truncate(true)",
            ] {
                XCTAssertFalse(
                    immutableProof.contains(forbidden),
                    "retained V10 proof gained a mutation surface: \(forbidden)"
                )
            }
        }
    }

    func testRetainedV11ReleaseUserAndRootGraphsAreExactAndImmutable() throws {
        let controller = try source(controllerPath)
        let retainedFiles: [(String, Int, String)] = [
            (
                retainedV11SourcePath,
                1_062_512,
                "a5d5d037f0f0d5804cef2a01bdd3cb8c18de99b3dc6b54d72af6e2d5d87f5eb0"
            ),
            (
                retainedV11LauncherPath,
                18_689,
                "6a76e969e1d037f5e1b0fc4bbdd26793716585a972c11dd638a62c2ee521763a"
            ),
            (
                retainedV11ContractPath,
                191_093,
                "deeaf25b49cfdeaf619121cd0b80792f731361a6daec90975bf8227dfbcfbc6c"
            ),
        ]
        for (path, size, digest) in retainedFiles {
            let bytes = try data(path)
            XCTAssertEqual(bytes.count, size, "retained V11 file size changed: \(path)")
            XCTAssertEqual(sha256Hex(bytes), digest, "retained V11 file bytes changed: \(path)")
        }

        for pin in [
            #"const RETAINED_V11_SOURCE_COMMIT: &str = "a726cf0b758c28fa2122d5ecf095de76f6af48fa";"#,
            #"const RETAINED_V11_SOURCE_TREE: &str = "23e3913dd9b4e8ba2f1052cf7a96d1684e54d7c3";"#,
            "const RETAINED_V11_SOURCE_SIZE: u64 = 1_062_512;",
            #""a5d5d037f0f0d5804cef2a01bdd3cb8c18de99b3dc6b54d72af6e2d5d87f5eb0""#,
            "const RETAINED_V11_LAUNCHER_SIZE: u64 = 18_689;",
            #""6a76e969e1d037f5e1b0fc4bbdd26793716585a972c11dd638a62c2ee521763a""#,
            "const RETAINED_V11_CONTRACT_TEST_SIZE: u64 = 191_093;",
            #""deeaf25b49cfdeaf619121cd0b80792f731361a6daec90975bf8227dfbcfbc6c""#,
            "const RETAINED_V11_CONTROLLER_BINARY_SIZE: u64 = 3_281_208;",
            #""0b76b8411a6f504d9210a28977363aab5d8af03bae0144d3fcb4b50a31fb3403""#,
            "const RETAINED_V11_PROBE_SIZE: u64 = 1_096_944;",
            #""b344eb24cde4ab1881b065e2ef0aa208aef12dbdd31fea7259eabc5ad5b6abaf""#,
        ] {
            XCTAssertTrue(controller.contains(pin), "missing immutable V11 pin: \(pin)")
        }

        let release = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v11_release_files(",
            endingBefore: "// V11 rolled back after its terminal audio-probe timeout"
        )
        assertOrdered([
            "RETAINED_V11_SOURCE_SIZE", "RETAINED_V11_SOURCE_SHA256",
            "RETAINED_V11_LAUNCHER_SIZE", "RETAINED_V11_LAUNCHER_SHA256",
            "RETAINED_V11_CONTRACT_TEST_SIZE", "RETAINED_V11_CONTRACT_TEST_SHA256",
            #"&format!("{RETAINED_V11_SOURCE_COMMIT}^{{tree}}")"#,
            "tree != RETAINED_V11_SOURCE_TREE",
            "for (relative, size, mode, digest, label) in specs",
            "require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "require_no_acl_or_xattrs(&path)?", "before.len() != size",
            "sha256(&path)? != digest",
            #"let object = format!("{RETAINED_V11_SOURCE_COMMIT}:{relative}")"#,
            #"&["show", &object]"#, "sha256_bytes(&output.stdout)? != digest",
            "identity_from_metadata(&before) != identity_from_metadata(&after)",
        ], in: release)

        let preflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "verify_retained_v10_release_files(&repo)?",
            "verify_retained_v11_release_files(&repo)?",
            "verify_candidate()?",
        ], in: preflight)

        let userIdentities = try functionBody(
            controller,
            beginningWith: "fn retained_v11_descriptor_graph_identities(",
            endingBefore: "fn verify_retained_v11_descriptor_graph_payload("
        )
        for token in [
            "RETAINED_V11_USER_UPDATE_ROOT_INODE", "RETAINED_V11_EVIDENCE_INODE",
            "RETAINED_V11_PROBES_INODE", "RETAINED_V11_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V11_JOURNAL_INODE", "RETAINED_V11_REQUEST_INODE",
            "RETAINED_V11_READER_INODE", "RETAINED_V11_CONTROLLER_PIN_INODE",
            "RETAINED_V11_CONTROLLER_IDENTITY_INODE", "RETAINED_V11_RESULT_INODE",
            "RETAINED_V11_USER_UPDATE_LOCK_INODE", "identity_from_metadata(&held)",
            "identities.last() != Some(&held_identity)",
        ] {
            XCTAssertTrue(userIdentities.contains(token), "V11 user identity graph omits \(token)")
        }
        XCTAssertEqual(occurrences(of: "(&graph.", in: userIdentities), 12)

        let userPayload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v11_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v11_descriptor_graph("
        )
        assertOrdered([
            "RETAINED_V11_EVIDENCE_LEAF.as_bytes()",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#,
            #"b"journal.log""#, #"b"opensteamer-diagnostic-snapshot-reader""#,
            #"b"probes""#, #"b"result.txt""#, #"b"root-request.txt""#,
            "require_retained_descriptor_children(&graph.probes, &[]",
            "RETAINED_V11_USER_ACTIVE_POINTER_PENDING",
            #"pointer != format!("{RETAINED_V11_EVIDENCE}\n").as_bytes()"#,
            "journal != RETAINED_V11_JOURNAL_TEXT.as_bytes()",
            "request != RETAINED_V11_REQUEST_TEXT.as_bytes()",
            #"pin != format!("{RETAINED_V11_CONTROLLER_BINARY_SHA256}\n").as_bytes()"#,
            "identity != RETAINED_V11_CONTROLLER_IDENTITY_TEXT.as_bytes()",
            "result != RETAINED_V11_RESULT_TEXT.as_bytes()",
            "RETAINED_V11_USER_ACTIVE_POINTER_SHA256", "RETAINED_V11_JOURNAL_SHA256",
            "RETAINED_V11_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V11_CONTROLLER_PIN_SHA256", "RETAINED_V11_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V11_RESULT_SHA256",
        ], in: userPayload)

        let userProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v11_descriptor_graph(",
            endingBefore: "#[derive(Clone, Debug, Eq, PartialEq)]\nstruct RetainedV1RootAttestation"
        )
        assertOrdered([
            "retained_v11_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v11_descriptor_graph_payload(graph)?",
            "retained_v11_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v11_descriptor_graph_payload(graph)?",
            "retained_v11_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v11_user_rolled_back_once(held_lock)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v11_user_rolled_back_once(held_lock)?",
        ], in: userProof)

        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v11_root_node_specs()",
            endingBefore: "fn validate_retained_v11_root_identity("
        )
        XCTAssertEqual(occurrences(of: "        file(", in: rootSpecs), 23)
        XCTAssertEqual(occurrences(of: "        directory(", in: rootSpecs), 17)
        for token in [
            "29_703_827", "29_703_828", "29_703_829", "29_703_830", "29_703_831",
            "29_703_832", "29_703_835", "29_703_836", "29_703_837", "29_704_818",
            "29_704_819", "29_704_820", "29_704_821", "29_704_822", "29_704_823",
            "29_704_824", "29_704_826", "29_704_832", "29_704_833", "29_704_834",
            "29_704_835", "29_704_836", "29_704_837", "29_704_838", "29_704_839",
            "29_704_840", "29_704_841", "29_704_842", "29_704_843", "29_704_844",
            "29_704_845", "29_704_846", "29_704_851", "29_705_037", "29_705_075",
            "29_705_076", "29_705_156", "29_705_157", "29_705_158",
            "RETAINED_V11_ROOT_UPDATE_LOCK_INODE", "RETAINED_V11_ROOT_ACTIVE_POINTER_SHA256",
            "RETAINED_V11_ROOT_JOURNAL_SHA256", "RETAINED_V11_ROOT_STATE_SHA256",
            "RETAINED_V11_ROOT_RESULT_SHA256", "RETAINED_V11_POST_RELOAD_ROUTE_SHA256",
            "RETAINED_V11_OSDS_BEFORE_SHA256", "RETAINED_V11_PROBE_SHA256",
            "RETAINED_V11_PROBE_SIZE",
        ] {
            XCTAssertTrue(rootSpecs.contains(token), "V11 root manifest omits \(token)")
        }

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v11_root_graph_once(",
            endingBefore: "fn verify_prebuilt_diagnostic_reader("
        )
        assertOrdered([
            "if specs.len() != 40", "collect_retained_v11_root_node_identities",
            "let child_sets = vec![", "for (path, expected, label) in child_sets",
            "require_retained_v4_root_children", "RETAINED_V11_ROOT_ACTIVE_POINTER_PENDING",
            #"transaction.join("journal.log.pending")"#,
            #"transaction.join("prestop-abort-journal.txt")"#,
            #"transaction.join("recovery-result.txt")"#,
            #"transaction.join("probes/osds-after-mirror.json")"#,
            #"transaction.join("probes/both-order-result-drop/both-order.json")"#,
            "require_retained_v4_root_absent", "hash_retained_v4_root_file",
            "collect_retained_v11_root_node_identities", "if before != after",
            "fn uid501_verify_retained_v11_root_rolled_back()",
            "verify_retained_v11_root_graph_once(true, None)?",
            "fn verify_retained_v11_root_rolled_back(",
            "verify_retained_v11_root_graph_once(false, Some(held_root_lock))?",
        ], in: rootProof)
        XCTAssertEqual(occurrences(of: #"], ""#, in: rootProof), 17)

        for immutableProof in [release, userProof, rootProof] {
            for forbidden in [
                "write_new_private(", "write_atomic_replace(", "fs::remove_file(",
                "fs::remove_dir(", ".create(true)", ".truncate(true)",
            ] {
                XCTAssertFalse(
                    immutableProof.contains(forbidden),
                    "retained V11 proof gained a mutation surface: \(forbidden)"
                )
            }
        }
    }

    func testRetainedV8V9V10AndV11LocksSpanPreflightForwardAndSealedRecoveryLifetimes() throws {
        let controller = try source(controllerPath)

        let preflight = try functionBody(
            controller,
            beginningWith: "fn preflight(",
            endingBefore: "fn build_diagnostic_reader("
        )
        assertOrdered([
            "acquire_retained_v7_user_update_lock()?",
            "acquire_retained_v8_user_update_lock()?",
            "acquire_retained_v9_user_update_lock()?",
            "acquire_retained_v10_user_update_lock()?",
            "verify_complete_preflight(", "&retained_v8_lock", "&retained_v9_lock",
            "&retained_v10_lock",
            "retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11=immutable",
        ], in: preflight)

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v5_user_update_lock()?",
            "acquire_retained_v6_user_update_lock()?",
            "acquire_retained_v7_user_update_lock()?",
            "acquire_retained_v8_user_update_lock()?",
            "acquire_retained_v9_user_update_lock()?",
            "acquire_retained_v10_user_update_lock()?", "let _lock = acquire_user_update_lock()?",
            "verify_retained_v8_user_rolled_back_once(&retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt_once(&retained_v9_lock)?",
            "verify_retained_v10_user_rolled_back_once(&retained_v10_lock)?",
            "verify_retained_v8_descriptor_graph(&dispatch_retained_v8_guard, &retained_v8_lock)?",
            "verify_retained_v9_descriptor_graph(&dispatch_retained_v9_guard, &retained_v9_lock)?",
            "verify_retained_v10_descriptor_graph(&dispatch_retained_v10_guard, &retained_v10_lock)?",
            "run_sudo_helper(&root_controller, ROOT_MODE",
            "verify_retained_v8_user_rolled_back_once(&retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt_once(&retained_v9_lock)?",
            "verify_retained_v10_user_rolled_back_once(&retained_v10_lock)?",
            #""retained v8 user boundary changed across root dispatch""#,
            "verify_retained_v9_descriptor_graph(&post_dispatch_retained_v9_guard, &retained_v9_lock)?",
            #""retained v9 user boundary changed across root dispatch""#,
            "verify_retained_v10_descriptor_graph(",
            "&post_dispatch_retained_v10_guard,",
            #""retained v10 user boundary changed across root dispatch""#,
        ], in: execute)

        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v4_root_update_lock()?",
            "acquire_retained_v5_root_update_lock()?",
            "acquire_retained_v6_root_update_lock()?",
            "acquire_retained_v7_root_update_lock()?",
            "acquire_retained_v8_root_update_lock()?",
            "acquire_retained_v9_root_update_lock()?",
            "acquire_retained_v10_root_update_lock()?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)?",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)?",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)?",
            "let initial = verify_live_current_host()?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)?",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)?",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)?",
            "let outcome = match transaction",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)? != retained_v8",
            #""retained v8 root boundary changed across the V12 cutover/rollback""#,
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)? != retained_v9",
            #""retained v9 root boundary changed across the V12 cutover/rollback""#,
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)? != retained_v10",
            #""retained v10 root boundary changed across the V12 cutover/rollback""#,
        ], in: rootTransaction)

        let publicRollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn complete_root_recovery("
        )
        assertOrdered([
            "acquire_retained_v5_user_update_lock()?",
            "acquire_retained_v6_user_update_lock()?",
            "acquire_retained_v7_user_update_lock()?",
            "acquire_retained_v8_user_update_lock()?",
            "acquire_retained_v9_user_update_lock()?",
            "acquire_retained_v10_user_update_lock()?",
            "uid501_verify_retained_v8_root_rolled_back()?",
            "uid501_verify_retained_v9_root_prestop_attempt()?",
            "uid501_verify_retained_v10_root_rolled_back()?",
            "verify_retained_v8_user_rolled_back(&retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt(&retained_v9_lock)?",
            "verify_retained_v10_user_rolled_back(&retained_v10_lock)?",
            "let _lock = acquire_user_update_lock()?",
            "verify_retained_v8_user_rolled_back_once(&retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt_once(&retained_v9_lock)?",
            "verify_retained_v10_user_rolled_back_once(&retained_v10_lock)?",
            "run_sudo_helper(", "ROOT_SEALED_ROLLBACK_MODE",
            "verify_retained_v8_user_rolled_back_once(&retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt_once(&retained_v9_lock)?",
            "verify_retained_v10_user_rolled_back_once(&retained_v10_lock)?",
            #""retained v8 user boundary changed across sealed root recovery""#,
            "verify_retained_v9_descriptor_graph(&post_recovery_retained_v9, &retained_v9_lock)?",
            #""retained v9 user boundary changed across sealed root recovery""#,
            "verify_retained_v10_descriptor_graph(",
            "&post_recovery_retained_v10,",
            #""retained v10 user boundary changed across sealed root recovery""#,
        ], in: publicRollback)

        let sealedRecovery = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn require_self_test_rejection<"
        )
        assertOrdered([
            "let _root_lock = acquire_root_update_lock()?",
            "acquire_retained_v4_root_update_lock()?",
            "acquire_retained_v5_root_update_lock()?",
            "acquire_retained_v6_root_update_lock()?",
            "acquire_retained_v7_root_update_lock()?",
            "acquire_retained_v8_root_update_lock()?",
            "acquire_retained_v9_root_update_lock()?",
            "acquire_retained_v10_root_update_lock()?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)?",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)?",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)?",
            "reconcile_root_pointer_for_recovery(&locator_request)?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)? != retained_v8",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)? != retained_v9",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)? != retained_v10",
            "finalize_sealed_bootstrap_without_root_pointer(&fixed_digest)?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)? != retained_v8",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)? != retained_v9",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)? != retained_v10",
            "parse_sealed_root_request(&layout.recovery_request)?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)? != retained_v8",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)? != retained_v9",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)? != retained_v10",
            "complete_root_recovery(request, layout)?",
            "verify_retained_v8_root_rolled_back(&retained_v8_root_lock)? != retained_v8",
            "verify_retained_v9_root_prestop_attempt(&retained_v9_root_lock)? != retained_v9",
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)? != retained_v10",
        ], in: sealedRecovery)

        let journalFields = try functionBody(
            controller,
            beginningWith: "fn root_authenticated_journal_fields(",
            endingBefore: "fn perform_root_transaction("
        )
        assertOrdered([
            #""retained_v8_journal_sha256""#, "RETAINED_V8_JOURNAL_SHA256",
            #""retained_v8_root_journal_sha256""#, "RETAINED_V8_ROOT_JOURNAL_SHA256",
            #""retained_v8_locator_device""#, "retained_v8.nodes[0].device",
            #""retained_v8_locator_inode""#, "retained_v8.nodes[0].inode",
            #""retained_v8_request_sha256""#, "RETAINED_V8_REQUEST_SHA256",
            #""retained_v9_journal_sha256""#, "RETAINED_V9_JOURNAL_SHA256",
            #""retained_v9_result_sha256""#, "RETAINED_V9_RESULT_SHA256",
            #""retained_v9_locator_device""#, "retained_v9.nodes[0].device",
            #""retained_v9_locator_inode""#, "retained_v9.nodes[0].inode",
            #""retained_v9_request_sha256""#, "RETAINED_V9_REQUEST_SHA256",
            #""retained_v10_journal_sha256""#, "RETAINED_V10_JOURNAL_SHA256",
            #""retained_v10_root_journal_sha256""#, "RETAINED_V10_ROOT_JOURNAL_SHA256",
            #""retained_v10_result_sha256""#, "RETAINED_V10_RESULT_SHA256",
            #""retained_v10_locator_device""#, "retained_v10.nodes[0].device",
            #""retained_v10_locator_inode""#, "retained_v10.nodes[0].inode",
            #""retained_v10_request_sha256""#, "RETAINED_V10_REQUEST_SHA256",
        ], in: journalFields)

        let journalSchema = try functionBody(
            controller,
            beginningWith: "fn validate_journal_fields(",
            endingBefore: "fn parse_journal_text("
        )
        assertOrdered([
            #""retained_v8_root_journal_sha256""#,
            #""retained_v9_journal_sha256""#,
            #""retained_v9_locator_device""#,
            #""retained_v9_locator_inode""#,
            #""retained_v9_request_sha256""#,
            #""retained_v9_result_sha256""#,
            #""retained_v10_journal_sha256""#,
            #""retained_v10_locator_device""#,
            #""retained_v10_locator_inode""#,
            #""retained_v10_request_sha256""#,
            #""retained_v10_result_sha256""#,
            #""retained_v10_root_journal_sha256""#,
            "if actual != expected",
            #"| "retained_v9_journal_sha256""#,
            #"| "retained_v9_request_sha256""#,
            #"| "retained_v9_result_sha256""#,
            #"| "retained_v10_journal_sha256""#,
            #"| "retained_v10_request_sha256""#,
            #"| "retained_v10_result_sha256""#,
            #"| "retained_v10_root_journal_sha256""#,
            "require_lower_hex(value, 64",
            #"| "retained_v9_locator_device""#,
            #"| "retained_v9_locator_inode""#,
            #"| "retained_v10_locator_device""#,
            #"| "retained_v10_locator_inode""#,
            "require_canonical_positive_decimal(value, \"journal number\")",
        ], in: journalSchema)

        for fixtureToken in [
            "let root_journal = format!(",
            "retained_v9_journal_sha256={}",
            "retained_v9_result_sha256={}",
            "retained_v9_locator_device=16777229",
            "retained_v9_locator_inode=29628341",
            "retained_v9_request_sha256={}",
            "retained_v10_journal_sha256={}",
            "retained_v10_result_sha256={}",
            "retained_v10_locator_device=16777229",
            "retained_v10_locator_inode=29658583",
            "retained_v10_request_sha256={}",
            "retained_v10_root_journal_sha256={}",
            "parse_journal_text(&root_journal, ROOT_JOURNAL_HEADER)? != UpdateState::Committed",
            "let authenticated_line = format!(",
            "require_self_test_rejection(parse_journal_text(&fixture, ROOT_JOURNAL_HEADER), label)?",
        ] {
            XCTAssertTrue(controller.contains(fixtureToken), "missing retained journal-schema fixture: \(fixtureToken)")
        }
    }

    func testRetainedV11GuardsSpanEveryPreflightDispatchAndRecoveryBoundary() throws {
        let controller = try source(controllerPath)

        let preflight = try functionBody(
            controller,
            beginningWith: "fn preflight(",
            endingBefore: "fn build_diagnostic_reader("
        )
        assertOrdered([
            "acquire_retained_v10_user_update_lock()?",
            "acquire_retained_v11_user_update_lock()?",
            "verify_complete_preflight(", "&retained_v11_lock",
            "retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11=immutable",
        ], in: preflight)

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v11_user_update_lock()?",
            "verify_retained_v11_user_rolled_back_once(&retained_v11_lock)?",
            "verify_retained_v11_descriptor_graph(&final_retained_v11_guard, &retained_v11_lock)?",
            "verify_retained_v11_descriptor_graph(&dispatch_retained_v11_guard, &retained_v11_lock)?",
            "run_sudo_helper(&root_controller, ROOT_MODE",
            "verify_retained_v11_user_rolled_back_once(&retained_v11_lock)?",
            "verify_retained_v11_descriptor_graph(", "&post_dispatch_retained_v11_guard,",
            #""retained v11 user boundary changed across root dispatch""#,
        ], in: execute)

        let publicRollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn complete_root_recovery("
        )
        assertOrdered([
            "acquire_retained_v11_user_update_lock()?",
            "uid501_verify_retained_v11_root_rolled_back()?",
            "verify_retained_v11_user_rolled_back(&retained_v11_lock)?",
            "verify_retained_v11_user_rolled_back_once(&retained_v11_lock)?",
            "run_sudo_helper(", "ROOT_SEALED_ROLLBACK_MODE",
            "verify_retained_v11_user_rolled_back_once(&retained_v11_lock)?",
            "verify_retained_v11_descriptor_graph(", "&post_recovery_retained_v11,",
            #""retained v11 user boundary changed across sealed root recovery""#,
        ], in: publicRollback)

        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v11_root_update_lock()?",
            "verify_retained_v11_root_rolled_back(&retained_v11_root_lock)?",
            "let initial = verify_live_current_host()?",
            "verify_retained_v11_root_rolled_back(&retained_v11_root_lock)?",
            "let outcome = match transaction",
            "verify_retained_v11_root_rolled_back(&retained_v11_root_lock)? != retained_v11",
            #""retained v11 root boundary changed across the V12 cutover/rollback""#,
        ], in: rootTransaction)

        let sealedRecovery = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "fn require_self_test_rejection<"
        )
        for token in [
            "acquire_retained_v11_root_update_lock()?",
            "verify_retained_v11_root_rolled_back(&retained_v11_root_lock)?",
            "reconcile_root_pointer_for_recovery(&locator_request)?",
            "finalize_sealed_bootstrap_without_root_pointer(&fixed_digest)?",
            "parse_sealed_root_request(&layout.recovery_request)?",
            "complete_root_recovery(request, layout)?",
            "retained v11 root boundary changed",
        ] {
            XCTAssertTrue(sealedRecovery.contains(token), "sealed recovery omits V11 guard: \(token)")
        }

        let journalFields = try functionBody(
            controller,
            beginningWith: "fn root_authenticated_journal_fields(",
            endingBefore: "fn perform_root_transaction("
        )
        assertOrdered([
            #""retained_v11_journal_sha256""#, "RETAINED_V11_JOURNAL_SHA256",
            #""retained_v11_root_journal_sha256""#, "RETAINED_V11_ROOT_JOURNAL_SHA256",
            #""retained_v11_result_sha256""#, "RETAINED_V11_RESULT_SHA256",
            #""retained_v11_locator_device""#, "retained_v11.nodes[0].device",
            #""retained_v11_locator_inode""#, "retained_v11.nodes[0].inode",
            #""retained_v11_request_sha256""#, "RETAINED_V11_REQUEST_SHA256",
        ], in: journalFields)
        let journalSchema = try functionBody(
            controller,
            beginningWith: "fn validate_journal_fields(",
            endingBefore: "fn parse_journal_text("
        )
        for token in [
            #""retained_v11_journal_sha256""#, #""retained_v11_root_journal_sha256""#,
            #""retained_v11_result_sha256""#, #""retained_v11_locator_device""#,
            #""retained_v11_locator_inode""#, #""retained_v11_request_sha256""#,
        ] {
            XCTAssertTrue(journalSchema.contains(token), "journal schema omits V11 field: \(token)")
        }
    }

    func testMirrorLoopbackProductionWriterIsDescriptorRelativeDurableAndChecked() throws {
        let probe = try source(probeSourcePath)
        let writer = try functionBody(
            probe,
            beginningWith: "private enum MirrorLoopbackWriter {",
            endingBefore: "private struct MirrorLoopbackWriterCanaryResult"
        )
        assertOrdered([
            #"static let resultLeaf = "both-order.json""#,
            "maximumEncodedByteCount = 1_048_576",
            "let directoryDescriptor = Darwin.open(", #"".""#,
            "O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW",
            "Darwin.openat(",
            "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC",
            "mode_t(0o600)", "while offset < buffer.count", "if errno == EINTR",
            "Darwin.fsync(outputDescriptor)",
            "let closeStatus = Darwin.close(outputDescriptor)",
            "outputIsOpen = false", "guard closeStatus == 0",
            "Darwin.renameatx_np(", "UInt32(RENAME_EXCL)",
            "temporaryExists = false", "Darwin.fsync(directoryDescriptor)",
        ], in: writer)
        let cleanup = try functionBody(
            writer,
            beginningWith: "private static func cleanupTemporary(",
            endingBefore: "static func write("
        )
        assertOrdered([
            "if outputIsOpen", "let closeStatus = Darwin.close(outputDescriptor)",
            "outputIsOpen = false", "cleanupFailure = .cleanupClose",
            "if temporaryExists", "Darwin.unlinkat(", "temporaryExists = false",
            "cleanupFailure = .cleanupUnlink", "Darwin.fsync(directoryDescriptor)",
            "cleanupFailure = .cleanupDirectorySync", "return cleanupFailure",
        ], in: cleanup)
        assertOrdered([
            "catch let originalFailure as Failure", "cleanupTemporary(",
            "throw cleanupFailure", "throw originalFailure",
        ], in: writer)
        for stage in [
            #"case .cleanupClose: return "cleanup-close""#,
            #"case .cleanupUnlink: return "cleanup-unlink""#,
            #"case .cleanupDirectorySync: return "cleanup-directory-sync""#,
            #"case .selfTestWrite: return "self-test-write""#,
        ] {
            XCTAssertTrue(writer.contains(stage), "writer omits canonical failure stage: \(stage)")
        }
        for forbidden in [
            "URL(", "URL(fileURLWithPath:", "FileManager", "getcwd(",
            ".path", "createDirectory(", "removeItem(", "Darwin.rename(",
        ] {
            XCTAssertFalse(writer.contains(forbidden), "production writer traverses a path: \(forbidden)")
        }

        let program = try functionBody(
            probe,
            beginningWith: "private enum MirrorLoopbackProgram {",
            endingBefore: "if let status = DefaultUIDSnapshotProgram.runIfRequested()"
        )
        assertOrdered([
            #"command == "mirror-loopback-writer-canary""#,
            "try validateResultLeaf(resultPath)", "let encodedCanary = try encodeForRelativeWriter(",
            "try MirrorLoopbackWriter.write(",
            #"if command == "mirror-loopback""#, "try validateResultLeaf(resultPath)",
            "let encodedResult = try encodeForRelativeWriter(result)",
            "try MirrorLoopbackWriter.write(",
            "throw MirrorLoopbackWriter.Failure.selfTestWrite",
            "catch let error as MirrorLoopbackWriter.Failure",
            "reportWriterFailure(stage: error.stage)", "return 74",
        ], in: program)
        XCTAssertFalse(program.contains(
            "throw MirrorLoopbackWriter.Failure.invalidEncodedResult\n                }\n            }"
        ))
        XCTAssertTrue(program.contains(
            #"OPENSTEAMER_MIRROR_LOOPBACK_WRITER_ERROR_V1 stage=\(stage)\n"#
        ))

        let probeBytes = try Data(contentsOf: URL(fileURLWithPath: v12ProbePath))
        XCTAssertEqual(probeBytes.count, 1_130_432)
        XCTAssertEqual(
            sha256Hex(probeBytes),
            "6a258902753b2606f599a306b1fcf3eec149554f40e5e0ce34902e21e7405ab5"
        )
        XCTAssertTrue(try source(controllerPath).contains(
            #"const BOTH_ORDER_PROBE_SIZE: u64 = 1_130_432;"#
        ))
        XCTAssertTrue(try source(controllerPath).contains(
            #""6a258902753b2606f599a306b1fcf3eec149554f40e5e0ce34902e21e7405ab5""#
        ))
    }

    func testPinnedWriterCanaryWorksBeneathNontraversableAncestorAndRejectsMutations() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("opensteamer-v12-writer-tests-\(UUID().uuidString)")
        let privateAncestor = temporaryRoot.appendingPathComponent("private-ancestor")
        let inheritedWorkingDirectory = privateAncestor.appendingPathComponent("drop")
        try fileManager.createDirectory(
            at: inheritedWorkingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        func chmodPath(_ path: String, _ mode: mode_t) -> Int32 {
            path.withCString { Darwin.chmod($0, mode) }
        }
        defer {
            _ = chmodPath(privateAncestor.path, mode_t(0o700))
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let nonce = "v12-nontraversable-writer-canary-001"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"cd "$1" || exit 97; chmod 000 "$2" || exit 98; exec "$3" mirror-loopback-writer-canary --nonce "$4" --result both-order.json"#,
            "v12-relative-writer", inheritedWorkingDirectory.path,
            privateAncestor.path, v12ProbePath, nonce,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        let denied = inheritedWorkingDirectory.path.withCString {
            Darwin.access($0, F_OK)
        }
        let deniedErrno = errno
        XCTAssertEqual(denied, -1)
        XCTAssertEqual(deniedErrno, EACCES)
        XCTAssertEqual(chmodPath(privateAncestor.path, mode_t(0o700)), 0)
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        XCTAssertTrue(output.isEmpty)
        XCTAssertTrue(error.isEmpty)

        let result = inheritedWorkingDirectory.appendingPathComponent("both-order.json")
        let expected = """
        {
          "nonce" : "\(nonce)",
          "schema" : "opensteamer.mirror-loopback-relative-writer-canary.v1",
          "status" : "passed"
        }
        """
        XCTAssertEqual(try Data(contentsOf: result), Data(expected.utf8))
        let attributes = try fileManager.attributesOfItem(atPath: result.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.intValue, 501)
        XCTAssertEqual((attributes[.groupOwnerAccountID] as? NSNumber)?.intValue, 20)

        func runProbe(_ arguments: [String], in directory: URL) throws -> (Int32, Data, Data) {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: v12ProbePath)
            child.arguments = arguments
            child.currentDirectoryURL = directory
            let childStdout = Pipe()
            let childStderr = Pipe()
            child.standardOutput = childStdout
            child.standardError = childStderr
            try child.run()
            child.waitUntilExit()
            return (
                child.terminationStatus,
                childStdout.fileHandleForReading.readDataToEndOfFile(),
                childStderr.fileHandleForReading.readDataToEndOfFile()
            )
        }

        let invalidDirectory = temporaryRoot.appendingPathComponent("invalid")
        try fileManager.createDirectory(at: invalidDirectory, withIntermediateDirectories: false)
        let invalid = try runProbe([
            "mirror-loopback-writer-canary", "--nonce", "v12-invalid-leaf-canary-001",
            "--result", "../both-order.json",
        ], in: invalidDirectory)
        XCTAssertEqual(invalid.0, 64)
        XCTAssertTrue(invalid.1.isEmpty)
        XCTAssertFalse(invalid.2.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: temporaryRoot.appendingPathComponent("both-order.json").path))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: invalidDirectory.path), [])

        let collisionDirectory = temporaryRoot.appendingPathComponent("collision")
        try fileManager.createDirectory(at: collisionDirectory, withIntermediateDirectories: false)
        let occupied = collisionDirectory.appendingPathComponent("both-order.json")
        try Data("occupied\n".utf8).write(to: occupied)
        let collision = try runProbe([
            "mirror-loopback-writer-canary", "--nonce", "v12-collision-canary-001",
            "--result", "both-order.json",
        ], in: collisionDirectory)
        XCTAssertEqual(collision.0, 74)
        XCTAssertTrue(collision.1.isEmpty)
        XCTAssertEqual(
            String(decoding: collision.2, as: UTF8.self),
            "OPENSTEAMER_MIRROR_LOOPBACK_WRITER_ERROR_V1 stage=rename\n"
        )
        XCTAssertEqual(try Data(contentsOf: occupied), Data("occupied\n".utf8))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: collisionDirectory.path), ["both-order.json"])
    }

    func testDisplayHelpersStayAquaWhileAuthorizationAndLoopbackUseDirectUID501Audio() throws {
        let controller = try source(controllerPath)
        for token in [
            #"const AQUA_UID501_HAL_EXEC_MODE: &str = "--aqua-root-drop-uid501-exec-hal-child";"#,
            #"("HOME", "/Users/ahmed")"#, #"("USER", "ahmed")"#,
            #"("LOGNAME", "ahmed")"#, #"("LC_ALL", "C")"#,
            #"("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")"#,
            #"("__CF_USER_TEXT_ENCODING", "0x1F5:0x0:0x0")"#,
        ] {
            XCTAssertTrue(controller.contains(token), "missing Aqua contract token: \(token)")
        }

        let environment = try functionBody(
            controller,
            beginningWith: "fn configure_exact_uid501_hal_environment(",
            endingBefore: "fn drop_aqua_hal_dispatcher_to_uid501("
        )
        assertOrdered([
            "command.env_clear()", "for (name, value) in UID501_HAL_ENVIRONMENT",
            "command.env(name, value)",
        ], in: environment)
        for forbidden in [
            "_NSGetEnviron", "setenv(", "install_exact_uid501_hal_environment",
            "*environment = std::ptr::null_mut()",
        ] {
            XCTAssertFalse(controller.contains(forbidden), "unsafe process environment mutation survived: \(forbidden)")
        }

        let credentialDrop = try functionBody(
            controller,
            beginningWith: "fn drop_aqua_hal_dispatcher_to_uid501(",
            endingBefore: "fn aqua_root_drop_uid501_exec_hal_child("
        )
        assertOrdered([
            "getuid() } != ROOT_ID", "geteuid() } != ROOT_ID", "let groups = [USER_GROUP]",
            "setgroups(1, groups.as_ptr())", "setgid(USER_GROUP)", "setuid(USER_ID)",
            "getgroups(", "getuid() } != USER_ID", "geteuid() } != USER_ID",
            "getgid() } != USER_GROUP", "getegid() } != USER_GROUP", "group_count != 1",
            "observed_groups[0] != USER_GROUP", "Ok(())",
        ], in: credentialDrop)

        let allowlist = try functionBody(
            controller,
            beginningWith: "fn verify_sealed_uid501_hal_program(",
            endingBefore: "fn aqua_root_drop_uid501_exec_hal_child("
        )
        assertOrdered([
            "let current = env::current_exe()?", "if program == current",
            "require_sealed_regular(program, ROOT_SEALED_EXECUTABLE_MODE)?",
            "require_no_acl_or_xattrs(program)?", "identity_from_metadata(&before)",
            "program.strip_prefix(ROOT_PROBE_PARENT)", "relative.components().count() != 2",
            "require_sealed_directory(Path::new(ROOT_PROBE_PARENT), ROOT_SEALED_TRAVERSE_MODE)?",
            "require_sealed_directory(parent, ROOT_SEALED_TRAVERSE_MODE)?",
            #""opensteamer-diagnostic-snapshot-reader""#, "DIAGNOSTIC_READER_SIZE",
            "DIAGNOSTIC_READER_SHA256", #""physical-virtual-microphone-probe""#,
            "BOTH_ORDER_PROBE_SIZE", "BOTH_ORDER_PROBE_SHA256",
            "before.len() != size", "sha256(program)? != digest",
            "identity_from_metadata(&before) != identity_from_metadata(&after)",
        ], in: allowlist)

        let dispatcher = try functionBody(
            controller,
            beginningWith: "fn aqua_root_drop_uid501_exec_hal_child(",
            endingBefore: "#[derive(Debug)]\nenum BoundedHalChildExecution"
        )
        assertOrdered([
            "current_directory.is_absolute()", "Path::new(program).is_absolute()",
            ".custom_flags(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)",
            ".open(current_directory)?", "verify_sealed_uid501_hal_program(Path::new(program))?",
            "fchdir(",
            "drop_aqua_hal_dispatcher_to_uid501()?", "Command::new(program)",
            ".args(arguments)", ".stdin(Stdio::inherit())", ".stdout(Stdio::inherit())",
            ".stderr(Stdio::inherit())", "configure_exact_uid501_hal_environment(&mut command)",
            "command.exec()",
        ], in: dispatcher)
        XCTAssertFalse(dispatcher.contains(".current_dir(current_directory)"))

        let launcher = try functionBody(
            controller,
            beginningWith: "fn bounded_aqua_uid501_hal_output_in_directory(",
            endingBefore: "fn bounded_direct_uid501_audio_output_in_directory("
        )
        assertOrdered([
            "getuid() } != ROOT_ID", "geteuid() } != ROOT_ID", "timeout.is_zero()",
            "let executable = env::current_exe()?", #""asuser".to_owned()"#,
            #""501".to_owned()"#, "path_text(&executable)?.to_owned()",
            "AQUA_UID501_HAL_EXEC_MODE.to_owned()", "path_text(current_directory)?.to_owned()",
            "program.to_owned()", "Command::new(\"/bin/launchctl\")", ".args(&launch_arguments)",
            "configure_exact_uid501_hal_environment(&mut command)", "command.pre_exec",
            "setpgid(0, 0)", ".spawn()", "let process_group = i32::try_from(child.id())",
            "if let Some(status) = child.try_wait()?",
            "hal_child_process_group_exists(process_group)?",
            "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "if Instant::now() >= deadline",
            "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "let (stdout, stdout_exceeded) = stdout_reader", ".join()",
            "let (stderr, stderr_exceeded) = stderr_reader", ".join()",
            "BoundedHalChildExecution::TimedOut", "BoundedHalChildExecution::Completed(Output",
        ], in: launcher)
        XCTAssertEqual(occurrences(of: "configure_exact_uid501_hal_environment(&mut command)", in: dispatcher), 1)
        XCTAssertEqual(occurrences(of: "configure_exact_uid501_hal_environment(&mut command)", in: launcher), 1)

        let direct = try functionBody(
            controller,
            beginningWith: "fn bounded_direct_uid501_audio_output_in_directory(",
            endingBefore: "fn require_completed_hal_child("
        )
        assertOrdered([
            "getuid() } != ROOT_ID", "geteuid() } != ROOT_ID", "timeout.is_zero()",
            "current_directory.is_absolute()", "Path::new(program).is_absolute()",
            ".custom_flags(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)",
            ".open(current_directory)?", "identity_from_metadata(&before_directory)",
            "verify_sealed_uid501_hal_program(Path::new(program))?",
            "let directory_descriptor = directory.as_raw_fd()", "Command::new(program)",
            ".args(arguments)", ".stdin(Stdio::null())", ".stdout(Stdio::piped())",
            ".stderr(Stdio::piped())", "configure_exact_uid501_hal_environment(&mut command)",
            "command.pre_exec(move ||", "fchdir(directory_descriptor)", "setpgid(0, 0)",
            "setgroups(1, groups.as_ptr())", "setgid(USER_GROUP)", "setuid(USER_ID)",
            "getgroups(", "getuid() != USER_ID", "geteuid() != USER_ID",
            "getgid() != USER_GROUP", "getegid() != USER_GROUP", "group_count != 1",
            "observed_groups[0] != USER_GROUP", "command.spawn()", "drop(directory)",
            "let process_group = i32::try_from(child.id())",
            "if let Some(status) = child.try_wait()?",
            "if hal_child_process_group_exists(process_group)?",
            "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "if Instant::now() >= deadline",
            "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "let (stdout, stdout_exceeded) = stdout_reader", ".join()",
            "let (stderr, stderr_exceeded) = stderr_reader", ".join()",
            "BoundedHalChildExecution::TimedOut", "BoundedHalChildExecution::Completed(Output",
        ], in: direct)
        for forbidden in [
            "/bin/launchctl", #""asuser""#, "AQUA_UID501_HAL_EXEC_MODE",
            ".current_dir(current_directory)", "aqua_root_drop_uid501_exec_hal_child",
        ] {
            XCTAssertFalse(direct.contains(forbidden), "direct audio seam gained Aqua boundary: \(forbidden)")
        }
        XCTAssertEqual(
            occurrences(of: "configure_exact_uid501_hal_environment(&mut command)", in: direct),
            1
        )

        let statusDiagnostic = try functionBody(
            controller,
            beginningWith: "fn exit_status_diagnostics(",
            endingBefore: "fn require_success("
        )
        for token in ["status.code()", "status.signal()", "status.core_dumped()"] {
            XCTAssertTrue(statusDiagnostic.contains(token), "missing signal-aware status field: \(token)")
        }
        let requireSuccess = try functionBody(
            controller,
            beginningWith: "fn require_success(",
            endingBefore: "fn command_line_with_timeout("
        )
        XCTAssertTrue(requireSuccess.contains("exit_status_diagnostics(&output.status)"))

        let routeHelper = try functionBody(
            controller,
            beginningWith: "fn run_uid501_fresh_route_helper(",
            endingBefore: "fn classify_fresh_route_helper_execution("
        )
        XCTAssertTrue(routeHelper.contains("bounded_aqua_uid501_hal_output_in_directory("))
        XCTAssertFalse(routeHelper.contains("bounded_direct_uid501_audio_output_in_directory("))
        XCTAssertFalse(routeHelper.contains("bounded_output("))

        let bothOrder = try functionBody(
            controller,
            beginningWith: "fn run_both_order_with_root_held_result(",
            endingBefore: "fn run_passive_driver_validation("
        )
        XCTAssertTrue(bothOrder.contains("bounded_direct_uid501_audio_output_in_directory("))
        XCTAssertTrue(bothOrder.contains("Duration::from_secs(120)"))
        XCTAssertTrue(bothOrder.contains("require_completed_hal_child("))
        XCTAssertFalse(bothOrder.contains("bounded_aqua_uid501_hal_output_in_directory("))
        XCTAssertFalse(bothOrder.contains("/bin/launchctl"))
        XCTAssertFalse(bothOrder.contains("bounded_output_in_directory("))

        let passiveReader = try functionBody(
            controller,
            beginningWith: "fn read_passive_snapshot(",
            endingBefore: "fn verify_mirror_loopback_result("
        )
        XCTAssertTrue(passiveReader.contains("bounded_aqua_uid501_hal_output_in_directory("))
        XCTAssertTrue(passiveReader.contains("require_completed_hal_child("))
        XCTAssertFalse(passiveReader.contains("bounded_direct_uid501_audio_output_in_directory("))
        XCTAssertFalse(passiveReader.contains("bounded_output("))

        let displayHelper = try functionBody(
            controller,
            beginningWith: "fn run_uid501_display_helper(",
            endingBefore: "fn apply_exact_current_virtual_display_mode_local("
        )
        XCTAssertTrue(displayHelper.contains("bounded_aqua_uid501_hal_output_in_directory("))
        XCTAssertFalse(displayHelper.contains("bounded_direct_uid501_audio_output_in_directory("))

        let privateDispatch = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        assertOrdered([
            "mode == UID501_MICROPHONE_AUTHORIZATION_MODE",
            "uid501_microphone_authorization_helper()",
            "[_, mode, current_directory, program, arguments @ ..]",
            "mode == AQUA_UID501_HAL_EXEC_MODE", "aqua_root_drop_uid501_exec_hal_child(",
        ], in: privateDispatch)

        let authorizationAPI = try functionBody(
            controller,
            beginningWith: "fn avfoundation_microphone_authorization_status(",
            endingBefore: "fn uid501_microphone_authorization_helper("
        )
        assertOrdered([
            "unsafe extern \"C\" fn(*mut c_void, *mut c_void, *mut c_void) -> isize",
            #"objc_getClass(c"AVCaptureDevice".as_ptr())"#,
            #"sel_registerName(c"authorizationStatusForMediaType:".as_ptr())"#,
            "let media_type = unsafe { AVMediaTypeAudio }",
            "let raw = unsafe { message(class, selector, media_type) }",
            "MicrophoneAuthorizationStatus::from_raw(raw)",
        ], in: authorizationAPI)
        for forbidden in [
            "requestAccessForMediaType", "requestAccess", "AVCaptureSession", "AudioQueue",
        ] {
            XCTAssertFalse(
                authorizationAPI.contains(forbidden),
                "authorization API can prompt or capture: \(forbidden)"
            )
        }

        let authorizationParser = try functionBody(
            controller,
            beginningWith: "fn require_authorized_microphone_probe_text(",
            endingBefore: "fn avfoundation_microphone_authorization_status("
        )
        assertOrdered([
            "microphone_authorization_probe_text(MicrophoneAuthorizationStatus::Authorized)",
            "if text != expected", "same-responsibility UID501 microphone authorization is not authorized",
        ], in: authorizationParser)
        XCTAssertTrue(controller.contains(
            #""OPENSTEAMER_UID501_MICROPHONE_AUTHORIZATION_V1\nstatus={}\nraw={}\n""#
        ))

        let authorizationHelper = try functionBody(
            controller,
            beginningWith: "fn uid501_microphone_authorization_helper(",
            endingBefore: "fn drop_aqua_hal_dispatcher_to_uid501("
        )
        assertOrdered([
            "getuid() } != USER_ID", "geteuid() } != USER_ID",
            "getgid() } != USER_GROUP", "getegid() } != USER_GROUP",
            "microphone_authorization_probe_text(avfoundation_microphone_authorization_status()?)",
        ], in: authorizationHelper)

        let authorizationProof = try functionBody(
            controller,
            beginningWith: "fn prove_same_responsibility_uid501_microphone_authorization(",
            endingBefore: "fn read_pipe_bounded("
        )
        assertOrdered([
            "getuid() } != ROOT_ID", "geteuid() } != ROOT_ID", "env::current_exe()?",
            "require_completed_hal_child(", "bounded_direct_uid501_audio_output_in_directory(",
            "UID501_MICROPHONE_AUTHORIZATION_MODE", "HAL_CHILD_TIMEOUT", "Path::new(\"/\")",
            "!output.status.success()", "!output.stderr.is_empty()",
            "String::from_utf8(output.stdout)", "require_authorized_microphone_probe_text(&text)",
        ], in: authorizationProof)
        XCTAssertFalse(authorizationProof.contains("bounded_aqua_uid501_hal_output_in_directory("))

        let reducer = try functionBody(
            controller,
            beginningWith: "fn self_test_microphone_authorization_reducer(",
            endingBefore: "fn self_test_exit_status_diagnostics("
        )
        for token in [
            "(0, MicrophoneAuthorizationStatus::NotDetermined)",
            "(1, MicrophoneAuthorizationStatus::Restricted)",
            "(2, MicrophoneAuthorizationStatus::Denied)",
            "(3, MicrophoneAuthorizationStatus::Authorized)",
            "(4, MicrophoneAuthorizationStatus::Unknown(4))",
            "(-1, MicrophoneAuthorizationStatus::Unknown(-1))",
            #"authorized.replace("raw=3\n", "raw=3\ntrailing=1\n")"#,
            #"authorized.replace("raw=3\n", "raw=3\nraw=3\n")"#,
            "require_self_test_rejection(require_authorized_microphone_probe_text(&fixture), label)?",
        ] {
            XCTAssertTrue(reducer.contains(token), "authorization reducer omits hostile case: \(token)")
        }
        XCTAssertFalse(reducer.contains("avfoundation_microphone_authorization_status()"))
        XCTAssertTrue(controller.contains("self_test_microphone_authorization_reducer()?"))

        let journalSchema = try functionBody(
            controller,
            beginningWith: "fn validate_journal_fields(",
            endingBefore: "fn parse_journal_text("
        )
        assertOrdered([
            #""avfoundation_audio_authorization""#,
            #""avfoundation_audio_authorization_raw""#,
            #""avfoundation_audio_authorization" if value == "authorized""#,
            #""avfoundation_audio_authorization_raw" if value == "3""#,
        ], in: journalSchema)
        for token in [
            #""avfoundation_audio_authorization_raw=0""#,
            #""avfoundation_audio_authorization_raw=1""#,
            #""avfoundation_audio_authorization_raw=2""#,
            #""avfoundation_audio_authorization_raw=4""#,
            #""avfoundation_audio_authorization_raw=3x""#,
            #""avfoundation_audio_authorization_raw=3 avfoundation_audio_authorization_raw=3""#,
            #""journal microphone authorization not determined""#,
            #""journal microphone authorization restricted""#,
            #""journal microphone authorization denied""#,
            #""journal microphone authorization unknown""#,
            #""journal microphone authorization trailing data""#,
            #""journal duplicate microphone authorization raw field""#,
        ] {
            XCTAssertTrue(controller.contains(token), "journal authorization fixtures omit: \(token)")
        }

        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "verify_retained_v10_root_rolled_back(&retained_v10_root_lock)?",
            "verify_retained_v11_root_rolled_back(&retained_v11_root_lock)?",
            "verify_rollback_reserve_lease(&layout, &reserve_lease)?",
            "prove_root_private_relative_result_writer(&both_order, &request.nonce, &layout)?",
            "prove_same_responsibility_uid501_microphone_authorization()?",
            "Ok(available_bytes)", "Err(error) =>", "abort_prestop_after_reserve(",
            "write_root_state_tracked(", "UpdateState::HostStopInitiated",
            #""avfoundation_audio_authorization""#, #""authorized".to_owned()"#,
            #""avfoundation_audio_authorization_raw""#, #""3".to_owned()"#,
            "stop_exact_current_host(&initial)?", "publish_candidate_driver(",
            "reload_coreaudio_exact(&baseline_coreaudio)?",
        ], in: transaction)

        let writerCanary = try functionBody(
            controller,
            beginningWith: "fn prove_root_private_relative_result_writer(",
            endingBefore: "// ROOT_HELD_BOTH_ORDER_RESULT:"
        )
        assertOrdered([
            #"layout.root.join("probes")"#,
            #"probes.join("relative-result-writer-canary-drop")"#,
            "O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC",
            "fchown(directory.as_raw_fd(), USER_ID, USER_GROUP)",
            "require_exact_child_names(&drop_directory, &[]",
            "bounded_direct_uid501_audio_output_in_directory(",
            #""mirror-loopback-writer-canary""#, #""--result""#,
            #""both-order.json""#, "HAL_CHILD_TIMEOUT",
            "fchown(descriptor, ROOT_ID, ROOT_ID)",
            "require_success(&output", "!output.stdout.is_empty()",
            "!output.stderr.is_empty()", #"&["both-order.json"]"#,
            "openat(", "O_RDONLY | O_NOFOLLOW | O_CLOEXEC",
            "opensteamer.mirror-loopback-relative-writer-canary.v1",
            "produced.uid() != USER_ID", "produced.gid() != USER_GROUP",
            "produced.permissions().mode() & 0o7777 != 0o600",
            "fchown(result.as_raw_fd(), ROOT_ID, ROOT_ID)", "result.sync_all()?",
        ], in: writerCanary)
        for forbidden in [
            "/bin/launchctl", #""asuser""#, "AudioQueue", "AVCaptureDevice",
        ] {
            XCTAssertFalse(writerCanary.contains(forbidden), "writer canary gained unrelated seam: \(forbidden)")
        }
        XCTAssertTrue(controller.contains("ROOT_PRIVATE_RELATIVE_WRITER_CANARY"))

        let shellLauncher = try source(launcherPath)
        XCTAssertFalse(shellLauncher.contains("--uid501-read-microphone-authorization-status"))
    }

    func testHALTimeoutKillsAndReapsTheCompleteProcessGroup() throws {
        let controller = try source(controllerPath)
        for token in [
            "const HAL_CHILD_TIMEOUT: Duration = Duration::from_secs(3);",
            "const POST_RELOAD_AFTER_GENERATION_RESERVE: Duration = Duration::from_secs(2);",
            "const HAL_CHILD_TERMINATION_GRACE: Duration = Duration::from_millis(250);",
            "enum BoundedHalChildExecution", "Completed(Output)", "TimedOut",
        ] {
            XCTAssertTrue(controller.contains(token), "missing bounded HAL child token: \(token)")
        }

        let cap = try functionBody(
            controller,
            beginningWith: "fn hal_child_timeout_preserving_after_generation_reserve(",
            endingBefore: "fn hal_child_process_group_exists("
        )
        assertOrdered([
            "let remaining = deadline", ".checked_duration_since(Instant::now())",
            ".checked_sub(POST_RELOAD_AFTER_GENERATION_RESERVE)",
            ".filter(|duration| !duration.is_zero())", "after-generation reserve was not preserved",
            "std::cmp::min(HAL_CHILD_TIMEOUT, available)",
        ], in: cap)

        let cleanup = try functionBody(
            controller,
            beginningWith: "fn terminate_and_reap_hal_child_process_group(",
            endingBefore: "fn bounded_aqua_uid501_hal_output_in_directory("
        )
        assertOrdered([
            "kill(-process_group, SIGTERM)", "HAL_CHILD_TERMINATION_GRACE",
            "child.try_wait()?", "!hal_child_process_group_exists(process_group)?",
            "child.wait()?", "kill(-process_group, SIGKILL)", "child.wait()?",
            "while hal_child_process_group_exists(process_group)?",
            "HAL child process group was not fully reaped",
        ], in: cleanup)

        let launcher = try functionBody(
            controller,
            beginningWith: "fn bounded_aqua_uid501_hal_output_in_directory(",
            endingBefore: "fn bounded_direct_uid501_audio_output_in_directory("
        )
        XCTAssertTrue(launcher.contains("setpgid(0, 0)"))
        assertOrdered([
            "if let Some(status) = child.try_wait()?",
            "if hal_child_process_group_exists(process_group)?",
            "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "break Some(status)", "if Instant::now() >= deadline",
            "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "let (stdout, stdout_exceeded) = stdout_reader", ".join()",
            "let (stderr, stderr_exceeded) = stderr_reader", ".join()",
        ], in: launcher)

        let executableReapTest = try functionBody(
            controller,
            beginningWith: "fn self_test_hal_child_process_group_kill_and_reap(",
            endingBefore: "fn require_self_test_rejection<"
        )
        assertOrdered([
            "Command::new(\"/bin/sh\")", #".args(["-c", "/bin/sleep 30 & wait"])"#,
            "command.pre_exec", "setpgid(0, 0)", "command.spawn()",
            "let process_group = i32::try_from(child.id())", "let readiness =",
            #""/bin/ps""#, #"&["-axo", "pid=,pgid="]"#, "group == process_group",
            "members >= 2", "terminate_and_reap_hal_child_process_group(&mut child, process_group)?",
            "child.try_wait()?.is_none()", "hal_child_process_group_exists(process_group)?",
        ], in: executableReapTest)

        let selfTest = try functionBody(
            controller,
            beginningWith: "fn self_test() -> Result<()> {",
            endingBefore: "    for (value, length, label) in ["
        )
        XCTAssertTrue(selfTest.contains("self_test_hal_child_process_group_kill_and_reap()?"))
    }

    func testRootSupervisorContainsSplitPGIDsDefersCancellationAndRecoversBeforeReporting() throws {
        let controller = try source(controllerPath)
        for token in [
            #"const ROOT_SUDO_SUPERVISOR_MODE: &str = "--root-supervise-diagnostic-driver-v12-worker";"#,
            "const SUDO_TRANSACTION_TIMEOUT: Duration = Duration::from_secs(1_500);",
            "const SUDO_RECOVERY_TIMEOUT: Duration = Duration::from_secs(1_200);",
            "const SUDO_RECOVERY_MAX_ATTEMPTS: usize = 3;",
            "enum BoundedSudoHelperExecution", "TimedOut(IsolatedSudoSessionProof)",
            "ContainmentViolation", "struct IsolatedSudoSessionProof",
            "observed_process_ids: BTreeSet<i32>",
            "observed_process_groups: BTreeSet<i32>", "used_sigkill: bool",
            "observer_failures: usize",
        ] {
            XCTAssertTrue(controller.contains(token), "missing root-supervisor token: \(token)")
        }

        let privateDispatch = try functionBody(
            controller,
            beginningWith: "fn real_main() -> Result<()> {",
            endingBefore: "fn parse_positive_u32("
        )
        assertOrdered([
            "mode == ROOT_SUDO_SUPERVISOR_MODE",
            "root_sudo_supervisor(worker_mode, worker_arguments)",
        ], in: privateDispatch)

        let signalGuard = try functionBody(
            controller,
            beginningWith: "const ROOT_SUDO_SUPERVISOR_GUARDED_SIGNALS:",
            endingBefore: "#[derive(Debug)]\nenum BoundedSudoHelperExecution"
        )
        assertOrdered([
            "[SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU]",
            "for signal_number in ROOT_SUDO_SUPERVISOR_GUARDED_SIGNALS",
            "signal(signal_number, handler)", "install_root_sudo_supervisor_signal_guard()",
            "SIG_IGN", "reset_supervised_worker_signal_dispositions()", "SIG_DFL",
        ], in: signalGuard)

        let sessionMembers = try functionBody(
            controller,
            beginningWith: "fn isolated_sudo_session_members(",
            endingBefore: "fn signal_isolated_sudo_session_members("
        )
        assertOrdered([
            "session_id <= 1", #""/bin/ps""#, #"&["-axo", "pid="]"#,
            "getsid(pid)", "observed_session != session_id", "getpgid(pid)",
            "members.push((pid, process_group))", "members.sort_unstable()", "members.dedup()",
        ], in: sessionMembers)

        let authenticatedLeader = try functionBody(
            controller,
            beginningWith: "fn isolated_sudo_leader_fallback_is_authenticated(",
            endingBefore: "fn signal_authenticated_unreaped_isolated_sudo_leader("
        )
        assertOrdered([
            "session_id > 1", "leader_is_unreaped_and_live",
            "observed_session_id == Some(session_id)",
            "observed_process_group == Some(session_id)",
        ], in: authenticatedLeader)

        let leaderFallback = try functionBody(
            controller,
            beginningWith: "fn signal_authenticated_unreaped_isolated_sudo_leader(",
            endingBefore: "fn observe_isolated_sudo_session_until_exact<"
        )
        assertOrdered([
            "child.try_wait(), Ok(None)", "getsid(session_id)", "getpgid(session_id)",
            "isolated_sudo_leader_fallback_is_authenticated(",
            "kill(-session_id, signal_number)", "kill(session_id, signal_number)",
        ], in: leaderFallback)
        XCTAssertFalse(leaderFallback.contains("observed_process_ids"))
        XCTAssertFalse(leaderFallback.contains("observed_process_groups"))

        let observerRetry = try functionBody(
            controller,
            beginningWith: "fn observe_isolated_sudo_session_until_exact<",
            endingBefore: "fn terminate_and_reap_sudo_helper_process_group_with_observer<"
        )
        assertOrdered([
            "child: &mut Child", "loop {", "match observer(session_id)", "Ok(members)",
            "proof.observed_process_ids.insert", "proof.observed_process_groups.insert",
            "Err(_)", "proof.observer_failures", "saturating_add(1)",
            "signal_authenticated_unreaped_isolated_sudo_leader(", "child", "session_id",
            "signal_number",
            "thread::sleep(Duration::from_millis(10))",
        ], in: observerRetry)
        if let outage = observerRetry.range(of: "Err(_)") {
            let outageBranch = String(observerRetry[outage.lowerBound...])
            XCTAssertFalse(outageBranch.contains("proof.observed_process_ids"))
            XCTAssertFalse(outageBranch.contains("proof.observed_process_groups"))
        } else {
            XCTFail("observer outage branch is absent")
        }

        let cleanup = try functionBody(
            controller,
            beginningWith: "fn terminate_and_reap_sudo_helper_process_group_with_observer<",
            endingBefore: "fn terminate_and_reap_sudo_helper_process_group("
        )
        assertOrdered([
            "session_id <= 1", "observed_process_ids: [session_id]",
            "observed_process_groups: [session_id]", "used_sigkill: false",
            "observer_failures: 0",
            "signal_authenticated_unreaped_isolated_sudo_leader(child, session_id, SIGTERM)",
            "SUDO_PROCESS_GROUP_TERMINATION_GRACE",
            "observe_isolated_sudo_session_until_exact(",
            "signal_isolated_sudo_session_members(&initial, SIGTERM)",
            "child.try_wait()",
            "observe_isolated_sudo_session_until_exact(", "remaining.is_empty()",
            "child.try_wait()", "Ok(Some(_))", "confirmation", "confirmation.is_empty()",
            "proof.used_sigkill = true", "loop {",
            "observe_isolated_sudo_session_until_exact(", "SIGKILL",
            "remaining.is_empty()", "child.try_wait()", "Ok(Some(_))", "confirmation",
            "confirmation.is_empty()", "signal_isolated_sudo_session_members(&confirmation, SIGKILL)",
        ], in: cleanup)
        XCTAssertFalse(cleanup.contains("hal_child_process_group_exists"))
        XCTAssertFalse(cleanup.contains("fallback_signal_known_isolated_sudo_session"))
        XCTAssertFalse(cleanup.contains("signal_isolated_sudo_session_members(&proof"))

        let wait = try functionBody(
            controller,
            beginningWith: "fn wait_for_isolated_sudo_worker_session_with_observer<",
            endingBefore: "fn wait_for_isolated_sudo_worker_session("
        )
        assertOrdered([
            "let mut timeout_proof = None", "let mut completion_containment = None",
            "let observed_status = match child.try_wait()", "if let Some(status) = observed_status",
            "let mut completion_probe",
            "observe_isolated_sudo_session_until_exact(", "if completion_members.is_empty()",
            "thread::sleep(Duration::from_millis(20))",
            "completion_members = observe_isolated_sudo_session_until_exact(",
            "if !completion_members.is_empty()",
            "terminate_and_reap_sudo_helper_process_group_with_observer(",
            "containment.observer_failures", "completion_probe.observer_failures",
            "completion_containment = Some(containment)", "if Instant::now() >= deadline",
            "terminate_and_reap_sudo_helper_process_group_with_observer(",
            "timeout_proof = Some(proof)", "stdout_reader", ".join()", "stderr_reader", ".join()",
            "Some(containment) => Ok(BoundedSudoHelperExecution::ContainmentViolation",
            "None => Ok(BoundedSudoHelperExecution::Completed(output))",
            "BoundedSudoHelperExecution::TimedOut(", "timeout_proof.ok_or_else",
        ], in: wait)

        let isolatedWorker = try functionBody(
            controller,
            beginningWith: "fn spawn_isolated_root_worker(",
            endingBefore: "fn root_recovery_output_is_terminal("
        )
        assertOrdered([
            "getuid() } != ROOT_ID", "geteuid() } != ROOT_ID", "Command::new(executable)",
            "command.pre_exec", "reset_supervised_worker_signal_dispositions()?", "setsid()",
            "let session_id = i32::try_from(child.id())",
            "wait_for_isolated_sudo_worker_session(&mut child, session_id, timeout)",
        ], in: isolatedWorker)

        let recovery = try functionBody(
            controller,
            beginningWith: "fn converge_supervised_sealed_recovery(",
            endingBefore: "fn recover_after_supervised_root_worker_containment("
        )
        assertOrdered([
            "for attempt in 1..=SUDO_RECOVERY_MAX_ATTEMPTS", "verify_fixed_root_recovery_artifact()?",
            "spawn_isolated_root_worker(", "ROOT_SEALED_ROLLBACK_MODE", "SUDO_RECOVERY_TIMEOUT",
            "BoundedSudoHelperExecution::Completed(output)",
            "root_recovery_output_is_terminal(&output)",
            "kind=nonterminal-completion",
            "BoundedSudoHelperExecution::TimedOut(containment)",
            "BoundedSudoHelperExecution::ContainmentViolation",
            "sealed recovery did not reach a clean terminal worker after containment",
        ], in: recovery)

        let supervisor = try functionBody(
            controller,
            beginningWith: "fn root_sudo_supervisor(",
            endingBefore: "fn run_sudo_helper("
        )
        assertOrdered([
            "install_root_sudo_supervisor_signal_guard()?", "getuid() } != ROOT_ID",
            "geteuid() } != ROOT_ID", #"Some("501")"#, #"Some("20")"#, #"Some("ahmed")"#,
            "verify_root_controller_identity(&request)?", "spawn_isolated_root_worker(",
            "SUDO_TRANSACTION_TIMEOUT", "BoundedSudoHelperExecution::Completed(output)",
            "BoundedSudoHelperExecution::TimedOut(containment)",
            "recover_after_supervised_root_worker_containment(\"timed out\"",
            "BoundedSudoHelperExecution::ContainmentViolation",
            "recover_after_supervised_root_worker_containment(",
            "exited with surviving descendants",
        ], in: supervisor)

        let sudoCaller = try functionBody(
            controller,
            beginningWith: "fn run_sudo_helper(",
            endingBefore: "fn rename_exclusive("
        )
        assertOrdered([
            "ROOT_SUDO_SUPERVISOR_MODE", "mode", "Command::new(\"/usr/bin/sudo\")",
            "command.pre_exec(reset_supervised_worker_signal_dispositions)", "command.output()?",
        ], in: sudoCaller)
        XCTAssertFalse(sudoCaller.contains("setpgid("))
        XCTAssertFalse(sudoCaller.contains("child.kill()"))
        XCTAssertFalse(sudoCaller.contains("bounded_output("))

        let cancellationFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_sudo_helper_process_group_timeout_no_orphan(",
            endingBefore: "fn self_test_completed_sudo_worker_survivor_is_containment_violation("
        )
        assertOrdered([
            "install_root_sudo_supervisor_signal_guard()?", "SELF_TEST_SPLIT_PGID_WORKER_MODE",
            "setsid()", "let deliberate_child_process_group = loop",
            "*process_group != session_id", "for signal_number in ROOT_SUDO_SUPERVISOR_GUARDED_SIGNALS",
            "kill(supervisor_pid, signal_number)", "let mut injected_observer_failures = 0_usize",
            "injected sudo session observer failure",
            "wait_for_isolated_sudo_worker_session_with_observer(",
            "BoundedSudoHelperExecution::TimedOut(proof)",
            ".observed_process_groups", "contains(&deliberate_child_process_group)",
            "proof.used_sigkill", "proof.observer_failures != 3",
            "isolated_sudo_session_members(session_id)?.is_empty()",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_V12_SUDO_SUPERVISOR_SELF_TEST_RECOVERY",
            "outcome=rolled-back", "if marker.exists()",
            "sudo helper timeout allowed a delayed orphan mutation after recovery",
        ], in: cancellationFixture)
        XCTAssertFalse(cancellationFixture.contains("hal_child_process_group_exists("))

        let survivorFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_completed_sudo_worker_survivor_is_containment_violation(",
            endingBefore: "fn self_test_post_reap_observer_outage_never_signals_stale_ids("
        )
        assertOrdered([
            "SELF_TEST_EXIT_ZERO_SURVIVOR_MODE", "setsid()",
            "let mut injected_observer_failures = 0_usize",
            "injected post-exit sudo observer failure",
            "wait_for_isolated_sudo_worker_session_with_observer(",
            "BoundedSudoHelperExecution::ContainmentViolation",
            "BoundedSudoHelperExecution::Completed(_)",
            "exit-zero sudo worker survivor was accepted as completed",
            ".observed_process_groups", "*process_group != session_id",
            "output.status.success()", "DIAGNOSTIC_DRIVER_V12_UPDATE_COMMITTED self-test-survivor=true",
            "proof.used_sigkill", "proof.observer_failures != 2",
            "isolated_sudo_session_members(session_id)?.is_empty()",
            "exit-zero sudo worker survivor mutated after containment",
        ], in: survivorFixture)
        XCTAssertFalse(survivorFixture.contains("hal_child_process_group_exists("))

        let recoveryStates = try functionBody(
            controller,
            beginningWith: "fn self_test_root_sudo_supervisor_timeout_recovery_states(",
            endingBefore: "fn self_test_sudo_helper_process_group_timeout_no_orphan("
        )
        assertOrdered([
            "UpdateState::HostStopInitiated", "UpdateState::CandidatePublished",
            "UpdateState::CoreAudioReloaded", "root_sudo_supervisor_timeout_requires_sealed_recovery",
            "let required_attempt_seconds = COMMAND_TIMEOUT", ".saturating_mul(6)",
            "COREAUDIO_TIMEOUT.as_secs().saturating_mul(3)",
            "HOST_TIMEOUT.as_secs().saturating_mul(3)",
            "SUDO_RECOVERY_TIMEOUT.as_secs() < required_attempt_seconds",
            "SUDO_RECOVERY_MAX_ATTEMPTS < 3",
            ".saturating_mul(SUDO_RECOVERY_MAX_ATTEMPTS as u64)",
            "required_attempt_seconds.saturating_mul(3)",
            "supervised sealed recovery budget cannot cover all bounded durable phases",
        ], in: recoveryStates)

        let staleIDFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_post_reap_observer_outage_never_signals_stale_ids(",
            endingBefore: "fn self_test_hal_child_process_group_kill_and_reap("
        )
        assertOrdered([
            "let stale_reused_session_id = 42_000",
            "isolated_sudo_leader_fallback_is_authenticated(", "true",
            "Some(stale_reused_session_id)", "Some(stale_reused_session_id)",
            "isolated_sudo_leader_fallback_is_authenticated(", "false",
            "isolated_sudo_leader_fallback_is_authenticated(",
            "Some(stale_reused_session_id + 1)",
            "isolated_sudo_leader_fallback_is_authenticated(",
            "Some(stale_reused_session_id + 1)",
            "post-reap observer outage allowed stale PID/PGID signaling",
            "fn observe_isolated_sudo_session_until_exact",
            "fn terminate_and_reap_sudo_helper_process_group_with_observer", "observer_body",
            "signal_authenticated_unreaped_isolated_sudo_leader",
            "cleanup_body",
            "let immediate_term = cleanup_body", "signal_authenticated_unreaped_isolated_sudo_leader",
            "let first_observation = cleanup_body.find", "observe_isolated_sudo_session_until_exact",
            "cleanup_body.contains(\"hal_child_process_group_exists\")",
            "term < observe",
            "isolated-session cleanup delayed the authenticated leader deadline",
        ], in: staleIDFixture)
        XCTAssertFalse(controller.contains("fn fallback_signal_known_isolated_sudo_session("))

        let slowObserverFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_sudo_helper_deadline_terms_leader_before_slow_observer(",
            endingBefore: "fn self_test_post_reap_observer_outage_never_signals_stale_ids("
        )
        assertOrdered([
            "install_root_sudo_supervisor_signal_guard()?", "Command::new(\"/bin/sh\")",
            "/bin/sleep 0.2", "command.pre_exec", "setsid()", "command.spawn()?",
            "let mut delayed_first_observation = false", "let mut slow_observer",
            "thread::sleep(Duration::from_millis(350))",
            "wait_for_isolated_sudo_worker_session_with_observer(",
            "Duration::from_millis(30)", "BoundedSudoHelperExecution::TimedOut(proof)",
            "delayed_first_observation", "isolated_sudo_session_members(session_id)?.is_empty()",
            "!marker.exists()", "slow observer allowed a post-deadline leader mutation",
        ], in: slowObserverFixture)
        XCTAssertFalse(slowObserverFixture.contains("hal_child_process_group_exists("))

        let selfTest = try functionBody(
            controller,
            beginningWith: "fn self_test() -> Result<()> {",
            endingBefore: "    for (value, length, label) in ["
        )
        assertOrdered([
            "self_test_root_sudo_supervisor_timeout_recovery_states()?",
            "self_test_sudo_helper_process_group_timeout_no_orphan()?",
            "self_test_completed_sudo_worker_survivor_is_containment_violation()?",
            "self_test_sudo_helper_deadline_terms_leader_before_slow_observer()?",
            "self_test_post_reap_observer_outage_never_signals_stale_ids()?",
        ], in: selfTest)
    }

    func testUID501RootArtifactStagingBlocksUnderProcessWideGuardAndRefusesPartialRetry() throws {
        let controller = try source(controllerPath)

        let guardInstaller = try functionBody(
            controller,
            beginningWith: "fn install_uid501_mutating_sudo_signal_guard(",
            endingBefore: "fn sudo_mutating_blocking("
        )
        assertOrdered([
            "getuid() } != USER_ID", "geteuid() } != USER_ID",
            "mutating sudo staging guard requires exact UID501",
            "install_root_sudo_supervisor_signal_guard()",
        ], in: guardInstaller)

        let blockingWait = try functionBody(
            controller,
            beginningWith: "fn wait_for_blocking_mutating_sudo_child(",
            endingBefore: "fn sudo_mutating_blocking("
        )
        assertOrdered([
            "let stdout = child", ".stdout", ".take()", "let stderr = child", ".stderr", ".take()",
            "thread::spawn(move || read_pipe_bounded(stdout, MAX_OUTPUT_BYTES))",
            "thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES))",
            "let status = child.wait()?", "stdout_reader", ".join()", "stderr_reader",
            ".join()", "stdout_exceeded || stderr_exceeded", "Ok(Output",
        ], in: blockingWait)

        let blockingSudo = try functionBody(
            controller,
            beginningWith: "fn sudo_mutating_blocking(",
            endingBefore: "fn parse_root_shasum_output("
        )
        assertOrdered([
            "getuid() } != USER_ID", "geteuid() } != USER_ID",
            "Command::new(\"/usr/bin/sudo\")", ".args(complete)", ".current_dir(\"/\")",
            ".env_clear()", ".stdin(Stdio::null())", ".stdout(Stdio::piped())",
            ".stderr(Stdio::piped())", "command.pre_exec(reset_supervised_worker_signal_dispositions)",
            "wait_for_blocking_mutating_sudo_child(command.spawn()?)",
        ], in: blockingSudo)
        for forbidden in [
            "bounded_output(", "child.kill(", "kill(", "try_wait(",
            "Instant::now()", "checked_add(", "timeout",
        ] {
            XCTAssertFalse(
                (blockingWait + blockingSudo).contains(forbidden),
                "mutating sudo staging must block through terminal wait, found: \(forbidden)"
            )
        }

        let stream = try functionBody(
            controller,
            beginningWith: "fn sudo_stream_root_file(",
            endingBefore: "fn stage_root_owned_controller("
        )
        assertOrdered([
            "require_absent(destination", "sudo_mutating_blocking(", "\"/usr/bin/install\"",
            "require_success(&create", "require_regular(destination", "sudo_root_require_no_acl_or_xattrs",
            "Command::new(\"/usr/bin/sudo\")", "\"/usr/bin/tee\"",
            "command.pre_exec(reset_supervised_worker_signal_dispositions)", "command.spawn()?",
            "thread::spawn(move || read_pipe_bounded(stderr, MAX_OUTPUT_BYTES))",
            "stdin.write_all(bytes)", "drop(stdin)",
            "let status_result = child.wait()", "stderr_reader", ".join()", "write_result?",
            "let status = status_result?", "sudo_root_sha256(destination)? != expected",
            "sudo_mutating_blocking(&[", "\"/bin/chmod\"", "require_success(&publish",
            "require_sealed_regular(destination", "sha256(destination)? != expected",
        ], in: stream)
        for forbidden in ["bounded_output(", "child.kill(", "kill(", "try_wait(", "Instant::now()"] {
            XCTAssertFalse(stream.contains(forbidden), "root byte stream can orphan sudo: \(forbidden)")
        }

        let freshNamespace = try functionBody(
            controller,
            beginningWith: "fn require_fresh_root_controller_staging_namespace(",
            endingBefore: "fn stage_root_owned_controller("
        )
        assertOrdered([
            "require_absent(support", "require_absent(recovery_controller",
            "require_absent(recovery_pin", "require_absent(bootstrap_locator",
        ], in: freshNamespace)

        let staging = try functionBody(
            controller,
            beginningWith: "fn stage_root_owned_controller(",
            endingBefore: "fn verify_root_controller_identity("
        )
        assertOrdered([
            "require_fresh_root_controller_staging_namespace(", "&support",
            "ROOT_RECOVERY_CONTROLLER", "ROOT_RECOVERY_CONTROLLER_PIN", "ROOT_BOOTSTRAP_LOCATOR",
            "sha256_bytes(controller_bytes)? != digest",
            "install_uid501_mutating_sudo_signal_guard()?",
            "sudo_stream_root_file(", "ROOT_BOOTSTRAP_LOCATOR",
            "sudo_mutating_blocking(", "\"/usr/bin/install\"", "\"-d\"",
            "sudo_stream_root_file(", "ROOT_RECOVERY_CONTROLLER",
            "sudo_stream_root_file(", "ROOT_RECOVERY_CONTROLLER_PIN",
            "sudo_stream_root_file(", "&controller",
            "require_sealed_regular(Path::new(ROOT_BOOTSTRAP_LOCATOR)",
            "require_root_directory_identity(", "require_uid501_restricted_root_directory_identity(",
        ], in: staging)
        XCTAssertFalse(staging.contains("bounded_output("))
        XCTAssertFalse(staging.contains("child.kill("))
        XCTAssertFalse(staging.contains("set_root_sudo_supervisor_signal_dispositions(SIG_DFL"))

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "let retained_v1_lock =", "let retained_v8_lock =", "let retained_v9_lock =",
            "let _lock = acquire_user_update_lock()?",
            "stage_root_owned_controller(", "verify_complete_preflight(",
            "verify_retained_v8_descriptor_graph(&dispatch_retained_v8_guard, &retained_v8_lock)?",
            "verify_retained_v9_descriptor_graph(&dispatch_retained_v9_guard, &retained_v9_lock)?",
            "run_sudo_helper(&root_controller, ROOT_MODE",
            "verify_retained_v8_user_rolled_back_once(&retained_v8_lock)?",
            "verify_retained_v9_user_prestop_attempt_once(&retained_v9_lock)?",
        ], in: execute)

        let executableFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_uid501_blocking_mutating_sudo_staging_guard(",
            endingBefore: "fn self_test_sudo_helper_process_group_timeout_no_orphan("
        )
        assertOrdered([
            "install_uid501_mutating_sudo_signal_guard()?", "Command::new(\"/bin/sh\")",
            #"/bin/sleep 0.2; /bin/echo staging-terminal"#,
            "command.pre_exec(reset_supervised_worker_signal_dispositions)", "command.spawn()?",
            "for signal_number in ROOT_SUDO_SUPERVISOR_GUARDED_SIGNALS",
            "kill(supervisor_pid, signal_number)", "wait_for_blocking_mutating_sudo_child(child)?",
            "signaler", ".join()", "output.status.success()", "b\"staging-terminal\\n\"",
            "require_fresh_root_controller_staging_namespace(", "create_new(true)",
            "file.write_all(b\"partial-staging\\n\")", "file.sync_all()?",
            "require_self_test_rejection(", "require_fresh_root_controller_staging_namespace(",
            "\"partial root-controller staging retry\"", "fs::remove_file(&locator)",
            "fs::remove_dir(&root)",
        ], in: executableFixture)

        let selfTest = try functionBody(
            controller,
            beginningWith: "fn self_test() -> Result<()> {",
            endingBefore: "    for (value, length, label) in ["
        )
        XCTAssertTrue(selfTest.contains("self_test_uid501_blocking_mutating_sudo_staging_guard()?"))
    }

    func testPostBootstrapPreLockRecoveryAuthenticatesRunningOrJobOnlyLaunchdOwnership() throws {
        let controller = try source(controllerPath)
        XCTAssertTrue(controller.contains(
            "const HOST_STARTUP_RECOVERY_GRACE: Duration = Duration::from_secs(5);"
        ))

        let launchParser = try functionBody(
            controller,
            beginningWith: "fn parse_loaded_host_launch_job(",
            endingBefore: "fn parse_host_launch_state("
        )
        assertOrdered([
            "gui/{USER_ID}/{HOST_LABEL} = {", "path =", "type =", "state =", "program =",
            "pid =", "runs =", "let mut expected_arguments = vec![HOST_EXECUTABLE.to_owned()]",
            "HOST_ARGUMENTS", "path.as_deref() != Some(HOST_PLIST)",
            "job_type.as_deref() != Some(\"LaunchAgent\")",
            "program.as_deref() != Some(HOST_EXECUTABLE)", "arguments != expected_arguments",
            "Ok(LoadedHostLaunchJob { state, pid, runs })",
        ], in: launchParser)

        let runningAuthentication = try functionBody(
            controller,
            beginningWith: "fn authenticate_exact_current_host_startup_in_progress(",
            endingBefore: "fn authenticate_exact_loaded_current_host_job_without_process("
        )
        assertOrdered([
            "verify_installed_current_host_bytes()?", "require_legacy_disabled_and_absent()?",
            "read_host_launch_state()?", "require_solo_current_host(pid)?",
            "replacement_current_host_startup_identity_is_exact(initial, &startup)",
            "open_exact_host_lock(initial.lock_device, initial.lock_inode)?",
            "read_host_launch_state()? != (startup.pid, startup.runs)",
            "process_start(startup.pid)? != startup.process_start", "require_solo_current_host(startup.pid)?",
        ], in: runningAuthentication)

        let jobOnlyAuthentication = try functionBody(
            controller,
            beginningWith: "fn authenticate_exact_loaded_current_host_job_without_process(",
            endingBefore: "fn bootout_exact_current_host_startup_for_rollback("
        )
        assertOrdered([
            "verify_installed_current_host_bytes()?", "require_legacy_disabled_and_absent()?",
            "read_loaded_host_launch_job()?", "exact_loaded_host_job_without_process_is_recoverable(",
            "capture_server_processes()?.is_empty()", "open_exact_host_lock(",
            "read_loaded_host_launch_job()? != job", "capture_server_processes()?.is_empty()",
        ], in: jobOnlyAuthentication)
        XCTAssertFalse(jobOnlyAuthentication.contains("parse_host_launch_state("))

        let jobOnlyBootout = try functionBody(
            controller,
            beginningWith: "fn bootout_exact_loaded_host_job_without_process_for_rollback(",
            endingBefore: "fn reconcile_post_bootstrap_pre_lock_host_for_rollback("
        )
        assertOrdered([
            "authenticate_exact_loaded_current_host_job_without_process(initial)? != expected",
            "format!(\"gui/{USER_ID}/{HOST_LABEL}\")", "\"/bin/launchctl\"",
            "&[\"bootout\", &target]", "require_success(", "&output",
            "output.stdout.is_empty()", "output.stderr.is_empty()",
            "wait_host_absent(initial.lock_device, initial.lock_inode)",
        ], in: jobOnlyBootout)

        let reconciliation = try functionBody(
            controller,
            beginningWith: "fn reconcile_post_bootstrap_pre_lock_host_for_rollback(",
            endingBefore: "fn restart_or_recover_exact_current_host("
        )
        assertOrdered([
            "checked_add(HOST_STARTUP_RECOVERY_GRACE)", "let mut exact_no_process_job = None",
            "loop {", "authenticate_exact_current_host_startup_in_progress(initial)",
            "bootout_exact_current_host_startup_for_rollback(initial, &startup)",
            "authenticate_exact_loaded_current_host_job_without_process(initial)",
            "exact_no_process_job = Some(job)", "require_service_absent(HOST_LABEL).is_ok()",
            "capture_server_processes().is_ok_and(|processes| processes.is_empty())",
            "if service_absent && process_absent", "wait_host_absent(",
            "if Instant::now() >= deadline", "no_process_host_recovery_action(",
            "NoProcessHostRecoveryAction::BootoutExactJob",
            "bootout_exact_loaded_host_job_without_process_for_rollback(",
            "initial, job",
            "post-bootstrap/pre-lock host could not be authenticated for rollback",
            "thread::sleep(Duration::from_millis(100))",
        ], in: reconciliation)

        let rollbackStop = try functionBody(
            controller,
            beginningWith: "fn stop_current_host_for_rollback(",
            endingBefore: "fn verify_retained_v7_driver("
        )
        assertOrdered([
            "verify_live_current_host()",
            "restore_and_verify_live_current_host(&initial.display_mode)",
            "stop_exact_current_host(&generation)",
            "reconcile_post_bootstrap_pre_lock_host_for_rollback(initial)",
        ], in: rollbackStop)

        let executableAdmission = try functionBody(
            controller,
            beginningWith: "fn self_test_post_bootstrap_pre_lock_recovery_admission(",
            endingBefore: "fn self_test_uid501_blocking_mutating_sudo_staging_guard("
        )
        assertOrdered([
            "let waiting_job = LoadedHostLaunchJob", "state: \"waiting\"", "pid: None",
            "runs: Some(0)", "job_with_pid.pid = Some(101)", "job_without_runs.runs = None",
            "exact_loaded_host_job_without_process_is_recoverable(&waiting_job, true)",
            "exact_loaded_host_job_without_process_is_recoverable(&job_with_pid, true)",
            "exact_loaded_host_job_without_process_is_recoverable(&job_without_runs, true)",
            "exact_loaded_host_job_without_process_is_recoverable(&waiting_job, false)",
            "no_process_host_recovery_action(Some(&waiting_job), true, false)",
            "NoProcessHostRecoveryAction::WaitForGrace",
            "no_process_host_recovery_action(Some(&waiting_job), true, true)",
            "NoProcessHostRecoveryAction::BootoutExactJob",
            "no_process_host_recovery_action(Some(&job_with_pid), true, true)",
            "NoProcessHostRecoveryAction::Reject",
        ], in: executableAdmission)

        let selfTest = try functionBody(
            controller,
            beginningWith: "fn self_test() -> Result<()> {",
            endingBefore: "    for (value, length, label) in ["
        )
        XCTAssertTrue(selfTest.contains("self_test_post_bootstrap_pre_lock_recovery_admission()?"))
    }

    func testRouteProofReservesAfterGenerationAndPreservesTypedTimeouts() throws {
        let controller = try source(controllerPath)
        for token in [
            "enum FreshRouteHelperOutcome", "Observation(PostReloadRouteObservation)",
            "TimedOut", "Fatal(ControllerError)",
        ] {
            XCTAssertTrue(controller.contains(token), "missing route outcome token: \(token)")
        }

        let classifier = try functionBody(
            controller,
            beginningWith: "fn classify_fresh_route_helper_outcome(",
            endingBefore: "fn fresh_route_observation_for_generation("
        )
        assertOrdered([
            "Ok(BoundedHalChildExecution::Completed(output))",
            "classify_fresh_route_helper_execution(Ok(output))",
            "FreshRouteHelperOutcome::Observation(observation)",
            "FreshRouteHelperOutcome::Fatal(error)",
            "Ok(BoundedHalChildExecution::TimedOut)", "FreshRouteHelperOutcome::TimedOut",
            "Err(error)", "FreshRouteHelperOutcome::Fatal(error)",
        ], in: classifier)

        let generationCapture = try functionBody(
            controller,
            beginningWith: "fn fresh_route_observation_for_generation(",
            endingBefore: "fn fresh_complete_route_snapshot_for_generation("
        )
        assertOrdered([
            "let before = read_coreaudio_generation()?",
            "let outcome =", "classify_fresh_route_helper_outcome(run_uid501_fresh_route_helper(",
            "let after = read_coreaudio_generation()?",
            "post_reload_generation_bracket_is_exact(expected, &before, &after)",
            "outcome.into_result()",
        ], in: generationCapture)

        let timeoutReducer = try functionBody(
            controller,
            beginningWith: "fn advance_post_reload_route_helper_outcome(",
            endingBefore: "fn evaluate_post_reload_route_observations("
        )
        assertOrdered([
            "FreshRouteHelperOutcome::Observation(observation)",
            "advance_post_reload_route_proof(",
            "FreshRouteHelperOutcome::TimedOut", "*previous_complete = None",
            "PostReloadRouteProofProgress::NeedAnotherComplete",
            "FreshRouteHelperOutcome::Fatal(error)", "Err(error)",
        ], in: timeoutReducer)

        let proof = try functionBody(
            controller,
            beginningWith: "fn prove_post_reload_routes(",
            endingBefore: "fn coreaudio_restart_successor_is_exact("
        )
        assertOrdered([
            "create_post_reload_route_transcript(probes)?",
            ".checked_add(POST_RELOAD_ROUTE_TIMEOUT)",
            "for attempt in 1..=POST_RELOAD_ROUTE_MAX_ATTEMPTS",
            "let before = match read_coreaudio_generation_before(deadline)",
            #""before-generation""#, #""exact""#,
            "let helper_timeout = match hal_child_timeout_preserving_after_generation_reserve(deadline)",
            "classify_fresh_route_helper_outcome(run_uid501_fresh_route_helper(helper_timeout))",
            "let outcome_token = outcome.transcript_token()", #""helper""#,
            "let after = match read_coreaudio_generation_before(deadline)",
            "post-reload after-generation failed after helper outcome={outcome_token}",
            "post_reload_generation_bracket_is_exact(", "expected_coreaudio, &before, &after",
            #""after-generation""#, #""exact""#,
            "advance_post_reload_route_helper_outcome(",
        ], in: proof)
        XCTAssertFalse(proof.contains("run_uid501_fresh_route_helper(remaining_before_post_reload_deadline"))
        XCTAssertFalse(proof.contains("capture_route_snapshot_classified_local"))
    }

    func testFatalRouteOutcomeDurablyTerminalizesWithoutMaskingOriginalHALFailure() throws {
        let controller = try source(controllerPath)

        let terminalResult = try functionBody(
            controller,
            beginningWith: "fn post_reload_route_helper_error_terminal_result(",
            endingBefore: "fn preserve_post_reload_route_helper_error("
        )
        assertOrdered([
            "FreshRouteHelperOutcome::Fatal(_)", "\"fatal\"", "\"failed\"",
        ], in: terminalResult)

        let preservation = try functionBody(
            controller,
            beginningWith: "fn preserve_post_reload_route_helper_error(",
            endingBefore: "fn combine_post_reload_helper_fatal_with_subsequent_error("
        )
        assertOrdered([
            "original: ControllerError", "transcript_finalization: Result<()>",
            "Ok(()) => original", "Err(transcript_error)",
            "original HAL helper fatal error", "original.0", "transcript_error.0",
        ], in: preservation)

        let subsequentFailure = try functionBody(
            controller,
            beginningWith: "fn combine_post_reload_helper_fatal_with_subsequent_error(",
            endingBefore: "fn classify_device_uid_status("
        )
        assertOrdered([
            "helper_fatal: Option<&str>", "subsequent: ControllerError", "Some(original)",
            "original HAL helper fatal error", "subsequent post-helper failure", "subsequent.0",
            "None => subsequent",
        ], in: subsequentFailure)

        let proof = try functionBody(
            controller,
            beginningWith: "fn prove_post_reload_routes(",
            endingBefore: "fn coreaudio_restart_successor_is_exact("
        )
        assertOrdered([
            "FreshRouteHelperOutcome::Fatal(_) => counts.fatal += 1",
            "FreshRouteHelperOutcome::Fatal(error) => Some(error.0.clone())",
            "outcome.transcript_token()", "if let Err(error) = append_post_reload_route_attempt_record(",
            "\"helper\"", "combine_post_reload_helper_fatal_with_subsequent_error(",
            "read_coreaudio_generation_before(deadline)",
            "combine_post_reload_helper_fatal_with_subsequent_error(",
            "post-reload after-generation failed",
            "append_post_reload_route_attempt_record(", "\"after-generation\"", "\"fatal\"",
            "preserve_post_reload_route_helper_error(",
            "post_reload_generation_bracket_is_exact(", "expected_coreaudio, &before, &after",
            "combine_post_reload_helper_fatal_with_subsequent_error(",
            "coreaudiod generation changed during post-reload route attempt", "\"changed\"",
            "preserve_post_reload_route_helper_error(",
            "if let Err(error) = append_post_reload_route_attempt_record(",
            "\"after-generation\"", "\"exact\"",
            "combine_post_reload_helper_fatal_with_subsequent_error(",
            "post_reload_route_helper_error_terminal_result(&outcome)",
            "advance_post_reload_route_helper_outcome(", "Err(error)",
            "finish_post_reload_route_transcript(", "helper_error_terminal_result",
            "preserve_post_reload_route_helper_error(", "error", "transcript_finalization",
        ], in: proof)

        let executableFatal = try functionBody(
            controller,
            beginningWith: "let fatal_transcript = concat!(",
            endingBefore: "let nonfatal_transcript = concat!("
        )
        assertOrdered([
            "phase=before-generation outcome=exact", "phase=helper outcome=fatal",
            "phase=after-generation outcome=exact", "result=fatal attempts=1",
            "parse_post_reload_route_transcript(fatal_transcript)",
            "self-test original HAL fatal error", "FreshRouteHelperOutcome::Fatal",
            "post_reload_route_helper_error_terminal_result(&fatal_outcome) != \"fatal\"",
            "advance_post_reload_route_helper_outcome(", "returned_fatal.0 != original_hal_fatal",
            "preserve_post_reload_route_helper_error(", "Ok(())",
            "preserve_post_reload_route_helper_error(",
            "injected transcript finalization failure", "preserved_success.0 != original_hal_fatal",
            "preserved_failure.0.contains(original_hal_fatal)",
            "contains(\"injected transcript finalization failure\")",
            "for subsequent in [", "injected transcript append failure",
            "injected after-generation read failure", "injected generation-changed failure",
            "combine_post_reload_helper_fatal_with_subsequent_error(",
            "Some(original_hal_fatal)", "combined.0.contains(original_hal_fatal)",
            "combined.0.contains(subsequent)",
            "helper Fatal subsequent failure masked original error",
        ], in: executableFatal)
    }

    func testRollbackCoreAudioRecoveryWaitsBoundedlyForTwoExactStableObservations() throws {
        let controller = try source(controllerPath)

        let reducer = try functionBody(
            controller,
            beginningWith: "fn advance_recovery_stable_coreaudio_observation(",
            endingBefore: "fn wait_for_stable_coreaudio_generation_for_recovery("
        )
        assertOrdered([
            "Ok(generation) if previous.as_ref() == Some(&generation) => Some(generation)",
            "Ok(generation)", "*previous = Some(generation)", "None",
            "Err(_)", "*previous = None", "None",
        ], in: reducer)

        let wait = try functionBody(
            controller,
            beginningWith: "fn wait_for_stable_coreaudio_generation_for_recovery(",
            endingBefore: "fn prove_post_reload_routes("
        )
        assertOrdered([
            "UpdateState::PriorDriverRestored", "UpdateState::RollbackCoreAudioReloadInitiated",
            "checked_add(COREAUDIO_TIMEOUT)", "let mut previous = None", "loop {",
            "advance_recovery_stable_coreaudio_observation(",
            "read_coreaudio_generation_before(deadline)", "return Ok(stable)",
            "deadline", ".checked_duration_since(Instant::now())", ".filter(|remaining| !remaining.is_zero())",
            "coreaudiod did not reach a stable exact generation during recovery from",
            "state.token()", "thread::sleep(std::cmp::min(Duration::from_millis(250), remaining))",
        ], in: wait)
        XCTAssertFalse(wait.contains("stable_coreaudio_generation()?"))

        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        assertOrdered([
            "if journal.state == UpdateState::PriorDriverRestored",
            "wait_for_stable_coreaudio_generation_for_recovery(",
            "UpdateState::PriorDriverRestored", "UpdateState::RollbackCoreAudioReloadInitiated",
            "if journal.state == UpdateState::RollbackCoreAudioReloadInitiated",
            "wait_for_stable_coreaudio_generation_for_recovery(",
            "UpdateState::RollbackCoreAudioReloadInitiated", "current.pid == old_pid",
            "reload_coreaudio_exact(&current)", "current.pid != old_pid",
            "current.runs == old_runs.saturating_add(1)",
        ], in: rollback)

        let executableReducer = try functionBody(
            controller,
            beginningWith: "let mut recovery_stability = None;",
            endingBefore: "    if AUDIO_HARDWARE_BAD_OBJECT_ERROR"
        )
        assertOrdered([
            "transient coreaudiod absence", "recovery_stability.is_some()",
            "Ok(same_second_before.clone())", "Ok(same_second_after.clone())",
            "Ok(same_second_after.clone())", "Some(same_second_after.clone())",
            "bounded recovery Core Audio stability wait accepted transient/changing generations",
        ], in: executableReducer)
    }

    func testRouteTranscriptIsCanonicalDurableBoundedAndPrivacySafe() throws {
        let controller = try source(controllerPath)
        for token in [
            "const POST_RELOAD_ROUTE_TRANSCRIPT_MAX_BYTES: u64 = 16 * 1_024;",
            #"const POST_RELOAD_ROUTE_TRANSCRIPT_NAME: &str = "post-reload-route-proof.log";"#,
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V12",
            #""before-generation" | "helper" | "after-generation""#,
            #""complete""#, #""transient-bad-object""#, #""timed-out""#,
            #""fatal""#, #""changed""#, #""not-run""#,
        ] {
            XCTAssertTrue(controller.contains(token), "missing transcript token: \(token)")
        }

        let parser = try functionBody(
            controller,
            beginningWith: "fn parse_post_reload_route_transcript(",
            endingBefore: "fn create_post_reload_route_transcript("
        )
        assertOrdered([
            "text.len() as u64 > POST_RELOAD_ROUTE_TRANSCRIPT_MAX_BYTES",
            "!text.ends_with('\\n')", "text.contains('\\r')",
            #"Some("OPENSTEAMER_DIAGNOSTIC_DRIVER_ROUTE_PROOF_V12")"#,
            "let mut expected_attempt = 1_usize", "let mut expected_phase = 0_usize",
            "let mut counts = [0_usize; 4]", "let mut previous_helper_was_complete = false",
            "let mut last_attempt_proved = false", "let mut last_attempt_had_fatal = false",
            "line.contains(\"uid\")", "line.split_ascii_whitespace()", "fields.insert(key, value)",
            "canonical_count(\"complete\")", "canonical_count(\"transient\")",
            "canonical_count(\"timeout\")", "canonical_count(\"fatal\")",
            #""proven" | "failed" | "fatal""#, "canonical_count(\"attempts\")",
            "attempts > POST_RELOAD_ROUTE_MAX_ATTEMPTS",
            #"*result == "proven" && !last_attempt_proved"#,
            #"*result == "fatal" && !last_attempt_had_fatal"#,
            #"*result == "failed" && (last_attempt_proved || last_attempt_had_fatal)"#,
            #""before-generation" | "helper" | "after-generation""#,
            "let canonical_phase =", "attempt != expected_attempt",
            "attempt > POST_RELOAD_ROUTE_MAX_ATTEMPTS", "*phase != canonical_phase",
            "match expected_phase", "record_counts != counts",
            "let mut expected_counts = counts", #""complete" => expected_counts[0] += 1"#,
            #""transient-bad-object" => expected_counts[1] += 1"#,
            #""timed-out" => expected_counts[2] += 1"#,
            #""fatal" => expected_counts[3] += 1"#, "record_counts != expected_counts",
            "last_attempt_had_fatal |= *outcome == \"fatal\"",
            "last_attempt_proved = previous_helper_was_complete",
            "last_attempt_had_fatal |= matches!(*outcome, \"changed\" | \"fatal\")",
            "expected_attempt += 1", "if expected_attempt == 1 || !saw_result",
        ], in: parser)

        let create = try functionBody(
            controller,
            beginningWith: "fn create_post_reload_route_transcript(",
            endingBefore: "fn append_post_reload_route_transcript("
        )
        assertOrdered([
            "require_directory(probes, ROOT_ID, ROOT_ID, ROOT_PRIVATE_MODE)?",
            "probes.join(POST_RELOAD_ROUTE_TRANSCRIPT_NAME)", "require_absent(&path",
            ".create_new(true)", ".mode(0o600)", ".custom_flags(O_NOFOLLOW | O_CLOEXEC)",
            "fchown(file.as_raw_fd(), ROOT_ID, ROOT_ID)", "fchmod(file.as_raw_fd(), 0o600)",
            "file.write_all(header)?", "file.sync_all()?", "fsync_parent(&path)?",
        ], in: create)

        let append = try functionBody(
            controller,
            beginningWith: "fn append_post_reload_route_transcript(",
            endingBefore: "fn append_post_reload_route_attempt_record("
        )
        assertOrdered([
            "record.is_empty()", "!record.ends_with('\\n')", "record.contains(\"uid\")",
            "POST_RELOAD_ROUTE_TRANSCRIPT_MAX_BYTES", "before.dev() != transcript.device",
            "before.ino() != transcript.inode", "before.uid() != ROOT_ID",
            "before.gid() != ROOT_ID", "before.permissions().mode()", "before.len()",
            "transcript.file.write_all(record.as_bytes())?", "transcript.file.sync_all()?",
            "fs::symlink_metadata(&transcript.path)?", "after.file_type().is_symlink()",
            "parse_post_reload_route_transcript(&text)",
            "route transcript canonical round trip failed",
        ], in: append)
        XCTAssertFalse(append.contains("input_uid"))
        XCTAssertFalse(append.contains("output_uid"))

        let attemptRecord = try functionBody(
            controller,
            beginningWith: "fn append_post_reload_route_attempt_record(",
            endingBefore: "fn finish_post_reload_route_transcript("
        )
        for field in [
            "attempt={attempt}", "phase={phase}", "outcome={outcome}",
            "complete={}", "transient={}", "timeout={}", "fatal={}",
        ] {
            XCTAssertTrue(attemptRecord.contains(field), "attempt record omits \(field)")
        }
    }

    func testDynamicSelectedDisplayNormalizesSixMappingsAllowsRawExtrasAndRejectsAliases() throws {
        let controller = try source(controllerPath)
        let constants = try functionBody(
            controller,
            beginningWith: "const CURRENT_VIRTUAL_DISPLAY_VENDOR:",
            endingBefore: "#[link(name = \"CoreGraphics\""
        )
        for token in [
            "const CURRENT_VIRTUAL_DISPLAY_VENDOR: u32 = 0x6F73;",
            "const CURRENT_VIRTUAL_DISPLAY_PRODUCT: u32 = 0x1718;",
            "const CURRENT_VIRTUAL_DISPLAY_SERIAL: u32 = 1;",
            "const CURRENT_VIRTUAL_DISPLAY_REFRESH_MILLIHERTZ: u32 = 60_000;",
            "const DISPLAY_CONFIGURATION_FOR_SESSION: u32 = 1;",
            #"const DISPLAY_SNAPSHOT_HEADER: &str = "OPENSTEAMER_CURRENT_VIRTUAL_DISPLAY_SNAPSHOT_V1";"#,
            #""OPENSTEAMER_CURRENT_VIRTUAL_DISPLAY_RESTORE_TARGET_V1";"#,
        ] {
            XCTAssertTrue(constants.contains(token), "missing selected-display constant: \(token)")
        }

        let requiredModes = try functionBody(
            controller,
            beginningWith: "fn required_current_virtual_display_modes()",
            endingBefore: "fn selected_virtual_display_mode("
        )
        XCTAssertEqual(occurrences(of: "        mode(", in: requiredModes), 6)
        assertOrdered([
            "mode(1_080, 1_920, 1_080, 1_920)",
            "mode(603, 1_311, 1_206, 2_622)",
            "mode(540, 1_170, 1_080, 2_340)",
            "mode(540, 960, 1_080, 1_920)",
            "mode(414, 896, 828, 1_792)",
            "mode(750, 1_334, 750, 1_334)",
        ], in: requiredModes)
        XCTAssertTrue(requiredModes.contains(
            "refresh_millihertz: CURRENT_VIRTUAL_DISPLAY_REFRESH_MILLIHERTZ"
        ))

        let reviewed = try functionBody(
            controller,
            beginningWith: "fn current_virtual_display_mode_is_reviewed(",
            endingBefore: "fn virtual_display_topology_for_selected("
        )
        XCTAssertTrue(reviewed.contains("required_current_virtual_display_modes().contains(mode)"))

        let topology = try functionBody(
            controller,
            beginningWith: "fn virtual_display_topology_for_selected(",
            endingBefore: "fn display_mode_identity_token("
        )
        assertOrdered([
            "if !current_virtual_display_mode_is_reviewed(selected)",
            "vendor: CURRENT_VIRTUAL_DISPLAY_VENDOR",
            "product: CURRENT_VIRTUAL_DISPLAY_PRODUCT",
            "serial: CURRENT_VIRTUAL_DISPLAY_SERIAL",
            "logical_width: selected.logical_width",
            "logical_height: selected.logical_height",
            "pixel_width: selected.pixel_width",
            "pixel_height: selected.pixel_height",
            "refresh_millihertz: selected.refresh_millihertz",
            "available_modes: required_current_virtual_display_modes()",
        ], in: topology)

        let parser = try functionBody(
            controller,
            beginningWith: "fn parse_canonical_display_mode_identity(",
            endingBefore: "fn normalize_display_refresh_millihertz("
        )
        assertOrdered([
            "value.split(':').collect::<Vec<_>>()",
            "fields.len() != 5",
            "require_canonical_positive_decimal(field, label)?",
            ".parse::<usize>()",
            "dimension overflowed",
            ".parse::<u32>()",
            "refresh rate overflowed",
            "display_mode_identity_token(&mode) != value",
            "!current_virtual_display_mode_is_reviewed(&mode)",
        ], in: parser)

        let refresh = try functionBody(
            controller,
            beginningWith: "fn normalize_display_refresh_millihertz(",
            endingBefore: "fn copy_current_virtual_display_modes_with_duplicates("
        )
        XCTAssertTrue(refresh.contains("!refresh_rate.is_finite()"))
        XCTAssertTrue(refresh.contains("(refresh_rate - 60.0).abs() > 0.05"))
        XCTAssertTrue(refresh.contains("Ok(CURRENT_VIRTUAL_DISPLAY_REFRESH_MILLIHERTZ)"))
        assertOrdered([
            "fn raw_display_mode_observation_from_values(",
            "let strict_identity = normalize_display_refresh_millihertz(refresh_rate)",
            ".ok()",
            "refresh_rate_bits: refresh_rate.to_bits()",
            "strict_identity,",
            "fn raw_display_mode_observation(",
            "CGDisplayModeGetRefreshRate(mode)",
            "fn strict_display_mode_identity_from_observation(",
            "observation.strict_identity.clone().ok_or_else",
            "selected virtual-display mode is not a strict 60 Hz identity",
            "fn display_mode_identity(",
            "strict_display_mode_identity_from_observation(&raw_display_mode_observation(mode))",
        ], in: refresh)

        let exactCapabilities = try functionBody(
            controller,
            beginningWith: "fn observed_virtual_display_capability_set_is_exact(",
            endingBefore: "fn capture_current_virtual_display_topology_local_with_policy("
        )
        assertOrdered([
            "required_current_virtual_display_modes()",
            ".iter()",
            ".all(|required| exact_raw_display_mode_match_count(available_modes, required) == 1)",
            "exact_raw_display_mode_match_count(available_modes, selected_mode) == 1",
            "current_virtual_display_mode_is_reviewed(selected_mode)",
            "allow_restart_interim_selected_mode",
            "fn normalized_reviewed_virtual_display_capabilities(",
            "observed_virtual_display_capability_set_is_exact(",
            ".then(required_current_virtual_display_modes)",
        ], in: exactCapabilities)
        XCTAssertEqual(
            occurrences(
                of: "capture_current_virtual_display_topology_local_with_policy(true)",
                in: controller
            ),
            1
        )
        XCTAssertEqual(
            occurrences(
                of: "capture_current_virtual_display_topology_local_with_policy(false)",
                in: controller
            ),
            1
        )

        let semantic = try functionBody(
            controller,
            beginningWith: "fn self_test_dynamic_selected_virtual_display_protocol()",
            endingBefore: "fn self_test()"
        )
        for token in [
            "modes.iter().cloned().collect::<BTreeSet<_>>().len() != 6",
            "for (index, mode) in modes.iter().enumerate()",
            "parse_virtual_display_snapshot_text(&snapshot)? != topology",
            "parse_virtual_display_restore_target_text(&restore_target)? != *mode",
            "dynamic virtual-display protocol round trip failed for mapping {index}",
            "selected=720:1280:720:1280:60000",
            "selected=1920:1080:1920:1080:60000",
            "selected=603:1312:1206:2622:60000",
            "virtual-display snapshot zero identity field",
            "virtual-display snapshot noncanonical selected tuple",
            "virtual-display snapshot dimension overflow",
            "virtual-display snapshot refresh overflow",
            "virtual-display snapshot bad refresh",
            "virtual-display snapshot missing field",
            "virtual-display snapshot identity substitution",
            "virtual-display snapshot reordered capability tuples",
            "virtual-display snapshot missing capability tuple",
            "virtual-display snapshot duplicate selected key",
            "virtual-display snapshot extra key",
            "virtual-display restore noncanonical number",
            "let reviewed_raw_modes = modes.iter().map(strict_observation).collect::<Vec<_>>()",
            "let zero_hz_extra = raw_display_mode_observation_from_values(640, 480, 640, 480, 0.0)",
            "raw_display_mode_observation_from_values(800, 600, 1_600, 1_200, 30.0)",
            "f64::NAN",
            "f64::INFINITY",
            "let mut raw_modes_with_irrelevant_extras = reviewed_raw_modes.clone()",
            "unsupported_selected_observation.clone()",
            "zero_hz_extra.clone()",
            "non_sixty_extra.clone()",
            "nonfinite_extra.clone()",
            "unknown_extra.clone()",
            "let mut missing_required_modes = raw_modes_with_irrelevant_extras.clone()",
            "missing_required_modes.remove(2)",
            "duplicate_required_modes.push(strict_observation(&modes[2]))",
            "duplicate_interim_selected_modes.push(unsupported_selected_observation.clone())",
            "!observed_virtual_display_capability_set_is_exact(",
            "&raw_modes_with_irrelevant_extras",
            "normalized_reviewed_virtual_display_capabilities(",
            "Some(modes.clone())",
            "&missing_required_modes",
            "&duplicate_required_modes",
            "exact_raw_display_mode_match_count(&[], &modes[0]) != 0",
            "exact_raw_display_mode_match_count(&reviewed_raw_modes, &modes[0]) != 1",
            "exact_raw_display_mode_match_count(&duplicate_target_modes, &modes[0]) != 2",
            "zero_hz_extra.strict_identity.is_some()",
            "non_sixty_extra.strict_identity.is_some()",
            "nonfinite_extra.strict_identity.is_some()",
            "unknown_extra.strict_identity.is_some()",
            "zero_hz_extra.refresh_rate_bits != 0.0_f64.to_bits()",
            "non_sixty_extra.refresh_rate_bits != 30.0_f64.to_bits()",
            "nonfinite_extra.refresh_rate_bits != f64::NAN.to_bits()",
            "unknown_extra.refresh_rate_bits != f64::INFINITY.to_bits()",
            "strict_display_mode_identity_from_observation(&zero_hz_extra).is_ok()",
            "strict_display_mode_identity_from_observation(&non_sixty_extra).is_ok()",
            "strict_display_mode_identity_from_observation(&nonfinite_extra).is_ok()",
            "current_virtual_display_selected_mode_is_exact(&wrong_identity_topology)",
            "raw virtual-display inventory did not ignore lossless unknown/zero/non-60 extras or rejected exact required-mode semantics",
        ] {
            XCTAssertTrue(semantic.contains(token), "missing dynamic-display case: \(token)")
        }
        assertOrdered([
            "|| !observed_virtual_display_capability_set_is_exact(",
            "&raw_modes_with_irrelevant_extras",
            "&modes[0]",
            "false",
            "&raw_modes_with_irrelevant_extras",
            "&modes[0]",
            "true",
            "&raw_modes_with_irrelevant_extras",
            "&unsupported",
            "false",
            "&raw_modes_with_irrelevant_extras",
            "&unsupported",
            "true",
            "normalized_reviewed_virtual_display_capabilities(",
            "&raw_modes_with_irrelevant_extras",
            "&modes[0]",
            "false",
            ") != Some(modes.clone())",
        ], in: semantic)
        XCTAssertFalse(semantic.contains(
            "unsupported/seventh virtual-display capability entered a stable reviewed snapshot"
        ))
        XCTAssertTrue(controller.contains("self_test_dynamic_selected_virtual_display_protocol()?;"))
        try assertRawDisplayExtrasAndOwnedCoreGraphicsResources(controller)
    }

    private func assertRawDisplayExtrasAndOwnedCoreGraphicsResources(
        _ controller: String
    ) throws {
        let observationType = try functionBody(
            controller,
            beginningWith: "struct RawDisplayModeObservation {",
            endingBefore: "struct VirtualDisplayTopology {"
        )
        for token in [
            "logical_width: usize",
            "logical_height: usize",
            "pixel_width: usize",
            "pixel_height: usize",
            "refresh_rate_bits: u64",
            "strict_identity: Option<DisplayModeIdentity>",
        ] {
            XCTAssertTrue(observationType.contains(token), "raw observation lost field: \(token)")
        }

        let rawClassifier = try functionBody(
            controller,
            beginningWith: "fn normalize_display_refresh_millihertz(",
            endingBefore: "fn copy_current_virtual_display_modes_with_duplicates("
        )
        assertOrdered([
            "!refresh_rate.is_finite()",
            "(refresh_rate - 60.0).abs() > 0.05",
            "fn raw_display_mode_observation_from_values(",
            "normalize_display_refresh_millihertz(refresh_rate)",
            ".ok()",
            ".map(|refresh_millihertz| DisplayModeIdentity",
            "refresh_rate_bits: refresh_rate.to_bits()",
            "strict_identity",
            "fn raw_display_mode_observation(",
            "CGDisplayModeGetWidth(mode)",
            "CGDisplayModeGetHeight(mode)",
            "CGDisplayModeGetPixelWidth(mode)",
            "CGDisplayModeGetPixelHeight(mode)",
            "CGDisplayModeGetRefreshRate(mode)",
            "fn strict_display_mode_identity_from_observation(",
            "observation.strict_identity.clone().ok_or_else",
            "selected virtual-display mode is not a strict 60 Hz identity",
            "fn display_mode_identity(",
            "strict_display_mode_identity_from_observation(&raw_display_mode_observation(mode))",
        ], in: rawClassifier)
        XCTAssertFalse(rawClassifier.contains("normalize_display_refresh_millihertz(refresh_rate)?"))

        let scoped = try functionBody(
            controller,
            beginningWith: "struct ScopedResource<T, F: FnMut(T)> {",
            endingBefore: "fn release_owned_cf_object("
        )
        assertOrdered([
            "value: Option<T>",
            "fn new(value: T, cleanup: F)",
            "value: Some(value)",
            "fn take(&mut self) -> T",
            "self.value",
            ".take()",
            "impl<T, F: FnMut(T)> Drop for ScopedResource<T, F>",
            "if let Some(value) = self.value.take()",
            "(self.cleanup)(value)",
        ], in: scoped)
        XCTAssertEqual(occurrences(of: "(self.cleanup)(value)", in: scoped), 1)

        let owned = try functionBody(
            controller,
            beginningWith: "fn release_owned_cf_object(",
            endingBefore: "fn cancel_pending_display_configuration("
        )
        assertOrdered([
            "unsafe { CFRelease(pointer.as_ptr()) }",
            "struct OwnedCfObject",
            "fn from_copy(pointer: *const std::ffi::c_void, label: &str) -> Result<Self>",
            "std::ptr::NonNull::new(pointer.cast_mut())",
            "ScopedResource::new(",
            "release_owned_cf_object",
            "fn as_ptr(&self) -> *const std::ffi::c_void",
            "self.resource.value().as_ptr()",
        ], in: owned)
        XCTAssertEqual(occurrences(of: "CFRelease(", in: owned), 1)

        let configurationGuard = try functionBody(
            controller,
            beginningWith: "fn cancel_pending_display_configuration(",
            endingBefore: "fn required_current_virtual_display_modes()"
        )
        assertOrdered([
            "CGCancelDisplayConfiguration(pointer.as_ptr())",
            "struct PendingDisplayConfiguration",
            "fn begin() -> Result<Self>",
            "CGBeginDisplayConfiguration(&mut pointer)",
            "let pending = std::ptr::NonNull::new(pointer).map(|pointer| Self",
            "ScopedResource::new(",
            "cancel_pending_display_configuration",
            "if status != 0",
            "pending.ok_or_else",
            "fn complete_for_session(mut self) -> i32",
            "let pointer = self.resource.take()",
            "CGCompleteDisplayConfiguration(pointer.as_ptr(), DISPLAY_CONFIGURATION_FOR_SESSION)",
        ], in: configurationGuard)
        XCTAssertEqual(
            occurrences(of: "CGCancelDisplayConfiguration(", in: configurationGuard),
            1
        )
        XCTAssertEqual(
            occurrences(of: "CGCompleteDisplayConfiguration(", in: configurationGuard),
            1
        )

        let copyModes = try functionBody(
            controller,
            beginningWith: "fn copy_current_virtual_display_modes_with_duplicates(",
            endingBefore: "fn observed_virtual_display_capability_set_is_exact("
        )
        assertOrdered([
            "let options = OwnedCfObject::from_copy",
            "CFDictionaryCreate(",
            "CGDisplayCopyAllDisplayModes(display, options.as_ptr())",
            "current virtual display mode set",
        ], in: copyModes)
        XCTAssertEqual(occurrences(of: "OwnedCfObject::from_copy", in: copyModes), 2)
        XCTAssertFalse(copyModes.contains("CFRelease("))

        let capture = try functionBody(
            controller,
            beginningWith: "fn capture_current_virtual_display_topology_local_with_policy(",
            endingBefore: "fn display_capability_set_token("
        )
        assertOrdered([
            "let mode = OwnedCfObject::from_copy(",
            "CGDisplayCopyDisplayMode(display)",
            "let selected_mode = display_mode_identity(mode.as_ptr())?",
            "let all_modes = copy_current_virtual_display_modes_with_duplicates(display)?",
            "CFArrayGetCount(all_modes.as_ptr())",
            "let available = unsafe { CFArrayGetValueAtIndex(all_modes.as_ptr(), index) }",
            "if available.is_null()",
            "available_modes.push(raw_display_mode_observation(available))",
            "exact_raw_display_mode_match_count(&available_modes, &selected_mode)",
            "raw_selected_mode_matches != 1",
            "normalized_reviewed_virtual_display_capabilities(",
            "available_modes: authenticated_available_modes",
        ], in: capture)
        XCTAssertEqual(occurrences(of: "OwnedCfObject::from_copy", in: capture), 1)
        XCTAssertFalse(capture.contains("OwnedCfObject::from_copy(available"))
        XCTAssertFalse(capture.contains("CFRelease("))

        let apply = try functionBody(
            controller,
            beginningWith: "fn apply_exact_current_virtual_display_mode_local(",
            endingBefore: "fn restore_exact_current_virtual_display_mode_after_host_restart("
        )
        assertOrdered([
            "if !current_virtual_display_mode_is_reviewed(target)",
            "capture_current_virtual_display_topology_local_with_policy(true)?",
            "let all_modes = copy_current_virtual_display_modes_with_duplicates(display)?",
            "let candidate = unsafe { CFArrayGetValueAtIndex(all_modes.as_ptr(), index) }",
            "if candidate.is_null()",
            "let observation = raw_display_mode_observation(candidate)",
            "observation.strict_identity.as_ref() == Some(target)",
            "let matches = exact_raw_display_mode_match_count(&observed_modes, target)",
            "if matches != 1",
            "let selected_again = OwnedCfObject::from_copy(",
            "display_mode_identity(selected_again.as_ptr())?",
            "drop(selected_again)",
            "let configuration = PendingDisplayConfiguration::begin()?",
            "CGConfigureDisplayWithDisplayMode(",
            "if configure != 0",
            "let complete = configuration.complete_for_session()",
            "drop(all_modes)",
            "if complete != 0",
            "read_current_virtual_display_topology_local()",
            "selected_virtual_display_mode(&topology) == *target",
        ], in: apply)
        XCTAssertEqual(occurrences(of: "OwnedCfObject::from_copy", in: apply), 1)
        XCTAssertFalse(apply.contains("OwnedCfObject::from_copy(candidate"))
        XCTAssertFalse(apply.contains("CFRelease("))
        XCTAssertFalse(apply.contains("CGCancelDisplayConfiguration("))

        let ownershipFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_core_graphics_scoped_resource_ownership()",
            endingBefore: "fn self_test_dynamic_selected_virtual_display_protocol()"
        )
        for token in [
            "normal_cleanup_count.get() != 1",
            "injected_error.is_ok()",
            "error_cleanup_count.get() != 1",
            "disarmed_cleanup_count.get() != 0",
            "CoreGraphics scoped resource single-release/disarm model failed",
            "capture_body.contains(\"OwnedCfObject::from_copy\")",
            "capture_body.contains(\"raw_display_mode_observation(available)\")",
            "capture_body.contains(\"CFRelease(\")",
            "apply_body.contains(\"PendingDisplayConfiguration::begin()\")",
            "apply_body.contains(\"CFRelease(\")",
            "let begin_position = configuration_body.find(\"CGBeginDisplayConfiguration\")",
            "let guarded_position = configuration_body.find(\"let pending = std::ptr::NonNull::new(pointer)\")",
            "let error_position = configuration_body.find(\"if status != 0\")",
            "let disarm_position = configuration_body.find(\"let pointer = self.resource.take();\")",
            "let complete_position = configuration_body.find(\"CGCompleteDisplayConfiguration\")",
            "begin < guarded && guarded < error",
            "disarm < complete",
            "configuration_body.contains(\"cancel_pending_display_configuration\")",
            "CoreGraphics owned-CF/configuration cancellation structure changed",
        ] {
            XCTAssertTrue(ownershipFixture.contains(token), "missing cleanup fixture: \(token)")
        }
        XCTAssertTrue(controller.contains("self_test_core_graphics_scoped_resource_ownership()?;"))
    }

    func testUID501DisplaySnapshotRestoreBindsIdentityNormalizedCapabilitiesAndUniqueRequiredModes() throws {
        let controller = try source(controllerPath)
        for token in [
            #"const UID501_DISPLAY_SNAPSHOT_MODE: &str = "--uid501-current-virtual-display-snapshot";"#,
            #"const UID501_DISPLAY_RESTORE_MODE: &str = "--uid501-restore-current-virtual-display";"#,
        ] {
            XCTAssertTrue(controller.contains(token), "missing UID501 display mode: \(token)")
        }

        let dispatch = try functionBody(
            controller,
            beginningWith: "[_, mode] if mode == UID501_DISPLAY_SNAPSHOT_MODE",
            endingBefore: "_ => Err(ControllerError(format!("
        )
        assertOrdered([
            "require_uid501_display_helper_identity()?",
            "read_current_virtual_display_topology_local()?",
            "print!(\"{}\", virtual_display_snapshot_text(&topology))",
            "UID501_DISPLAY_RESTORE_MODE",
            "require_uid501_display_helper_identity()?",
            "parse_virtual_display_restore_target_text(target)?",
            "apply_exact_current_virtual_display_mode_local(&target)?",
            "read_current_virtual_display_topology_local()?",
            "restored_virtual_display_matches_target(&topology, &target)",
            "print!(\"{}\", virtual_display_snapshot_text(&topology))",
        ], in: dispatch)

        let capture = try functionBody(
            controller,
            beginningWith: "fn capture_current_virtual_display_topology_local_with_policy(",
            endingBefore: "fn display_capability_set_token("
        )
        for token in [
            "count != 1",
            "CGMainDisplayID()",
            "CGDisplayIsOnline",
            "CGDisplayIsActive",
            "CGDisplayMirrorsDisplay",
            "CGDisplayVendorNumber",
            "CGDisplayModelNumber",
            "CGDisplaySerialNumber",
            "copy_current_virtual_display_modes_with_duplicates(display)?",
            "if !(1..=256).contains(&mode_count)",
            "exact_raw_display_mode_match_count(&available_modes, &selected_mode)",
            "raw_selected_mode_matches != 1",
            "normalized_reviewed_virtual_display_capabilities(",
            "&available_modes",
            "&selected_mode",
            "available_modes: authenticated_available_modes",
            "capture_current_virtual_display_topology_local_with_policy(false)",
            "topology.available_modes == required_current_virtual_display_modes()",
        ] {
            XCTAssertTrue(capture.contains(token), "missing exact capture proof: \(token)")
        }
        XCTAssertFalse(capture.contains(
            "available_modes.len() == required_current_virtual_display_modes().len()"
        ))

        let snapshot = try functionBody(
            controller,
            beginningWith: "fn virtual_display_snapshot_text(",
            endingBefore: "fn virtual_display_restore_target_text("
        )
        assertOrdered([
            "{DISPLAY_SNAPSHOT_HEADER}",
            "identity={}:{}:{}",
            "selected={}",
            "required_mappings={}",
            "lines.next() != Some(DISPLAY_SNAPSHOT_HEADER)",
            "!text.ends_with('\\n')",
            "values.insert(key.to_owned(), value.to_owned()).is_some()",
            "[\"identity\", \"required_mappings\", \"selected\"]",
            "identity_fields.len() != 3",
            "require_canonical_positive_decimal(field, \"UID501 virtual-display identity\")?",
            "vendor != CURRENT_VIRTUAL_DISPLAY_VENDOR",
            "product != CURRENT_VIRTUAL_DISPLAY_PRODUCT",
            "serial != CURRENT_VIRTUAL_DISPLAY_SERIAL",
            "parse_canonical_display_mode_identity(",
            "mappings != display_capability_set_token(&expected_mappings)",
            "virtual_display_snapshot_text(&topology) != text",
        ], in: snapshot)

        let restore = try functionBody(
            controller,
            beginningWith: "fn virtual_display_restore_target_text(",
            endingBefore: "fn root_request_display_matches_generation("
        )
        for token in [
            "if !current_virtual_display_mode_is_reviewed(target)",
            "{DISPLAY_RESTORE_TARGET_HEADER}\\nselected={}\\n",
            "lines.clone().count() != 1",
            ".strip_prefix(\"selected=\")",
            "parse_canonical_display_mode_identity(",
            "virtual_display_restore_target_text(&target)? != text",
            "topology.vendor == CURRENT_VIRTUAL_DISPLAY_VENDOR",
            "topology.product == CURRENT_VIRTUAL_DISPLAY_PRODUCT",
            "topology.serial == CURRENT_VIRTUAL_DISPLAY_SERIAL",
            "topology.available_modes == required_current_virtual_display_modes()",
            "selected_virtual_display_mode(topology) == *target",
        ] {
            XCTAssertTrue(restore.contains(token), "missing exact restore protocol: \(token)")
        }

        let helper = try functionBody(
            controller,
            beginningWith: "fn require_uid501_display_helper_identity()",
            endingBefore: "fn apply_exact_current_virtual_display_mode_local("
        )
        assertOrdered([
            "getuid() } != USER_ID",
            "geteuid() } != USER_ID",
            "fn run_uid501_display_helper(",
            "bounded_aqua_uid501_hal_output_in_directory(",
            "path_text(&executable)?",
            "HOST_TIMEOUT",
            "require_success(&output, label)?",
            "if !output.stderr.is_empty()",
            "String::from_utf8(output.stdout)",
            "parse_virtual_display_snapshot_text(&text)",
            "UID501_DISPLAY_SNAPSHOT_MODE",
        ], in: helper)

        let apply = try functionBody(
            controller,
            beginningWith: "fn apply_exact_current_virtual_display_mode_local(",
            endingBefore: "fn restore_exact_current_virtual_display_mode_after_host_restart("
        )
        assertOrdered([
            "if !current_virtual_display_mode_is_reviewed(target)",
            "capture_current_virtual_display_topology_local_with_policy(true)?",
            "CGDisplayVendorNumber",
            "CGDisplayModelNumber",
            "CGDisplaySerialNumber",
            "copy_current_virtual_display_modes_with_duplicates(display)?",
            "exact_raw_display_mode_match_count(&observed_modes, target)",
            "if matches != 1",
            "!observed_virtual_display_capability_set_is_exact(",
            "&observed_modes",
            "&selected_virtual_display_mode(&topology)",
            "PendingDisplayConfiguration::begin()?",
            "CGConfigureDisplayWithDisplayMode",
            "configuration.complete_for_session()",
            "read_current_virtual_display_topology_local()",
            "selected_virtual_display_mode(&topology) == *target",
        ], in: apply)

        let displayOnly = [capture, snapshot, restore, helper, apply].joined(separator: "\n")
        for forbidden in [
            "AudioObjectSetPropertyData",
            "reload_coreaudio_exact",
            "stable_fresh_route_snapshot_for_generation",
            "SwitchAudioSource",
            "set_default_route",
        ] {
            XCTAssertFalse(displayOnly.contains(forbidden), "display protocol mutated route: \(forbidden)")
        }
    }

    func testDisplayBaselineIsDurableAcrossPreflightForwardRollbackAndSealedRecovery() throws {
        let controller = try source(controllerPath)
        let hostType = try functionBody(
            controller,
            beginningWith: "struct HostGeneration {",
            endingBefore: "struct HostStartupIdentity {"
        )
        XCTAssertTrue(hostType.contains("display_mode: DisplayModeIdentity"))
        let requestType = try functionBody(
            controller,
            beginningWith: "struct RootRequest {",
            endingBefore: "fn main()"
        )
        XCTAssertTrue(requestType.contains("display_topology: VirtualDisplayTopology"))

        let liveHost = try functionBody(
            controller,
            beginningWith: "fn verify_live_current_host()",
            endingBefore: "fn restore_and_verify_live_current_host("
        )
        assertOrdered([
            "read_current_virtual_display_topology()?",
            "selected_virtual_display_mode(&initial_display_topology)",
            "verify_live_current_host_generation_only(&selected_mode)?",
            "read_current_virtual_display_topology()? != initial_display_topology",
        ], in: liveHost)

        let requestProtocol = try functionBody(
            controller,
            beginningWith: "fn root_request_text(",
            endingBefore: "fn acquire_user_update_lock("
        )
        for token in [
            "display_identity={}:{}:{}",
            "display_selected={}",
            "display_capabilities={}",
            "display_mode_identity_token(&selected_virtual_display_mode(",
            "display_capability_set_token(&request.display_topology.available_modes)",
            "\"display_capabilities\"",
            "\"display_identity\"",
            "\"display_selected\"",
            "parse_virtual_display_snapshot_text(&display_snapshot)?",
        ] {
            XCTAssertTrue(requestProtocol.contains(token), "missing sealed display binding: \(token)")
        }

        let journalValidation = try functionBody(
            controller,
            beginningWith: "fn validate_journal_fields(",
            endingBefore: "fn parse_journal_text("
        )
        XCTAssertGreaterThanOrEqual(occurrences(of: "\"display_mode\"", in: journalValidation), 3)
        XCTAssertTrue(journalValidation.contains(
            "parse_canonical_display_mode_identity(value, \"journal display mode\")?"
        ))

        let rootState = try functionBody(
            controller,
            beginningWith: "fn write_root_state_tracked(",
            endingBefore: "fn journal_and_root_state_are_crash_coherent("
        )
        for token in [
            "initial_host: &HostGeneration",
            "initial_host_display_mode={}",
            "display_mode_identity_token(&initial_host.display_mode)",
            "fn write_root_state(",
            "write_root_state_tracked(layout, state, initial_host, route, None)",
            ".remove(\"initial_host_display_mode\")",
            "parse_canonical_display_mode_identity(",
            "display_mode,",
        ] {
            XCTAssertTrue(rootState.contains(token), "missing durable state display binding: \(token)")
        }

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "= verify_complete_preflight(",
            "display_topology: virtual_display_topology_for_selected(&initial.display_mode)?",
            "display_mode_identity_token(&initial.display_mode)",
            "= verify_complete_preflight(",
            "final_host != initial",
            "run_sudo_helper(&root_controller, ROOT_MODE",
        ], in: execute)

        let authenticatedFields = try functionBody(
            controller,
            beginningWith: "fn root_authenticated_journal_fields(",
            endingBefore: "fn perform_root_transaction("
        )
        assertOrdered([
            "\"display_mode\"",
            "display_mode_identity_token(&initial.display_mode)",
        ], in: authenticatedFields)

        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "let request = parse_bootstrap_root_request(request_path)?",
            "let initial = verify_live_current_host()?",
            "if !root_request_display_matches_generation(&request, &initial)",
            "root_authenticated_journal_fields(",
            "journal.record(UpdateState::Authenticated, &authenticated_fields)?",
            "write_root_state(",
            "UpdateState::Authenticated",
            "if verify_live_current_host()? != initial",
            "if !root_request_display_matches_generation(&request, &initial)",
            "write_root_state(",
            "UpdateState::Authenticated",
            "write_root_state_tracked(",
            "UpdateState::HostStopInitiated",
            "&initial",
        ], in: transaction)
        XCTAssertTrue(transaction.contains("stable_fresh_route_snapshot_for_generation(&baseline_coreaudio)?"))
        XCTAssertTrue(transaction.contains("stable_fresh_route_snapshot_for_generation(&new_coreaudio)?"))

        let forwardRestart = try functionBody(
            controller,
            beginningWith: "fn restart_exact_current_host(",
            endingBefore: "fn replacement_current_host_startup_identity_is_exact("
        )
        for token in [
            "verify_live_current_host_generation_only(&initial.display_mode)",
            "replacement.display_mode == initial.display_mode",
            "restore_exact_current_virtual_display_mode_after_host_restart(&initial.display_mode)?",
            "verify_live_current_host()? != generation",
        ] {
            XCTAssertTrue(forwardRestart.contains(token), "forward restart lost display target: \(token)")
        }

        let rollbackRestart = try functionBody(
            controller,
            beginningWith: "fn restart_or_recover_exact_current_host(",
            endingBefore: "fn stop_current_host_for_rollback("
        )
        assertOrdered([
            "verify_live_current_host_generation_only(&initial.display_mode)",
            "replacement_current_host_generation_is_exact(initial, &generation)",
            "restore_exact_current_virtual_display_mode_after_host_restart(&initial.display_mode)?",
            "verify_live_current_host()? != generation",
            "restart_exact_current_host(initial)",
        ], in: rollbackRestart)

        let rollback = try functionBody(
            controller,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        for token in [
            "if durable_initial != *initial",
            "restore_and_verify_live_current_host(&initial.display_mode)?",
            "restart_or_recover_exact_current_host(initial)?",
            "UpdateState::HostRebootstrapped",
            "write_root_state(layout, UpdateState::RolledBack, initial, baseline_route)?",
        ] {
            XCTAssertTrue(rollback.contains(token), "rollback lost display target: \(token)")
        }

        let terminalRepair = try functionBody(
            controller,
            beginningWith: "fn repair_committed_terminal_state(",
            endingBefore: "fn rollback_resume_action("
        )
        XCTAssertEqual(
            occurrences(
                of: "restore_and_verify_live_current_host(&initial.display_mode)?",
                in: terminalRepair
            ),
            2
        )
        XCTAssertTrue(terminalRepair.contains("write_root_state(layout, UpdateState::Committed, &initial"))
        XCTAssertTrue(terminalRepair.contains("write_root_state(layout, UpdateState::RolledBack, &initial"))
        XCTAssertTrue(terminalRepair.contains("if host != initial"))

        let durableBinding = try functionBody(
            controller,
            beginningWith: "fn verify_durable_root_display_binding(",
            endingBefore: "fn read_root_active_layout("
        )
        assertOrdered([
            "journal.exact_fields_for_state(UpdateState::Authenticated)",
            "authenticated.get(\"display_mode\")",
            "request_journal_state_display_binding_is_exact(",
            "durable_state == UpdateState::PrestopAborted",
            "journal.state == UpdateState::PrestopAborted",
            "fn complete_root_recovery(",
            "verify_durable_root_display_binding(&request, &journal, *state, initial)?",
            "let effective_journal = journal.effective_state_with_pending()?",
            "let plan = root_recovery_plan(",
            "rollback_root_transaction(&layout, &mut journal, &initial, route.as_ref())?",
        ], in: durableBinding)

        for semanticCase in [
            "request/journal/state display mismatch was not rejected",
            "root display baseline differs from the sealed UID501 preflight snapshot",
            "sealed display baseline changed before durable stop intent",
            "sealed request, authenticated journal, and durable display baseline differ",
        ] {
            XCTAssertTrue(controller.contains(semanticCase), "missing durable display case: \(semanticCase)")
        }
    }

    func testDisplayRecoveryRepairsWrongReviewedModeAndAuthenticatesEveryAbortDispatchBoundary() throws {
        let controller = try source(controllerPath)

        let rollbackStop = try functionBody(
            controller,
            beginningWith: "fn rollback_host_requires_exact_display_restore(",
            endingBefore: "fn verify_retained_v7_driver("
        )
        assertOrdered([
            "observed.display_mode != initial.display_mode",
            "fn stop_current_host_for_rollback(",
            "match verify_live_current_host()",
            "Ok(generation) if !rollback_host_requires_exact_display_restore(&generation, initial)",
            "Ok(_) | Err(_) => restore_and_verify_live_current_host(&initial.display_mode)",
            "generation.display_mode != initial.display_mode",
            "stop_exact_current_host(&generation)",
            "reconcile_post_bootstrap_pre_lock_host_for_rollback(initial)",
        ], in: rollbackStop)

        let rollbackFixture = try functionBody(
            controller,
            beginningWith: "fn self_test_post_bootstrap_pre_lock_recovery_admission()",
            endingBefore: "fn self_test_uid501_blocking_mutating_sudo_staging_guard("
        )
        assertOrdered([
            "let same_display_host = initial.clone()",
            "wrong_reviewed_display_host.display_mode = required_current_virtual_display_modes()[1].clone()",
            "rollback_host_requires_exact_display_restore(&same_display_host, &initial)",
            "!rollback_host_requires_exact_display_restore(&wrong_reviewed_display_host, &initial)",
        ], in: rollbackFixture)

        let pointerless = try functionBody(
            controller,
            beginningWith: "fn finalize_sealed_bootstrap_without_root_pointer(",
            endingBefore: "fn root_sealed_rollback_authorized_update("
        )
        assertOrdered([
            "let request = parse_root_request_text(",
            "let host = verify_live_current_host()?",
            "if !root_request_display_matches_generation(&request, &host)",
            "verify_pairing_metadata_only()?",
            "let layout = root_layout(&request.nonce)?",
            "journal.record(UpdateState::PrestopAborted, &[])?",
            "write_root_state(&layout, UpdateState::PrestopAborted, &host, None)?",
            "write_root_recovery_result(",
            "display_mode={}",
            "display_mode_identity_token(&host.display_mode)",
            "DIAGNOSTIC_DRIVER_V12_ROOT_PRESTOP_ABORTED host_pid={} display_mode={}",
            "display_mode_identity_token(&host.display_mode)",
        ], in: pointerless)

        let rootBinding = try functionBody(
            controller,
            beginningWith: "fn verify_durable_root_display_binding(",
            endingBefore: "fn read_root_active_layout("
        )
        for token in [
            "if !root_request_display_matches_generation(request, initial)",
            "match journal.exact_fields_for_state(UpdateState::Authenticated)",
            "request_journal_state_display_binding_is_exact(request, journal_mode, initial)",
            "durable_state == UpdateState::PrestopAborted",
            "journal.state == UpdateState::PrestopAborted",
            "{ROOT_JOURNAL_HEADER}\\nSTATE BEGUN\\nSTATE PRESTOP_ABORTED\\n",
            "durable display baseline has no authenticated journal binding",
            "verify_durable_root_display_binding(&request, &journal, *state, initial)?",
        ] {
            XCTAssertTrue(rootBinding.contains(token), "missing abort/recovery binding: \(token)")
        }
        let bindingPosition = rootBinding.range(
            of: "verify_durable_root_display_binding(&request, &journal, *state, initial)?"
        )
        let planPosition = rootBinding.range(of: "let plan = root_recovery_plan(")
        XCTAssertNotNil(bindingPosition)
        XCTAssertNotNil(planPosition)
        if let bindingPosition, let planPosition {
            XCTAssertLessThan(bindingPosition.lowerBound, planPosition.lowerBound)
        }

        let userDispatch = try functionBody(
            controller,
            beginningWith: "fn user_authenticated_root_dispatch_binding_is_exact(",
            endingBefore: "fn acquire_user_update_lock("
        )
        for token in [
            "\"display_mode\"",
            "\"host_pid\"",
            "\"nonce\"",
            "\"release_commit\"",
            "\"release_tree\"",
            "authenticated.keys().map(String::as_str).collect::<BTreeSet<_>>() == expected_keys",
            "root_request_display_matches_generation(request, initial)",
            "authenticated.get(\"nonce\") == Some(&request.nonce)",
            "authenticated.get(\"host_pid\") == Some(&initial.pid.to_string())",
            "authenticated.get(\"display_mode\")",
            "display_mode_identity_token(&initial.display_mode)",
            "authenticated.get(\"release_commit\") == Some(&request.authorized_commit)",
            "authenticated.get(\"release_tree\") == Some(&request.authorized_tree)",
            "fn verify_user_authenticated_root_dispatch_binding(",
            "journal.state != UpdateState::Authenticated",
            "let request_before = require_regular(&layout.request",
            "let request_text = read_bounded_utf8(&layout.request, 4_096)?",
            "let request_after = require_regular(&layout.request",
            "identity_from_metadata(&request_before) != identity_from_metadata(&request_after)",
            "let reread_request = parse_root_request_text(&request_text)?",
            "root_request_text(&reread_request)? != root_request_text(expected_request)?",
            "let journal_before = require_regular(&layout.journal",
            "journal.exact_fields_for_state(UpdateState::Authenticated)?",
            "let journal_after = require_regular(&layout.journal",
            "identity_from_metadata(&journal_before) != identity_from_metadata(&journal_after)",
            "user_authenticated_root_dispatch_binding_is_exact(",
        ] {
            XCTAssertTrue(userDispatch.contains(token), "missing user dispatch binding: \(token)")
        }

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "final_host != initial",
            "verify_user_authenticated_root_dispatch_binding(&layout, &journal, &request, &initial)?",
            "run_sudo_helper(&root_controller, ROOT_MODE, Some(&root_bootstrap_request))?",
        ], in: execute)

        let semantic = try functionBody(
            controller,
            beginningWith: "let authenticated_dispatch = BTreeMap::from([",
            endingBefore: "let request_tree_line = format!("
        )
        for token in [
            "let mut substituted_dispatch = authenticated_dispatch.clone()",
            "substituted_dispatch.insert(",
            "let mut extra_dispatch = authenticated_dispatch.clone()",
            "extra_dispatch.insert(\"extra\".to_owned(), \"1\".to_owned())",
            "!user_authenticated_root_dispatch_binding_is_exact(",
            "user_authenticated_root_dispatch_binding_is_exact(",
            "&substituted_request",
            "&substituted_state_generation",
            "&extra_dispatch",
            "request/journal/state display mismatch was not rejected",
        ] {
            XCTAssertTrue(semantic.contains(token), "missing hostile dispatch case: \(token)")
        }
    }

    func testCoreAudioReloadIsDurableBeforeAnyPostReloadRouteProof() throws {
        let controller = try source(controllerPath)
        let transaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "let (old_coreaudio, new_coreaudio) = reload_coreaudio_exact(&baseline_coreaudio)?",
            "journal.record(", "UpdateState::CoreAudioReloaded",
            "write_root_state(", "UpdateState::CoreAudioReloaded",
            "prove_post_reload_routes(", "&new_coreaudio", "&baseline_route",
            "run_passive_driver_validation(",
        ], in: transaction)
        let reloadPosition = transaction.range(of: "UpdateState::CoreAudioReloaded")
        let proofPosition = transaction.range(of: "prove_post_reload_routes(")
        XCTAssertNotNil(reloadPosition)
        XCTAssertNotNil(proofPosition)
        if let reloadPosition, let proofPosition {
            XCTAssertLessThan(reloadPosition.lowerBound, proofPosition.lowerBound)
        }

        for semanticCase in [
            "COREAUDIO_RELOADED was not durable before route proof",
            "timeout classification was masked",
            "first transient then timeout",
            "first complete then timeout",
        ] {
            XCTAssertTrue(controller.contains(semanticCase), "missing ordering case: \(semanticCase)")
        }
    }

    func testRootTransactionRunsTheRealUID501DisplayCanaryBeforeStagingOrHostStop() throws {
        let controller = try source(controllerPath)
        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "parse_bootstrap_root_request(request_path)?",
            "verify_root_controller_identity(&request)?",
            "let initial = verify_live_current_host()?",
            "root_request_display_matches_generation(&request, &initial)",
            "stable_coreaudio_generation()?",
            "ensure_root_update_layout(&request.nonce)?",
            "stage_root_artifacts(&layout, &request)",
            "UpdateState::HostStopInitiated",
            "stop_exact_current_host(&initial)?",
        ], in: rootTransaction)

        let liveHost = try functionBody(
            controller,
            beginningWith: "fn verify_live_current_host()",
            endingBefore: "fn restore_and_verify_live_current_host("
        )
        assertOrdered([
            "read_current_virtual_display_topology()?",
            "selected_virtual_display_mode(&initial_display_topology)",
            "verify_live_current_host_generation_only(&selected_mode)?",
            "read_current_virtual_display_topology()? != initial_display_topology",
        ], in: liveHost)

        let snapshotPath = try functionBody(
            controller,
            beginningWith: "fn run_uid501_display_helper(",
            endingBefore: "fn apply_exact_current_virtual_display_mode_local("
        )
        assertOrdered([
            "bounded_aqua_uid501_hal_output_in_directory(",
            "if unsafe { geteuid() } == USER_ID",
            "read_current_virtual_display_topology_local()",
            "run_uid501_display_helper(",
            "UID501_DISPLAY_SNAPSHOT_MODE",
        ], in: snapshotPath)
        XCTAssertTrue(controller.contains("AQUA_UID501_HAL_EXEC_MODE"))
    }

    func testV12PureSelfTestExecutesTheNewRouteAndAquaSemantics() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let sourcePin = shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: launcher)
        let binaryPin = shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: launcher)
        XCTAssertEqual(shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher), "PINNED_FINAL_REVIEW")
        XCTAssertEqual(
            shellSingleQuotedValue("EXPECTED_MACOSX_DEPLOYMENT_TARGET", in: launcher),
            "26.0"
        )
        XCTAssertEqual(sourcePin, sha256Hex(controller))
        XCTAssertEqual(sourcePin?.count, 64)
        XCTAssertEqual(binaryPin?.count, 64)
        XCTAssertTrue(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v12"))
        XCTAssertFalse(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v8"))
        XCTAssertFalse(launcher.contains(#"if [ "$MODE" != "$SELF_TEST_MODE" ]; then"#))
        XCTAssertTrue(launcher.contains(
            #"[ "$CONTROLLER_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ] || {"#
        ))

        let deterministicCompile = try functionBody(
            launcher,
            beginningWith: "compile_controller() {",
            endingBefore: "CONTROLLER_A=\"$BUILD_ROOT_A/controller\""
        )
        assertOrdered([
            #"MACOSX_DEPLOYMENT_TARGET="$EXPECTED_MACOSX_DEPLOYMENT_TARGET" \"#,
            #""$RUSTC" --edition=2021 -D warnings -C opt-level=2"#,
            #"compile_controller "$BUILD_ROOT_A""#,
            #"compile_controller "$BUILD_ROOT_B""#,
        ], in: deterministicCompile)
        XCTAssertEqual(
            occurrences(of: #"compile_controller "$BUILD_ROOT_"#, in: deterministicCompile),
            2
        )

        for semanticCase in [
            "first transient then timeout",
            "first complete then timeout",
            "timeout classification was masked",
            "after-generation reserve was not preserved",
            "HAL child process group was not fully reaped",
            "Aqua HAL environment/credential contract changed",
            "route transcript canonical round trip failed",
            "COREAUDIO_RELOADED was not durable before route proof",
        ] {
            XCTAssertTrue(controller.contains(semanticCase), "missing executable case: \(semanticCase)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot.appendingPathComponent(launcherPath).path,
            "--self-test-diagnostic-driver-v12-update",
        ]
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
        XCTAssertNotNil(
            output.range(
                of: #"\ADIAGNOSTIC_DRIVER_V12_SELF_TEST_OK tests=[1-9][0-9]*\n\z"#,
                options: .regularExpression
            ),
            output
        )
        XCTAssertEqual(error, "")
    }
}
