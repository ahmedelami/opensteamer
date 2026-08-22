import Foundation
import CryptoKit
import XCTest

final class V7DriverHostUpdateContractTests: XCTestCase {
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
        XCTAssertNotEqual(start.location, NSNotFound)
        let tail = NSRange(
            location: start.location,
            length: nsSource.length - start.location
        )
        let finish = nsSource.range(of: ending, options: [], range: tail)
        XCTAssertNotEqual(finish.location, NSNotFound)
        return nsSource.substring(
            with: NSRange(location: start.location, length: finish.location - start.location)
        )
    }

    private func replacingInFunction(
        _ source: String,
        beginningWith beginning: String,
        endingBefore ending: String,
        target: String,
        replacement: String
    ) -> String {
        let nsSource = source as NSString
        let start = nsSource.range(of: beginning)
        guard start.location != NSNotFound else { return source }
        let tail = NSRange(
            location: start.location,
            length: nsSource.length - start.location
        )
        let finish = nsSource.range(of: ending, options: [], range: tail)
        guard finish.location != NSNotFound else { return source }
        let body = NSRange(
            location: start.location,
            length: finish.location - start.location
        )
        let mutation = nsSource.range(of: target, options: [], range: body)
        guard mutation.location != NSNotFound else { return source }
        return nsSource.replacingCharacters(in: mutation, with: replacement)
    }

    private func replacingLastInFunction(
        _ source: String,
        beginningWith beginning: String,
        endingBefore ending: String,
        target: String,
        replacement: String
    ) -> String {
        let nsSource = source as NSString
        let start = nsSource.range(of: beginning)
        guard start.location != NSNotFound else { return source }
        let tail = NSRange(
            location: start.location,
            length: nsSource.length - start.location
        )
        let finish = nsSource.range(of: ending, options: [], range: tail)
        guard finish.location != NSNotFound else { return source }
        let body = NSRange(
            location: start.location,
            length: finish.location - start.location
        )
        let mutation = nsSource.range(of: target, options: .backwards, range: body)
        guard mutation.location != NSNotFound else { return source }
        return nsSource.replacingCharacters(in: mutation, with: replacement)
    }

    private func sha256Hex(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func hasExactLauncherSourcePinContract(
        controller: String,
        launcher: String,
        expectedSHA256: String
    ) -> Bool {
        let comparison =
            "[ \"$(/usr/bin/shasum -a 256 \"$SOURCE\" | /usr/bin/awk '{print $1}')\" = \\\n  \"$EXPECTED_SOURCE_SHA256\" ]"
        return sha256Hex(controller) == expectedSHA256
            && launcher.contains("EXPECTED_SOURCE_SHA256='\(expectedSHA256)'")
            && launcher.contains(comparison)
            && launcher.contains("paired-v7 controller source differs from the reviewed bytes")
    }

    private func assertOrdered(
        _ tokens: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previous = -1
        let nsSource = source as NSString
        for token in tokens {
            let range = nsSource.range(
                of: token,
                options: [],
                range: NSRange(
                    location: previous + 1,
                    length: nsSource.length - previous - 1
                )
            )
            XCTAssertNotEqual(range.location, NSNotFound, "missing ordered token: \(token)", file: file, line: line)
            previous = range.location
        }
    }

    private func containsOrdered(_ tokens: [String], in source: String) -> Bool {
        var remainder = source[source.startIndex...]
        for token in tokens {
            guard let range = remainder.range(of: token) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return true
    }

    private func hasRealLFProductionDriverManifestContract(_ verifier: String) -> Bool {
        let canonicalJoin =
            "expected_nodes_text=\"$(canonical_manifest_text \"${expected_nodes[@]}\")\""
        let literalBackslashNJoin =
            "expected_nodes_text=\"${(j:\\n:)expected_nodes}\""
        let required = [
            "canonical_manifest_text()",
            "manifest_is_exact()",
            canonicalJoin,
            "manifest_is_exact \"$expected_nodes_text\" \"$actual_nodes_text\"",
            "--self-test-lstat-manifest-v7",
            "exact_manifest=$'Directory|755|.\\nDirectory|755|Contents'",
            "literal_backslash_n_mutant='Directory|755|.\\nDirectory|755|Contents'",
            "manifest_is_exact \"$exact_manifest\" \"$actual_manifest\"",
            "manifest_is_exact \"$exact_manifest\" \"$literal_backslash_n_mutant\"",
            "SELF_TEST_OK production-driver-lstat-manifest-v7",
        ]
        return required.allSatisfy(verifier.contains)
            && !verifier.contains(literalBackslashNJoin)
    }

    private func hasDeterministicOptimizedMirrorProbeCompileContract(
        _ controller: String
    ) -> Bool {
        guard
            let build = try? functionBody(
                controller,
                beginningWith: "fn build_and_verify_v7_probe_binaries(",
                endingBefore: "struct BoundedChildOutcome"
            )
        else {
            return false
        }
        let validationTokens = [
            "let mirror_source = require_exported_pinned_file(",
            "\"iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift\"",
            "EXPECTED_MIRROR_PROBE_SOURCE_SHA256,",
            "const MIRROR_SOURCE_BASENAME: &str = \"physical-blackhole-microphone-probe.swift\";",
            "let mirror_source_parent = mirror_source.parent().ok_or_else(",
            "require_directory(mirror_source_parent, 0o700)?;",
            "if mirror_source.file_name().and_then(|name| name.to_str())",
            "!= Some(MIRROR_SOURCE_BASENAME)",
        ]
        let guardianValidationTokens = [
            "let guardian_source = require_exported_pinned_file(",
            "\"macOS/VirtualAudioDriver/Probes/V7DefaultRouteGuardian.swift\"",
            "EXPECTED_DEFAULT_ROUTE_GUARDIAN_SOURCE_SHA256,",
            "const GUARDIAN_SOURCE_BASENAME: &str = \"V7DefaultRouteGuardian.swift\";",
            "let guardian_source_parent = guardian_source.parent().ok_or_else(",
            "require_directory(guardian_source_parent, 0o700)?;",
            "if guardian_source.file_name().and_then(|name| name.to_str())",
            "!= Some(GUARDIAN_SOURCE_BASENAME)",
        ]
        let compileClosureTokens = [
            "let compile_swift = |source_argument: &str,",
            "source_directory: Option<&Path>,",
            "\"-O\",",
            "source_argument,",
            "arguments.push(\"-o\");",
            "arguments.push(path_text(output)?);",
            "if let Some(directory) = source_directory {",
            "command.current_dir(directory);",
            "let result = command",
            ".output()?;",
            #"require_output_success(&result, "compile exact paired-v7 Swift probe")?;"#,
            "let compiled_output_is_exact = |metadata: &fs::Metadata, expected_mode: u32|",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == expected_mode",
            "let named_before = fs::symlink_metadata(output)?;",
            "if !compiled_output_is_exact(&named_before, 0o700)",
            "let compiled_output = OpenOptions::new()",
            ".read(true)",
            ".write(true)",
            ".custom_flags(O_NOFOLLOW)",
            ".open(output)?;",
            "let descriptor_before = compiled_output.metadata()?;",
            "if !compiled_output_is_exact(&descriptor_before, 0o700)",
            "descriptor_before.dev() != named_before.dev()",
            "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()",
            "compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;",
            "let descriptor_after = compiled_output.metadata()?;",
            "let named_after = fs::symlink_metadata(output)?;",
            "if !compiled_output_is_exact(&descriptor_after, 0o755)",
            "!compiled_output_is_exact(&named_after, 0o755)",
            "descriptor_before.dev() != descriptor_after.dev()",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.len() != descriptor_after.len()",
            "descriptor_before.dev() != named_after.dev()",
            "descriptor_before.ino() != named_after.ino()",
            "descriptor_before.len() != named_after.len()",
            "Ok(())",
        ]
        let mirrorCompileTokens = [
            "compile_swift(",
            "MIRROR_SOURCE_BASENAME,",
            "Some(mirror_source_parent),",
            "&layout.mirror_probe,",
            "\"-Xfrontend\",",
            "\"-disable-sil-perf-optzns\",",
            "\"-Xfrontend\",",
            "\"-disable-incremental-llvm-codegen\",",
            "\"-Xlinker\",",
            "\"-reproducible\",",
            "\"-framework\",",
            "\"AudioToolbox\",",
            "\"-framework\",",
            "\"CoreAudio\",",
        ]
        let guardianCompileTokens = [
            "compile_swift(",
            "GUARDIAN_SOURCE_BASENAME,",
            "Some(guardian_source_parent),",
            "&layout.default_route_guardian,",
            "&[],",
        ]
        return containsOrdered(validationTokens, in: build)
            && containsOrdered(guardianValidationTokens, in: build)
            && containsOrdered(compileClosureTokens, in: build)
            && build.contains("\"-O\",")
            && !build.contains("\"-Onone\",")
            && containsOrdered(mirrorCompileTokens, in: build)
            && !build.contains("path_text(&mirror_source)?")
            && containsOrdered(guardianCompileTokens, in: build)
            && !build.contains("path_text(&guardian_source)?")
            && controller.contains(
                "const EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256: &str =\n"
                    + "        \"53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c\";"
            )
            && build.components(separatedBy: "-disable-sil-perf-optzns").count - 1 == 1
            && build.components(separatedBy: "-disable-incremental-llvm-codegen").count - 1 == 1
            && build.components(separatedBy: "-reproducible").count - 1 == 1
            && build.components(
                separatedBy: "compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;"
            ).count - 1 == 1
            && !build.contains("fs::set_permissions(output,")
    }

    private func hasPinnedProductionXcodeTrustContract(_ controller: String) -> Bool {
        guard
            let verifier = try? functionBody(
                controller,
                beginningWith: "fn verify_pinned_xcode_developer_directory(",
                endingBefore: "fn verify_v7_production_signing_availability("
            ),
            let signingAvailability = try? functionBody(
                controller,
                beginningWith: "fn verify_v7_production_signing_availability(",
                endingBefore: "fn verify_reviewed_production_candidate_preflight("
            ),
            let stagedBuild = try? functionBody(
                controller,
                beginningWith: "fn build_and_verify_v7_staged_app(",
                endingBefore: "fn require_exported_pinned_file("
            )
        else {
            return false
        }
        let exactPins = [
            #"const PINNED_XCODE_APPLICATION_LINK: &str = "/Applications/Xcode-26.6.0.app";"#,
            #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";"#,
            #"const PINNED_XCODE_DEVELOPER_DIR: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer";"#,
            #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer";"#,
            "const PINNED_XCODE_DEVELOPER_UID: u32 = 501;",
            "const PINNED_XCODE_DEVELOPER_GID: u32 = 20;",
            "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o755;",
            #"const PINNED_XCODE_SWIFTC_ALIAS: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";"#,
            #"const PINNED_XCODE_RESOLVED_SWIFTC_ALIAS: &str = "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";"#,
            #"const PINNED_XCODE_SWIFTC_ALIAS_TARGET: &str = "swift-frontend";"#,
            #"const PINNED_XCODE_SWIFT_FRONTEND: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend";"#,
            #"const PINNED_XCODE_CLANG: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang";"#,
            #""2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb";"#,
            #""7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a";"#,
            #"const EXPECTED_XCODE_SWIFTC_VERSION: &str = "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0";"#,
        ]
        let verifierTokens = [
            "let application_link = Path::new(PINNED_XCODE_APPLICATION_LINK);",
            "fs::symlink_metadata(application_link)?;",
            "!application_link_metadata.file_type().is_symlink()",
            "let application_target = fs::read_link(application_link)?;",
            "!application_target.is_absolute()",
            "application_target.to_str() != Some(PINNED_XCODE_APPLICATION_TARGET)",
            "fs::canonicalize(PINNED_XCODE_DEVELOPER_DIR)?;",
            "canonical_developer_directory != Path::new(PINNED_XCODE_RESOLVED_DEVELOPER_DIR)",
            "fs::symlink_metadata(PINNED_XCODE_RESOLVED_DEVELOPER_DIR)?;",
            "!resolved_developer_directory.file_type().is_dir()",
            "resolved_developer_directory.file_type().is_symlink()",
            "resolved_developer_directory.uid() != PINNED_XCODE_DEVELOPER_UID",
            "resolved_developer_directory.gid() != PINNED_XCODE_DEVELOPER_GID",
            "resolved_developer_directory.permissions().mode() & 0o7777",
            "!= PINNED_XCODE_DEVELOPER_MODE",
            "let swiftc_alias = Path::new(PINNED_XCODE_SWIFTC_ALIAS);",
            "let swiftc_alias_metadata = fs::symlink_metadata(swiftc_alias)?;",
            "!swiftc_alias_metadata.file_type().is_symlink()",
            "let swiftc_alias_target = fs::read_link(swiftc_alias)?;",
            "swiftc_alias_target.to_str() != Some(PINNED_XCODE_SWIFTC_ALIAS_TARGET)",
            "PINNED_XCODE_SWIFT_FRONTEND,",
            "EXPECTED_XCODE_SWIFT_FRONTEND_SHA256,",
            "PINNED_XCODE_CLANG,",
            "EXPECTED_XCODE_CLANG_SHA256,",
            "let tool_metadata = fs::symlink_metadata(tool_path)?;",
            "!tool_metadata.file_type().is_file()",
            "tool_metadata.file_type().is_symlink()",
            "tool_metadata.permissions().mode() & 0o111 == 0",
            "sha256(tool_path)? != expected_sha256",
            "let xcrun_swiftc = Command::new(\"/usr/bin/xcrun\")",
            #".args(["--sdk", "macosx", "--find", "swiftc"])"#,
            ".env_clear()",
            #".env("LC_ALL", "C")"#,
            #".env("HOME", USER_HOME)"#,
            #".env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")"#,
            #".env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)"#,
            "require_output_success(&xcrun_swiftc, \"resolve the pinned production swiftc\")?;",
            #"format!("{PINNED_XCODE_RESOLVED_SWIFTC_ALIAS}\n")"#,
            "!xcrun_swiftc.stderr.is_empty()",
            "xcrun_swiftc.stdout.as_slice() != expected_xcrun_swiftc.as_bytes()",
            "let swiftc_version = Command::new(\"/usr/bin/xcrun\")",
            #".args(["--sdk", "macosx", "swiftc", "--version"])"#,
            ".env_clear()",
            #".env("LC_ALL", "C")"#,
            #".env("HOME", USER_HOME)"#,
            #".env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")"#,
            #".env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)"#,
            "require_output_success(&swiftc_version, \"inspect the pinned production swiftc version\")?;",
            "let observed_swiftc_version = format!(\"{version_stderr}{version_stdout}\");",
            "observed_swiftc_version.strip_suffix('\\n') != Some(EXPECTED_XCODE_SWIFTC_VERSION)",
        ]
        return exactPins.allSatisfy(controller.contains)
            && containsOrdered(verifierTokens, in: verifier)
            && verifier.components(separatedBy: ".env_clear()").count - 1 == 2
            && verifier.components(
                separatedBy: #".env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)"#
            ).count - 1 == 2
            && signingAvailability.contains("verify_pinned_xcode_developer_directory()?;")
            && signingAvailability.contains(
                #".env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)"#
            )
            && stagedBuild.components(
                separatedBy: #".env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)"#
            ).count - 1 == 1
    }

    private func swappingFirst(
        _ first: String,
        with second: String,
        in source: String
    ) -> String {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(
                of: second,
                range: firstRange.upperBound..<source.endIndex
              ) else {
            return source
        }
        var result = source
        result.replaceSubrange(secondRange, with: first)
        result.replaceSubrange(firstRange, with: second)
        return result
    }

    private func hasPostPublishGuardianFenceContract(
        guardian: String,
        controller: String
    ) -> Bool {
        guard
            let counters = try? functionBody(
                guardian,
                beginningWith: "private final class ListenerCounters",
                endingBefore: "private final class DefaultListener"
            ),
            let listener = try? functionBody(
                guardian,
                beginningWith: "private final class DefaultListener",
                endingBefore: "private struct Restoration"
            ),
            let broker = try? functionBody(
                guardian,
                beginningWith: "private static func broker(",
                endingBefore: "private static func snapshot("
            ),
            let decision = try? functionBody(
                guardian,
                beginningWith: "private enum DecisionModel",
                endingBefore: "private enum CoreAudioDefaults"
            ),
            let checkBranch = try? functionBody(
                broker,
                beginningWith: "case \"CHECK\"",
                endingBefore: "case \"POST_PUBLISH_FENCE\""
            ),
            let postPublishBranch = try? functionBody(
                broker,
                beginningWith: "case \"POST_PUBLISH_FENCE\"",
                endingBefore: "case \"RUN_VPIO\""
            ),
            let runBranch = try? functionBody(
                broker,
                beginningWith: "case \"RUN_VPIO\"",
                endingBefore: "case \"REPAIR\""
            ),
            let transaction = try? functionBody(
                controller,
                beginningWith: "\nfn uid_proxy_transaction()",
                endingBefore: "\nfn uid_local_trial_guardian()"
            ),
            let rootProtocol = try? functionBody(
                controller,
                beginningWith: "\nfn root_protocol(",
                endingBefore: "\nfn root_broker()"
            ),
            let validator = try? functionBody(
                controller,
                beginningWith: "\nfn guardian_evidence_validation_program(",
                endingBefore: "\nfn verify_guardian_evidence("
            ),
            let linker = try? functionBody(
                controller,
                beginningWith: "\nfn verify_guardian_post_publish_link(",
                endingBefore: "\nfn verify_mirror_result("
            ),
            let rootRequestUntil = try? functionBody(
                controller,
                beginningWith: "\n    fn request_until(",
                endingBefore: "\n    fn ping("
            ),
            let guardianBroker = try? functionBody(
                controller,
                beginningWith: "\nimpl GuardianBroker {",
                endingBefore: "\nfn detach_root_broker_session("
            ),
            let guardianExchangeUntil = try? functionBody(
                guardianBroker,
                beginningWith: "\n    fn exchange_until(",
                endingBefore: "\n}\n"
            ),
            let commit = try? functionBody(
                counters,
                beginningWith: "func commitPostPublishEpoch(",
                endingBefore: "func preEpochStatus("
            )
        else {
            return false
        }

        let counterTokens = [
            "observedDefaults != baseline",
            "preEpochUIDMismatchOrReadFailure = true",
            "guard value < UInt64.max",
            "overflowed = true",
            "checkpointWithoutLock() == expected",
        ]
        let decisionTokens = [
            "before == after",
            "first == baseline",
            "second == baseline",
            "safeOutputs(first)",
            "safeOutputs(second)",
            "hiddenNeverDefault(first)",
            "hiddenNeverDefault(second)",
            "!isForbiddenRestorationInput(first.inputUID)",
        ]
        let listenerOrder = [
            "func install() throws",
            "queue.sync {}",
            "let before = drainAndCheckpoint()",
            "let first = try CoreAudioDefaults.snapshot()",
            "Thread.sleep(forTimeInterval: 0.10)",
            "let second = try CoreAudioDefaults.snapshot()",
            "let after = drainAndCheckpoint()",
            "DecisionModel.postPublishFenceSafe(",
            "!preEpochStatus.failed",
        ]
        let brokerOrder = [
            "try listener.install()",
            "let first = try CoreAudioDefaults.snapshot()",
            "listener.armPreEpochBaseline(first)",
            "Thread.sleep(forTimeInterval: 0.10)",
            "let second = try CoreAudioDefaults.snapshot()",
            "case \"POST_PUBLISH_FENCE\"",
            "try listener.preparePostPublishEpoch(",
            "to: postPublishFenceResultPath",
            "listener.commitPostPublishEpoch(",
            "postPublishEpochEstablished = true",
            "GUARDIAN_BROKER_POST_PUBLISH_FENCED",
            "case \"RUN_VPIO\"",
        ]
        let transactionOrder = [
            "\"L1Ciab PUBLISH\"",
            "let post_publish_fence_deadline = Instant::now()",
            "let post_publish_local_deadline = post_publish_fence_deadline",
            "let post_publish_guardian_deadline = post_publish_local_deadline",
            "guardian.exchange_until(",
            "\"POST_PUBLISH_FENCE\"",
            "post_publish_guardian_deadline,",
            "if Instant::now() >= post_publish_guardian_deadline",
            "let post_publish_evidence_deadline = post_publish_local_deadline",
            "let post_publish_parent_sync_deadline = post_publish_evidence_deadline",
            "sync_parent_directory(&layout.guardian_post_publish_fence_result)?;",
            "if Instant::now() >= post_publish_parent_sync_deadline",
            "verify_guardian_evidence_until(",
            "stable_private_sha256_until(",
            "post_publish_fence_hash != verified_post_publish_fence_hash",
            "root.exchange_until(",
            "L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}",
            "post_publish_fence_deadline,",
            "if Instant::now() >= post_publish_fence_deadline",
            "run_mirror_probe_until(mirror_probe_deadline)?;",
            "guardian.exchange(\"RUN_VPIO\"",
            "\"L1Ciab PROBES_VERIFIED\"",
            "\"L1Ciab RELEASE_CANDIDATE_GATE\"",
        ]
        let deadlineTokens = [
            "POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS: u64 = 5",
            "POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS",
            "POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
            "POST_PUBLISH_PARENT_SYNC_PRIMITIVE_SECONDS: u64 = 5",
            "POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS",
            "reviewed_post_publish_fence_minimum(",
            "GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS",
            "GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS",
            "post_publish_guardian_deadline,",
            "post_publish_evidence_deadline,",
            "post_publish_local_deadline,",
            "post_publish_fence_deadline,",
        ]
        let transactionDeadlineTokens = [
            ".checked_add(Duration::from_secs(POST_PUBLISH_FENCE_PRIMITIVE_SECONDS))",
            "POST_PUBLISH_ROOT_EXCHANGE_PRIMITIVE_SECONDS,",
            "POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS,",
            "GUARDIAN_PRIVATE_STATE_HASH_PRIMITIVE_SECONDS,",
            ".checked_sub(Duration::from_secs(GUARDIAN_EVIDENCE_PRIMITIVE_SECONDS))",
            "post_publish_guardian_deadline,",
            "post_publish_evidence_deadline,",
            "post_publish_local_deadline,",
            "post_publish_fence_deadline,",
        ]
        let rootTokens = [
            "command.strip_prefix(\"L1Ciab POST_PUBLISH_FENCE \")",
            "state.postpublish_fenced",
            "state.postpublish_fence_hash.is_some()",
            "verify_bound_dormant_candidate_gate",
            "require_named_identity",
            "verify_guardian_evidence(",
            "state.postpublish_fence_hash = Some(observed.clone());",
            "state.postpublish_fenced = true;",
            "verify_guardian_post_publish_link(",
            "fence_hash != expected_fence_hash",
        ]
        let validatorTokens = [
            "import hashlib,json,sys",
            "preEpochBaselineArmed",
            "preEpochUIDMismatchOrReadFailure",
            "c['sequence']==c['inputNotifications']+c['outputNotifications']+c['systemOutputNotifications']",
            "checkpoint(e)==v['listener']['postPublishEpochFingerprint']",
            "a==e and v['listener']['inputNotifications']==0",
        ]
        return counterTokens.allSatisfy(counters.contains)
            && decisionTokens.allSatisfy(decision.contains)
            && !counters.contains("&+=")
            && !commit.contains("sequence = 0")
            && !commit.contains("input = 0")
            && !commit.contains("output = 0")
            && !commit.contains("systemOutput = 0")
            && containsOrdered(listenerOrder, in: listener)
            && containsOrdered(brokerOrder, in: broker)
            && broker.components(separatedBy: "let listener = DefaultListener()").count - 1 == 1
            && checkBranch.contains("!repairWritten")
            && postPublishBranch.contains("!repairWritten")
            && runBranch.contains("!repairWritten")
            && !postPublishBranch.contains("Restorer.restore")
            && !postPublishBranch.contains("setPreparedDefaultInput")
            && !postPublishBranch.contains("listener.install")
            && !postPublishBranch.contains("listener.removeAndDrain")
            && containsOrdered(transactionOrder, in: transaction)
            && deadlineTokens.allSatisfy(controller.contains)
            && transactionDeadlineTokens.allSatisfy(transaction.contains)
            && !transaction.contains("post_publish_guardian_response_deadline")
            && !transaction.contains("post_publish_root_response_deadline")
            && containsOrdered(
                [
                    "writeln!(self.stream, \"{command}\")",
                    "self.stream.flush()",
                    "remaining_phase_timeout(deadline, maximum_response, label)?",
                    "let result = self.read_line();",
                    "if Instant::now() >= deadline",
                ],
                in: rootRequestUntil
            )
            && containsOrdered(
                [
                    "writeln!(input, \"{command}\")",
                    "input.flush()",
                    "remaining_phase_timeout(deadline, maximum_response, label)?",
                    ".recv_timeout(timeout)",
                    "self.transcript.sync_all()",
                    "if Instant::now() >= deadline",
                ],
                in: guardianExchangeUntil
            )
            && !transaction.contains("verify_guardian_evidence(\n")
            && !transaction.contains(
                "stable_private_sha256(&layout.guardian_post_publish_fence_result)"
            )
            && controller.contains(
                "\"PING\" | \"CHECK\" | \"POST_PUBLISH_FENCE\" | \"RUN_VPIO\" | \"REPAIR\" | \"STOP\""
            )
            && rootTokens.allSatisfy(rootProtocol.contains)
            && validatorTokens.allSatisfy(validator.contains)
            && linker.contains(
                "f['listener']['postPublishEpochFingerprint']==l['listener']['postPublishEpochFingerprint']"
            )
    }

    private func hasBoundsSafeStreamConfigurationParser(_ probe: String) -> Bool {
        guard let reader = try? functionBody(
            probe,
            beginningWith: "private enum CoreAudioReader",
            endingBefore: "private enum PhysicalOutputPolicy"
        ) else {
            return false
        }
        let required = [
            "private static let maximumDeviceInventoryBytes = 1_048_576",
            "private static let maximumStreamConfigurationBytes = 1_048_576",
            "MemoryLayout<AudioBufferList>.offset(",
            "of: \\AudioBufferList.mBuffers",
            "returnedByteCount >= headerSize",
            "returnedByteCount <= allocatedByteCount",
            "UInt64(numberOfBuffers) <= UInt64(maximumBufferCount)",
            "(returnedByteCount - headerSize) / MemoryLayout<AudioBuffer>.stride",
            "memcpy(\n                &buffer,",
            "var channelCount: UInt64 = 0",
            "channelCount <= UInt64(UInt32.max)",
            "validStreamConfigurationAllocationSize(",
            "readSize <= size",
            "devices.prefix(returnedCount)",
            "allocatedByteCount: headerSize,\n            returnedByteCount: headerSize",
            "allocatedByteCount: populatedSize,\n            returnedByteCount: populatedSize",
            "channels: [UInt32.max, 1]",
            "prepare(numberOfBuffers: 0, channels: [7])",
            "maximumStreamConfigurationBytes + 1",
            "headerSize - 1",
            "validDeviceInventoryByteCount(Int(size))",
            "returnedByteCount <= allocatedByteCount",
            "returnedByteCount.isMultiple(",
            "deviceInventorySizeSelfTestPasses()",
        ]
        return required.allSatisfy(reader.contains)
            && !reader.contains("UnsafeMutableAudioBufferListPointer")
            && !reader.contains("bindMemory(to: AudioBufferList.self")
    }

    private func hasStateSpecificRootIdleContract(_ controller: String) -> Bool {
        guard
            let model = try? functionBody(
                controller,
                beginningWith: "\nenum RootProtocolExpectedCommand {",
                endingBefore: "\nfn root_protocol("
            ),
            let protocolBody = try? functionBody(
                controller,
                beginningWith: "\nfn root_protocol(",
                endingBefore: "\nfn root_broker()"
            ),
            let mirrorJSON = try? functionBody(
                controller,
                beginningWith: "\nfn verify_json_contract_until(",
                endingBefore: "\nfn mirror_result_contract_program("
            ),
            let mirrorProbe = try? functionBody(
                controller,
                beginningWith: "\nfn run_mirror_probe_until(",
                endingBefore: "\nfn run_live_guardian_heartbeat_until("
            ),
            let liveHeartbeat = try? functionBody(
                controller,
                beginningWith: "\nfn run_live_guardian_heartbeat_until(",
                endingBefore: "\nfn arm_live_trial_until("
            ),
            let liveArm = try? functionBody(
                controller,
                beginningWith: "\nfn arm_live_trial_until(",
                endingBefore: "\nfn stop_request_present()"
            ),
            let transaction = try? functionBody(
                controller,
                beginningWith: "\nfn uid_proxy_transaction()",
                endingBefore: "\nfn uid_local_trial_guardian()"
            )
        else {
            return false
        }
        let constantTokens = [
            "ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
            "ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
            "ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS\n        + POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS\n        + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
            "ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS\n        + MIRROR_PROBE_CALL_PRIMITIVE_SECONDS\n        + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
            "ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS: u64 =\n    POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS + ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
            "GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS: u64 = 5;",
            "ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS: u64 = 2\n    * POST_PUBLISH_GUARDIAN_EXCHANGE_PRIMITIVE_SECONDS\n    + GUARDIAN_FINISH_ABSOLUTE_SECONDS\n    + GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS\n    + 2 * ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
            "MIRROR_PROBE_HASH_PRIMITIVE_SECONDS",
            "MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS",
            "MIRROR_PROBE_OUTPUT_WRITES_PRIMITIVE_SECONDS",
            "MIRROR_PROBE_JSON_PRIMITIVE_SECONDS",
            "MIRROR_PROBE_CALL_HANDOFF_SECONDS: u64 = 1",
            "MIRROR_PROBE_CALL_PRIMITIVE_SECONDS: u64 =\n    MIRROR_PROBE_CALL_HANDOFF_SECONDS + MIRROR_PROBE_PRIMITIVE_SECONDS;",
            "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS: u64 =",
            "LIVE_ITERATION_OVERHANG_SECONDS: u64 =",
            "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS + LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
            "LIVE_ARM_EVIDENCE_PUBLICATION_PRIMITIVE_SECONDS: u64 =",
            "LIVE_ARM_PRIMITIVE_SECONDS: u64 =",
            "GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS: u64 =",
        ]
        let modelTokens = [
            "Self::PrestopFence => ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS",
            "Self::PostStopPing => ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS",
            "Self::PostPublishFence => ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS",
            "Self::PostMirrorPing => ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS",
            "Self::CandidateRelease => ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS",
            "ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS",
            "| Self::Live\n            | Self::RoutesRepaired",
            "Self::PrestopFence => command == \"L1Ciab PRESTOP_FENCE\",",
            "Self::PostPublishFence => command.starts_with(\"L1Ciab POST_PUBLISH_FENCE \"),",
            "Self::CandidateRelease => command == \"L1Ciab RELEASE_CANDIDATE_GATE\",",
            "Self::GuardianReaped => command.starts_with(\"L1Ciab GUARDIAN_REAPED \"),",
            "Self::Live if command == \"L1Ciab CANDIDATE_STOPPED\" => Self::GuardianReaped",
            "Self::Live => Self::Live",
        ]
        return constantTokens.allSatisfy(controller.contains)
            && modelTokens.allSatisfy(model.contains)
            && containsOrdered(
                [
                    "let mut expected_command = RootProtocolExpectedCommand::GuardianState;",
                    "Duration::from_secs(expected_command.idle_seconds())",
                    "responses.recv_timeout(timeout)",
                    "if !expected_command.accepts(&command)",
                    "root_send(&mut stream, &response)?;",
                    "expected_command = expected_command.after(&command)?;",
                ],
                in: protocolBody
            )
            && !protocolBody.contains(
                "Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),\n            remaining,"
            )
            && controller.contains("ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS != 85")
            && controller.contains("ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS != 85")
            && controller.contains(
                "ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS != 139"
            )
            && controller.contains("ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS != 175")
            && controller.contains("ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS != 85")
            && controller.contains(
                "ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS != 205"
            )
            && controller.contains("MIRROR_PROBE_CALL_PRIMITIVE_SECONDS != 90")
            && controller.contains("LIVE_ARM_PRIMITIVE_SECONDS != 315")
            && controller.contains("GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS != 280")
            && controller.contains(
                "RootProtocolExpectedCommand::Live.idle_seconds() != ROOT_BROKER_DEADMAN_SECONDS"
            )
            && containsOrdered(
                [
                    ".checked_duration_since(Instant::now())",
                    ".checked_sub(Duration::from_secs(MIRROR_PROBE_TEARDOWN_SECONDS))",
                    "Duration::from_secs(maximum_seconds)",
                    "if !output.status.success() || Instant::now() >= deadline",
                ],
                in: mirrorJSON
            )
            && !mirrorJSON.contains("maximum_seconds + MIRROR_PROBE_TEARDOWN_SECONDS")
            && containsOrdered(
                [
                    "let entry_deadline = Instant::now()",
                    "MIRROR_PROBE_PRIMITIVE_SECONDS",
                    "if outer_deadline < entry_deadline",
                    "let deadline = std::cmp::min(outer_deadline, entry_deadline);",
                    "MIRROR_PROBE_JSON_PRIMITIVE_SECONDS",
                    "MIRROR_PROBE_EXECUTION_PRIMITIVE_SECONDS",
                    "sha256_until(",
                    "MIRROR_PROBE_HASH_SECONDS",
                    "let execution_remaining = execution_deadline",
                    ".checked_duration_since(Instant::now())",
                    "Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS)",
                    "write_new_private_bytes(&layout.mirror_stdout",
                    "stdout_write_deadline",
                    "write_new_private_bytes(&layout.mirror_stderr",
                    "stderr_write_deadline",
                    "verify_mirror_result_until(&layout.mirror_result, deadline)?;",
                ],
                in: mirrorProbe
            )
            && !mirrorProbe.contains("require_hash(Path::new(SEALED_MIRROR_PROBE)")
            && !mirrorProbe.contains("verify_mirror_result(&layout.mirror_result)")
            && containsOrdered(
                [
                    "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
                    "let guardian_deadline = local_deadline",
                    "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
                    "let first_root_deadline = guardian_deadline",
                    "LIVE_GUARDIAN_HEARTBEAT_PRIMITIVE_SECONDS",
                    "root.exchange_until(",
                    "guardian.exchange_until(",
                    "LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS",
                    "if Instant::now() >= guardian_deadline",
                    "root.exchange_until(",
                    "if Instant::now() >= local_deadline",
                ],
                in: liveHeartbeat
            )
            && liveHeartbeat.components(separatedBy: "root.exchange_until(").count - 1 == 2
            && containsOrdered(
                [
                    "let health_deadline = deadline",
                    "LIVE_GUARDIAN_ROOT_HEARTBEAT_PRIMITIVE_SECONDS",
                    "let evidence_deadline = health_deadline",
                    "LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS",
                    "append_journal(layout,",
                    "if Instant::now() >= journal_deadline",
                    "append_private_line(",
                    "if Instant::now() >= evidence_deadline",
                    "root.request_until(",
                    "run_live_guardian_heartbeat_until(root, guardian, deadline)?;",
                ],
                in: liveArm
            )
            && transaction.contains("run_mirror_probe_until(mirror_probe_deadline)?;")
            && transaction.contains("MIRROR_PROBE_CALL_PRIMITIVE_SECONDS")
            && transaction.contains("arm_live_trial_until(")
            && transaction.contains("run_live_guardian_heartbeat_until(")
            && transaction.contains("GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS")
            && transaction.contains(
                "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline\n        .checked_sub(Duration::from_secs(LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS))"
            )
            && containsOrdered(
                [
                    "publish_guardian_reaped_on_root_capability(guardian_pid)?;",
                    "if !guardian_outcome.diagnostics.is_empty()",
                    "GUARDIAN_REAPED_WITH_DIAGNOSTICS {}",
                    "if Instant::now() >= guardian_reaped_command_deadline",
                    "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
                ],
                in: transaction
            )
            && transaction.contains(
                "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")"
            )
            && transaction.contains("guardian_reaped_transition_deadline,")
            && controller.contains(
                "let gate_to_prestop_wait = RootProtocolExpectedCommand::PrestopFence.idle_seconds();"
            )
            && controller.contains(
                "let post_stop_ping_wait = RootProtocolExpectedCommand::PostStopPing.idle_seconds();"
            )
            && controller.contains(
                "let post_publish_fence_wait = RootProtocolExpectedCommand::PostPublishFence.idle_seconds();"
            )
            && controller.contains(
                "let post_fence_second_ping_wait = RootProtocolExpectedCommand::PostMirrorPing.idle_seconds();"
            )
            && controller.contains(
                "let probes_to_release_wait = RootProtocolExpectedCommand::CandidateRelease.idle_seconds();"
            )
            && controller.contains("let live_arm = LIVE_ARM_PRIMITIVE_SECONDS;")
            && controller.contains(
                "let trial_with_final_heartbeat = 600 + LIVE_ITERATION_OVERHANG_SECONDS;"
            )
            && controller.contains("let stop_phase_sum = LIVE_ITERATION_OVERHANG_SECONDS")
            && controller.contains(
                "let guardian_reaped_transition = GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS;"
            )
            && controller.contains("|| complete_protocol_sum != 29_534")
            && controller.contains("|| root_lifecycle_ceiling != 72_209")
            && controller.contains("const ROOT_BROKER_ABSOLUTE_SECONDS: u64 = 73_000;")
    }

    private func hasStrictExplicitLoginKeychainContract(_ controller: String) -> Bool {
        guard
            let metadataPredicate = try? functionBody(
                controller,
                beginningWith: "fn isolated_pairing_keychain_metadata_is_exact(",
                endingBefore: "fn require_isolated_pairing_login_keychain("
            ),
            let metadataProof = try? functionBody(
                controller,
                beginningWith: "fn require_isolated_pairing_login_keychain(",
                endingBefore: "fn verify_isolated_pairing_items_present("
            ),
            let query = try? functionBody(
                controller,
                beginningWith: "fn verify_isolated_pairing_items_present(",
                endingBefore: "fn require_root_owned_system_executable("
            )
        else {
            return false
        }

        let sourceTokens = [
            #"const ISOLATED_PAIRING_LOGIN_KEYCHAIN: &str ="#,
            #"/Users/ahmed/Library/Keychains/login.keychain-db"#,
            "const ISOLATED_PAIRING_LOGIN_KEYCHAIN_GID: u32 = 20;",
            "const ISOLATED_PAIRING_LOGIN_KEYCHAIN_MODE: u32 = 0o644;",
        ]
        let predicateTokens = [
            "proof.is_regular_file",
            "!proof.is_symlink",
            "proof.uid == USER_ID",
            "proof.gid == ISOLATED_PAIRING_LOGIN_KEYCHAIN_GID",
            "proof.nlink == 1",
            "proof.mode == ISOLATED_PAIRING_LOGIN_KEYCHAIN_MODE",
        ]
        let proofTokens = [
            "geteuid() } != USER_ID",
            "fs::symlink_metadata(path)?",
            "metadata.file_type().is_file()",
            "metadata.file_type().is_symlink()",
            "uid: metadata.uid()",
            "gid: metadata.gid()",
            "nlink: metadata.nlink()",
            "metadata.permissions().mode() & 0o7777",
        ]
        let queryTokens = [
            #"require_root_owned_system_executable(Path::new("/usr/bin/security"))?;"#,
            "require_isolated_pairing_login_keychain()?;",
            "ISOLATED_PAIRING_IDENTITY_ACCOUNT",
            "ISOLATED_PAIRING_VIEWER_ACCOUNT",
            #""find-generic-password""#,
            "ISOLATED_PAIRING_LOGIN_KEYCHAIN,",
        ]
        return sourceTokens.allSatisfy(controller.contains)
            && predicateTokens.allSatisfy(metadataPredicate.contains)
            && proofTokens.allSatisfy(metadataProof.contains)
            && queryTokens.allSatisfy(query.contains)
            && query.components(separatedBy: "ISOLATED_PAIRING_LOGIN_KEYCHAIN,").count - 1 == 1
            && !query.contains(#""-w""#)
    }

    private func hasRootSealedV7ControllerIdentityContract(
        controller: String,
        launcher: String
    ) -> Bool {
        guard
            let stableIdentity = try? functionBody(
                controller,
                beginningWith: "fn stable_controller_binary_identity(",
                endingBefore: "fn verified_uid501_controller_identity()"
            ),
            let uidBootstrap = try? functionBody(
                controller,
                beginningWith: "fn bootstrap_root_owned_v7_controller_for_prepare()",
                endingBefore: "fn verify_root_owned_v7_controller_for_restore("
            ),
            let rootBootstrap = try? functionBody(
                controller,
                beginningWith: "fn bootstrap_root_controller_identity()",
                endingBefore: "fn publish_root_controller()"
            ),
            let rootVerification = try? functionBody(
                controller,
                beginningWith: "fn verify_root_controller_identity()",
                endingBefore: "fn require_retry_3_root_operation_trust("
            ),
            let proxyVerification = try? functionBody(
                controller,
                beginningWith: "fn verify_uid501_controller_against_root_pin()",
                endingBefore: "fn sudo_install_directory("
            )
        else {
            return false
        }

        let launcherTokens = [
            "EXPECTED_BINARY_SHA256='0e70c2f4b9be266b793ad307a51be9c7c798b37c15abd83f2235d132439938e9'",
            "CONTROLLER_BINARY_SHA256=$(/usr/bin/shasum -a 256 \"$CONTROLLER\"",
            "[ \"$CONTROLLER_BINARY_SHA256\" = \"$EXPECTED_BINARY_SHA256\" ]",
            "compiled paired-v7 controller differs from the reviewed binary hash",
        ]
        let stableIdentityTokens = [
            ".custom_flags(O_NOFOLLOW)",
            "metadata.nlink() == 1",
            "metadata.len() <= MAX_V7_CONTROLLER_BYTES",
            "before.dev() != after.dev()",
            "before.ino() != after.ino()",
            "sha256: sha256_bytes(&bytes)?",
        ]
        let uidBootstrapTokens = [
            "let before = verified_uid501_controller_identity()?;",
            #"ROOT_V7_CONTROLLER,"#,
            "parse_shasum_output(",
            ")? != before.sha256",
            #"sudo_output(&["-n", ROOT_V7_CONTROLLER, ROOT_V7_CONTROLLER_BOOTSTRAP_MODE])?"#,
            "let after = verified_uid501_controller_identity()?;",
            "if before != after",
            "read_root_controller_identity_records_via_sudo()?",
            "sealed.sha256 != after.sha256 || sealed.length != after.length",
        ]
        let rootBootstrapTokens = [
            "geteuid() } != 0",
            "env::current_exe()? != Path::new(ROOT_V7_CONTROLLER)",
            "stable_controller_binary_identity(",
            "Path::new(ROOT_V7_CONTROLLER_PIN)",
            "Path::new(ROOT_V7_CONTROLLER_IDENTITY_JOURNAL)",
            "read_root_controller_identity_records()? != identity",
        ]
        return launcherTokens.allSatisfy(launcher.contains)
            && !controller.contains("const EXPECTED_BINARY_SHA256")
            && stableIdentityTokens.allSatisfy(stableIdentity.contains)
            && uidBootstrapTokens.allSatisfy(uidBootstrap.contains)
            && rootBootstrapTokens.allSatisfy(rootBootstrap.contains)
            && rootVerification.contains(
                "require_root_controller_identity_binding(&actual, &sealed)?;"
            )
            && proxyVerification.contains(
                "require_proxy_controller_identity_binding(&actual, &sealed)?;"
            )
    }

    private func hasTwoCommitV7ReleaseCycleContract(_ controller: String) -> Bool {
        guard
            let inputSelection = try? functionBody(
                controller,
                beginningWith: "fn functional_input_path(",
                endingBefore: "fn require_canonical_release_path("
            ),
            let inputEnumeration = try? functionBody(
                controller,
                beginningWith: "fn canonical_functional_inputs_from_git(",
                endingBefore: "fn canonical_functional_inputs_sha256("
            ),
            let inputDigest = try? functionBody(
                controller,
                beginningWith: "fn canonical_functional_inputs_sha256(",
                endingBefore: "fn release_changed_paths("
            ),
            let changedPaths = try? functionBody(
                controller,
                beginningWith: "fn release_changed_paths(",
                endingBefore: "fn validate_release_cycle_evidence("
            ),
            let validator = try? functionBody(
                controller,
                beginningWith: "fn validate_release_cycle_evidence(",
                endingBefore: "fn read_candidate_source_binding("
            ),
            let verifier = try? functionBody(
                controller,
                beginningWith: "fn verify_candidate_manifest_provenance(",
                endingBefore: "fn materialize_reviewed_production_driver("
            )
        else {
            return false
        }

        let sourceTokens = [
            "const REQUIRED_RELEASE_DIFF_PATHS: [&str; 2]",
            "const RELEASE_ONLY_PATH_ALLOWLIST: [&str; 9]",
            "const EXPECTED_FUNCTIONAL_INPUTS_SHA256: &str",
            "self_test_release_cycle_contract()?;",
        ]
        let enumerationTokens = [
            #"&["ls-tree", "-r", "-z", "--full-tree", commit, "--"]"#,
            "!listing.stdout.ends_with(&[0])",
            #"!matches!(fields[0], "100644" | "100755")"#,
            #"fields[1] != "blob""#,
            #"&["cat-file", "blob", fields[2]]"#,
            "inputs.sort();",
        ]
        let digestTokens = [
            "OPENSTEAMER_FUNCTIONAL_INPUTS_V1",
            "path_length={} path={} mode={} sha256={}",
            "previous.is_some_and(|path| path >= input.path.as_str())",
            "sha256_bytes(&canonical)",
        ]
        let pathTokens = [
            #""diff","#,
            #""--name-only","#,
            #""--no-renames","#,
            #""-z","#,
            "!diff.stdout.ends_with(&[0])",
            "paths.sort();",
        ]
        let validationTokens = [
            "candidate.tree != resolved_candidate_tree",
            "candidate.commit == release_commit || !candidate_is_ancestor",
            "!RELEASE_ONLY_PATH_ALLOWLIST.contains(&path.as_str())",
            "REQUIRED_RELEASE_DIFF_PATHS",
            "source_inputs.is_empty() || source_inputs != release_inputs",
            "actual != expected_functional_inputs_sha256",
        ]
        let verificationTokens = [
            #"&["rev-parse", "--verify", &format!("{}^{{commit}}", candidate.commit)]"#,
            #"&["rev-parse", &format!("{}^{{tree}}", candidate.commit)]"#,
            #""merge-base","#,
            #""--is-ancestor","#,
            "release_changed_paths(repo, &candidate.commit, &provenance.commit)?",
            "canonical_functional_inputs_from_git(repo, &candidate.commit)?",
            "canonical_functional_inputs_from_git(repo, &provenance.commit)?",
            "validate_release_cycle_evidence(",
        ]
        return sourceTokens.allSatisfy(controller.contains)
            && inputSelection.contains("RELEASE_ONLY_PATH_ALLOWLIST.contains(&path)")
            && inputSelection.contains(#"path.starts_with("macOS/Sources/")"#)
            && inputSelection.contains(#"path.starts_with("macOS/VirtualAudioDriver/")"#)
            && enumerationTokens.allSatisfy(inputEnumeration.contains)
            && digestTokens.allSatisfy(inputDigest.contains)
            && pathTokens.allSatisfy(changedPaths.contains)
            && validationTokens.allSatisfy(validator.contains)
            && verificationTokens.allSatisfy(verifier.contains)
    }

    private func hasRebootStableRollbackReserveDeviceContract(_ controller: String) -> Bool {
        guard
            let mountIdentity = try? functionBody(
                controller,
                beginningWith: "fn data_volume_mount_identity(",
                endingBefore: "fn plist_value_after_unique_key"
            ),
            let plistValidation = try? functionBody(
                controller,
                beginningWith: "fn validate_data_volume_plist(",
                endingBefore: "fn verified_data_volume_device("
            ),
            let deviceDerivation = try? functionBody(
                controller,
                beginningWith: "fn verified_data_volume_device(",
                endingBefore: "fn sudo_output("
            ),
            let v5Verification = try? functionBody(
                controller,
                beginningWith: "fn verify_committed_v5_baseline(",
                endingBefore: "fn verify_committed_v6_baseline("
            ),
            let v6Verification = try? functionBody(
                controller,
                beginningWith: "fn verify_committed_v6_baseline(",
                endingBefore: "fn verify_committed_v3_oracle_pins("
            )
        else {
            return false
        }
        let exactPins = [
            #"const PINNED_DATA_VOLUME_MOUNT: &str = "/System/Volumes/Data";"#,
            #"const EXPECTED_DATA_VOLUME_UUID: &str = "AF638805-E0CB-4356-941F-16B84DFB6435";"#,
            #"const EXPECTED_DATA_VOLUME_GROUP_UUID: &str = "AF638805-E0CB-4356-941F-16B84DFB6435";"#,
            #"const PINNED_DATA_VOLUME_DISKUTIL: &str = "/usr/sbin/diskutil";"#,
            #""9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049";"#,
            "const COMMITTED_V5_RESERVE_INODE: u64 = 25_430_692;",
            "const COMMITTED_V6_RESERVE_INODE: u64 = 25_795_487;",
        ]
        let mountTokens = [
            "let mount = Path::new(PINNED_DATA_VOLUME_MOUNT);",
            "let metadata = fs::symlink_metadata(mount)?;",
            "!metadata.file_type().is_dir()",
            "metadata.file_type().is_symlink()",
            "metadata.uid() != 0",
            "metadata.gid() != 80",
            "metadata.permissions().mode() & 0o7777 != 0o775",
            "metadata.st_flags() != 0",
            "metadata.dev() == 0",
            "fs::canonicalize(mount)? != mount",
            "device: metadata.dev(),",
            "inode: metadata.ino(),",
            "mode: metadata.mode(),",
            "links: metadata.nlink(),",
            "length: metadata.len(),",
            "flags: metadata.st_flags(),",
        ]
        let plistTokens = [
            #"("VolumeUUID", EXPECTED_DATA_VOLUME_UUID)"#,
            #"("APFSVolumeGroupID", EXPECTED_DATA_VOLUME_GROUP_UUID)"#,
            #"("MountPoint", PINNED_DATA_VOLUME_MOUNT)"#,
            #"("FilesystemType", "apfs")"#,
            #"if !exact_plist_boolean(plist, "Internal")?"#,
            #"if !exact_plist_boolean(plist, "Writable")?"#,
        ]
        let derivationTokens = [
            "let diskutil = Path::new(PINNED_DATA_VOLUME_DISKUTIL);",
            "require_fixed_system_binary(diskutil, 0o755)?;",
            "sha256(diskutil)? != EXPECTED_DATA_VOLUME_DISKUTIL_SHA256",
            "let mount_before = data_volume_mount_identity()?;",
            "let volume = Command::new(PINNED_DATA_VOLUME_DISKUTIL)",
            #".args(["info", "-plist", PINNED_DATA_VOLUME_MOUNT])"#,
            ".env_clear()",
            #".env("LC_ALL", "C")"#,
            #".env("HOME", USER_HOME)"#,
            #".env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")"#,
            "require_output_success(&volume, \"inspect the canonical APFS Data volume\")?;",
            "volume.stdout.len() < 256",
            "volume.stdout.len() > 131_072",
            "!volume.stderr.is_empty()",
            "volume.stdout.contains(&0)",
            "volume.stdout.contains(&b'\\r')",
            "let mount_after = data_volume_mount_identity()?;",
            "mount_after != mount_before",
            "validate_data_volume_plist(decode_utf8(",
            "Ok(mount_before.device)",
        ]
        let v5Tokens = [
            #"let reserve = evidence.join("rollback-reserve.bin");"#,
            "require_regular(&reserve, 0o600)?;",
            "let reserve_metadata = fs::symlink_metadata(&reserve)?;",
            "reserve_metadata.dev() != data_volume_device",
            "reserve_metadata.ino() != COMMITTED_V5_RESERVE_INODE",
            "reserve_metadata.len() != 0",
            "reserve_metadata.blocks() != 0",
        ]
        let v6Tokens = [
            "let data_volume_device = verified_data_volume_device()?;",
            "verify_committed_v5_baseline(data_volume_device)?;",
            #"let reserve = evidence.join("rollback-reserve.bin");"#,
            "require_regular(&reserve, 0o600)?;",
            "let reserve_metadata = fs::symlink_metadata(&reserve)?;",
            "reserve_metadata.dev() != data_volume_device",
            "reserve_metadata.ino() != COMMITTED_V6_RESERVE_INODE",
            "reserve_metadata.len() != 0",
            "reserve_metadata.blocks() != 0",
        ]
        return exactPins.allSatisfy(controller.contains)
            && !controller.contains("COMMITTED_V5_RESERVE_DEVICE")
            && !controller.contains("COMMITTED_V6_RESERVE_DEVICE")
            && !v5Verification.contains("16_777_229")
            && !v6Verification.contains("16_777_229")
            && containsOrdered(mountTokens, in: mountIdentity)
            && containsOrdered(plistTokens, in: plistValidation)
            && containsOrdered(derivationTokens, in: deviceDerivation)
            && containsOrdered(v5Tokens, in: v5Verification)
            && containsOrdered(v6Tokens, in: v6Verification)
    }

    private func hasEvidencePreservingRetryNamespaceContract(_ controller: String) -> Bool {
        let retainedRoot =
            #"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7"#
        let retry2Pointer =
            #"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-2"#
        let retry1Pointer =
            #"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-1"#
        let firstAttemptPointer =
            #"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7"#
        let retainedName =
            "paired-v7-update-1787367704-92913-bba21548-458c-4d31-bd0a-eccdb282c02a"
        let retainedPath = retainedRoot + "/" + retainedName
        let retainedRetry1Name =
            "paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25"
        let retainedRetry1Path = retainedRoot + "/" + retainedRetry1Name
        guard
            controller.contains(
                "const V7_UPDATE_ROOT: &str =\n        \"" + retainedRoot + "\";"
            ),
            controller.contains(
                "const V7_ACTIVE_UPDATE: &str =\n        \"" + retry2Pointer + "\";"
            ),
            controller.contains(
                "const FIRST_ATTEMPT_V7_ACTIVE_UPDATE: &str =\n        \""
                    + firstAttemptPointer + "\";"
            ),
            controller.contains(
                "const RETRY_1_V7_ACTIVE_UPDATE: &str =\n        \""
                    + retry1Pointer + "\";"
            ),
            controller.contains(
                "const RETAINED_FAILED_V7_ATTEMPT_NAME: &str =\n        \""
                    + retainedName + "\";"
            ),
            controller.contains(
                "const RETAINED_FAILED_V7_ATTEMPT: &str =\n        \""
                    + retainedPath + "\";"
            ),
            controller.contains(
                "const RETAINED_FAILED_V7_RETRY_1_NAME: &str =\n        \""
                    + retainedRetry1Name + "\";"
            ),
            controller.contains(
                "const RETAINED_FAILED_V7_RETRY_1: &str =\n        \""
                    + retainedRetry1Path + "\";"
            ),
            !controller.contains("paired-host-updates-v7-retry-1"),
            let singleChild = try? functionBody(
                controller,
                beginningWith: "fn require_exact_single_private_directory_child_at(",
                endingBefore: "fn require_exact_retained_file("
            ),
            let exactFile = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_file(",
                endingBefore: "fn require_exact_retained_failure_file("
            ),
            let exactFailureFile = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_failure_file(",
                endingBefore: "fn require_exact_retained_empty_directory("
            ),
            let emptyDirectory = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_empty_directory(",
                endingBefore: "fn require_exact_retained_probe_directory("
            ),
            let probes = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_probe_directory(",
                endingBefore: "fn require_exact_retained_retry_1_probe_directory("
            ),
            let retry1Probes = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_retry_1_probe_directory(",
                endingBefore: "fn require_no_v7_pending_pointers()"
            ),
            let pendingScan = try? functionBody(
                controller,
                beginningWith: "fn require_no_v7_pending_pointers()",
                endingBefore: "fn require_exact_retained_v7_top_level("
            ),
            let topLevel = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_v7_top_level(",
                endingBefore: "fn require_exact_retained_v7_evidence("
            ),
            let retainedEvidence = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_v7_evidence(",
                endingBefore: "fn require_exact_retained_retry_1_v7_evidence("
            ),
            let retainedRetry1Evidence = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_retry_1_v7_evidence(",
                endingBefore: "fn require_v7_retry_admission_ready()"
            ),
            let admission = try? functionBody(
                controller,
                beginningWith: "fn require_v7_retry_admission_ready()",
                endingBefore: "enum RetryV7PointerExpectation"
            ),
            let rootNames = try? functionBody(
                controller,
                beginningWith: "fn require_exact_v7_root_names(",
                endingBefore: "fn require_exact_v7_retained_pair("
            ),
            let retainedPair = try? functionBody(
                controller,
                beginningWith: "fn require_exact_v7_retained_pair(",
                endingBefore: "fn require_exact_v7_root_triplet("
            ),
            let rootTriplet = try? functionBody(
                controller,
                beginningWith: "fn require_exact_v7_root_triplet(",
                endingBefore: "fn require_retry_v7_pointer_expectation("
            ),
            let pointerExpectation = try? functionBody(
                controller,
                beginningWith: "fn require_retry_v7_pointer_expectation(",
                endingBefore: "fn require_current_retry_v7_layout("
            ),
            let currentRetry = try? functionBody(
                controller,
                beginningWith: "fn require_current_retry_v7_layout(",
                endingBefore: "fn execute_paired_v7_update("
            ),
            let main = try? functionBody(
                controller,
                beginningWith: "fn paired_v7_real_main()",
                endingBefore: "fn parse_v7_command("
            ),
            let parseCommand = try? functionBody(
                controller,
                beginningWith: "fn parse_v7_command(",
                endingBefore: "fn require_canonical_git_oid("
            ),
            let execute = try? functionBody(
                controller,
                beginningWith: "fn execute_paired_v7_update(",
                endingBefore: "fn perform_paired_v7_update("
            ),
            let perform = try? functionBody(
                controller,
                beginningWith: "fn perform_paired_v7_update(",
                endingBefore: "fn rollback_existing_paired_v7_update("
            ),
            let pendingLeafPID = try? functionBody(
                controller,
                beginningWith: "fn require_retry_v7_leaf_main_pid(",
                endingBefore: "fn open_exact_retry_v7_pending_pointer("
            ),
            let pendingFile = try? functionBody(
                controller,
                beginningWith: "fn open_exact_retry_v7_pending_pointer(",
                endingBefore: "fn retire_exact_retry_v7_pending_pointer_after_parent_crash("
            ),
            let pendingRecovery = try? functionBody(
                controller,
                beginningWith: "fn retire_exact_retry_v7_pending_pointer_after_parent_crash(",
                endingBefore: "fn uid_proxy_complete_host_crash_rollback("
            ),
            let crashRecovery = try? functionBody(
                controller,
                beginningWith: "fn uid_proxy_complete_host_crash_rollback(",
                endingBefore: "fn uid501_driver_broker_proxy("
            ),
            let restoreLayout = try? functionBody(
                controller,
                beginningWith: "fn existing_v7_layout_for_restore_proxy(",
                endingBefore: "fn uid_restore_proxy_abort("
            ),
            let restoreProxy = try? functionBody(
                controller,
                beginningWith: "fn uid501_driver_restore_proxy(",
                endingBefore: "struct RootExistingDriverRestoreClient"
            ),
            let restoreClient = try? functionBody(
                controller,
                beginningWith: "impl RootExistingDriverRestoreClient",
                endingBefore: "impl Drop for RootExistingDriverRestoreClient"
            ),
            let pointerTokens = try? functionBody(
                controller,
                beginningWith: "impl RetryV7PointerExpectation",
                endingBefore: "fn require_exact_v7_root_names("
            ),
            let rollback = try? functionBody(
                controller,
                beginningWith: "fn rollback_existing_paired_v7_update(",
                endingBefore: "fn rollback_to_current_baseline("
            ),
            let rollbackBaseline = try? functionBody(
                controller,
                beginningWith: "fn rollback_to_current_baseline(",
                endingBefore: "fn v7_layout_from_existing("
            ),
            let pointerOperations = try? functionBody(
                controller,
                beginningWith: "fn publish_v7_active_pointer(",
                endingBefore: "fn path_exists_without_follow("
            )
        else {
            return false
        }
        let exactPins = [
            "active-paired-host-update-v7.pending-",
            "active-paired-host-update-v7-retry-1.pending-",
            "active-paired-host-update-v7-retry-2.pending-",
            "const RETAINED_FAILED_V7_ROOT_INODE: u64 = 27_737_655;",
            "const RETAINED_FAILED_V7_ATTEMPT_INODE: u64 = 27_737_656;",
            "const RETAINED_FAILED_V7_RESULT_INODE: u64 = 27_744_003;",
            "a2c6cc1df53d424a97cf6aca55672b7eeb39a6d528aa63315c1e878ab429adc4",
            "result=failed-before-stop\\ndiagnostic=required file has unsafe type/owner/link-count/mode:",
            "probes/physical-virtual-microphone-probe\\n\";",
            "const RETAINED_FAILED_V7_JOURNAL_INODE: u64 = 27_737_659;",
            "cdc94d9d88b6e12e41f485c217f9f88bbfc5621f226079501ee94b8512b80c3a",
            "STATE SOURCE_EXPORTED commit=1ec63de7b4f6721cf7b04b7445f54f0e33f8b3a0 tree=c343c0bac2d77036e7f3a78dacc3cbf48e83b7ee initial_pid=873",
            "const RETAINED_FAILED_V7_PROVENANCE_INODE: u64 = 27_738_087;",
            "b2205b990a7dc7773a8f65730179566a91999315e6769112b682070d3fbb7dc6",
            "functional_source_commit=7beb049226ada83e97afba3e60089469d0eeeef6",
            "functional_source_tree=60e2df01afe1b4c09362b8e1b55efa709f23a748",
            "authorized_release_commit=1ec63de7b4f6721cf7b04b7445f54f0e33f8b3a0",
            "authorized_release_tree=c343c0bac2d77036e7f3a78dacc3cbf48e83b7ee",
            "upstream=origin/agent/auto-select-iphone-microphone",
            "remote=https://github.com/ahmedelami/opensteamer.git",
            "functional_input_evidence_sha256=73a01a709f6a78b768696ac4105128a6b22de5ae3a46512980b8d77ea6370967",
            "source_archive_sha256=11d5a102b43e46856bd3b8a055e026bbc7a8c04365ad28cadb711eb4ac7de74d",
            "/Applications/.opensteamer-paired-v7-install-bba21548-458c-4d31-bd0a-eccdb282c02a",
            "const RETAINED_FAILED_V7_SOURCE_TAR_INODE: u64 = 27_737_662;",
            "const RETAINED_FAILED_V7_SOURCE_TAR_SIZE: u64 = 12_584_960;",
            "11d5a102b43e46856bd3b8a055e026bbc7a8c04365ad28cadb711eb4ac7de74d",
            "const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_INODE: u64 = 27_738_086;",
            "const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SIZE: u64 = 22_759;",
            "73a01a709f6a78b768696ac4105128a6b22de5ae3a46512980b8d77ea6370967",
            "const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_INODE: u64 = 27_737_660;",
            "const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SIZE: u64 = 82;",
            "faab67bc8d4008d4d01734876654c7935e7aaf3af98610402c7927f80d699e28",
            "const RETAINED_FAILED_V7_PROBES_INODE: u64 = 27_743_975;",
            "const RETAINED_FAILED_V7_PUBLIC_PROBE_INODE: u64 = 27_743_999;",
            "const RETAINED_FAILED_V7_PUBLIC_PROBE_SIZE: u64 = 154_912;",
            "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8",
            "const RETAINED_FAILED_V7_GUARDIAN_INODE: u64 = 27_743_985;",
            "const RETAINED_FAILED_V7_GUARDIAN_SIZE: u64 = 286_968;",
            "a59c39bfc198546729a430e7cdbfd19d982e30697c7e67e3a4bd72ca49304e1e",
            "const RETAINED_FAILED_V7_MIRROR_PROBE_INODE: u64 = 27_743_981;",
            "const RETAINED_FAILED_V7_MIRROR_PROBE_SIZE: u64 = 1_096_944;",
            "13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b",
            "const RETAINED_FAILED_V7_FAILED_NEW_INODE: u64 = 27_737_658;",
            "const RETAINED_FAILED_V7_ROLLBACK_CURRENT_INODE: u64 = 27_737_657;",
            "const RETAINED_FAILED_V7_RETRY_1_INODE: u64 = 27_758_526;",
            "const RETAINED_FAILED_V7_RETRY_1_RESULT_INODE: u64 = 27_765_144;",
            "606dd930e931ef96c1f028d4693473b39ad5c24fede939ed961d0e5c8b12aa70",
            "paired-v7 probe binary differs from its release pin:",
            "probes/opensteamer-v7-default-route-guardian\\n\";",
            "const RETAINED_FAILED_V7_RETRY_1_JOURNAL_INODE: u64 = 27_758_529;",
            "41a2e81d30d176f32dec89c1a770e0181695a3cb00428d09dcb449411d802827",
            "STATE SOURCE_EXPORTED commit=17c61bafcbef3e873bbd25789e3c516379bbac91 tree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d initial_pid=873",
            "const RETAINED_FAILED_V7_RETRY_1_PROVENANCE_INODE: u64 = 27_758_957;",
            "dba0fc40a54e28fee8a7ec55220d94be596097c4167466510a2808d1fb3ba114",
            "authorized_release_commit=17c61bafcbef3e873bbd25789e3c516379bbac91",
            "authorized_release_tree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d",
            "functional_input_evidence_sha256=42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75",
            "source_archive_sha256=bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1",
            "const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_INODE: u64 = 27_758_532;",
            "const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SIZE: u64 = 12_707_840;",
            "const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_INODE: u64 = 27_758_956;",
            "const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SIZE: u64 = 22_759;",
            "const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_INODE: u64 = 27_758_530;",
            "19c00bad374b30b1ea7d9e6ed23c3c2cd8c26e7e48a8aa059bb1eb7ffd15a3fb",
            "const RETAINED_FAILED_V7_RETRY_1_PROBES_INODE: u64 = 27_764_883;",
            "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_INODE: u64 = 27_765_140;",
            "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_INODE: u64 = 27_765_125;",
            "53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c",
            "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_INODE: u64 = 27_765_117;",
            "const RETAINED_FAILED_V7_RETRY_1_FAILED_NEW_INODE: u64 = 27_758_528;",
            "const RETAINED_FAILED_V7_RETRY_1_ROLLBACK_CURRENT_INODE: u64 = 27_758_527;",
            "/Applications/.opensteamer-paired-v7-install-716c0ed7-8cd5-4b9f-9d64-a3169a077a25",
        ]
        let scopedRetry1Declarations = [
            "const RETAINED_FAILED_V7_RETRY_1_RESULT: &str =\n        \"result=failed-before-stop\\ndiagnostic=paired-v7 probe binary differs from its release pin: /Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25/probes/opensteamer-v7-default-route-guardian\\n\";",
            "const RETAINED_FAILED_V7_RETRY_1_JOURNAL: &str =\n        \"OPENSTEAMER_PAIRED_HOST_UPDATE_V7\\nSTATE BEGUN\\nSTATE SOURCE_EXPORTED commit=17c61bafcbef3e873bbd25789e3c516379bbac91 tree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d initial_pid=873\\n\";",
            "const RETAINED_FAILED_V7_RETRY_1_PROVENANCE: &str =\n        \"commit=17c61bafcbef3e873bbd25789e3c516379bbac91\\ntree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d\\nfunctional_source_commit=7beb049226ada83e97afba3e60089469d0eeeef6\\nfunctional_source_tree=60e2df01afe1b4c09362b8e1b55efa709f23a748\\nauthorized_release_commit=17c61bafcbef3e873bbd25789e3c516379bbac91\\nauthorized_release_tree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d\\nupstream=origin/agent/auto-select-iphone-microphone\\nremote=https://github.com/ahmedelami/opensteamer.git\\nfunctional_inputs_sha256=fdef1da4413f66d5f066c86b0eba709b55c74b1f72b29dac8d62e991a2343ca6\\nfunctional_input_evidence_sha256=42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75\\nsource_archive_sha256=bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1\\n\";",
            "const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256: &str =\n        \"bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1\";",
            "const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256: &str =\n        \"42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75\";",
            "const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE: u64 = 82;",
            "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE: u64 = 154_912;",
            "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256: &str =\n        \"0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8\";",
            "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE: u64 = 286_968;",
            "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256: &str =\n        \"53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c\";",
            "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE: u64 = 1_096_944;",
            "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256: &str =\n        \"13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b\";",
        ]
        let singleChildTokens = [
            "expected_name.is_empty() || expected_name.contains('/')",
            "require_directory(root, 0o700)?;",
            "let root_before = fs::symlink_metadata(root)?;",
            "let mut entries = fs::read_dir(root)",
            "let entry = entries.next().transpose()?.ok_or_else(",
            "if entries.next().transpose()?.is_some()",
            "if entry.file_name().to_str() != Some(expected_name)",
            "let expected = root.join(expected_name);",
            "entry.path().as_os_str() != expected.as_os_str()",
            "require_directory(&expected, 0o700)?;",
            "let root_after = fs::symlink_metadata(root)?;",
            "root_before.dev() != root_after.dev()",
            "root_before.ino() != root_after.ino()",
            "Ok(expected)",
        ]
        let exactFileTokens = [
            "expected_mode: u32,",
            "expected_length: u64,",
            "expected_length > 16 * 1_024 * 1_024",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == expected_mode",
            "metadata.dev() == expected_device",
            "metadata.ino() == expected_inode",
            "metadata.len() == expected_length",
            "metadata.st_flags() == 0",
            "let named_before = fs::symlink_metadata(path)?;",
            "let mut file = OpenOptions::new()",
            ".read(true)",
            ".custom_flags(O_NOFOLLOW)",
            ".open(path)?;",
            "let descriptor_before = file.metadata()?;",
            "descriptor_before.dev() != named_before.dev()",
            "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()",
            "Read::by_ref(&mut file)",
            ".take(expected_length + 1)",
            "let descriptor_after = file.metadata()?;",
            "let named_after = fs::symlink_metadata(path)?;",
            "bytes.len() as u64 != expected_length",
            "sha256_bytes(&bytes)? != expected_sha256",
            "descriptor_before.dev() != descriptor_after.dev()",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.len() != descriptor_after.len()",
            "descriptor_before.dev() != named_after.dev()",
            "descriptor_before.ino() != named_after.ino()",
            "descriptor_before.len() != named_after.len()",
        ]
        let retainedEvidenceTokens = [
            "let root = Path::new(V7_UPDATE_ROOT);",
            "let retained = Path::new(RETAINED_FAILED_V7_ATTEMPT);",
            "retained.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)",
            "let root_before = fs::symlink_metadata(root)?;",
            "let retained_before = fs::symlink_metadata(retained)?;",
            "Path::new(RETAINED_FAILED_V7_INSTALL_HOLD),",
            #"&retained.join("rollback-reserve.bin"),"#,
            #"&retained.join("driver-transaction-record.txt"),"#,
            "require_exact_retained_v7_top_level(retained)?;",
            #"&retained.join("result.txt"),"#,
            "RETAINED_FAILED_V7_RESULT_INODE,",
            #"&retained.join("journal.log"),"#,
            "RETAINED_FAILED_V7_JOURNAL_INODE,",
            #"&retained.join("provenance.txt"),"#,
            "RETAINED_FAILED_V7_PROVENANCE_INODE,",
            #"&retained.join("source.tar"),"#,
            "RETAINED_FAILED_V7_SOURCE_TAR_INODE,",
            #"&retained.join("functional-inputs.txt"),"#,
            "RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_INODE,",
            #"&retained.join("install-hold-name.txt"),"#,
            "RETAINED_FAILED_V7_INSTALL_HOLD_NAME_INODE,",
            "require_exact_retained_probe_directory(retained, expected_device)?;",
            #"&retained.join("failed-new"),"#,
            "RETAINED_FAILED_V7_FAILED_NEW_INODE,",
            #"&retained.join("rollback-current"),"#,
            "RETAINED_FAILED_V7_ROLLBACK_CURRENT_INODE,",
            "require_exact_retained_v7_top_level(retained)?;",
            "let retained_after = fs::symlink_metadata(retained)?;",
            "let root_after = fs::symlink_metadata(root)?;",
            "root_before.ino() != root_after.ino()",
            "retained_before.ino() != retained_after.ino()",
        ]
        let retainedRetry1EvidenceTokens = [
            "let root = Path::new(V7_UPDATE_ROOT);",
            "let retained = Path::new(RETAINED_FAILED_V7_RETRY_1);",
            "RETAINED_FAILED_V7_RETRY_1_INODE",
            "retained.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)",
            "let root_before = fs::symlink_metadata(root)?;",
            "let retained_before = fs::symlink_metadata(retained)?;",
            "Path::new(RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD),",
            #"&retained.join("rollback-reserve.bin"),"#,
            #"&retained.join("driver-transaction-record.txt"),"#,
            #"&retained.join("retired-pending-active-pointer.txt"),"#,
            "require_exact_retained_v7_top_level(retained)?;",
            #"&retained.join("result.txt"),"#,
            "RETAINED_FAILED_V7_RETRY_1_RESULT_INODE,",
            "RETAINED_FAILED_V7_RETRY_1_RESULT,",
            "RETAINED_FAILED_V7_RETRY_1_RESULT_SHA256,",
            #"&retained.join("journal.log"),"#,
            "RETAINED_FAILED_V7_RETRY_1_JOURNAL_INODE,",
            "RETAINED_FAILED_V7_RETRY_1_JOURNAL,",
            "RETAINED_FAILED_V7_RETRY_1_JOURNAL_SHA256,",
            #"&retained.join("provenance.txt"),"#,
            "RETAINED_FAILED_V7_RETRY_1_PROVENANCE_INODE,",
            "RETAINED_FAILED_V7_RETRY_1_PROVENANCE,",
            "RETAINED_FAILED_V7_RETRY_1_PROVENANCE_SHA256,",
            #"&retained.join("source.tar"),"#,
            "RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_INODE,",
            "RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SIZE,",
            "RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256,",
            #"&retained.join("functional-inputs.txt"),"#,
            "RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_INODE,",
            "RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SIZE,",
            "RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256,",
            #"&retained.join("install-hold-name.txt"),"#,
            "RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_INODE,",
            "RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE,",
            "RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SHA256,",
            "require_exact_retained_retry_1_probe_directory(retained, expected_device)?;",
            #"&retained.join("failed-new"),"#,
            "RETAINED_FAILED_V7_RETRY_1_FAILED_NEW_INODE,",
            #"&retained.join("rollback-current"),"#,
            "RETAINED_FAILED_V7_RETRY_1_ROLLBACK_CURRENT_INODE,",
            "require_exact_retained_v7_top_level(retained)?;",
            "let retained_after = fs::symlink_metadata(retained)?;",
            "let root_after = fs::symlink_metadata(root)?;",
            "root_before.ino() != root_after.ino()",
            "retained_before.ino() != retained_after.ino()",
        ]
        let admissionTokens = [
            "Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),",
            "\"retained first-attempt paired-v7 pointer\",",
            "Path::new(RETRY_1_V7_ACTIVE_UPDATE),",
            "\"retained retry-1 paired-v7 pointer\",",
            #"require_path_absent(Path::new(V7_ACTIVE_UPDATE), "retry paired-v7 pointer")?;"#,
            "require_no_v7_pending_pointers()?;",
            "Path::new(RETAINED_FAILED_V7_INSTALL_HOLD),",
            "Path::new(RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD),",
            "Path::new(ROOT_V7_SUPPORT_DIRECTORY),",
            "Path::new(ROOT_V7_TRANSACTION_PARENT),",
            "let data_volume_device = verified_data_volume_device()?;",
            "let root = Path::new(V7_UPDATE_ROOT);",
            "require_exact_v7_retained_pair(root)?;",
            "require_exact_retained_v7_evidence(data_volume_device)?;",
            "require_exact_retained_retry_1_v7_evidence(data_volume_device)?;",
            "require_exact_v7_retained_pair(root)",
        ]
        return exactPins.allSatisfy(controller.contains)
            && scopedRetry1Declarations.allSatisfy(controller.contains)
            && containsOrdered(singleChildTokens, in: singleChild)
            && containsOrdered(exactFileTokens, in: exactFile)
            && containsOrdered(
                [
                    "let bytes = require_exact_retained_file(",
                    "0o600,",
                    "expected_bytes.len() as u64,",
                    "expected_sha256,",
                    "bytes.as_slice() != expected_bytes.as_bytes()",
                ],
                in: exactFailureFile
            )
            && containsOrdered(
                [
                    "metadata.file_type().is_dir()",
                    "metadata.nlink() == 2",
                    "metadata.permissions().mode() & 0o7777 == 0o700",
                    "metadata.ino() == expected_inode",
                    "fs::read_dir(path)?.next().transpose()?.is_some()",
                    "let after = fs::symlink_metadata(path)?;",
                    "before.ino() != after.ino()",
                ],
                in: emptyDirectory
            )
            && [
                "opensteamer-public-vpio-probe",
                "opensteamer-v7-default-route-guardian",
                "physical-virtual-microphone-probe",
                "metadata.nlink() == 5",
                "RETAINED_FAILED_V7_PROBES_INODE",
                "if !entry.file_type()?.is_file()",
                "actual.sort_unstable();",
                "RETAINED_FAILED_V7_PUBLIC_PROBE_INODE",
                "RETAINED_FAILED_V7_GUARDIAN_INODE",
                "RETAINED_FAILED_V7_MIRROR_PROBE_INODE",
                "let after = fs::symlink_metadata(&probes)?;",
                "before.ino() != after.ino()",
            ].allSatisfy(probes.contains)
            && containsOrdered(
                [
                    "opensteamer-public-vpio-probe",
                    "opensteamer-v7-default-route-guardian",
                    "physical-virtual-microphone-probe",
                    "metadata.nlink() == 5",
                    "RETAINED_FAILED_V7_RETRY_1_PROBES_INODE",
                    "if !entry.file_type()?.is_file()",
                    "actual.sort_unstable();",
                    "RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_INODE,",
                    "0o755,",
                    "RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE,",
                    "RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256,",
                    "RETAINED_FAILED_V7_RETRY_1_GUARDIAN_INODE,",
                    "0o755,",
                    "RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE,",
                    "RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256,",
                    "RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_INODE,",
                    "0o755,",
                    "RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE,",
                    "RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256,",
                    "let after = fs::symlink_metadata(&probes)?;",
                    "before.ino() != after.ino()",
                ],
                in: retry1Probes
            )
            && containsOrdered(
                [
                    "let private_root = Path::new(PRIVATE_ROOT);",
                    "require_directory(private_root, 0o700)?;",
                    "for entry in fs::read_dir(private_root)?",
                    "name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)",
                    "name.starts_with(RETRY_1_V7_PENDING_PREFIX)",
                    "name.starts_with(RETRY_V7_PENDING_PREFIX)",
                    "let after = fs::symlink_metadata(private_root)?;",
                    "before.dev() != after.dev()",
                    "before.ino() != after.ino()",
                ],
                in: pendingScan
            )
            && [
                "D:deployment-reference", "D:failed-new", "D:probes",
                "D:production-driver-v7", "D:rollback-current", "D:source-export",
                "D:staged-output", "D:swiftpm-scratch", "F:build.stderr",
                "F:build.stdout", "F:functional-inputs.txt", "F:install-hold-name.txt",
                "F:journal.log", "F:provenance.txt", "F:result.txt", "F:source.tar",
            ].allSatisfy(topLevel.contains)
            && containsOrdered(
                [
                    "let file_type = entry.file_type()?;",
                    "if file_type.is_dir()",
                    "else if file_type.is_file()",
                    "actual.push(format!(\"{kind}:{name}\"));",
                    "actual.sort_unstable();",
                    "actual.len() != EXPECTED.len()",
                    ".ne(EXPECTED.iter().copied())",
                    "let after = fs::symlink_metadata(retained)?;",
                ],
                in: topLevel
            )
            && containsOrdered(retainedEvidenceTokens, in: retainedEvidence)
            && containsOrdered(retainedRetry1EvidenceTokens, in: retainedRetry1Evidence)
            && containsOrdered(admissionTokens, in: admission)
            && containsOrdered(
                [
                    #".strip_prefix("paired-v7-update-retry-2-")"#,
                    "suffix.as_bytes()[suffix.len() - 37] != b'-'",
                    "let nonce = &nonce_with_separator[1..];",
                    "validate_v7_nonce(nonce)?;",
                    "expected_nonce.is_some_and(|expected| expected != nonce)",
                    "let (timestamp_text, pid_text) = numeric.split_once('-')",
                    "value.to_string() != timestamp_text",
                    "value.to_string() != pid_text",
                    "let root = Path::new(V7_UPDATE_ROOT);",
                    "let expected_evidence = root.join(name);",
                    "evidence.to_str() != expected_evidence.to_str()",
                    "evidence.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)",
                    "evidence.to_str() == Some(RETAINED_FAILED_V7_ATTEMPT)",
                    "evidence.to_str() == Some(RETAINED_FAILED_V7_RETRY_1)",
                    "let data_volume_device = verified_data_volume_device()?;",
                    "let retry_metadata = fs::symlink_metadata(evidence)?;",
                    "retry_metadata.dev() != data_volume_device",
                    "retry_metadata.ino() == RETAINED_FAILED_V7_ATTEMPT_INODE",
                    "retry_metadata.ino() == RETAINED_FAILED_V7_RETRY_1_INODE",
                    "retry_metadata.nlink() < 2",
                    "require_exact_v7_root_triplet(root, name)?;",
                    "require_exact_retained_v7_evidence(data_volume_device)?;",
                    "require_exact_retained_retry_1_v7_evidence(data_volume_device)?;",
                    "require_retry_v7_pointer_expectation(evidence, pointer_expectation)?;",
                    "require_exact_v7_root_triplet(root, name)?;",
                    "let root_after = fs::symlink_metadata(root)?;",
                    "let retry_after = fs::symlink_metadata(evidence)?;",
                    "root_before.dev() != root_after.dev()",
                    "root_before.ino() != root_after.ino()",
                    "retry_metadata.dev() != retry_after.dev()",
                    "retry_metadata.ino() != retry_after.ino()",
                    "retry_metadata.nlink() != retry_after.nlink()",
                    "retry_metadata.len() != retry_after.len()",
                    "require_retry_v7_pointer_expectation(evidence, pointer_expectation)?;",
                    "require_exact_v7_root_triplet(root, name)?;",
                ],
                in: currentRetry
            )
            && containsOrdered(
                [
                    "root.to_str() != Some(V7_UPDATE_ROOT)",
                    "expected_names.is_empty()",
                    "name.is_empty() || name.contains('/')",
                    "let root_before = fs::symlink_metadata(root)?;",
                    "for entry in fs::read_dir(root)?",
                    "if !entry.file_type()?.is_dir()",
                    "actual.sort_unstable();",
                    "let mut expected: Vec<String> = expected_names",
                    "expected.windows(2).any",
                    "actual != expected",
                    "let root_after = fs::symlink_metadata(root)?;",
                    "root_before.ino() != root_after.ino()",
                ],
                in: rootNames
            )
            && containsOrdered(
                [
                    "require_exact_v7_root_names(",
                    "RETAINED_FAILED_V7_ATTEMPT_NAME,",
                    "RETAINED_FAILED_V7_RETRY_1_NAME,",
                ],
                in: retainedPair
            )
            && containsOrdered(
                [
                    "require_exact_v7_root_names(",
                    "RETAINED_FAILED_V7_ATTEMPT_NAME,",
                    "RETAINED_FAILED_V7_RETRY_1_NAME,",
                    "current_name,",
                ],
                in: rootTriplet
            )
            && containsOrdered(
                [
                    "Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),",
                    "Path::new(RETRY_1_V7_ACTIVE_UPDATE),",
                    "require_no_v7_pending_pointers()?;",
                    "RetryV7PointerExpectation::Absent",
                    "require_path_absent(Path::new(V7_ACTIVE_UPDATE),",
                    "RetryV7PointerExpectation::Present",
                    "verify_update_pointer_at(",
                    "Path::new(V7_ACTIVE_UPDATE),",
                    "evidence,",
                    "Path::new(V7_UPDATE_ROOT),",
                ],
                in: pointerExpectation
            )
            && main.components(
                separatedBy: "require_v7_retry_admission_ready()?;"
            ).count - 1 == 1
            && execute.components(
                separatedBy: "require_v7_retry_admission_ready()?;"
            ).count - 1 == 2
            && containsOrdered(
                [
                    "require_v7_retry_admission_ready()?;",
                    "let evidence = PathBuf::from(V7_UPDATE_ROOT).join(format!(",
                    "\"paired-v7-update-retry-2-{}-{}-{}\"",
                    "require_v7_retry_admission_ready()?;",
                    "create_private_directory(&evidence)?;",
                    "require_current_retry_v7_layout(",
                    "&evidence,",
                    "Some(&nonce),",
                    "RetryV7PointerExpectation::Absent,",
                ],
                in: execute
            )
            && containsOrdered(
                [
                    "let active_pointer_exists =",
                    "path_exists_without_follow(Path::new(V7_ACTIVE_UPDATE))?;",
                    "let pointer_absent_before_stop = !active_pointer_exists",
                    "matches!(journal.state, V7State::StopInitiated | V7State::RolledBack);",
                    "let crossed_stop = v7_crossed_stop_without_durable_commit(journal.state)",
                    "&& !pointer_absent_before_stop;",
                    "let rollback_pointer_expectation = if active_pointer_exists",
                    "RetryV7PointerExpectation::Present",
                    "retire_exact_retry_v7_pending_pointer_after_parent_crash(",
                    "std::process::id(),",
                    "RetryV7PointerExpectation::Absent",
                    "match rollback_to_current_baseline(",
                    "rollback_pointer_expectation,",
                    "if rollback_pointer_expectation == RetryV7PointerExpectation::Present",
                    "retire_v7_active_pointer(&layout)?;",
                    "require_current_retry_v7_layout(",
                    "RetryV7PointerExpectation::Absent,",
                ],
                in: execute
            )
            && perform.components(
                separatedBy: "require_current_retry_v7_layout("
            ).count - 1 == 5
            && containsOrdered(
                [
                    "require_current_retry_v7_layout(",
                    "let boundary_provenance = verify_paired_v7_git_provenance",
                    "require_current_retry_v7_layout(",
                    "let mut broker = RootDriverBrokerClient::start(layout)?;",
                    "journal.record(V7State::DriverPrepared, &[])?;",
                    "require_current_retry_v7_layout(",
                    "let final_generation = verify_paired_v7_runtime()?;",
                    "require_current_retry_v7_layout(",
                    "let transaction = (|| -> Result<LaunchGeneration>",
                ],
                in: perform
            )
            && containsOrdered(
                [
                    "if let Err(error) = broker.prepare_commit()",
                    "return rollback_ready_commit_failure(error, &mut broker, journal);",
                    "if let Err(error) = require_current_retry_v7_layout(",
                    "&layout.evidence,",
                    "Some(&layout.nonce),",
                    "RetryV7PointerExpectation::Present,",
                    "return rollback_ready_commit_failure(error, &mut broker, journal);",
                    "if let Err(error) = journal.record(V7State::Committed, &[])",
                ],
                in: perform
            )
            && containsOrdered(
                [
                    "expected_main_pid == 0",
                    #".strip_prefix("paired-v7-update-retry-2-")"#,
                    "suffix.as_bytes()[suffix.len() - 37] != b'-'",
                    "validate_v7_nonce(&nonce_with_separator[1..])?;",
                    "let (timestamp_text, pid_text) = numeric.split_once('-')",
                    "let pid = pid_text.parse::<u32>().ok();",
                    "let expected_path = format!(\"{V7_UPDATE_ROOT}/{name}\");",
                    "pid != Some(expected_main_pid)",
                    "pid_text != expected_main_pid.to_string()",
                    "evidence.to_str() != Some(expected_path.as_str())",
                    "evidence.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)",
                ],
                in: pendingLeafPID
            )
            && containsOrdered(
                [
                    "let expected_bytes = format!(\"{}\\n\", evidence.display());",
                    "metadata.file_type().is_file()",
                    "!metadata.file_type().is_symlink()",
                    "metadata.uid() == USER_ID",
                    "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
                    "metadata.nlink() == 1",
                    "metadata.permissions().mode() & 0o7777 == 0o600",
                    "metadata.dev() == expected_device",
                    "metadata.len() == expected_bytes.len() as u64",
                    "let named_before = fs::symlink_metadata(path)?;",
                    ".custom_flags(O_NOFOLLOW)",
                    "let descriptor_before = file.metadata()?;",
                    "Read::by_ref(&mut file)",
                    ".take(expected_bytes.len() as u64 + 1)",
                    "bytes.as_slice() != expected_bytes.as_bytes()",
                    "descriptor_before.ino() != descriptor_after.ino()",
                    "descriptor_before.ino() != named_after.ino()",
                    "Ok((file, descriptor_before))",
                ],
                in: pendingFile
            )
            && containsOrdered(
                [
                    "Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),",
                    "Path::new(RETRY_1_V7_ACTIVE_UPDATE),",
                    "require_path_absent(Path::new(V7_ACTIVE_UPDATE),",
                    "{V7_ACTIVE_UPDATE}.pending-{expected_main_pid}",
                    "let root_before = fs::symlink_metadata(private_root)?;",
                    "for entry in fs::read_dir(private_root)?",
                    "name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)",
                    "name.starts_with(RETRY_1_V7_PENDING_PREFIX)",
                    "name.starts_with(RETRY_V7_PENDING_PREFIX)",
                    "if name != pending_name || entry.path().to_str() != pending.to_str()",
                    "unexpected paired-v7 pending pointer blocks crash recovery",
                    "let root_after_scan = fs::symlink_metadata(private_root)?;",
                    #"let retired = evidence.join("retired-pending-active-pointer.txt");"#,
                    "if found_expected_pending && retired_exists",
                    "if !found_expected_pending && !retired_exists",
                    "require_no_v7_pending_pointers()?;",
                    "require_retry_v7_leaf_main_pid(evidence, expected_main_pid)?;",
                    "let data_volume_device = verified_data_volume_device()?;",
                    "open_exact_retry_v7_pending_pointer(source, evidence, data_volume_device)?;",
                    "rename_exclusive(&pending, &retired)?;",
                    "fsync_parent(&pending)?;",
                    "fsync_parent(&retired)?;",
                    "let descriptor_after = file.metadata()?;",
                    "let retired_after = fs::symlink_metadata(&retired)?;",
                    "retired_after.uid() != USER_ID",
                    "retired_after.nlink() != 1",
                    "retired_after.permissions().mode() & 0o7777 != 0o600",
                    "descriptor_before.ino() != retired_after.ino()",
                    "require_path_absent(&pending,",
                    "require_no_v7_pending_pointers()",
                ],
                in: pendingRecovery
            )
            && crashRecovery.components(
                separatedBy: "require_current_retry_v7_layout("
            ).count - 1 == 2
            && crashRecovery.components(
                separatedBy: "if pointer_expectation == RetryV7PointerExpectation::Present"
            ).count - 1 == 2
            && crashRecovery.contains("RetryV7PointerExpectation::Absent")
            && crashRecovery.contains("RetryV7PointerExpectation::Present")
            && containsOrdered(
                [
                    "let active_pointer_exists = path_exists_without_follow",
                    "let pointer_expectation = if active_pointer_exists",
                    "RetryV7PointerExpectation::Present",
                    "retire_exact_retry_v7_pending_pointer_after_parent_crash(",
                    "&layout.evidence,",
                    "expected_main_pid,",
                    "RetryV7PointerExpectation::Absent",
                    "require_current_retry_v7_layout(",
                    "pointer_expectation,",
                    "if pointer_expectation == RetryV7PointerExpectation::Present",
                    "verify_v7_active_pointer(&layout.evidence)?;",
                    "let transaction_lock = acquire_crash_recovery_transaction_lock()?;",
                    "journal.state != V7State::DriverRestored",
                    "rollback_to_current_baseline(",
                    "pointer_expectation,",
                    "write_result(",
                    "if pointer_expectation == RetryV7PointerExpectation::Present",
                    "retire_v7_active_pointer(layout)",
                    "require_current_retry_v7_layout(",
                    "RetryV7PointerExpectation::Absent,",
                ],
                in: crashRecovery
            )
            && controller.components(
                separatedBy: "uid_proxy_complete_host_crash_rollback(&layout, parent_pid)?;"
            ).count - 1 == 3
            && containsOrdered(
                [
                    "V7Command::UIDDriverRestoreProxy {",
                    "nonce,",
                    "evidence,",
                    "pointer_expectation,",
                    "parent_pid,",
                    "parent_start_sha256,",
                    "uid501_driver_restore_proxy(",
                    "&nonce,",
                    "Path::new(&evidence),",
                    "pointer_expectation,",
                    "parent_pid,",
                    "&parent_start_sha256,",
                ],
                in: main
            )
            && containsOrdered(
                [
                    "evidence: &Path,",
                    "pointer_expectation: RetryV7PointerExpectation,",
                    "if pointer_expectation == RetryV7PointerExpectation::Present",
                    "let active_evidence =",
                    "read_update_pointer_at(Path::new(V7_ACTIVE_UPDATE), Path::new(V7_UPDATE_ROOT))?;",
                    "active_evidence.to_str() != evidence.to_str()",
                    "require_current_retry_v7_layout(",
                    "evidence,",
                    "Some(nonce),",
                    "pointer_expectation,",
                    "v7_layout_from_existing(PathBuf::from(V7_EXPECTED_REPO), evidence.to_path_buf())?;",
                ],
                in: restoreLayout
            )
            && containsOrdered(
                [
                    "evidence,",
                    "pointer_expectation,",
                    "parent_pid,",
                    "RetryV7PointerExpectation::from_token(pointer_expectation)?;",
                    "evidence: evidence.clone(),",
                    "pointer_expectation,",
                ],
                in: parseCommand
            )
            && containsOrdered(
                [
                    "fn token(self) -> &'static str",
                    "Self::Absent => \"absent\"",
                    "Self::Present => \"present\"",
                    "fn from_token(token: &str) -> Result<Self>",
                    "\"absent\" => Ok(Self::Absent)",
                    "\"present\" => Ok(Self::Present)",
                ],
                in: pointerTokens
            )
            && containsOrdered(
                [
                    "evidence: &Path,",
                    "pointer_expectation: RetryV7PointerExpectation,",
                    "require_exact_broker_parent(parent_pid, parent_start_sha256)?;",
                    "existing_v7_layout_for_restore_proxy(nonce, evidence, pointer_expectation)?;",
                ],
                in: restoreProxy
            )
            && containsOrdered(
                [
                    "pointer_expectation: RetryV7PointerExpectation,",
                    "let evidence = path_text(&layout.evidence)?;",
                    "let pointer_expectation_token = pointer_expectation.token();",
                    "\"--uid501-driver-restore-proxy-v7\"",
                    "&layout.nonce,",
                    "evidence,",
                    "pointer_expectation_token,",
                    "&parent_pid_text,",
                    "&parent_start_sha256,",
                ],
                in: restoreClient
            )
            && rollback.contains(
                "read_update_pointer_at(Path::new(V7_ACTIVE_UPDATE), Path::new(V7_UPDATE_ROOT))?;"
            )
            && rollback.components(
                separatedBy: "require_current_retry_v7_layout("
            ).count - 1 == 2
            && containsOrdered(
                [
                    "read_update_pointer_at(Path::new(V7_ACTIVE_UPDATE), Path::new(V7_UPDATE_ROOT))?;",
                    "require_current_retry_v7_layout(",
                    "RetryV7PointerExpectation::Present,",
                    "let layout = v7_layout_from_existing(repo, evidence)?;",
                    "require_current_retry_v7_layout(",
                    "Some(&layout.nonce),",
                ],
                in: rollback
            )
            && rollback.contains("RetryV7PointerExpectation::Present,")
            && rollbackBaseline.components(
                separatedBy: "require_current_retry_v7_layout("
            ).count - 1 == 2
            && containsOrdered(
                [
                    "pointer_expectation: RetryV7PointerExpectation,",
                    "journal.require_healthy()?;",
                    "require_current_retry_v7_layout(",
                    "Some(&layout.nonce),",
                    "pointer_expectation,",
                    "RootExistingDriverRestoreClient::start(",
                    "layout,",
                    "pointer_expectation,",
                    "if layout.rollback_reserve.exists()",
                    "require_current_retry_v7_layout(",
                    "Some(&layout.nonce),",
                    "pointer_expectation,",
                    "bootout_paired_v7_job_if_loaded(layout)?;",
                ],
                in: rollbackBaseline
            )
            && containsOrdered(
                [
                    "require_current_retry_v7_layout(",
                    "RetryV7PointerExpectation::Absent,",
                    "format!(\"{V7_ACTIVE_UPDATE}.pending-{}\", std::process::id())",
                    #"require_path_absent(Path::new(V7_ACTIVE_UPDATE), "active paired-v7 pointer")?;"#,
                    "rename_exclusive(&pending, Path::new(V7_ACTIVE_UPDATE))?;",
                    "fsync_parent(Path::new(V7_ACTIVE_UPDATE))?;",
                    "require_current_retry_v7_layout(",
                    "RetryV7PointerExpectation::Present,",
                    "fn verify_v7_active_pointer",
                    "require_current_retry_v7_layout(",
                    "RetryV7PointerExpectation::Present,",
                    "fn retire_v7_active_pointer",
                    "let pointer_expectation = if path_exists_without_follow",
                    "require_current_retry_v7_layout(",
                    "retire_update_pointer_at(",
                    "require_current_retry_v7_layout(",
                    "&layout.evidence,",
                    "RetryV7PointerExpectation::Absent,",
                ],
                in: pointerOperations
            )
    }

    private func hasEvidencePreservingRetry2CriticalRecoveryContract(
        controller: String,
        launcher: String
    ) -> Bool {
        guard
            let recovery = try? functionBody(
                controller,
                beginningWith: "fn recover_retry_2_critical_failure(",
                endingBefore: "fn execute_paired_v7_update("
            ),
            let safeProof = try? functionBody(
                controller,
                beginningWith: "fn prove_retry_2_safe_runtime(",
                endingBefore: "fn recover_retry_2_critical_failure("
            ),
            let failureEvidence = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retry_2_failure_evidence(",
                endingBefore: "fn require_exact_retry_2_install_hold_at("
            ),
            let archive = try? functionBody(
                controller,
                beginningWith: "fn archive_exact_retry_2_install_hold(",
                endingBefore: "fn retry_2_reserve_is_released("
            ),
            let installHold = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retry_2_install_hold_at(",
                endingBefore: "fn retry_2_install_hold_is_archived("
            ),
            let reserveState = try? functionBody(
                controller,
                beginningWith: "fn retry_2_reserve_is_released(",
                endingBefore: "fn release_exact_retry_2_reserve("
            ),
            let reserveRelease = try? functionBody(
                controller,
                beginningWith: "fn release_exact_retry_2_reserve(",
                endingBefore: "fn verify_retry_2_default_route_snapshot("
            ),
            let journalContract = try? functionBody(
                controller,
                beginningWith: "fn retry_2_recovery_safe_record(",
                endingBefore: "fn require_exact_retry_2_failure_evidence("
            ),
            let safeRecord = try? functionBody(
                controller,
                beginningWith: "fn retry_2_recovery_safe_record(",
                endingBefore: "fn retry_2_recovery_transition_record("
            ),
            let rootAttest = try? functionBody(
                controller,
                beginningWith: "fn root_attest_retry_2_safe_state(",
                endingBefore: "fn require_fixed_system_binary("
            ),
            let reload = try? functionBody(
                controller,
                beginningWith: "fn reload_core_audio_root(",
                endingBefore: "fn require_exact_root_directory_identity("
            ),
            let coreAudioGeneration = try? functionBody(
                controller,
                beginningWith: "fn read_core_audio_generation_root(",
                endingBefore: "fn reload_core_audio_root("
            ),
            let coreAudioParser = try? functionBody(
                controller,
                beginningWith: "fn parse_core_audio_launch_state(",
                endingBefore: "fn require_core_audio_process("
            ),
            let coreAudioProcess = try? functionBody(
                controller,
                beginningWith: "fn require_core_audio_process(",
                endingBefore: "fn read_core_audio_generation_root("
            ),
            let restore = try? functionBody(
                controller,
                beginningWith: "fn uid_restore_proxy_restore(",
                endingBefore: "fn verify_product_endpoints_absent("
            ),
            let genericGuardian = try? functionBody(
                controller,
                beginningWith: "fn verify_product_endpoints_absent(",
                endingBefore: "fn verify_exact_retry_2_product_endpoints_absent("
            ),
            let exactGuardian = try? functionBody(
                controller,
                beginningWith: "fn verify_exact_retry_2_product_endpoints_absent(",
                endingBefore: "fn uid501_driver_restore_proxy("
            ),
            let recoveryBootstrap = try? functionBody(
                controller,
                beginningWith: "fn bootstrap_root_owned_v7_recovery_controller(",
                endingBefore: "fn attest_retry_2_root_safe_state_via_sudo("
            ),
            let recoveryPublisher = try? functionBody(
                controller,
                beginningWith: "fn publish_root_recovery_controller(",
                endingBefore: "fn bootstrap_root_recovery_controller_identity("
            ),
            let recoverySealRepair = try? functionBody(
                controller,
                beginningWith: "fn create_or_repair_root_recovery_sealed(",
                endingBefore: "fn publish_root_recovery_controller("
            ),
            let recoveryIdentityBootstrap = try? functionBody(
                controller,
                beginningWith: "fn bootstrap_root_recovery_controller_identity(",
                endingBefore: "fn verify_root_controller_identity("
            ),
            let recoveryIdentityVerify = try? functionBody(
                controller,
                beginningWith: "fn verify_root_recovery_controller_identity(",
                endingBefore: "fn require_root_private_directory("
            ),
            let pinnedSystemBinary = try? functionBody(
                controller,
                beginningWith: "fn require_pinned_system_binary(",
                endingBefore: "fn parse_core_audio_launch_state("
            ),
            let retainedV1RootFile = try? functionBody(
                controller,
                beginningWith: "fn require_exact_retained_root_recovery_v1_file(",
                endingBefore: "fn require_retained_root_recovery_v1("
            ),
            let retainedV1Root = try? functionBody(
                controller,
                beginningWith: "fn require_retained_root_recovery_v1(",
                endingBefore: "fn require_exact_root_transaction_children("
            ),
            let retainedV1SudoStat = try? functionBody(
                controller,
                beginningWith: "fn sudo_retained_root_recovery_v1_stat(",
                endingBefore: "fn require_retained_root_recovery_v1_via_sudo("
            ),
            let retainedV1Sudo = try? functionBody(
                controller,
                beginningWith: "fn require_retained_root_recovery_v1_via_sudo(",
                endingBefore: "fn read_root_controller_identity_records_via_sudo("
            ),
            let recoveryAttestViaSudo = try? functionBody(
                controller,
                beginningWith: "fn attest_retry_2_root_safe_state_via_sudo(",
                endingBefore: "fn spawn_bounded_line_reader"
            ),
            let controllerSelfTest = try? functionBody(
                controller,
                beginningWith: "fn paired_v7_self_test(",
                endingBefore: "fn self_test_controller_binary_identity_binding("
            ),
            let tornTail = try? functionBody(
                controller,
                beginningWith: "fn is_plausible_retry_2_recovery_torn_tail(",
                endingBefore: "impl Retry2RecoveryJournal"
            ),
            let cleanup = try? functionBody(
                controller,
                beginningWith: "fn root_broker_cleanup_after_failure(",
                endingBefore: "fn root_driver_broker("
            ),
            let cleanupTopology = try? functionBody(
                controller,
                beginningWith: "fn root_driver_restore_or_abandon_existing(",
                endingBefore: "fn root_driver_verify_existing_restore_ready("
            )
        else {
            return false
        }
        let exactPins = [
            #"const V7_RECOVER_RETRY_2_MODE: &str ="#,
            #""--recover-authorized-paired-v7-retry-2-critical-failure";"#,
            #""paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c";"#,
            #""f0361f4443eefae656aa2e5e75ed5a4d4a80df521d56403bcc386f00556cfa3f";"#,
            #""10578545d58874d94e821cc23657838b62428522be6f32d7b7b23bd926a3e2ba";"#,
            #""55c9dc33d4e7d368f775013c73045eee70a142d8bf30e2faafa7d5e4276e8474";"#,
            #""31d2d750db685c631b95958c1a26a77a49fcb20f9781a5554bfb61f5d634d964";"#,
            #""2daeb1f36095b44b318410b3f4e8b5d989dcc7bb023d1426c492dab0a3053e74";"#,
            #""f6bbd6e37f9c2df0a54b86ff3e631e3d14b1931e16574cf952653585f31b3977";"#,
            "const ROOT_V7_RECOVERY_SUPPORT_DIRECTORY: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2\";",
            #"const ROOT_V7_RECOVERY_CONTROLLER: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/opensteamer-v7-recovery-controller";"#,
            #"const ROOT_V7_RECOVERY_CONTROLLER_PENDING: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/.opensteamer-v7-recovery-controller.pending";"#,
            #"const ROOT_V7_RECOVERY_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/controller-binary.sha256";"#,
            #"const ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/controller-identity.log";"#,
            #""--root-bootstrap-controller-identity-v7-recovery-retry-2-v2""#,
            #""--root-publish-controller-v7-recovery-retry-2-v2""#,
            #""--root-attest-v7-retry-2-safe-state-v2""#,
            #""OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V2""#,
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_DIRECTORY: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2\";",
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/opensteamer-v7-recovery-controller";"#,
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PENDING: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/.opensteamer-v7-recovery-controller.pending";"#,
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/controller-binary.sha256";"#,
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_IDENTITY_JOURNAL: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/controller-identity.log";"#,
            "const RETAINED_ROOT_V7_RECOVERY_V1_DEVICE: u64 = 16_777_229;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE: u64 = 27_803_148;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_INODE: u64 = 27_803_149;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_LENGTH: u64 = 1_420_216;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_SHA256: &str =\n        \"b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317\";",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN_INODE: u64 = 27_803_150;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN_LENGTH: u64 = 65;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN_SHA256: &str =\n        \"030450c1027f4e0d36fabf66471248e4ef9690e1b30d2d3961db4f1cae0ffdd6\";",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN: &str =\n        \"b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317\\n\";",
            "const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_INODE: u64 = 27_803_151;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_LENGTH: u64 = 332;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_SHA256: &str =\n        \"41c5042ed37c13692cb4d11fc8e039d0008d8038b7240175920b0338701737a7\";",
            #"const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL: &str = "OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V1\ncontroller_path=/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/opensteamer-v7-recovery-controller\ncontroller_device=16777229\ncontroller_inode=27803149\ncontroller_length=1420216\ncontroller_sha256=b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317\n";"#,
            "const EXPECTED_LS_SHA256: &str =\n        \"a97c50d34f912a5ada66959c231897ec2144e3c9cb922cd8150e4f2b0c9470e7\";",
            "const RECOVERY_RETRY_2_ROOT_TRANSACTION_INODE: u64 = 27_777_176;",
            "const RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE: u64 = 27_777_177;",
            "const RECOVERY_RETRY_2_ROOT_PACKAGE_INODE: u64 = 27_777_188;",
            "const RECOVERY_RETRY_2_ROOT_STATE_INODE: u64 = 27_777_224;",
            "const RECOVERY_RETRY_2_EVIDENCE_INODE: u64 = 27_770_302;",
            "const RECOVERY_RETRY_2_POINTER_INODE: u64 = 27_777_557;",
            "const RECOVERY_RETRY_2_JOURNAL_INODE: u64 = 27_770_306;",
            "const RECOVERY_RETRY_2_RESULT_INODE: u64 = 27_777_807;",
            "const RECOVERY_RETRY_2_PROVENANCE_INODE: u64 = 27_770_734;",
            "const RECOVERY_RETRY_2_DRIVER_RECORD_INODE: u64 = 27_777_174;",
            "const RECOVERY_RETRY_2_RESERVE_INODE: u64 = 27_777_546;",
            "const RECOVERY_RETRY_2_RESERVE_SIZE: u64 = 8_388_608;",
            "const RECOVERY_RETRY_2_GUARDIAN_INODE: u64 = 27_776_710;",
            "const RECOVERY_RETRY_2_GUARDIAN_SIZE: u64 = 286_968;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_INODE: u64 = 27_776_737;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_APP_INODE: u64 = 27_776_738;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_INODE: u64 = 27_776_743;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_SIZE: u64 = 6_090_624;",
            "const RECOVERY_RETRY_2_V6_APP_INODE: u64 = 25_795_490;",
            "const RECOVERY_RETRY_2_V6_EXECUTABLE_INODE: u64 = 25_795_495;",
            "const RECOVERY_RETRY_2_SYSTEM_PROFILER_SIZE: u64 = 1_148;",
            "const RECOVERY_RETRY_2_COREAUDIO_OLD_PID: u32 = 180;",
            "const RECOVERY_RETRY_2_COREAUDIO_OLD_RUNS: u64 = 1;",
            "const RECOVERY_RETRY_2_COREAUDIO_PID: u32 = 6_355;",
            "const RECOVERY_RETRY_2_COREAUDIO_RUNS: u64 = 2;",
            "const RECOVERY_RETRY_2_V6_PID: u32 = 7_631;",
            "const RECOVERY_RETRY_2_V6_RUNS: u64 = 1;",
        ]
        let recoveryOrder = [
            "let _transaction_lock = acquire_update_transaction_lock_at(Path::new(V7_UPDATE_LOCK))?;",
            "require_descriptor_close_on_exec(\n            &_transaction_lock.file,\n            \"retry-2 recovery transaction lock\",\n        )?;",
            "let initial_pointer_expectation =",
            "path_exists_without_follow(Path::new(V7_ACTIVE_UPDATE))?",
            "require_exact_retry_2_failure_evidence(",
            "verify_retry_2_recovered_v6_generation()?;",
            "authenticate_v7_privileged_boundary()?;",
            "bootstrap_root_owned_v7_recovery_controller()?;",
            "prove_retry_2_safe_runtime(&initial_layout)?;",
            "let recovery_journal_exists = path_exists_without_follow(recovery_journal_path)?;",
            "retry_2_install_hold_is_archived(&initial_layout)?",
            "retry_2_reserve_is_released(&initial_layout)?",
            "Retry2RecoveryJournal::create(",
            "initial_pointer_expectation == RetryV7PointerExpectation::Absent",
            "recovery_journal.state != Retry2RecoveryState::RecoveredV6",
            "archive_exact_retry_2_install_hold(&layout)?;",
            "recovery_journal.record(Retry2RecoveryState::InstallHoldArchived)?;",
            "retry_2_reserve_is_released(&layout)?",
            "release_exact_retry_2_reserve(&layout)?;",
            "retry_2_reserve_is_released(&layout)?",
            "recovery_journal.record(Retry2RecoveryState::ReserveReleased)?;",
            "prove_retry_2_safe_runtime(&layout)?;",
            "recovery_journal.record(Retry2RecoveryState::RecoveredV6)?;",
            "retire_update_pointer_at(",
            "RetryV7PointerExpectation::Absent,",
            "Retry2RecoveryJournal::open(",
            "prove_retry_2_safe_runtime(&final_layout)?;",
        ]
        let failureEvidenceTokens = [
            "let data_volume_device = verified_data_volume_device()?;",
            "&evidence.join(\"journal.log\"),\n            data_volume_device,\n            RECOVERY_RETRY_2_JOURNAL_INODE,\n            RECOVERY_RETRY_2_JOURNAL,\n            RECOVERY_RETRY_2_JOURNAL_SHA256,",
            "&evidence.join(\"result.txt\"),\n            data_volume_device,\n            RECOVERY_RETRY_2_RESULT_INODE,\n            RECOVERY_RETRY_2_RESULT,\n            RECOVERY_RETRY_2_RESULT_SHA256,",
            "&evidence.join(\"provenance.txt\"),\n            data_volume_device,\n            RECOVERY_RETRY_2_PROVENANCE_INODE,\n            RECOVERY_RETRY_2_PROVENANCE,\n            RECOVERY_RETRY_2_PROVENANCE_SHA256,",
            "&evidence.join(\"driver-transaction-record.txt\"),\n            data_volume_device,\n            RECOVERY_RETRY_2_DRIVER_RECORD_INODE,\n            RECOVERY_RETRY_2_DRIVER_RECORD,\n            RECOVERY_RETRY_2_DRIVER_RECORD_SHA256,",
        ]
        let archiveOrder = [
            "require_no_openers_user(source)?;",
            ".custom_flags(O_NOFOLLOW)",
            ".open(source)?;",
            "let before = descriptor.metadata()?;",
            "let data_volume_device = verified_data_volume_device()?;",
            "before.dev() != data_volume_device",
            "require_path_absent(archive,",
            "rename_exclusive(source, archive)?;",
            "fsync_parent(source)?;",
            "fsync_parent(archive)?;",
            "let after = descriptor.metadata()?;",
            "let named = fs::symlink_metadata(archive)?;",
            "before.ino() != named.ino()",
            "require_path_absent(source,",
        ]
        let installHoldTokens = [
            "let data_volume_device = verified_data_volume_device()?;",
            "root.dev() != data_volume_device",
            "app_metadata.dev() != data_volume_device",
            "executable_metadata.dev() != data_volume_device",
            "RECOVERY_RETRY_2_INSTALL_HOLD_INODE",
            "RECOVERY_RETRY_2_INSTALL_HOLD_APP_INODE",
            "RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_INODE",
            "RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_SHA256",
        ]
        let rootTokens = [
            "require_retained_root_recovery_v1()?;",
            "verify_root_recovery_controller_identity()?;",
            "let data_volume_device = verified_data_volume_device()?;",
            "old_controller.sha256 != RECOVERY_RETRY_2_ROOT_CONTROLLER_SHA256",
            "require_root_controller_identity_binding(&old_controller, &old_sealed)?;",
            "transaction,\n            data_volume_device,",
            "require_exact_root_transaction_children(transaction)?;",
            "require_path_absent(",
            "Path::new(PRODUCT_DRIVER_CANONICAL_PATH)",
            "failed.dev() != data_volume_device",
            "verify_root_production_driver(&layout.failed)?;",
            "hold.inode != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE",
            "require_exact_root_regular_identity(",
            "RECOVERY_RETRY_2_ROOT_STATE_SHA256,",
            "verify_root_production_package(&layout.package)?;",
            "require_no_extended_attributes_root(transaction)?;",
            "require_no_openers_root(transaction)?;",
            "read_core_audio_generation_root()?;",
            "require_retained_root_recovery_v1()?;",
        ]
        let pinnedSystemBinaryTokens = [
            "expected_mode: u32,",
            "if !matches!(expected_mode, 0o755 | 0o4755)",
            "require_fixed_system_binary(path, expected_mode & 0o777)?;",
            ".custom_flags(O_NOFOLLOW)",
            "metadata.permissions().mode() & 0o7777 == expected_mode",
            "!metadata_is_exact(&descriptor_before)",
            "!metadata_is_exact(&named_before)",
            "sha256_bytes(&bytes)? != expected_sha256",
            "!metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&named_after)",
        ]
        let retainedV1RootFileTokens = [
            ".custom_flags(O_NOFOLLOW)",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == expected_mode",
            "metadata.dev() == RETAINED_ROOT_V7_RECOVERY_V1_DEVICE",
            "metadata.ino() == expected_inode",
            "metadata.len() == expected_length",
            "metadata.st_flags() == 0",
            "!metadata_is_exact(&before)",
            "!metadata_is_exact(&named_before)",
            ".take(expected_length + 1)",
            "sha256_bytes(&bytes)? != expected_sha256",
            "if let Some(expected_bytes) = expected_bytes",
            "if bytes != expected_bytes",
            "!metadata_is_exact(&after)",
            "!metadata_is_exact(&named_after)",
        ]
        let retainedV1RootTokens = [
            "unsafe { geteuid() } != 0",
            "Path::new(child).parent() != Some(support)",
            "metadata.nlink() != RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK",
            "metadata.permissions().mode() & 0o7777 != 0o700",
            "metadata.dev() != RETAINED_ROOT_V7_RECOVERY_V1_DEVICE",
            "metadata.ino() != RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE",
            "metadata.len() != RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_LENGTH",
            "metadata.st_flags() != 0",
            "names.sort_unstable();",
            "if names\n                != [",
            #""controller-binary.sha256".to_owned()"#,
            #""controller-identity.log".to_owned()"#,
            #""opensteamer-v7-recovery-controller".to_owned()"#,
            "let before = read_support()?;",
            "let children_before = read_children()?;",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PENDING",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_INODE,",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_SHA256,",
            "RETAINED_ROOT_V7_RECOVERY_V1_PIN_INODE,",
            "RETAINED_ROOT_V7_RECOVERY_V1_PIN_SHA256,",
            "Some(RETAINED_ROOT_V7_RECOVERY_V1_PIN.as_bytes()),",
            "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_INODE,",
            "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_SHA256,",
            "Some(RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL.as_bytes()),",
            "let children_after = read_children()?;",
            "let after = read_support()?;",
            "children_before != children_after",
        ]
        let retainedV1SudoStatTokens = [
            #""%u:%g:%l:%Mp%Lp:%HT:%d:%i:%z:%f""#,
            "require_output_success(&output,",
            "if !output.stderr.is_empty()",
            ".strip_suffix('\\n')",
            ".filter(|line| !line.is_empty() && !line.contains('\\n'))",
        ]
        let retainedV1SudoTokens = [
            #"require_pinned_system_binary(Path::new("/bin/ls"), 0o755, EXPECTED_LS_SHA256)?;"#,
            "let support = Path::new(RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_DIRECTORY);",
            #""0:0:{}:0700:Directory:{}:{}:{}:0""#,
            #""0:0:1:0500:Regular File:{}:{}:{}:0""#,
            #""0:0:1:0400:Regular File:{}:{}:{}:0""#,
            "if sudo_stat(pending)?.is_some()",
            #""/bin/ls""#,
            #""-1A""#,
            #"b"controller-binary.sha256\ncontroller-identity.log\nopensteamer-v7-recovery-controller\n""#,
            "sudo_retained_root_recovery_v1_stat(support)?",
            "sudo_retained_root_recovery_v1_stat(controller)?",
            "sudo_retained_root_recovery_v1_stat(pin)?",
            "sudo_retained_root_recovery_v1_stat(journal)?",
            "let before = read_topology()?;",
            "expected_support.clone(),",
            "expected_controller.clone(),",
            "expected_pin.clone(),",
            "expected_journal.clone(),",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_SHA256",
            "pin_bytes != RETAINED_ROOT_V7_RECOVERY_V1_PIN",
            "RETAINED_ROOT_V7_RECOVERY_V1_PIN_SHA256",
            "journal_bytes != RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL",
            "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_SHA256",
            "let after = read_topology()?;",
            "if after != before",
        ]
        let controllerModeSelfTestTokens = [
            #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)?;"#,
            #"require_pinned_system_binary(Path::new("/bin/ps"), 0o755, EXPECTED_PS_SHA256).is_ok()"#,
            "Path::new(\"/bin/launchctl\"),\n            0o755,\n            EXPECTED_LAUNCHCTL_SHA256,",
            "Path::new(\"/bin/launchctl\"),\n            0o4755,\n            EXPECTED_LAUNCHCTL_SHA256,",
        ]
        let coreaudiodPinnedCall = "require_pinned_system_binary(\n            Path::new(PINNED_COREAUDIOD),\n            0o755,\n            EXPECTED_COREAUDIOD_SHA256,\n        )?;"
        let launchctlPinnedCall = "require_pinned_system_binary(\n            Path::new(\"/bin/launchctl\"),\n            0o755,\n            EXPECTED_LAUNCHCTL_SHA256,\n        )?;"
        let launchctlWrongModeSelfTestCall = "require_pinned_system_binary(\n            Path::new(\"/bin/launchctl\"),\n            0o4755,\n            EXPECTED_LAUNCHCTL_SHA256,\n        )"
        let psPinnedCall = #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)"#
        let psWrongModeSelfTestCall = #"require_pinned_system_binary(Path::new("/bin/ps"), 0o755, EXPECTED_PS_SHA256)"#
        let lsofPinnedCall = "require_pinned_system_binary(\n            Path::new(\"/usr/sbin/lsof\"),\n            0o755,\n            EXPECTED_LSOF_SHA256,\n        )?;"
        let xattrPinnedCall = "require_pinned_system_binary(\n            Path::new(\"/usr/bin/xattr\"),\n            0o755,\n            EXPECTED_XATTR_SHA256,\n        )?;"
        let systemProfilerPinnedCall = "require_pinned_system_binary(\n            Path::new(\"/usr/sbin/system_profiler\"),\n            0o755,\n            EXPECTED_SYSTEM_PROFILER_SHA256,\n        )?;"
        let reloadTokens = [
            #"require_pinned_system_binary(Path::new("/bin/kill"), 0o755, EXPECTED_KILL_SHA256)?;"#,
            "let before = read_core_audio_generation_root()?;",
            "let pid = before.pid.to_string();",
            #"command_output("/bin/kill", &["-TERM", &pid], None)?;"#,
            "let expected_runs = before.runs.checked_add(1)",
            "after.pid != before.pid && after.runs == expected_runs",
        ]
        let coreAudioGenerationTokens = [
            "Path::new(PINNED_COREAUDIOD),\n            0o755,\n            EXPECTED_COREAUDIOD_SHA256,",
            "Path::new(\"/bin/launchctl\"),\n            0o755,\n            EXPECTED_LAUNCHCTL_SHA256,",
            #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)?;"#,
            #"&["print", "system/com.apple.audio.coreaudiod"]"#,
            "parse_core_audio_launch_state(",
            "require_core_audio_process(generation)?;",
            "let first = read()?;",
            "let second = read()?;",
            "if first != second",
        ]
        let coreAudioParserTokens = [
            #"Some("system/com.apple.audio.coreaudiod = {")"#,
            "if depth == 0",
            #"line.strip_prefix("state = ")"#,
            #"set_once(&mut state, value, "coreaudiod state")?;"#,
            #"line.strip_prefix("program = ")"#,
            #"line.strip_prefix("domain = ")"#,
            #"line.strip_prefix("username = ")"#,
            #"line.strip_prefix("group = ")"#,
            #"line.strip_prefix("runs = ")"#,
            "if runs.replace(value).is_some()",
            #"line.strip_prefix("pid = ")"#,
            ".filter(|value| *value > 0)",
            "if pid.replace(value).is_some()",
            #"state.as_deref() != Some("running")"#,
            "program.as_deref() != Some(PINNED_COREAUDIOD)",
            #"domain.as_deref() != Some("system")"#,
            #"username.as_deref() != Some("_coreaudiod")"#,
            #"group.as_deref() != Some("_coreaudiod")"#,
            "runs: runs",
            ".filter(|value| *value > 0)",
        ]
        let coreAudioProcessTokens = [
            "let pid = generation.pid.to_string();",
            "let output = command_output(",
            #""/bin/ps","#,
            #""-p","#,
            "&pid,",
            #""ppid=""#,
            #""uid=""#,
            #""gid=""#,
            #""comm=""#,
            "require_output_success(&output,",
            "if !output.stderr.is_empty()",
            "if records.len() != 1",
            "pid.as_str(),",
            #""1","#,
            #""202","#,
            "PINNED_COREAUDIOD,",
        ]
        let reserveStateTokens = [
            "let data_volume_device = verified_data_volume_device()?;",
            ".custom_flags(O_NOFOLLOW)",
            "before.dev() != data_volume_device",
            "before.ino() != RECOVERY_RETRY_2_RESERVE_INODE",
            "before.len() == RECOVERY_RETRY_2_RESERVE_SIZE",
            "let allocated_bytes = before.blocks().checked_mul(512)",
            "allocated_bytes < RECOVERY_RETRY_2_RESERVE_SIZE",
            "RECOVERY_RETRY_2_RESERVE_SHA256,",
            "before.blocks() != after.blocks()",
            "before.len() != 0",
            "before.blocks() != 0",
            "read != 0",
            "Ok(true)",
        ]
        let reserveReleaseTokens = [
            "retry_2_reserve_is_released(layout)?",
            "let data_volume_device = verified_data_volume_device()?;",
            ".write(true)",
            ".custom_flags(O_NOFOLLOW)",
            "before.dev() != data_volume_device",
            "before.ino() != RECOVERY_RETRY_2_RESERVE_INODE",
            "before.blocks().checked_mul(512)",
            "sha256_bytes(&bytes)? != RECOVERY_RETRY_2_RESERVE_SHA256",
            "descriptor.set_len(0)?;",
            "descriptor.sync_all()?;",
            "after.blocks() != 0",
            "retry_2_reserve_is_released(layout)?",
        ]
        let journalTokens = [
            "evidence_inode={}",
            "provenance_inode={}",
            "reserve_inode={}",
            "reserve_allocated_bytes_at_least={}",
            "allocated_bytes_before_at_least={}",
            "guardian_inode={}",
            "install_hold_inode={}",
            "root_transaction_inode={}",
            "root_failed_tree_sha256={}",
            "root_package_sha256={}",
            "v6_app_inode={}",
            "v6_executable_sha256={}",
            "initial.as_bytes().starts_with(&bytes)",
            "file.set_len(0)?;",
            "file.write_all(initial.as_bytes())?;",
            "is_plausible_retry_2_recovery_torn_tail(tail, state)",
            "file.set_len(complete_length as u64)?;",
        ]
        let journalDurabilityOrder = [
            "file.write_all(text.as_bytes())?;",
            "file.sync_all()?;",
            "fsync_parent(path)?;",
            "file.set_len(0)?;",
            "file.seek(SeekFrom::Start(0))?;",
            "file.write_all(initial.as_bytes())?;",
            "file.sync_all()?;",
            "fsync_parent(path)?;",
            "file.set_len(complete_length as u64)?;",
            "file.sync_all()?;",
            ".write_all(record.as_bytes())",
            ".and_then(|_| self.file.sync_all())",
            "self.file.set_len(prior_length)?;\n                self.file.sync_all()?;",
            "self.file.sync_all()?;",
        ]
        let tornTailTokens = [
            "tail.is_empty()",
            "tail.contains(&b'\\n')",
            "tail.contains(&b'\\r')",
            "retry_2_recovery_transition_record(state)",
            ".map(|(_, next)| next.as_bytes().starts_with(tail))",
            ".unwrap_or(false)",
        ]
        let safeRecordPins = [
            "RECOVERY_RETRY_2_EVIDENCE_INODE,",
            "RECOVERY_RETRY_2_POINTER_INODE,",
            "RECOVERY_RETRY_2_POINTER_SHA256,",
            "RECOVERY_RETRY_2_JOURNAL_INODE,",
            "RECOVERY_RETRY_2_JOURNAL_SHA256,",
            "RECOVERY_RETRY_2_RESULT_INODE,",
            "RECOVERY_RETRY_2_RESULT_SHA256,",
            "RECOVERY_RETRY_2_PROVENANCE_INODE,",
            "RECOVERY_RETRY_2_PROVENANCE_SHA256,",
            "RECOVERY_RETRY_2_DRIVER_RECORD_INODE,",
            "RECOVERY_RETRY_2_DRIVER_RECORD_SHA256,",
            "RECOVERY_RETRY_2_RESERVE_INODE,",
            "RECOVERY_RETRY_2_RESERVE_SIZE,",
            "RECOVERY_RETRY_2_RESERVE_SIZE,",
            "RECOVERY_RETRY_2_RESERVE_SHA256,",
            "RECOVERY_RETRY_2_GUARDIAN_INODE,",
            "RECOVERY_RETRY_2_GUARDIAN_SIZE,",
            "EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256,",
            "RECOVERY_RETRY_2_INSTALL_HOLD_INODE,",
            "RECOVERY_RETRY_2_INSTALL_HOLD_APP_INODE,",
            "RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_INODE,",
            "RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_SIZE,",
            "RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_SHA256,",
            "RECOVERY_RETRY_2_ROOT_CONTROLLER_SHA256,",
            "RECOVERY_RETRY_2_ROOT_TRANSACTION_INODE,",
            "RECOVERY_RETRY_2_ROOT_STATE_INODE,",
            "RECOVERY_RETRY_2_ROOT_STATE_SHA256,",
            "RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE,",
            "EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,",
            "EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,",
            "RECOVERY_RETRY_2_ROOT_PACKAGE_INODE,",
            "EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,",
            "RECOVERY_RETRY_2_COREAUDIO_OLD_PID,",
            "RECOVERY_RETRY_2_COREAUDIO_OLD_RUNS,",
            "RECOVERY_RETRY_2_COREAUDIO_PID,",
            "RECOVERY_RETRY_2_COREAUDIO_RUNS,",
            "RECOVERY_RETRY_2_SYSTEM_PROFILER_SIZE,",
            "RECOVERY_RETRY_2_SYSTEM_PROFILER_SHA256,",
            "RECOVERY_RETRY_2_V6_PID,",
            "RECOVERY_RETRY_2_V6_RUNS,",
            "RECOVERY_RETRY_2_V6_NONCE,",
            "RECOVERY_RETRY_2_V6_APP_INODE,",
            "RECOVERY_RETRY_2_V6_EXECUTABLE_INODE,",
            "CURRENT_BASELINE_EXECUTABLE_SHA256,",
        ]
        let exactGuardianTokens = [
            "RECOVERY_RETRY_2_EVIDENCE",
            "let data_volume_device = verified_data_volume_device()?;",
            ".custom_flags(O_NOFOLLOW)",
            "before.ino() != RECOVERY_RETRY_2_GUARDIAN_INODE",
            "before.len() != RECOVERY_RETRY_2_GUARDIAN_SIZE",
            "sha256_bytes(&bytes)? != EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256",
            "verify_product_endpoints_absent(layout)?;",
            "before.ino() != named_after.ino()",
        ]
        let genericGuardianTokens = [
            "require_regular(&layout.default_route_guardian, 0o755)?;",
            "EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256",
            ".arg(\"verify-product-absent\")",
            ".env_clear()",
            #".env("LC_ALL", "C")"#,
            "require_output_success(&output,",
            "PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE",
        ]
        let recoveryPublishTokens = [
            "env::current_exe()? != Path::new(ROOT_V7_RECOVERY_CONTROLLER_PENDING)",
            "require_retained_root_recovery_v1()?;",
            "descriptor.sync_all()?;",
            "require_path_absent(",
            "rename_exclusive(",
            "ROOT_V7_RECOVERY_CONTROLLER_PENDING",
            "ROOT_V7_RECOVERY_CONTROLLER",
            "fsync_parent(Path::new(ROOT_V7_RECOVERY_CONTROLLER))?;",
            "pending != published",
            "require_retained_root_recovery_v1()?;",
            #"println!("ROOT_V7_RECOVERY_CONTROLLER_V2_PUBLISHED");"#,
        ]
        let recoveryBootstrapTokens = [
            "require_retained_root_recovery_v1_via_sudo()?;",
            "sudo_stat(Path::new(ROOT_V7_RECOVERY_CONTROLLER))?",
            "sudo_stat(Path::new(ROOT_V7_RECOVERY_CONTROLLER_PENDING))?",
            "ROOT_V7_RECOVERY_CONTROLLER_PENDING,",
            "ROOT_V7_RECOVERY_CONTROLLER_PUBLISH_MODE,",
            "ROOT_V7_RECOVERY_CONTROLLER_V2_PUBLISHED",
            "ROOT_V7_RECOVERY_CONTROLLER,\n            ROOT_V7_RECOVERY_CONTROLLER_BOOTSTRAP_MODE,",
            "ROOT_V7_RECOVERY_CONTROLLER_V2_IDENTITY_SEALED",
            "require_retained_root_recovery_v1_via_sudo()?;",
        ]
        let recoverySealTokens = [
            "!matches!(metadata.permissions().mode() & 0o7777, 0o400 | 0o600)",
            "expected.as_bytes().starts_with(&bytes)",
            "file.set_len(0)?;",
            "file.write_all(expected.as_bytes())?;",
            "file.set_permissions(fs::Permissions::from_mode(0o400))?;",
            "file.sync_all()?;",
            "fsync_parent(path)?;",
        ]
        let recoveryIdentityBootstrapTokens = [
            "env::current_exe()? != Path::new(ROOT_V7_RECOVERY_CONTROLLER)",
            "require_retained_root_recovery_v1()?;",
            "require_root_private_directory(Path::new(ROOT_V7_RECOVERY_SUPPORT_DIRECTORY))?;",
            "create_or_repair_root_recovery_sealed(\n            Path::new(ROOT_V7_RECOVERY_CONTROLLER_PIN)",
            "create_or_repair_root_recovery_sealed(\n            Path::new(ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL)",
            "let sealed = read_root_controller_identity_records_at(\n            Path::new(ROOT_V7_RECOVERY_CONTROLLER_PIN)",
            "Path::new(ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL)",
            "ROOT_V7_RECOVERY_CONTROLLER,",
            #""OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V2""#,
            "require_root_controller_identity_binding(&identity, &sealed)?;",
            "require_retained_root_recovery_v1()?;",
            #"println!("ROOT_V7_RECOVERY_CONTROLLER_V2_IDENTITY_SEALED");"#,
        ]
        let recoveryIdentityVerifyTokens = [
            "executable != Path::new(ROOT_V7_RECOVERY_CONTROLLER)",
            "Path::new(ROOT_V7_RECOVERY_CONTROLLER_PIN)",
            "Path::new(ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL)",
            "ROOT_V7_RECOVERY_CONTROLLER,",
            #""OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V2""#,
            "require_root_controller_identity_binding(&actual, &sealed)?;",
        ]
        let recoveryAttestViaSudoTokens = [
            "require_retained_root_recovery_v1_via_sudo()?;",
            "ROOT_V7_RECOVERY_CONTROLLER,",
            "ROOT_V7_RECOVERY_ATTEST_MODE,",
            "require_output_success(&output,",
            "if output.stdout != expected.as_bytes() || !output.stderr.is_empty()",
            "require_retained_root_recovery_v1_via_sudo()?;",
        ]
        let cleanupTopologyTokens = [
            "if canonical == prior && held_is_hold {",
            "return root_driver_abandon_prepare(nonce);",
            "if canonical == prior && abandoned_is_hold {",
            "verify_root_production_driver(&layout.abandoned)?;",
            "root_driver_rollback_reload(nonce)",
        ]
        return exactPins.allSatisfy(controller.contains)
            && containsOrdered(recoveryOrder, in: recovery)
            && failureEvidenceTokens.allSatisfy(failureEvidence.contains)
            && containsOrdered(archiveOrder, in: archive)
            && installHoldTokens.allSatisfy(installHold.contains)
            && containsOrdered(reserveStateTokens, in: reserveState)
            && containsOrdered(reserveReleaseTokens, in: reserveRelease)
            && journalTokens.allSatisfy(journalContract.contains)
            && containsOrdered(journalDurabilityOrder, in: journalContract)
            && containsOrdered(tornTailTokens, in: tornTail)
            && containsOrdered(safeRecordPins, in: safeRecord)
            && containsOrdered(rootTokens, in: rootAttest)
            && containsOrdered(pinnedSystemBinaryTokens, in: pinnedSystemBinary)
            && containsOrdered(retainedV1RootFileTokens, in: retainedV1RootFile)
            && containsOrdered(retainedV1RootTokens, in: retainedV1Root)
            && containsOrdered(retainedV1SudoStatTokens, in: retainedV1SudoStat)
            && containsOrdered(retainedV1SudoTokens, in: retainedV1Sudo)
            && containsOrdered(controllerModeSelfTestTokens, in: controllerSelfTest)
            && controller.components(separatedBy: "require_pinned_system_binary(").count - 1 == 14
            && controller.components(separatedBy: coreaudiodPinnedCall).count - 1 == 1
            && controller.components(separatedBy: launchctlPinnedCall).count - 1 == 2
            && controller.components(separatedBy: launchctlWrongModeSelfTestCall).count - 1 == 1
            && controller.components(separatedBy: psPinnedCall).count - 1 == 2
            && controller.components(separatedBy: psWrongModeSelfTestCall).count - 1 == 1
            && controller.components(separatedBy: lsofPinnedCall).count - 1 == 2
            && controller.components(separatedBy: xattrPinnedCall).count - 1 == 1
            && controller.components(separatedBy: systemProfilerPinnedCall).count - 1 == 1
            && controller.components(
                separatedBy: #"require_pinned_system_binary(Path::new("/bin/kill"), 0o755, EXPECTED_KILL_SHA256)?;"#
            ).count - 1 == 1
            && controller.components(
                separatedBy: #"require_pinned_system_binary(Path::new("/bin/ls"), 0o755, EXPECTED_LS_SHA256)?;"#
            ).count - 1 == 1
            && containsOrdered(reloadTokens, in: reload)
            && containsOrdered(coreAudioGenerationTokens, in: coreAudioGeneration)
            && containsOrdered(coreAudioParserTokens, in: coreAudioParser)
            && containsOrdered(coreAudioProcessTokens, in: coreAudioProcess)
            && containsOrdered(genericGuardianTokens, in: genericGuardian)
            && !genericGuardian.contains("RECOVERY_RETRY_2_")
            && !genericGuardian.contains("paired-host-updates-v7")
            && containsOrdered(exactGuardianTokens, in: exactGuardian)
            && containsOrdered(recoveryPublishTokens, in: recoveryPublisher)
            && containsOrdered(recoveryBootstrapTokens, in: recoveryBootstrap)
            && containsOrdered(recoverySealTokens, in: recoverySealRepair)
            && containsOrdered(recoveryIdentityBootstrapTokens, in: recoveryIdentityBootstrap)
            && containsOrdered(recoveryIdentityVerifyTokens, in: recoveryIdentityVerify)
            && containsOrdered(recoveryAttestViaSudoTokens, in: recoveryAttestViaSudo)
            && containsOrdered(cleanupTopologyTokens, in: cleanupTopology)
            && containsOrdered(
                [
                    "attest_retry_2_root_safe_state_via_sudo()?;",
                    "verify_exact_retry_2_product_endpoints_absent(layout)?;",
                    "verify_retry_2_default_route_snapshot()?;",
                    "verify_retry_2_recovered_v6_generation()?;",
                    "verify_exact_retry_2_product_endpoints_absent(layout)?;",
                    "verify_retry_2_recovered_v6_generation()?;",
                    "attest_retry_2_root_safe_state_via_sudo()?;",
                ],
                in: safeProof
            )
            && restore.contains("verify_product_endpoints_absent(layout)?;")
            && cleanup.contains("root_driver_restore_or_abandon_existing(nonce)")
            && !cleanup.contains("if published")
            && !reload.contains("kickstart")
            && !reload.contains("launchctl\", &[\"kill")
            && !reload.contains("killall")
            && !recovery.contains("bootout_")
            && !recovery.contains("bootstrap_exact_new_job")
            && !recovery.contains("write_result(")
            && !recovery.contains("journal.log\"")
            && launcher.contains("RECOVER_RETRY_2_MODE='--recover-authorized-paired-v7-retry-2-critical-failure'")
            && launcher.contains(#""$EXECUTE_MODE"|"$RECOVER_RETRY_2_MODE")"#)
    }

    private func hasRetry3TerminalNamespaceContract(_ controller: String) -> Bool {
        guard
            let pending = try? functionBody(
                controller,
                beginningWith: "    fn require_no_v7_pending_pointers()",
                endingBefore: "    fn require_exact_retained_v7_top_level"
            ),
            let topLevel = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retry_2_post_recovery_top_level",
                endingBefore: "    fn require_exact_terminal_retry_2_recovery_journal"
            ),
            let terminalJournal = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_terminal_retry_2_recovery_journal",
                endingBefore: "    fn require_exact_recovered_retry_2_probes"
            ),
            let probes = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_recovered_retry_2_probes",
                endingBefore: "    fn require_exact_recovered_retry_2_evidence"
            ),
            let recovered = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_recovered_retry_2_evidence",
                endingBefore: "    fn require_v7_retry_admission_ready"
            ),
            let admission = try? functionBody(
                controller,
                beginningWith: "    fn require_v7_retry_admission_ready",
                endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]"
            ),
            let triplet = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_v7_retained_triplet",
                endingBefore: "    fn require_exact_v7_root_quartet"
            ),
            let rootNames = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_v7_root_names",
                endingBefore: "    fn require_exact_v7_retained_triplet"
            ),
            let quartet = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_v7_root_quartet",
                endingBefore: "    fn require_retry_v7_pointer_expectation"
            ),
            let pointer = try? functionBody(
                controller,
                beginningWith: "    fn require_retry_v7_pointer_expectation",
                endingBefore: "    fn require_current_retry_v7_layout"
            ),
            let current = try? functionBody(
                controller,
                beginningWith: "    fn require_current_retry_v7_layout",
                endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n    enum Retry2RecoveryState"
            ),
            let reserve = try? functionBody(
                controller,
                beginningWith: "    fn retry_2_reserve_is_released",
                endingBefore: "    fn verify_retry_2_default_route_snapshot"
            ),
            let archivedHold = try? functionBody(
                controller,
                beginningWith: "    fn retry_2_install_hold_is_archived",
                endingBefore: "    fn retry_2_reserve_is_released"
            ),
            let retainedFile = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retained_file",
                endingBefore: "    fn require_exact_retained_failure_file"
            ),
            let retainedFailure = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retained_failure_file",
                endingBefore: "    fn require_exact_retained_empty_directory"
            ),
            let retainedEmpty = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retained_empty_directory",
                endingBefore: "    fn require_exact_retained_probe_directory"
            ),
            let pendingRetire = try? functionBody(
                controller,
                beginningWith: "    fn retire_exact_retry_v7_pending_pointer_after_parent_crash",
                endingBefore: "    fn uid_proxy_complete_host_crash_rollback"
            ),
            let recovery = try? functionBody(
                controller,
                beginningWith: "    fn recover_retry_2_critical_failure",
                endingBefore: "    fn recover_retry_3_critical_failure"
            ),
            let uidBroker = try? functionBody(
                controller,
                beginningWith: "    fn uid501_driver_broker_proxy",
                endingBefore: "    fn existing_v7_layout_for_restore_proxy"
            ),
            let execute = try? functionBody(
                controller,
                beginningWith: "    fn execute_paired_v7_update",
                endingBefore: "    fn perform_paired_v7_update"
            )
        else { return false }

        let exactPins = [
            "const V7_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-3\";",
            "const FIRST_ATTEMPT_V7_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7\";",
            "const RETRY_1_V7_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-1\";",
            "const RETRY_2_V7_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-2\";",
            #"const FIRST_ATTEMPT_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7.pending-";"#,
            #"const RETRY_1_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7-retry-1.pending-";"#,
            #"const RETRY_2_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7-retry-2.pending-";"#,
            #"const RETRY_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7-retry-3.pending-";"#,
            "const RETAINED_FAILED_V7_ROOT_NLINK: u64 = 5;",
            "const RETAINED_FAILED_V7_ROOT_SIZE: u64 = 160;",
            "const RETRY_3_V7_ROOT_NLINK: u64 = 6;",
            "const RETRY_3_V7_ROOT_SIZE: u64 = 192;",
            "const RECOVERY_RETRY_2_EVIDENCE_INODE: u64 = 27_770_302;",
            "const RECOVERY_RETRY_2_EVIDENCE_NLINK: u64 = 22;",
            "const RECOVERY_RETRY_2_EVIDENCE_SIZE: u64 = 704;",
            "const RECOVERY_RETRY_2_RECOVERY_JOURNAL_INODE: u64 = 27_807_742;",
            "const RECOVERY_RETRY_2_RECOVERY_JOURNAL_SIZE: u64 = 2_720;",
            #""6b5d1b606bfd8eb3bf662e7596698afa891a13340d35af3be4805b1033a83c87""#,
            #""61c88c3d3633119af3910a86afd8bea14d6033f49976615f5c5a1b2e888c450f""#,
            #""f0361f4443eefae656aa2e5e75ed5a4d4a80df521d56403bcc386f00556cfa3f""#,
            #""10578545d58874d94e821cc23657838b62428522be6f32d7b7b23bd926a3e2ba""#,
            #""82f6ab1ce97e08b23e2bbfa3ae309fbfcf3de8734822895ae3064b834f932a1f""#,
            #""55c9dc33d4e7d368f775013c73045eee70a142d8bf30e2faafa7d5e4276e8474""#,
            #""abb699a0a4b80026533b57c960ebe612a2b1a01d""#,
            #""7c47dea69e8d1026d2e54a793e4bb5eb65b7efd6""#,
            "const RECOVERY_RETRY_2_SOURCE_TAR_INODE: u64 = 27_770_309;",
            "const RECOVERY_RETRY_2_SOURCE_TAR_SIZE: u64 = 12_748_800;",
            #""2d4b88d64d3a0df724de32ca6126c0aecbe3e821f72e60ffe78b2ede6f6450ae""#,
            "const RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_INODE: u64 = 27_770_733;",
            #""44da69e650783d6697c1b3b3afe67d29e22161023d712d79c1824eba589327ef""#,
            "const RECOVERY_RETRY_2_PROBES_INODE: u64 = 27_776_651;",
            "const RECOVERY_RETRY_2_PROBES_NLINK: u64 = 7;",
            "const RECOVERY_RETRY_2_PROBES_SIZE: u64 = 224;",
            #""035e3cd9c881c75f101aed88f749c730cff5293c3ca04dfb88f7c14fef84275d""#,
            #""5a9f216f281ddc4540ea4b763580d1d46efc7bc02e66e4b67da974dd380bedf2""#,
            "const RECOVERY_RETRY_2_FAILED_NEW_INODE: u64 = 27_770_305;",
            "const RECOVERY_RETRY_2_FAILED_NEW_NLINK: u64 = 3;",
            "const RECOVERY_RETRY_2_FAILED_NEW_SIZE: u64 = 96;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_INODE: u64 = 27_776_737;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_APP_INODE: u64 = 27_776_738;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_INODE: u64 = 27_776_743;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_SIZE: u64 = 6_090_624;",
            #""78d63b9806739cd1088f9b342a4ec0976e6cadff66a95b6750bb5597b74672df""#,
            #""e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855""#,
        ]
        let scopedPinDeclarations = [
            "const RECOVERY_RETRY_2_NAME: &str =\n        \"paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c\";",
            "const RECOVERY_RETRY_2_EVIDENCE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c\";",
            #"const RECOVERY_RETRY_2_NONCE: &str = "34192453-910c-4331-a0d0-d9cb250b1f9c";"#,
            "const RECOVERY_RETRY_2_POINTER_INODE: u64 = 27_777_557;",
            "const RECOVERY_RETRY_2_POINTER_SHA256: &str =\n        \"61c88c3d3633119af3910a86afd8bea14d6033f49976615f5c5a1b2e888c450f\";",
            "const RECOVERY_RETRY_2_POINTER: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c\\n\";",
            "const RECOVERY_RETRY_2_JOURNAL_INODE: u64 = 27_770_306;",
            "const RECOVERY_RETRY_2_JOURNAL_SHA256: &str =\n        \"f0361f4443eefae656aa2e5e75ed5a4d4a80df521d56403bcc386f00556cfa3f\";",
            #"""
            const RECOVERY_RETRY_2_JOURNAL: &str =
                    "OPENSTEAMER_PAIRED_HOST_UPDATE_V7\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit=f4962f422b9795b4074d73dd25f332fb6b05b073 tree=52e737fb8a46a607a4a673b788ddccfbcd38efe6 initial_pid=873\nSTATE BUILD_VERIFIED executable_sha256=78d63b9806739cd1088f9b342a4ec0976e6cadff66a95b6750bb5597b74672df\nSTATE INSTALL_HOLD_VERIFIED\nSTATE DRIVER_PREPARED\nSTATE STOP_INITIATED reserve_device=16777229 reserve_inode=27777546 reserve_bytes=8388608\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE ROLLBACK_STARTED\nSTATE CRITICAL_FAILURE phase=rollback\n";
            """#,
            "const RECOVERY_RETRY_2_RESULT_INODE: u64 = 27_777_807;",
            "const RECOVERY_RETRY_2_RESULT_SHA256: &str =\n        \"10578545d58874d94e821cc23657838b62428522be6f32d7b7b23bd926a3e2ba\";",
            #"""
            const RECOVERY_RETRY_2_RESULT: &str =
                    "result=critical-failure\ndiagnostic=primary=CRITICAL: paired-v7 failure could not prove product-driver restoration before host rollback: primary=root broker response pipe closed before ROOT_V7_BROKER_PUBLISHED nonce=34192453-910c-4331-a0d0-d9cb250b1f9c; host_stop=Ok(()); privileged_cleanup=Broken pipe (os error 32); rollback=restore proxy response pipe closed before UID_V7_RESTORE_PROXY_READY nonce=34192453-910c-4331-a0d0-d9cb250b1f9c\n";
            """#,
            "const RECOVERY_RETRY_2_PROVENANCE_INODE: u64 = 27_770_734;",
            "const RECOVERY_RETRY_2_PROVENANCE_SHA256: &str =\n        \"82f6ab1ce97e08b23e2bbfa3ae309fbfcf3de8734822895ae3064b834f932a1f\";",
            #"""
            const RECOVERY_RETRY_2_PROVENANCE: &str =
                    "commit=f4962f422b9795b4074d73dd25f332fb6b05b073\ntree=52e737fb8a46a607a4a673b788ddccfbcd38efe6\nfunctional_source_commit=7beb049226ada83e97afba3e60089469d0eeeef6\nfunctional_source_tree=60e2df01afe1b4c09362b8e1b55efa709f23a748\nauthorized_release_commit=f4962f422b9795b4074d73dd25f332fb6b05b073\nauthorized_release_tree=52e737fb8a46a607a4a673b788ddccfbcd38efe6\nupstream=origin/agent/auto-select-iphone-microphone\nremote=https://github.com/ahmedelami/opensteamer.git\nfunctional_inputs_sha256=fdef1da4413f66d5f066c86b0eba709b55c74b1f72b29dac8d62e991a2343ca6\nfunctional_input_evidence_sha256=44da69e650783d6697c1b3b3afe67d29e22161023d712d79c1824eba589327ef\nsource_archive_sha256=2d4b88d64d3a0df724de32ca6126c0aecbe3e821f72e60ffe78b2ede6f6450ae\n";
            """#,
            "const RECOVERY_RETRY_2_DRIVER_RECORD_INODE: u64 = 27_777_174;",
            "const RECOVERY_RETRY_2_DRIVER_RECORD_SHA256: &str =\n        \"55c9dc33d4e7d368f775013c73045eee70a142d8bf30e2faafa7d5e4276e8474\";",
            #"""
            const RECOVERY_RETRY_2_DRIVER_RECORD: &str =
                    "schema=opensteamer.driver-transaction-evidence.v7\nnonce=34192453-910c-4331-a0d0-d9cb250b1f9c\ncanonical_product_driver=/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver\nroot_controller_sha256=8c1efa7039649a027987fa306460af8d27caa1f10f5d741ee4332b54a0e3a07c\nroot=ROOT_V7_DRIVER_PREPARED root=/Library/Application Support/opensteamer/driver-transactions-v7/transaction-34192453-910c-4331-a0d0-d9cb250b1f9c prior=0 prior_device=0 prior_inode=0 hold_device=16777229 hold_inode=27777177\nroot=ROOT_V7_BROKER_READY nonce=34192453-910c-4331-a0d0-d9cb250b1f9c\nuser=PING\nroot=ROOT_V7_BROKER_PONG nonce=34192453-910c-4331-a0d0-d9cb250b1f9c\nuser=PUBLISH\nuser=ABANDON\n";
            """#,
            "const RECOVERY_RETRY_2_RECOVERY_JOURNAL_INODE: u64 = 27_807_742;",
            "const RECOVERY_RETRY_2_RECOVERY_JOURNAL_SIZE: u64 = 2_720;",
            "const RECOVERY_RETRY_2_RECOVERY_JOURNAL_SHA256: &str =\n        \"6b5d1b606bfd8eb3bf662e7596698afa891a13340d35af3be4805b1033a83c87\";",
            "const RECOVERY_RETRY_2_SOURCE_TAR_INODE: u64 = 27_770_309;",
            "const RECOVERY_RETRY_2_SOURCE_TAR_SIZE: u64 = 12_748_800;",
            "const RECOVERY_RETRY_2_SOURCE_TAR_SHA256: &str =\n        \"2d4b88d64d3a0df724de32ca6126c0aecbe3e821f72e60ffe78b2ede6f6450ae\";",
            "const RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_INODE: u64 = 27_770_733;",
            "const RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_SIZE: u64 = 22_759;",
            "const RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_SHA256: &str =\n        \"44da69e650783d6697c1b3b3afe67d29e22161023d712d79c1824eba589327ef\";",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_NAME_INODE: u64 = 27_770_307;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_NAME_SIZE: u64 = 82;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_NAME_SHA256: &str =\n        \"0d898c51b1ecf2ec41027fe5f3d5aa29046f0d46eebc2c5e59b2ddc055f16c4b\";",
            "const RECOVERY_RETRY_2_ROLLBACK_CURRENT_INODE: u64 = 27_770_304;",
            "const RECOVERY_RETRY_2_RESERVE_INODE: u64 = 27_777_546;",
            "const RECOVERY_RETRY_2_RESERVE_SIZE: u64 = 8_388_608;",
            "const RECOVERY_RETRY_2_RESERVE_SHA256: &str =\n        \"2daeb1f36095b44b318410b3f4e8b5d989dcc7bb023d1426c492dab0a3053e74\";",
            "const RECOVERY_RETRY_2_RELEASED_RESERVE_SHA256: &str =\n        \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\";",
            "const RECOVERY_RETRY_2_PROBES_INODE: u64 = 27_776_651;",
            "const RECOVERY_RETRY_2_PROBES_NLINK: u64 = 7;",
            "const RECOVERY_RETRY_2_PROBES_SIZE: u64 = 224;",
            "const RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_INODE: u64 = 27_776_734;",
            "const RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_SIZE: u64 = 122;",
            "const RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_SHA256: &str =\n        \"035e3cd9c881c75f101aed88f749c730cff5293c3ca04dfb88f7c14fef84275d\";",
            "const RECOVERY_RETRY_2_MIRROR_SELF_TEST_INODE: u64 = 27_776_731;",
            "const RECOVERY_RETRY_2_MIRROR_SELF_TEST_SIZE: u64 = 10_310;",
            "const RECOVERY_RETRY_2_MIRROR_SELF_TEST_SHA256: &str =\n        \"5a9f216f281ddc4540ea4b763580d1d46efc7bc02e66e4b67da974dd380bedf2\";",
            "const RECOVERY_RETRY_2_PUBLIC_PROBE_INODE: u64 = 27_776_727;",
            "const RECOVERY_RETRY_2_PUBLIC_PROBE_SIZE: u64 = 154_912;",
            "const RECOVERY_RETRY_2_GUARDIAN_INODE: u64 = 27_776_710;",
            "const RECOVERY_RETRY_2_GUARDIAN_SIZE: u64 = 286_968;",
            "const RECOVERY_RETRY_2_MIRROR_PROBE_INODE: u64 = 27_776_683;",
            "const RECOVERY_RETRY_2_MIRROR_PROBE_SIZE: u64 = 1_096_944;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_INODE: u64 = 27_776_737;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_APP_INODE: u64 = 27_776_738;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_INODE: u64 = 27_776_743;",
            "const RECOVERY_RETRY_2_INSTALL_HOLD_EXECUTABLE_SHA256: &str =\n        \"78d63b9806739cd1088f9b342a4ec0976e6cadff66a95b6750bb5597b74672df\";",
            "const RECOVERY_RETRY_2_INSTALL_HOLD: &str =\n        \"/Applications/.opensteamer-paired-v7-install-34192453-910c-4331-a0d0-d9cb250b1f9c\";",
            "const RECOVERY_RETRY_2_ARCHIVED_INSTALL_HOLD: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c/failed-new/partial-install-hold-root\";",
            "const RECOVERY_RETRY_2_RECOVERY_JOURNAL: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c/recovery-journal.txt\";",
            "const RECOVERY_RETRY_2_RECOVERY_COMMIT: &str =\n        \"abb699a0a4b80026533b57c960ebe612a2b1a01d\";",
            "const RECOVERY_RETRY_2_RECOVERY_TREE: &str =\n        \"7c47dea69e8d1026d2e54a793e4bb5eb65b7efd6\";",
            "const RECOVERY_RETRY_2_RETIRED_POINTER: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c/retired-active-pointer.txt\";",
        ]
        let topLevelNames = [
            "D:deployment-reference", "D:failed-new", "D:probes",
            "D:production-driver-v7", "D:rollback-current", "D:source-export",
            "D:staged-output", "D:swiftpm-scratch", "F:build.stderr",
            "F:build.stdout", "F:driver-transaction-record.txt",
            "F:functional-inputs.txt", "F:install-hold-name.txt", "F:journal.log",
            "F:provenance.txt", "F:recovery-journal.txt", "F:result.txt",
            "F:retired-active-pointer.txt", "F:rollback-reserve.bin", "F:source.tar",
        ]
        let terminalTokens = [
            ".custom_flags(O_NOFOLLOW)",
            "let before = descriptor.metadata()?;", "let named_before = fs::symlink_metadata(path)?;",
            "metadata.file_type().is_file()", "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID", "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1", "mode() & 0o7777 == 0o600", "metadata.dev() == expected_device",
            "RECOVERY_RETRY_2_RECOVERY_JOURNAL_INODE", "RECOVERY_RETRY_2_RECOVERY_JOURNAL_SIZE",
            "metadata.st_flags() == 0", "!metadata_is_exact(&before)", "!metadata_is_exact(&named_before)",
            "before.dev() != named_before.dev()", "before.ino() != named_before.ino()",
            "before.len() != named_before.len()", ".take(RECOVERY_RETRY_2_RECOVERY_JOURNAL_SIZE + 1)",
            "sha256_bytes(&bytes)? != RECOVERY_RETRY_2_RECOVERY_JOURNAL_SHA256",
            "text != expected",
            "state != Retry2RecoveryState::RecoveredV6",
            "RECOVERY_RETRY_2_RECOVERY_COMMIT.to_owned()",
            "RECOVERY_RETRY_2_RECOVERY_TREE.to_owned()",
            #"!text.ends_with("STATE RECOVERED_V6\n")"#,
            "let after = descriptor.metadata()?;",
            "let named_after = fs::symlink_metadata(path)?;",
            "!metadata_is_exact(&after)", "!metadata_is_exact(&named_after)",
            "before.dev() != after.dev()", "before.ino() != after.ino()", "before.len() != after.len()",
            "before.dev() != named_after.dev()", "before.ino() != named_after.ino()",
            "before.len() != named_after.len()",
        ]
        let pendingTokens = [
            "require_directory(private_root, 0o700)?;", "let before = fs::symlink_metadata(private_root)?;",
            "for entry in fs::read_dir(private_root)?", "name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)",
            "name.starts_with(RETRY_1_V7_PENDING_PREFIX)", "name.starts_with(RETRY_2_V7_PENDING_PREFIX)",
            "name.starts_with(RETRY_V7_PENDING_PREFIX)", "let after = fs::symlink_metadata(private_root)?;",
            "before.dev() != after.dev()", "before.ino() != after.ino()",
            "before.permissions().mode() & 0o7777 != 0o700", "after.permissions().mode() & 0o7777 != 0o700",
        ]
        let topLevelTokens = [
            "const EXPECTED: [&str; 20]", "let before = fs::symlink_metadata(evidence)?;",
            "for entry in fs::read_dir(evidence)?", "entry.file_type()?.is_dir()", "entry.file_type()?.is_file()",
            "entry.path() != evidence.join(&name)", "actual.push(format!(\"{kind}:{name}\"));",
            "actual.sort_unstable();", "actual.iter().map(String::as_str).ne(EXPECTED)",
            "let after = fs::symlink_metadata(evidence)?;", "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.nlink() != after.nlink()", "before.len() != after.len()",
            "before.permissions().mode() != after.permissions().mode()", "before.st_flags() != after.st_flags()",
        ]
        let probeTokens = [
            "const EXPECTED: [&str; 5]", "let before = fs::symlink_metadata(&probes)?;",
            "metadata.file_type().is_dir()", "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID", "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == RECOVERY_RETRY_2_PROBES_NLINK", "mode() & 0o7777 == 0o700",
            "metadata.dev() == expected_device", "metadata.ino() == RECOVERY_RETRY_2_PROBES_INODE",
            "metadata.len() == RECOVERY_RETRY_2_PROBES_SIZE", "metadata.st_flags() == 0",
            "!metadata_is_exact(&before)",
            "for entry in fs::read_dir(&probes)?", "!entry.file_type()?.is_file()",
            "entry.path() != probes.join(&name)", "actual.sort_unstable();",
            "actual.iter().map(String::as_str).ne(EXPECTED)", "guardian-self-test.json",
            "RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_INODE", "0o600",
            "RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_SIZE", "RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_SHA256",
            "mirror-loopback-self-test.json", "RECOVERY_RETRY_2_MIRROR_SELF_TEST_INODE", "0o600",
            "RECOVERY_RETRY_2_MIRROR_SELF_TEST_SIZE", "RECOVERY_RETRY_2_MIRROR_SELF_TEST_SHA256",
            "opensteamer-public-vpio-probe", "RECOVERY_RETRY_2_PUBLIC_PROBE_INODE", "0o755",
            "RECOVERY_RETRY_2_PUBLIC_PROBE_SIZE", "EXPECTED_PUBLIC_VPIO_PROBE_BINARY_SHA256",
            "opensteamer-v7-default-route-guardian", "RECOVERY_RETRY_2_GUARDIAN_INODE", "0o755",
            "RECOVERY_RETRY_2_GUARDIAN_SIZE", "EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256",
            "physical-virtual-microphone-probe", "RECOVERY_RETRY_2_MIRROR_PROBE_INODE", "0o755",
            "RECOVERY_RETRY_2_MIRROR_PROBE_SIZE", "EXPECTED_MIRROR_PROBE_BINARY_SHA256",
            "require_exact_retained_file(",
            "let after = fs::symlink_metadata(&probes)?;", "!metadata_is_exact(&after)",
            "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.nlink() != after.nlink()", "before.len() != after.len()",
        ]
        let recoveredTokens = [
            "evidence.parent() != Some(root)", "Some(RECOVERY_RETRY_2_NAME)",
            "let root_before = fs::symlink_metadata(root)?;", "let before = fs::symlink_metadata(evidence)?;",
            "metadata.file_type().is_dir()", "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID", "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == RECOVERY_RETRY_2_EVIDENCE_NLINK", "mode() & 0o7777 == 0o700",
            "metadata.dev() == expected_device", "metadata.ino() == RECOVERY_RETRY_2_EVIDENCE_INODE",
            "metadata.len() == RECOVERY_RETRY_2_EVIDENCE_SIZE", "metadata.st_flags() == 0",
            "!metadata_is_exact(&before)", "RETRY_2_V7_ACTIVE_UPDATE", "RECOVERY_RETRY_2_INSTALL_HOLD",
            "require_exact_retry_2_post_recovery_top_level(evidence)?;",
            #"&evidence.join("journal.log")"#,
            "expected_device", "RECOVERY_RETRY_2_JOURNAL_INODE", "RECOVERY_RETRY_2_JOURNAL",
            "RECOVERY_RETRY_2_JOURNAL_SHA256",
            #"&evidence.join("result.txt")"#,
            "expected_device", "RECOVERY_RETRY_2_RESULT_INODE", "RECOVERY_RETRY_2_RESULT",
            "RECOVERY_RETRY_2_RESULT_SHA256",
            #"&evidence.join("provenance.txt")"#,
            "expected_device", "RECOVERY_RETRY_2_PROVENANCE_INODE", "RECOVERY_RETRY_2_PROVENANCE",
            "RECOVERY_RETRY_2_PROVENANCE_SHA256",
            #"&evidence.join("driver-transaction-record.txt")"#,
            "expected_device", "RECOVERY_RETRY_2_DRIVER_RECORD_INODE", "RECOVERY_RETRY_2_DRIVER_RECORD",
            "RECOVERY_RETRY_2_DRIVER_RECORD_SHA256", "Path::new(RECOVERY_RETRY_2_RETIRED_POINTER)",
            "expected_device", "RECOVERY_RETRY_2_POINTER_INODE", "RECOVERY_RETRY_2_POINTER",
            "RECOVERY_RETRY_2_POINTER_SHA256",
            #"&evidence.join("source.tar")"#,
            "expected_device", "RECOVERY_RETRY_2_SOURCE_TAR_INODE", "0o600",
            "RECOVERY_RETRY_2_SOURCE_TAR_SIZE", "RECOVERY_RETRY_2_SOURCE_TAR_SHA256",
            #"&evidence.join("functional-inputs.txt")"#,
            "expected_device", "RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_INODE", "0o600",
            "RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_SIZE", "RECOVERY_RETRY_2_FUNCTIONAL_INPUTS_SHA256",
            #"&evidence.join("install-hold-name.txt")"#,
            "expected_device", "RECOVERY_RETRY_2_INSTALL_HOLD_NAME_INODE", "0o600",
            "RECOVERY_RETRY_2_INSTALL_HOLD_NAME_SIZE", "RECOVERY_RETRY_2_INSTALL_HOLD_NAME_SHA256",
            "require_exact_recovered_retry_2_probes(evidence, expected_device)?;",
            "require_exact_terminal_retry_2_recovery_journal(expected_device)?;",
            #"&evidence.join("rollback-current")"#,
            "let failed = fs::symlink_metadata(&layout.failed_dir)?;",
            "!failed.file_type().is_dir()", "failed.file_type().is_symlink()", "failed.uid() != USER_ID",
            "failed.gid() != RETAINED_FAILED_V7_ATTEMPT_GID", "failed.nlink() != RECOVERY_RETRY_2_FAILED_NEW_NLINK",
            "failed.permissions().mode() & 0o7777 != 0o700", "failed.dev() != expected_device",
            "failed.ino() != RECOVERY_RETRY_2_FAILED_NEW_INODE", "failed.len() != RECOVERY_RETRY_2_FAILED_NEW_SIZE",
            "failed.st_flags() != 0",
            "retry_2_install_hold_is_archived(&layout)?",
            "retry_2_reserve_is_released(&layout)?",
            "let failed_after = fs::symlink_metadata(&layout.failed_dir)?;",
            "let failed_metadata_is_exact = |metadata: &fs::Metadata|",
            "!failed_metadata_is_exact(&failed_after)",
            "failed.dev() != failed_after.dev()", "failed.ino() != failed_after.ino()",
            "failed.nlink() != failed_after.nlink()", "failed.len() != failed_after.len()",
            "failed.permissions().mode() & 0o7777", "failed_after.permissions().mode() & 0o7777",
            "failed.st_flags() != failed_after.st_flags()",
            "RECOVERY_RETRY_2_RELEASED_RESERVE_SHA256",
            "require_exact_retry_2_post_recovery_top_level(evidence)?;",
            "let after = fs::symlink_metadata(evidence)?;",
            "!metadata_is_exact(&after)", "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.nlink() != after.nlink()", "before.len() != after.len()",
            "root_before.dev() != root_after.dev()", "root_before.ino() != root_after.ino()",
        ]
        let admissionTokens = [
            "FIRST_ATTEMPT_V7_ACTIVE_UPDATE", "RETRY_1_V7_ACTIVE_UPDATE",
            "RETRY_2_V7_ACTIVE_UPDATE", "V7_ACTIVE_UPDATE",
            "require_no_v7_pending_pointers()?;", "ROOT_V7_SUPPORT_DIRECTORY",
            "require_exact_v7_retained_triplet(root, data_volume_device)?;",
            "require_exact_retained_v7_evidence(data_volume_device)?;",
            "require_exact_retained_retry_1_v7_evidence(data_volume_device)?;",
            "require_exact_recovered_retry_2_evidence(data_volume_device)?;",
            "require_exact_v7_retained_triplet(root, data_volume_device)",
        ]
        let rootNameTokens = [
            "root.to_str() != Some(V7_UPDATE_ROOT)", "expected_names.is_empty()",
            "name.is_empty() || name.contains('/')", "let root_before = fs::symlink_metadata(root)?;",
            "root_before.file_type().is_dir()", "root_before.file_type().is_symlink()",
            "root_before.uid() != USER_ID", "root_before.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "root_before.permissions().mode() & 0o7777 != 0o700",
            "root_before.ino() != RETAINED_FAILED_V7_ROOT_INODE", "root_before.st_flags() != 0",
            "for entry in fs::read_dir(root)?", "!entry.file_type()?.is_dir()",
            "entry.path().to_str() != expected_path.to_str()", "actual.push(entry_name.to_owned());",
            "actual.sort_unstable();", "expected.sort_unstable();",
            "expected.windows(2).any(|pair| pair[0] == pair[1]) || actual != expected",
            "let root_after = fs::symlink_metadata(root)?;", "root_after.uid() != USER_ID",
            "root_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID", "root_after.st_flags() != 0",
            "root_before.dev() != root_after.dev()", "root_before.ino() != root_after.ino()",
            "root_before.nlink() != root_after.nlink()",
        ]
        let tripletTokens = [
            "require_exact_v7_root_names(", "RETAINED_FAILED_V7_ATTEMPT_NAME",
            "RETAINED_FAILED_V7_RETRY_1_NAME", "RECOVERY_RETRY_2_NAME",
            "let metadata = fs::symlink_metadata(root)?;", "metadata.dev() != expected_device",
            "metadata.ino() != RETAINED_FAILED_V7_ROOT_INODE", "metadata.uid() != USER_ID",
            "metadata.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() != RETAINED_FAILED_V7_ROOT_NLINK", "mode() & 0o7777 != 0o700",
            "metadata.len() != RETAINED_FAILED_V7_ROOT_SIZE", "metadata.st_flags() != 0",
        ]
        let quartetTokens = [
            "require_exact_v7_root_names(", "RETAINED_FAILED_V7_ATTEMPT_NAME",
            "RETAINED_FAILED_V7_RETRY_1_NAME", "RECOVERY_RETRY_2_NAME", "current_name",
        ]
        let pointerTokens = [
            "Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE)", "Path::new(RETRY_1_V7_ACTIVE_UPDATE)",
            "Path::new(RETRY_2_V7_ACTIVE_UPDATE)", "require_no_v7_pending_pointers()?;",
            "RetryV7PointerExpectation::Absent", "require_path_absent(Path::new(V7_ACTIVE_UPDATE)",
            "RetryV7PointerExpectation::Present", "verify_update_pointer_at(",
            "Path::new(V7_ACTIVE_UPDATE)", "evidence", "Path::new(V7_UPDATE_ROOT)",
        ]
        let currentTokens = [
            #".strip_prefix("paired-v7-update-retry-3-")"#,
            "suffix.len() <= 37", "suffix.as_bytes()[suffix.len() - 37] != b'-'",
            "suffix.split_at(suffix.len() - 37)", "validate_v7_nonce(nonce)?;",
            "expected_nonce.is_some_and(|expected| expected != nonce)", "numeric.split_once('-')",
            "timestamp_text.parse::<u64>().ok()", "pid_text.parse::<u32>().ok()",
            "timestamp.filter(|value| *value > 0).is_none()", "value.to_string() != timestamp_text",
            "value.to_string() != pid_text", "pid_text.contains('-')", "let root = Path::new(V7_UPDATE_ROOT);",
            "evidence.to_str() != expected_evidence.to_str()", "evidence.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)",
            "RETAINED_FAILED_V7_ATTEMPT", "RETAINED_FAILED_V7_RETRY_1", "RECOVERY_RETRY_2_EVIDENCE",
            "root_before.file_type().is_dir()", "root_before.file_type().is_symlink()",
            "root_before.uid() != USER_ID", "root_before.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "root_before.permissions().mode() & 0o7777 != 0o700",
            "root_before.dev() != data_volume_device", "root_before.ino() != RETAINED_FAILED_V7_ROOT_INODE",
            "root_before.nlink() != RETRY_3_V7_ROOT_NLINK", "root_before.len() != RETRY_3_V7_ROOT_SIZE",
            "root_before.st_flags() != 0",
            "retry_metadata.file_type().is_symlink()", "!retry_metadata.file_type().is_dir()",
            "retry_metadata.uid() != USER_ID", "retry_metadata.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "retry_metadata.permissions().mode() & 0o7777 != 0o700",
            "retry_metadata.dev() != data_volume_device", "retry_metadata.ino() == 0",
            "RETAINED_FAILED_V7_ATTEMPT_INODE", "RETAINED_FAILED_V7_RETRY_1_INODE",
            "RECOVERY_RETRY_2_EVIDENCE_INODE", "retry_metadata.nlink() < 2", "retry_metadata.st_flags() != 0",
            "require_exact_v7_root_quartet(root, name)?;",
            "require_exact_retained_v7_evidence(data_volume_device)?;",
            "require_exact_retained_retry_1_v7_evidence(data_volume_device)?;",
            "require_exact_recovered_retry_2_evidence(data_volume_device)?;",
            "require_retry_v7_pointer_expectation(evidence, pointer_expectation)?;",
            "require_exact_v7_root_quartet(root, name)?;",
            "let root_after = fs::symlink_metadata(root)?;", "let retry_after = fs::symlink_metadata(evidence)?;",
            "root_after.file_type().is_dir()", "root_after.file_type().is_symlink()",
            "root_after.uid() != USER_ID", "root_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "root_after.permissions().mode() & 0o7777 != 0o700",
            "root_after.nlink() != RETRY_3_V7_ROOT_NLINK", "root_after.len() != RETRY_3_V7_ROOT_SIZE",
            "retry_after.file_type().is_symlink()", "!retry_after.file_type().is_dir()",
            "retry_after.uid() != USER_ID", "retry_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "retry_after.permissions().mode() & 0o7777 != 0o700",
            "root_before.dev() != root_after.dev()", "root_before.ino() != root_after.ino()",
            "root_before.nlink() != root_after.nlink()", "root_before.permissions().mode() & 0o7777",
            "root_after.permissions().mode() & 0o7777", "root_before.st_flags() != root_after.st_flags()",
            "retry_metadata.dev() != retry_after.dev()", "retry_metadata.ino() != retry_after.ino()",
            "retry_metadata.nlink() != retry_after.nlink()", "retry_metadata.len() != retry_after.len()",
            "retry_metadata.st_flags() != retry_after.st_flags()", "require_retry_v7_pointer_expectation(evidence, pointer_expectation)?;",
            "require_exact_v7_root_quartet(root, name)?;",
        ]
        let recoveryTokens = [
            "terminal retry-2 recovery verification transaction lock",
            "Path::new(RETRY_2_V7_ACTIVE_UPDATE)", "Path::new(V7_ACTIVE_UPDATE)",
            "require_no_v7_pending_pointers()?;", "verified_data_volume_device()?;",
            "require_exact_recovered_retry_2_evidence(data_volume_device)?;",
            "verify_retry_2_recovered_v6_generation()?;",
            "authenticate_v7_privileged_boundary()?;", "prove_retry_2_safe_runtime(&layout)?;",
            "require_exact_recovered_retry_2_evidence(data_volume_device)?;",
            "PAIRED_V7_RETRY_2_RECOVERED_V6_VERIFIED",
        ]
        let retainedFileTokens = [
            "expected_length > 16 * 1_024 * 1_024", "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()", "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID", "metadata.nlink() == 1",
            "mode() & 0o7777 == expected_mode", "metadata.dev() == expected_device",
            "metadata.ino() == expected_inode", "metadata.len() == expected_length",
            "metadata.st_flags() == 0", "let named_before = fs::symlink_metadata(path)?;",
            ".custom_flags(O_NOFOLLOW)", "let descriptor_before = file.metadata()?;",
            "descriptor_before.dev() != named_before.dev()", "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()", ".take(expected_length + 1)",
            "let descriptor_after = file.metadata()?;", "let named_after = fs::symlink_metadata(path)?;",
            "sha256_bytes(&bytes)? != expected_sha256", "!metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&named_after)", "descriptor_before.dev() != descriptor_after.dev()",
            "descriptor_before.ino() != descriptor_after.ino()", "descriptor_before.len() != descriptor_after.len()",
            "descriptor_before.dev() != named_after.dev()", "descriptor_before.ino() != named_after.ino()",
            "descriptor_before.len() != named_after.len()",
        ]
        let retainedFailureTokens = [
            "require_exact_retained_file(", "0o600", "expected_bytes.len() as u64",
            "expected_sha256", "bytes.as_slice() != expected_bytes.as_bytes()",
        ]
        let retainedEmptyTokens = [
            "metadata.file_type().is_dir()", "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID", "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 2", "mode() & 0o7777 == 0o700",
            "metadata.dev() == expected_device", "metadata.ino() == expected_inode", "metadata.st_flags() == 0",
            "let before = fs::symlink_metadata(path)?;", "fs::read_dir(path)?.next().transpose()?.is_some()",
            "let after = fs::symlink_metadata(path)?;", "!metadata_is_exact(&after)",
            "before.dev() != after.dev()", "before.ino() != after.ino()", "before.nlink() != after.nlink()",
        ]
        let archivedHoldTokens = [
            "Path::new(RECOVERY_RETRY_2_INSTALL_HOLD)", "Path::new(RECOVERY_RETRY_2_ARCHIVED_INSTALL_HOLD)",
            "archive.parent() != Some(layout.failed_dir.as_path())", "path_exists_without_follow(source)?",
            "path_exists_without_follow(archive)?", "match (source_exists, archive_exists)",
            "(true, false)", "require_exact_retry_2_install_hold_at(source, layout)?;",
            "fs::read_dir(&layout.failed_dir)?", "Ok(false)", "(false, true)",
            "require_exact_retry_2_install_hold_at(archive, layout)?;", "names != [\"partial-install-hold-root\".to_owned()]",
            "Ok(true)", "retry-2 install hold is duplicated or missing",
        ]
        let releasedReserveTokens = [
            "verified_data_volume_device()?", "require_regular(&layout.rollback_reserve, 0o600)?;",
            ".custom_flags(O_NOFOLLOW)", "let before = descriptor.metadata()?;",
            "let named_before = fs::symlink_metadata(&layout.rollback_reserve)?;",
            "before.dev() != data_volume_device", "before.ino() != RECOVERY_RETRY_2_RESERVE_INODE",
            "before.uid() != USER_ID", "before.gid() != RETAINED_FAILED_V7_ATTEMPT_GID",
            "before.nlink() != 1", "mode() & 0o7777 != 0o600", "before.st_flags() != 0",
            "before.dev() != named_before.dev()", "before.len() == RECOVERY_RETRY_2_RESERVE_SIZE",
            "before.blocks().checked_mul(512)", "allocated_bytes < RECOVERY_RETRY_2_RESERVE_SIZE",
            "RECOVERY_RETRY_2_RESERVE_SHA256", "return Ok(false)", "let read = descriptor.read(&mut byte)?;",
            "before.len() != 0", "before.blocks() != 0", "read != 0", "after.uid() != USER_ID",
            "after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID", "after.nlink() != 1",
            "after.permissions().mode() & 0o7777 != 0o600", "after.blocks() != 0",
            "named_after.uid() != USER_ID", "named_after.blocks() != 0",
            "before.dev() != after.dev()", "before.dev() != named_after.dev()", "Ok(true)",
        ]
        let pendingRetireTokens = [
            "Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE)", "Path::new(RETRY_1_V7_ACTIVE_UPDATE)",
            "Path::new(RETRY_2_V7_ACTIVE_UPDATE)", "Path::new(V7_ACTIVE_UPDATE)",
            #""{V7_ACTIVE_UPDATE}.pending-{expected_main_pid}""#, "require_directory(private_root, 0o700)?;",
            "for entry in fs::read_dir(private_root)?", "name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)",
            "name.starts_with(RETRY_1_V7_PENDING_PREFIX)", "name.starts_with(RETRY_2_V7_PENDING_PREFIX)",
            "name.starts_with(RETRY_V7_PENDING_PREFIX)", "name != pending_name",
            "if found_expected_pending", "root_before.dev() != root_after_scan.dev()",
            "evidence.join(\"retired-pending-active-pointer.txt\")", "found_expected_pending && retired_exists",
            "!found_expected_pending && !retired_exists", "require_retry_v7_leaf_main_pid(evidence, expected_main_pid)?;",
            "open_exact_retry_v7_pending_pointer(source, evidence, data_volume_device)?;",
            "rename_exclusive(&pending, &retired)?;", "fsync_parent(&pending)?;", "fsync_parent(&retired)?;",
            "descriptor_before.dev() != descriptor_after.dev()", "descriptor_before.dev() != retired_after.dev()",
            "require_path_absent(&pending", "require_no_v7_pending_pointers()",
        ]
        return exactPins.allSatisfy(controller.contains)
            && scopedPinDeclarations.allSatisfy(controller.contains)
            && topLevelNames.allSatisfy(topLevel.contains)
            && containsOrdered(pendingTokens, in: pending)
            && containsOrdered(topLevelTokens, in: topLevel)
            && containsOrdered(terminalTokens, in: terminalJournal)
            && ["guardian-self-test.json", "mirror-loopback-self-test.json",
                "opensteamer-public-vpio-probe", "opensteamer-v7-default-route-guardian",
                "physical-virtual-microphone-probe"]
                .allSatisfy(probes.contains)
            && containsOrdered(probeTokens, in: probes)
            && containsOrdered(recoveredTokens, in: recovered)
            && containsOrdered(admissionTokens, in: admission)
            && containsOrdered(rootNameTokens, in: rootNames)
            && containsOrdered(tripletTokens, in: triplet)
            && containsOrdered(quartetTokens, in: quartet)
            && containsOrdered(pointerTokens, in: pointer)
            && containsOrdered(currentTokens, in: current)
            && reserve.contains("before.blocks() != 0")
            && reserve.contains("RECOVERY_RETRY_2_RELEASED_RESERVE_SHA256") == false
            && containsOrdered(recoveryTokens, in: recovery)
            && containsOrdered(retainedFileTokens, in: retainedFile)
            && containsOrdered(retainedFailureTokens, in: retainedFailure)
            && containsOrdered(retainedEmptyTokens, in: retainedEmpty)
            && containsOrdered(archivedHoldTokens, in: archivedHold)
            && containsOrdered(releasedReserveTokens, in: reserve)
            && containsOrdered(pendingRetireTokens, in: pendingRetire)
            && !recovery.contains("Retry2RecoveryJournal::open")
            && !recovery.contains("Retry2RecoveryJournal::create")
            && !recovery.contains(".record(")
            && !recovery.contains("retire_update_pointer_at")
            && !controller.contains("legacy_recover_retry_2_critical_failure")
            && !controller.contains("Retry2RecoveryJournal")
            && !controller.contains("archive_exact_retry_2_install_hold")
            && !controller.contains("release_exact_retry_2_reserve")
            && controller.components(separatedBy: "recover_retry_2_critical_failure(").count - 1 == 2
            && containsOrdered(
                [
                    "require_exact_staged_driver_artifacts(nonce, staged_driver, staged_package)?;",
                    "require_current_retry_v7_layout(",
                    "Some(&layout.nonce)",
                    "RetryV7PointerExpectation::Absent",
                    "Command::new(\"/usr/bin/sudo\")",
                ],
                in: uidBroker
            )
            && execute.contains(#""paired-v7-update-retry-3-{}-{}-{}""#)
            && execute.components(separatedBy: "require_v7_retry_admission_ready()?;").count - 1 >= 3
            && execute.contains("require_retry_3_root_admission_via_sudo()?;")
            && execute.contains("require_current_retry_v7_layout(")
    }

    private func hasRetry3RootV2Contract(_ controller: String) -> Bool {
        guard
            let direct = try? functionBody(controller, beginningWith: "    fn require_retained_root_controller_set(", endingBefore: "    fn require_retained_root_normal_v1"),
            let sudo = try? functionBody(controller, beginningWith: "    fn require_retained_root_controller_set_via_sudo", endingBefore: "    fn require_retained_root_normal_v1_via_sudo"),
            let parent = try? functionBody(controller, beginningWith: "    fn require_exact_retry_3_transaction_parent_names", endingBefore: "    fn require_retained_retry_2_root_tombstone"),
            let tombstone = try? functionBody(controller, beginningWith: "    fn require_retained_retry_2_root_tombstone", endingBefore: "    fn require_no_openers_root"),
            let topology = try? functionBody(controller, beginningWith: "    fn require_root_v2_support_topology", endingBefore: "    fn create_or_repair_root_recovery_sealed"),
            let repair = try? functionBody(controller, beginningWith: "    fn create_or_repair_root_recovery_sealed", endingBefore: "    fn verify_root_controller_identity"),
            let publisher = try? functionBody(controller, beginningWith: "    fn publish_root_controller", endingBefore: "    fn require_root_v2_support_topology"),
            let bootstrap = try? functionBody(controller, beginningWith: "    fn bootstrap_root_controller_identity", endingBefore: "    fn publish_root_controller"),
            let retainedFile = try? functionBody(controller, beginningWith: "    fn require_exact_retained_root_controller_set_file", endingBefore: "    fn require_retained_root_controller_set("),
            let recoveryV1File = try? functionBody(controller, beginningWith: "    fn require_exact_retained_root_recovery_v1_file", endingBefore: "    fn require_retained_root_recovery_v1"),
            let recoveryV1Direct = try? functionBody(controller, beginningWith: "    fn require_retained_root_recovery_v1()", endingBefore: "    fn require_exact_retained_root_controller_set_file"),
            let sudoSealed = try? functionBody(controller, beginningWith: "    fn sudo_root_sealed_file", endingBefore: "    fn sudo_retained_root_recovery_v1_stat"),
            let recoveryV1SudoStat = try? functionBody(controller, beginningWith: "    fn sudo_retained_root_recovery_v1_stat", endingBefore: "    fn require_retained_root_recovery_v1_via_sudo"),
            let recoveryV1Sudo = try? functionBody(controller, beginningWith: "    fn require_retained_root_recovery_v1_via_sudo", endingBefore: "    fn require_retained_root_controller_set_via_sudo"),
            let sudoParent = try? functionBody(controller, beginningWith: "    fn require_retry_3_transaction_parent_via_sudo", endingBefore: "    fn read_root_controller_identity_records_via_sudo"),
            let normalV1Direct = try? functionBody(controller, beginningWith: "    fn require_retained_root_normal_v1()", endingBefore: "    fn require_retained_root_recovery_v2"),
            let recoveryV2Direct = try? functionBody(controller, beginningWith: "    fn require_retained_root_recovery_v2()", endingBefore: "    fn require_exact_root_transaction_children"),
            let normalV1Sudo = try? functionBody(controller, beginningWith: "    fn require_retained_root_normal_v1_via_sudo", endingBefore: "    fn require_retained_root_recovery_v2_via_sudo"),
            let recoveryV2Sudo = try? functionBody(controller, beginningWith: "    fn require_retained_root_recovery_v2_via_sudo", endingBefore: "    fn require_retry_3_transaction_parent_via_sudo"),
            let uidPrepare = try? functionBody(controller, beginningWith: "    fn bootstrap_root_owned_v7_controller_for_prepare", endingBefore: "    fn verify_root_owned_v7_controller_for_restore"),
            let uidRestore = try? functionBody(controller, beginningWith: "    fn verify_root_owned_v7_controller_for_restore", endingBefore: "    fn attest_retry_2_root_safe_state_via_sudo"),
            let attestSudo = try? functionBody(controller, beginningWith: "    fn attest_retry_2_root_safe_state_via_sudo", endingBefore: "    fn require_retry_3_root_admission_via_sudo"),
            let rootAdmission = try? functionBody(controller, beginningWith: "    fn require_retry_3_root_admission_via_sudo", endingBefore: "    fn spawn_bounded_line_reader"),
            let verifyRootController = try? functionBody(controller, beginningWith: "    fn verify_root_controller_identity", endingBefore: "    fn require_retry_3_root_operation_trust"),
            let rootTrust = try? functionBody(controller, beginningWith: "    fn require_retry_3_root_operation_trust", endingBefore: "    fn finish_retry_3_root_operation"),
            let finish = try? functionBody(controller, beginningWith: "    fn finish_retry_3_root_operation", endingBefore: "    fn verify_root_recovery_controller_identity"),
            let recoveryIdentity = try? functionBody(controller, beginningWith: "    fn verify_root_recovery_controller_identity", endingBefore: "    fn require_root_private_directory"),
            let rootAttest = try? functionBody(controller, beginningWith: "    fn root_attest_retry_2_safe_state", endingBefore: "    fn require_fixed_system_binary"),
            let rootDirectoryIdentity = try? functionBody(controller, beginningWith: "    fn require_exact_root_directory_identity", endingBefore: "    fn require_exact_root_regular_identity"),
            let rootRegularIdentity = try? functionBody(controller, beginningWith: "    fn require_exact_root_regular_identity", endingBefore: "    fn require_exact_retained_root_recovery_v1_file"),
            let rootChildren = try? functionBody(controller, beginningWith: "    fn require_exact_root_transaction_children", endingBefore: "    fn require_exact_retry_3_transaction_parent_names"),
            let commandEnum = try? functionBody(controller, beginningWith: "    enum V7Command", endingBefore: "    impl V7Layout"),
            let main = try? functionBody(controller, beginningWith: "    fn paired_v7_real_main", endingBefore: "    fn parse_v7_command"),
            let parser = try? functionBody(controller, beginningWith: "    fn parse_v7_command", endingBefore: "    fn require_canonical_git_oid"),
            let releasePins = try? functionBody(controller, beginningWith: "    fn require_v7_release_pins", endingBefore: "    fn count_exact_production_identity"),
            let stableIdentity = try? functionBody(controller, beginningWith: "    fn stable_controller_binary_identity", endingBefore: "    fn verified_uid501_controller_identity"),
            let pinnedBinary = try? functionBody(controller, beginningWith: "    fn require_pinned_system_binary", endingBefore: "    fn parse_core_audio_launch_state"),
            let prepare = try? functionBody(controller, beginningWith: "    fn root_driver_prepare", endingBefore: "    fn root_driver_publish_reload"),
            let publish = try? functionBody(controller, beginningWith: "    fn root_driver_publish_reload", endingBefore: "    fn root_driver_rollback_reload"),
            let rollback = try? functionBody(controller, beginningWith: "    fn root_driver_rollback_reload", endingBefore: "    fn root_driver_restore_or_abandon_existing"),
            let abandon = try? functionBody(controller, beginningWith: "    fn root_driver_abandon_prepare", endingBefore: "    fn root_driver_verify_commit_ready")
        else { return false }

        let exactPins = [
            #""/Library/Application Support/opensteamer/privileged-v7-v2""#,
            #""/Library/Application Support/opensteamer/privileged-v7-v2/opensteamer-v7-controller""#,
            #""/Library/Application Support/opensteamer/privileged-v7-v2/.opensteamer-v7-controller.pending""#,
            #""--root-publish-controller-identity-v7-v2""#,
            #""--root-bootstrap-controller-identity-v7-v2""#,
            #""/Library/Application Support/opensteamer/privileged-v7""#,
            "const RETAINED_ROOT_V7_V1_SUPPORT_INODE: u64 = 27_777_169;",
            "const RETAINED_ROOT_V7_V1_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_V1_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_INODE: u64 = 27_777_170;",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_LENGTH: u64 = 1_309_384;",
            #""8c1efa7039649a027987fa306460af8d27caa1f10f5d741ee4332b54a0e3a07c""#,
            #""b0686ad2c1ddc26ccd5d9fa4c31b80339427de6a52efccd34994f815e54f61e7""#,
            #""0c8907ef3d77c3c296d8e255d4aeb01cf91333aa4147fa2cacbdee9c73c1ff62""#,
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE: u64 = 27_803_148;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_INODE: u64 = 27_803_149;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_LENGTH: u64 = 1_420_216;",
            #""b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317""#,
            #""030450c1027f4e0d36fabf66471248e4ef9690e1b30d2d3961db4f1cae0ffdd6""#,
            #""41c5042ed37c13692cb4d11fc8e039d0008d8038b7240175920b0338701737a7""#,
            "const RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_INODE: u64 = 27_807_654;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_INODE: u64 = 27_807_655;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_LENGTH: u64 = 1_438_232;",
            #""4ce57b2affe12fca36c4b1bc5d1425d78355bbe5153ab99053a9ddf1ae71c31d""#,
            #""9cc5788a0094c204bd776724553babe10d010093de6391aa1ea484fa11732459""#,
            #""1f88d2b981364a34a2db517a3ffc75a52f9b081c8693c3b8322b8718569b536d""#,
            "const RETAINED_ROOT_V7_TRANSACTION_PARENT_INODE: u64 = 27_777_175;",
            "const RETAINED_ROOT_V7_TRANSACTION_PARENT_NLINK: u64 = 3;",
            "const RETAINED_ROOT_V7_TRANSACTION_PARENT_LENGTH: u64 = 96;",
            "const RECOVERY_RETRY_2_ROOT_TRANSACTION_INODE: u64 = 27_777_176;",
            "const RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE: u64 = 27_777_177;",
            "OPENSTEAMER_V7_CONTROLLER_IDENTITY_V2",
        ]
        let scopedRootDeclarations = [
            "const ROOT_V7_SUPPORT_DIRECTORY: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-v2\";",
            "const ROOT_V7_CONTROLLER: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-v2/opensteamer-v7-controller\";",
            "const ROOT_V7_CONTROLLER_PENDING: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-v2/.opensteamer-v7-controller.pending\";",
            "const ROOT_V7_CONTROLLER_PIN: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-v2/controller-binary.sha256\";",
            "const ROOT_V7_CONTROLLER_IDENTITY_JOURNAL: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-v2/controller-identity.log\";",
            "const RETAINED_ROOT_V7_V1_SUPPORT_DIRECTORY: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7\";",
            "const RETAINED_ROOT_V7_V1_CONTROLLER: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7/opensteamer-v7-controller\";",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_PENDING: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7/.opensteamer-v7-controller.pending\";",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_PIN: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7/controller-binary.sha256\";",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_IDENTITY_JOURNAL: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7/controller-identity.log\";",
            "const RETAINED_ROOT_V7_V1_DEVICE: u64 = 16_777_229;",
            "const RETAINED_ROOT_V7_V1_SUPPORT_INODE: u64 = 27_777_169;",
            "const RETAINED_ROOT_V7_V1_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_V1_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_INODE: u64 = 27_777_170;",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_LENGTH: u64 = 1_309_384;",
            "const RETAINED_ROOT_V7_V1_CONTROLLER_SHA256: &str =\n        \"8c1efa7039649a027987fa306460af8d27caa1f10f5d741ee4332b54a0e3a07c\";",
            "const RETAINED_ROOT_V7_V1_PIN_INODE: u64 = 27_777_172;",
            "const RETAINED_ROOT_V7_V1_PIN_LENGTH: u64 = 65;",
            "const RETAINED_ROOT_V7_V1_PIN_SHA256: &str =\n        \"b0686ad2c1ddc26ccd5d9fa4c31b80339427de6a52efccd34994f815e54f61e7\";",
            "const RETAINED_ROOT_V7_V1_JOURNAL_INODE: u64 = 27_777_173;",
            "const RETAINED_ROOT_V7_V1_JOURNAL_LENGTH: u64 = 297;",
            "const RETAINED_ROOT_V7_V1_JOURNAL_SHA256: &str =\n        \"0c8907ef3d77c3c296d8e255d4aeb01cf91333aa4147fa2cacbdee9c73c1ff62\";",
            "const RETAINED_ROOT_V7_V1_PIN: &str =\n        \"8c1efa7039649a027987fa306460af8d27caa1f10f5d741ee4332b54a0e3a07c\\n\";",
            #"const RETAINED_ROOT_V7_V1_JOURNAL: &str = "OPENSTEAMER_V7_CONTROLLER_IDENTITY_V1\ncontroller_path=/Library/Application Support/opensteamer/privileged-v7/opensteamer-v7-controller\ncontroller_device=16777229\ncontroller_inode=27777170\ncontroller_length=1309384\ncontroller_sha256=8c1efa7039649a027987fa306460af8d27caa1f10f5d741ee4332b54a0e3a07c\n";"#,
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_DIRECTORY: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2\";",
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/opensteamer-v7-recovery-controller";"#,
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PENDING: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/.opensteamer-v7-recovery-controller.pending";"#,
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/controller-binary.sha256";"#,
            #"const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_IDENTITY_JOURNAL: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/controller-identity.log";"#,
            "const RETAINED_ROOT_V7_RECOVERY_V1_DEVICE: u64 = 16_777_229;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE: u64 = 27_803_148;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_INODE: u64 = 27_803_149;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_LENGTH: u64 = 1_420_216;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_SHA256: &str =\n        \"b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317\";",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN_INODE: u64 = 27_803_150;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN_LENGTH: u64 = 65;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN_SHA256: &str =\n        \"030450c1027f4e0d36fabf66471248e4ef9690e1b30d2d3961db4f1cae0ffdd6\";",
            "const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_INODE: u64 = 27_803_151;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_LENGTH: u64 = 332;",
            "const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_SHA256: &str =\n        \"41c5042ed37c13692cb4d11fc8e039d0008d8038b7240175920b0338701737a7\";",
            "const RETAINED_ROOT_V7_RECOVERY_V1_PIN: &str =\n        \"b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317\\n\";",
            #"const RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL: &str = "OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V1\ncontroller_path=/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2/opensteamer-v7-recovery-controller\ncontroller_device=16777229\ncontroller_inode=27803149\ncontroller_length=1420216\ncontroller_sha256=b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317\n";"#,
            "const ROOT_V7_RECOVERY_SUPPORT_DIRECTORY: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2\";",
            #"const ROOT_V7_RECOVERY_CONTROLLER: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/opensteamer-v7-recovery-controller";"#,
            #"const ROOT_V7_RECOVERY_CONTROLLER_PENDING: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/.opensteamer-v7-recovery-controller.pending";"#,
            #"const ROOT_V7_RECOVERY_CONTROLLER_PIN: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/controller-binary.sha256";"#,
            #"const ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL: &str = "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/controller-identity.log";"#,
            "const RETAINED_ROOT_V7_RECOVERY_V2_DEVICE: u64 = 16_777_229;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_INODE: u64 = 27_807_654;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_NLINK: u64 = 5;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_LENGTH: u64 = 160;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_INODE: u64 = 27_807_655;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_LENGTH: u64 = 1_438_232;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_SHA256: &str =\n        \"4ce57b2affe12fca36c4b1bc5d1425d78355bbe5153ab99053a9ddf1ae71c31d\";",
            "const RETAINED_ROOT_V7_RECOVERY_V2_PIN_INODE: u64 = 27_807_656;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_PIN_LENGTH: u64 = 65;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_PIN_SHA256: &str =\n        \"9cc5788a0094c204bd776724553babe10d010093de6391aa1ea484fa11732459\";",
            "const RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL_INODE: u64 = 27_807_657;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL_LENGTH: u64 = 335;",
            "const RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL_SHA256: &str =\n        \"1f88d2b981364a34a2db517a3ffc75a52f9b081c8693c3b8322b8718569b536d\";",
            "const RETAINED_ROOT_V7_RECOVERY_V2_PIN: &str =\n        \"4ce57b2affe12fca36c4b1bc5d1425d78355bbe5153ab99053a9ddf1ae71c31d\\n\";",
            #"const RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL: &str = "OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V2\ncontroller_path=/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/opensteamer-v7-recovery-controller\ncontroller_device=16777229\ncontroller_inode=27807655\ncontroller_length=1438232\ncontroller_sha256=4ce57b2affe12fca36c4b1bc5d1425d78355bbe5153ab99053a9ddf1ae71c31d\n";"#,
        ]
        let directTokens = [
            "child.parent() != Some(support)", "metadata.file_type().is_dir()",
            "metadata.file_type().is_symlink()", "metadata.uid() != 0", "metadata.gid() != 0",
            "metadata.nlink() != support_nlink", "mode() & 0o7777 != 0o700",
            "metadata.dev() != expected_device", "metadata.ino() != support_inode",
            "metadata.len() != support_length", "metadata.st_flags() != 0",
            "fs::read_dir(support)?", "controller-binary.sha256", "controller-identity.log",
            "expected.sort_unstable();", "if names != expected",
            "require_path_absent(pending", "require_exact_retained_root_controller_set_file(",
            "let children_after = read_children()?;", "let after = read_support()?;",
            "children_before != children_after", "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.nlink() != after.nlink()",
            "before.len() != after.len()", "before.permissions().mode() != after.permissions().mode()",
            "before.st_flags() != after.st_flags()",
        ]
        let sudoTokens = [
            "child.parent() != Some(support)", "expected_support", "controller-binary.sha256",
            "controller-identity.log", "sudo_stat(pending)?.is_some()",
            #"sudo_output(&["-n", "/bin/ls", "-1A", support_text])?"#,
            "listing.stderr.is_empty()", "listing.stdout != expected_listing.as_bytes()",
            "let before = read_topology()?;", "if before", "expected_support",
            "expected_controller", "expected_pin", "expected_journal",
            #"sudo_output(&["-n", "/usr/bin/shasum", "-a", "256", controller_text])?"#,
            "sudo_root_sealed_file(pin, pin_length)?", "sudo_root_sealed_file(journal, journal_length)?",
            "if read_topology()? != before",
        ]
        let sudoFormatTokens = [
            "let expected_support = format!(",
            #""0:0:{support_nlink}:0700:Directory:{expected_device}:{support_inode}:{support_length}:0""#,
            "let expected_controller = format!(",
            #""0:0:1:0500:Regular File:{expected_device}:{controller_inode}:{controller_length}:0""#,
            "let expected_pin =", #""0:0:1:0400:Regular File:{expected_device}:{pin_inode}:{pin_length}:0""#,
            "let expected_journal = format!(",
            #""0:0:1:0400:Regular File:{expected_device}:{journal_inode}:{journal_length}:0""#,
        ]
        let parentTokens = [
            "let before = fs::symlink_metadata(parent)?;", "let expected_nlink = if current.is_some()",
            "RETAINED_ROOT_V7_TRANSACTION_PARENT_NLINK + 1",
            "metadata.file_type().is_dir()", "!metadata.file_type().is_symlink()",
            "metadata.uid() == 0", "metadata.gid() == 0", "metadata.nlink() == expected_nlink",
            "mode() & 0o7777 == 0o700", "metadata.dev() == RETAINED_ROOT_V7_TRANSACTION_PARENT_DEVICE",
            "metadata.ino() == RETAINED_ROOT_V7_TRANSACTION_PARENT_INODE",
            "RETAINED_ROOT_V7_TRANSACTION_PARENT_LENGTH", "+ if current.is_some() { 32 } else { 0 }",
            "metadata.st_flags() == 0", "!metadata_is_exact(&before)",
            "current.parent() != Some(parent) || current == retained",
            "if actual != expected", "let after = fs::symlink_metadata(parent)?;",
            "!metadata_is_exact(&after)", "before.dev() != after.dev()", "before.ino() != after.ino()",
            "before.nlink() != after.nlink()", "before.len() != after.len()",
            "before.st_flags() != after.st_flags()",
        ]
        let tombstoneTokens = [
            "verified_data_volume_device()?", "require_exact_root_directory_identity(",
            "transaction", "data_volume_device", "RECOVERY_RETRY_2_ROOT_TRANSACTION_INODE", "5",
            "require_exact_root_transaction_children(transaction)?;", "root_driver_layout(RECOVERY_RETRY_2_NONCE)?",
            "layout.root != transaction",
            "PRODUCT_DRIVER_CANONICAL_PATH", "layout.hold", "layout.prior", "layout.abandoned",
            "!failed.file_type().is_dir()", "failed.file_type().is_symlink()",
            "failed.uid() != 0", "failed.gid() != 0", "failed.nlink() != 3",
            "mode() & 0o7777 != 0o755", "failed.dev() != data_volume_device",
            "failed.ino() != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE", "failed.st_flags() != 0",
            "verify_root_production_driver(&layout.failed)?;", "read_root_driver_state(&layout)?",
            "prior.present", "hold.device != data_volume_device",
            "hold.inode != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE",
            "root_node_identity(&layout.failed)?.device != hold.device",
            "root_node_identity(&layout.failed)?.inode != hold.inode",
            "require_exact_root_regular_identity(", "&layout.state", "data_volume_device",
            "RECOVERY_RETRY_2_ROOT_STATE_INODE", "0o600", "RECOVERY_RETRY_2_ROOT_STATE.len() as u64",
            "RECOVERY_RETRY_2_ROOT_STATE_SHA256", "read_root_bounded_utf8(&layout.state, 4_096)?",
            "RECOVERY_RETRY_2_ROOT_STATE",
            "require_exact_root_regular_identity(", "&layout.package", "data_volume_device",
            "RECOVERY_RETRY_2_ROOT_PACKAGE_INODE", "0o400", "54_515",
            "EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256", "verify_root_production_package(&layout.package)?;",
            "require_no_extended_attributes_root(transaction)?;", "require_no_openers_root(transaction)?;",
            "require_exact_root_directory_identity(", "transaction", "data_volume_device",
            "RECOVERY_RETRY_2_ROOT_TRANSACTION_INODE", "5", "require_exact_root_transaction_children(transaction)?;",
        ]
        let topologyTokens = [
            "expected_sets.is_empty()", "fs::read_dir(support)?", "!entry.file_type()?.is_file()",
            "matches_expected", "expected_nlink = 2 + actual.len() as u64",
            "expected_length = 64 + 32 * actual.len() as u64", "metadata.file_type().is_dir()",
            "!metadata.file_type().is_symlink()", "metadata.uid() == 0", "metadata.gid() == 0",
            "metadata.nlink() == expected_nlink", "mode() & 0o7777 == 0o700",
            "metadata.dev() == RETAINED_ROOT_V7_TRANSACTION_PARENT_DEVICE",
            "metadata.len() == expected_length", "metadata.st_flags() == 0",
            "!metadata_is_exact(&before)", "!metadata_is_exact(&after)",
            "before.dev() != after.dev()", "before.ino() != after.ino()",
            "before.nlink() != after.nlink()", "before.len() != after.len()",
        ]
        let publishTokens = [
            "geteuid()", "env::current_exe()? != Path::new(ROOT_V7_CONTROLLER_PENDING)",
            "require_retained_root_normal_v1()?;", "require_retained_root_recovery_v1()?;",
            "require_retained_root_recovery_v2()?;", "require_exact_retry_3_transaction_parent_names(None)?;",
            "require_retained_retry_2_root_tombstone(true)?;", "stable_controller_binary_identity(",
            "Path::new(ROOT_V7_CONTROLLER_PENDING)", ".custom_flags(O_NOFOLLOW)",
            "let before = descriptor.metadata()?;", "descriptor.sync_all()?;", "require_path_absent(Path::new(ROOT_V7_CONTROLLER)",
            "rename_exclusive(", "fsync_parent(Path::new(ROOT_V7_CONTROLLER))?;", "let after = descriptor.metadata()?;",
            "stable_controller_binary_identity(", "Path::new(ROOT_V7_CONTROLLER)", "pending != published",
            "before.dev() != after.dev()", "before.ino() != after.ino()", "before.len() != after.len()",
            "require_root_v2_support_topology",
            "ROOT_V7_CONTROLLER_V2_PUBLISHED",
        ]
        let prepareTokens = [
            "require_retry_3_root_operation_trust(None, true)?;",
            "require_current_retry_v7_layout(", "RetryV7PointerExpectation::Absent",
            "fs::create_dir(&layout.root)?;", "finish_retry_3_root_operation(&layout, operation, true)?;",
        ]
        let retainedFileTokens = [
            ".custom_flags(O_NOFOLLOW)", "let before = descriptor.metadata()?;",
            "let named_before = fs::symlink_metadata(path)?;", "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()", "metadata.uid() == 0", "metadata.gid() == 0",
            "metadata.nlink() == 1", "mode() & 0o7777 == expected_mode",
            "metadata.dev() == expected_device", "metadata.ino() == expected_inode",
            "metadata.len() == expected_length", "metadata.st_flags() == 0",
            "!metadata_is_exact(&before)", "!metadata_is_exact(&named_before)",
            "before.dev() != named_before.dev()", "before.ino() != named_before.ino()",
            "before.len() != named_before.len()", ".take(expected_length + 1)",
            "sha256_bytes(&bytes)? != expected_sha256",
            "expected_bytes.is_some_and", "let after = descriptor.metadata()?;",
            "let named_after = fs::symlink_metadata(path)?;", "!metadata_is_exact(&after)",
            "!metadata_is_exact(&named_after)", "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.len() != after.len()",
            "before.dev() != named_after.dev()", "before.ino() != named_after.ino()",
            "before.len() != named_after.len()",
        ]
        let recoveryV1FileTokens = [
            ".custom_flags(O_NOFOLLOW)", "let before = descriptor.metadata()?;",
            "let named_before = fs::symlink_metadata(path)?;", "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()", "metadata.uid() == 0",
            "metadata.gid() == 0", "metadata.nlink() == 1",
            "mode() & 0o7777 == expected_mode", "metadata.dev() == RETAINED_ROOT_V7_RECOVERY_V1_DEVICE",
            "metadata.ino() == expected_inode", "metadata.len() == expected_length", "metadata.st_flags() == 0",
            "!metadata_is_exact(&before)", "!metadata_is_exact(&named_before)",
            "before.dev() != named_before.dev()", "before.ino() != named_before.ino()",
            "before.len() != named_before.len()",
            ".take(expected_length + 1)", "sha256_bytes(&bytes)? != expected_sha256",
            "bytes != expected_bytes", "let after = descriptor.metadata()?;",
            "let named_after = fs::symlink_metadata(path)?;", "!metadata_is_exact(&after)",
            "!metadata_is_exact(&named_after)", "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.len() != after.len()",
            "before.dev() != named_after.dev()", "before.ino() != named_after.ino()",
            "before.len() != named_after.len()",
        ]
        let recoveryV1DirectTokens = [
            "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_DIRECTORY", "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PIN", "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_IDENTITY_JOURNAL",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PENDING", "metadata.file_type().is_dir()",
            "metadata.file_type().is_symlink()", "metadata.uid() != 0", "metadata.gid() != 0",
            "metadata.nlink() != RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK", "mode() & 0o7777 != 0o700",
            "metadata.dev() != RETAINED_ROOT_V7_RECOVERY_V1_DEVICE", "metadata.ino() != RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE",
            "metadata.len() != RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_LENGTH", "metadata.st_flags() != 0",
            "fs::read_dir(support)?", "if names", "!= [", "controller-binary.sha256",
            "controller-identity.log", "require_path_absent(", "require_exact_retained_root_recovery_v1_file(",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_SHA256", "RETAINED_ROOT_V7_RECOVERY_V1_PIN_SHA256",
            "Some(RETAINED_ROOT_V7_RECOVERY_V1_PIN.as_bytes())", "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_SHA256",
            "Some(RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL.as_bytes())", "let children_after = read_children()?;",
            "children_before != children_after", "before.dev() != after.dev()",
            "before.ino() != after.ino()", "before.nlink() != after.nlink()",
            "before.len() != after.len()", "before.permissions().mode() != after.permissions().mode()",
            "before.st_flags() != after.st_flags()",
        ]
        let recoveryV1SudoStatTokens = [
            #"%u:%g:%l:%Mp%Lp:%HT:%d:%i:%z:%f"#, "require_output_success",
            "!output.stderr.is_empty()", ".strip_suffix('\\n')", "!line.is_empty() && !line.contains('\\n')",
        ]
        let recoveryV1SudoTokens = [
            #"require_pinned_system_binary(Path::new("/bin/ls"), 0o755, EXPECTED_LS_SHA256)?;"#,
            "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_DIRECTORY", "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PIN", "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_IDENTITY_JOURNAL",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_PENDING", "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK",
            "RETAINED_ROOT_V7_RECOVERY_V1_DEVICE", "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE",
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_INODE", "RETAINED_ROOT_V7_RECOVERY_V1_PIN_INODE",
            "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_INODE", "sudo_stat(pending)?.is_some()",
            "listing.stdout\n                    != b\"controller-binary.sha256\\ncontroller-identity.log\\nopensteamer-v7-recovery-controller\\n\"",
            "let before = read_topology()?;", "if before", "expected_support.clone()",
            "expected_controller.clone()", "expected_pin.clone()", "expected_journal.clone()",
            "controller_hash", "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_SHA256",
            "sudo_root_sealed_file(pin", "RETAINED_ROOT_V7_RECOVERY_V1_PIN_SHA256",
            "sudo_root_sealed_file(", "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_SHA256",
            "let after = read_topology()?;", "after != before",
        ]
        let recoveryV1SudoFormatTokens = [
            "let expected_support = format!(", #""0:0:{}:0700:Directory:{}:{}:{}:0""#,
            "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_NLINK", "RETAINED_ROOT_V7_RECOVERY_V1_DEVICE",
            "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE", "RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_LENGTH",
            "let expected_controller = format!(", #""0:0:1:0500:Regular File:{}:{}:{}:0""#,
            "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_INODE", "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER_LENGTH",
            "let expected_pin = format!(", #""0:0:1:0400:Regular File:{}:{}:{}:0""#,
            "RETAINED_ROOT_V7_RECOVERY_V1_PIN_INODE", "RETAINED_ROOT_V7_RECOVERY_V1_PIN_LENGTH",
            "let expected_journal = format!(", #""0:0:1:0400:Regular File:{}:{}:{}:0""#,
            "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_INODE", "RETAINED_ROOT_V7_RECOVERY_V1_JOURNAL_LENGTH",
        ]
        let normalV1WrapperTokens = [
            #""normal-v1""#, "RETAINED_ROOT_V7_V1_SUPPORT_DIRECTORY", "RETAINED_ROOT_V7_V1_CONTROLLER",
            "RETAINED_ROOT_V7_V1_CONTROLLER_PENDING", "RETAINED_ROOT_V7_V1_CONTROLLER_PIN",
            "RETAINED_ROOT_V7_V1_CONTROLLER_IDENTITY_JOURNAL", "RETAINED_ROOT_V7_V1_DEVICE",
            "RETAINED_ROOT_V7_V1_SUPPORT_INODE", "RETAINED_ROOT_V7_V1_SUPPORT_NLINK",
            "RETAINED_ROOT_V7_V1_SUPPORT_LENGTH", "RETAINED_ROOT_V7_V1_CONTROLLER_INODE",
            "RETAINED_ROOT_V7_V1_CONTROLLER_LENGTH",
            "RETAINED_ROOT_V7_V1_CONTROLLER_SHA256", "RETAINED_ROOT_V7_V1_PIN_INODE",
            "RETAINED_ROOT_V7_V1_PIN_SHA256", "RETAINED_ROOT_V7_V1_PIN",
            "RETAINED_ROOT_V7_V1_JOURNAL_INODE", "RETAINED_ROOT_V7_V1_JOURNAL_LENGTH",
            "RETAINED_ROOT_V7_V1_JOURNAL_SHA256",
            "RETAINED_ROOT_V7_V1_JOURNAL",
        ]
        let recoveryV2WrapperTokens = [
            #""recovery-v2""#, "ROOT_V7_RECOVERY_SUPPORT_DIRECTORY", "ROOT_V7_RECOVERY_CONTROLLER",
            "ROOT_V7_RECOVERY_CONTROLLER_PENDING", "ROOT_V7_RECOVERY_CONTROLLER_PIN",
            "ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL", "RETAINED_ROOT_V7_RECOVERY_V2_DEVICE",
            "RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_INODE", "RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_NLINK",
            "RETAINED_ROOT_V7_RECOVERY_V2_SUPPORT_LENGTH", "RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_INODE",
            "RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_LENGTH",
            "RETAINED_ROOT_V7_RECOVERY_V2_CONTROLLER_SHA256", "RETAINED_ROOT_V7_RECOVERY_V2_PIN_INODE",
            "RETAINED_ROOT_V7_RECOVERY_V2_PIN_SHA256", "RETAINED_ROOT_V7_RECOVERY_V2_PIN",
            "RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL_INODE", "RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL_LENGTH",
            "RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL_SHA256",
            "RETAINED_ROOT_V7_RECOVERY_V2_JOURNAL",
        ]
        let normalV1SudoOnlyTokens = ["RETAINED_ROOT_V7_V1_PIN_LENGTH"]
        let recoveryV2SudoOnlyTokens = ["RETAINED_ROOT_V7_RECOVERY_V2_PIN_LENGTH"]
        let sudoSealedTokens = [
            #"%u:%g:%l:%Lp:%HT:%d:%i:%z"#, "fields.len() != 8", #"fields[3] != "400""#,
            #"fields[4] != "Regular File""#, "length == 0 || length > maximum",
            "let before = read_identity()?;", #"sudo_output(&["-n", "/bin/cat", path_text(path)?])?"#,
            "output.stdout.len() as u64 > maximum", "let after = read_identity()?;", "before != after",
        ]
        let sudoParentTokens = [
            #"require_pinned_system_binary(Path::new("/bin/ls"), 0o755, EXPECTED_LS_SHA256)?;"#,
            "RETAINED_ROOT_V7_TRANSACTION_PARENT_NLINK", "if current.is_some() { 1 } else { 0 }",
            "RETAINED_ROOT_V7_TRANSACTION_PARENT_LENGTH", "if current.is_some() { 32 } else { 0 }",
            "let expected_parent = format!(", #""0:0:{expected_nlink}:0700:Directory:{}:{}:{expected_length}:0""#,
            "RETAINED_ROOT_V7_TRANSACTION_PARENT_DEVICE", "RETAINED_ROOT_V7_TRANSACTION_PARENT_INODE",
            "current.parent() != Some(parent) || current == retained", "expected_names.sort_unstable();",
            "let parent_stat = sudo_retained_root_recovery_v1_stat(parent)?;", "parent_stat != expected_parent",
            #"sudo_output(&["#, #""/bin/ls""#, "ROOT_V7_TRANSACTION_PARENT",
            "require_output_success(&listing", "!listing.stderr.is_empty()",
            "listing.stdout != expected_listing.as_bytes()", "let before = read()?;", "let after = read()?;",
            "before != after",
        ]
        let repairTokens = [
            "expected.is_empty()", "expected.len() > 1_024", "!expected.ends_with('\\n')",
            "!metadata.file_type().is_file()", "metadata.file_type().is_symlink()",
            "metadata.uid() != 0", "metadata.gid() != 0", "metadata.nlink() != 1",
            "mode() & 0o7777, 0o400 | 0o600", "metadata.len() > expected.len() as u64",
            "metadata.st_flags() != 0",
            ".read(true)", ".write(true)", ".custom_flags(O_NOFOLLOW)",
            "let before = file.metadata()?;", "let named_before = fs::symlink_metadata(path)?;",
            "before.dev() != named_before.dev()", "before.ino() != named_before.ino()",
            "before.len() != named_before.len()",
            ".take(expected.len() as u64 + 1)", "expected.as_bytes().starts_with(&bytes)",
            "if bytes != expected.as_bytes()",
            "file.set_len(0)?;", "file.seek(SeekFrom::Start(0))?;", "file.write_all(expected.as_bytes())?;",
            "file.set_permissions(fs::Permissions::from_mode(0o400))?;", "file.sync_all()?;",
            "fsync_parent(path)?;", "read_root_sealed_utf8(path, 1_024)? != expected",
        ]
        let bootstrapTokens = [
            "geteuid()", "env::current_exe()? != Path::new(ROOT_V7_CONTROLLER)",
            "require_retained_root_normal_v1()?;", "require_retained_root_recovery_v1()?;",
            "require_retained_root_recovery_v2()?;", "require_exact_retry_3_transaction_parent_names(None)?;",
            "require_retained_retry_2_root_tombstone(true)?;", "require_root_v2_support_topology",
            "stable_controller_binary_identity(", "create_or_repair_root_recovery_sealed(",
            "ROOT_V7_CONTROLLER_PIN", "create_or_repair_root_recovery_sealed(",
            "ROOT_V7_CONTROLLER_IDENTITY_JOURNAL", "read_root_controller_identity_records()? != identity",
            "require_root_v2_support_topology", "require_retained_root_normal_v1()?;",
            "require_retained_root_recovery_v1()?;", "require_retained_root_recovery_v2()?;",
            "require_exact_retry_3_transaction_parent_names(None)?;", "require_retained_retry_2_root_tombstone(true)?;",
            "ROOT_V7_CONTROLLER_V2_IDENTITY_SEALED",
        ]
        let uidPrepareTokens = [
            "require_retained_root_normal_v1_via_sudo()?;", "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;", "require_retry_3_transaction_parent_via_sudo(None)?;",
            "attest_retry_2_root_safe_state_via_sudo()?;", "let before = verified_uid501_controller_identity()?;",
            "ROOT_V7_CONTROLLER_PENDING", "stage exact normal root controller V2",
            "hash staged normal root controller V2", "!= before.sha256", "ROOT_V7_CONTROLLER_PUBLISH_MODE",
            "ROOT_V7_CONTROLLER_V2_PUBLISHED", "ROOT_V7_CONTROLLER", "!= before.sha256",
            #"Some("0:0:1:500:Regular File")"#, "ROOT_V7_CONTROLLER_BOOTSTRAP_MODE",
            "ROOT_V7_CONTROLLER_V2_IDENTITY_SEALED", "let after = verified_uid501_controller_identity()?;",
            "before != after", "read_root_controller_identity_records_via_sudo()?",
            "sealed.sha256 != after.sha256 || sealed.length != after.length",
            "require_retained_root_normal_v1_via_sudo()?;", "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;", "require_retry_3_transaction_parent_via_sudo(None)?;",
            "attest_retry_2_root_safe_state_via_sudo()?;",
        ]
        let uidStageTokens = [
            "let output = sudo_output(&[", #""-n""#, #""/usr/bin/install""#,
            #""-o""#, #""root""#, #""-g""#, #""wheel""#, #""-m""#, #""0500""#,
            "path_text(&current)?", "ROOT_V7_CONTROLLER_PENDING", "])?;",
            #"require_output_success(&output, "stage exact normal root controller V2")?;"#,
        ]
        let uidRestoreTokens = [
            "require_retained_root_normal_v1_via_sudo()?;", "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;", "require_current_retry_v7_layout(",
            "Some(&layout.nonce)", "pointer_expectation", "expected_root == Path::new(RECOVERY_RETRY_2_ROOT_TRANSACTION)",
            "require_retry_3_transaction_parent_via_sudo(Some(&expected_root))?;",
            "let before = verified_uid501_controller_identity()?;", "hash existing normal root controller V2",
            "!= before.sha256", #"Some("0:0:1:500:Regular File")"#,
            "sudo_stat(Path::new(ROOT_V7_CONTROLLER_PENDING))?.is_some()", "read_root_controller_identity_records_via_sudo()?",
            "sealed.sha256 != before.sha256 || sealed.length != before.length",
            "require_retained_root_normal_v1_via_sudo()?;", "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;", "require_retry_3_transaction_parent_via_sudo(Some(&expected_root))?;",
            "require_current_retry_v7_layout(",
        ]
        let finishTokens = [
            "require_retry_3_root_operation_trust(", "Some(&layout.root)",
            "operation.is_ok() && success_requires_product_absent", "match (operation, post)",
            "(Ok(value), Ok(())) => Ok(value)", "(Err(primary), Ok(())) => Err(primary)",
            "(Ok(_), Err(post)) => Err(post)", "(Err(primary), Err(post))",
        ]
        let verifyRootControllerTokens = [
            "geteuid()", "env::current_exe()?", "ROOT_V7_CONTROLLER",
            "require_retained_root_normal_v1()?;", "require_retained_root_recovery_v1()?;",
            "require_retained_root_recovery_v2()?;", "require_root_v2_support_topology",
            "stable_controller_binary_identity(&executable, 0, Some(0), 0o500)?",
            "read_root_controller_identity_records()?", "require_root_controller_identity_binding(&actual, &sealed)?;",
            "require_retained_retry_2_root_tombstone(false)?;",
            "require_retained_root_normal_v1()?;", "require_retained_root_recovery_v1()?;",
            "require_retained_root_recovery_v2()?;", "require_root_v2_support_topology",
        ]
        let rootTrustTokens = [
            "verify_root_controller_identity()?;", "require_exact_retry_3_transaction_parent_names(current)?;",
            "require_retained_retry_2_root_tombstone(require_product_absent)?;",
        ]
        let rootDirectoryTokens = [
            "fs::symlink_metadata(path)?", "metadata.file_type().is_dir()", "metadata.file_type().is_symlink()",
            "metadata.uid() != 0", "metadata.gid() != 0", "mode() & 0o7777 != 0o700",
            "metadata.dev() != expected_device", "metadata.ino() != expected_inode",
            "metadata.nlink() != expected_nlink", "metadata.st_flags() != 0",
        ]
        let rootRegularTokens = [
            "require_root_regular(path, expected_mode)?;", "let before = fs::symlink_metadata(path)?;",
            "before.dev() != expected_device", "before.ino() != expected_inode", "before.len() != expected_length",
            "before.st_flags() != 0", "sha256(path)? != expected_sha256", "let after = fs::symlink_metadata(path)?;",
            "before.dev() != after.dev()", "before.ino() != after.ino()", "before.len() != after.len()",
            "before.nlink() != after.nlink()",
        ]
        let rootChildrenTokens = [
            "let before = fs::symlink_metadata(root)?;", "for entry in fs::read_dir(root)?",
            "entry.path() != root.join(&name)", "if names", "!= [",
            "OpensteamerVirtualMicrophone-v7.pkg", "failed-v7-product-driver.node", "state.txt",
            "let after = fs::symlink_metadata(root)?;",
            "before.dev() != after.dev()", "before.ino() != after.ino()", "before.nlink() != after.nlink()",
            "before.len() != after.len()",
        ]
        let recoveryIdentityTokens = [
            "geteuid()", "env::current_exe()?", "Path::new(ROOT_V7_RECOVERY_CONTROLLER)",
            "stable_controller_binary_identity(&executable, 0, Some(0), 0o500)?",
            "ROOT_V7_RECOVERY_CONTROLLER_PIN", "ROOT_V7_RECOVERY_CONTROLLER_IDENTITY_JOURNAL",
            "OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V2", "require_root_controller_identity_binding(&actual, &sealed)?;",
        ]
        let rootAttestTokens = [
            "require_retained_root_normal_v1()?;", "require_retained_root_recovery_v1()?;",
            "require_retained_root_recovery_v2()?;", "verify_root_recovery_controller_identity()?;",
            "verified_data_volume_device()?", "RECOVERY_RETRY_2_ROOT_CONTROLLER_SHA256",
            "OPENSTEAMER_V7_CONTROLLER_IDENTITY_V1", "require_root_controller_identity_binding(&old_controller, &old_sealed)?;",
            "require_exact_root_directory_identity(", "require_exact_root_transaction_children(transaction)?;",
            "root_driver_layout(RECOVERY_RETRY_2_NONCE)?", "layout.root != transaction",
            "PRODUCT_DRIVER_CANONICAL_PATH", "layout.hold", "layout.prior", "layout.abandoned",
            "!failed.file_type().is_dir()", "failed.file_type().is_symlink()",
            "failed.uid() != 0", "failed.gid() != 0", "mode() & 0o7777 != 0o755",
            "failed.dev() != data_volume_device", "failed.ino() != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE",
            "failed.nlink() != 3", "failed.st_flags() != 0",
            "verify_root_production_driver(&layout.failed)?;", "read_root_driver_state(&layout)?",
            "prior.present", "hold.device != data_volume_device",
            "hold.inode != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE",
            "root_node_identity(&layout.failed)?.device != hold.device",
            "root_node_identity(&layout.failed)?.inode != hold.inode",
            "RECOVERY_RETRY_2_ROOT_STATE_INODE",
            "RECOVERY_RETRY_2_ROOT_STATE_SHA256", "read_root_bounded_utf8(&layout.state, 4_096)? != RECOVERY_RETRY_2_ROOT_STATE",
            "RECOVERY_RETRY_2_ROOT_PACKAGE_INODE", "verify_root_production_package(&layout.package)?;",
            "require_no_extended_attributes_root(transaction)?;", "require_no_openers_root(transaction)?;",
            "read_core_audio_generation_root()?", "RECOVERY_RETRY_2_COREAUDIO_PID",
            "require_exact_root_directory_identity(", "require_exact_root_transaction_children(transaction)?;",
            "require_retained_root_normal_v1()?;", "require_retained_root_recovery_v1()?;",
            "require_retained_root_recovery_v2()?;", "ROOT_V7_RETRY_2_SAFE_STATE",
        ]
        let attestSudoTokens = [
            "require_retained_root_normal_v1_via_sudo()?;", "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;", "ROOT_V7_RECOVERY_CONTROLLER",
            "ROOT_V7_RECOVERY_ATTEST_MODE", "require_output_success", "ROOT_V7_RETRY_2_SAFE_STATE",
            "output.stdout != expected.as_bytes()", "!output.stderr.is_empty()",
            "require_retained_root_normal_v1_via_sudo()?;", "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;",
        ]
        let releaseSystemHashTokens = [
            #""pinned coreaudiod SHA-256""#, "EXPECTED_COREAUDIOD_SHA256", "64,",
            #""pinned kill SHA-256""#, "EXPECTED_KILL_SHA256", "64",
            #""pinned launchctl SHA-256""#, "EXPECTED_LAUNCHCTL_SHA256", "64,",
            #""pinned ps SHA-256""#, "EXPECTED_PS_SHA256", "64",
            #""pinned ls SHA-256""#, "EXPECTED_LS_SHA256", "64",
            #""pinned system_profiler SHA-256""#, "EXPECTED_SYSTEM_PROFILER_SHA256", "64,",
            #""pinned lsof SHA-256""#, "EXPECTED_LSOF_SHA256", "64",
            #""pinned xattr SHA-256""#, "EXPECTED_XATTR_SHA256", "64",
        ]
        let rootAdmissionTokens = [
            "authenticate_v7_privileged_boundary()?;", "require_retained_root_normal_v1_via_sudo()?;",
            "require_retained_root_recovery_v1_via_sudo()?;", "require_retained_root_recovery_v2_via_sudo()?;",
            "require_retry_3_transaction_parent_via_sudo(None)?;", "sudo_stat(Path::new(ROOT_V7_SUPPORT_DIRECTORY))?.is_some()",
            "attest_retry_2_root_safe_state_via_sudo()?;", "require_retained_root_normal_v1_via_sudo()?;",
            "require_retained_root_recovery_v1_via_sudo()?;", "require_retained_root_recovery_v2_via_sudo()?;",
            "require_retry_3_transaction_parent_via_sudo(None)?;", "sudo_stat(Path::new(ROOT_V7_SUPPORT_DIRECTORY))?.is_some()",
        ]
        let compactPublisher = publisher.filter { !$0.isWhitespace }
        let compactBootstrap = bootstrap.filter { !$0.isWhitespace }
        let publishPendingTopology = #"require_root_v2_support_topology(&[&[".opensteamer-v7-controller.pending"]])?;"#
        let publishFinalTopology = #"require_root_v2_support_topology(&[&["opensteamer-v7-controller"]])?;"#
        let bootstrapEntryTopology = #"require_root_v2_support_topology(&[&["opensteamer-v7-controller"],&["controller-binary.sha256","opensteamer-v7-controller"],&["controller-binary.sha256","controller-identity.log","opensteamer-v7-controller",],])?;"#
        let bootstrapAfterPinTopology = #"require_root_v2_support_topology(&[&["controller-binary.sha256","opensteamer-v7-controller"],&["controller-binary.sha256","controller-identity.log","opensteamer-v7-controller",],])?;"#
        let bootstrapFinalTopology = #"require_root_v2_support_topology(&[&["controller-binary.sha256","controller-identity.log","opensteamer-v7-controller",]])?;"#
        let publisherProgressTokens = [
            publishPendingTopology, "stable_controller_binary_identity(Path::new(ROOT_V7_CONTROLLER_PENDING)",
            "rename_exclusive(Path::new(ROOT_V7_CONTROLLER_PENDING),Path::new(ROOT_V7_CONTROLLER),)?;",
            "stable_controller_binary_identity(Path::new(ROOT_V7_CONTROLLER)", publishFinalTopology,
        ]
        let bootstrapProgressTokens = [
            bootstrapEntryTopology, "create_or_repair_root_recovery_sealed(Path::new(ROOT_V7_CONTROLLER_PIN)",
            bootstrapAfterPinTopology,
            "create_or_repair_root_recovery_sealed(Path::new(ROOT_V7_CONTROLLER_IDENTITY_JOURNAL)",
            "read_root_controller_identity_records()?!=identity", bootstrapFinalTopology,
        ]
        let psExact = #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)?;"#
        let psWrongRejected = #"require_pinned_system_binary(Path::new("/bin/ps"), 0o755, EXPECTED_PS_SHA256).is_ok()"#
        let coreaudiodCall = "require_pinned_system_binary(\n            Path::new(PINNED_COREAUDIOD),\n            0o755,\n            EXPECTED_COREAUDIOD_SHA256,\n        )?;"
        let launchctlCall = "require_pinned_system_binary(\n            Path::new(\"/bin/launchctl\"),\n            0o755,\n            EXPECTED_LAUNCHCTL_SHA256,\n        )?;"
        let lsofCall = "require_pinned_system_binary(\n            Path::new(\"/usr/sbin/lsof\"),\n            0o755,\n            EXPECTED_LSOF_SHA256,\n        )?;"
        let xattrCall = "require_pinned_system_binary(\n            Path::new(\"/usr/bin/xattr\"),\n            0o755,\n            EXPECTED_XATTR_SHA256,\n        )?;"
        let profilerCall = "require_pinned_system_binary(\n            Path::new(\"/usr/sbin/system_profiler\"),\n            0o755,\n            EXPECTED_SYSTEM_PROFILER_SHA256,\n        )?;"
        let killCall = #"require_pinned_system_binary(Path::new("/bin/kill"), 0o755, EXPECTED_KILL_SHA256)?;"#
        let lsCall = #"require_pinned_system_binary(Path::new("/bin/ls"), 0o755, EXPECTED_LS_SHA256)?;"#
        return exactPins.allSatisfy(controller.contains)
            && scopedRootDeclarations.allSatisfy(controller.contains)
            && containsOrdered(directTokens, in: direct)
            && containsOrdered(sudoTokens, in: sudo)
            && containsOrdered(sudoFormatTokens, in: sudo)
            && containsOrdered(parentTokens, in: parent)
            && containsOrdered(tombstoneTokens, in: tombstone)
            && containsOrdered(topologyTokens, in: topology)
            && containsOrdered(repairTokens, in: repair)
            && containsOrdered(publishTokens, in: publisher)
            && containsOrdered(retainedFileTokens, in: retainedFile)
            && containsOrdered(recoveryV1FileTokens, in: recoveryV1File)
            && containsOrdered(recoveryV1DirectTokens, in: recoveryV1Direct)
            && containsOrdered(recoveryV1SudoStatTokens, in: recoveryV1SudoStat)
            && containsOrdered(recoveryV1SudoTokens, in: recoveryV1Sudo)
            && containsOrdered(recoveryV1SudoFormatTokens, in: recoveryV1Sudo)
            && containsOrdered(normalV1WrapperTokens, in: normalV1Direct)
            && containsOrdered(recoveryV2WrapperTokens, in: recoveryV2Direct)
            && containsOrdered(normalV1WrapperTokens, in: normalV1Sudo)
            && containsOrdered(recoveryV2WrapperTokens, in: recoveryV2Sudo)
            && normalV1SudoOnlyTokens.allSatisfy(normalV1Sudo.contains)
            && recoveryV2SudoOnlyTokens.allSatisfy(recoveryV2Sudo.contains)
            && containsOrdered(sudoSealedTokens, in: sudoSealed)
            && containsOrdered(sudoParentTokens, in: sudoParent)
            && containsOrdered(bootstrapTokens, in: bootstrap)
            && containsOrdered(uidPrepareTokens, in: uidPrepare)
            && containsOrdered(uidStageTokens, in: uidPrepare)
            && containsOrdered(uidRestoreTokens, in: uidRestore)
            && containsOrdered(verifyRootControllerTokens, in: verifyRootController)
            && containsOrdered(rootTrustTokens, in: rootTrust)
            && containsOrdered(finishTokens, in: finish)
            && containsOrdered(rootDirectoryTokens, in: rootDirectoryIdentity)
            && containsOrdered(rootRegularTokens, in: rootRegularIdentity)
            && containsOrdered(rootChildrenTokens, in: rootChildren)
            && containsOrdered(recoveryIdentityTokens, in: recoveryIdentity)
            && containsOrdered(rootAttestTokens, in: rootAttest)
            && containsOrdered(attestSudoTokens, in: attestSudo)
            && containsOrdered(rootAdmissionTokens, in: rootAdmission)
            && containsOrdered(publisherProgressTokens, in: compactPublisher)
            && containsOrdered(bootstrapProgressTokens, in: compactBootstrap)
            && rootAdmission.components(separatedBy: "require_retry_3_transaction_parent_via_sudo(None)?;").count - 1 == 2
            && rootAdmission.components(separatedBy: "ROOT_V7_SUPPORT_DIRECTORY").count - 1 == 2
            && rootAdmission.contains("attest_retry_2_root_safe_state_via_sudo()?;")
            && containsOrdered(prepareTokens, in: prepare)
            && publish.contains("finish_retry_3_root_operation(&layout, operation, false)?;")
            && rollback.contains("finish_retry_3_root_operation(&layout, operation, true)?;")
            && abandon.contains("finish_retry_3_root_operation(&layout, operation, true)?;")
            && commandEnum.contains("RootControllerPublish")
            && commandEnum.contains("RootControllerBootstrap")
            && parser.contains("ROOT_V7_CONTROLLER_PUBLISH_MODE")
            && parser.contains("Ok(V7Command::RootControllerPublish)")
            && parser.contains("ROOT_V7_CONTROLLER_BOOTSTRAP_MODE")
            && parser.contains("Ok(V7Command::RootControllerBootstrap)")
            && main.contains("V7Command::RootControllerPublish => publish_root_controller()")
            && main.contains("V7Command::RootControllerBootstrap => bootstrap_root_controller_identity()")
            && containsOrdered(
                ["paired-v7 preflight transaction lock", "require_retry_3_root_admission_via_sudo()?;"],
                in: main
            )
            && containsOrdered(releaseSystemHashTokens, in: releasePins)
            && controller.components(separatedBy: psExact).count - 1 == 2
            && controller.contains(psWrongRejected)
            && controller.components(separatedBy: coreaudiodCall).count - 1 == 1
            && controller.components(separatedBy: launchctlCall).count - 1 == 2
            && controller.components(separatedBy: lsofCall).count - 1 == 2
            && controller.components(separatedBy: xattrCall).count - 1 == 1
            && controller.components(separatedBy: profilerCall).count - 1 == 1
            && controller.components(separatedBy: killCall).count - 1 == 1
            && controller.components(separatedBy: lsCall).count - 1 == 3
            && pinnedBinary.contains("metadata.permissions().mode() & 0o7777 == expected_mode")
            && stableIdentity.contains("metadata.permissions().mode() & 0o7777 == expected_mode")
            && !controller.contains("RootRecoveryControllerPublish")
            && !controller.contains("RootRecoveryControllerBootstrap")
            && !controller.contains("ROOT_V7_RECOVERY_CONTROLLER_PUBLISH_MODE")
            && !controller.contains("ROOT_V7_RECOVERY_CONTROLLER_BOOTSTRAP_MODE")
            && !controller.contains("publish_root_recovery_controller")
            && !controller.contains("bootstrap_root_recovery_controller_identity")
            && !controller.contains("bootstrap_root_owned_v7_recovery_controller")
    }

    private func hasRetry3IncidentRecoveryContract(
        controller: String,
        launcher: String
    ) -> Bool {
        guard
            let rootState = try? functionBody(
                controller,
                beginningWith: "    fn read_root_driver_state",
                endingBefore: "    fn expected_driver_nodes"
            ),
            let history = try? functionBody(
                controller,
                beginningWith: "    fn parse_v7_journal_history",
                endingBefore: "    fn v7_field_schema"
            ),
            let rootProof = try? functionBody(
                controller,
                beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                endingBefore: "    fn require_retry_3_log_has_no_openers"
            ),
            let guardian = try? functionBody(
                controller,
                beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                endingBefore: "    fn uid501_driver_restore_proxy"
            ),
            let logs = try? functionBody(
                controller,
                beginningWith: "    fn require_retry_3_log_has_no_openers",
                endingBefore: "    fn read_root_controller_identity_records_via_sudo"
            ),
            let exactLog = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retry_3_log(",
                endingBefore: "    fn require_exact_retry_3_logs"
            ),
            let logNoOpeners = try? functionBody(
                controller,
                beginningWith: "    fn require_retry_3_log_has_no_openers",
                endingBefore: "    fn require_exact_retry_3_log("
            ),
            let logPrefix = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retry_3_log_prefix(",
                endingBefore: "    fn require_exact_retry_3_log_prefixes"
            ),
            let logPrefixMappings = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retry_3_log_prefixes",
                endingBefore: "    fn require_exact_retry_3_offline_log_prefixes"
            ),
            let repairLog = try? functionBody(
                controller,
                beginningWith: "    fn repair_exact_retry_3_log_mode(",
                endingBefore: "    fn repair_exact_retry_3_logs"
            ),
            let coreAudioMatch = try? functionBody(
                controller,
                beginningWith: "    fn require_retry_3_core_audio_generation",
                endingBefore: "    fn prove_retry_3_offline_safe_runtime"
            ),
            let offlineProof = try? functionBody(
                controller,
                beginningWith: "    fn prove_retry_3_offline_safe_runtime",
                endingBefore: "    fn retry_3_recovery_checkpoint"
            ),
            let recoveryCheckpoint = try? functionBody(
                controller,
                beginningWith: "    fn retry_3_recovery_checkpoint",
                endingBefore: "    fn prove_retry_3_online_safe_runtime"
            ),
            let evidence = try? functionBody(
                controller,
                beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                endingBefore: "    fn require_exact_retained_probe_directory"
            ),
            let journal = try? functionBody(
                controller,
                beginningWith: "    enum Retry3RecoveryState",
                endingBefore: "    fn require_exact_retry_2_install_hold_at"
            ),
            let journalSafe = try? functionBody(
                controller,
                beginningWith: "    fn retry_3_recovery_safe_record",
                endingBefore: "    fn retry_3_recovery_result_text"
            ),
            let generationMatch = try? functionBody(
                controller,
                beginningWith: "    fn require_retry_3_generation_matches",
                endingBefore: "    fn retry_3_recovery_safe_record"
            ),
            let recoveredGeneration = try? functionBody(
                controller,
                beginningWith: "    fn retry_3_recovered_generation",
                endingBefore: "    fn require_retry_3_generation_matches"
            ),
            let journalTransition = try? functionBody(
                controller,
                beginningWith: "    fn retry_3_recovery_transition_record",
                endingBefore: "    fn parse_retry_3_recovery_terminal"
            ),
            let journalParser = try? functionBody(
                controller,
                beginningWith: "    fn retry_3_recovery_safe_value",
                endingBefore: "    fn validate_retry_3_recovery_journal_file"
            ),
            let journalCreate = try? functionBody(
                controller,
                beginningWith: "        fn create_or_publish(",
                endingBefore: "        fn open("
            ),
            let journalValidation = try? functionBody(
                controller,
                beginningWith: "    fn validate_retry_3_recovery_journal_file",
                endingBefore: "    impl Retry3RecoveryJournal"
            ),
            let journalOpen = try? functionBody(
                controller,
                beginningWith: "        fn open(\n            path: &Path,\n            expected_commit: &str,\n            expected_tree: &str,\n            expected_terminal: Option<&Retry3RecoveryResultBinding>,",
                endingBefore: "        fn record(\n            &mut self,\n            next: Retry3RecoveryState,"
            ),
            let journalRecord = try? functionBody(
                controller,
                beginningWith: "        fn record(\n            &mut self,\n            next: Retry3RecoveryState,",
                endingBefore: "    fn require_terminal_retry_3_recovery_journal"
            ),
            let terminalJournal = try? functionBody(
                controller,
                beginningWith: "    fn require_terminal_retry_3_recovery_journal",
                endingBefore: "    fn parse_retry_3_recovery_result"
            ),
            let pendingResultReset = try? functionBody(
                controller,
                beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                endingBefore: "    fn read_retry_3_recovery_result"
            ),
            let pendingResultPrefix = try? functionBody(
                controller,
                beginningWith: "    fn is_plausible_retry_3_recovery_result_prefix",
                endingBefore: "    fn reset_retry_3_pending_result_before_generation_publish"
            ),
            let resultRead = try? functionBody(
                controller,
                beginningWith: "    fn read_retry_3_recovery_result",
                endingBefore: "    fn publish_retry_3_recovery_result"
            ),
            let resultPublish = try? functionBody(
                controller,
                beginningWith: "    fn publish_retry_3_recovery_result",
                endingBefore: "    fn require_exact_retry_2_install_hold_at"
            ),
            let onlineProof = try? functionBody(
                controller,
                beginningWith: "    fn prove_retry_3_online_safe_runtime",
                endingBefore: "    fn retry_3_v6_service_is_absent"
            ),
            let launchResume = try? functionBody(
                controller,
                beginningWith: "    fn launch_or_resume_retry_3_v6",
                endingBefore: "    fn read_root_controller_identity_records_via_sudo"
            ),
            let recovery = try? functionBody(
                controller,
                beginningWith: "    fn recover_retry_3_critical_failure",
                endingBefore: "    fn execute_paired_v7_update"
            ),
            let commandEnum = try? functionBody(
                controller,
                beginningWith: "    enum V7Command",
                endingBefore: "    impl V7Layout"
            ),
            let main = try? functionBody(
                controller,
                beginningWith: "    fn paired_v7_real_main",
                endingBefore: "    fn parse_v7_command"
            ),
            let parser = try? functionBody(
                controller,
                beginningWith: "    fn parse_v7_command",
                endingBefore: "    fn require_canonical_git_oid"
            ),
            let releasePins = try? functionBody(
                controller,
                beginningWith: "    fn require_v7_release_pins",
                endingBefore: "    fn count_exact_production_identity"
            )
        else { return false }

        let exactPins = [
            "const V7_RECOVER_RETRY_3_MODE: &str =",
            #""--recover-authorized-paired-v7-retry-3-critical-failure";"#,
            #"const RECOVERY_RETRY_3_NONCE: &str = "09602523-891e-4822-bf48-650a3b7f9637";"#,
            "const RECOVERY_RETRY_3_EVIDENCE_INODE: u64 = 27_828_068;",
            "const RECOVERY_RETRY_3_POINTER_INODE: u64 = 27_832_813;",
            #""efbe37925571f60f5ad898c7046dbd85d8e31d4bad9af603c57745928bf7059e""#,
            "const RECOVERY_RETRY_3_JOURNAL_INODE: u64 = 27_828_075;",
            "const RECOVERY_RETRY_3_JOURNAL_SIZE: u64 = 593;",
            #""d76c64d82bb7ba94dd067cf9c60a327e161377dce778850906fcddfb65aee1ad""#,
            "const RECOVERY_RETRY_3_RESULT_INODE: u64 = 27_833_303;",
            #""ce55694655fb8f1231d36ee80817abe67bc75e848f848be4d932504725f940ac""#,
            "const RECOVERY_RETRY_3_DRIVER_RECORD_INODE: u64 = 27_832_682;",
            #""148a9e96a4dc72f3936359b3b7c726e351197508a26b41b965cf98f51dc9dd62""#,
            "const RECOVERY_RETRY_3_STDOUT_INODE: u64 = 27_131_806;",
            #""afb8ac5fc5893694378d0472957c52b4ba239f9853e8001accf21394f5c28045""#,
            "const RECOVERY_RETRY_3_STDERR_INODE: u64 = 27_131_807;",
            #""ed48b41850a21cf525f14ad834d54e0dab96ae59387052212cf80797390d49c0""#,
            "const RECOVERY_RETRY_3_GUARDIAN_INODE: u64 = 27_832_356;",
            #""53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c""#,
            "const RECOVERY_RETRY_3_ROOT_TRANSACTION_INODE: u64 = 27_832_701;",
            "const RECOVERY_RETRY_3_ROOT_FAILED_DRIVER_INODE: u64 = 27_832_705;",
            #""ee133b1fe60f19e262081eb3eef6c290f03414b49533e6514b71901dfc854f55""#,
            "const RETAINED_ROOT_V7_NORMAL_V2_CONTROLLER_INODE: u64 = 27_832_674;",
            #""5feb2414a70b55ebac702916850cfb2b35f5d51a70ea63ae9ca00d67ba10bb04""#,
            #"const RECOVERY_RETRY_3_RECOVERY_JOURNAL_PENDING: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-3-1787392225-87409-09602523-891e-4822-bf48-650a3b7f9637/.retry-3-recovery-journal.txt.pending";"#,
            #"const RECOVERY_RETRY_3_RECOVERY_RESULT_PENDING: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-3-1787392225-87409-09602523-891e-4822-bf48-650a3b7f9637/.retry-3-recovery-result.txt.pending";"#,
        ]
        let rootStateTokens = [
            #"mode: 0o040755"#,
            #"kind: "directory".to_owned()"#,
        ]
        let historyTokens = [
            "let mut latest_critical_predecessor = None;",
            "validate_v7_transition(previous, next)?;",
            "if next == V7State::CriticalFailure {",
            "latest_critical_predecessor = Some(previous);",
            "terminal_critical_predecessor: if state == V7State::CriticalFailure {",
            "latest_critical_predecessor",
            "} else {",
            "None",
        ]
        let rootTokens = [
            "if layout.root != transaction",
            #""0:0:{}:0755:Directory:{}:{}:{}:0""#,
            "require_retained_root_normal_v1_via_sudo()?;",
            "require_retained_root_recovery_v1_via_sudo()?;",
            "require_retained_root_recovery_v2_via_sudo()?;",
            "require_retained_root_normal_v2_via_sudo()?;",
            "require_retry_3_transaction_parent_via_sudo(Some(transaction))",
            #""0:0:{}:0700:Directory:{}:{}:{}:0""#,
            #""0:0:{}:0755:Directory:{}:{}:{}:0""#,
            #""0:0:1:0600:Regular File:{}:{}:{}:0""#,
            #""0:0:1:0400:Regular File:{}:{}:{}:0""#,
            #"state_fields.get("prior_present").copied() != Some("0")"#,
            #".get("hold_device")"#,
            "Some(RECOVERY_RETRY_3_ROOT_DEVICE)",
            #".get("hold_inode")"#,
            "Some(RECOVERY_RETRY_3_ROOT_FAILED_DRIVER_INODE)",
            #""OpensteamerVirtualMicrophone-v7.pkg\nfailed-v7-product-driver.node\nstate.txt\n""#,
            "PRODUCT_DRIVER_CANONICAL_PATH",
            "layout.hold.as_path()",
            "layout.prior.as_path()",
            "layout.abandoned.as_path()",
            "RECOVERY_RETRY_3_ROOT_STATE_SHA256",
            "RECOVERY_RETRY_3_ROOT_STATE",
            "EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256",
            "RECOVERY_RETRY_3_ROOT_FAILED_EXECUTABLE_INODE",
            #""/usr/bin/xattr", "-lr""#,
            "require_output_success(&xattrs, \"prove retry-3 root transaction has no xattrs\")?;",
            "if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {",
            #""/usr/sbin/lsof", "+D""#,
            "if openers.status.code() != Some(1)",
            "!openers.stdout.is_empty()",
            "!openers.stderr.is_empty()",
            "EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256",
            "attest_transaction()?;",
            "verify_exact_retry_3_product_endpoints_absent",
            "attest_transaction()?;",
            "attest_immutable_sets()",
        ]
        let guardianTokens = [
            "layout.default_route_guardian != expected_guardian",
            "let data_volume_device = verified_data_volume_device()?;",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "require_descriptor_close_on_exec(&guardian",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1",
            "mode() & 0o7777 == 0o755",
            "metadata.dev() == data_volume_device",
            "metadata.ino() == RECOVERY_RETRY_3_GUARDIAN_INODE",
            "metadata.len() == RECOVERY_RETRY_3_GUARDIAN_SIZE",
            "metadata.st_flags() == 0",
            "if !metadata_is_exact(&before)",
            "!metadata_is_exact(&named_before)",
            "before.dev() != named_before.dev()",
            "before.ino() != named_before.ino()",
            "before.len() != named_before.len()",
            "sha256_bytes(&bytes)? != RECOVERY_RETRY_3_GUARDIAN_SHA256",
            #".arg("verify-product-absent")"#,
            "require_output_success(&output, \"prove exact retry-3 product HAL endpoints absent\")?;",
            #"if output.stdout != b"PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE\n""#,
            "|| !output.stderr.is_empty()",
            "let after = guardian.metadata()?;",
            "let named_after = fs::symlink_metadata",
            "!metadata_is_exact(&after)",
            "!metadata_is_exact(&named_after)",
            "before.dev() != after.dev()",
            "before.ino() != after.ino()",
            "before.len() != after.len()",
        ]
        let exactLogTokens = [
            "matches!(expected_mode, 0o600 | 0o644)",
            "let expected_device = verified_data_volume_device()?;",
            "require_retry_3_log_has_no_openers(path)?;",
            "metadata.uid() == USER_ID",
            "metadata.gid() == 0",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == expected_mode",
            "metadata.dev() == expected_device",
            "metadata.ino() == expected_inode",
            "metadata.len() == expected_length",
            "metadata.st_flags() == 0",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "descriptor_before.ino() != named_before.ino()",
            "sha256_bytes(&bytes)? != expected_sha256",
            "!metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&named_after)",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.ino() != named_after.ino()",
            "require_retry_3_log_has_no_openers(path)",
        ]
        let logNoOpenersTokens = [
            #"Path::new("/usr/sbin/lsof")"#,
            "EXPECTED_LSOF_SHA256",
            #""/usr/sbin/lsof""#,
            #"&["-n", "-Fpcufa", "--", path_text(path)?]"#,
            "if output.status.code() != Some(1)",
            "!output.stdout.is_empty()",
            "!output.stderr.is_empty()",
            "Ok(())",
        ]
        let logPrefixTokens = [
            "let expected_device = verified_data_volume_device()?;",
            "metadata.uid() == USER_ID",
            "metadata.gid() == 0",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == 0o600",
            "metadata.dev() == expected_device",
            "metadata.ino() == expected_inode",
            "metadata.len() >= expected_prefix_length",
            "metadata.len() <= expected_prefix_length + 16 * 1_024 * 1_024",
            "metadata.st_flags() == 0",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "sha256_bytes(&prefix)? != expected_prefix_sha256",
            "!metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&named_after)",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.ino() != named_after.ino()",
            "descriptor_after.len() < descriptor_before.len()",
            "named_after.len() < named_before.len()",
        ]
        let repairLogTokens = [
            "let expected_device = verified_data_volume_device()?;",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == 0",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == mode",
            "metadata.dev() == expected_device",
            "metadata.ino() == expected_inode",
            "metadata.len() == expected_length",
            "metadata.st_flags() == 0",
            "if !matches!(before_mode, 0o600 | 0o644)",
            "!metadata_is_exact(&named_before, before_mode)",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "require_descriptor_close_on_exec(&file, \"retry-3 recovery log\")?;",
            "if !metadata_is_exact(&descriptor_before, before_mode)",
            "descriptor_before.dev() != named_before.dev()",
            "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()",
            "if before_bytes.len() as u64 != expected_length",
            "sha256_bytes(&before_bytes)? != expected_sha256",
            "file.set_permissions(fs::Permissions::from_mode(0o600))?;",
            "file.sync_all()?;",
            "if !metadata_is_exact(&descriptor_after, 0o600)",
            "!metadata_is_exact(&named_after, 0o600)",
            "descriptor_before.dev() != descriptor_after.dev()",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.len() != descriptor_after.len()",
            "descriptor_before.dev() != named_after.dev()",
            "descriptor_before.ino() != named_after.ino()",
            "descriptor_before.len() != named_after.len()",
            "after_bytes != before_bytes",
            "sha256_bytes(&after_bytes)? != expected_sha256",
            "require_retry_3_log_has_no_openers(path)",
        ]
        let logPrefixMappingTokens = [
            "Path::new(RECOVERY_RETRY_3_STDOUT_LOG)",
            "RECOVERY_RETRY_3_STDOUT_INODE",
            "RECOVERY_RETRY_3_STDOUT_SIZE",
            "RECOVERY_RETRY_3_STDOUT_SHA256",
            "Path::new(RECOVERY_RETRY_3_STDERR_LOG)",
            "RECOVERY_RETRY_3_STDERR_INODE",
            "RECOVERY_RETRY_3_STDERR_SIZE",
            "RECOVERY_RETRY_3_STDERR_SHA256",
        ]
        let coreAudioMatchTokens = [
            "if expected.is_some_and(|expected| expected != actual) {",
            "Ok(actual)",
        ]
        let offlineProofTokens = [
            "require_retry_3_restored_root_via_sudo()?;",
            "verify_exact_retry_3_product_endpoints_absent(layout)?;",
            "let core_audio_before = read_core_audio_generation_root()?;",
            "require_retry_3_exact_v6_offline()?;",
            "let core_audio_after = read_core_audio_generation_root()?;",
            "verify_exact_retry_3_product_endpoints_absent(layout)?;",
            "require_retry_3_restored_root_via_sudo()?;",
            "if core_audio_before != core_audio_after",
            "require_retry_3_core_audio_generation(core_audio_before, expected_core_audio)",
        ]
        let recoveryCheckpointTokens = [
            "offset: RECOVERY_RETRY_3_STDOUT_SIZE",
            "device: RETAINED_ROOT_V7_NORMAL_V2_DEVICE",
            "inode: RECOVERY_RETRY_3_STDOUT_INODE",
        ]
        let logTokens = [
            "matches!(expected_mode, 0o600 | 0o644)",
            "require_retry_3_log_has_no_openers(path)?;",
            "metadata.uid() == USER_ID",
            "metadata.gid() == 0",
            "metadata.nlink() == 1",
            "metadata.ino() == expected_inode",
            "metadata.len() == expected_length",
            "metadata.st_flags() == 0",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "require_descriptor_close_on_exec(&file",
            "sha256_bytes(&bytes)? != expected_sha256",
            "Retry3IncidentLogModes {",
            "stdout: require_exact_retry_3_log_admission_mode(",
            "stderr: require_exact_retry_3_log_admission_mode(",
            "before == now || (before == 0o644 && now == 0o600)",
            "sha256_bytes(&prefix)? != expected_prefix_sha256",
            "require_exact_retry_3_log_prefixes()?;",
            "file.set_permissions(fs::Permissions::from_mode(0o600))?;",
            "file.sync_all()?;",
            "after_bytes != before_bytes",
            "require_retry_3_core_audio_generation(core_audio_before, expected_core_audio)",
            "require_retry_3_core_audio_generation(core_audio_before, Some(expected_core_audio))?;",
        ]
        let evidenceTokens = [
            "let expected_device = verified_data_volume_device()?;",
            "recovery_journal_pending_exists",
            "recovery_result_pending_exists",
            "recovery_journal_exists && recovery_journal_pending_exists",
            "if (recovery_result_exists || recovery_result_pending_exists) && !recovery_journal_exists",
            "recovery_result_exists && recovery_result_pending_exists",
            "if retired_pointer_exists && (!recovery_journal_exists || !recovery_result_exists)",
            "RECOVERY_RETRY_3_EVIDENCE_NLINK + optional_children",
            "RECOVERY_RETRY_3_EVIDENCE_SIZE",
            "metadata.file_type().is_dir()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == expected_nlink",
            "metadata.permissions().mode() & 0o7777 == 0o700",
            "metadata.dev() == expected_device",
            "metadata.ino() == RECOVERY_RETRY_3_EVIDENCE_INODE",
            "metadata.len() == expected_length",
            "metadata.st_flags() == 0",
            "if evidence.file_name().and_then(|name| name.to_str()) != Some(RECOVERY_RETRY_3_NAME)",
            "evidence.parent() != Some(Path::new(V7_UPDATE_ROOT))",
            "!metadata_is_exact(&evidence_before)",
            "RECOVERY_RETRY_3_JOURNAL",
            "RECOVERY_RETRY_3_JOURNAL_SHA256",
            "RECOVERY_RETRY_3_RESULT",
            "RECOVERY_RETRY_3_RESULT_SHA256",
            "RECOVERY_RETRY_3_DRIVER_RECORD",
            "RECOVERY_RETRY_3_DRIVER_RECORD_SHA256",
            "history.state != V7State::CriticalFailure",
            "history.terminal_critical_predecessor != Some(V7State::CurrentRestored)",
            #"(".retry-3-recovery-result.txt.pending", false)"#,
            #"(".retry-3-recovery-journal.txt.pending", false)"#,
            "actual.contains_key(name) != expected_present",
            "if !metadata_is_exact(&evidence_after)",
            "evidence_before.dev() != evidence_after.dev()",
            "evidence_before.ino() != evidence_after.ino()",
            "evidence_before.nlink() != evidence_after.nlink()",
            "evidence_before.len() != evidence_after.len()",
            "evidence_before.st_flags() != evidence_after.st_flags()",
        ]
        let journalTokens = [
            "coreaudio_pid={}",
            "coreaudio_runs={}",
            "stdout_initial_mode={:04o}",
            "stderr_initial_mode={:04o}",
            "critical_predecessor=CURRENT_RESTORED",
            "retry_3_recovery_safe_value",
            "parse_log_mode",
            "retry_3_recovery_safe_record(",
            "Retry3RecoveryState::SafeRuntimeProven",
            "Retry3RecoveryState::LogsRepaired",
            "Retry3RecoveryState::LaunchArmed",
            "Retry3RecoveryState::RecoveredV6",
            "result_inode={}",
            "result_sha256={}",
            ".create_new(true)",
            ".open(pending_path)",
            "text.as_bytes().starts_with(&existing)",
            "file.write_all(text.as_bytes())?;",
            "file.sync_all()?;",
            "fsync_parent(pending_path)?;",
            "rename_exclusive(pending_path, path)?;",
            "fsync_parent(path)?;",
            "validate_retry_3_recovery_journal_file(path, &file)?;",
            "tail.contains(&b'\\n')",
            "next.as_bytes().starts_with(tail)",
            "file.set_len(complete_length as u64)?;",
            ".write_all(record.as_bytes())",
            ".and_then(|_| self.file.sync_all())",
            "self.file.set_len(prior_length)?;",
            "parsed.terminal.as_ref() != Some(expected_terminal)",
            "RECOVERY_RETRY_3_RECOVERY_RESULT_PENDING",
            "rename_exclusive(pending, final_path)?;",
        ]
        let journalSafeTokens = [
            "STATE SAFE_RUNTIME_PROVEN",
            "critical_predecessor=CURRENT_RESTORED",
            "coreaudio_pid={}",
            "coreaudio_runs={}",
            "stdout_initial_mode={:04o}",
            "stderr_initial_mode={:04o}",
            "RECOVERY_RETRY_3_JOURNAL_SHA256",
            "RECOVERY_RETRY_3_RESULT_SHA256",
            "RECOVERY_RETRY_3_ROOT_STATE_SHA256",
            "RETAINED_ROOT_V7_NORMAL_V2_CONTROLLER_SHA256",
            "admission.core_audio.pid",
            "admission.core_audio.runs",
            "admission.log_modes.stdout",
            "admission.log_modes.stderr",
        ]
        let generationMatchTokens = [
            "if retry_3_recovered_generation(generation)? != *expected {",
            "retry-3 recovered v6 generation changed after its durable result",
            "Ok(())",
        ]
        let recoveredGenerationTokens = [
            "pid: generation.pid",
            "runs: generation.runs",
            "process_start_sha256: sha256_bytes(generation.process_start.as_bytes())?",
            "nonce: generation.nonce.clone()",
            "lock_device: generation.lock_device",
            "lock_inode: generation.lock_inode",
        ]
        let journalTransitionTokens = [
            "Retry3RecoveryState::SafeRuntimeProven",
            "Retry3RecoveryState::LogsRepaired",
            "STATE LOGS_REPAIRED",
            "Retry3RecoveryState::LaunchArmed",
            "STATE LAUNCH_ARMED",
            "terminal.ok_or_else",
            "Retry3RecoveryState::RecoveredV6",
            "STATE RECOVERED_V6 result_inode={} result_size={} result_sha256={} pid={} runs={} process_start_sha256={} nonce={} lock_device={} lock_inode={}",
            "terminal.inode",
            "terminal.size",
            "terminal.sha256",
        ]
        let journalParserTokens = [
            "retry_3_recovery_safe_value(&safe_fields, \"coreaudio_pid=\")",
            "retry_3_recovery_safe_value(&safe_fields, \"coreaudio_runs=\")",
            #""0600" => Ok(0o600)"#,
            #""0644" => Ok(0o644)"#,
            "stdout: parse_log_mode(\"stdout_initial_mode=\")?",
            "stderr: parse_log_mode(\"stderr_initial_mode=\")?",
            "if format!(\"{safe}\\n\")",
            "retry_3_recovery_safe_record(",
            "retry_3_recovery_transition_record(state, None)?",
            "parse_retry_3_recovery_terminal(line)?",
        ]
        let journalCreateTokens = [
            "require_path_absent(path, \"retry-3 recovery journal before atomic publication\")?;",
            ".create_new(true)",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "validate_retry_3_recovery_journal_file(pending_path, &file)?;",
            "!text.as_bytes().starts_with(&existing)",
            "let before_write_inode =",
            "validate_retry_3_recovery_journal_file(pending_path, &file)?;",
            "file.set_len(0)?;",
            "file.write_all(text.as_bytes())?;",
            "file.sync_all()?;",
            "fsync_parent(pending_path)?;",
            "rename_exclusive(pending_path, path)?;",
            "fsync_parent(path)?;",
            "require_path_absent(",
            "validate_retry_3_recovery_journal_file(path, &file)?;",
        ]
        let journalValidationTokens = [
            "let expected_device = verified_data_volume_device()?;",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == 0o600",
            "metadata.dev() == expected_device",
            "metadata.len() <= 32_768",
            "metadata.st_flags() == 0",
            "if !metadata_is_exact(&descriptor)",
            "!metadata_is_exact(&named)",
            "descriptor.ino() != named.ino()",
            "descriptor.len() != named.len()",
            "Ok(descriptor.ino())",
        ]
        let journalOpenTokens = [
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "let journal_inode =",
            "validate_retry_3_recovery_journal_file(path, &file)?;",
            ".take(32_769)",
            "let post_read_inode = validate_retry_3_recovery_journal_file(path, &file)?;",
            "if post_read_inode != journal_inode || file.metadata()?.len() != length",
            "tail.contains(&b'\\n')",
            "!next.as_bytes().starts_with(tail)",
            "validate_retry_3_recovery_journal_file(path, &file)?;",
            "file.set_len(complete_length as u64)?;",
            "file.sync_all()?;",
            "let after_truncate_inode =",
            "if parsed.recovery_commit != expected_commit\n                || parsed.recovery_tree != expected_tree",
            "let final_inode = validate_retry_3_recovery_journal_file(path, &file)?;",
        ]
        let journalRecordTokens = [
            "retry_3_recovery_transition_record(self.state, terminal)?",
            "let before_append_inode =",
            "validate_retry_3_recovery_journal_file(&self.path, &self.file)?;",
            "let prior_length = self.file.metadata()?.len();",
            "self.file.seek(SeekFrom::End(0))? != prior_length",
            "let immediate_inode =",
            "validate_retry_3_recovery_journal_file(&self.path, &self.file)?;",
            ".write_all(record.as_bytes())",
            ".and_then(|_| self.file.sync_all())",
            "self.file.set_len(prior_length)?;\n                self.file.sync_all()?;\n                return Err(ControllerError(format!(",
            "validate_retry_3_recovery_journal_file(&self.path, &self.file)?;",
            "let reopened = Self::open(",
        ]
        let terminalJournalTokens = [
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "validate_retry_3_recovery_journal_file(path, &file)?;",
            ".take(32_769)",
            "let validated_after_inode = validate_retry_3_recovery_journal_file(path, &file)?;",
            "if bytes.len() as u64 != length",
            "after.ino() != inode",
            "validated_after_inode != inode",
            "after.len() != length",
            "after.dev() != named_after.dev()",
            "after.ino() != named_after.ino()",
            "after.len() != named_after.len()",
            "parse_retry_3_recovery_journal(&text, inode)?",
            "parsed.state != Retry3RecoveryState::RecoveredV6",
            "parsed.recovery_commit != expected_commit",
            "parsed.recovery_tree != expected_tree",
            "parsed.terminal.as_ref() != Some(expected_terminal)",
        ]
        let pendingResetTokens = [
            "require_path_absent(",
            "let expected_device = verified_data_volume_device()?;",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == 0o600",
            "metadata.dev() == expected_device",
            "metadata.len() <= 2_048",
            "metadata.st_flags() == 0",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "require_descriptor_close_on_exec(&file, \"retry-3 stale pending recovery result\")?;",
            "if !metadata_is_exact(&named_before)",
            "!metadata_is_exact(&descriptor_before)",
            "descriptor_before.dev() != named_before.dev()",
            "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()",
            "if bytes.len() as u64 != descriptor_before.len()",
            "!is_plausible_retry_3_recovery_result_prefix(&bytes)",
            "!metadata_is_exact(&descriptor_read)",
            "!metadata_is_exact(&named_read)",
            "descriptor_before.dev() != descriptor_read.dev()",
            "descriptor_before.ino() != descriptor_read.ino()",
            "descriptor_before.len() != descriptor_read.len()",
            "descriptor_before.dev() != named_read.dev()",
            "descriptor_before.ino() != named_read.ino()",
            "descriptor_before.len() != named_read.len()",
            "file.set_len(0)?;",
            "file.sync_all()?;",
            "fsync_parent(pending)?;",
            "if !metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&named_after)",
            "descriptor_after.len() != 0",
            "named_after.len() != 0",
            "descriptor_before.dev() != descriptor_after.dev()",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.dev() != named_after.dev()",
            "descriptor_before.ino() != named_after.ino()",
        ]
        let pendingPrefixTokens = [
            "if bytes.len() > 2_048 || bytes.contains(&b'\\r') || bytes.contains(&0) {",
            "std::str::from_utf8(bytes)",
            "lines.len() > 8",
            "OPENSTEAMER_PAIRED_HOST_RECOVERY_RESULT_V7_RETRY_3",
            "result=recovered-v6",
            "process_start_sha256=",
            "lock_inode=",
            "value.len() > 64",
            "value.parse::<u64>().ok().filter(|value| *value > 0)",
            "true",
        ]
        let resultReadTokens = [
            "let expected_device = verified_data_volume_device()?;",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == 0o600",
            "metadata.dev() == expected_device",
            "metadata.len() > 0",
            "metadata.len() <= 2_048",
            "metadata.st_flags() == 0",
            "if !metadata_is_exact(&named_before)",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "require_descriptor_close_on_exec(&file, \"retry-3 recovery result\")?;",
            "if !metadata_is_exact(&descriptor_before)",
            "descriptor_before.dev() != named_before.dev()",
            "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()",
            ".take(2_049)",
            "if bytes.len() as u64 != descriptor_before.len()",
            "!metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&named_after)",
            "descriptor_before.dev() != descriptor_after.dev()",
            "descriptor_before.ino() != descriptor_after.ino()",
            "descriptor_before.len() != descriptor_after.len()",
            "descriptor_before.dev() != named_after.dev()",
            "descriptor_before.ino() != named_after.ino()",
            "descriptor_before.len() != named_after.len()",
            "inode: descriptor_before.ino(),",
            "size: descriptor_before.len(),",
            "sha256: sha256_bytes(&bytes)?,",
            "parse_retry_3_recovery_result(&text)?",
        ]
        let resultPublishTokens = [
            "path_exists_without_follow(final_path)?",
            "path_exists_without_follow(pending)?",
            "(true, true) =>",
            "if binding.generation != expected_generation",
            "fsync_parent(final_path)?;\n                let sealed = read_retry_3_recovery_result(final_path)?;\n                if sealed != binding",
            "return Ok(sealed);",
            ".create_new(true)",
            ".mode(0o600)",
            ".custom_flags(O_NOFOLLOW | 0x0100_0000)",
            "require_descriptor_close_on_exec(&file, \"retry-3 pending recovery result\")?;",
            "let expected_device = verified_data_volume_device()?;",
            "metadata.file_type().is_file()",
            "!metadata.file_type().is_symlink()",
            "metadata.uid() == USER_ID",
            "metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID",
            "metadata.nlink() == 1",
            "metadata.permissions().mode() & 0o7777 == 0o600",
            "metadata.dev() == expected_device",
            "metadata.len() <= expected.len() as u64",
            "metadata.st_flags() == 0",
            "if !metadata_is_exact(&descriptor_before)",
            "!metadata_is_exact(&named_before)",
            "descriptor_before.dev() != named_before.dev()",
            "descriptor_before.ino() != named_before.ino()",
            "descriptor_before.len() != named_before.len()",
            "if current.len() as u64 != descriptor_before.len()",
            "expected.as_bytes().starts_with(&current)",
            "let descriptor_read = file.metadata()?;",
            "!metadata_is_exact(&descriptor_read)",
            "!metadata_is_exact(&named_read)",
            "descriptor_read.dev() != descriptor_before.dev()",
            "descriptor_read.ino() != descriptor_before.ino()",
            "descriptor_read.len() != descriptor_before.len()",
            "descriptor_read.dev() != named_read.dev()",
            "descriptor_read.ino() != named_read.ino()",
            "descriptor_read.len() != named_read.len()",
            "if current != expected.as_bytes() {",
            "file.set_len(0)?;",
            "file.seek(SeekFrom::Start(0))?;",
            "file.write_all(expected.as_bytes())?;",
            "file.sync_all()?;",
            "if !metadata_is_exact(&descriptor_ready)",
            "!metadata_is_exact(&named_ready)",
            "descriptor_ready.len() != expected.len() as u64",
            "descriptor_ready.dev() != descriptor_before.dev()",
            "descriptor_ready.ino() != descriptor_before.ino()",
            "descriptor_ready.dev() != named_ready.dev()",
            "descriptor_ready.ino() != named_ready.ino()",
            "descriptor_ready.len() != named_ready.len()",
            "path_exists_without_follow(final_path)?",
            "file.sync_all()?;\n        fsync_parent(pending)?;\n        rename_exclusive(pending, final_path)?;\n        fsync_parent(final_path)?;",
            "if !metadata_is_exact(&descriptor_after)",
            "!metadata_is_exact(&final_named)",
            "descriptor_after.len() != expected.len() as u64",
            "descriptor_ready.dev() != descriptor_after.dev()",
            "descriptor_ready.ino() != descriptor_after.ino()",
            "descriptor_ready.len() != descriptor_after.len()",
            "descriptor_after.dev() != final_named.dev()",
            "descriptor_after.ino() != final_named.ino()",
            "descriptor_after.len() != final_named.len()",
            "path_exists_without_follow(pending)?",
            "read_retry_3_recovery_result(final_path)?",
            "if binding.generation != expected_generation",
        ]
        let onlineProofTokens = [
            "let generation = verify_paired_v7_runtime()?;",
            "require_retry_3_generation_matches(&generation, expected_generation)?;",
            "verify_deployment(",
            "require_retry_3_core_audio_generation(core_audio_before, Some(expected_core_audio))?;",
            "let final_generation = verify_paired_v7_runtime()?;",
            "require_retry_3_generation_matches(&final_generation, expected_generation)?;",
            "Ok(final_generation)",
        ]
        let launchResumeTokens = [
            "if retry_3_v6_service_is_absent()? {",
            "require_exact_retry_3_offline_log_prefixes()?;",
            "prove_retry_3_offline_safe_runtime(layout, Some(expected_core_audio))?;",
            "reset_retry_3_pending_result_before_generation_publish()?;",
            "require_exact_retry_3_critical_failure_evidence(",
            "prove_retry_3_offline_safe_runtime(layout, Some(expected_core_audio))?;",
            "require_exact_retry_3_offline_log_prefixes()?;",
            "bootstrap_exact_new_job()?;",
        ]
        let recoveryOrder = [
            "require_exact_retry_3_critical_failure_evidence(pointer_expectation)?;",
            "let journal_exists = path_exists_without_follow(journal_path)?;",
            "if journal_exists {\n            fsync_parent(journal_path)?;\n        }",
            "let initial_log_modes = require_exact_retry_3_log_admission_modes()?;",
            "let admitted_core_audio = prove_retry_3_offline_safe_runtime(&layout, None)?;",
            "require_exact_retry_3_critical_failure_evidence(",
            "if require_exact_retry_3_log_admission_modes()? != initial_log_modes",
            "prove_retry_3_offline_safe_runtime(&layout, Some(admitted_core_audio))?;",
            "Retry3RecoveryJournal::create_or_publish(",
            "require_exact_retry_3_critical_failure_evidence(",
            "Retry3RecoveryJournal::open(",
            "require_retry_3_log_resume_modes(recovery_journal.admission.log_modes)?;",
            "prove_retry_3_offline_safe_runtime(&layout, Some(admitted_core_audio))?;",
            "repair_exact_retry_3_logs()?;",
            "require_exact_retry_3_logs(0o600)?;",
            "prove_retry_3_offline_safe_runtime(&layout, Some(admitted_core_audio))?;",
            "require_exact_retry_3_critical_failure_evidence(",
            "recovery_journal.record(Retry3RecoveryState::LogsRepaired, None)?;",
            "require_exact_retry_3_logs(0o600)?;",
            "prove_retry_3_offline_safe_runtime(&layout, Some(admitted_core_audio))?;",
            "require_exact_retry_3_logs(0o600)?;",
            "let checkpoint = capture_log_checkpoint()?;",
            "checkpoint.offset != RECOVERY_RETRY_3_STDOUT_SIZE",
            "checkpoint.device != RETAINED_ROOT_V7_NORMAL_V2_DEVICE",
            "checkpoint.inode != RECOVERY_RETRY_3_STDOUT_INODE",
            "require_exact_retry_3_critical_failure_evidence(",
            "recovery_journal.record(Retry3RecoveryState::LaunchArmed, None)?;",
            "launch_or_resume_retry_3_v6(&layout, admitted_core_audio)?",
            "reset_retry_3_pending_result_before_generation_publish()?;",
            "require_exact_retry_3_critical_failure_evidence(",
            "let expected_generation = retry_3_recovered_generation(&generation)?;",
            "generation = prove_retry_3_online_safe_runtime(",
            "let binding = publish_retry_3_recovery_result(&generation)?;\n            require_retry_3_generation_matches(&generation, &binding.generation)?;\n            require_path_absent(result_pending, \"published retry-3 pending recovery result\")?;",
            "require_exact_retry_3_critical_failure_evidence(",
            "prove_retry_3_online_safe_runtime(",
            "recovery_journal.record(Retry3RecoveryState::RecoveredV6, Some(&binding))?;",
            "if result != terminal",
            "require_retry_3_generation_matches(&generation, &terminal.generation)?;",
            "prove_retry_3_online_safe_runtime(",
            "RetryV7PointerExpectation::Present",
            "require_terminal_retry_3_recovery_journal(",
            "if terminal_admission != open_admission",
            "retire_v7_active_pointer(&layout)?;",
            "RetryV7PointerExpectation::Absent",
            "require_terminal_retry_3_recovery_journal(",
            "if retired_admission != terminal_admission",
            "if read_retry_3_recovery_result(result_path)? != terminal",
            "prove_retry_3_online_safe_runtime(",
        ]
        let releasePinTokens = [
            "V7_RECOVER_RETRY_3_MODE",
            "RECOVERY_RETRY_3_EVIDENCE",
            "RECOVERY_RETRY_3_JOURNAL_SHA256",
            "RECOVERY_RETRY_3_RESULT_SHA256",
            "RECOVERY_RETRY_3_DRIVER_RECORD_SHA256",
            "RECOVERY_RETRY_3_STDOUT_SHA256",
            "RECOVERY_RETRY_3_STDERR_SHA256",
            "RECOVERY_RETRY_3_ROOT_STATE_SHA256",
            "RETAINED_ROOT_V7_NORMAL_V2_CONTROLLER_SHA256",
            #""retry-3 failure journal SHA-256""#,
            #""retry-3 root state SHA-256""#,
            #""retained normal-v2 controller SHA-256""#,
        ]
        let reachableRecoverySurface = [
            recovery,
            launchResume,
            onlineProof,
            offlineProof,
            rootProof,
            guardian,
            logs,
            evidence,
            journal,
        ].joined(separator: "\n")
        let forbiddenRecoveryWriters = [
            "RootExistingDriverRestoreClient",
            "RootDriverBrokerClient",
            "root_driver_restore",
            "bootstrap_root_owned_v7_controller",
            "publish_root_controller",
            "V7Journal::open",
            "write_result(",
        ]
        return exactPins.allSatisfy(controller.contains)
            && containsOrdered(rootStateTokens, in: rootState)
            && containsOrdered(historyTokens, in: history)
            && containsOrdered(rootTokens, in: rootProof)
            && containsOrdered(guardianTokens, in: guardian)
            && containsOrdered(logTokens, in: logs)
            && containsOrdered(logNoOpenersTokens, in: logNoOpeners)
            && containsOrdered(exactLogTokens, in: exactLog)
            && containsOrdered(logPrefixTokens, in: logPrefix)
            && containsOrdered(logPrefixMappingTokens, in: logPrefixMappings)
            && containsOrdered(repairLogTokens, in: repairLog)
            && containsOrdered(coreAudioMatchTokens, in: coreAudioMatch)
            && containsOrdered(offlineProofTokens, in: offlineProof)
            && containsOrdered(recoveryCheckpointTokens, in: recoveryCheckpoint)
            && containsOrdered(evidenceTokens, in: evidence)
            && journalTokens.allSatisfy(journal.contains)
            && containsOrdered(journalSafeTokens, in: journalSafe)
            && containsOrdered(recoveredGenerationTokens, in: recoveredGeneration)
            && containsOrdered(generationMatchTokens, in: generationMatch)
            && containsOrdered(journalTransitionTokens, in: journalTransition)
            && containsOrdered(journalParserTokens, in: journalParser)
            && containsOrdered(journalCreateTokens, in: journalCreate)
            && containsOrdered(journalValidationTokens, in: journalValidation)
            && containsOrdered(journalOpenTokens, in: journalOpen)
            && containsOrdered(journalRecordTokens, in: journalRecord)
            && containsOrdered(terminalJournalTokens, in: terminalJournal)
            && containsOrdered(pendingResetTokens, in: pendingResultReset)
            && containsOrdered(pendingPrefixTokens, in: pendingResultPrefix)
            && !pendingResultPrefix.contains("    fn is_plausible_retry_3_recovery_result_prefix(bytes: &[u8]) -> bool {\n        return true;")
            && containsOrdered(resultReadTokens, in: resultRead)
            && containsOrdered(resultPublishTokens, in: resultPublish)
            && resultPublish.components(
                separatedBy: ".custom_flags(O_NOFOLLOW | 0x0100_0000)"
            ).count - 1 == 2
            && containsOrdered(onlineProofTokens, in: onlineProof)
            && containsOrdered(launchResumeTokens, in: launchResume)
            && containsOrdered(recoveryOrder, in: recovery)
            && releasePinTokens.allSatisfy(releasePins.contains)
            && commandEnum.contains("RecoverRetry3 {")
            && commandEnum.contains("authorized_commit: String")
            && commandEnum.contains("authorized_tree: String")
            && parser.contains("V7_RECOVER_RETRY_3_MODE")
            && parser.contains("[_, mode, repo, authorized_commit, authorized_tree]")
            && parser.contains("if mode == V7_RECOVER_RETRY_3_MODE =>")
            && parser.contains("Ok(V7Command::RecoverRetry3 {")
            && main.contains("V7Command::RecoverRetry3 {")
            && main.contains("recover_retry_3_critical_failure(")
            && main.contains("canonical_repo(&repo)?")
            && main.contains("&authorized_commit")
            && main.contains("&authorized_tree")
            && launcher.contains("RECOVER_RETRY_3_MODE='--recover-authorized-paired-v7-retry-3-critical-failure'")
            && launcher.contains(#""$EXECUTE_MODE"|"$RECOVER_RETRY_2_MODE"|"$RECOVER_RETRY_3_MODE")"#)
            && launcher.contains(#"[ "$#" -eq 4 ] && [ "$2" = "$EXPECTED_REPO" ] || usage"#)
            && forbiddenRecoveryWriters.allSatisfy { !reachableRecoverySurface.contains($0) }
            && recovery.components(
                separatedBy: "require_retry_3_generation_matches(&generation, &binding.generation)?;"
            ).count - 1 == 2
            && rootProof.components(separatedBy: "sudo_require_exact_incident_stat(\n                transaction,").count - 1 == 2
            && rootProof.components(separatedBy: "RECOVERY_RETRY_3_ROOT_STATE_SHA256,").count - 1 == 2
            && rootProof.components(separatedBy: "EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,").count - 1 == 2
            && rootProof.components(separatedBy: "EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256").count - 1 >= 2
    }

    func testV7Retry2CriticalRecoveryPreservesEvidenceAndRejectsMutants() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        let launcher = try source("macOS/scripts/update-opensteamer-host-paired-v7.sh")
        if controller.contains("active-paired-host-update-v7-retry-3") {
            XCTAssertTrue(hasRetry3TerminalNamespaceContract(controller))
            XCTAssertTrue(hasRetry3RootV2Contract(controller))
            XCTAssertTrue(
                hasRetry3IncidentRecoveryContract(controller: controller, launcher: launcher)
            )
            let publishPendingCall = "        require_root_v2_support_topology(&[&[\".opensteamer-v7-controller.pending\"]])?;\n"
            let publishFinalCall = "        require_root_v2_support_topology(&[&[\"opensteamer-v7-controller\"]])?;\n"
            var publisherOrderMutant = replacingInFunction(
                controller,
                beginningWith: "    fn publish_root_controller",
                endingBefore: "    fn require_root_v2_support_topology",
                target: publishPendingCall,
                replacement: "        __PUBLISH_TOPOLOGY_SWAP__\n"
            )
            publisherOrderMutant = replacingInFunction(
                publisherOrderMutant,
                beginningWith: "    fn publish_root_controller",
                endingBefore: "    fn require_root_v2_support_topology",
                target: publishFinalCall,
                replacement: publishPendingCall
            ).replacingOccurrences(
                of: "        __PUBLISH_TOPOLOGY_SWAP__\n",
                with: publishFinalCall
            )
            let bootstrapEntryCall = "        require_root_v2_support_topology(&[\n            &[\"opensteamer-v7-controller\"],\n            &[\"controller-binary.sha256\", \"opensteamer-v7-controller\"],\n            &[\n                \"controller-binary.sha256\",\n                \"controller-identity.log\",\n                \"opensteamer-v7-controller\",\n            ],\n        ])?;\n"
            let bootstrapFinalCall = "        require_root_v2_support_topology(&[&[\n            \"controller-binary.sha256\",\n            \"controller-identity.log\",\n            \"opensteamer-v7-controller\",\n        ]])?;\n"
            var bootstrapOrderMutant = replacingInFunction(
                controller,
                beginningWith: "    fn bootstrap_root_controller_identity",
                endingBefore: "    fn publish_root_controller",
                target: bootstrapEntryCall,
                replacement: "        __BOOTSTRAP_TOPOLOGY_SWAP__\n"
            )
            bootstrapOrderMutant = replacingInFunction(
                bootstrapOrderMutant,
                beginningWith: "    fn bootstrap_root_controller_identity",
                endingBefore: "    fn publish_root_controller",
                target: bootstrapFinalCall,
                replacement: bootstrapEntryCall
            ).replacingOccurrences(
                of: "        __BOOTSTRAP_TOPOLOGY_SWAP__\n",
                with: bootstrapFinalCall
            )
            let retry3Mutants = [
                publisherOrderMutant,
                bootstrapOrderMutant,
                controller.replacingOccurrences(
                    of: "active-paired-host-update-v7-retry-3",
                    with: "active-paired-host-update-v7-retry-2"
                ),
                controller.replacingOccurrences(
                    of: "active-paired-host-update-v7-retry-2.pending-",
                    with: "active-paired-host-update-v7-retry-3.pending-"
                ),
                controller.replacingOccurrences(
                    of: "const RETRY_3_V7_ROOT_NLINK: u64 = 6;",
                    with: "const RETRY_3_V7_ROOT_NLINK: u64 = 5;"
                ),
                controller.replacingOccurrences(
                    of: "const RETRY_3_V7_ROOT_SIZE: u64 = 192;",
                    with: "const RETRY_3_V7_ROOT_SIZE: u64 = 160;"
                ),
                controller.replacingOccurrences(
                    of: "6b5d1b606bfd8eb3bf662e7596698afa891a13340d35af3be4805b1033a83c87",
                    with: "f0361f4443eefae656aa2e5e75ed5a4d4a80df521d56403bcc386f00556cfa3f"
                ),
                controller.replacingOccurrences(
                    of: "abb699a0a4b80026533b57c960ebe612a2b1a01d",
                    with: "f4962f422b9795b4074d73dd25f332fb6b05b073"
                ),
                controller.replacingOccurrences(
                    of: "            \"F:retired-active-pointer.txt\",\n",
                    with: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_terminal_retry_2_recovery_journal",
                    endingBefore: "    fn require_exact_recovered_retry_2_probes",
                    target: ".custom_flags(O_NOFOLLOW)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_terminal_retry_2_recovery_journal",
                    endingBefore: "    fn require_exact_recovered_retry_2_probes",
                    target: "            || sha256_bytes(&bytes)? != RECOVERY_RETRY_2_RECOVERY_JOURNAL_SHA256\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_evidence",
                    endingBefore: "    fn require_v7_retry_admission_ready",
                    target: "        let failed_after = fs::symlink_metadata(&layout.failed_dir)?;\n",
                    replacement: "        let failed_after = failed;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_v7_retry_admission_ready",
                    endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]",
                    target: "        require_exact_recovered_retry_2_evidence(data_volume_device)?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_current_retry_v7_layout",
                    endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n    enum Retry2RecoveryState",
                    target: #".strip_prefix("paired-v7-update-retry-3-")"#,
                    replacement: #".strip_prefix("paired-v7-update-retry-2-")"#
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_2_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        require_exact_recovered_retry_2_evidence(data_volume_device)?;\n",
                    replacement: ""
                ),
                controller + "\nfn legacy_recover_retry_2_critical_failure() {}\n",
                controller + "\nenum RootRecoveryControllerPublish {}\n",
                controller + "\nfn release_exact_retry_2_reserve() {}\n",
                controller.replacingOccurrences(
                    of: "/Library/Application Support/opensteamer/privileged-v7-v2",
                    with: "/Library/Application Support/opensteamer/privileged-v7"
                ),
                controller.replacingOccurrences(
                    of: "OPENSTEAMER_V7_CONTROLLER_IDENTITY_V2",
                    with: "OPENSTEAMER_V7_CONTROLLER_IDENTITY_V1"
                ),
                controller.replacingOccurrences(
                    of: "const RETAINED_ROOT_V7_V1_SUPPORT_INODE: u64 = 27_777_169;",
                    with: "const RETAINED_ROOT_V7_V1_SUPPORT_INODE: u64 = 27_777_170;"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_controller_set(",
                    endingBefore: "    fn require_retained_root_normal_v1",
                    target: "                || metadata.st_flags() != 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_controller_set_via_sudo",
                    endingBefore: "    fn require_retained_root_normal_v1_via_sudo",
                    target: "        if read_topology()? != before {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_transaction_parent_names",
                    endingBefore: "    fn require_retained_retry_2_root_tombstone",
                    target: "                        + if current.is_some() { 32 } else { 0 }\n",
                    replacement: "\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_retry_2_root_tombstone",
                    endingBefore: "    fn require_no_openers_root",
                    target: "        require_no_extended_attributes_root(transaction)?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_root_controller",
                    endingBefore: "    fn require_root_v2_support_topology",
                    target: "        descriptor.sync_all()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_root_controller",
                    endingBefore: "    fn require_root_v2_support_topology",
                    target: "        rename_exclusive(\n",
                    replacement: "        fs::rename(\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn root_driver_prepare",
                    endingBefore: "    fn root_driver_publish_reload",
                    target: "        require_current_retry_v7_layout(\n",
                    replacement: "        verify_update_pointer_at(\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn root_driver_publish_reload",
                    endingBefore: "    fn root_driver_rollback_reload",
                    target: "        finish_retry_3_root_operation(&layout, operation, false)?;\n",
                    replacement: "        operation?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn root_driver_rollback_reload",
                    endingBefore: "    fn root_driver_restore_or_abandon_existing",
                    target: "        finish_retry_3_root_operation(&layout, operation, true)?;\n",
                    replacement: "        operation?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn root_driver_abandon_prepare",
                    endingBefore: "    fn root_driver_verify_commit_ready",
                    target: "        finish_retry_3_root_operation(&layout, operation, true)?;\n",
                    replacement: "        operation?;\n"
                ),
                controller.replacingOccurrences(
                    of: #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)?;"#,
                    with: #"require_pinned_system_binary(Path::new("/bin/ps"), 0o755, EXPECTED_PS_SHA256)?;"#
                ),
                controller.replacingOccurrences(
                    of: "Path::new(\"/usr/sbin/lsof\"),\n            0o755,",
                    with: "Path::new(\"/usr/sbin/lsof\"),\n            0o4755,"
                ),
                controller.replacingOccurrences(
                    of: #"require_pinned_system_binary(Path::new("/bin/ls"), 0o755, EXPECTED_LS_SHA256)?;"#,
                    with: #"require_pinned_system_binary(Path::new("/bin/ls"), 0o4755, EXPECTED_LS_SHA256)?;"#
                ),
                controller.replacingOccurrences(
                    of: "Path::new(\"/usr/sbin/system_profiler\"),\n            0o755,",
                    with: "Path::new(\"/usr/sbin/system_profiler\"),\n            0o4755,"
                ),
                controller.replacingOccurrences(
                    of: "Path::new(\"/usr/bin/xattr\"),\n            0o755,",
                    with: "Path::new(\"/usr/bin/xattr\"),\n            0o4755,"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn stable_controller_binary_identity",
                    endingBefore: "    fn verified_uid501_controller_identity",
                    target: "metadata.permissions().mode() & 0o7777 == expected_mode",
                    replacement: "metadata.permissions().mode() & 0o777 == expected_mode"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_v7_release_pins",
                    endingBefore: "    fn count_exact_production_identity",
                    target: "\"pinned ps SHA-256\"",
                    replacement: "\"pinned process SHA-256\""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_no_v7_pending_pointers",
                    endingBefore: "    fn require_exact_retained_v7_top_level",
                    target: "                || name.starts_with(RETRY_2_V7_PENDING_PREFIX)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_2_post_recovery_top_level",
                    endingBefore: "    fn require_exact_terminal_retry_2_recovery_journal",
                    target: "actual.iter().map(String::as_str).ne(EXPECTED)",
                    replacement: "false"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_probes",
                    endingBefore: "    fn require_exact_recovered_retry_2_evidence",
                    target: "actual.iter().map(String::as_str).ne(EXPECTED)",
                    replacement: "false"
                ),
                controller.replacingOccurrences(
                    of: "const RECOVERY_RETRY_2_JOURNAL_SHA256: &str =\n        \"f0361f4443eefae656aa2e5e75ed5a4d4a80df521d56403bcc386f00556cfa3f\";",
                    with: "const RECOVERY_RETRY_2_JOURNAL_SHA256: &str =\n        \"10578545d58874d94e821cc23657838b62428522be6f32d7b7b23bd926a3e2ba\";"
                ),
                controller.replacingOccurrences(
                    of: "const ROOT_V7_CONTROLLER_PIN: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7-v2/controller-binary.sha256\";",
                    with: "const ROOT_V7_CONTROLLER_PIN: &str =\n        \"/Library/Application Support/opensteamer/privileged-v7/controller-binary.sha256\";"
                ),
                controller.replacingOccurrences(
                    of: "const RETAINED_ROOT_V7_V1_PIN_INODE: u64 = 27_777_172;",
                    with: "const RETAINED_ROOT_V7_V1_PIN_INODE: u64 = 27_777_173;"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn create_or_repair_root_recovery_sealed",
                    endingBefore: "    fn verify_root_controller_identity",
                    target: "        file.sync_all()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn bootstrap_root_controller_identity",
                    endingBefore: "    fn publish_root_controller",
                    target: "        require_retained_root_normal_v1()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn bootstrap_root_owned_v7_controller_for_prepare",
                    endingBefore: "    fn verify_root_owned_v7_controller_for_restore",
                    target: "                ROOT_V7_CONTROLLER_PENDING,\n",
                    replacement: "                ROOT_V7_CONTROLLER,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn finish_retry_3_root_operation",
                    endingBefore: "    fn verify_root_recovery_controller_identity",
                    target: "            (Err(primary), Err(post)) => Err(ControllerError(format!(\n",
                    replacement: "            (Err(primary), Err(_post)) => Err(primary), /*\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn paired_v7_real_main",
                    endingBefore: "    fn parse_v7_command",
                    target: "                require_descriptor_close_on_exec(\n                    &_transaction_lock.file,\n                    \"paired-v7 preflight transaction lock\",\n                )?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn parse_v7_command",
                    endingBefore: "    fn require_canonical_git_oid",
                    target: "            [_, mode] if mode == ROOT_V7_CONTROLLER_PUBLISH_MODE => {\n                Ok(V7Command::RootControllerPublish)\n            }\n",
                    replacement: ""
                ),
                controller.replacingOccurrences(
                    of: "const FIRST_ATTEMPT_V7_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7\";",
                    with: "const FIRST_ATTEMPT_V7_ACTIVE_UPDATE: &str =\n        \"/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-1\";"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_v7_root_names",
                    endingBefore: "    fn require_exact_v7_retained_triplet",
                    target: "expected.windows(2).any(|pair| pair[0] == pair[1]) || actual != expected",
                    replacement: "false"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_v7_retained_triplet",
                    endingBefore: "    fn require_exact_v7_root_quartet",
                    target: "                RETAINED_FAILED_V7_ATTEMPT_NAME,\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_v7_root_quartet",
                    endingBefore: "    fn require_retry_v7_pointer_expectation",
                    target: "                RETAINED_FAILED_V7_RETRY_1_NAME,\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_v7_pointer_expectation",
                    endingBefore: "    fn require_current_retry_v7_layout",
                    target: "        require_path_absent(\n            Path::new(RETRY_2_V7_ACTIVE_UPDATE),\n            \"retained retry-2 paired-v7 pointer\",\n        )?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_current_retry_v7_layout",
                    endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n    enum Retry2RecoveryState",
                    target: "            || pid_text.contains('-')\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_terminal_retry_2_recovery_journal",
                    endingBefore: "    fn require_exact_recovered_retry_2_probes",
                    target: "                && metadata.uid() == USER_ID\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_probes",
                    endingBefore: "    fn require_exact_recovered_retry_2_evidence",
                    target: "                RECOVERY_RETRY_2_PUBLIC_PROBE_INODE,\n",
                    replacement: "                RECOVERY_RETRY_2_GUARDIAN_INODE,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_file",
                    endingBefore: "    fn require_exact_retained_failure_file",
                    target: "                && metadata.nlink() == 1\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_empty_directory",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: " || fs::read_dir(path)?.next().transpose()?.is_some()",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn retry_2_install_hold_is_archived",
                    endingBefore: "    fn retry_2_reserve_is_released",
                    target: "if names != [\"partial-install-hold-root\".to_owned()]",
                    replacement: "if false"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn retry_2_reserve_is_released",
                    endingBefore: "    fn verify_retry_2_default_route_snapshot",
                    target: "            || before.blocks() != 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn retire_exact_retry_v7_pending_pointer_after_parent_crash",
                    endingBefore: "    fn uid_proxy_complete_host_crash_rollback",
                    target: "                || name.starts_with(RETRY_2_V7_PENDING_PREFIX)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_root_recovery_v1_file",
                    endingBefore: "    fn require_retained_root_recovery_v1",
                    target: "metadata.permissions().mode() & 0o7777 == expected_mode",
                    replacement: "metadata.permissions().mode() & 0o777 == expected_mode"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_recovery_v1()",
                    endingBefore: "    fn require_exact_retained_root_controller_set_file",
                    target: "            if names\n                != [",
                    replacement: "            if false { /*"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_recovery_v1_via_sudo",
                    endingBefore: "    fn require_retained_root_controller_set_via_sudo",
                    target: "listing.stdout\n                    != b\"controller-binary.sha256\\ncontroller-identity.log\\nopensteamer-v7-recovery-controller\\n\"",
                    replacement: "false"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_controller_set(",
                    endingBefore: "    fn require_retained_root_normal_v1",
                    target: "            if names != expected {\n",
                    replacement: "            if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_controller_set_via_sudo",
                    endingBefore: "    fn require_retained_root_normal_v1_via_sudo",
                    target: "if !listing.stderr.is_empty() || listing.stdout != expected_listing.as_bytes()",
                    replacement: "if false"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_root_controller_set_file",
                    endingBefore: "    fn require_retained_root_controller_set(",
                    target: "                && metadata.nlink() == 1\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_root_transaction_children",
                    endingBefore: "    fn require_exact_retry_3_transaction_parent_names",
                    target: "        if names\n            != [",
                    replacement: "        if false { /*"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_root_regular_identity",
                    endingBefore: "    fn require_exact_retained_root_recovery_v1_file",
                    target: "            || sha256(path)? != expected_sha256\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_root_operation_trust",
                    endingBefore: "    fn finish_retry_3_root_operation",
                    target: "        verify_root_controller_identity()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_root_admission_via_sudo",
                    endingBefore: "    fn spawn_bounded_line_reader",
                    target: "        require_retained_root_recovery_v1_via_sudo()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_root_controller",
                    endingBefore: "    fn require_root_v2_support_topology",
                    target: #"require_root_v2_support_topology(&[&[".opensteamer-v7-controller.pending"]])?;"#,
                    replacement: #"require_root_v2_support_topology(&[&[".opensteamer-v7-controller.pending"], &["opensteamer-v7-controller"]])?;"#
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn bootstrap_root_controller_identity",
                    endingBefore: "    fn publish_root_controller",
                    target: "            &[\"opensteamer-v7-controller\"],\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn create_or_repair_root_recovery_sealed",
                    endingBefore: "    fn verify_root_controller_identity",
                    target: " || expected.len() > 1_024",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn create_or_repair_root_recovery_sealed",
                    endingBefore: "    fn verify_root_controller_identity",
                    target: "                    || metadata.nlink() != 1\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_root_controller_identity",
                    endingBefore: "    fn require_retry_3_root_operation_trust",
                    target: "        require_retained_root_recovery_v2()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_retry_2_root_tombstone",
                    endingBefore: "    fn require_no_openers_root",
                    target: "        if prior.present\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_retry_2_root_tombstone",
                    endingBefore: "    fn require_no_openers_root",
                    target: "            || hold.inode != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_transaction_parent_names",
                    endingBefore: "    fn require_retained_retry_2_root_tombstone",
                    target: "                && metadata.uid() == 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_transaction_parent_names",
                    endingBefore: "    fn require_retained_retry_2_root_tombstone",
                    target: "                && metadata.nlink() == expected_nlink\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_transaction_parent_via_sudo",
                    endingBefore: "    fn read_root_controller_identity_records_via_sudo",
                    target: "0:0:{expected_nlink}:0700:Directory:{}:{}:{expected_length}:0",
                    replacement: "0:0:{expected_nlink}:0755:Directory:{}:{}:{expected_length}:0"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_probes",
                    endingBefore: "    fn require_exact_recovered_retry_2_evidence",
                    target: "                && metadata.uid() == USER_ID\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_probes",
                    endingBefore: "    fn require_exact_recovered_retry_2_evidence",
                    target: "RECOVERY_RETRY_2_GUARDIAN_SELF_TEST_SIZE",
                    replacement: "RECOVERY_RETRY_2_MIRROR_SELF_TEST_SIZE"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_root_recovery_v1_file",
                    endingBefore: "    fn require_retained_root_recovery_v1",
                    target: "            || !metadata_is_exact(&named_before)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_root_recovery_v1_file",
                    endingBefore: "    fn require_retained_root_recovery_v1",
                    target: "        if !metadata_is_exact(&after)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retained_root_controller_set_file",
                    endingBefore: "    fn require_retained_root_controller_set(",
                    target: "        if !metadata_is_exact(&after)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_root_v2_support_topology",
                    endingBefore: "    fn create_or_repair_root_recovery_sealed",
                    target: "                && metadata.uid() == 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_root_v2_support_topology",
                    endingBefore: "    fn create_or_repair_root_recovery_sealed",
                    target: "                && metadata.nlink() == expected_nlink\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_root_controller",
                    endingBefore: "    fn require_root_v2_support_topology",
                    target: "            || before.ino() != after.ino()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_terminal_retry_2_recovery_journal",
                    endingBefore: "    fn require_exact_recovered_retry_2_probes",
                    target: "        if !metadata_is_exact(&after)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_evidence",
                    endingBefore: "    fn require_v7_retry_admission_ready",
                    target: "            RECOVERY_RETRY_2_RESULT_INODE,\n            RECOVERY_RETRY_2_RESULT,\n",
                    replacement: "            RECOVERY_RETRY_2_JOURNAL_INODE,\n            RECOVERY_RETRY_2_JOURNAL,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_evidence",
                    endingBefore: "    fn require_v7_retry_admission_ready",
                    target: "        if !metadata_is_exact(&before) {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_current_retry_v7_layout",
                    endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n    enum Retry2RecoveryState",
                    target: "            || retry_metadata.permissions().mode() & 0o7777 != 0o700\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_current_retry_v7_layout",
                    endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n    enum Retry2RecoveryState",
                    target: "            || retry_metadata.st_flags() != 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_controller_set(",
                    endingBefore: "    fn require_retained_root_normal_v1",
                    target: "        if children_before != children_after\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_recovery_v1()",
                    endingBefore: "    fn require_exact_retained_root_controller_set_file",
                    target: "        if children_before != children_after\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_current_retry_v7_layout",
                    endingBefore: "    #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n    enum Retry2RecoveryState",
                    target: "            || root_before.nlink() != RETRY_3_V7_ROOT_NLINK\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_recovered_retry_2_evidence",
                    endingBefore: "    fn require_v7_retry_admission_ready",
                    target: "        if !failed_metadata_is_exact(&failed_after)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn create_or_repair_root_recovery_sealed",
                    endingBefore: "    fn verify_root_controller_identity",
                    target: "        if bytes != expected.as_bytes() {\n",
                    replacement: "        if true {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_controller_set_via_sudo",
                    endingBefore: "    fn require_retained_root_normal_v1_via_sudo",
                    target: "0:0:{support_nlink}:0700:Directory:{expected_device}:{support_inode}:{support_length}:0",
                    replacement: "0:0:{support_nlink}:0755:Directory:{expected_device}:{support_inode}:{support_length}:0"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retained_root_recovery_v1_via_sudo",
                    endingBefore: "    fn require_retained_root_controller_set_via_sudo",
                    target: "0:0:{}:0700:Directory:{}:{}:{}:0",
                    replacement: "0:0:{}:0755:Directory:{}:{}:{}:0"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn root_attest_retry_2_safe_state",
                    endingBefore: "    fn require_fixed_system_binary",
                    target: "        if prior.present\n",
                    replacement: "        if false\n"
                ),
            ]
            for (index, mutant) in retry3Mutants.enumerated() {
                XCTAssertNotEqual(mutant, controller, "retry3/root mutant \(index) was inert")
                XCTAssertFalse(
                    hasRetry3TerminalNamespaceContract(mutant)
                        && hasRetry3RootV2Contract(mutant),
                    "retry3/root contract accepted mutant \(index)"
                )
            }
            let incidentMutants = [
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_root_driver_state",
                    endingBefore: "    fn expected_driver_nodes",
                    target: "            mode: 0o040755,\n",
                    replacement: "            mode: 0,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_root_driver_state",
                    endingBefore: "    fn expected_driver_nodes",
                    target: "            mode: 0o040755,\n",
                    replacement: "            mode: 0o0755,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn parse_v7_journal_history",
                    endingBefore: "    fn v7_field_schema",
                    target: "                    latest_critical_predecessor = Some(previous);\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "history.terminal_critical_predecessor != Some(V7State::CurrentRestored)",
                    replacement: "history.terminal_critical_predecessor != Some(V7State::CurrentBootstrapped)"
                ),
                controller.replacingOccurrences(
                    of: #""d76c64d82bb7ba94dd067cf9c60a327e161377dce778850906fcddfb65aee1ad""#,
                    with: #""ce55694655fb8f1231d36ee80817abe67bc75e848f848be4d932504725f940ac""#
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "            require_retained_root_normal_v2_via_sudo()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: #""0:0:{}:0700:Directory:{}:{}:{}:0""#,
                    replacement: #""0:0:{}:0755:Directory:{}:{}:{}:0""#
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "!= Some(RECOVERY_RETRY_3_ROOT_FAILED_DRIVER_INODE)\n",
                    replacement: "!= Some(1)\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: ".custom_flags(O_NOFOLLOW | 0x0100_0000)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "                && metadata.ino() == RECOVERY_RETRY_3_GUARDIAN_INODE\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "            || before.ino() != after.ino()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log(",
                    endingBefore: "    fn require_exact_retry_3_logs",
                    target: "if !matches!(expected_mode, 0o600 | 0o644)",
                    replacement: "if expected_mode != 0o644"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log(",
                    endingBefore: "    fn require_exact_retry_3_logs",
                    target: "                && metadata.gid() == 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_log_resume_modes",
                    endingBefore: "    fn require_exact_retry_3_log_prefix",
                    target: "before == now || (before == 0o644 && now == 0o600)",
                    replacement: "matches!(now, 0o600 | 0o644)"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log_prefix",
                    endingBefore: "    fn require_exact_retry_3_log_prefixes",
                    target: "            || sha256_bytes(&prefix)? != expected_prefix_sha256\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn prove_retry_3_online_safe_runtime",
                    endingBefore: "    fn retry_3_v6_service_is_absent",
                    target: "        require_retry_3_core_audio_generation(core_audio_before, Some(expected_core_audio))?;\n",
                    replacement: "        require_retry_3_core_audio_generation(core_audio_before, None)?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn prove_retry_3_online_safe_runtime",
                    endingBefore: "    fn retry_3_v6_service_is_absent",
                    target: "        let final_generation = verify_paired_v7_runtime()?;\n",
                    replacement: "        let final_generation = generation;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn create_or_publish(",
                    endingBefore: "        fn open(\n            path: &Path,\n            expected_commit: &str,",
                    target: "                .create_new(true)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn create_or_publish(",
                    endingBefore: "        fn open(\n            path: &Path,\n            expected_commit: &str,",
                    target: "            let before_write_inode =\n                validate_retry_3_recovery_journal_file(pending_path, &file)?;\n",
                    replacement: "            let before_write_inode = journal_inode;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn open(\n            path: &Path,\n            expected_commit: &str,",
                    endingBefore: "        fn record(\n            &mut self,\n            next: Retry3RecoveryState,",
                    target: "            let post_read_inode = validate_retry_3_recovery_journal_file(path, &file)?;\n",
                    replacement: "            let post_read_inode = journal_inode;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn record(\n            &mut self,\n            next: Retry3RecoveryState,",
                    endingBefore: "    fn require_terminal_retry_3_recovery_journal",
                    target: "            let immediate_inode =\n                validate_retry_3_recovery_journal_file(&self.path, &self.file)?;\n",
                    replacement: "            let immediate_inode = self.journal_inode;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || !is_plausible_retry_3_recovery_result_prefix(&bytes)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "        fsync_parent(pending)?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "        let descriptor_read = file.metadata()?;\n",
                    replacement: "        let descriptor_read = descriptor_before;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "        rename_exclusive(pending, final_path)?;\n",
                    replacement: "        fs::rename(pending, final_path)?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn launch_or_resume_retry_3_v6",
                    endingBefore: "    fn read_root_controller_identity_records_via_sudo",
                    target: "            reset_retry_3_pending_result_before_generation_publish()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "                reset_retry_3_pending_result_before_generation_publish()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "                generation = prove_retry_3_online_safe_runtime(\n",
                    replacement: "                generation = generation; /*\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        let terminal_admission = require_terminal_retry_3_recovery_journal(\n",
                    replacement: "        let terminal_admission = open_admission; /*\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        verify_committed_v6_baseline()?;\n",
                    replacement: "        RootExistingDriverRestoreClient::start();\n        verify_committed_v6_baseline()?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        verify_committed_v6_baseline()?;\n",
                    replacement: "        V7Journal::open(Path::new(\"unsafe\"))?;\n        verify_committed_v6_baseline()?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn parse_v7_command",
                    endingBefore: "    fn require_canonical_git_oid",
                    target: "                if mode == V7_RECOVER_RETRY_3_MODE =>\n",
                    replacement: "                if false =>\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_generation_matches",
                    endingBefore: "    fn retry_3_recovery_safe_record",
                    target: "        if retry_3_recovered_generation(generation)? != *expected {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_core_audio_generation",
                    endingBefore: "    fn prove_retry_3_offline_safe_runtime",
                    target: "        if expected.is_some_and(|expected| expected != actual) {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn prove_retry_3_offline_safe_runtime",
                    endingBefore: "    fn retry_3_recovery_checkpoint",
                    target: "        if core_audio_before != core_audio_after {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn launch_or_resume_retry_3_v6",
                    endingBefore: "    fn read_root_controller_identity_records_via_sudo",
                    target: "            reset_retry_3_pending_result_before_generation_publish()?;\n",
                    replacement: "            RootDriverBrokerClient::start();\n            reset_retry_3_pending_result_before_generation_publish()?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn is_plausible_retry_3_recovery_result_prefix",
                    endingBefore: "    fn reset_retry_3_pending_result_before_generation_publish",
                    target: "        if bytes.len() > 2_048 || bytes.contains(&b'\\r') || bytes.contains(&0) {\n",
                    replacement: "        if false && (bytes.len() > 2_048 || bytes.contains(&b'\\r') || bytes.contains(&0)) {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log(",
                    endingBefore: "    fn require_exact_retry_3_logs",
                    target: "                && metadata.permissions().mode() & 0o7777 == expected_mode\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log_prefixes",
                    endingBefore: "    fn require_exact_retry_3_offline_log_prefixes",
                    target: "Path::new(RECOVERY_RETRY_3_STDERR_LOG)",
                    replacement: "Path::new(RECOVERY_RETRY_3_STDOUT_LOG)"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn parse_retry_3_recovery_journal",
                    endingBefore: "    fn validate_retry_3_recovery_journal_file",
                    target: "        if format!(\"{safe}\\n\")\n",
                    replacement: "        if false && format!(\"{safe}\\n\")\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        if result != terminal {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        if read_retry_3_recovery_result(result_path)? != terminal {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "                && metadata.dev() == data_volume_device\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "                && metadata.st_flags() == 0\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn is_plausible_retry_3_recovery_result_prefix",
                    endingBefore: "    fn reset_retry_3_pending_result_before_generation_publish",
                    target: "    fn is_plausible_retry_3_recovery_result_prefix(bytes: &[u8]) -> bool {\n",
                    replacement: "    fn is_plausible_retry_3_recovery_result_prefix(bytes: &[u8]) -> bool {\n        return true;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        if terminal_admission != open_admission {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        if retired_admission != terminal_admission {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "                || checkpoint.device != RETAINED_ROOT_V7_NORMAL_V2_DEVICE\n",
                    replacement: ""
                ),
                controller.replacingOccurrences(
                    of: "        require_retry_3_generation_matches(&generation, &terminal.generation)?;\n",
                    with: ""
                ),
                replacingLastInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "                RECOVERY_RETRY_3_ROOT_STATE_SHA256,\n",
                    replacement: "                RECOVERY_RETRY_3_RESULT_SHA256,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "            require_retained_root_normal_v1_via_sudo()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "            require_retained_root_recovery_v1_via_sudo()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "            require_retained_root_recovery_v2_via_sudo()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "        require_output_success(&output, \"prove exact retry-3 product HAL endpoints absent\")?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_log_has_no_openers",
                    endingBefore: "    fn require_exact_retry_3_log(",
                    target: "        if output.status.code() != Some(1)\n",
                    replacement: "        if false && output.status.code() != Some(1)\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "            if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {\n",
                    replacement: "            if false && (!xattrs.stdout.is_empty() || !xattrs.stderr.is_empty()) {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_restored_root_via_sudo",
                    endingBefore: "    fn require_retry_3_log_has_no_openers",
                    target: "            if openers.status.code() != Some(1)\n",
                    replacement: "            if false && openers.status.code() != Some(1)\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "        if output.stdout != b\"PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE\\n\"\n",
                    replacement: "        if false && output.stdout != b\"PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE\\n\"\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_core_audio_generation",
                    endingBefore: "    fn prove_retry_3_offline_safe_runtime",
                    target: "        if expected.is_some_and(|expected| expected != actual) {\n",
                    replacement: "        if false && expected.is_some_and(|expected| expected != actual) {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_3_generation_matches",
                    endingBefore: "    fn retry_3_recovery_safe_record",
                    target: "        if retry_3_recovered_generation(generation)? != *expected {\n",
                    replacement: "        if false && retry_3_recovered_generation(generation)? != *expected {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn retry_3_recovered_generation",
                    endingBefore: "    fn require_retry_3_generation_matches",
                    target: "            runs: generation.runs,\n",
                    replacement: "            runs: 1,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn retry_3_recovery_checkpoint",
                    endingBefore: "    fn prove_retry_3_online_safe_runtime",
                    target: "            device: RETAINED_ROOT_V7_NORMAL_V2_DEVICE,\n",
                    replacement: "            device: 1,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn validate_retry_3_recovery_journal_file",
                    endingBefore: "    impl Retry3RecoveryJournal",
                    target: "        if !metadata_is_exact(&descriptor)\n",
                    replacement: "        if false && !metadata_is_exact(&descriptor)\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn record(\n            &mut self,\n            next: Retry3RecoveryState,",
                    endingBefore: "    fn require_terminal_retry_3_recovery_journal",
                    target: "                self.file.set_len(prior_length)?;\n                self.file.sync_all()?;\n",
                    replacement: "                self.file.set_len(prior_length)?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "                if binding.generation != expected_generation {\n",
                    replacement: "                if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "            if require_exact_retry_3_log_admission_modes()? != initial_log_modes {\n",
                    replacement: "            if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "        if journal_exists {\n            fsync_parent(journal_path)?;\n        }\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "            require_retry_3_generation_matches(&generation, &binding.generation)?;\n",
                    replacement: ""
                ),
                replacingLastInFunction(
                    controller,
                    beginningWith: "    fn recover_retry_3_critical_failure",
                    endingBefore: "    fn execute_paired_v7_update",
                    target: "            require_retry_3_generation_matches(&generation, &binding.generation)?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log_prefix(",
                    endingBefore: "    fn require_exact_retry_3_log_prefixes",
                    target: "                && metadata.len() <= expected_prefix_length + 16 * 1_024 * 1_024\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            sha256: sha256_bytes(&bytes)?,\n",
                    replacement: "            sha256: RECOVERY_RETRY_3_RESULT_SHA256.to_owned(),\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            inode: descriptor_before.ino(),\n",
                    replacement: "            inode: RECOVERY_RETRY_3_RESULT_INODE,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            size: descriptor_before.len(),\n",
                    replacement: "            size: RECOVERY_RETRY_3_RESULT_SIZE,\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "                && metadata.dev() == expected_device\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "                && metadata.len() <= 2_048\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "        require_descriptor_close_on_exec(&file, \"retry-3 recovery result\")?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.dev() != named_before.dev()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.len() != named_before.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "        if bytes.len() as u64 != descriptor_before.len()\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.dev() != descriptor_after.dev()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.len() != descriptor_after.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.dev() != named_after.dev()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.len() != named_after.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn read_retry_3_recovery_result",
                    endingBefore: "    fn publish_retry_3_recovery_result",
                    target: "            || descriptor_before.ino() != named_after.ino()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "                && metadata.nlink() == 1\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "        let expected_device = verified_data_volume_device()?;\n",
                    replacement: "        let expected_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "                fsync_parent(final_path)?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "                if sealed != binding {\n",
                    replacement: "                if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "                .custom_flags(O_NOFOLLOW | 0x0100_0000)\n",
                    replacement: ""
                ),
                replacingLastInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "                .custom_flags(O_NOFOLLOW | 0x0100_0000)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || !metadata_is_exact(&named_before)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || descriptor_before.dev() != named_before.dev()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || descriptor_before.len() != named_before.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "        if current.len() as u64 != descriptor_before.len()\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || !metadata_is_exact(&named_read)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || descriptor_read.len() != named_read.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || !metadata_is_exact(&named_ready)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "        if !metadata_is_exact(&descriptor_ready)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || descriptor_ready.len() != expected.len() as u64\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || path_exists_without_follow(final_path)?\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "        file.sync_all()?;\n        fsync_parent(pending)?;\n        rename_exclusive(pending, final_path)?;\n        fsync_parent(final_path)?;\n",
                    replacement: "        fsync_parent(pending)?;\n        rename_exclusive(pending, final_path)?;\n        fsync_parent(final_path)?;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || !metadata_is_exact(&final_named)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || descriptor_ready.len() != descriptor_after.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || descriptor_after.len() != final_named.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn publish_retry_3_recovery_result",
                    endingBefore: "    fn require_exact_retry_2_install_hold_at",
                    target: "            || path_exists_without_follow(pending)?\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log_prefix(",
                    endingBefore: "    fn require_exact_retry_3_log_prefixes",
                    target: "            || !metadata_is_exact(&descriptor_after)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log_prefix(",
                    endingBefore: "    fn require_exact_retry_3_log_prefixes",
                    target: "            || !metadata_is_exact(&named_after)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log(",
                    endingBefore: "    fn require_exact_retry_3_logs",
                    target: "        let expected_device = verified_data_volume_device()?;\n",
                    replacement: "        let expected_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log_prefix(",
                    endingBefore: "    fn require_exact_retry_3_log_prefixes",
                    target: "        let expected_device = verified_data_volume_device()?;\n",
                    replacement: "        let expected_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn repair_exact_retry_3_log_mode(",
                    endingBefore: "    fn repair_exact_retry_3_logs",
                    target: "        let expected_device = verified_data_volume_device()?;\n",
                    replacement: "        let expected_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "        let data_volume_device = verified_data_volume_device()?;\n",
                    replacement: "        let data_volume_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn open(\n            path: &Path,",
                    endingBefore: "        fn record(\n            &mut self,",
                    target: "            if parsed.recovery_commit != expected_commit\n                || parsed.recovery_tree != expected_tree\n",
                    replacement: "            if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_terminal_retry_3_recovery_journal",
                    endingBefore: "    fn parse_retry_3_recovery_result",
                    target: "            || parsed.recovery_commit != expected_commit\n            || parsed.recovery_tree != expected_tree\n",
                    replacement: "            || false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "        let expected_device = verified_data_volume_device()?;\n",
                    replacement: "        let expected_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "        if (recovery_result_exists || recovery_result_pending_exists) && !recovery_journal_exists {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "        if retired_pointer_exists && (!recovery_journal_exists || !recovery_result_exists) {\n",
                    replacement: "        if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "                && metadata.nlink() == expected_nlink\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "            || !metadata_is_exact(&evidence_before)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_critical_failure_evidence",
                    endingBefore: "    fn require_exact_retained_probe_directory",
                    target: "        if !metadata_is_exact(&evidence_after)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "        let expected_device = verified_data_volume_device()?;\n",
                    replacement: "        let expected_device = 1;\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "        if !metadata_is_exact(&named_before)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || !metadata_is_exact(&descriptor_before)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || descriptor_before.len() != named_before.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "        if bytes.len() as u64 != descriptor_before.len()\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || !metadata_is_exact(&named_read)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || descriptor_before.len() != named_read.len()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "        if !metadata_is_exact(&descriptor_after)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || !metadata_is_exact(&named_after)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn reset_retry_3_pending_result_before_generation_publish",
                    endingBefore: "    fn read_retry_3_recovery_result",
                    target: "            || descriptor_before.ino() != named_after.ino()\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn repair_exact_retry_3_log_mode(",
                    endingBefore: "    fn repair_exact_retry_3_logs",
                    target: "                && metadata.nlink() == 1\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn repair_exact_retry_3_log_mode(",
                    endingBefore: "    fn repair_exact_retry_3_logs",
                    target: "        if !matches!(before_mode, 0o600 | 0o644)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn repair_exact_retry_3_log_mode(",
                    endingBefore: "    fn repair_exact_retry_3_logs",
                    target: "        if !metadata_is_exact(&descriptor_before, before_mode)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn repair_exact_retry_3_log_mode(",
                    endingBefore: "    fn repair_exact_retry_3_logs",
                    target: "        if !metadata_is_exact(&descriptor_after, 0o600)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn repair_exact_retry_3_log_mode(",
                    endingBefore: "    fn repair_exact_retry_3_logs",
                    target: "            || !metadata_is_exact(&named_after, 0o600)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "        if !metadata_is_exact(&before)\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn verify_exact_retry_3_product_endpoints_absent",
                    endingBefore: "    fn uid501_driver_restore_proxy",
                    target: "            || !metadata_is_exact(&named_before)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "        fn open(\n            path: &Path,",
                    endingBefore: "        fn record(\n            &mut self,",
                    target: "            if post_read_inode != journal_inode || file.metadata()?.len() != length {\n",
                    replacement: "            if false {\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_retry_3_log(",
                    endingBefore: "    fn require_exact_retry_3_logs",
                    target: "            || !metadata_is_exact(&named_after)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_terminal_retry_3_recovery_journal",
                    endingBefore: "    fn parse_retry_3_recovery_result",
                    target: "        if bytes.len() as u64 != length\n",
                    replacement: "        if false\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_terminal_retry_3_recovery_journal",
                    endingBefore: "    fn parse_retry_3_recovery_result",
                    target: "            || after.len() != named_after.len()\n",
                    replacement: ""
                ),
            ]
            for (index, mutant) in incidentMutants.enumerated() {
                XCTAssertNotEqual(mutant, controller, "retry3 incident mutant \(index) was inert")
                XCTAssertFalse(
                    hasRetry3IncidentRecoveryContract(controller: mutant, launcher: launcher),
                    "retry3 incident contract accepted mutant \(index)"
                )
            }
            let incidentLauncherMutants = [
                launcher.replacingOccurrences(
                    of: "RECOVER_RETRY_3_MODE='--recover-authorized-paired-v7-retry-3-critical-failure'",
                    with: "RECOVER_RETRY_3_MODE='--recover-authorized-paired-v7-retry-2-critical-failure'"
                ),
                launcher.replacingOccurrences(
                    of: #""$EXECUTE_MODE"|"$RECOVER_RETRY_2_MODE"|"$RECOVER_RETRY_3_MODE")"#,
                    with: #""$EXECUTE_MODE"|"$RECOVER_RETRY_2_MODE")"#
                ),
                launcher.replacingOccurrences(
                    of: #"[ "$#" -eq 4 ] && [ "$2" = "$EXPECTED_REPO" ] || usage"#,
                    with: #"[ "$#" -ge 2 ] && [ "$2" = "$EXPECTED_REPO" ] || usage"#
                ),
            ]
            for (index, mutant) in incidentLauncherMutants.enumerated() {
                XCTAssertNotEqual(mutant, launcher, "retry3 incident launcher mutant \(index) was inert")
                XCTAssertFalse(
                    hasRetry3IncidentRecoveryContract(controller: controller, launcher: mutant),
                    "retry3 incident contract accepted launcher mutant \(index)"
                )
            }
            XCTAssertTrue(launcher.contains("RECOVER_RETRY_2_MODE='--recover-authorized-paired-v7-retry-2-critical-failure'"))
            return
        }
        XCTAssertTrue(
            hasEvidencePreservingRetry2CriticalRecoveryContract(
                controller: controller,
                launcher: launcher
            )
        )
        let mutants = [
            controller.replacingOccurrences(
                of: "RECOVERY_RETRY_2_JOURNAL_SHA256,\n        )?;",
                with: "RECOVERY_RETRY_2_RESULT_SHA256,\n        )?;"
            ),
            controller.replacingOccurrences(
                of: "RECOVERY_RETRY_2_RESULT_SHA256,\n        )?;",
                with: "RECOVERY_RETRY_2_JOURNAL_SHA256,\n        )?;"
            ),
            controller.replacingOccurrences(
                of: "RECOVERY_RETRY_2_DRIVER_RECORD_SHA256,\n        )?;",
                with: "RECOVERY_RETRY_2_RESULT_SHA256,\n        )?;"
            ),
            controller.replacingOccurrences(
                of: "        verify_root_production_driver(&layout.failed)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            || hold.inode != RECOVERY_RETRY_2_ROOT_FAILED_DRIVER_INODE\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        require_no_extended_attributes_root(transaction)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        require_no_openers_root(transaction)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        require_no_openers_user(source)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            .custom_flags(O_NOFOLLOW)\n            .open(source)?;",
                with: "            .open(source)?;"
            ),
            controller.replacingOccurrences(
                of: "        fsync_parent(archive)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            recovery_journal.record(Retry2RecoveryState::RecoveredV6)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            recovery_journal.record(Retry2RecoveryState::ReserveReleased)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        verify_exact_retry_2_product_endpoints_absent(layout)?;\n",
                with: "",
                options: [],
                range: controller.range(of: "fn prove_retry_2_safe_runtime(")!.lowerBound..<controller.endIndex
            ),
            controller.replacingOccurrences(
                of: #"command_output("/bin/kill", &["-TERM", &pid], None)?;"#,
                with: #"command_output("/usr/bin/killall", &["coreaudiod"], None)?;"#
            ),
            controller.replacingOccurrences(
                of: "after.pid != before.pid && after.runs == expected_runs",
                with: "after.pid != before.pid"
            ),
            controller.replacingOccurrences(
                of: "            require_core_audio_process(generation)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        root_driver_restore_or_abandon_existing(nonce)\n",
                with: "        root_driver_rollback_reload(nonce)\n"
            ),
            controller.replacingOccurrences(
                of: "            return root_driver_abandon_prepare(nonce);\n",
                with: "            return root_driver_rollback_reload(nonce);\n"
            ),
            controller.replacingOccurrences(
                of: "        verify_product_endpoints_absent(layout)?;\n        uid_proxy_finish_driver_rollback",
                with: "        uid_proxy_finish_driver_rollback"
            ),
            controller.replacingOccurrences(
                of: "        retire_update_pointer_at(\n",
                with: "        write_result(&layout.result, \"rolled-back-recovered\", None)?;\n        retire_update_pointer_at(\n"
            ),
            controller.replacingOccurrences(
                of: "        let initial_pointer_expectation =\n            if path_exists_without_follow(Path::new(V7_ACTIVE_UPDATE))? {\n                RetryV7PointerExpectation::Present\n            } else {\n                RetryV7PointerExpectation::Absent\n            };\n",
                with: "        let initial_pointer_expectation = RetryV7PointerExpectation::Present;\n"
            ),
            controller.replacingOccurrences(
                of: "        if initial_pointer_expectation == RetryV7PointerExpectation::Absent\n            && recovery_journal.state != Retry2RecoveryState::RecoveredV6\n        {\n            return Err(ControllerError(\n                \"retry-2 pointer retired before recovery reached durable RECOVERED_V6\"\n                    .to_owned(),\n            ));\n        }\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            if retry_2_install_hold_is_archived(&initial_layout)? {\n",
                with: "            if false {\n"
            ),
            controller.replacingOccurrences(
                of: "            if retry_2_reserve_is_released(&initial_layout)? {\n",
                with: "            if false {\n"
            ),
            controller.replacingOccurrences(
                of: "            || before.blocks() != 0\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                file.set_len(complete_length as u64)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: " provenance_inode={} provenance_sha256={}",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            || before.ino() != RECOVERY_RETRY_2_GUARDIAN_INODE\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        rename_exclusive(\n            Path::new(ROOT_V7_RECOVERY_CONTROLLER_PENDING),\n            Path::new(ROOT_V7_RECOVERY_CONTROLLER),\n        )?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        if !expected.as_bytes().starts_with(&bytes) {\n",
                with: "        if false {\n"
            ),
            controller.replacingOccurrences(
                of: "    const RECOVERY_RETRY_2_EVIDENCE_INODE: u64 = 27_770_302;\n",
                with: "    const RECOVERY_RETRY_2_EVIDENCE_INODE: u64 = 1;\n"
            ),
            controller.replacingOccurrences(
                of: "            RECOVERY_RETRY_2_PROVENANCE_SHA256,\n            RECOVERY_RETRY_2_DRIVER_RECORD_INODE,\n",
                with: "            RECOVERY_RETRY_2_RESULT_SHA256,\n            RECOVERY_RETRY_2_DRIVER_RECORD_INODE,\n"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn parse_core_audio_launch_state(",
                endingBefore: "fn require_core_audio_process(",
                target: #"state.as_deref() != Some("running")"#,
                replacement: "false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn parse_core_audio_launch_state(",
                endingBefore: "fn require_core_audio_process(",
                target: "if runs.replace(value).is_some()",
                replacement: "if false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn is_plausible_retry_2_recovery_torn_tail(",
                endingBefore: "impl Retry2RecoveryJournal",
                target: "tail.contains(&b'\\r')",
                replacement: "false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn is_plausible_retry_2_recovery_torn_tail(",
                endingBefore: "impl Retry2RecoveryJournal",
                target: ".map(|(_, next)| next.as_bytes().starts_with(tail))",
                replacement: ".map(|_| true)"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn bootstrap_root_recovery_controller_identity(",
                endingBefore: "fn verify_root_controller_identity(",
                target: "ROOT_V7_RECOVERY_CONTROLLER_PIN",
                replacement: "ROOT_V7_CONTROLLER_PIN"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn bootstrap_root_recovery_controller_identity(",
                endingBefore: "fn verify_root_controller_identity(",
                target: "let sealed = read_root_controller_identity_records_at(\n            Path::new(ROOT_V7_RECOVERY_CONTROLLER_PIN)",
                replacement: "let sealed = read_root_controller_identity_records_at(\n            Path::new(ROOT_V7_CONTROLLER_PIN)"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn verify_root_recovery_controller_identity(",
                endingBefore: "fn require_root_private_directory(",
                target: #""OPENSTEAMER_V7_RECOVERY_CONTROLLER_IDENTITY_V2""#,
                replacement: #""OPENSTEAMER_V7_CONTROLLER_IDENTITY_V1""#
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn root_attest_retry_2_safe_state(",
                endingBefore: "fn require_fixed_system_binary(",
                target: "let data_volume_device = verified_data_volume_device()?;",
                replacement: "let data_volume_device = 16_777_229;"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_exact_retry_2_install_hold_at(",
                endingBefore: "fn retry_2_install_hold_is_archived(",
                target: "let data_volume_device = verified_data_volume_device()?;",
                replacement: "let data_volume_device = 16_777_229;"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn archive_exact_retry_2_install_hold(",
                endingBefore: "fn retry_2_reserve_is_released(",
                target: "before.dev() != data_volume_device",
                replacement: "false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn retry_2_reserve_is_released(",
                endingBefore: "fn release_exact_retry_2_reserve(",
                target: "if allocated_bytes < RECOVERY_RETRY_2_RESERVE_SIZE",
                replacement: "if false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn release_exact_retry_2_reserve(",
                endingBefore: "fn verify_retry_2_default_route_snapshot(",
                target: "before.dev() != data_volume_device",
                replacement: "false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn recover_retry_2_critical_failure(",
                endingBefore: "fn execute_paired_v7_update(",
                target: "release_exact_retry_2_reserve(&layout)?;",
                replacement: "release_rollback_reserve(&layout.rollback_reserve)?;"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn verify_product_endpoints_absent(",
                endingBefore: "fn verify_exact_retry_2_product_endpoints_absent(",
                target: "require_regular(&layout.default_route_guardian, 0o755)?;",
                replacement: "let _ = RECOVERY_RETRY_2_GUARDIAN_INODE;\n        require_regular(&layout.default_route_guardian, 0o755)?;"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn retry_2_recovery_safe_record(",
                endingBefore: "fn retry_2_recovery_transition_record(",
                target: " reserve_allocated_bytes_at_least={}",
                replacement: ""
            ),
            controller.replacingOccurrences(
                of: "const ROOT_V7_RECOVERY_CONTROLLER_PIN: &str = \"/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2/controller-binary.sha256\";",
                with: "const ROOT_V7_RECOVERY_CONTROLLER_PIN: &str = \"/Library/Application Support/opensteamer/privileged-v7/controller-binary.sha256\";"
            ),
            controller.replacingOccurrences(
                of: "        require_descriptor_close_on_exec(\n            &_transaction_lock.file,\n            \"retry-2 recovery transaction lock\",\n        )?;\n",
                with: ""
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn reload_core_audio_root(",
                endingBefore: "fn require_exact_root_directory_identity(",
                target: "let pid = before.pid.to_string();",
                replacement: "let pid = \"1\".to_owned();"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_core_audio_process(",
                endingBefore: "fn read_core_audio_generation_root(",
                target: "pid.as_str(),",
                replacement: "\"1\","
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn create(path: &Path, commit: &str, tree: &str)",
                endingBefore: "fn open(path: &Path, expected_commit: &str, expected_tree: &str)",
                target: "file.sync_all()?;",
                replacement: ""
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn record(&mut self, next: Retry2RecoveryState)",
                endingBefore: "fn require_exact_retry_2_failure_evidence(",
                target: ".and_then(|_| self.file.sync_all())",
                replacement: ".and_then(|_| Ok(()))"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn retry_2_recovery_safe_record(",
                endingBefore: "fn retry_2_recovery_transition_record(",
                target: "RECOVERY_RETRY_2_RESULT_SHA256,\n            RECOVERY_RETRY_2_PROVENANCE_INODE,\n            RECOVERY_RETRY_2_PROVENANCE_SHA256,",
                replacement: "RECOVERY_RETRY_2_PROVENANCE_SHA256,\n            RECOVERY_RETRY_2_PROVENANCE_INODE,\n            RECOVERY_RETRY_2_RESULT_SHA256,"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn retry_2_recovery_safe_record(",
                endingBefore: "fn retry_2_recovery_transition_record(",
                target: "RECOVERY_RETRY_2_RESERVE_SIZE,\n            RECOVERY_RETRY_2_RESERVE_SIZE,",
                replacement: "RECOVERY_RETRY_2_RESERVE_SIZE,\n            RECOVERY_RETRY_2_GUARDIAN_SIZE,"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_pinned_system_binary(",
                endingBefore: "fn parse_core_audio_launch_state(",
                target: "metadata.permissions().mode() & 0o7777 == expected_mode",
                replacement: "metadata.permissions().mode() & 0o777 == expected_mode"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_pinned_system_binary(",
                endingBefore: "fn parse_core_audio_launch_state(",
                target: "if !matches!(expected_mode, 0o755 | 0o4755)",
                replacement: "if !matches!(expected_mode, 0o755)"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn read_core_audio_generation_root(",
                endingBefore: "fn reload_core_audio_root(",
                target: #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)?;"#,
                replacement: #"require_pinned_system_binary(Path::new("/bin/ps"), 0o755, EXPECTED_PS_SHA256)?;"#
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn paired_v7_self_test(",
                endingBefore: "fn self_test_controller_binary_identity_binding(",
                target: #"require_pinned_system_binary(Path::new("/bin/ps"), 0o4755, EXPECTED_PS_SHA256)?;"#,
                replacement: ""
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn paired_v7_self_test(",
                endingBefore: "fn self_test_controller_binary_identity_binding(",
                target: "Path::new(\"/bin/launchctl\"),\n            0o4755,",
                replacement: "Path::new(\"/bin/launchctl\"),\n            0o755,"
            ),
            controller.replacingOccurrences(
                of: "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2-v2",
                with: "/Library/Application Support/opensteamer/privileged-v7-recovery-retry-2"
            ),
            controller.replacingOccurrences(
                of: "--root-attest-v7-retry-2-safe-state-v2",
                with: "--root-attest-v7-retry-2-safe-state"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE: u64 = 27_803_148;",
                with: "const RETAINED_ROOT_V7_RECOVERY_V1_SUPPORT_INODE: u64 = 1;"
            ),
            controller.replacingOccurrences(
                of: "b763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317",
                with: "c763b2eaec3d3c0a9d6ae558f0f55c6c478237a22baedf99d42945584347f317"
            ),
            controller.replacingOccurrences(
                of: "030450c1027f4e0d36fabf66471248e4ef9690e1b30d2d3961db4f1cae0ffdd6",
                with: "130450c1027f4e0d36fabf66471248e4ef9690e1b30d2d3961db4f1cae0ffdd6"
            ),
            controller.replacingOccurrences(
                of: "41c5042ed37c13692cb4d11fc8e039d0008d8038b7240175920b0338701737a7",
                with: "51c5042ed37c13692cb4d11fc8e039d0008d8038b7240175920b0338701737a7"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_exact_retained_root_recovery_v1_file(",
                endingBefore: "fn require_retained_root_recovery_v1(",
                target: "metadata.permissions().mode() & 0o7777 == expected_mode",
                replacement: "metadata.permissions().mode() & 0o777 == expected_mode"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_retained_root_recovery_v1(",
                endingBefore: "fn require_exact_root_transaction_children(",
                target: "if names\n                != [",
                replacement: "if false && names\n                != ["
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn sudo_retained_root_recovery_v1_stat(",
                endingBefore: "fn require_retained_root_recovery_v1_via_sudo(",
                target: #""%u:%g:%l:%Mp%Lp:%HT:%d:%i:%z:%f""#,
                replacement: #""%u:%g:%l:%Lp:%HT:%d:%i:%z:%f""#
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_retained_root_recovery_v1_via_sudo(",
                endingBefore: "fn read_root_controller_identity_records_via_sudo(",
                target: "if sudo_stat(pending)?.is_some()",
                replacement: "if false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_retained_root_recovery_v1_via_sudo(",
                endingBefore: "fn read_root_controller_identity_records_via_sudo(",
                target: "if after != before",
                replacement: "if false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn publish_root_recovery_controller(",
                endingBefore: "fn bootstrap_root_recovery_controller_identity(",
                target: "require_retained_root_recovery_v1()?;",
                replacement: ""
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn bootstrap_root_owned_v7_recovery_controller(",
                endingBefore: "fn attest_retry_2_root_safe_state_via_sudo(",
                target: "require_retained_root_recovery_v1_via_sudo()?;",
                replacement: ""
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn attest_retry_2_root_safe_state_via_sudo(",
                endingBefore: "fn spawn_bounded_line_reader",
                target: "require_retained_root_recovery_v1_via_sudo()?;",
                replacement: ""
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn bootstrap_root_owned_v7_recovery_controller(",
                endingBefore: "fn attest_retry_2_root_safe_state_via_sudo(",
                target: "ROOT_V7_RECOVERY_CONTROLLER,\n            ROOT_V7_RECOVERY_CONTROLLER_BOOTSTRAP_MODE,",
                replacement: "RETAINED_ROOT_V7_RECOVERY_V1_CONTROLLER,\n            ROOT_V7_RECOVERY_CONTROLLER_BOOTSTRAP_MODE,"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn paired_v7_self_test(",
                endingBefore: "fn self_test_controller_binary_identity_binding(",
                target: #"if require_pinned_system_binary(Path::new("/bin/ps"), 0o755, EXPECTED_PS_SHA256).is_ok()"#,
                replacement: "if false"
            ),
            replacingInFunction(
                controller,
                beginningWith: "fn require_no_openers_root(",
                endingBefore: "fn require_no_extended_attributes_root(",
                target: "Path::new(\"/usr/sbin/lsof\"),\n            0o755,",
                replacement: "Path::new(\"/usr/sbin/lsof\"),\n            0o4755,"
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "retry-2 recovery mutant \(index) was inert")
            XCTAssertFalse(
                hasEvidencePreservingRetry2CriticalRecoveryContract(
                    controller: mutant,
                    launcher: launcher
                ),
                "retry-2 recovery source contract accepted mutant \(index)"
            )
        }
    }

    func testV7RetryNamespacePreservesPriorFailedEvidenceAndRejectsMutants() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        if controller.contains("paired-v7-update-retry-3-") {
            XCTAssertTrue(hasRetry3TerminalNamespaceContract(controller))
            let retry3NamespaceMutants = [
                controller.replacingOccurrences(
                    of: #".strip_prefix("paired-v7-update-retry-3-")"#,
                    with: #".strip_prefix("paired-v7-update-retry-2-")"#
                ),
                controller.replacingOccurrences(
                    of: #""paired-v7-update-retry-3-{}-{}-{}""#,
                    with: #""paired-v7-update-retry-2-{}-{}-{}""#
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_v7_retained_triplet",
                    endingBefore: "    fn require_exact_v7_root_quartet",
                    target: "                RECOVERY_RETRY_2_NAME,\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_exact_v7_root_quartet",
                    endingBefore: "    fn require_retry_v7_pointer_expectation",
                    target: "                current_name,\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_retry_v7_pointer_expectation",
                    endingBefore: "    fn require_current_retry_v7_layout",
                    target: "            Path::new(RETRY_2_V7_ACTIVE_UPDATE),\n",
                    replacement: "            Path::new(V7_ACTIVE_UPDATE),\n"
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn require_no_v7_pending_pointers",
                    endingBefore: "    fn require_exact_retained_v7_top_level",
                    target: "                || name.starts_with(RETRY_2_V7_PENDING_PREFIX)\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn execute_paired_v7_update",
                    endingBefore: "    fn perform_paired_v7_update",
                    target: "        require_retry_3_root_admission_via_sudo()?;\n",
                    replacement: ""
                ),
                replacingInFunction(
                    controller,
                    beginningWith: "    fn uid501_driver_broker_proxy",
                    endingBefore: "    fn existing_v7_layout_for_restore_proxy",
                    target: "        require_current_retry_v7_layout(\n",
                    replacement: "        verify_update_pointer_at(\n"
                ),
            ]
            for (index, mutant) in retry3NamespaceMutants.enumerated() {
                XCTAssertNotEqual(mutant, controller, "retry3 namespace mutant \(index) was inert")
                XCTAssertFalse(
                    hasRetry3TerminalNamespaceContract(mutant),
                    "retry3 namespace contract accepted mutant \(index)"
                )
            }
            return
        }
        XCTAssertTrue(hasEvidencePreservingRetryNamespaceContract(controller))

        let retainedRoot =
            "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7"
        let retry2Pointer =
            "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-2"
        let retry1Pointer =
            "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-1"
        let firstAttemptPointer =
            "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7"
        let mutants = [
            controller.replacingOccurrences(
                of: "        \"\(retainedRoot)\";\n    const V7_ACTIVE_UPDATE",
                with: "        \"\(retainedRoot)-retry-1\";\n    const V7_ACTIVE_UPDATE"
            ),
            controller.replacingOccurrences(of: retry2Pointer, with: firstAttemptPointer),
            controller.replacingOccurrences(
                of: "        \"\(firstAttemptPointer)\";\n    const RETRY_1_V7_ACTIVE_UPDATE",
                with: "        \"\(retry2Pointer)\";\n    const RETRY_1_V7_ACTIVE_UPDATE"
            ),
            controller.replacingOccurrences(
                of: "        \"\(retry1Pointer)\";\n    const FIRST_ATTEMPT_V7_PENDING_PREFIX",
                with: "        \"\(retry2Pointer)\";\n    const FIRST_ATTEMPT_V7_PENDING_PREFIX"
            ),
            controller.replacingOccurrences(
                of: "paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25",
                with: "paired-v7-update-retry-1-1787373601-48365-wrong-attempt"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_INODE: u64 = 27_758_526;",
                with: "const RETAINED_FAILED_V7_RETRY_1_INODE: u64 = 27_758_527;"
            ),
            controller.replacingOccurrences(
                of: "606dd930e931ef96c1f028d4693473b39ad5c24fede939ed961d0e5c8b12aa70",
                with: "706dd930e931ef96c1f028d4693473b39ad5c24fede939ed961d0e5c8b12aa70"
            ),
            controller.replacingOccurrences(
                of: "41a2e81d30d176f32dec89c1a770e0181695a3cb00428d09dcb449411d802827",
                with: "51a2e81d30d176f32dec89c1a770e0181695a3cb00428d09dcb449411d802827"
            ),
            controller.replacingOccurrences(
                of: "dba0fc40a54e28fee8a7ec55220d94be596097c4167466510a2808d1fb3ba114",
                with: "eba0fc40a54e28fee8a7ec55220d94be596097c4167466510a2808d1fb3ba114"
            ),
            controller.replacingOccurrences(
                of: "bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1",
                with: "cfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1"
            ),
            controller.replacingOccurrences(
                of: "42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75",
                with: "52819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75"
            ),
            controller.replacingOccurrences(
                of: "19c00bad374b30b1ea7d9e6ed23c3c2cd8c26e7e48a8aa059bb1eb7ffd15a3fb",
                with: "29c00bad374b30b1ea7d9e6ed23c3c2cd8c26e7e48a8aa059bb1eb7ffd15a3fb"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_PROBES_INODE: u64 = 27_764_883;",
                with: "const RETAINED_FAILED_V7_RETRY_1_PROBES_INODE: u64 = 27_764_884;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_FAILED_NEW_INODE: u64 = 27_758_528;",
                with: "const RETAINED_FAILED_V7_RETRY_1_FAILED_NEW_INODE: u64 = 27_758_529;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_ROLLBACK_CURRENT_INODE: u64 = 27_758_527;",
                with: "const RETAINED_FAILED_V7_RETRY_1_ROLLBACK_CURRENT_INODE: u64 = 27_758_528;"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE,",
                with: "RETAINED_FAILED_V7_PUBLIC_PROBE_SIZE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256,",
                with: "RETAINED_FAILED_V7_PUBLIC_PROBE_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE,",
                with: "RETAINED_FAILED_V7_GUARDIAN_SIZE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256,",
                with: "RETAINED_FAILED_V7_GUARDIAN_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE,",
                with: "RETAINED_FAILED_V7_MIRROR_PROBE_SIZE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256,",
                with: "RETAINED_FAILED_V7_MIRROR_PROBE_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_RESULT,",
                with: "RETAINED_FAILED_V7_RESULT,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_RESULT_SHA256,",
                with: "RETAINED_FAILED_V7_RESULT_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_JOURNAL,",
                with: "RETAINED_FAILED_V7_JOURNAL,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_JOURNAL_SHA256,",
                with: "RETAINED_FAILED_V7_JOURNAL_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_PROVENANCE,",
                with: "RETAINED_FAILED_V7_PROVENANCE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_PROVENANCE_SHA256,",
                with: "RETAINED_FAILED_V7_PROVENANCE_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SIZE,",
                with: "RETAINED_FAILED_V7_SOURCE_TAR_SIZE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256,",
                with: "RETAINED_FAILED_V7_SOURCE_TAR_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SIZE,",
                with: "RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SIZE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256,",
                with: "RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE,",
                with: "RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SIZE,"
            ),
            controller.replacingOccurrences(
                of: "RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SHA256,",
                with: "RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SHA256,"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_RESULT: &str =\n        \"result=failed-before-stop\\ndiagnostic=",
                with: "const RETAINED_FAILED_V7_RETRY_1_RESULT: &str =\n        \"result=rolled-back\\ndiagnostic="
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_JOURNAL: &str =\n        \"OPENSTEAMER_PAIRED_HOST_UPDATE_V7\\nSTATE BEGUN",
                with: "const RETAINED_FAILED_V7_RETRY_1_JOURNAL: &str =\n        \"OPENSTEAMER_PAIRED_HOST_UPDATE_V7\\nSTATE COMMITTED"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_PROVENANCE: &str =\n        \"commit=17c61bafcbef3e873bbd25789e3c516379bbac91",
                with: "const RETAINED_FAILED_V7_RETRY_1_PROVENANCE: &str =\n        \"commit=0000000000000000000000000000000000000000"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256: &str =\n        \"bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1\";",
                with: "const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256: &str =\n        \"cfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1\";"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256: &str =\n        \"42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75\";",
                with: "const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256: &str =\n        \"52819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75\";"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE: u64 = 82;",
                with: "const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE: u64 = 83;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE: u64 = 154_912;",
                with: "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE: u64 = 154_913;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256: &str =\n        \"0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8\";",
                with: "const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256: &str =\n        \"1ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8\";"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE: u64 = 286_968;",
                with: "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE: u64 = 286_969;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256: &str =\n        \"53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c\";",
                with: "const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256: &str =\n        \"63ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c\";"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE: u64 = 1_096_944;",
                with: "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE: u64 = 1_096_945;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256: &str =\n        \"13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b\";",
                with: "const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256: &str =\n        \"23f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b\";"
            ),
            controller.replacingOccurrences(
                of: "paired-v7-update-1787367704-92913-bba21548-458c-4d31-bd0a-eccdb282c02a",
                with: "paired-v7-update-1787367704-92913-wrong-attempt"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_ATTEMPT_INODE: u64 = 27_737_656;",
                with: "const RETAINED_FAILED_V7_ATTEMPT_INODE: u64 = 27_737_657;"
            ),
            controller.replacingOccurrences(
                of: "a2c6cc1df53d424a97cf6aca55672b7eeb39a6d528aa63315c1e878ab429adc4",
                with: "b2c6cc1df53d424a97cf6aca55672b7eeb39a6d528aa63315c1e878ab429adc4"
            ),
            controller.replacingOccurrences(
                of: "result=failed-before-stop\\ndiagnostic=",
                with: "result=rolled-back\\ndiagnostic="
            ),
            controller.replacingOccurrences(
                of: "cdc94d9d88b6e12e41f485c217f9f88bbfc5621f226079501ee94b8512b80c3a",
                with: "ddc94d9d88b6e12e41f485c217f9f88bbfc5621f226079501ee94b8512b80c3a"
            ),
            controller.replacingOccurrences(
                of: "commit=1ec63de7b4f6721cf7b04b7445f54f0e33f8b3a0",
                with: "commit=8a42a04e63a87890757e6eca1201de1aad3ad36c"
            ),
            controller.replacingOccurrences(
                of: "tree=c343c0bac2d77036e7f3a78dacc3cbf48e83b7ee",
                with: "tree=0000000000000000000000000000000000000000"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_SOURCE_TAR_INODE: u64 = 27_737_662;",
                with: "const RETAINED_FAILED_V7_SOURCE_TAR_INODE: u64 = 27_737_663;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_SOURCE_TAR_SIZE: u64 = 12_584_960;",
                with: "const RETAINED_FAILED_V7_SOURCE_TAR_SIZE: u64 = 12_584_961;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_INODE: u64 = 27_738_086;",
                with: "const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_INODE: u64 = 27_738_087;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_INODE: u64 = 27_737_660;",
                with: "const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_INODE: u64 = 27_737_661;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_PROBES_INODE: u64 = 27_743_975;",
                with: "const RETAINED_FAILED_V7_PROBES_INODE: u64 = 27_743_976;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_PUBLIC_PROBE_INODE: u64 = 27_743_999;",
                with: "const RETAINED_FAILED_V7_PUBLIC_PROBE_INODE: u64 = 27_744_000;"
            ),
            controller.replacingOccurrences(
                of: "a59c39bfc198546729a430e7cdbfd19d982e30697c7e67e3a4bd72ca49304e1e",
                with: "b59c39bfc198546729a430e7cdbfd19d982e30697c7e67e3a4bd72ca49304e1e"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_FAILED_NEW_INODE: u64 = 27_737_658;",
                with: "const RETAINED_FAILED_V7_FAILED_NEW_INODE: u64 = 27_737_659;"
            ),
            controller.replacingOccurrences(
                of: "const RETAINED_FAILED_V7_ROLLBACK_CURRENT_INODE: u64 = 27_737_657;",
                with: "const RETAINED_FAILED_V7_ROLLBACK_CURRENT_INODE: u64 = 27_737_658;"
            ),
            controller.replacingOccurrences(
                of: "            Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            Path::new(RETRY_1_V7_ACTIVE_UPDATE),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        require_path_absent(Path::new(V7_ACTIVE_UPDATE), \"retry paired-v7 pointer\")?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        if entries.next().transpose()?.is_some() {\n",
                with: "        if entries.next().transpose()?.is_none() {\n"
            ),
            controller.replacingOccurrences(
                of: "            .custom_flags(O_NOFOLLOW)\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "&retained.join(\"result.txt\")",
                with: "&retained.join(\"other.txt\")"
            ),
            controller.replacingOccurrences(
                of: "b2205b990a7dc7773a8f65730179566a91999315e6769112b682070d3fbb7dc6",
                with: "c2205b990a7dc7773a8f65730179566a91999315e6769112b682070d3fbb7dc6"
            ),
            controller.replacingOccurrences(
                of: "upstream=origin/agent/auto-select-iphone-microphone",
                with: "upstream=origin/main"
            ),
            controller.replacingOccurrences(
                of: "D:production-driver-v7",
                with: "F:production-driver-v7"
            ),
            controller.replacingOccurrences(
                of: "        require_no_v7_pending_pointers()?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            Path::new(RETAINED_FAILED_V7_INSTALL_HOLD),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            Path::new(RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            &retained.join(\"rollback-reserve.bin\"),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            &retained.join(\"driver-transaction-record.txt\"),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            Path::new(ROOT_V7_SUPPORT_DIRECTORY),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            Path::new(ROOT_V7_TRANSACTION_PARENT),\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "rename_exclusive(&pending, Path::new(V7_ACTIVE_UPDATE))?;",
                with: "rename_exclusive(&pending, Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE))?;"
            ),
            controller.replacingOccurrences(
                of: "paired-v7-update-retry-2-{}-{}-{}",
                with: "paired-v7-update-{}-{}-{}"
            ),
            controller.replacingOccurrences(
                of: "            || evidence.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            || evidence.to_str() == Some(RETAINED_FAILED_V7_ATTEMPT)\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            || evidence.to_str() == Some(RETAINED_FAILED_V7_RETRY_1)\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: #".strip_prefix("paired-v7-update-retry-2-")"#,
                with: #".strip_prefix("paired-v7-update-retry-1-")"#
            ),
            controller.replacingOccurrences(
                of: "            RetryV7PointerExpectation::Present => verify_update_pointer_at(\n                Path::new(V7_ACTIVE_UPDATE),\n                evidence,\n                Path::new(V7_UPDATE_ROOT),\n            ),",
                with: "            RetryV7PointerExpectation::Present => verify_update_pointer_at(\n                Path::new(V7_ACTIVE_UPDATE),\n                Path::new(RETAINED_FAILED_V7_ATTEMPT),\n                Path::new(V7_UPDATE_ROOT),\n            ),"
            ),
            controller.replacingOccurrences(
                of: "actual != expected",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: "        require_exact_retained_v7_evidence(data_volume_device)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        require_exact_retained_retry_1_v7_evidence(data_volume_device)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                RETAINED_FAILED_V7_RETRY_1_NAME,\n",
                with: "                RETAINED_FAILED_V7_ATTEMPT_NAME,\n"
            ),
            controller.replacingOccurrences(
                of: "retry_metadata.ino() != retry_after.ino()",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        create_private_directory(&evidence)?;\n        require_current_retry_v7_layout(",
                with: "        create_private_directory(&evidence)?;\n        let _omitted_retry_layout = ("
            ),
            controller.replacingOccurrences(
                of: "        let boundary_provenance = verify_paired_v7_git_provenance(&layout.repo, true)?;",
                with: "        let boundary_provenance = verify_paired_v7_git_provenance(&layout.repo, true)?; // require_current_retry_v7_layout omitted"
            ).replacingOccurrences(
                of: "        require_current_retry_v7_layout(\n            &layout.evidence,\n            Some(&layout.nonce),\n            RetryV7PointerExpectation::Absent,\n        )?;\n        let boundary_provenance",
                with: "        let boundary_provenance"
            ),
            controller.replacingOccurrences(
                of: "        require_current_retry_v7_layout(\n            &layout.evidence,\n            Some(&layout.nonce),\n            RetryV7PointerExpectation::Absent,\n        )?;\n        let mut broker = RootDriverBrokerClient::start(layout)?;",
                with: "        let mut broker = RootDriverBrokerClient::start(layout)?;"
            ),
            controller.replacingOccurrences(
                of: "        journal.record(V7State::DriverPrepared, &[])?;\n\n        require_current_retry_v7_layout(",
                with: "        journal.record(V7State::DriverPrepared, &[])?;\n\n        let _omitted_post_broker_layout = ("
            ),
            controller.replacingOccurrences(
                of: "        let transaction = (|| -> Result<LaunchGeneration> {",
                with: "        let transaction = (|| -> Result<LaunchGeneration> { // require_current_retry_v7_layout omitted"
            ).replacingOccurrences(
                of: "        require_current_retry_v7_layout(\n            &layout.evidence,\n            Some(&layout.nonce),\n            RetryV7PointerExpectation::Absent,\n        )?;\n        let transaction",
                with: "        let transaction"
            ),
            controller.replacingOccurrences(
                of: "        require_current_retry_v7_layout(\n            evidence,\n            Some(nonce),\n            pointer_expectation,\n        )?;\n        let layout =\n            v7_layout_from_existing(PathBuf::from(V7_EXPECTED_REPO), evidence.to_path_buf())?;",
                with: "        let layout =\n            v7_layout_from_existing(PathBuf::from(V7_EXPECTED_REPO), evidence.to_path_buf())?;"
            ),
            controller.replacingOccurrences(
                of: "        require_current_retry_v7_layout(\n            &evidence,\n            None,\n            RetryV7PointerExpectation::Present,\n        )?;\n        let layout = v7_layout_from_existing(repo, evidence)?;",
                with: "        let layout = v7_layout_from_existing(repo, evidence)?;"
            ),
            controller.replacingOccurrences(
                of: "    fn verify_v7_active_pointer(expected_evidence: &Path) -> Result<()> {\n        require_current_retry_v7_layout(",
                with: "    fn verify_v7_active_pointer(expected_evidence: &Path) -> Result<()> {\n        verify_update_pointer_at("
            ),
            controller.replacingOccurrences(
                of: "        require_current_retry_v7_layout(\n            &layout.evidence,\n            Some(&layout.nonce),\n            pointer_expectation,\n        )?;\n        retire_update_pointer_at(",
                with: "        retire_update_pointer_at("
            ),
            controller.replacingOccurrences(
                of: "            retire_exact_retry_v7_pending_pointer_after_parent_crash(\n                &layout.evidence,\n                expected_main_pid,\n            )?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "{V7_ACTIVE_UPDATE}.pending-{expected_main_pid}",
                with: "{V7_ACTIVE_UPDATE}.pending-{}"
            ),
            controller.replacingOccurrences(
                of: "            || pid != Some(expected_main_pid)\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            if name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)\n                || name.starts_with(RETRY_1_V7_PENDING_PREFIX)\n                || name.starts_with(RETRY_V7_PENDING_PREFIX)\n",
                with: "            if name.starts_with(RETRY_V7_PENDING_PREFIX)\n"
            ),
            controller.replacingOccurrences(
                of: "                if name != pending_name || entry.path().to_str() != pending.to_str() {\n",
                with: "                if false {\n"
            ),
            controller.replacingOccurrences(
                of: "        let expected_bytes = format!(\"{}\\n\", evidence.display());",
                with: "        let expected_bytes = format!(\"{}\\n\", RETAINED_FAILED_V7_ATTEMPT);"
            ),
            controller.replacingOccurrences(
                of: "            rename_exclusive(&pending, &retired)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            || descriptor_before.ino() != retired_after.ino()\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                        uid_proxy_complete_host_crash_rollback(&layout, parent_pid)?;",
                with: "                        uid_proxy_complete_host_crash_rollback(&layout, std::process::id())?;"
            ),
            controller.replacingOccurrences(
                of: "        if let Err(error) = require_current_retry_v7_layout(\n            &layout.evidence,\n            Some(&layout.nonce),\n            RetryV7PointerExpectation::Present,\n        ) {\n            return rollback_ready_commit_failure(error, &mut broker, journal);\n        }\n        if let Err(error) = journal.record(V7State::Committed, &[]) {",
                with: "        if let Err(error) = journal.record(V7State::Committed, &[]) {"
            ),
            controller.replacingOccurrences(
                of: "matches!(journal.state, V7State::StopInitiated | V7State::RolledBack);",
                with: "matches!(journal.state, V7State::StopInitiated | V7State::RollbackStarted | V7State::RolledBack);"
            ),
            controller.replacingOccurrences(
                of: "matches!(journal.state, V7State::StopInitiated | V7State::RolledBack);",
                with: "matches!(journal.state, V7State::StopInitiated | V7State::DriverRestored | V7State::RolledBack);"
            ),
            controller.replacingOccurrences(
                of: "                    retire_exact_retry_v7_pending_pointer_after_parent_crash(\n                        &layout.evidence,\n                        std::process::id(),\n                    )?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        pointer_expectation: RetryV7PointerExpectation,\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            if active_evidence.to_str() != evidence.to_str() {\n",
                with: "            if false {\n"
            ),
            controller.replacingOccurrences(
                of: "                    RetryV7PointerExpectation::from_token(pointer_expectation)?;",
                with: "                    RetryV7PointerExpectation::Present;"
            ),
            controller.replacingOccurrences(
                of: "existing_v7_layout_for_restore_proxy(nonce, evidence, pointer_expectation)?;",
                with: "existing_v7_layout_for_restore_proxy(\n                nonce,\n                evidence,\n                RetryV7PointerExpectation::Present,\n            )?;"
            ),
            controller.replacingOccurrences(
                of: "                    evidence,\n                    pointer_expectation_token,\n",
                with: "                    path_text(Path::new(RETAINED_FAILED_V7_ATTEMPT))?,\n                    pointer_expectation_token,\n"
            ),
            controller.replacingOccurrences(
                of: "            Some(RootExistingDriverRestoreClient::start(\n                layout,\n                pointer_expectation,\n            )?)",
                with: "            Some(RootExistingDriverRestoreClient::start(\n                layout,\n                RetryV7PointerExpectation::Present,\n            )?)"
            ),
            controller.replacingOccurrences(
                of: "                Path::new(&evidence),\n                pointer_expectation,\n                parent_pid,",
                with: "                Path::new(RETAINED_FAILED_V7_ATTEMPT),\n                pointer_expectation,\n                parent_pid,"
            ),
            controller.replacingOccurrences(
                of: "                Path::new(&evidence),\n                pointer_expectation,\n                parent_pid,",
                with: "                Path::new(&evidence),\n                RetryV7PointerExpectation::Present,\n                parent_pid,"
            ),
            controller.replacingOccurrences(
                of: "        rollback_to_current_baseline(\n            layout,\n            &mut journal,\n            &transaction_lock,\n            pointer_expectation,\n        )?;",
                with: "        if pointer_expectation == RetryV7PointerExpectation::Present {\n            rollback_to_current_baseline(\n                layout,\n                &mut journal,\n                &transaction_lock,\n                pointer_expectation,\n            )?;\n        }"
            ),
            controller.replacingOccurrences(
                of: "        rollback_to_current_baseline(\n            layout,\n            &mut journal,\n            &transaction_lock,\n            pointer_expectation,\n        )?;",
                with: "        rollback_to_current_baseline(\n            layout,\n            &mut journal,\n            &transaction_lock,\n            RetryV7PointerExpectation::Present,\n        )?;"
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "retry namespace mutant \(index) was inert")
            XCTAssertFalse(
                hasEvidencePreservingRetryNamespaceContract(mutant),
                "retry namespace source contract accepted mutant \(index)"
            )
        }
    }

    func testV7RemainsProductionOnlyAndHasExactFinalReleasePins() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        let launcher = try source("macOS/scripts/update-opensteamer-host-paired-v7.sh")

        XCTAssertTrue(
            controller.contains(#"const RELEASE_PIN_STATUS: &str = "PINNED_FINAL_REVIEW";"#)
        )
        XCTAssertTrue(launcher.contains("RELEASE_PIN_STATUS='PINNED_FINAL_REVIEW'"))
        let expectedControllerSourceSHA256 =
            "da254e4bd5d829be4a66031320ff47c8bf2f8379e2d2dbeaa51df94836a65804"
        XCTAssertTrue(
            hasExactLauncherSourcePinContract(
                controller: controller,
                launcher: launcher,
                expectedSHA256: expectedControllerSourceSHA256
            )
        )
        XCTAssertTrue(
            launcher.contains(
                "EXPECTED_BINARY_SHA256='0e70c2f4b9be266b793ad307a51be9c7c798b37c15abd83f2235d132439938e9'"
            )
        )
        let exactControllerReleasePins = [
            "opensteamer-production-v7",
            "2BD65FABE76E3155726886963F8836E0048440E2",
            "39FE8277467264AAAFDAAE6A74E68F99FE8B3461",
            "4021696842E07336784376884D24969D9A94654A54F5B0C5C8FBC3C8C5D599AE",
            "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v7/production-driver-v7",
            "88c842ec87374b6cbf1f5de32ae7788e15cf42f81fcb9213952ea8338a11f1a1",
            "fdef1da4413f66d5f066c86b0eba709b55c74b1f72b29dac8d62e991a2343ca6",
            "f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49",
            "ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866",
            "e2b13dde169a7994a50b819e414212e884136b0ab0c40c482531b8f8dc2a3f45",
            "3c6baf8474bd5f2ed807f74bd910a9e057bfcf384e54f6b66aadeb1634554383",
            "13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b",
            "88a8a3d7cced350337e6624d010efc0c061d9f23ed1ce8e72f626494c14f1b2d",
            "cbb5cf76c51119e9d232f2cee3c8d4d66c3fc85fa8611a09436587becec6ad2b",
            "31bd71470968758c1809d5475dfc1a7b823b7b5db2cbe889b6660f84f1907aab",
            "4ec4cf52b5bb79eae45b6965e97912f23041a3d879b3814b67763caded0548dd",
            "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8",
            "f152ef8d05eed29c5918666be31821e5ef6e325351d2fcf4ad5f8b83987e299c",
            "53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c",
            "91e1da8c84d47f05dd4dc19a84418a946238b1e411cf09d0dd3fb275babc88d5",
            "290731edd02baf42ca40f43f11f74d75271617a46393184cb4d0d566a147257e",
            "25293a4c83b5c6a6e1c95a95388d596f56057e5c5a54add0756017cfc6b0deac",
            "2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb",
            "7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a",
            "7beb049226ada83e97afba3e60089469d0eeeef6",
        ]
        for pin in exactControllerReleasePins {
            XCTAssertTrue(controller.contains("\"\(pin)\";"), "missing exact release pin: \(pin)")
        }
        XCTAssertTrue(controller.contains("Developer ID Application"))
        XCTAssertTrue(controller.contains("Developer ID Installer"))
        XCTAssertTrue(controller.contains("MSMG8CJLB3"))
        XCTAssertTrue(controller.contains("notarytool"))
        XCTAssertTrue(controller.contains("EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256"))
        XCTAssertFalse(controller.contains("--local-uncommitted-trial"))
        let sourceComparison =
            "[ \"$(/usr/bin/shasum -a 256 \"$SOURCE\" | /usr/bin/awk '{print $1}')\" = \\\n  \"$EXPECTED_SOURCE_SHA256\" ]"
        let sourcePinMutant = launcher.replacingOccurrences(
            of: sourceComparison,
            with: "true"
        )
        XCTAssertNotEqual(sourcePinMutant, launcher, "launcher source-pin mutant was inert")
        XCTAssertFalse(
            hasExactLauncherSourcePinContract(
                controller: controller,
                launcher: sourcePinMutant,
                expectedSHA256: expectedControllerSourceSHA256
            ),
            "launcher source-hash comparison bypass was accepted"
        )
    }

    func testV7RollbackReserveDeviceIsDerivedFromExactDataVolumeAndRejectsMutants() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        XCTAssertTrue(hasRebootStableRollbackReserveDeviceContract(controller))

        let mutants = [
            controller.replacingOccurrences(
                of: #"const EXPECTED_DATA_VOLUME_UUID: &str = "AF638805-E0CB-4356-941F-16B84DFB6435";"#,
                with: #"const EXPECTED_DATA_VOLUME_UUID: &str = "00000000-0000-0000-0000-000000000000";"#
            ),
            controller.replacingOccurrences(
                of: #"const EXPECTED_DATA_VOLUME_GROUP_UUID: &str = "AF638805-E0CB-4356-941F-16B84DFB6435";"#,
                with: #"const EXPECTED_DATA_VOLUME_GROUP_UUID: &str = "00000000-0000-0000-0000-000000000000";"#
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_DATA_VOLUME_MOUNT: &str = "/System/Volumes/Data";"#,
                with: #"const PINNED_DATA_VOLUME_MOUNT: &str = "/System/Volumes/Wrong";"#
            ),
            controller.replacingOccurrences(
                of: #"("FilesystemType", "apfs")"#,
                with: #"("FilesystemType", "hfs")"#
            ),
            controller.replacingOccurrences(
                of: #"if !exact_plist_boolean(plist, "Internal")?"#,
                with: #"if exact_plist_boolean(plist, "Internal")?"#
            ),
            controller.replacingOccurrences(
                of: #"if !exact_plist_boolean(plist, "Writable")?"#,
                with: #"if exact_plist_boolean(plist, "Writable")?"#
            ),
            controller.replacingOccurrences(
                of: "let mount_before = data_volume_mount_identity()?;",
                with: "let mount_before = mount_after;"
            ),
            controller.replacingOccurrences(
                of: "let mount_after = data_volume_mount_identity()?;",
                with: "let mount_after = mount_before;"
            ),
            controller.replacingOccurrences(
                of: "        if mount_after != mount_before {\n",
                with: "        if false {\n"
            ),
            controller.replacingOccurrences(
                of: "        validate_data_volume_plist(decode_utf8(\n",
                with: "        decode_utf8(\n"
            ),
            controller.replacingOccurrences(
                of: "reserve_metadata.dev() != data_volume_device",
                with: "reserve_metadata.dev() != 16_777_229"
            ),
            controller.replacingOccurrences(
                of: "const COMMITTED_V5_RESERVE_INODE: u64 = 25_430_692;",
                with: "const COMMITTED_V5_RESERVE_INODE: u64 = 25_430_693;"
            ),
            controller.replacingOccurrences(
                of: "const COMMITTED_V6_RESERVE_INODE: u64 = 25_795_487;",
                with: "const COMMITTED_V6_RESERVE_INODE: u64 = 25_795_488;"
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_DATA_VOLUME_DISKUTIL: &str = "/usr/sbin/diskutil";"#,
                with: #"const PINNED_DATA_VOLUME_DISKUTIL: &str = "/tmp/diskutil";"#
            ),
            controller.replacingOccurrences(
                of: "9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049",
                with: String(repeating: "0", count: 64)
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "Data-volume mutant \(index) was inert")
            XCTAssertFalse(
                hasRebootStableRollbackReserveDeviceContract(mutant),
                "Data-volume source contract accepted mutant \(index)"
            )
        }
    }

    func testV7ControllerBinaryPinIsExternalThenRootSealedAndMutationClosed() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        let launcher = try source("macOS/scripts/update-opensteamer-host-paired-v7.sh")
        XCTAssertTrue(
            hasRootSealedV7ControllerIdentityContract(
                controller: controller,
                launcher: launcher
            )
        )

        let controllerMutants = [
            controller.replacingOccurrences(
                of: "require_root_controller_identity_binding(&actual, &sealed)?;",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "require_proxy_controller_identity_binding(&actual, &sealed)?;",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "before.dev() != after.dev()",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: #"sudo_output(&["-n", ROOT_V7_CONTROLLER, ROOT_V7_CONTROLLER_BOOTSTRAP_MODE])?"#,
                with: #"sudo_output(&["-n", ROOT_V7_CONTROLLER, ROOT_V7_CONTROLLER_BOOTSTRAP_MODE, &before.sha256])?"#
            ),
        ]
        for (index, mutant) in controllerMutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "controller identity mutant \(index) was inert")
            XCTAssertFalse(
                hasRootSealedV7ControllerIdentityContract(
                    controller: mutant,
                    launcher: launcher
                ),
                "controller identity source contract accepted mutant \(index)"
            )
        }

        let launcherMutant = launcher.replacingOccurrences(
            of: "[ \"$CONTROLLER_BINARY_SHA256\" = \"$EXPECTED_BINARY_SHA256\" ]",
            with: "true"
        )
        XCTAssertNotEqual(launcherMutant, launcher)
        XCTAssertFalse(
            hasRootSealedV7ControllerIdentityContract(
                controller: controller,
                launcher: launcherMutant
            )
        )
    }

    func testV7ReleaseCycleBindsStrictDescendantAllowlistAndFunctionalInputs() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        XCTAssertTrue(hasTwoCommitV7ReleaseCycleContract(controller))

        let mutants = [
            controller.replacingOccurrences(
                of: "candidate.commit == release_commit || !candidate_is_ancestor",
                with: "candidate.commit == release_commit"
            ),
            controller.replacingOccurrences(
                of: "candidate.tree != resolved_candidate_tree",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: "!RELEASE_ONLY_PATH_ALLOWLIST.contains(&path.as_str())",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: "source_inputs.is_empty() || source_inputs != release_inputs",
                with: "source_inputs.is_empty()"
            ),
            controller.replacingOccurrences(
                of: "actual != expected_functional_inputs_sha256",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: #""--no-renames","#,
                with: ""
            ),
            controller.replacingOccurrences(
                of: "!listing.stdout.ends_with(&[0])",
                with: "false"
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "release-cycle mutant \(index) was inert")
            XCTAssertFalse(
                hasTwoCommitV7ReleaseCycleContract(mutant),
                "release-cycle source contract accepted mutant \(index)"
            )
        }
    }

    func testV7CutoverOrdersDriverAndProbesBeforeHostPublication() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        let perform = try functionBody(
            controller,
            beginningWith: "fn perform_paired_v7_update(",
            endingBefore: "fn rollback_existing_paired_v7_update("
        )
        assertOrdered(
            [
                "RootDriverBrokerClient::start(layout)",
                "V7State::DriverPrepared",
                "V7State::StopInitiated",
                "V7State::CurrentStopped",
                "V7State::CurrentHeld",
                "broker.publish()",
                "V7State::DriverPublished",
                "run_installed_driver_probes(layout, &mut broker)",
                "V7State::ProbesVerified",
                "V7State::NewPublished",
                "bootstrap_exact_new_job()",
                "V7State::ReadyVerified",
            ],
            in: perform
        )
    }

    func testV7DetachedCrashBoundaryRestoresDriverBeforeV6Host() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        XCTAssertGreaterThanOrEqual(
            controller.components(separatedBy: ".process_group(0)").count - 1,
            5
        )
        XCTAssertTrue(controller.contains("require_descriptor_close_on_exec"))
        XCTAssertTrue(controller.contains("exact_broker_parent_is_alive"))
        XCTAssertTrue(controller.contains("self_test_detached_crash_matrix"))
        assertOrdered(
            [
                "root_restore_exact_prior_driver",
                "root_reload_core_audio",
                "journal_driver_restored",
                "uid_restore_exact_v6_app",
                "uid_bootstrap_exact_v6_host",
                "uid_prove_exact_v6_ready",
            ],
            in: controller
        )
    }

    func testV7ProductionVerifierIsSeparateFromLocalAdHocVerifier() throws {
        let production = try source(
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v7.sh"
        )
        let local = try source(
            "macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh"
        )
        XCTAssertTrue(production.contains("Developer ID Application"))
        XCTAssertTrue(production.contains("stapler validate"))
        XCTAssertTrue(production.contains("spctl"))
        XCTAssertTrue(production.contains("installer_leaf_sha256"))
        XCTAssertTrue(local.contains("ad-hoc"))
        XCTAssertFalse(local.contains("Developer ID Application"))
    }

    func testV7ProductionVerifierUsesRealLFForExactLstatManifest() throws {
        let production = try source(
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v7.sh"
        )
        XCTAssertTrue(hasRealLFProductionDriverManifestContract(production))

        let mutant = production.replacingOccurrences(
            of: "expected_nodes_text=\"$(canonical_manifest_text \"${expected_nodes[@]}\")\"",
            with: "expected_nodes_text=\"${(j:\\n:)expected_nodes}\""
        )
        XCTAssertNotEqual(mutant, production)
        XCTAssertFalse(hasRealLFProductionDriverManifestContract(mutant))
    }

    func testV7ProductionXcodeAndToolchainTrustIsExactAndMutationClosed() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        XCTAssertTrue(hasPinnedProductionXcodeTrustContract(controller))

        let mutants = [
            controller.replacingOccurrences(
                of: #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";"#,
                with: #""/Volumes/wrong/Xcode-26.6.0.app";"#
            ),
            controller.replacingOccurrences(
                of: #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";"#,
                with: #""/Volumes//t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";"#
            ),
            controller.replacingOccurrences(
                of: #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";"#,
                with: #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/./Xcode-26.6.0.app";"#
            ),
            controller.replacingOccurrences(
                of: #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";"#,
                with: #""/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/";"#
            ),
            controller.replacingOccurrences(
                of: "application_target.to_str() != Some(PINNED_XCODE_APPLICATION_TARGET)",
                with: "application_target != Path::new(PINNED_XCODE_APPLICATION_TARGET)"
            ),
            controller.replacingOccurrences(
                of: "const PINNED_XCODE_DEVELOPER_UID: u32 = 501;",
                with: "const PINNED_XCODE_DEVELOPER_UID: u32 = 0;"
            ),
            controller.replacingOccurrences(
                of: "const PINNED_XCODE_DEVELOPER_GID: u32 = 20;",
                with: "const PINNED_XCODE_DEVELOPER_GID: u32 = 80;"
            ),
            controller.replacingOccurrences(
                of: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o755;",
                with: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o775;"
            ),
            controller.replacingOccurrences(
                of: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o755;",
                with: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o4755;"
            ),
            controller.replacingOccurrences(
                of: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o755;",
                with: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o2755;"
            ),
            controller.replacingOccurrences(
                of: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o755;",
                with: "const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o1755;"
            ),
            controller.replacingOccurrences(
                of: "resolved_developer_directory.permissions().mode() & 0o7777",
                with: "resolved_developer_directory.permissions().mode() & 0o777"
            ),
            controller.replacingOccurrences(
                of: "            || resolved_developer_directory.file_type().is_symlink()\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "fs::canonicalize(PINNED_XCODE_DEVELOPER_DIR)?",
                with: "PathBuf::from(PINNED_XCODE_DEVELOPER_DIR)"
            ),
            controller.replacingOccurrences(
                of: "canonical_developer_directory != Path::new(PINNED_XCODE_RESOLVED_DEVELOPER_DIR)",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: "let application_target = fs::read_link(application_link)?;",
                with: "let application_target = PathBuf::from(PINNED_XCODE_APPLICATION_TARGET);"
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_XCODE_SWIFTC_ALIAS: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";"#,
                with: #"const PINNED_XCODE_SWIFTC_ALIAS: &str = "/usr/bin/swiftc";"#
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_XCODE_RESOLVED_SWIFTC_ALIAS: &str = "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";"#,
                with: #"const PINNED_XCODE_RESOLVED_SWIFTC_ALIAS: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";"#
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_XCODE_SWIFT_FRONTEND: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend";"#,
                with: #"const PINNED_XCODE_SWIFT_FRONTEND: &str = "/usr/bin/swift-frontend";"#
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_XCODE_CLANG: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang";"#,
                with: #"const PINNED_XCODE_CLANG: &str = "/usr/bin/clang";"#
            ),
            controller.replacingOccurrences(
                of: #"const PINNED_XCODE_SWIFTC_ALIAS_TARGET: &str = "swift-frontend";"#,
                with: #"const PINNED_XCODE_SWIFTC_ALIAS_TARGET: &str = "/usr/bin/swiftc";"#
            ),
            controller.replacingOccurrences(
                of: "2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb",
                with: String(repeating: "0", count: 64)
            ),
            controller.replacingOccurrences(
                of: "7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a",
                with: String(repeating: "0", count: 64)
            ),
            controller.replacingOccurrences(
                of: #"const EXPECTED_XCODE_SWIFTC_VERSION: &str = "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0";"#,
                with: #"const EXPECTED_XCODE_SWIFTC_VERSION: &str = "Apple Swift version 6.3.3";"#
            ),
            controller.replacingOccurrences(
                of: "        if !swiftc_alias_metadata.file_type().is_symlink() {\n",
                with: "        if false {\n"
            ),
            controller.replacingOccurrences(
                of: "swiftc_alias_target.to_str() != Some(PINNED_XCODE_SWIFTC_ALIAS_TARGET)",
                with: "swiftc_alias_target != Path::new(PINNED_XCODE_SWIFTC_ALIAS_TARGET)"
            ),
            controller.replacingOccurrences(
                of: "                || tool_metadata.file_type().is_symlink()\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                || tool_metadata.permissions().mode() & 0o111 == 0\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            if sha256(tool_path)? != expected_sha256 {\n",
                with: "            if false {\n"
            ),
            controller.replacingOccurrences(
                of: #".args(["--sdk", "macosx", "--find", "swiftc"])"#,
                with: #".args(["--sdk", "macosx", "--find", "clang"])"#
            ),
            controller.replacingOccurrences(
                of: #".args(["--sdk", "macosx", "--find", "swiftc"])"#
                    + "\n            .env_clear()",
                with: #".args(["--sdk", "macosx", "--find", "swiftc"])"#
            ),
            controller.replacingOccurrences(
                of: #"format!("{PINNED_XCODE_RESOLVED_SWIFTC_ALIAS}\n")"#,
                with: #"format!("{PINNED_XCODE_SWIFTC_ALIAS}\n")"#
            ),
            controller.replacingOccurrences(
                of: "xcrun_swiftc.stdout.as_slice() != expected_xcrun_swiftc.as_bytes()",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: #".args(["--sdk", "macosx", "swiftc", "--version"])"#,
                with: #".args(["--sdk", "macosx", "clang", "--version"])"#
            ),
            controller.replacingOccurrences(
                of: "let observed_swiftc_version = format!(\"{version_stderr}{version_stdout}\");",
                with: "let observed_swiftc_version = format!(\"{version_stdout}{version_stderr}\");"
            ),
            controller.replacingOccurrences(
                of: "observed_swiftc_version.strip_suffix('\\n') != Some(EXPECTED_XCODE_SWIFTC_VERSION)",
                with: "false"
            ),
            controller.replacingOccurrences(
                of: "        verify_pinned_xcode_developer_directory()?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: #"            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")"#
                    + "\n"
                    + #"            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)"#
                    + "\n"
                    + #"            .env("OPENSTEAMER_HOST_APP_OUTPUT_DIR", &layout.stage_output)"#,
                with: #"            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")"#
                    + "\n"
                    + #"            .env("OPENSTEAMER_HOST_APP_OUTPUT_DIR", &layout.stage_output)"#
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "production Xcode mutant \(index) was inert")
            XCTAssertFalse(
                hasPinnedProductionXcodeTrustContract(mutant),
                "production Xcode source contract accepted mutant \(index)"
            )
        }
    }

    func testGuardianAllowsLegacyVisibleInputButNeverVirtualOutputs() throws {
        let guardian = try source(
            "macOS/VirtualAudioDriver/Probes/V7DefaultRouteGuardian.swift"
        )
        XCTAssertTrue(guardian.contains("isForbiddenRestorationInput"))
        XCTAssertTrue(guardian.contains("isForbiddenOutput"))
        XCTAssertTrue(
            guardian.contains("[Contract.writerUID, Contract.legacyWriterUID].contains(uid)")
        )
        XCTAssertTrue(
            guardian.contains("(Contract.legacyVisibleUID, Contract.visibleUID, .restoreOwnedProduct)")
        )
        XCTAssertFalse(guardian.contains("isVirtual("))
    }

    func testPostPublishGuardianFenceIsDurableOrderedAndMutationClosed() throws {
        let guardian = try source(
            "macOS/VirtualAudioDriver/Probes/V7DefaultRouteGuardian.swift"
        )
        let controller = try source(
            "macOS/scripts/opensteamer-host-local-mono-trial-controller.rs"
        )
        XCTAssertTrue(
            hasPostPublishGuardianFenceContract(
                guardian: guardian,
                controller: controller
            )
        )

        let guardianMutants = [
            guardian.replacingOccurrences(
                of: "observedDefaults != baseline",
                with: "false"
            ),
            guardian.replacingOccurrences(
                of: "Thread.sleep(forTimeInterval: 0.10)",
                with: "Thread.sleep(forTimeInterval: 0.0)"
            ),
            guardian.replacingOccurrences(
                of: "let before = drainAndCheckpoint()",
                with: "let before = counters.snapshot()"
            ),
            guardian.replacingOccurrences(
                of: "second == baseline",
                with: "true"
            ),
            guardian.replacingOccurrences(
                of: "!repairWritten else {",
                with: "true else {"
            ),
            guardian.replacingOccurrences(
                of: "preEpochClosed = true",
                with: "sequence = 0"
            ),
            swappingFirst(
                "to: postPublishFenceResultPath",
                with: "listener.commitPostPublishEpoch(",
                in: guardian
            ),
        ]
        let controllerMutants = [
            controller.replacingOccurrences(
                of: "guardian.exchange_until(\n        \"POST_PUBLISH_FENCE\",\n        \"GUARDIAN_BROKER_POST_PUBLISH_FENCED\",\n        post_publish_guardian_deadline,\n        Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS),\n        \"post-publish guardian fence\",\n    )?;",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "sync_parent_directory(&layout.guardian_post_publish_fence_result)?;",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "if post_publish_fence_hash != verified_post_publish_fence_hash",
                with: "if false"
            ),
            controller.replacingOccurrences(
                of: "verify_guardian_evidence_until(",
                with: "verify_guardian_evidence("
            ),
            controller.replacingOccurrences(
                of: "stable_private_sha256_until(",
                with: "stable_private_sha256("
            ),
            controller.replacingOccurrences(
                of: "POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS,",
                with: "0,"
            ),
            controller.replacingOccurrences(
                of: "post_publish_guardian_deadline,",
                with: "post_publish_guardian_deadline.checked_sub(Duration::from_secs(POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS)).unwrap(),"
            ),
            controller.replacingOccurrences(
                of: "post_publish_fence_deadline,",
                with: "post_publish_fence_deadline.checked_sub(Duration::from_secs(POST_PUBLISH_EXCHANGE_IO_RESERVE_SECONDS)).unwrap(),"
            ),
            controller.replacingOccurrences(
                of: "root.exchange_until(",
                with: "root.exchange_with_timeout("
            ),
            controller.replacingOccurrences(
                of: "let timeout = remaining_phase_timeout(deadline, maximum_response, label)?;",
                with: "let timeout = maximum_response;"
            ),
            controller.replacingOccurrences(
                of: "L1Ciab POST_PUBLISH_FENCE {post_publish_fence_hash}",
                with: "L1Ciab PING"
            ),
            controller.replacingOccurrences(
                of: "checkpoint(e)==v['listener']['postPublishEpochFingerprint']",
                with: "True"
            ),
            controller.replacingOccurrences(
                of: "f['listener']['postPublishEpochFingerprint']==l['listener']['postPublishEpochFingerprint']",
                with: "True"
            ),
        ]
        for (index, mutant) in guardianMutants.enumerated() {
            XCTAssertNotEqual(mutant, guardian, "guardian mutant \(index) was inert")
            XCTAssertFalse(
                hasPostPublishGuardianFenceContract(
                    guardian: mutant,
                    controller: controller
                ),
                "guardian source contract accepted mutant \(index)"
            )
        }
        for (index, mutant) in controllerMutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "controller mutant \(index) was inert")
            XCTAssertFalse(
                hasPostPublishGuardianFenceContract(
                    guardian: guardian,
                    controller: mutant
                ),
                "controller source contract accepted mutant \(index)"
            )
        }
    }

    func testRootProtocolUsesStateSpecificNextCommandIdleBounds() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-local-mono-trial-controller.rs"
        )
        XCTAssertTrue(hasStateSpecificRootIdleContract(controller))
        let mutants = [
            controller.replacingOccurrences(
                of: "Self::PrestopFence => ROOT_WAIT_PRESTOP_AFTER_GATE_SECONDS",
                with: "Self::PrestopFence => ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "Self::PostStopPing => ROOT_WAIT_PING_AFTER_V6_STOP_SECONDS",
                with: "Self::PostStopPing => ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "Self::PostPublishFence => ROOT_WAIT_POST_PUBLISH_FENCE_COMMAND_SECONDS",
                with: "Self::PostPublishFence => ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "Self::PostMirrorPing => ROOT_WAIT_SECOND_PING_AFTER_FENCE_SECONDS",
                with: "Self::PostMirrorPing => ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "Self::CandidateRelease => ROOT_WAIT_RELEASE_AFTER_PROBES_SECONDS",
                with: "Self::CandidateRelease => ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "Self::GuardianReaped => ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS,",
                with: "Self::GuardianReaped => ROOT_BROKER_DEADMAN_SECONDS,"
            ),
            controller.replacingOccurrences(
                of: "Duration::from_secs(expected_command.idle_seconds())",
                with: "Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS)"
            ),
            controller.replacingOccurrences(
                of: "if !expected_command.accepts(&command)",
                with: "if false"
            ),
            controller.replacingOccurrences(
                of: "| Self::Live\n            | Self::RoutesRepaired",
                with: "| Self::RoutesRepaired"
            ),
            controller.replacingOccurrences(
                of: "Self::PrestopFence => command == \"L1Ciab PRESTOP_FENCE\",",
                with: "Self::PrestopFence => command == \"L1Ciab PRESTOP_FENCE\" || command == \"L1Ciab PING\","
            ),
            controller.replacingOccurrences(
                of: "Self::PostPublishFence => command.starts_with(\"L1Ciab POST_PUBLISH_FENCE \"),",
                with: "Self::PostPublishFence => command.starts_with(\"L1Ciab POST_PUBLISH_FENCE \") || command == \"L1Ciab PING\","
            ),
            controller.replacingOccurrences(
                of: "Self::CandidateRelease => command == \"L1Ciab RELEASE_CANDIDATE_GATE\",",
                with: "Self::CandidateRelease => command == \"L1Ciab RELEASE_CANDIDATE_GATE\" || command == \"L1Ciab PING\","
            ),
            controller.replacingOccurrences(
                of: "Self::GuardianReaped => command.starts_with(\"L1Ciab GUARDIAN_REAPED \"),",
                with: "Self::GuardianReaped => command.starts_with(\"L1Ciab GUARDIAN_REAPED \") || command == \"L1Ciab PING\","
            ),
            controller.replacingOccurrences(
                of: "+ POST_PUBLISH_LOCAL_REPROOF_PRIMITIVE_SECONDS",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "+ MIRROR_PROBE_PRIMITIVE_SECONDS",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "+ GUARDIAN_FINISH_ABSOLUTE_SECONDS",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "+ GUARDIAN_REAPED_DIAGNOSTIC_PUBLICATION_PRIMITIVE_SECONDS",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "+ ROOT_COMMAND_WRITE_PRIMITIVE_SECONDS;",
                with: ";"
            ),
            controller.replacingOccurrences(
                of: "sha256_until(",
                with: "sha256("
            ),
            controller.replacingOccurrences(
                of: "Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS)",
                with: "Duration::from_secs(MIRROR_PROBE_EXECUTION_SECONDS + 15)"
            ),
            controller.replacingOccurrences(
                of: "if Instant::now() >= stdout_write_deadline",
                with: "if false"
            ),
            controller.replacingOccurrences(
                of: "if Instant::now() >= stderr_write_deadline",
                with: "if false"
            ),
            controller.replacingOccurrences(
                of: "verify_mirror_result_until(&layout.mirror_result, deadline)?;",
                with: "verify_mirror_result(&layout.mirror_result)?;"
            ),
            controller.replacingOccurrences(
                of: "Duration::from_secs(maximum_seconds)",
                with: "Duration::from_secs(maximum_seconds + 15)"
            ),
            controller.replacingOccurrences(
                of: "guardian.exchange_until(",
                with: "guardian.exchange("
            ),
            controller.replacingOccurrences(
                of: "LIVE_GUARDIAN_HEARTBEAT_RESPONSE_SECONDS",
                with: "ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "root.exchange_until(\n        \"L1Ciab PING\",\n        \"LOCAL_ROOT_BROKER_PONG\",\n        local_deadline,",
                with: "root.exchange_with_timeout(\n        \"L1Ciab PING\",\n        \"LOCAL_ROOT_BROKER_PONG\","
            ),
            controller.replacingOccurrences(
                of: "run_mirror_probe_until(mirror_probe_deadline)?;",
                with: "run_mirror_probe()?;"
            ),
            controller.replacingOccurrences(
                of: "run_live_guardian_heartbeat_until(\n                &mut root,\n                &mut guardian,\n                heartbeat_deadline,\n            )?;",
                with: "guardian.exchange(\"PING\", \"GUARDIAN_BROKER_PONG\")?;"
            ),
            controller.replacingOccurrences(
                of: "root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
                with: "root.exchange_with_timeout(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")"
            ),
            controller.replacingOccurrences(
                of: "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline\n        .checked_sub(Duration::from_secs(LIVE_ROOT_EXCHANGE_PRIMITIVE_SECONDS))",
                with: "let guardian_reaped_command_deadline = guardian_reaped_transition_deadline\n        .checked_sub(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS))"
            ),
            swappingFirst(
                "    if !guardian_outcome.diagnostics.is_empty() {",
                with: "    root.exchange_until(\n        &format!(\"L1Ciab GUARDIAN_REAPED {guardian_pid}\")",
                in: controller
            ),
            controller.replacingOccurrences(
                of: "MIRROR_PROBE_CALL_HANDOFF_SECONDS + MIRROR_PROBE_PRIMITIVE_SECONDS",
                with: "MIRROR_PROBE_PRIMITIVE_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "let gate_to_prestop_wait = RootProtocolExpectedCommand::PrestopFence.idle_seconds();",
                with: "let gate_to_prestop_wait = ROOT_BROKER_DEADMAN_SECONDS;"
            ),
            controller.replacingOccurrences(
                of: "let post_stop_ping_wait = RootProtocolExpectedCommand::PostStopPing.idle_seconds();",
                with: "let post_stop_ping_wait = ROOT_BROKER_DEADMAN_SECONDS;"
            ),
            controller.replacingOccurrences(
                of: "let post_publish_fence_wait = RootProtocolExpectedCommand::PostPublishFence.idle_seconds();",
                with: "let post_publish_fence_wait = ROOT_BROKER_DEADMAN_SECONDS;"
            ),
            controller.replacingOccurrences(
                of: "let post_fence_second_ping_wait = RootProtocolExpectedCommand::PostMirrorPing.idle_seconds();",
                with: "let post_fence_second_ping_wait = ROOT_BROKER_DEADMAN_SECONDS;"
            ),
            controller.replacingOccurrences(
                of: "let probes_to_release_wait = RootProtocolExpectedCommand::CandidateRelease.idle_seconds();",
                with: "let probes_to_release_wait = ROOT_BROKER_DEADMAN_SECONDS;"
            ),
            controller.replacingOccurrences(
                of: "let live_arm = LIVE_ARM_PRIMITIVE_SECONDS;",
                with: "let live_arm = 0;"
            ),
            controller.replacingOccurrences(
                of: "let trial_with_final_heartbeat = 600 + LIVE_ITERATION_OVERHANG_SECONDS;",
                with: "let trial_with_final_heartbeat = 600 + 2 * ROOT_BROKER_DEADMAN_SECONDS;"
            ),
            controller.replacingOccurrences(
                of: "let stop_phase_sum = LIVE_ITERATION_OVERHANG_SECONDS",
                with: "let stop_phase_sum = 2 * ROOT_BROKER_DEADMAN_SECONDS"
            ),
            controller.replacingOccurrences(
                of: "let guardian_reaped_transition = GUARDIAN_REAPED_TRANSITION_PRIMITIVE_SECONDS;",
                with: "let guardian_reaped_transition = ROOT_WAIT_GUARDIAN_REAPED_AFTER_CANDIDATE_STOP_SECONDS;"
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "root-idle mutant \(index) was inert")
            XCTAssertFalse(
                hasStateSpecificRootIdleContract(mutant),
                "root idle source contract accepted mutant \(index)"
            )
        }
    }

    func testMirrorProbeParsesVariableAudioBufferListsWithoutFullStructBinding()
        throws {
        let probe = try source(
            "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"
        )
        XCTAssertTrue(hasBoundsSafeStreamConfigurationParser(probe))
        let mutants = [
            probe.replacingOccurrences(
                of: "returnedByteCount >= headerSize",
                with: "returnedByteCount >= MemoryLayout<AudioBufferList>.size"
            ),
            probe.replacingOccurrences(
                of: "returnedByteCount <= allocatedByteCount",
                with: "true"
            ),
            probe.replacingOccurrences(
                of: "UInt64(numberOfBuffers) <= UInt64(maximumBufferCount)",
                with: "true"
            ),
            probe.replacingOccurrences(
                of: "(returnedByteCount - headerSize) / MemoryLayout<AudioBuffer>.stride",
                with: "(allocatedByteCount - headerSize) / MemoryLayout<AudioBuffer>.stride"
            ),
            probe.replacingOccurrences(
                of: "channelCount <= UInt64(UInt32.max)",
                with: "true"
            ),
            probe.replacingOccurrences(
                of: "maximumStreamConfigurationBytes + 1",
                with: "maximumStreamConfigurationBytes"
            ),
            probe.replacingOccurrences(
                of: "validDeviceInventoryByteCount(Int(size))",
                with: "true"
            ),
            probe.replacingOccurrences(
                of: "returnedByteCount.isMultiple(\n                of: MemoryLayout<AudioDeviceID>.stride\n              )",
                with: "true"
            ),
            probe.replacingOccurrences(
                of: "devices.prefix(returnedCount)",
                with: "devices"
            ),
            probe.replacingOccurrences(
                of: "maximumDeviceInventoryBytes = 1_048_576",
                with: "maximumDeviceInventoryBytes = 2_048_576"
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, probe, "ABL mutant \(index) was inert")
            XCTAssertFalse(
                hasBoundsSafeStreamConfigurationParser(mutant),
                "ABL source contract accepted mutant \(index)"
            )
        }
    }

    func testV7MirrorProbeOptimizedCompileIsDeterministicAndMutationClosed() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        XCTAssertTrue(hasDeterministicOptimizedMirrorProbeCompileContract(controller))

        let mutants = [
            controller.replacingOccurrences(
                of: "        require_directory(mirror_source_parent, 0o700)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "MIRROR_SOURCE_BASENAME,\n            Some(mirror_source_parent),",
                with: "path_text(&mirror_source)?,\n            None,"
            ),
            controller.replacingOccurrences(
                of: "                \"-Xfrontend\",\n                \"-disable-sil-perf-optzns\",\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "-disable-sil-perf-optzns",
                with: "-enable-sil-perf-optzns"
            ),
            controller.replacingOccurrences(
                of: "                \"-Xfrontend\",\n                \"-disable-incremental-llvm-codegen\",\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "-disable-incremental-llvm-codegen",
                with: "-enable-incremental-llvm-codegen"
            ),
            controller.replacingOccurrences(
                of: "                \"-Xlinker\",\n                \"-reproducible\",\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "\"-reproducible\"",
                with: "\"-random_uuid\""
            ),
            controller.replacingOccurrences(
                of: "                command.current_dir(directory);\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            &layout.mirror_probe,\n",
                with: "            &mirror_source,\n"
            ),
            controller.replacingOccurrences(
                of: "        require_directory(guardian_source_parent, 0o700)?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "GUARDIAN_SOURCE_BASENAME,\n            Some(guardian_source_parent),",
                with: "path_text(&guardian_source)?,\n            None,"
            ),
            controller.replacingOccurrences(
                of: "const GUARDIAN_SOURCE_BASENAME: &str = \"V7DefaultRouteGuardian.swift\";",
                with: "const GUARDIAN_SOURCE_BASENAME: &str = \"OtherGuardian.swift\";"
            ),
            controller.replacingOccurrences(
                of: "            Some(guardian_source_parent),\n            &layout.default_route_guardian,",
                with: "            Some(mirror_source_parent),\n            &layout.default_route_guardian,"
            ),
            controller.replacingOccurrences(
                of: "            &layout.default_route_guardian,\n            &[],",
                with: "            &layout.default_route_guardian,\n            &[\"-Xlinker\", \"-reproducible\"],"
            ),
            controller.replacingOccurrences(
                of: "53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c",
                with: "307136582f85087ab7f8b846a49b428de9fb87d2726071e7e3ea4b3112d90b8b"
            ),
            controller.replacingOccurrences(
                of: "            compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;",
                with: "compiled_output.set_permissions(fs::Permissions::from_mode(0o700))?;"
            ),
            controller.replacingOccurrences(
                of: "compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;",
                with: "fs::set_permissions(output, fs::Permissions::from_mode(0o755))?;"
            ),
            controller.replacingOccurrences(
                of: "            if !compiled_output_is_exact(&named_before, 0o700) {\n",
                with: "            if !compiled_output_is_exact(&named_before, 0o755) {\n"
            ),
            controller.replacingOccurrences(
                of: "                .custom_flags(O_NOFOLLOW)\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                || descriptor_before.len() != named_before.len()\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                || descriptor_before.len() != descriptor_after.len()\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                || descriptor_before.len() != named_after.len()\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "                || !compiled_output_is_exact(&named_after, 0o755)\n",
                with: ""
            ),
            swappingFirst(
                "let descriptor_before = compiled_output.metadata()?;",
                with: "compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;",
                in: controller
            ),
            swappingFirst(
                #"require_output_success(&result, "compile exact paired-v7 Swift probe")?;"#,
                with: "compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;",
                in: controller
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "mirror determinism mutant \(index) was inert")
            XCTAssertFalse(
                hasDeterministicOptimizedMirrorProbeCompileContract(mutant),
                "mirror determinism source contract accepted mutant \(index)"
            )
        }
    }

    func testV7PairingQueriesPinTheExactUID501LoginKeychainAndRejectMutants() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        XCTAssertTrue(hasStrictExplicitLoginKeychainContract(controller))

        let mutants = [
            controller.replacingOccurrences(
                of: "/Users/ahmed/Library/Keychains/login.keychain-db",
                with: "/Users/ahmed/Library/Keychains/other.keychain-db"
            ),
            controller.replacingOccurrences(
                of: "                    ISOLATED_PAIRING_LOGIN_KEYCHAIN,\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            && proof.uid == USER_ID\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            && proof.gid == ISOLATED_PAIRING_LOGIN_KEYCHAIN_GID\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            && proof.nlink == 1\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            && proof.mode == ISOLATED_PAIRING_LOGIN_KEYCHAIN_MODE\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "        require_isolated_pairing_login_keychain()?;\n",
                with: ""
            ),
            controller.replacingOccurrences(
                of: "            ISOLATED_PAIRING_VIEWER_ACCOUNT,\n",
                with: ""
            ),
        ]
        for (index, mutant) in mutants.enumerated() {
            XCTAssertNotEqual(mutant, controller, "mutation fixture \(index) did not mutate source")
            XCTAssertFalse(
                hasStrictExplicitLoginKeychainContract(mutant),
                "strict login Keychain source contract accepted mutant \(index)"
            )
        }
    }
}
