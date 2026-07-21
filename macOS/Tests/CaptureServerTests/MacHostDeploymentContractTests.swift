import Foundation
import XCTest

/// Locks the checked-in LaunchAgent, signed host process, and loaded launchd job into one
/// deployment contract.
///
/// These tests deliberately inspect both files on disk and the code actually mapped into a live
/// process. Mutation fixtures prove that a matching path is insufficient after an executable or
/// framework has been replaced. The launchd fixtures likewise require semantic plist identity,
/// exact arguments, reviewed job-scoped environment, and persistent restart behavior.
final class MacHostDeploymentContractTests: XCTestCase {
    private struct ProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var diagnostic: String {
            "status=\(status)\nstdout:\n\(standardOutput)\nstderr:\n\(standardError)"
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLaunchAgentTemplateRunsTheSignedHostWithExplicitCapabilities() throws {
        let template = repositoryRoot.appendingPathComponent(
            "macOS/LaunchAgents/org.example.audiostreamer.worldwide.plist"
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: template),
            format: nil
        )
        let values = try XCTUnwrap(propertyList as? [String: Any])
        let arguments = try XCTUnwrap(values["ProgramArguments"] as? [String])
        let environment = try XCTUnwrap(
            values["EnvironmentVariables"] as? [String: Any]
        )

        XCTAssertEqual(values["Label"] as? String, "org.example.audiostreamer.worldwide")
        XCTAssertEqual(
            arguments,
            [
                "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer",
                "--worldwide",
                "--allow-remote-control",
                "--duration",
                "0",
                "--verbose",
            ]
        )
        XCTAssertEqual(values["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(values["KeepAlive"] as? Bool, true)
        XCTAssertEqual(Set(environment.keys), Set(["OSLogRateLimit"]))
        XCTAssertEqual(environment["OSLogRateLimit"] as? String, "64")
        XCTAssertFalse(
            arguments.contains { argument in
                argument.contains("MacCaptureHost.app") || argument.contains("/.build/")
            }
        )
    }

    func testLiveProcessOracleRejectsWrongHashAndSamePathReplacement() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-live-code-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        let identifier = "org.example.AudioStreamer.ProcessOracleFixture"
        let executable = temporaryRoot.appendingPathComponent("runner")
        try copyAndSign(
            source: URL(fileURLWithPath: "/bin/sleep"),
            destination: executable,
            identifier: identifier
        )
        let originalHash = try codeHash(of: executable)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(process.isRunning)

        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-live-mac-host-process.sh"
        )
        let arguments = [
            String(process.processIdentifier),
            executable.path,
            originalHash,
            identifier,
            "not set",
            "/usr/lib/dyld",
        ]
        let positive = try run(executable: verifier, arguments: arguments)
        XCTAssertEqual(positive.status, 0, positive.diagnostic)
        XCTAssertTrue(
            positive.standardOutput.contains("live_cdhash=\(originalHash)"),
            positive.diagnostic
        )

        let wrongHash = String(repeating: "0", count: 40)
        let wrongHashRejection = try run(
            executable: verifier,
            arguments: [
                String(process.processIdentifier),
                executable.path,
                wrongHash,
                identifier,
                "not set",
                "/usr/lib/dyld",
            ]
        )
        XCTAssertNotEqual(wrongHashRejection.status, 0, wrongHashRejection.diagnostic)
        XCTAssertTrue(
            wrongHashRejection.standardError.contains(
                "live CDHash: expected '\(wrongHash)', found '\(originalHash)'"
            ),
            wrongHashRejection.diagnostic
        )

        let replacement = temporaryRoot.appendingPathComponent("replacement")
        try copyAndSign(
            source: URL(fileURLWithPath: "/bin/cat"),
            destination: replacement,
            identifier: identifier
        )
        let replacementHash = try codeHash(of: replacement)
        XCTAssertNotEqual(replacementHash, originalHash)
        let replace = try run(
            executable: URL(fileURLWithPath: "/bin/mv"),
            arguments: ["-f", replacement.path, executable.path]
        )
        XCTAssertEqual(replace.status, 0, replace.diagnostic)
        // POSIX replacement gives the path a new inode while the running process retains its old
        // mapping. This is the regression the live-image oracle must detect.
        XCTAssertTrue(
            process.isRunning,
            "The mutation must retain the old mapped process while replacing its on-disk path."
        )

