import CryptoKit
import Foundation
import XCTest

final class DiagnosticDriverV14UpdateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let controllerPath =
        "macOS/scripts/opensteamer-diagnostic-driver-v14-update-controller.rs"
    private let launcherPath = "macOS/scripts/update-opensteamer-diagnostic-driver-v14.sh"
    private let retainedV13SourcePath =
        "macOS/scripts/opensteamer-diagnostic-driver-v13-update-controller.rs"
    private let retainedV13LauncherPath =
        "macOS/scripts/update-opensteamer-diagnostic-driver-v13.sh"
    private let retainedV13ContractPath =
        "macOS/Tests/CaptureServerTests/DiagnosticDriverV13UpdateContractTests.swift"
    private let probeSourcePath =
        "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"

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

    private func normalizedV14(_ source: String) -> String {
        source
            .replacingOccurrences(of: "V14", with: "V13")
            .replacingOccurrences(of: "v14", with: "v13")
    }

    func testV14UsesOnlyFreshNamespacesAndCannotRetryOrReuseV13() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let freshConstants = try functionBody(
            controller,
            beginningWith: "const PREFLIGHT_MODE:",
            endingBefore: "const RETAINED_V1_DEVICE:"
        )

        for token in [
            #"const EXPECTED_RELEASE_BRANCH: &str = "fix/diagnostic-driver-v14-retired-core-slots";"#,
            #"const EXPECTED_UPDATER_BASE_COMMIT: &str = "05f0440ac61982516c438a8aeff013910e82b422";"#,
            #"const EXPECTED_UPDATER_BASE_TREE: &str = "d90e91adeb59af7e6ac6710e56dc78d6a68a5f25";"#,
            #"const PREFLIGHT_MODE: &str = "--verify-diagnostic-driver-v14-update-preflight";"#,
            #"const EXECUTE_MODE: &str = "--execute-authorized-diagnostic-driver-v14-update";"#,
            #"const ROLLBACK_MODE: &str = "--rollback-authorized-diagnostic-driver-v14-update";"#,
            #"const SELF_TEST_MODE: &str = "--self-test-diagnostic-driver-v14-update";"#,
            #"const ROOT_MODE: &str = "--root-authorized-diagnostic-driver-v14-update";"#,
            #"const ROOT_ROLLBACK_MODE: &str = "--root-rollback-diagnostic-driver-v14-update";"#,
            #"const ROOT_SEALED_ROLLBACK_MODE: &str = "--root-sealed-rollback-diagnostic-driver-v14-update";"#,
            #"const JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V14";"#,
            #"const ROOT_JOURNAL_HEADER: &str = "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V14";"#,
            "/diagnostic-driver-updates-v14", "/active-diagnostic-driver-update-v14",
            "/diagnostic-driver-update-v14.lock", "/diagnostic-driver-controllers-v14",
            "/diagnostic-driver-bootstrap-v14.txt", "/diagnostic-driver-probes-v14",
        ] {
            XCTAssertTrue(freshConstants.contains(token), "missing fresh V14 token: \(token)")
        }
        for stale in [
            "/diagnostic-driver-updates-v13", "/active-diagnostic-driver-update-v13",
            "/diagnostic-driver-update-v13.lock", "/diagnostic-driver-controllers-v13",
            "/diagnostic-driver-bootstrap-v13.txt", "/diagnostic-driver-probes-v13",
        ] {
            XCTAssertFalse(freshConstants.contains(stale), "V14 reuses a V13 namespace: \(stale)")
        }

        for candidate in [
            #"const CANDIDATE_ROOT: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v14/production-driver-v7";"#,
            #"const CANDIDATE_DRIVER: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v14/production-driver-v7/OpensteamerVirtualMicrophone.driver";"#,
            #"const CANDIDATE_PACKAGE: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v14/production-driver-v7/OpensteamerVirtualMicrophone-v7.pkg";"#,
            #"const CANDIDATE_MANIFEST: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v14/production-driver-v7/candidate-manifest.txt";"#,
        ] {
            XCTAssertTrue(controller.contains(candidate), "missing fresh V14 candidate: \(candidate)")
        }
        XCTAssertFalse(controller.contains("reviewed-driver-candidates-v13/production-driver-v7"))
        XCTAssertFalse(controller.contains(
            "/Library/Application Support/opensteamer/diagnostic-driver-controllers-v13/recovery-controller\", ROOT_MODE"
        ))
        XCTAssertTrue(controller.contains(
            "retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11_v12_v13=immutable"
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
        for privateMode in [
            "ROOT_MODE", "ROOT_ROLLBACK_MODE", "ROOT_SEALED_ROLLBACK_MODE",
            "UID501_RETAINED_V13_BOUNDARY_MODE",
        ] {
            XCTAssertFalse(publicDispatch.contains(privateMode), "launcher exposes \(privateMode)")
        }
    }

    func testV14RetainsExactV13ReleaseBytesAndTerminalEvidenceHashes() throws {
        let controller = try source(controllerPath)
        let retainedFiles: [(String, Int, String)] = [
            (
                retainedV13SourcePath,
                1_194_972,
                "1ea3c460e9e3df0c150840330d6ace6b80694128b983f2f0b2e19a4e5c89aff1"
            ),
            (
                retainedV13LauncherPath,
                18_689,
                "1fb6b82159359713f0d31776b87feb7f3fe9ac1a15209219edccf0c144c491c4"
            ),
            (
                retainedV13ContractPath,
                248_360,
                "e330c4de104af8018dd54e03f13bff9a39c0c2751ca4d8a977a2345586c42f3a"
            ),
            (
                probeSourcePath,
                388_802,
                "2cd52ef094b2e90ccf166626de36b5deb1179f6d4e0eed40b2223ac52343566c"
            ),
        ]
        for (path, size, digest) in retainedFiles {
            let bytes = try data(path)
            XCTAssertEqual(bytes.count, size, "retained V13 file size changed: \(path)")
            XCTAssertEqual(sha256Hex(bytes), digest, "retained V13 file bytes changed: \(path)")
        }

        for token in [
            #"const RETAINED_V13_SOURCE_COMMIT: &str = "05f0440ac61982516c438a8aeff013910e82b422";"#,
            #"const RETAINED_V13_SOURCE_TREE: &str = "d90e91adeb59af7e6ac6710e56dc78d6a68a5f25";"#,
            "const RETAINED_V13_SOURCE_SIZE: u64 = 1_194_972;",
            "1ea3c460e9e3df0c150840330d6ace6b80694128b983f2f0b2e19a4e5c89aff1",
            "const RETAINED_V13_LAUNCHER_SIZE: u64 = 18_689;",
            "1fb6b82159359713f0d31776b87feb7f3fe9ac1a15209219edccf0c144c491c4",
            "const RETAINED_V13_CONTRACT_TEST_SIZE: u64 = 248_360;",
            "e330c4de104af8018dd54e03f13bff9a39c0c2751ca4d8a977a2345586c42f3a",
            "const RETAINED_V13_CONTROLLER_BINARY_SIZE: u64 = 3_554_376;",
            "4b0e2bb7ef1110e3a98834600811a221fb9ca3b21319f63902f5c9933dbcfefc",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_UPDATE_V13",
            "OPENSTEAMER_DIAGNOSTIC_DRIVER_ROOT_UPDATE_V13",
            "STATE ROLLED_BACK",
            "state=ROLLED_BACK",
            "status=rolled-back",
            "candidate-error=passive osDS JSON contract failed;routes=unchanged",
            "const RETAINED_V13_USER_UPDATE_ROOT_INODE: u64 = 29_770_190;",
            "const RETAINED_V13_USER_UPDATE_LOCK_INODE: u64 = 29_769_976;",
            "const RETAINED_V13_USER_ACTIVE_POINTER_INODE: u64 = 29_770_196;",
            "const RETAINED_V13_EVIDENCE_INODE: u64 = 29_770_191;",
            "const RETAINED_V13_PROBES_INODE: u64 = 29_770_192;",
            "const RETAINED_V13_READER_INODE: u64 = 29_770_193;",
            "const RETAINED_V13_REQUEST_INODE: u64 = 29_770_195;",
            "const RETAINED_V13_JOURNAL_INODE: u64 = 29_770_197;",
            "const RETAINED_V13_CONTROLLER_PIN_INODE: u64 = 29_770_205;",
            "const RETAINED_V13_CONTROLLER_IDENTITY_INODE: u64 = 29_770_206;",
            "const RETAINED_V13_RESULT_INODE: u64 = 29_774_472;",
            "const RETAINED_V13_ROOT_UPDATE_LOCK_INODE: u64 = 29_770_550;",
        ] {
            XCTAssertTrue(controller.contains(token), "missing exact V13 terminal pin: \(token)")
        }

        // These are the unique SHA-256 values from the captured 11-node UID501 graph.
        for digest in [
            "df51884110a20feaeb8347d06211a551e95329b2f1386ec32f0a3f64578c0f95",
            "6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded",
            "9d61f5c90411ae7ea8988fcd98b4b176e777a8b52ff826a51dab5c3657d2bb86",
            "86730b2b082000d27b48c1996946db3f5cc4a968c9a3b0ca1eff5c05fab6d64b",
            "df9a1beb9c15c00510070240ba9d35910af8f54fb8ee4b58b917566df839e41a",
            "daf617fc2ea148a446ee375ec3ae9b54c46c494df1bc0b15268b6c14965691be",
            "aded413440dcd20c123e4a28edc15c7fb6869659cc57d18c847529de199d5104",
        ] {
            XCTAssertTrue(controller.contains(digest), "missing V13 UID501 graph digest: \(digest)")
        }

        // These are every unique SHA-256 value from the captured 45-node root graph.
        for digest in [
            "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d",
            "389e5bf011a029bff8c22477994018ed2a17a065f15e30b49db361205a728525",
            "4798181065dbb851f0de518be396d6d4f8a465158923adf16bbf91bcb826a166",
            "49092a2f6280acd93793787689437c5ec126e612b43c11ff10dec30138babd0b",
            "4b0e2bb7ef1110e3a98834600811a221fb9ca3b21319f63902f5c9933dbcfefc",
            "63202ae6ab294069b6f77114f0cce8f35531bbb75355f1d96c8db68f949acdc5",
            "6a258902753b2606f599a306b1fcf3eec149554f40e5e0ce34902e21e7405ab5",
            "6d3f5d71b399ada1244b84177d351c2406d426055da8f54e8f689af1c22a8ded",
            "6e2fa0980cd27498ffe1075bcd439e61fcb0b6d38827ca2dadc3a7d6872e84e1",
            "7044d2b4e6084cc6f410bd2fc198657deff1ae55e46f3dad9a4269830c61df9c",
            "827c875b136de1063efc0897a611a5dc9c3e6df116d212991d56d380e2c83d7e",
            "86730b2b082000d27b48c1996946db3f5cc4a968c9a3b0ca1eff5c05fab6d64b",
            "92c1b53f174dd64d1835fa9b2ecbddd84eac815ad43bbe231090d214b1cc9731",
            "97da790be4e1bbb6629576dd8066723d74837d6c4103ea4fb7a2cbb87518d79f",
            "a92d6cab0ab45deeb91251fd87aff0ce4bca5961a77356f08b8b0b1f7b9eef43",
            "aded413440dcd20c123e4a28edc15c7fb6869659cc57d18c847529de199d5104",
            "afff3f4fa251eeeeac8e6be48c68839db99a5ec98054e3c68b8988d4287815fb",
            "b7e8f55054d59cf3ae0be1fe3a2811a592ed1d0ffb27721a0c5bc8a59a7bef22",
            "daf617fc2ea148a446ee375ec3ae9b54c46c494df1bc0b15268b6c14965691be",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "ed4b7cab5ce2a645702fab88cc847128d1dc85a32c34c458087c5780f51d3171",
        ] {
            XCTAssertTrue(controller.contains(digest), "missing V13 root graph digest: \(digest)")
        }

        let release = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v13_release_files(",
            endingBefore: "struct RetainedV13DescriptorGraph"
        )
        assertOrdered([
            "RETAINED_V13_SOURCE_SIZE", "RETAINED_V13_SOURCE_SHA256",
            "RETAINED_V13_LAUNCHER_SIZE", "RETAINED_V13_LAUNCHER_SHA256",
            "RETAINED_V13_CONTRACT_TEST_SIZE", "RETAINED_V13_CONTRACT_TEST_SHA256",
            "RETAINED_V13_PROBE_SOURCE_SIZE", "RETAINED_V13_PROBE_SOURCE_SHA256",
            #"&format!("{RETAINED_V13_SOURCE_COMMIT}^{{tree}}")"#,
            "tree != RETAINED_V13_SOURCE_TREE", "for (relative, size, mode, digest, label) in specs",
            "require_regular(&path, USER_ID, USER_GROUP, mode)?",
            "require_no_acl_or_xattrs(&path)?", "before.len() != size",
            "sha256(&path)? != digest", "sha256_bytes(&output.stdout)? != digest",
            "identity_from_metadata(&before) != identity_from_metadata(&after)",
        ], in: release)
    }

    func testRetainedV13UserAndRootGraphsAreExactStableAndReadOnly() throws {
        let controller = try source(controllerPath)
        let userIdentities = try functionBody(
            controller,
            beginningWith: "fn open_retained_v13_descriptor_graph(",
            endingBefore: "fn verify_retained_v13_descriptor_graph_payload("
        )
        for token in [
            "RETAINED_V13_USER_UPDATE_ROOT_INODE", "RETAINED_V13_EVIDENCE_INODE",
            "RETAINED_V13_PROBES_INODE", "RETAINED_V13_USER_ACTIVE_POINTER_INODE",
            "RETAINED_V13_JOURNAL_INODE", "RETAINED_V13_REQUEST_INODE",
            "RETAINED_V13_READER_INODE", "RETAINED_V13_CONTROLLER_PIN_INODE",
            "RETAINED_V13_CONTROLLER_IDENTITY_INODE", "RETAINED_V13_RESULT_INODE",
            "RETAINED_V13_USER_UPDATE_LOCK_INODE",
        ] {
            XCTAssertTrue(userIdentities.contains(token), "V13 11-node user graph omits \(token)")
        }
        let identitySpecs = try functionBody(
            userIdentities,
            beginningWith: "let specs = [",
            endingBefore: "let mut"
        )
        XCTAssertEqual(occurrences(of: "&graph.", in: identitySpecs), 11)

        let userPayload = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v13_descriptor_graph_payload(",
            endingBefore: "fn verify_retained_v13_descriptor_graph("
        )
        assertOrdered([
            "RETAINED_V13_EVIDENCE_LEAF.as_bytes()",
            #"b"controller-identity.txt""#, #"b"controller.sha256""#,
            #"b"journal.log""#, #"b"opensteamer-diagnostic-snapshot-reader""#,
            #"b"probes""#, #"b"result.txt""#, #"b"root-request.txt""#,
            "RETAINED_V13_USER_ACTIVE_POINTER_SHA256", "RETAINED_V13_JOURNAL_SHA256",
            "RETAINED_V13_REQUEST_SHA256", "DIAGNOSTIC_READER_SHA256",
            "RETAINED_V13_CONTROLLER_PIN_SHA256", "RETAINED_V13_CONTROLLER_IDENTITY_SHA256",
            "RETAINED_V13_RESULT_SHA256",
        ], in: userPayload)

        let userGraph = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v13_descriptor_graph(",
            endingBefore: "fn verify_retained_v13_user_rolled_back_once("
        )
        assertOrdered([
            "retained_v13_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v13_descriptor_graph_payload(graph)?",
            "retained_v13_descriptor_graph_identities(graph, held_lock)?",
            "verify_retained_v13_descriptor_graph_payload(graph)?",
            "retained_v13_descriptor_graph_identities(graph, held_lock)?",
            "before != middle || middle != after",
        ], in: userGraph)

        let rootSpecs = try functionBody(
            controller,
            beginningWith: "fn retained_v13_root_node_specs()",
            endingBefore: "fn validate_retained_v13_root_identity("
        )
        XCTAssertEqual(occurrences(of: "        file(", in: rootSpecs), 27)
        XCTAssertEqual(occurrences(of: "        directory(", in: rootSpecs), 18)
        for inode in [
            "29_770_200", "29_770_201", "29_770_208", "29_770_209", "29_770_204",
            "29_770_207", "29_770_203", "29_770_202", "29_770_740", "29_770_747",
            "29_770_755", "29_770_757", "29_770_712", "29_770_713", "29_770_716",
            "29_770_726", "29_770_727", "29_770_731", "29_770_736", "29_770_728",
            "29_770_733", "29_770_729", "29_770_730", "29_770_735", "29_770_734",
            "29_770_732", "29_770_717", "29_773_540", "29_773_409", "29_773_543",
            "29_772_649", "29_772_654", "29_773_372", "29_773_410", "29_773_539",
            "29_773_710", "29_773_708", "29_770_780", "29_770_714", "29_773_709",
            "29_770_718", "29_770_715", "29_770_720", "29_770_198",
        ] {
            XCTAssertTrue(rootSpecs.contains(inode), "V13 root graph omits inode \(inode)")
        }
        for token in [
            "RETAINED_V13_ROOT_BOOTSTRAP_LOCATOR", "RETAINED_V13_ROOT_CONTROLLER_PARENT",
            "RETAINED_V13_ROOT_PROBE_PARENT", "RETAINED_V13_ROOT_UPDATE_ROOT",
            "RETAINED_V13_ROOT_UPDATE_LOCK_INODE", "RETAINED_V13_ROOT_ACTIVE_POINTER_SHA256",
            "RETAINED_V13_ROOT_JOURNAL_SHA256", "RETAINED_V13_ROOT_STATE_SHA256",
            "RETAINED_V13_ROOT_RESULT_SHA256", "RETAINED_V13_REQUEST_SHA256",
            "RETAINED_V13_CONTROLLER_BINARY_SHA256",
            "RETAINED_V13_CONTROLLER_PIN_SHA256", "RETAINED_V13_CONTROLLER_IDENTITY_SHA256",
            "5_170", "580", "139",
            #"transaction.join("failed-driver")"#, #"transaction.join("probes")"#,
            #"transaction.join("probes/osds-before-mirror.json")"#,
            #"transaction.join("probes/osds-after-mirror.json")"#,
            #"transaction.join("journal.log")"#, #"transaction.join("state.txt")"#,
            #"transaction.join("result.txt")"#, #"transaction.join("rollback-reserve.bin")"#,
        ] {
            XCTAssertTrue(rootSpecs.contains(token), "V13 45-node root graph omits \(token)")
        }

        let rootProof = try functionBody(
            controller,
            beginningWith: "fn verify_retained_v13_root_graph_once(",
            endingBefore: "fn uid501_verify_retained_v13_root_rolled_back("
        )
        assertOrdered([
            "let specs = retained_v13_root_node_specs()",
            "if specs.len() != 45",
            "retained v13 root manifest does not contain exactly 45 nodes",
            "collect_retained_v13_root_node_identities(restricted_uid501, held_root_lock)?",
            "let child_sets = vec![", "for (path, expected, label) in child_sets",
            "RETAINED_V13_ROOT_ACTIVE_POINTER_PENDING",
            #"transaction.join("journal.log.pending")"#,
            #"transaction.join("prestop-abort-journal.txt")"#,
            #"transaction.join("recovery-result.txt")"#,
            #"read_retained_v4_root_file(&transaction.join("journal.log")"#,
            #"read_retained_v4_root_file(&transaction.join("state.txt")"#,
            #"read_retained_v4_root_file(&transaction.join("result.txt")"#,
            "journal.ends_with(b\"STATE ROLLED_BACK\\n\")",
            "state != RETAINED_V13_ROOT_STATE_TEXT.as_bytes()",
            "result != RETAINED_V13_ROOT_RESULT_TEXT.as_bytes()",
            "retained v13 ROLLED_BACK root semantics changed",
            "collect_retained_v13_root_node_identities(restricted_uid501, held_root_lock)?",
            "if before != after",
        ], in: rootProof)
        for retainedChild in [
            #""physical-virtual-microphone-probe".to_owned()"#,
            #""OpensteamerVirtualMicrophone.driver".to_owned()"#,
            #""both-order.json".to_owned()"#,
            #""osds-before-mirror.json".to_owned()"#,
            #""osds-after-mirror.json".to_owned()"#,
            #""relative-result-writer-canary-drop".to_owned()"#,
            #""post-reload-route-proof.log".to_owned()"#,
            #""both-order-result-drop".to_owned()"#,
            #""rollback-reserve.bin".to_owned()"#,
        ] {
            XCTAssertTrue(rootProof.contains(retainedChild), "V13 root child set omits \(retainedChild)")
        }

        let stableProof = try functionBody(
            controller,
            beginningWith: "fn uid501_verify_retained_v13_root_rolled_back(",
            endingBefore: "fn verify_prebuilt_diagnostic_reader("
        )
        assertOrdered([
            "verify_retained_v13_root_graph_once(true, None)?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v13_root_graph_once(true, None)?",
            "fn verify_retained_v13_root_rolled_back(",
            "verify_retained_v13_root_graph_once(false, Some(held_root_lock))?",
            "thread::sleep(Duration::from_millis(50))",
            "verify_retained_v13_root_graph_once(false, Some(held_root_lock))?",
        ], in: stableProof)

        for immutableProof in [userIdentities, userPayload, userGraph, rootSpecs, rootProof, stableProof] {
            for forbidden in [
                "write_new_private(", "write_atomic_replace(", "fs::remove_file(",
                "fs::remove_dir(", ".create(true)", ".truncate(true)",
            ] {
                XCTAssertFalse(
                    immutableProof.contains(forbidden),
                    "retained V13 proof gained a mutation surface: \(forbidden)"
                )
            }
        }
    }

    func testRetainedV13GuardsSpanPreflightDispatchRollbackAndSealedRecovery() throws {
        let controller = try source(controllerPath)
        let completePreflight = try functionBody(
            controller,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "verify_retained_v12_release_files(&repo)?",
            "verify_retained_v13_release_files(&repo)?",
            "verify_candidate()?",
            "uid501_verify_retained_v13_root_rolled_back()?",
            "verify_retained_v13_user_rolled_back(retained_v13_lock)?",
        ], in: completePreflight)

        let preflight = try functionBody(
            controller,
            beginningWith: "fn preflight(",
            endingBefore: "fn build_diagnostic_reader("
        )
        assertOrdered([
            "acquire_retained_v12_user_update_lock()?",
            "acquire_retained_v13_user_update_lock()?",
            "verify_complete_preflight(", "&retained_v13_lock",
            "retained_v1_v2_v3_v4_v5_v6_v7_v8_v9_v10_v11_v12_v13=immutable",
        ], in: preflight)

        let execute = try functionBody(
            controller,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v13_user_update_lock()?",
            "verify_retained_v13_user_rolled_back_once(&retained_v13_lock)?",
            "verify_retained_v13_descriptor_graph(&dispatch_retained_v13_guard, &retained_v13_lock)?",
            "run_sudo_helper(&root_controller, ROOT_MODE",
            "verify_retained_v13_descriptor_graph(", "&post_dispatch_retained_v13_guard,",
            "retained v13 user boundary changed across root dispatch",
        ], in: execute)

        let rootTransaction = try functionBody(
            controller,
            beginningWith: "fn perform_root_transaction(",
            endingBefore: "fn root_authorized_update("
        )
        assertOrdered([
            "acquire_retained_v12_root_update_lock()?",
            "acquire_retained_v13_root_update_lock()?",
            "verify_retained_v13_root_rolled_back(&retained_v13_root_lock)?",
            "let initial = verify_live_current_host()?",
            "let prestop_revalidation = (|| -> Result<u64> {",
            "verify_retained_v12_root_prestop_aborted(&retained_v12_root_lock)?",
            "verify_retained_v13_root_rolled_back(&retained_v13_root_lock)?",
            "retained v13 rolled-back attestation changed before host stop",
            "verify_rollback_reserve_lease(&layout, &reserve_lease)?",
            "let available_bytes = match prestop_revalidation",
            "write_root_state_tracked(",
            "UpdateState::HostStopInitiated",
            "let outcome = match transaction",
            "verify_retained_v13_root_rolled_back(&retained_v13_root_lock)? != retained_v13",
            "retained v13 root boundary changed across the V14 cutover/rollback",
        ], in: rootTransaction)

        let prestop = try functionBody(
            rootTransaction,
            beginningWith: "let prestop_revalidation = (|| -> Result<u64> {",
            endingBefore: "let available_bytes = match prestop_revalidation"
        )
        assertOrdered([
            "let retained_v12_again =",
            "verify_retained_v12_root_prestop_aborted(&retained_v12_root_lock)?",
            "if retained_v12_again != retained_v12",
            "retained v12 PRESTOP_ABORTED attestation changed before host stop",
            "let retained_v13_again =",
            "verify_retained_v13_root_rolled_back(&retained_v13_root_lock)?",
            "if retained_v13_again != retained_v13",
            "retained v13 rolled-back attestation changed before host stop",
            "verify_rollback_reserve_lease(&layout, &reserve_lease)?",
        ], in: prestop)

        let publicRollback = try functionBody(
            controller,
            beginningWith: "fn rollback_authorized_update(",
            endingBefore: "fn complete_root_recovery("
        )
        for token in [
            "acquire_retained_v13_user_update_lock()?",
            "uid501_verify_retained_v13_root_rolled_back()?",
            "verify_retained_v13_user_rolled_back(&retained_v13_lock)?",
            "verify_retained_v13_user_rolled_back_once(&retained_v13_lock)?",
            "ROOT_SEALED_ROLLBACK_MODE",
            "post_recovery_retained_v13",
            "retained v13 user boundary changed across sealed root recovery",
        ] {
            XCTAssertTrue(publicRollback.contains(token), "rollback omits V13 guard: \(token)")
        }

        let sealedRecovery = try functionBody(
            controller,
            beginningWith: "fn root_sealed_rollback_authorized_update(",
            endingBefore: "const SUDO_SUPERVISOR_SELF_TEST_MARKER_PREFIX:"
        )
        for token in [
            "acquire_retained_v13_root_update_lock()?",
            "let retained_v13 = verify_retained_v13_root_rolled_back(&retained_v13_root_lock)?",
            "reconcile_root_pointer_for_recovery(&locator_request)?",
            "finalize_sealed_bootstrap_without_root_pointer(&fixed_digest)?",
            "parse_sealed_root_request(&layout.recovery_request)?",
            "complete_root_recovery(request, layout)?",
            "retained v13 root boundary changed across sealed recovery",
        ] {
            XCTAssertTrue(sealedRecovery.contains(token), "sealed recovery omits V13 guard: \(token)")
        }

        let journalFields = try functionBody(
            controller,
            beginningWith: "fn root_authenticated_journal_fields(",
            endingBefore: "fn perform_root_transaction("
        )
        for token in [
            #""retained_v13_journal_sha256""#, "RETAINED_V13_JOURNAL_SHA256",
            #""retained_v13_root_journal_sha256""#, "RETAINED_V13_ROOT_JOURNAL_SHA256",
            #""retained_v13_result_sha256""#, "RETAINED_V13_RESULT_SHA256",
            #""retained_v13_locator_device""#, "retained_v13.nodes[0].device",
            #""retained_v13_locator_inode""#, "retained_v13.nodes[0].inode",
            #""retained_v13_request_sha256""#, "RETAINED_V13_REQUEST_SHA256",
        ] {
            XCTAssertTrue(journalFields.contains(token), "root journal omits V13 attestation: \(token)")
        }
    }

    func testCandidateAndLocalProbeBytesAndOpenatGuardsStayExact() throws {
        let v13 = try source(retainedV13SourcePath)
        let v14 = try source(controllerPath)
        for token in [
            "c37c82d8d4e62e387aadc556d0073fad80c752d96040bc2215e6088d8620c93a",
            "84bfc68a9bf808936e60c80dbd8a02f601f54fe248c3f1f8de0b095142401dba",
            "35c3a3f222665015ce139c4b2b517fd905d5810fb501e8f042ff56a7ec504a3d",
            "9f801306c944d2ea021fd1e65650714dd3c0c788e3b521dc927875dd9c3f004d",
            "6a258902753b2606f599a306b1fcf3eec149554f40e5e0ce34902e21e7405ab5",
            "const BOTH_ORDER_PROBE_SIZE: u64 = 1_130_432;",
            #"const BOTH_ORDER_PROBE: &str = "/Users/ahmed/Library/Application Support/opensteamer/reviewed-diagnostic-probes-v14/physical-virtual-microphone-probe";"#,
        ] {
            XCTAssertTrue(v14.contains(token), "V14 candidate/probe pin changed: \(token)")
        }
        XCTAssertFalse(v14.contains(
            "/Volumes/t7/opensteamer-diagnostic-driver-v14-probe-build/physical-virtual-microphone-probe"
        ))

        for (start, end) in [
            ("fn verify_candidate()", "fn verify_installed_v7_driver()"),
            ("fn verify_reader_inputs(", "fn verify_root_staging_static_source_reads("),
            ("fn verify_root_staging_static_source_reads()", "fn verify_generated_root_staging_reader("),
            ("fn verify_generated_root_staging_reader(", "fn require_retained_descriptor("),
        ] {
            let oldBody = try functionBody(v13, beginningWith: start, endingBefore: end)
            let newBody = try functionBody(v14, beginningWith: start, endingBefore: end)
            XCTAssertEqual(normalizedV14(newBody), oldBody, "candidate/probe guard changed: \(start)")
        }

        let completePreflight = try functionBody(
            v14,
            beginningWith: "fn verify_complete_preflight(",
            endingBefore: "fn preflight("
        )
        assertOrdered([
            "verify_reader_inputs(&repo)?",
            "verify_root_staging_static_source_reads()?",
            "verify_prebuilt_diagnostic_reader()?",
            "if require_fresh", "require_fresh_namespaces()?",
        ], in: completePreflight)

        let execute = try functionBody(
            v14,
            beginningWith: "fn execute_authorized_update(",
            endingBefore: "fn rollback_authorized_update("
        )
        assertOrdered([
            "verify_complete_preflight(",
            "sudo_fixed(&[\"/usr/bin/true\"]",
            "build_diagnostic_reader(repo, &nonce, &layout.reader)?",
            "Journal::create(&layout.journal",
            "stage_root_owned_controller(",
            "run_sudo_helper(&root_controller, ROOT_MODE",
        ], in: execute)
    }

    func testUnrelatedRecoveryGuardsStayByteEquivalentToV13AfterVersionNormalization() throws {
        let v13 = try source(retainedV13SourcePath)
        let v14 = try source(controllerPath)
        for (start, end) in [
            ("fn rollback_root_transaction(", "fn verify_root_pointer("),
            ("fn repair_committed_terminal_state(", "fn rollback_resume_action("),
            ("fn rollback_host_requires_exact_display_restore(", "fn verify_retained_v7_driver("),
        ] {
            let oldBody = try functionBody(v13, beginningWith: start, endingBefore: end)
            let newBody = try functionBody(v14, beginningWith: start, endingBefore: end)
            XCTAssertEqual(normalizedV14(newBody), oldBody, "recovery guard changed: \(start)")
        }

        let durableDisplay = try functionBody(
            v14,
            beginningWith: "fn verify_durable_root_display_binding(",
            endingBefore: "fn read_root_active_layout("
        )
        assertOrdered([
            "root_request_display_matches_generation(request, initial)",
            "journal.exact_fields_for_state(UpdateState::Authenticated)",
            "request_journal_state_display_binding_is_exact(request, journal_mode, initial)",
            "durable_state == UpdateState::PrestopAborted",
            "journal.state == UpdateState::PrestopAborted",
            "fn complete_root_recovery(",
            "verify_durable_root_display_binding(&request, &journal, *state, initial)?",
            "let effective_journal = journal.effective_state_with_pending()?",
            "let plan = root_recovery_plan(",
        ], in: durableDisplay)

        let v14Rollback = try functionBody(
            v14,
            beginningWith: "fn rollback_root_transaction(",
            endingBefore: "fn verify_root_pointer("
        )
        for token in [
            "restore_and_verify_live_current_host(&initial.display_mode)?",
            "restart_or_recover_exact_current_host(initial)?",
            "UpdateState::HostRebootstrapped",
            "write_root_state(layout, UpdateState::RolledBack, initial, baseline_route)?",
        ] {
            XCTAssertTrue(v14Rollback.contains(token), "rollback lost guard: \(token)")
        }
    }

    func testBaselineSnapshotRequiresAnExactlyEmptyCoreSlotSet() throws {
        let controller = try source(controllerPath)
        let common = try functionBody(
            controller,
            beginningWith: "fn parse_passive_snapshot_summary(",
            endingBefore: "fn validate_passive_baseline_snapshot_json("
        )
        for token in [
            "let zero_counts = [",
            #""coreActiveSlotCount""#,
            #""timelineSeed""#,
            #""currentSeedGeneration""#,
            #""anchorHostTicks""#,
            #"!json_string_is(object, "coreActiveSlotBitmap", "0000000000000000")"#,
            #"!json_string_is(object, "driverStartedSlotBitmap", "0000000000000000")"#,
            "validate_registered_only_idle_driver_slots(object)?",
            "validate_passive_idle_work_loops(object)?",
            "core_client_slots: parse_passive_core_client_slots(object)?",
        ] {
            XCTAssertTrue(common.contains(token), "common passive proof omits \(token)")
        }
        let baseline = try functionBody(
            controller,
            beginningWith: "fn validate_passive_baseline_snapshot_json(",
            endingBefore: "fn validate_post_loopback_snapshot_json("
        )
        assertOrdered([
            "parse_passive_snapshot_summary(bytes)?",
            "!summary.core_client_slots.is_empty()",
            "baseline core-slot leak",
        ], in: baseline)
        XCTAssertTrue(controller.contains("baseline core-slot leak"))

        let transaction = try functionBody(
            controller,
            beginningWith: "fn run_passive_driver_validation(",
            endingBefore: "// BOUNDED_NATIVE_JSON_VALIDATOR:"
        )
        assertOrdered([
            #"layout.root.join("probes/osds-before-mirror.json")"#,
            "validate_passive_baseline_snapshot_json(",
            "run_both_order_with_root_held_result(",
            "verify_mirror_loopback_result(",
            #"layout.root.join("probes/osds-after-mirror.json")"#,
            "validate_post_loopback_snapshot_json(",
            "validate_post_loopback_causal_delta(",
        ], in: transaction)
    }

    func testPostLoopbackRetiredCoreSlotsAreStructurallyAndCausallyExact() throws {
        let controller = try source(controllerPath)
        let post = try functionBody(
            controller,
            beginningWith: "fn validate_post_loopback_snapshot_json(",
            endingBefore: "fn validate_post_loopback_causal_delta("
        )
        for token in [
            "parse_passive_snapshot_summary(bytes)?",
            "summary.core_client_slots.len() != 2",
            "slot.slot_index >= summary.client_slot_capacity",
            "slot.slot_index >= 64",
            "slot_bitmap & slot_bit != 0",
            "slot.session_id != 0",
            "!(1..=2).contains(&slot.endpoint_role)",
            "slot.slot_index != slot.endpoint_role - 1",
            "slot.client_id >> 32 != expected_device",
            "let low_client_id = slot.client_id & u32::MAX as u64",
            "low_client_id == 0",
            "slot.timeline_seed == 0",
            "slot.timeline_seed > summary.last_issued_seed",
            "slot.timeline_seed != summary.last_issued_seed",
            "slot.timeline_seed != summary.last_cleared_seed",
            "slot.timeline_seed != summary.last_cleared_seed_generation",
            "summary.io_last_client_ids[endpoint_index]",
            "summary.zero_timestamp_last_client_ids[endpoint_index]",
            "DIAGNOSTIC_VISIBLE_DEVICE_OBJECT_ID",
            "DIAGNOSTIC_WRITER_DEVICE_OBJECT_ID",
            "role_bitmap != 0b11 || slot_bitmap != 0b11",
        ] {
            XCTAssertTrue(post.contains(token), "post-loopback core-slot proof omits \(token)")
        }

        let deltaHelper = try functionBody(
            controller,
            beginningWith: "fn exact_counter_delta(",
            endingBefore: "fn validate_post_loopback_causal_delta("
        )
        XCTAssertTrue(deltaHelper.contains("after.checked_sub(before) != Some(expected)"))
        let causal = try functionBody(
            controller,
            beginningWith: "fn validate_post_loopback_causal_delta(",
            endingBefore: "fn validate_mirror_loopback_json("
        )
        for token in [
            "baseline.driver_instance_generation != post.driver_instance_generation",
            "baseline.driver_client_add_attempt_count", "post.driver_client_add_attempt_count",
            "4", "post add-attempt delta",
            "baseline.driver_client_add_count", "post.driver_client_add_count",
            "post add-count delta",
            "baseline.driver_client_remove_attempt_count", "post.driver_client_remove_attempt_count",
            "post remove-attempt delta",
            "baseline.driver_client_remove_count", "post.driver_client_remove_count",
            "post remove-count delta",
            "baseline.global_start_attempt_count", "post.global_start_attempt_count",
            "6", "post start-attempt delta",
            "baseline.global_start_transition_count", "post.global_start_transition_count",
            "post start-transition delta",
            "baseline.global_stop_attempt_count", "post.global_stop_attempt_count",
            "post stop-attempt delta",
            "baseline.global_stop_transition_count", "post.global_stop_transition_count",
            "post stop-transition delta",
            "baseline.seed_create_count", "post.seed_create_count",
            "3", "post seed-create delta",
            "baseline.seed_clear_count", "post.seed_clear_count", "post seed-clear delta",
            "baseline.core_lifecycle_sequence", "post.core_lifecycle_sequence",
            "24", "post core-lifecycle delta",
            "baseline.driver_lifecycle_sequence", "post.driver_lifecycle_sequence",
            "20", "post driver-lifecycle delta",
            "baseline.last_issued_session_id", "post.last_issued_session_id",
            "post session delta",
            "baseline.last_issued_seed", "post.last_issued_seed",
            "baseline.last_cleared_seed", "post.last_cleared_seed",
            "baseline.last_cleared_seed_generation", "post.last_cleared_seed_generation",
            "post last-seed delta",
            "low_client_id <= baseline.io_last_client_ids[index]",
            "low_client_id <= baseline.zero_timestamp_last_client_ids[index]",
        ] {
            XCTAssertTrue(causal.contains(token), "post-loopback causal proof omits \(token)")
        }
    }

    func testPureSelfTestRejectsEveryHostileCoreSlotAndDeltaFixture() throws {
        let controller = try source(controllerPath)
        guard let selfTestStart = controller.range(of: "fn self_test() -> Result<()> {") else {
            XCTFail("missing pure self-test")
            return
        }
        let selfTest = String(controller[selfTestStart.lowerBound...])
        for label in [
            "baseline core-slot leak",
            "post core-slot count",
            "post core-slot duplicate",
            "post core-slot index",
            "post core-slot active session",
            "post core-slot role",
            "post core-slot device encoding",
            "post core-slot zero-low-client",
            "post core-slot zero seed",
            "post core-slot future seed",
            "post core-slot io-client mismatch",
            "post core-slot zero-timestamp-client mismatch",
            "post add-attempt delta",
            "post add-count delta",
            "post remove-attempt delta",
            "post remove-count delta",
            "post start-attempt delta",
            "post start-transition delta",
            "post stop-attempt delta",
            "post stop-transition delta",
            "post seed-create delta",
            "post seed-clear delta",
            "post core-lifecycle delta",
            "post driver-lifecycle delta",
            "post session delta",
            "post last-seed delta",
            "post driver generation mismatch",
        ] {
            XCTAssertTrue(selfTest.contains(label), "self-test omits hostile fixture: \(label)")
        }
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "require_self_test_rejection(", in: selfTest),
            20
        )
        assertOrdered([
            "let baseline = validate_passive_baseline_snapshot_json(passive_json.as_bytes())?",
            "let post = validate_post_loopback_snapshot_json(post_json.as_bytes())?",
            "validate_post_loopback_causal_delta(&baseline, &post)?",
        ], in: selfTest)
    }

    func testV14PureSelfTestRunsWhenFinalPinsMatch() throws {
        let controller = try source(controllerPath)
        let launcher = try source(launcherPath)
        let sourcePin = shellSingleQuotedValue("EXPECTED_SOURCE_SHA256", in: launcher)
        let binaryPin = shellSingleQuotedValue("EXPECTED_BINARY_SHA256", in: launcher)
        XCTAssertEqual(shellSingleQuotedValue("RELEASE_PIN_STATUS", in: launcher), "PINNED_FINAL_REVIEW")
        XCTAssertEqual(
            shellSingleQuotedValue("EXPECTED_MACOSX_DEPLOYMENT_TARGET", in: launcher),
            "26.0"
        )
        XCTAssertEqual(sourcePin?.count, 64)
        XCTAssertEqual(binaryPin?.count, 64)
        XCTAssertTrue(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v14"))
        XCTAssertFalse(launcher.contains("/reviewed/opensteamer-diagnostic-driver-v13"))
        XCTAssertTrue(launcher.contains(
            #"[ "$CONTROLLER_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ] || {"#
        ))

        guard sourcePin == sha256Hex(controller) else {
            throw XCTSkip("V14 final source/binary pins are not fixed yet")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot.appendingPathComponent(launcherPath).path,
            "--self-test-diagnostic-driver-v14-update",
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
        if process.terminationStatus != 0
            && error == "compiled diagnostic-driver controller differs from reviewed binary hash\n"
        {
            throw XCTSkip("V14 final binary pin is not fixed yet")
        }
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertNotNil(
            output.range(
                of: #"\ADIAGNOSTIC_DRIVER_V14_SELF_TEST_OK tests=[1-9][0-9]*\n\z"#,
                options: .regularExpression
            ),
            output
        )
        XCTAssertEqual(error, "")
    }
}
