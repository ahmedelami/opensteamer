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
            "EXPECTED_BINARY_SHA256='PIN_AFTER_FINAL_REVIEW_CONTROLLER_BINARY_SHA256'",
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

    func testV7RemainsProductionOnlyAndIntentionallyUnpinned() throws {
        let controller = try source(
            "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
        )
        let launcher = try source("macOS/scripts/update-opensteamer-host-paired-v7.sh")

        XCTAssertTrue(controller.contains("UNPINNED_SOURCE_AND_ARTIFACTS"))
        XCTAssertTrue(launcher.contains("UNPINNED_SOURCE_AND_ARTIFACTS"))
        XCTAssertTrue(controller.contains("Developer ID Application"))
        XCTAssertTrue(controller.contains("Developer ID Installer"))
        XCTAssertTrue(controller.contains("MSMG8CJLB3"))
        XCTAssertTrue(controller.contains("notarytool"))
        XCTAssertTrue(controller.contains("EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256"))
        XCTAssertFalse(controller.contains("--local-uncommitted-trial"))
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