        let staleMappingRejection = try run(
            executable: verifier,
            arguments: [
                String(process.processIdentifier),
                executable.path,
                replacementHash,
                identifier,
                "not set",
                "/usr/lib/dyld",
            ]
        )
        XCTAssertNotEqual(
            staleMappingRejection.status,
            0,
            staleMappingRejection.diagnostic
        )
        XCTAssertTrue(
            staleMappingRejection.standardError.contains(
                "failed dynamic code-signature validation"
            ) || staleMappingRejection.standardError.contains("live CDHash:"),
            staleMappingRejection.diagnostic
        )
    }

    func testLiveProcessOracleRejectsStaleFrameworkWithUnchangedMainExecutable() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-live-framework-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        let framework = temporaryRoot.appendingPathComponent("libFixture.dylib")
        let replacementFramework = temporaryRoot.appendingPathComponent(
            "replacement-libFixture.dylib"
        )
        let executable = temporaryRoot.appendingPathComponent("runner")
        try compileDynamicLibrary(at: framework, returnValue: 7)
        try compileDynamicLibrary(at: replacementFramework, returnValue: 11)
        try compileFrameworkFixtureRunner(at: executable, linkedTo: framework)

        let identifier = "org.example.AudioStreamer.FrameworkProcessOracleFixture"
        try sign(executable: framework, identifier: "org.example.AudioStreamer.Fixture")
        try sign(
            executable: replacementFramework,
            identifier: "org.example.AudioStreamer.Fixture"
        )
        try sign(executable: executable, identifier: identifier)
        let originalExecutableHash = try codeHash(of: executable)

        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
        XCTAssertTrue(process.isRunning)

        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-live-mac-host-process.sh"
        )
        let verifierArguments = [
            String(process.processIdentifier),
            executable.path,
            originalExecutableHash,
            identifier,
            "not set",
            framework.path,
        ]
        let positive = try eventuallyRun(
            executable: verifier,
            arguments: verifierArguments
        ) { $0.status == 0 }
        XCTAssertEqual(positive.status, 0, positive.diagnostic)

        let replace = try run(
            executable: URL(fileURLWithPath: "/bin/mv"),
            arguments: ["-f", replacementFramework.path, framework.path]
        )
        XCTAssertEqual(replace.status, 0, replace.diagnostic)
        // Keep the main executable byte-for-byte stable so rejection can only come from checking
        // the already-mapped framework rather than revalidating the executable path.
        XCTAssertTrue(
            process.isRunning,
            "The framework mutant must leave the original process alive."
        )
        XCTAssertEqual(
            try codeHash(of: executable),
            originalExecutableHash,
            "The mutant must change only the framework, not the main executable."
        )

        let staleFrameworkRejection = try run(
            executable: verifier,
            arguments: verifierArguments
        )
        XCTAssertNotEqual(
            staleFrameworkRejection.status,
            0,
            staleFrameworkRejection.diagnostic
        )
        XCTAssertTrue(
            staleFrameworkRejection.standardError.contains("live framework mapping:"),
            staleFrameworkRejection.diagnostic
        )
    }

    func testLaunchStateOracleRejectsDriftedConfigurationAndLoadedPersistence() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-launch-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let executable = "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer"
        let template = repositoryRoot.appendingPathComponent(
            "macOS/LaunchAgents/org.example.audiostreamer.worldwide.plist"
        )
        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-mac-host-launch-state.sh"
        )
        let installed = temporaryRoot.appendingPathComponent(
            "org.example.audiostreamer.worldwide.plist"
        )
        try FileManager.default.copyItem(at: template, to: installed)
        // This is a representative `launchctl print gui/<uid>/<label>` rendering. The verifier
        // parses it as an external wire format, so whitespace and section boundaries are part of
        // the fixture even though plist formatting itself is intentionally semantic.
        let baseline = """
        gui/501/org.example.audiostreamer.worldwide = {
            path = \(installed.path)
            type = LaunchAgent
            program = \(executable)
            arguments = {
                \(executable)
                --worldwide
                --allow-remote-control
                --duration
                0
                --verbose
            }
            inherited environment = {
                SSH_AUTH_SOCK => /var/run/example
            }
            default environment = {
                PATH => /usr/bin:/bin:/usr/sbin:/sbin
            }
            environment = {
                OSLogRateLimit => 64
                XPC_SERVICE_NAME => org.example.audiostreamer.worldwide
            }
            pid = 4242
            properties = keepalive | runatload | inferred program
        }
        """

        let baselineURL = temporaryRoot.appendingPathComponent("baseline.txt")
        try baseline.write(to: baselineURL, atomically: true, encoding: .utf8)
        let baselineArguments = [
            baselineURL.path,
            executable,
            template.path,
            installed.path,
        ]
        let positive = try run(
            executable: verifier,
            arguments: baselineArguments
        )
        XCTAssertEqual(positive.status, 0, positive.diagnostic)

        // macOS 26 can repeat the same job-scoped value in `launchctl print`.
        // Repetition is harmless only when every reported value agrees with the
        // source-controlled LaunchAgent.
        let repeatedIdenticalOSLogRateLimit = baseline.replacingOccurrences(
            of: "OSLogRateLimit => 64",
            with: "OSLogRateLimit => 64\n" +
                "        OSLogRateLimit => 64"
        )
        XCTAssertNotEqual(repeatedIdenticalOSLogRateLimit, baseline)
        let repeatedIdenticalOSLogRateLimitURL = temporaryRoot.appendingPathComponent(
            "repeated-identical-os-log-rate-limit.txt"
        )
        try repeatedIdenticalOSLogRateLimit.write(
            to: repeatedIdenticalOSLogRateLimitURL,
            atomically: true,
            encoding: .utf8
        )
        let repeatedIdenticalPositive = try run(
            executable: verifier,
            arguments: [
                repeatedIdenticalOSLogRateLimitURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertEqual(
            repeatedIdenticalPositive.status,
            0,
            repeatedIdenticalPositive.diagnostic
        )

        let repeatedIdenticalXPCServiceName = baseline.replacingOccurrences(
            of: "XPC_SERVICE_NAME => org.example.audiostreamer.worldwide",
            with: "XPC_SERVICE_NAME => org.example.audiostreamer.worldwide\n" +
                "        XPC_SERVICE_NAME => org.example.audiostreamer.worldwide"
        )
        XCTAssertNotEqual(repeatedIdenticalXPCServiceName, baseline)
        let repeatedIdenticalXPCServiceNameURL = temporaryRoot.appendingPathComponent(
            "repeated-identical-xpc-service-name.txt"
        )
        try repeatedIdenticalXPCServiceName.write(
            to: repeatedIdenticalXPCServiceNameURL,
            atomically: true,
            encoding: .utf8
        )
        let repeatedIdenticalXPCPositive = try run(
            executable: verifier,
            arguments: [
                repeatedIdenticalXPCServiceNameURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertEqual(
            repeatedIdenticalXPCPositive.status,
            0,
            repeatedIdenticalXPCPositive.diagnostic
        )

        // XPC_SERVICE_NAME is injected by launchd rather than declared by the
        // release manifest. Validate it when present without depending on a
        // particular macOS `launchctl print` rendering.
        let absentXPCServiceName = baseline.replacingOccurrences(
            of: "        XPC_SERVICE_NAME => org.example.audiostreamer.worldwide\n",
            with: ""
        )
        XCTAssertNotEqual(absentXPCServiceName, baseline)
        let absentXPCServiceNameURL = temporaryRoot.appendingPathComponent(
            "absent-xpc-service-name.txt"
        )
        try absentXPCServiceName.write(
            to: absentXPCServiceNameURL,
            atomically: true,
            encoding: .utf8
        )
        let absentXPCPositive = try run(
            executable: verifier,
            arguments: [
                absentXPCServiceNameURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertEqual(absentXPCPositive.status, 0, absentXPCPositive.diagnostic)

        let conflictingRepeatedOSLogRateLimit = baseline.replacingOccurrences(
            of: "OSLogRateLimit => 64",
            with: "OSLogRateLimit => 64\n" +
                "        OSLogRateLimit => 63"
        )
        XCTAssertNotEqual(conflictingRepeatedOSLogRateLimit, baseline)
        let conflictingRepeatedOSLogRateLimitURL = temporaryRoot.appendingPathComponent(
            "conflicting-repeated-os-log-rate-limit.txt"
        )
        try conflictingRepeatedOSLogRateLimit.write(
            to: conflictingRepeatedOSLogRateLimitURL,
            atomically: true,
            encoding: .utf8
        )
        let conflictingRepeatedRejection = try run(
            executable: verifier,
            arguments: [
                conflictingRepeatedOSLogRateLimitURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            conflictingRepeatedRejection.status,
            0,
            conflictingRepeatedRejection.diagnostic
        )
        XCTAssertTrue(
            conflictingRepeatedRejection.standardError.contains(
                "loaded launchd OSLogRateLimit is '63', expected '64'"
            ),
            conflictingRepeatedRejection.diagnostic
        )

        let conflictingRepeatedXPCServiceName = baseline.replacingOccurrences(
            of: "XPC_SERVICE_NAME => org.example.audiostreamer.worldwide",
            with: "XPC_SERVICE_NAME => org.example.audiostreamer.worldwide\n" +
                "        XPC_SERVICE_NAME => com.example.wrong"
        )
        XCTAssertNotEqual(conflictingRepeatedXPCServiceName, baseline)
        let conflictingRepeatedXPCServiceNameURL = temporaryRoot.appendingPathComponent(
            "conflicting-repeated-xpc-service-name.txt"
        )
        try conflictingRepeatedXPCServiceName.write(
            to: conflictingRepeatedXPCServiceNameURL,
            atomically: true,
            encoding: .utf8
        )
        let conflictingRepeatedXPCRejection = try run(
            executable: verifier,
            arguments: [
                conflictingRepeatedXPCServiceNameURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            conflictingRepeatedXPCRejection.status,
            0,
            conflictingRepeatedXPCRejection.diagnostic
        )
        XCTAssertTrue(
            conflictingRepeatedXPCRejection.standardError.contains(
                "loaded launchd XPC_SERVICE_NAME is 'com.example.wrong'"
            ),
            conflictingRepeatedXPCRejection.diagnostic
        )

        let trailingOSLogRateLimit = baseline.replacingOccurrences(
            of: "OSLogRateLimit => 64",
            with: "OSLogRateLimit => 64 trailing"
        )
        XCTAssertNotEqual(trailingOSLogRateLimit, baseline)
        let trailingOSLogRateLimitURL = temporaryRoot.appendingPathComponent(
            "trailing-os-log-rate-limit.txt"
        )
        try trailingOSLogRateLimit.write(
            to: trailingOSLogRateLimitURL,
            atomically: true,
            encoding: .utf8
        )
        let trailingOSLogRateLimitRejection = try run(
            executable: verifier,
            arguments: [
                trailingOSLogRateLimitURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            trailingOSLogRateLimitRejection.status,
            0,
            trailingOSLogRateLimitRejection.diagnostic
        )

        let unknownJobEnvironment = baseline.replacingOccurrences(
            of: "XPC_SERVICE_NAME => org.example.audiostreamer.worldwide",
            with: "XPC_SERVICE_NAME => org.example.audiostreamer.worldwide\n" +
                "        UNREVIEWED_MODE => enabled"
        )
        XCTAssertNotEqual(unknownJobEnvironment, baseline)
        let unknownJobEnvironmentURL = temporaryRoot.appendingPathComponent(
            "unknown-job-environment.txt"
        )
        try unknownJobEnvironment.write(
            to: unknownJobEnvironmentURL,
            atomically: true,
            encoding: .utf8
        )
        let unknownJobEnvironmentRejection = try run(
            executable: verifier,
            arguments: [
                unknownJobEnvironmentURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            unknownJobEnvironmentRejection.status,
            0,
            unknownJobEnvironmentRejection.diagnostic
        )
        XCTAssertTrue(
            unknownJobEnvironmentRejection.standardError.contains(
                "unreviewed environment key 'UNREVIEWED_MODE'"
            ),
            unknownJobEnvironmentRejection.diagnostic
        )

        let semanticallyIdenticalData = try PropertyListSerialization.data(
            fromPropertyList: try XCTUnwrap(
                try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: template),
                    format: nil
                ) as? [String: Any]
            ),
            format: .xml,
            options: 0
        )
        try semanticallyIdenticalData.write(to: installed, options: .atomic)
        // Re-encoding the plist changes bytes and formatting without changing its meaning.
        XCTAssertNotEqual(
            try Data(contentsOf: installed),
            try Data(contentsOf: template),
            "The positive fixture must prove formatting is not part of plist identity."
        )
        let reformattedPositive = try run(
            executable: verifier,
            arguments: baselineArguments
        )
        XCTAssertEqual(reformattedPositive.status, 0, reformattedPositive.diagnostic)

        try FileManager.default.removeItem(at: installed)
        try FileManager.default.copyItem(at: template, to: installed)

        let extraArgument = baseline.replacingOccurrences(
            of: "--verbose",
            with: "--with-lan\n        --verbose"
        )
        XCTAssertNotEqual(extraArgument, baseline)
        let extraArgumentURL = temporaryRoot.appendingPathComponent("extra-argument.txt")
        try extraArgument.write(to: extraArgumentURL, atomically: true, encoding: .utf8)
        let extraArgumentRejection = try run(
            executable: verifier,
            arguments: [
                extraArgumentURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            extraArgumentRejection.status,
            0,
            extraArgumentRejection.diagnostic
        )
        XCTAssertTrue(
            extraArgumentRejection.standardError.contains(
                "arguments do not exactly match"
            ),
            extraArgumentRejection.diagnostic
        )

        let overriddenEnvironment = baseline.replacingOccurrences(
            of: "OSLogRateLimit => 64",
            with: "OSLogRateLimit => 64\n" +
                "        AUDIOSTREAMER_RENDEZVOUS_URL => wss://wrong.example"
        )
        XCTAssertNotEqual(overriddenEnvironment, baseline)
        let overriddenEnvironmentURL = temporaryRoot.appendingPathComponent(
            "overridden-environment.txt"
        )
        try overriddenEnvironment.write(
            to: overriddenEnvironmentURL,
            atomically: true,
            encoding: .utf8
        )
        let environmentRejection = try run(
            executable: verifier,
            arguments: [
                overriddenEnvironmentURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(environmentRejection.status, 0, environmentRejection.diagnostic)
        XCTAssertTrue(
            environmentRejection.standardError.contains(
                "behavior-overriding environment: AUDIOSTREAMER_RENDEZVOUS_URL"
            ),
            environmentRejection.diagnostic
        )

        let missingOSLogRateLimit = baseline.replacingOccurrences(
            of: "OSLogRateLimit => 64",
            with: ""
        )
        XCTAssertNotEqual(missingOSLogRateLimit, baseline)
        let missingOSLogRateLimitURL = temporaryRoot.appendingPathComponent(
            "missing-os-log-rate-limit.txt"
        )
        try missingOSLogRateLimit.write(
            to: missingOSLogRateLimitURL,
            atomically: true,
            encoding: .utf8
        )
        let missingOSLogRateLimitRejection = try run(
            executable: verifier,
            arguments: [
                missingOSLogRateLimitURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            missingOSLogRateLimitRejection.status,
            0,
            missingOSLogRateLimitRejection.diagnostic
        )
        XCTAssertTrue(
            missingOSLogRateLimitRejection.standardError.contains(
                "loaded launchd job is missing OSLogRateLimit"
            ),
            missingOSLogRateLimitRejection.diagnostic
        )

        let inheritedOnlyOSLogRateLimit = baseline.replacingOccurrences(
            of: "    environment = {\n" +
                "        OSLogRateLimit => 64\n" +
                "        XPC_SERVICE_NAME => org.example.audiostreamer.worldwide\n" +
                "    }",
            with: "    inherited environment = {\n" +
                "        OSLogRateLimit => 64\n" +
                "    }\n" +
                "    environment = {\n" +
                "        XPC_SERVICE_NAME => org.example.audiostreamer.worldwide\n" +
                "    }"
        )
        XCTAssertNotEqual(inheritedOnlyOSLogRateLimit, baseline)
        let inheritedOnlyOSLogRateLimitURL = temporaryRoot.appendingPathComponent(
            "inherited-only-os-log-rate-limit.txt"
        )
        try inheritedOnlyOSLogRateLimit.write(
            to: inheritedOnlyOSLogRateLimitURL,
            atomically: true,
            encoding: .utf8
        )
        let inheritedOnlyOSLogRateLimitRejection = try run(
            executable: verifier,
            arguments: [
                inheritedOnlyOSLogRateLimitURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            inheritedOnlyOSLogRateLimitRejection.status,
            0,
            inheritedOnlyOSLogRateLimitRejection.diagnostic
        )
        XCTAssertTrue(
            inheritedOnlyOSLogRateLimitRejection.standardError.contains(
                "loaded launchd job is missing OSLogRateLimit"
            ),
            inheritedOnlyOSLogRateLimitRejection.diagnostic
        )

        let wrongOSLogRateLimit = baseline.replacingOccurrences(
            of: "OSLogRateLimit => 64",
            with: "OSLogRateLimit => 63"
        )
        XCTAssertNotEqual(wrongOSLogRateLimit, baseline)
        let wrongOSLogRateLimitURL = temporaryRoot.appendingPathComponent(
            "wrong-os-log-rate-limit.txt"
        )
        try wrongOSLogRateLimit.write(
            to: wrongOSLogRateLimitURL,
            atomically: true,
            encoding: .utf8
        )
        let wrongOSLogRateLimitRejection = try run(
            executable: verifier,
            arguments: [
                wrongOSLogRateLimitURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            wrongOSLogRateLimitRejection.status,
            0,
            wrongOSLogRateLimitRejection.diagnostic
        )
        XCTAssertTrue(
            wrongOSLogRateLimitRejection.standardError.contains(
                "loaded launchd OSLogRateLimit is '63', expected '64'"
            ),
            wrongOSLogRateLimitRejection.diagnostic
        )

        let sourceValues = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: template),
                format: nil
            ) as? [String: Any]
        )

        func writeInstalledMutation(key: String, value: Any) throws {
            var values = sourceValues
            values[key] = value
            let data = try PropertyListSerialization.data(
                fromPropertyList: values,
                format: .xml,
                options: 0
            )
            try data.write(to: installed, options: .atomic)
        }

        func assertInstalledMutationRejected(
            key: String,
            value: Any,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            // Each mutant changes only the installed copy; source and loaded-state fixtures stay
            // fixed so a pass cannot be attributed to another launchd validation boundary.
            try writeInstalledMutation(key: key, value: value)
            XCTAssertNotEqual(
                try Data(contentsOf: installed),
                try Data(contentsOf: template),
                "The plist mutant must differ from the source artifact.",
                file: file,
                line: line
            )
            let rejection = try run(
                executable: verifier,
                arguments: baselineArguments
            )
            XCTAssertNotEqual(rejection.status, 0, rejection.diagnostic, file: file, line: line)
            XCTAssertTrue(
                rejection.standardError.contains(
                    "installed LaunchAgent plist differs from the source-controlled template"
                ),
                rejection.diagnostic,
                file: file,
                line: line
            )
        }

        try assertInstalledMutationRejected(key: "KeepAlive", value: false)
        try assertInstalledMutationRejected(key: "RunAtLoad", value: false)
        try assertInstalledMutationRejected(key: "ThrottleInterval", value: 11)

        func assertSourcePersistenceMutationRejected(
            key: String,
            expectedDiagnostic: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            // Mutate source and installed plists together to isolate the semantic persistence
            // rule from the separate source-versus-installed drift check.
            var values = sourceValues
            values[key] = false
            let mutatedTemplate = temporaryRoot.appendingPathComponent(
                "source-\(key).plist"
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: values,
                format: .xml,
                options: 0
            )
            try data.write(to: mutatedTemplate, options: .atomic)
            try data.write(to: installed, options: .atomic)
            XCTAssertEqual(
                try Data(contentsOf: installed),
                try Data(contentsOf: mutatedTemplate),
                "This mutant must isolate the persistence contract, not file drift.",
                file: file,
                line: line
            )
            let rejection = try run(
                executable: verifier,
                arguments: [
                    baselineURL.path,
                    executable,
                    mutatedTemplate.path,
                    installed.path,
                ]
            )
            XCTAssertNotEqual(rejection.status, 0, rejection.diagnostic, file: file, line: line)
            XCTAssertTrue(
                rejection.standardError.contains(expectedDiagnostic),
                rejection.diagnostic,
                file: file,
                line: line
            )
        }

        try assertSourcePersistenceMutationRejected(
            key: "KeepAlive",
            expectedDiagnostic: "requires KeepAlive=true"
        )
        try assertSourcePersistenceMutationRejected(
            key: "RunAtLoad",
            expectedDiagnostic: "requires RunAtLoad=true"
        )

        try FileManager.default.removeItem(at: installed)
        try FileManager.default.copyItem(at: template, to: installed)

        let missingKeepAlive = baseline.replacingOccurrences(
            of: "properties = keepalive | runatload | inferred program",
            with: "properties = runatload | inferred program"
        )
        XCTAssertNotEqual(missingKeepAlive, baseline)
        let missingKeepAliveURL = temporaryRoot.appendingPathComponent(
            "missing-keepalive.txt"
        )
        try missingKeepAlive.write(
            to: missingKeepAliveURL,
            atomically: true,
            encoding: .utf8
        )
        let missingKeepAliveRejection = try run(
            executable: verifier,
            arguments: [
                missingKeepAliveURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            missingKeepAliveRejection.status,
            0,
            missingKeepAliveRejection.diagnostic
        )
        XCTAssertTrue(
            missingKeepAliveRejection.standardError.contains(
                "missing KeepAlive persistence"
            ),
            missingKeepAliveRejection.diagnostic
        )

        let missingRunAtLoad = baseline.replacingOccurrences(
            of: "properties = keepalive | runatload | inferred program",
            with: "properties = keepalive | inferred program"
        )
        XCTAssertNotEqual(missingRunAtLoad, baseline)
        let missingRunAtLoadURL = temporaryRoot.appendingPathComponent(
            "missing-run-at-load.txt"
        )
        try missingRunAtLoad.write(
            to: missingRunAtLoadURL,
            atomically: true,
            encoding: .utf8
        )
        let missingRunAtLoadRejection = try run(
            executable: verifier,
            arguments: [
                missingRunAtLoadURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            missingRunAtLoadRejection.status,
            0,
            missingRunAtLoadRejection.diagnostic
        )
        XCTAssertTrue(
            missingRunAtLoadRejection.standardError.contains(
                "missing RunAtLoad persistence"
            ),
            missingRunAtLoadRejection.diagnostic
        )

        let wrongLoadedPath = baseline.replacingOccurrences(
            of: "path = \(installed.path)",
            with: "path = \(installed.path).stale"
        )
        XCTAssertNotEqual(wrongLoadedPath, baseline)
        let wrongLoadedPathURL = temporaryRoot.appendingPathComponent(
            "wrong-loaded-path.txt"
        )
        try wrongLoadedPath.write(
            to: wrongLoadedPathURL,
            atomically: true,
            encoding: .utf8
        )
        let wrongLoadedPathRejection = try run(
            executable: verifier,
            arguments: [
                wrongLoadedPathURL.path,
                executable,
                template.path,
                installed.path,
            ]
        )
        XCTAssertNotEqual(
            wrongLoadedPathRejection.status,
            0,
            wrongLoadedPathRejection.diagnostic
        )
        XCTAssertTrue(
            wrongLoadedPathRejection.standardError.contains("launchd loaded plist is"),
            wrongLoadedPathRejection.diagnostic
        )
    }

    private func copyAndSign(source: URL, destination: URL, identifier: String) throws {
        let copy = try run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: [source.path, destination.path]
        )
        XCTAssertEqual(copy.status, 0, copy.diagnostic)
        let sign = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                // Ad-hoc signing exercises code-identity checks without requiring a private key.
                "--sign",
                "-",
                "--identifier",
                identifier,
                destination.path,
            ]
        )
        XCTAssertEqual(sign.status, 0, sign.diagnostic)
    }

    private func compileDynamicLibrary(at output: URL, returnValue: Int) throws {
        // Distinct return constants force the two dylibs to have different signed code content.
        let source = output.deletingPathExtension().appendingPathExtension("c")
        try "int fixture_value(void) { return \(returnValue); }\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [
                "-dynamiclib",
                "-install_name",
                "@rpath/libFixture.dylib",
                source.path,
                "-o",
                output.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }

    private func compileFrameworkFixtureRunner(at output: URL, linkedTo framework: URL) throws {
        // The runner loads the fixture before sleeping, ensuring the verifier observes a live
        // mapping rather than a merely linked but unopened path.
        let source = output.appendingPathExtension("c")
        try """
        #include <unistd.h>
        extern int fixture_value(void);
        int main(void) {
            if (fixture_value() != 7) { return 7; }
            sleep(30);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [
                source.path,
                framework.path,
                "-Wl,-rpath,@executable_path",
                "-o",
                output.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }

    private func sign(executable: URL, identifier: String) throws {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                "--sign",
                "-",
                "--identifier",
                identifier,
                executable.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }

    private func eventuallyRun(
        executable: URL,
        arguments: [String],
        until predicate: (ProcessResult) -> Bool
    ) throws -> ProcessResult {
        // dyld/code-signing metadata can become observable just after Process reports launch.
        // Poll for at most two seconds instead of introducing an unconditional slow sleep.
        let deadline = Date().addingTimeInterval(2)
        var result = try run(executable: executable, arguments: arguments)
        while !predicate(result), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            result = try run(executable: executable, arguments: arguments)
        }
        return result
    }

    private func codeHash(of executable: URL) throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--display", "--verbose=4", executable.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        let hash = result.standardError
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("CDHash=") }?
            .dropFirst("CDHash=".count)
        return try XCTUnwrap(hash.map(String.init), result.diagnostic)
    }

    private func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot

        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let standardOutputURL = captureDirectory.appendingPathComponent("stdout")
        let standardErrorURL = captureDirectory.appendingPathComponent("stderr")
        // File-backed capture cannot fill a pipe while this synchronous helper waits for exit.
        XCTAssertTrue(FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil))
        let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        let standardError = try FileHandle(forWritingTo: standardErrorURL)
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        try standardOutput.close()
        try standardError.close()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: try Data(contentsOf: standardOutputURL),
                as: UTF8.self
            ),
            standardError: String(
                decoding: try Data(contentsOf: standardErrorURL),
                as: UTF8.self
            )
        )
    }
}
