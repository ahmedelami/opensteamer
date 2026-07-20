import Foundation
import Darwin
import XCTest

final class PhysicalValidationScriptTests: XCTestCase {
    private typealias PhysicalDriver = (
        relativePath: String,
        arguments: (URL) -> [String]
    )

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var physicalDrivers: [PhysicalDriver] {
        [
            (
                "iOS/AudioStreamer/scripts/validate-release-pair-baseline.sh",
                { artifactDirectory in ["self-test-device", artifactDirectory.path] }
            ),
            (
                "iOS/AudioStreamer/scripts/validate-physical-update-keychain.sh",
                { artifactDirectory in ["self-test-device", artifactDirectory.path] }
            ),
            (
                "iOS/AudioStreamer/scripts/validate-testflight-paired-reconnect.sh",
                { artifactDirectory in ["self-test-device", "29", artifactDirectory.path] }
            ),
        ]
    }

    func testUpdateDriverRunsMissingCredentialCasesWithInertApplicationHost() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/AudioStreamer/scripts/validate-physical-update-keychain.sh"
            ),
            encoding: .utf8
        )
        let applicationRoot = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/AudioStreamer/Sources/App/AudioStreamerApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            script.contains(
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG " +
                    "AUDIOSTREAMER_UPDATE_VALIDATION_HOST ${condition}"
            )
        )
        XCTAssertTrue(
            script.contains(
                "remove_existing_validation_app\nrun_phase \\\n  seed"
            ),
            "A previously installed normal debug app could relaunch between test phases."
        )
        let orderedGates = [
            "testSeedStableItemsForPhysicalUpdateValidation",
            "testStableItemsSurvivePhysicalUpdate",
            "testSeedMissingIdentityForPhysicalUpdateValidation",
            "testVerifyHostDoesNotCreateMissingIdentity",
            "testSeedMissingPairedMacForPhysicalUpdateValidation",
            "testVerifyHostDoesNotCreateMissingPairedMac",
        ]
        var remainingScript = script[...]
        for gate in orderedGates {
            let range = try XCTUnwrap(remainingScript.range(of: gate))
            remainingScript = remainingScript[range.upperBound...]
        }

        XCTAssertTrue(applicationRoot.contains("#if AUDIOSTREAMER_UPDATE_VALIDATION_HOST"))
        XCTAssertTrue(applicationRoot.contains("isPhysicalUpdateValidationHost = true"))
        XCTAssertTrue(applicationRoot.contains("EmptyView()"))
        XCTAssertTrue(applicationRoot.contains("#else\n    @StateObject"))
    }

    func testReconnectDriverWritesHostStatusInRealZshProcess() throws {
        let script = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/validate-testflight-paired-reconnect.sh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-script-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let staleEvidence = [
            "summary.json",
            "device-locked-during-test.txt",
            "production-release-paired-reconnect.xcresult/stale.txt",
            "DerivedData/stale.txt",
            "DerivedData/Build/Intermediates.noindex/XCBuildData/build.db",
        ]
        for relativePath in staleEvidence {
            let url = artifactDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stale".utf8).write(to: url)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "self-test-device", "29", artifactDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["AUDIOSTREAMER_SCRIPT_SELF_TEST"] = "write-host-status"
        process.environment = environment

        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        let exitedWithinDeadline = waitForExit(process, timeout: 5)
        if !exitedWithinDeadline {
            forceStopProcessAndIsolatedGroup(process)
        }
        XCTAssertTrue(exitedWithinDeadline, "The reconnect driver self-test hung.")
        guard !process.isRunning else {
            XCTFail("The reconnect driver self-test survived forced cleanup.")
            return
        }

        let errorData = readAvailableData(from: standardError)
        let errorOutput = String(decoding: errorData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)

        let statusURL = artifactDirectory.appendingPathComponent("host-restart-status.txt")
        let status = try String(contentsOf: statusURL, encoding: .utf8)
        XCTAssertEqual(
            status,
            "status=pending\nconnections=2\nrestarts=1\ndetail=runtime self-test\n"
        )
        for relativePath in staleEvidence {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: artifactDirectory.appendingPathComponent(relativePath).path
                ),
                "The driver reused stale evidence at \(relativePath)."
            )
        }
        let runStatus = try String(
            contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(runStatus, "status=self-test-passed\n")
    }

    func testBaselineAndReconnectDeleteStaleDerivedDataBeforeSelfTests() throws {
        let drivers: [PhysicalDriver] = [physicalDrivers[0], physicalDrivers[2]]
        for driver in drivers {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioStreamer-stale-derived-data-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let staleURLs = [
                artifactDirectory.appendingPathComponent("DerivedData/stale.txt"),
                artifactDirectory.appendingPathComponent(
                    "DerivedData/Build/Intermediates.noindex/XCBuildData/build.db"
                ),
            ]
            for staleURL in staleURLs {
                try FileManager.default.createDirectory(
                    at: staleURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("stale".utf8).write(to: staleURL)
            }

            let result = try runPhysicalDriverSelfTest(
                driver,
                mode: "fail-command",
                artifactDirectory: artifactDirectory,
                timeout: 5
            )

            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 9, result.diagnostic)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: artifactDirectory.appendingPathComponent("DerivedData").path
                ),
                "\(driver.relativePath) reused stale DerivedData."
            )
        }
    }

    func testReconnectRejectsBatchedMalformedConnectedLineInRealZsh() throws {
        try assertReconnectProvenanceSelfTestPasses("batched-malformed")
    }

    func testReconnectRejectsPreKickMismatchedConnectedLineInRealZsh() throws {
        try assertReconnectProvenanceSelfTestPasses("pre-kick-mismatch")
    }

    func testReconnectRejectsLateConnectedLineAfterThirdRestartInRealZsh() throws {
        try assertReconnectProvenanceSelfTestPasses("late-mismatch")
    }

    func testReconnectRejectsSameInodeRewriteInRealZsh() throws {
        try assertReconnectProvenanceSelfTestPasses("same-inode-rewrite")
    }

    func testReconnectRejectsReusedPIDAndAcceptsFourGloballyUniquePIDs() throws {
        try assertReconnectProvenanceSelfTestPasses("reused-pid")
        try assertReconnectProvenanceSelfTestPasses("unique-pids")
    }

    func testReconnectFinalAuditRejectsLateLineWithoutPostEndKickstart() throws {
        try assertReconnectProvenanceSelfTestPasses("final-audit-mismatch")
        try assertReconnectProvenanceSelfTestPasses("final-partial-mismatch")
    }

    func testCoherentLogSnapshotRejectsRewriteDuringOpenedDescriptorRead() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-log-snapshot-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let log = artifactDirectory.appendingPathComponent("host.log")
        let firstChunk = artifactDirectory.appendingPathComponent("first.bin")
        let secondChunk = artifactDirectory.appendingPathComponent("second.bin")
        let ready = artifactDirectory.appendingPathComponent("ready.txt")
        let proceed = artifactDirectory.appendingPathComponent("proceed.txt")
        try Data("baseline\nWorldwide WebRTC peer state: connected pid=100\n".utf8)
            .write(to: log)

        let result = try runPhysicalValidationHelperProbe(
            "empty=$(audiostreamer_empty_sha256); " +
                "audiostreamer_capture_log_snapshot \"$1\" \"\" 0 \"$empty\" \"$2\"; " +
                "identity=$AUDIOSTREAMER_LOG_SNAPSHOT_ID; " +
                "offset=$AUDIOSTREAMER_LOG_SNAPSHOT_OFFSET; " +
                "digest=$AUDIOSTREAMER_LOG_SNAPSHOT_DIGEST; " +
                "export AUDIOSTREAMER_LOG_SNAPSHOT_TEST_READY=\"$4\"; " +
                "export AUDIOSTREAMER_LOG_SNAPSHOT_TEST_PROCEED=\"$5\"; " +
                "audiostreamer_capture_log_snapshot \"$1\" \"$identity\" " +
                "\"$offset\" \"$digest\" \"$3\" & snapshot=$!; " +
                "for poll in {1..200}; do [[ -f \"$4\" ]] && break; sleep 0.01; done; " +
                "[[ -f \"$4\" ]]; " +
                "/usr/bin/python3 -c 'import os,sys; p=sys.argv[1]; " +
                "d=open(p,\"rb\").read(); f=open(p,\"wb\"); " +
                "f.write(b\"Baseline\\n\" + d[len(b\"baseline\\n\"):]); " +
                "f.flush(); os.fsync(f.fileno()); f.close()' \"$1\"; " +
                "print -r -- proceed > \"$5\"; " +
                "if wait \"$snapshot\"; then exit 91; fi",
            arguments: [
                log.path,
                firstChunk.path,
                secondChunk.path,
                ready.path,
                proceed.path,
            ]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertTrue(
            result.standardError.contains("consumed log prefix digest changed"),
            result.diagnostic
        )
    }

    func testConnectedLineAuditorBuffersIncompleteTrailingLineInRealZsh() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-partial-log-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let first = artifactDirectory.appendingPathComponent("first.bin")
        let second = artifactDirectory.appendingPathComponent("second.bin")
        let partial = artifactDirectory.appendingPathComponent("partial.bin")
        let completed = artifactDirectory.appendingPathComponent("completed.txt")
        try Data("Worldwide WebRTC peer state: connected pid=".utf8).write(to: first)
        try Data("100\n".utf8).write(to: second)

        let result = try runPhysicalValidationHelperProbe(
            "audiostreamer_split_completed_log_lines \"$1\" \"$3\" \"$4\"; " +
                "[[ ! -s \"$4\" ]]; " +
                "audiostreamer_split_completed_log_lines \"$2\" \"$3\" \"$4\"; " +
                "audiostreamer_audit_connected_log_lines \"$4\" 100 100; " +
                "print -r -- \"$AUDIOSTREAMER_AUDITED_CONNECTION_COUNT\"",
            arguments: [first.path, second.path, partial.path, completed.path]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertEqual(result.standardOutput, "1\n")
    }

    func testConnectedLineAuditorRejectsMultipleMarkersOnOneLineInRealZsh() throws {
        let completed = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-multiple-markers-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: completed) }
        try Data(
            (
                "Worldwide WebRTC peer state: connected pid=999 " +
                    "Worldwide WebRTC peer state: connected pid=100\n"
            ).utf8
        ).write(to: completed)

        let result = try runPhysicalValidationHelperProbe(
            "audiostreamer_audit_connected_log_lines \"$1\" 100 100",
            arguments: [completed.path]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
    }

    func testReconnectCancellationKillsStoppedWatcherBeforeValidationGroup() throws {
        let script = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/validate-testflight-paired-reconnect.sh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-cancel-churn-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "self-test-device", "29", artifactDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["AUDIOSTREAMER_SCRIPT_SELF_TEST"] = "cancel-stopped-churn"
        environment["AUDIOSTREAMER_HOST_CHURN_LOCK_ATTEMPTS"] = "5"
        process.environment = environment
        let standardError = Pipe()
        process.standardError = standardError

        try process.run()
        let exitedWithinDeadline = waitForExit(process, timeout: 8)
        if !exitedWithinDeadline {
            forceStopProcessAndIsolatedGroup(process)
        }
        XCTAssertTrue(exitedWithinDeadline, "Stopped-churn cancellation self-test hung.")
        guard !process.isRunning else {
            XCTFail("Stopped-churn cancellation self-test survived forced cleanup.")
            return
        }
        let diagnostic = String(
            decoding: readAvailableData(from: standardError),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifactDirectory.appendingPathComponent(
                    "cancel-churn-action.txt"
                ).path
            ),
            "Host churn ran after cancellation killed the validation group."
        )
        let runStatus = try String(
            contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(runStatus, "status=self-test-passed\n", diagnostic)
    }

    func testPhysicalValidationHelperForceTerminatesTermIgnoringProcessTree() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/physical-validation-helpers.zsh"
        )
        let stubbornProcess = Process()
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-child-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        let leafPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-leaf-pids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: leafPIDFile) }
        stubbornProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        stubbornProcess.arguments = [
            "-c",
            "trap ':' TERM; /bin/zsh -c 'trap \":\" TERM; " +
                "while true; do sleep 30 & leaf=$!; print -r -- $leaf >> \"$1\"; " +
                "wait $leaf || true; done' descendant \"$2\" & " +
                "print -r -- $! > \"$1\"; while true; do wait || true; done",
            "physical-validation-stubborn-process",
            childPIDFile.path,
            leafPIDFile.path,
        ]
        try stubbornProcess.run()
        defer {
            for pidFile in [childPIDFile, leafPIDFile] {
                let pids = (try? String(contentsOf: pidFile, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline)
                    .compactMap { pid_t(String($0)) } ?? []
                for pid in pids where kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
            if stubbornProcess.isRunning {
                forceStopProcessAndIsolatedGroup(stubbornProcess)
            } else {
                kill(-stubbornProcess.processIdentifier, SIGKILL)
            }
        }
        XCTAssertTrue(
            waitForFileToExist(childPIDFile, timeout: 2),
            "The stubborn harness did not publish its descendant PID."
        )
        XCTAssertTrue(
            waitForFileToExist(leafPIDFile, timeout: 2),
            "The stubborn harness did not publish its leaf PID."
        )
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childPIDText))

        let terminator = Process()
        terminator.executableURL = URL(fileURLWithPath: "/bin/zsh")
        terminator.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_terminate_process_tree \"$2\" 1",
            "physical-validation-helper-test",
            helper.path,
            String(stubbornProcess.processIdentifier),
        ]
        let standardError = Pipe()
        terminator.standardError = standardError

        let started = Date()
        try terminator.run()
        let terminatorExited = waitForExit(terminator, timeout: 5)
        if !terminatorExited {
            forceStopProcessAndIsolatedGroup(terminator)
        }
        XCTAssertTrue(terminatorExited, "Termination helper hung.")
        guard !terminator.isRunning else {
            XCTFail("The termination helper survived forced cleanup.")
            return
        }
        let errorData = readAvailableData(from: standardError)
        let errorOutput = String(decoding: errorData, as: UTF8.self)
        XCTAssertEqual(terminator.terminationStatus, 0, errorOutput)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let stubbornExited = waitForExit(stubbornProcess, timeout: 2)
        if !stubbornExited {
            forceStopProcessAndIsolatedGroup(stubbornProcess)
        }
        XCTAssertTrue(stubbornExited, "The TERM-ignoring process tree survived the bounded helper.")
        XCTAssertTrue(
            waitForPIDToDisappear(childPID, timeout: 2),
            "The helper killed the root but orphaned descendant PID \(childPID)."
        )
        let leafPIDs = try String(contentsOf: leafPIDFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0)) }
        XCTAssertGreaterThanOrEqual(
            leafPIDs.count,
            2,
            "The harness did not recreate the TERM-time child-respawn race."
        )
        for leafPID in leafPIDs {
            XCTAssertTrue(
                waitForPIDToDisappear(leafPID, timeout: 2),
                "The helper orphaned respawned leaf PID \(leafPID)."
            )
        }
    }

    func testPhysicalValidationHelperKillsReparentedChildrenAfterRootExits() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/physical-validation-helpers.zsh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-reparent-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let childPIDFile = artifactDirectory.appendingPathComponent("child-pid.txt")
        let leafPIDFile = artifactDirectory.appendingPathComponent("leaf-pid.txt")
        let rootProcess = Process()
        rootProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        rootProcess.arguments = [
            "-c",
            "/bin/zsh -c 'trap \"\" TERM HUP; while true; do sleep 30 & leaf=$!; " +
                "print -r -- $leaf >> \"$1\"; wait $leaf || true; done' " +
                "reparented-child \"$2\" & print -r -- $! > \"$1\"; wait",
            "terminating-root",
            childPIDFile.path,
            leafPIDFile.path,
        ]
        try rootProcess.run()
        defer {
            for pidFile in [childPIDFile, leafPIDFile] {
                let pids = (try? String(contentsOf: pidFile, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline)
                    .compactMap { pid_t(String($0)) } ?? []
                for pid in pids where kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
            if rootProcess.isRunning {
                forceStopProcessAndIsolatedGroup(rootProcess)
            } else {
                kill(-rootProcess.processIdentifier, SIGKILL)
            }
        }
        XCTAssertTrue(waitForFileToExist(childPIDFile, timeout: 2))
        XCTAssertTrue(waitForFileToExist(leafPIDFile, timeout: 2))
        let childPID = try XCTUnwrap(
            pid_t(
                String(contentsOf: childPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        let terminator = Process()
        terminator.executableURL = URL(fileURLWithPath: "/bin/zsh")
        terminator.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_terminate_process_tree \"$2\" 1",
            "physical-validation-reparent-test",
            helper.path,
            String(rootProcess.processIdentifier),
        ]
        try terminator.run()
        let terminatorExited = waitForExit(terminator, timeout: 5)
        if !terminatorExited {
            forceStopProcessAndIsolatedGroup(terminator)
        }
        XCTAssertTrue(terminatorExited, "Termination helper hung.")
        guard !terminator.isRunning else {
            XCTFail("The termination helper survived forced cleanup.")
            return
        }
        XCTAssertEqual(terminator.terminationStatus, 0)
        let rootExited = waitForExit(rootProcess, timeout: 2)
        if !rootExited {
            forceStopProcessAndIsolatedGroup(rootProcess)
        }
        XCTAssertTrue(rootExited)
        XCTAssertTrue(
            waitForPIDToDisappear(childPID, timeout: 2),
            "The helper orphaned reparented child PID \(childPID)."
        )
        let leafPIDs = try String(contentsOf: leafPIDFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0)) }
        XCTAssertGreaterThanOrEqual(
            leafPIDs.count,
            2,
            "The harness did not recreate a child respawn after reparenting."
        )
        for leafPID in leafPIDs {
            XCTAssertTrue(
                waitForPIDToDisappear(leafPID, timeout: 2),
                "The helper orphaned reparented leaf PID \(leafPID)."
            )
        }
    }

    func testIsolatedProcessGroupKillsChildSpawnedByTermHandler() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/physical-validation-helpers.zsh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-group-handler-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let readyFile = artifactDirectory.appendingPathComponent("ready.txt")
        let childPIDFile = artifactDirectory.appendingPathComponent("spawned-child.txt")
        let harness = """
        ready_file=$1
        child_file=$2
        function onterm() {
          /usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(30)' &
          print -r -- $! > "$child_file"
          exit 0
        }
        trap onterm TERM
        print -r -- ready > "$ready_file"
        while true; do sleep 30; done
        """
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/zsh")
        leader.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_exec_in_isolated_process_group " +
                "/bin/zsh -c \"$2\" group-handler \"$3\" \"$4\"",
            "isolated-group-launcher",
            helper.path,
            harness,
            readyFile.path,
            childPIDFile.path,
        ]
        try leader.run()
        let leaderPID = leader.processIdentifier
        defer {
            kill(-leaderPID, SIGKILL)
            if leader.isRunning {
                forceStopProcessAndIsolatedGroup(leader)
            }
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
        }
        XCTAssertTrue(waitForFileToExist(readyFile, timeout: 3))

        let terminator = Process()
        terminator.executableURL = URL(fileURLWithPath: "/bin/zsh")
        terminator.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_require_isolated_process_group \"$2\" 3; " +
                "audiostreamer_terminate_isolated_process_group \"$2\" 1",
            "isolated-group-terminator",
            helper.path,
            String(leaderPID),
        ]
        try terminator.run()
        let terminatorExited = waitForExit(terminator, timeout: 5)
        if !terminatorExited {
            forceStopProcessAndIsolatedGroup(terminator)
        }
        XCTAssertTrue(terminatorExited)
        guard !terminator.isRunning else {
            XCTFail("The isolated-group terminator survived forced cleanup.")
            return
        }
        XCTAssertEqual(terminator.terminationStatus, 0)
        XCTAssertTrue(waitForFileToExist(childPIDFile, timeout: 2))
        let childPID = try XCTUnwrap(
            pid_t(
                String(contentsOf: childPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        let leaderExited = waitForExit(leader, timeout: 2)
        if !leaderExited {
            forceStopProcessAndIsolatedGroup(leader)
        }
        XCTAssertTrue(leaderExited)
        XCTAssertTrue(waitForPIDToDisappear(childPID, timeout: 2))
        XCTAssertEqual(kill(-leaderPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testIsolatedProcessGroupRemainsTerminableAfterFastLeaderExit() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/physical-validation-helpers.zsh"
        )
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-fast-leader-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        let harness = """
        /usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(30)' &
        print -r -- $! > "$1"
        exit 0
        """
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/zsh")
        leader.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_exec_in_isolated_process_group " +
                "/bin/zsh -c \"$2\" fast-leader \"$3\"",
            "isolated-fast-launcher",
            helper.path,
            harness,
            childPIDFile.path,
        ]
        try leader.run()
        let leaderPID = leader.processIdentifier
        defer {
            kill(-leaderPID, SIGKILL)
            if leader.isRunning {
                forceStopProcessAndIsolatedGroup(leader)
            }
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
        }
        XCTAssertTrue(waitForFileToExist(childPIDFile, timeout: 3))
        let leaderExited = waitForExit(leader, timeout: 3)
        if !leaderExited {
            forceStopProcessAndIsolatedGroup(leader)
        }
        XCTAssertTrue(leaderExited, "The group leader did not exit quickly.")
        guard !leader.isRunning else {
            XCTFail("The fast group leader survived forced cleanup.")
            return
        }
        let childPID = try XCTUnwrap(
            pid_t(
                String(contentsOf: childPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertEqual(kill(-leaderPID, 0), 0, "The surviving child lost its process-group handle.")

        let terminator = Process()
        terminator.executableURL = URL(fileURLWithPath: "/bin/zsh")
        terminator.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_terminate_isolated_process_group \"$2\" 1",
            "isolated-fast-terminator",
            helper.path,
            String(leaderPID),
        ]
        try terminator.run()
        let terminatorExited = waitForExit(terminator, timeout: 5)
        if !terminatorExited {
            forceStopProcessAndIsolatedGroup(terminator)
        }
        XCTAssertTrue(terminatorExited)
        guard !terminator.isRunning else {
            XCTFail("The isolated-group terminator survived forced cleanup.")
            return
        }
        XCTAssertEqual(terminator.terminationStatus, 0)
        XCTAssertTrue(waitForPIDToDisappear(childPID, timeout: 2))
        XCTAssertEqual(kill(-leaderPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testHostPIDParserAcceptsValidConnectedLogLineInRealZsh() throws {
        let result = try runPhysicalValidationHelperProbe(
            "audiostreamer_connected_host_pid_from_log_line \"$1\"",
            arguments: [
                "2026-07-18T10:00:00Z Worldwide WebRTC peer state: connected pid=4242",
            ]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertEqual(result.standardOutput, "4242\n")
    }

    func testHostPIDParserRejectsMissingAndNonNumericPIDInRealZsh() throws {
        let invalidLogLines = [
            "Worldwide WebRTC peer state: connected pid=",
            "Worldwide WebRTC peer state: connected pid=not-a-pid",
            "Worldwide WebRTC peer state: connected pid=999 " +
                "Worldwide WebRTC peer state: connected pid=4242",
            "Worldwide WebRTC peer state: connected",
        ]

        for logLine in invalidLogLines {
            let result = try runPhysicalValidationHelperProbe(
                "audiostreamer_connected_host_pid_from_log_line \"$1\"",
                arguments: [logLine]
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
            XCTAssertEqual(result.standardOutput, "")
        }
    }

    func testSameHostProcessRejectsPIDMismatchAndMalformedPIDInRealZsh() throws {
        let valid = try runPhysicalValidationHelperProbe(
            "audiostreamer_require_same_host_process \"$1\" \"$2\" \"$3\"",
            arguments: ["4242", "4242", "4242"]
        )
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)

        for arguments in [
            ["4242", "4242", "4343"],
            ["4242", "not-a-pid", "4242"],
            ["", "4242", "4242"],
        ] {
            let result = try runPhysicalValidationHelperProbe(
                "audiostreamer_require_same_host_process \"$1\" \"$2\" \"$3\"",
                arguments: arguments
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
        }
    }

    func testContinuousLogRejectsIdentityChangeAndTruncationInRealZsh() throws {
        let valid = try runPhysicalValidationHelperProbe(
            "audiostreamer_require_continuous_log \"$1\" \"$2\" \"$3\" \"$4\"",
            arguments: ["16777234:9988", "16777234:9988", "10", "11"]
        )
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)

        let identityMismatch = try runPhysicalValidationHelperProbe(
            "audiostreamer_require_continuous_log \"$1\" \"$2\" \"$3\" \"$4\"",
            arguments: ["16777234:9988", "16777234:9989", "10", "11"]
        )
        XCTAssertTrue(identityMismatch.exitedWithinDeadline, identityMismatch.diagnostic)
        XCTAssertNotEqual(identityMismatch.terminationStatus, 0, identityMismatch.diagnostic)

        let truncated = try runPhysicalValidationHelperProbe(
            "audiostreamer_require_continuous_log \"$1\" \"$2\" \"$3\" \"$4\"",
            arguments: ["16777234:9988", "16777234:9988", "11", "10"]
        )
        XCTAssertTrue(truncated.exitedWithinDeadline, truncated.diagnostic)
        XCTAssertNotEqual(truncated.terminationStatus, 0, truncated.diagnostic)
    }

    func testIsolatedValidationGroupCanBeProvenStoppedThenResumed() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/physical-validation-helpers.zsh"
        )
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-suspend-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyFile) }

        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/zsh")
        leader.arguments = [
            "-c",
            "source \"$1\"; audiostreamer_exec_in_isolated_process_group " +
                "/bin/zsh -c 'print -r -- ready > \"$1\"; " +
                "trap \"exit 0\" TERM; while true; do sleep 30; done' " +
                "suspend-harness \"$2\"",
            "isolated-suspend-launcher",
            helper.path,
            readyFile.path,
        ]
        try leader.run()
        let leaderPID = leader.processIdentifier
        defer {
            kill(-leaderPID, SIGKILL)
            if leader.isRunning {
                forceStopProcessAndIsolatedGroup(leader)
            }
        }
        XCTAssertTrue(waitForFileToExist(readyFile, timeout: 3))

        let result = try runPhysicalValidationHelperProbe(
            "audiostreamer_suspend_isolated_process_group \"$1\" 3; " +
                "state=$(ps -o state= -p \"$1\" | tr -d '[:space:]'); " +
                "[[ \"$state\" == T* ]]; " +
                "audiostreamer_resume_process_group \"$1\"",
            arguments: [String(leaderPID)]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertTrue(leader.isRunning, "The suspension proof terminated its live group.")
        XCTAssertEqual(kill(leaderPID, 0), 0, "The group did not survive resume.")
    }

    func testFinalWaitDrainsStopContinueWithoutMaskingExitStatus() throws {
        for expectedStatus in [0, 7, 19, 145] {
            let result = try runPhysicalValidationHelperProbe(
                "/bin/zsh -c 'sleep 0.25; exit \"$1\"' wait-child \"$1\" & " +
                    "child=$!; " +
                    "(sleep 0.05; kill -STOP \"$child\"; sleep 0.05; " +
                    "kill -CONT \"$child\") & transition=$!; " +
                    "audiostreamer_wait_for_final_process_status \"$child\"; " +
                    "wait \"$transition\" 2>/dev/null || true; " +
                    "print -r -- \"$AUDIOSTREAMER_FINAL_PROCESS_STATUS\"",
                arguments: [String(expectedStatus)]
            )

            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            XCTAssertEqual(
                result.standardOutput,
                "\(expectedStatus)\n",
                "STOP/CONT masked the child's real exit status"
            )
        }
    }

    func testFinalWaitPreservesTerminationAfterStopContinue() throws {
        let result = try runPhysicalValidationHelperProbe(
            "/bin/zsh -c 'sleep 5' wait-child & child=$!; " +
                "(sleep 0.05; kill -STOP \"$child\"; sleep 0.05; " +
                "kill -CONT \"$child\"; sleep 0.05; kill -TERM \"$child\") & transition=$!; " +
                "audiostreamer_wait_for_final_process_status \"$child\"; " +
                "wait \"$transition\" 2>/dev/null || true; " +
                "print -r -- \"$AUDIOSTREAMER_FINAL_PROCESS_STATUS\"",
            arguments: []
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertEqual(result.standardOutput, "143\n")
    }

    func testBoundedCriticalCommandTimesOut() throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-timeout-descendant-\(UUID().uuidString)")
        defer {
            if let text = try? String(contentsOf: descendantPIDFile, encoding: .utf8),
               let descendantPID = pid_t(
                   text.trimmingCharacters(in: .whitespacesAndNewlines)
               ),
               kill(descendantPID, 0) == 0 {
                kill(descendantPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: descendantPIDFile)
        }
        let started = Date()
        let result = try runPhysicalValidationHelperProbe(
            "audiostreamer_run_with_timeout 0.1 /bin/zsh -c " +
                "'trap \"exit 0\" TERM; " +
                "/usr/bin/python3 -c \"import signal,time; " +
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); " +
                "signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(30)\" & " +
                "print -r -- $! > \"$1\"; while true; do sleep 30; done' " +
                "timeout-root \"$1\"",
            arguments: [descendantPIDFile.path]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 124, result.diagnostic)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let descendantPID = try XCTUnwrap(
            pid_t(
                String(contentsOf: descendantPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertTrue(
            waitForPIDToDisappear(descendantPID, timeout: 2),
            "The bounded critical command orphaned descendant PID \(descendantPID)."
        )
    }

    func testEveryPhysicalDriverTreatsTerminationAsFailure() throws {
        try assertEveryPhysicalDriverFailsRuntimeSelfTest(
            mode: "self-signal",
            expectedStatus: 143
        )
    }

    func testEveryPhysicalDriverCleansUpAfterErrexit() throws {
        try assertEveryPhysicalDriverFailsRuntimeSelfTest(
            mode: "fail-command",
            expectedStatus: 9
        )
    }

    func testEveryPhysicalDriverOverwritesStalePassBeforeCleanupFailure() throws {
        for driver in physicalDrivers {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioStreamer-startup-failure-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: artifactDirectory.path
                )
                try? FileManager.default.removeItem(at: artifactDirectory)
            }
            let runStatusURL = artifactDirectory.appendingPathComponent("run-status.txt")
            try Data("status=passed\n".utf8).write(to: runStatusURL)
            let staleName = driver.relativePath.contains("update-keychain")
                ? "seed-summary.json"
                : "summary.json"
            let staleURL = artifactDirectory.appendingPathComponent(staleName)
            try Data("stale".utf8).write(to: staleURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: artifactDirectory.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                repositoryRoot.appendingPathComponent(driver.relativePath).path,
            ] + driver.arguments(artifactDirectory)
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            let exitedWithinDeadline = waitForExit(process, timeout: 5)
            if !exitedWithinDeadline {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(exitedWithinDeadline, "\(driver.relativePath) hung.")
            guard !process.isRunning else {
                XCTFail("\(driver.relativePath) survived forced cleanup.")
                continue
            }
            let errorData = readAvailableData(from: standardError)
            let errorOutput = String(decoding: errorData, as: UTF8.self)
            XCTAssertNotEqual(process.terminationStatus, 0, errorOutput)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: staleURL.path),
                "The probe did not exercise the intended stale-cleanup failure."
            )
            let runStatus = try String(contentsOf: runStatusURL, encoding: .utf8)
            XCTAssertEqual(runStatus, "status=failed\n", errorOutput)
        }
    }

    func testEveryPhysicalDriverCleansFastExitedIsolatedGroup() throws {
        for driver in physicalDrivers {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioStreamer-driver-fast-group-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                repositoryRoot.appendingPathComponent(driver.relativePath).path,
            ] + driver.arguments(artifactDirectory)
            var environment = ProcessInfo.processInfo.environment
            environment["AUDIOSTREAMER_SCRIPT_SELF_TEST"] = "fast-group-failure"
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError

            try process.run()
            let exitedWithinDeadline = waitForExit(process, timeout: 8)
            if !exitedWithinDeadline {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(exitedWithinDeadline, "\(driver.relativePath) hung.")
            guard !process.isRunning else {
                XCTFail("\(driver.relativePath) survived forced cleanup.")
                continue
            }
            let errorData = readAvailableData(from: standardError)
            let errorOutput = String(decoding: errorData, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 8, errorOutput)
            let leaderPID = try XCTUnwrap(
                pid_t(
                    String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "fast-group-leader-pid.txt"
                        ),
                        encoding: .utf8
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            let childPID = try XCTUnwrap(
                pid_t(
                    String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "fast-group-child-pid.txt"
                        ),
                        encoding: .utf8
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            defer {
                kill(-leaderPID, SIGKILL)
                if kill(childPID, 0) == 0 {
                    kill(childPID, SIGKILL)
                }
            }
            XCTAssertTrue(
                waitForPIDToDisappear(childPID, timeout: 2),
                "\(driver.relativePath) orphaned fast child PID \(childPID)."
            )
            XCTAssertEqual(kill(-leaderPID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            let runStatus = try String(
                contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
                encoding: .utf8
            )
            XCTAssertEqual(runStatus, "status=failed\n", errorOutput)
        }
    }

    private func assertEveryPhysicalDriverFailsRuntimeSelfTest(
        mode: String,
        expectedStatus: Int32
    ) throws {
        for driver in physicalDrivers {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioStreamer-\(mode)-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            var staleEvidenceURLs: [URL] = []
            if mode == "fail-command", driver.relativePath.contains("update-keychain") {
                try FileManager.default.createDirectory(
                    at: artifactDirectory,
                    withIntermediateDirectories: true
                )
                staleEvidenceURLs = [
                    "seed-watchdog-state.txt",
                    "seed-watchdog-failure.txt",
                    "verify-watchdog-state.txt",
                    "verify-watchdog-failure.txt",
                ].map(artifactDirectory.appendingPathComponent)
                for url in staleEvidenceURLs {
                    try Data("stale".utf8).write(to: url)
                }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                repositoryRoot.appendingPathComponent(driver.relativePath).path,
            ] + driver.arguments(artifactDirectory)
            var environment = ProcessInfo.processInfo.environment
            environment["AUDIOSTREAMER_SCRIPT_SELF_TEST"] = mode
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError

            try process.run()
            defer {
                if process.isRunning {
                    forceStopProcessAndIsolatedGroup(process)
                } else {
                    kill(-process.processIdentifier, SIGKILL)
                }
            }
            let exitedWithinDeadline = waitForExit(process, timeout: 5)
            if !exitedWithinDeadline {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(exitedWithinDeadline, "\(driver.relativePath) hung in \(mode).")
            guard !process.isRunning else {
                XCTFail("\(driver.relativePath) survived forced cleanup in \(mode).")
                continue
            }
            let errorData = readAvailableData(from: standardError)
            let errorOutput = String(decoding: errorData, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, expectedStatus, errorOutput)
            let runStatusURL = artifactDirectory.appendingPathComponent("run-status.txt")
            let runStatus = try String(contentsOf: runStatusURL, encoding: .utf8)
            XCTAssertEqual(runStatus, "status=failed\n", errorOutput)
            for url in staleEvidenceURLs {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: url.path),
                    "\(driver.relativePath) retained stale lifecycle evidence at \(url.lastPathComponent)."
                )
            }
        }
    }

    private func assertReconnectProvenanceSelfTestPasses(
        _ scenario: String
    ) throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-host-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "host-provenance-\(scenario)",
            artifactDirectory: artifactDirectory,
            timeout: 8
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        let runStatus = try String(
            contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(runStatus, "status=self-test-passed\n", result.diagnostic)
    }

    private func runPhysicalDriverSelfTest(
        _ driver: PhysicalDriver,
        mode: String,
        artifactDirectory: URL,
        timeout: TimeInterval
    ) throws -> ZshProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repositoryRoot.appendingPathComponent(driver.relativePath).path,
        ] + driver.arguments(artifactDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["AUDIOSTREAMER_SCRIPT_SELF_TEST"] = mode
        process.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let exitedWithinDeadline = waitForExit(process, timeout: timeout)
        if !exitedWithinDeadline {
            forceStopProcessAndIsolatedGroup(process)
        }
        guard !process.isRunning else {
            throw NSError(
                domain: "PhysicalValidationScriptTests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "The physical driver self-test survived cleanup.",
                ]
            )
        }
        return ZshProbeResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(
                decoding: readAvailableData(from: standardOutput),
                as: UTF8.self
            ),
            standardError: String(
                decoding: readAvailableData(from: standardError),
                as: UTF8.self
            ),
            exitedWithinDeadline: exitedWithinDeadline
        )
    }

    private struct ZshProbeResult {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
        let exitedWithinDeadline: Bool

        var diagnostic: String {
            let timeoutMessage = exitedWithinDeadline ? "" : "Process exceeded its deadline.\n"
            return timeoutMessage + standardError
        }
    }

    private func runPhysicalValidationHelperProbe(
        _ command: String,
        arguments: [String]
    ) throws -> ZshProbeResult {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/AudioStreamer/scripts/physical-validation-helpers.zsh"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "source \"$1\"; shift; \(command)",
            "physical-validation-host-provenance-probe",
            helper.path,
        ] + arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let exitedWithinDeadline = waitForExit(process, timeout: 3)
        if !exitedWithinDeadline {
            forceStopProcessAndIsolatedGroup(process)
        }
        guard !process.isRunning else {
            throw NSError(
                domain: "PhysicalValidationScriptTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The zsh helper probe survived forced cleanup.",
                ]
            )
        }

        return ZshProbeResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(
                decoding: readAvailableData(from: standardOutput),
                as: UTF8.self
            ),
            standardError: String(
                decoding: readAvailableData(from: standardError),
                as: UTF8.self
            ),
            exitedWithinDeadline: exitedWithinDeadline
        )
    }

    private func forceStopProcessAndIsolatedGroup(
        _ process: Process,
        grace: TimeInterval = 0.5
    ) {
        let processID = process.processIdentifier

        // A physical driver can create a process group whose leader PID remains the stable handle
        // after that leader exits. Negative-PID signaling closes inherited pipes and prevents an
        // orphaned child from trapping a test even when the direct Process has already terminated.
        kill(-processID, SIGTERM)
        if process.isRunning {
            kill(processID, SIGTERM)
        }
        _ = waitForExit(process, timeout: grace)

        kill(-processID, SIGKILL)
        if process.isRunning {
            kill(processID, SIGKILL)
        }
        _ = waitForExit(process, timeout: 1)
    }

    private func readAvailableData(from pipe: Pipe) -> Data {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(descriptor, F_SETFL, originalFlags)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                data.append(contentsOf: buffer.prefix(byteCount))
                continue
            }
            if byteCount == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            if errno != EINTR {
                break
            }
        }
        return data
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        return !process.isRunning
    }

    private func waitForFileToExist(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            usleep(20_000)
        }
        return false
    }

    private func waitForPIDToDisappear(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(20_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}
