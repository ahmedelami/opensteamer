import Foundation
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
        return containsOrdered(validationTokens, in: build)
            && containsOrdered(compileClosureTokens, in: build)
            && build.contains("\"-O\",")
            && !build.contains("\"-Onone\",")
            && containsOrdered(mirrorCompileTokens, in: build)
            && !build.contains("path_text(&mirror_source)?")
            && containsOrdered(
                [
                    "compile_swift(\n            path_text(&guardian_source)?,",
                    "None,",
                    "&layout.default_route_guardian,",
                    "&[],",
                ],
                in: build
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
                beginningWith: "fn bootstrap_root_owned_v7_controller()",
                endingBefore: "fn spawn_bounded_line_reader<"
            ),
            let rootBootstrap = try? functionBody(
                controller,
                beginningWith: "fn bootstrap_root_controller_identity()",
                endingBefore: "fn verify_root_controller_identity()"
            ),
            let rootVerification = try? functionBody(
                controller,
                beginningWith: "fn verify_root_controller_identity()",
                endingBefore: "fn require_root_private_directory("
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
            "EXPECTED_BINARY_SHA256='8d58bdee98d18620b82c84b8f37023839f9608acae4fd4a6247e1712105b0278'",
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
            && !controller.contains("16_777_229")
            && containsOrdered(mountTokens, in: mountIdentity)
            && containsOrdered(plistTokens, in: plistValidation)
            && containsOrdered(derivationTokens, in: deviceDerivation)
            && containsOrdered(v5Tokens, in: v5Verification)
            && containsOrdered(v6Tokens, in: v6Verification)
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
        XCTAssertTrue(
            launcher.contains(
                "EXPECTED_SOURCE_SHA256='472469623cc7bb44ce1db337c994ed00f6d339182da87efa392233a7acfc4ac1'"
            )
        )
        XCTAssertTrue(
            launcher.contains(
                "EXPECTED_BINARY_SHA256='8d58bdee98d18620b82c84b8f37023839f9608acae4fd4a6247e1712105b0278'"
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
            "b69c5d4d71db35d871a5e561c33fb2a0303ecec48a411ee8e41aa963987018bb",
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
                of: "            None,\n            &layout.default_route_guardian,",
                with: "            Some(mirror_source_parent),\n            &layout.default_route_guardian,"
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
