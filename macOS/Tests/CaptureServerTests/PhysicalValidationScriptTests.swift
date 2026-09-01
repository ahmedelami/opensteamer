import Foundation
import Darwin
import AVFoundation
import XCTest

/// Regression-tests the shell harness that turns physical iPhone runs into trustworthy evidence.
///
/// The suite invokes real zsh processes but selects script-owned self-test modes, so it validates
/// artifact freshness, process provenance, bounded cleanup, and failure reporting without needing
/// a connected phone. The oracles favor false negatives over stale or ambiguous passes: every
/// required activity must belong to one run, every connection must map to the intended host PID,
/// and every spawned process group must be reclaimable on success, failure, cancellation, or timeout.
final class PhysicalValidationScriptTests: XCTestCase {
    private static let rustOracleSupport: (directory: URL, binary: URL) = {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
            .appendingPathComponent(
                "opensteamer-physical-validation-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let temporaryDirectory = directory.appendingPathComponent("tmp", isDirectory: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/physical-validation-oracle.rs"
        )
        let binary = directory.appendingPathComponent("physical-validation-oracle")

        try! fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        precondition(chmod(directory.path, S_IRWXU) == 0)
        precondition(chmod(temporaryDirectory.path, S_IRWXU) == 0)
        let compiler = Process()
        compiler.executableURL = URL(
            fileURLWithPath: "/opt/homebrew/Cellar/rust/1.97.1/bin/rustc"
        )
        compiler.arguments = [
            "--edition=2021",
            "-D", "warnings",
            "-C", "opt-level=2",
            "--sysroot", "/opt/homebrew/Cellar/rust/1.97.1",
            source.path,
            "-o", binary.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        compiler.environment = environment
        try! compiler.run()
        compiler.waitUntilExit()
        precondition(compiler.terminationStatus == 0)
        precondition(chmod(binary.path, S_IRUSR | S_IXUSR) == 0)
        return (directory, binary)
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        setenv(
            "OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE",
            Self.rustOracleSupport.binary.path,
            1
        )
    }

    override class func tearDown() {
        unsetenv("OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE")
        try? FileManager.default.removeItem(at: rustOracleSupport.directory)
        super.tearDown()
    }

    /// A physical driver and the positional arguments needed to enter its inert self-test mode.
    private typealias PhysicalDriver = (
        relativePath: String,
        arguments: (URL) -> [String]
    )

    private enum SyntheticPhysicalDevice {
        static let coreDeviceIdentifier = "synthetic-coredevice-selector"
        static let hardwareUDID = "synthetic-hardware-udid"
        static let expectedBuild = "self-test-build"
        static let physicalOutputUID = "BuiltInSpeakerDevice"
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var physicalDrivers: [PhysicalDriver] {
        // Keep this inventory aligned with every script capable of publishing a physical-pass
        // artifact; shared cleanup/failure tests iterate the complete set.
        [
            (
                "iOS/opensteamer/scripts/validate-release-pair-baseline.sh",
                { artifactDirectory in
                    [
                        SyntheticPhysicalDevice.coreDeviceIdentifier,
                        SyntheticPhysicalDevice.hardwareUDID,
                        SyntheticPhysicalDevice.expectedBuild,
                        artifactDirectory.path,
                    ]
                }
            ),
            (
                "iOS/opensteamer/scripts/validate-physical-update-keychain.sh",
                { artifactDirectory in
                    [
                        SyntheticPhysicalDevice.coreDeviceIdentifier,
                        SyntheticPhysicalDevice.hardwareUDID,
                        artifactDirectory.path,
                    ]
                }
            ),
            (
                "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh",
                { artifactDirectory in
                    [
                        SyntheticPhysicalDevice.coreDeviceIdentifier,
                        SyntheticPhysicalDevice.hardwareUDID,
                        SyntheticPhysicalDevice.expectedBuild,
                        SyntheticPhysicalDevice.physicalOutputUID,
                        artifactDirectory.path,
                    ]
                }
            ),
        ]
    }

    func testReconnectDriverAndSharedHelpersHaveNoPythonRuntimeDependency() throws {
        for relativePath in [
            "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh",
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.lowercased().contains("python"),
                "\(relativePath) reintroduced an interpreter dependency."
            )
        }
    }

    func testRawMicrophonePhysicalContractRequiresBuiltInCaptureRouteV3() throws {
        let parser = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/OracleTestSupport/PhysicalOracleEvaluator.swift"
            ),
            encoding: .utf8
        )
        let production = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/Sources/Diagnostics/WorldwidePhysicalOracles.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(parser.contains("private static let schemaVersion = 3"))
        XCTAssertTrue(parser.contains("fields[\"captureBuiltInMic\"] == \"1\""))
        XCTAssertTrue(production.contains("fields.append(\"captureBuiltInMic=1\")"))
        XCTAssertTrue(production.contains("captureRouteProofGeneration"))
    }

    func testReconnectDriverRejectsReservedSelfTestEnvironmentOutsideSelfTest() throws {
        let artifactDirectory = URL(
            fileURLWithPath:
                "/Volumes/t7/opensteamer-self-test-env-rejection-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh"
            ).path,
            SyntheticPhysicalDevice.coreDeviceIdentifier,
            SyntheticPhysicalDevice.hardwareUDID,
            SyntheticPhysicalDevice.expectedBuild,
            SyntheticPhysicalDevice.physicalOutputUID,
            artifactDirectory.path,
        ]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("OPENSTEAMER_SELF_TEST_")
                && $0.key != "OPENSTEAMER_SCRIPT_SELF_TEST"
        }
        environment["OPENSTEAMER_SELF_TEST_RAW_NOW_NS"] = ""
        process.environment = environment
        let standardError = Pipe()
        process.standardError = standardError

        try process.run()
        let exited = waitForExit(process, timeout: 3)
        if !exited {
            forceStopProcessAndIsolatedGroup(process)
        }
        XCTAssertTrue(exited)
        guard !process.isRunning else { return }
        let diagnostic = String(
            decoding: readAvailableData(from: standardError),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 2, diagnostic)
        XCTAssertTrue(
            diagnostic.contains("reserved self-test variables present"),
            diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    func testReconnectDriverRejectsUnsafeArtifactPathsWithoutTouchingOutsideSentinel()
        throws {
        let fileManager = FileManager.default
        let outside = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-artifact-guard-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        let t7Prefix = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
            .appendingPathComponent(
                "opensteamer-artifact-guard-\(UUID().uuidString)",
                isDirectory: true
            )
        let symlink = t7Prefix.appendingPathComponent("linked", isDirectory: true)
        let wrongMode = t7Prefix.appendingPathComponent("wrong-mode", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: t7Prefix)
            try? fileManager.removeItem(at: outside)
        }
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("preserve-me\n".utf8).write(to: sentinel)
        try fileManager.createDirectory(at: t7Prefix, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(t7Prefix.path, S_IRWXU), 0)
        try fileManager.createSymbolicLink(
            at: symlink,
            withDestinationURL: outside
        )
        try fileManager.createDirectory(at: wrongMode, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(wrongMode.path, 0o755), 0)

        let traversal = URL(
            fileURLWithPath:
                "/Volumes/t7/guard/../..\(outside.path)/artifact",
            isDirectory: true
        )
        for (mode, path) in [
            ("artifact-path-traversal", traversal),
            ("artifact-path-symlink", symlink.appendingPathComponent("artifact")),
            ("artifact-path-wrong-mode", wrongMode.appendingPathComponent("artifact")),
        ] {
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: path,
                timeout: 8
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 2, result.diagnostic)
            XCTAssertEqual(
                try String(contentsOf: sentinel, encoding: .utf8),
                "preserve-me\n",
                "\(mode) touched the outside sentinel."
            )
        }
    }

    func testReconnectDriverRejectsProtectedOrArbitraryHostLabelBeforeLaunchctlMutation()
        throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opensteamer-host-label-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
        let shimDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let mutationLog = root.appendingPathComponent("launchctl-mutations.txt")
        let shim = shimDirectory.appendingPathComponent("launchctl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: shimDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            "#!/bin/zsh\nprint -r -- mutation >> \"$OPENSTEAMER_LAUNCHCTL_MUTATION_LOG\"\nexit 99\n".utf8
        ).write(to: shim)
        XCTAssertEqual(chmod(shim.path, S_IRWXU), 0)

        for label in [
            "com.elamin.audiostreamer.worldwide",
            "org.example.arbitrary.worldwide",
        ] {
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: "host-identity-preflight",
                artifactDirectory: root.appendingPathComponent(UUID().uuidString),
                timeout: 5,
                additionalEnvironment: [
                    "OPENSTEAMER_HOST_LAUNCH_AGENT_LABEL": label,
                    "OPENSTEAMER_LAUNCHCTL_MUTATION_LOG": mutationLog.path,
                    "PATH": shimDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                ]
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 2, result.diagnostic)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mutationLog.path),
            "An unsafe launch identity reached launchctl."
        )
    }

    func testRustPhysicalValidationOracleSelfTestPasses() throws {
        let process = Process()
        process.executableURL = Self.rustOracleSupport.binary
        process.arguments = ["self-test"]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let exited = waitForExit(process, timeout: 10)
        if !exited {
            forceStopProcessAndIsolatedGroup(process)
        }
        XCTAssertTrue(exited, "The Rust physical-validation oracle self-test timed out.")
        guard !process.isRunning else { return }
        let output = String(
            decoding: readAvailableData(from: standardOutput),
            as: UTF8.self
        )
        let error = String(
            decoding: readAvailableData(from: standardError),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertEqual(output, "SELF_TEST_OK physical-validation-oracle\n")
    }

    func testReconnectSelfTestRejectsArbitraryExportedRustOracle() throws {
        let artifactDirectory = URL(
            fileURLWithPath:
                "/Volumes/t7/opensteamer-exported-oracle-rejection-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "raw-readiness-exact-start",
            artifactDirectory: artifactDirectory,
            timeout: 5,
            additionalEnvironment: [
                "OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE": "/bin/true",
            ]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertTrue(
            result.standardError.contains(
                "XCTest-exported Rust physical-validation oracle is unsafe"
            ),
            result.diagnostic
        )
        XCTAssertEqual(
            try String(
                contentsOf: artifactDirectory.appendingPathComponent(
                    "run-status.txt"
                ),
                encoding: .utf8
            ),
            "status=failed\n"
        )
    }

    func testReconnectDriverBuildsPinnedMigrationLockProbeOnT7() throws {
        let artifactDirectory = URL(
            fileURLWithPath:
                "/Volumes/t7/opensteamer-migration-lock-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "migration-controller-lock-probe-build",
            artifactDirectory: artifactDirectory,
            timeout: 10
        )
        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertEqual(
            try String(
                contentsOf: artifactDirectory.appendingPathComponent(
                    "migration-controller-lock-probe-status.txt"
                ),
                encoding: .utf8
            ),
            "status=validated sha256=0beb8e96aabd059ee5f108dfd05d7d5d99fa52b58f56ab942a31ee8efd33f528\n"
        )
    }

    func testUpdateDriverRunsMissingCredentialCasesWithInertApplicationHost() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/validate-physical-update-keychain.sh"
            ),
            encoding: .utf8
        )
        let applicationRoot = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/Sources/App/OpensteamerApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            script.contains(
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG " +
                    "OPENSTEAMER_UPDATE_VALIDATION_HOST ${condition}"
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

        XCTAssertTrue(applicationRoot.contains("#if OPENSTEAMER_UPDATE_VALIDATION_HOST"))
        XCTAssertTrue(applicationRoot.contains("isPhysicalUpdateValidationHost = true"))
        XCTAssertTrue(applicationRoot.contains("EmptyView()"))
        XCTAssertTrue(applicationRoot.contains("#else\n    @StateObject"))
    }

    func testPhysicalIPhoneXRDetailsHelperRequiresSeparatedExactIdentityTuple() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-device-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        enum FixtureMutation {
            case coreDeviceIdentifier
            case hardwareUDID
            case marketingName
            case productType
            case hardwareModel
            case platform
            case reality
            case osVersion
            case osBuild
            case bootState
            case pairingState
            case swappedIdentities
            case missingRequiredField
        }

        func fixture(mutation: FixtureMutation? = nil) throws -> URL {
            var resultIdentifier = SyntheticPhysicalDevice.coreDeviceIdentifier
            var hardwareProperties: [String: Any] = [
                "udid": SyntheticPhysicalDevice.hardwareUDID,
                "marketingName": "iPhone XR",
                "productType": "iPhone11,8",
                "hardwareModel": "N841AP",
                "platform": "iOS",
                "reality": "physical",
            ]
            // Intentionally omit deviceProperties.name: it is not part of the public identity tuple.
            var deviceProperties: [String: Any] = [
                "osVersionNumber": "18.7.9",
                "osBuildUpdate": "22H355",
                "bootState": "booted",
            ]
            var connectionProperties: [String: Any] = [
                "pairingState": "paired",
            ]

            switch mutation {
            case .coreDeviceIdentifier?:
                resultIdentifier = "mutated-coredevice-selector"
            case .hardwareUDID?:
                hardwareProperties["udid"] = "mutated-hardware-udid"
            case .marketingName?:
                hardwareProperties["marketingName"] = "Synthetic Phone"
            case .productType?:
                hardwareProperties["productType"] = "SyntheticProduct,0"
            case .hardwareModel?:
                hardwareProperties["hardwareModel"] = "SyntheticHardwareModel"
            case .platform?:
                hardwareProperties["platform"] = "SyntheticPlatform"
            case .reality?:
                hardwareProperties["reality"] = "virtual"
            case .osVersion?:
                deviceProperties["osVersionNumber"] = "0.0.0-synthetic"
            case .osBuild?:
                deviceProperties["osBuildUpdate"] = "SYNTHETIC-BUILD"
            case .bootState?:
                deviceProperties["bootState"] = "shutdown"
            case .pairingState?:
                connectionProperties["pairingState"] = "unpaired"
            case .swappedIdentities?:
                resultIdentifier = SyntheticPhysicalDevice.hardwareUDID
                hardwareProperties["udid"] = SyntheticPhysicalDevice.coreDeviceIdentifier
            case .missingRequiredField?:
                deviceProperties.removeValue(forKey: "osBuildUpdate")
            case nil:
                break
            }

            let object: [String: Any] = [
                "info": [
                    "outcome": "success",
                ],
                "result": [
                    "identifier": resultIdentifier,
                    "hardwareProperties": hardwareProperties,
                    "deviceProperties": deviceProperties,
                    "connectionProperties": connectionProperties,
                ] as [String: Any],
            ]
            let url = root.appendingPathComponent(
                "devicectl-details-\(UUID().uuidString).json"
            )
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: url)
            return url
        }

        func assertRejected(_ mutation: FixtureMutation, _ message: String) throws {
            let result = try runPhysicalValidationHelperProbe(
                "opensteamer_require_physical_iphone_xr_details \"$1\" \"$2\" \"$3\"",
                arguments: [
                    try fixture(mutation: mutation).path,
                    SyntheticPhysicalDevice.coreDeviceIdentifier,
                    SyntheticPhysicalDevice.hardwareUDID,
                ]
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, message)
        }

        let valid = try runPhysicalValidationHelperProbe(
            "opensteamer_require_physical_iphone_xr_details \"$1\" \"$2\" \"$3\"",
            arguments: [
                try fixture().path,
                SyntheticPhysicalDevice.coreDeviceIdentifier,
                SyntheticPhysicalDevice.hardwareUDID,
            ]
        )
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)

        let rejectedMutations: [(FixtureMutation, String)] = [
            (
                .coreDeviceIdentifier,
                "A mismatched CoreDevice identifier was accepted."
            ),
            (
                .hardwareUDID,
                "A mismatched hardware UDID was accepted."
            ),
            (.marketingName, "A mismatched marketing name was accepted."),
            (.productType, "A mismatched product type was accepted."),
            (.hardwareModel, "A mismatched hardware model was accepted."),
            (.platform, "A mismatched platform was accepted."),
            (.reality, "A non-physical device was accepted."),
            (.osVersion, "A mismatched OS version was accepted."),
            (.osBuild, "A mismatched OS build was accepted."),
            (.bootState, "A non-booted device was accepted."),
            (.pairingState, "A non-paired device was accepted."),
            (
                .swappedIdentities,
                "Swapped CoreDevice and hardware identities were accepted."
            ),
            (
                .missingRequiredField,
                "A missing required device-details field was accepted."
            ),
        ]
        for (mutation, message) in rejectedMutations {
            try assertRejected(mutation, message)
        }
    }

    func testDefaultInputLifecycleValidatorAcceptsPreselectedOrSwitchedAndRejectsMutations()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opensteamer-default-input-lifecycle-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        enum Mutation {
            case delayedUntilAudio
            case noRestore
            case wrongRestore
            case outputChanged
            case systemOutputChanged
            case hiddenDefaultInput
            case forbiddenDefaultOutput
            case forbiddenSystemOutput
        }

        let prior = String(repeating: "a", count: 64)
        let blackHole = String(repeating: "b", count: 64)
        let output = String(repeating: "c", count: 64)
        let systemOutput = String(repeating: "d", count: 64)
        let probeStart = 3_000

        func write(
            role: String,
            time: Int,
            input: String,
            isBlackHole: Bool,
            inputTransportClass: String? = nil,
            outputFingerprint: String = output,
            systemFingerprint: String = systemOutput,
            inputIsHiddenMirrorBlackHole: Bool = false,
            defaultOutputIsForbiddenBlackHole: Bool = false,
            defaultSystemOutputIsForbiddenBlackHole: Bool = false
        ) throws -> URL {
            let url = root.appendingPathComponent(
                "\(role)-\(UUID().uuidString).json"
            )
            try JSONSerialization.data(
                withJSONObject: [
                    "schema":
                        "opensteamer.default-input-snapshot.v3",
                    "role": role,
                    "observedAtMonotonicNs": time,
                    "inputUIDFingerprint": input,
                    "outputUIDFingerprint":
                        outputFingerprint,
                    "systemOutputUIDFingerprint":
                        systemFingerprint,
                    "inputIsCanonicalBlackHole":
                        isBlackHole,
                    "inputIsHiddenMirrorBlackHole":
                        inputIsHiddenMirrorBlackHole,
                    "defaultOutputIsForbiddenBlackHole":
                        defaultOutputIsForbiddenBlackHole,
                    "defaultSystemOutputIsForbiddenBlackHole":
                        defaultSystemOutputIsForbiddenBlackHole,
                    "inputTransportClass":
                        inputTransportClass
                            ?? (isBlackHole ? "virtual" : "built-in"),
                ],
                options: [.sortedKeys]
            ).write(to: url)
            return url
        }

        func fixtures(
            mutation: Mutation? = nil,
            preselected: Bool = false
        ) throws -> (URL, URL, URL) {
            let before = try write(
                role: "before",
                time: 1_000,
                input: preselected ? blackHole : prior,
                isBlackHole: preselected,
                inputTransportClass:
                    mutation == .hiddenDefaultInput
                        ? "virtual"
                        : nil,
                inputIsHiddenMirrorBlackHole:
                    mutation == .hiddenDefaultInput,
                defaultOutputIsForbiddenBlackHole:
                    mutation == .forbiddenDefaultOutput,
                defaultSystemOutputIsForbiddenBlackHole:
                    mutation == .forbiddenSystemOutput
            )
            let healthy = try write(
                role: "healthy",
                time: mutation == .delayedUntilAudio
                    ? 3_100
                    : 2_000,
                input: blackHole,
                isBlackHole: true,
                outputFingerprint:
                    mutation == .outputChanged
                        ? String(repeating: "e", count: 64)
                        : output,
                systemFingerprint:
                    mutation == .systemOutputChanged
                        ? String(repeating: "f", count: 64)
                        : systemOutput,
                defaultOutputIsForbiddenBlackHole:
                    mutation == .forbiddenDefaultOutput,
                defaultSystemOutputIsForbiddenBlackHole:
                    mutation == .forbiddenSystemOutput
            )
            let after = try write(
                role: "after",
                time: 4_000,
                input: mutation == .noRestore
                    ? blackHole
                    : mutation == .wrongRestore
                        ? String(repeating: "9", count: 64)
                        : preselected ? blackHole : prior,
                isBlackHole:
                    mutation == .noRestore || preselected,
                inputTransportClass:
                    mutation == .hiddenDefaultInput
                        ? "virtual"
                        : nil,
                inputIsHiddenMirrorBlackHole:
                    mutation == .hiddenDefaultInput,
                defaultOutputIsForbiddenBlackHole:
                    mutation == .forbiddenDefaultOutput,
                defaultSystemOutputIsForbiddenBlackHole:
                    mutation == .forbiddenSystemOutput
            )
            return (before, healthy, after)
        }

        func run(
            mutation: Mutation? = nil,
            preselected: Bool = false
        ) throws -> ZshProbeResult {
            let fixture = try fixtures(
                mutation: mutation,
                preselected: preselected
            )
            return try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: "validate-default-input-lifecycle",
                artifactDirectory: root.appendingPathComponent(
                    "artifact-\(UUID().uuidString)"
                ),
                timeout: 5,
                additionalEnvironment: [
                    "OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_BEFORE":
                        fixture.0.path,
                    "OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_HEALTHY":
                        fixture.1.path,
                    "OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_AFTER":
                        fixture.2.path,
                    "OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_PROBE_START":
                        String(probeStart),
                ]
            )
        }

        let valid = try run()
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(
            valid.terminationStatus,
            0,
            valid.diagnostic
        )
        let preselected = try run(preselected: true)
        XCTAssertTrue(
            preselected.exitedWithinDeadline,
            preselected.diagnostic
        )
        XCTAssertEqual(
            preselected.terminationStatus,
            0,
            preselected.diagnostic
        )

        for mutation in [
            Mutation.delayedUntilAudio,
            .noRestore,
            .wrongRestore,
            .outputChanged,
            .systemOutputChanged,
            .hiddenDefaultInput,
            .forbiddenDefaultOutput,
            .forbiddenSystemOutput,
        ] {
            let rejected = try run(mutation: mutation)
            XCTAssertTrue(
                rejected.exitedWithinDeadline,
                rejected.diagnostic
            )
            XCTAssertNotEqual(
                rejected.terminationStatus,
                0,
                "Validator accepted \(mutation)"
            )
        }
    }

    func testReconnectDriverRequiresFiveArgumentProductionCLI() throws {
        let script = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh"
        )
        for arguments in [
            [
                SyntheticPhysicalDevice.coreDeviceIdentifier,
                SyntheticPhysicalDevice.hardwareUDID,
                SyntheticPhysicalDevice.expectedBuild,
            ],
            [
                SyntheticPhysicalDevice.coreDeviceIdentifier,
                SyntheticPhysicalDevice.hardwareUDID,
                SyntheticPhysicalDevice.expectedBuild,
                "",
            ],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path] + arguments
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            let exitedWithinDeadline = waitForExit(process, timeout: 5)
            if !exitedWithinDeadline {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(exitedWithinDeadline)
            guard !process.isRunning else {
                XCTFail("The reconnect driver survived invalid CLI cleanup.")
                continue
            }
            let diagnostic = String(
                decoding: readAvailableData(from: standardError),
                as: UTF8.self
            )
            XCTAssertEqual(process.terminationStatus, 2, diagnostic)
            XCTAssertTrue(
                diagnostic.contains(
                    "expected-production-build physical-output-uid [artifact-directory]"
                ),
                diagnostic
            )
        }
    }

    func testReconnectDriverWritesHostStatusInRealZshProcess() throws {
        let script = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-script-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let staleEvidence = [
            "summary.json",
            "device-locked-during-test.txt",
            "production-build-self-test-build-paired-reconnect.xcresult/stale.txt",
            "DerivedData/stale.txt",
            "DerivedData/Build/Intermediates.noindex/XCBuildData/build.db",
            "host-restart-status.txt",
            "host-restart-events.log",
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
        process.arguments = [
            script.path,
            SyntheticPhysicalDevice.coreDeviceIdentifier,
            SyntheticPhysicalDevice.hardwareUDID,
            SyntheticPhysicalDevice.expectedBuild,
            SyntheticPhysicalDevice.physicalOutputUID,
            artifactDirectory.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SCRIPT_SELF_TEST"] = "write-host-status"
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

        let statusURL = artifactDirectory.appendingPathComponent(
            "\(reconnectPhaseDirectoryName)/host-restart-status.txt"
        )
        let status = try String(contentsOf: statusURL, encoding: .utf8)
        XCTAssertEqual(
            status,
            "status=pending\nconnections=2\nproofs=0\nbound_proofs=0\n" +
                "restarts=1\ndetail=runtime self-test\n"
        )
        for relativePath in staleEvidence {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: artifactDirectory.appendingPathComponent(relativePath).path
                )
            ,
                "The driver reused stale evidence at \(relativePath)."
            )
        }
        let runStatus = try String(
            contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(runStatus, "status=self-test-passed\n")
    }

    private var reconnectPhaseDirectoryName: String {
        "phase-2-reconnect"
    }

    func testReconnectDriverRequiresEveryCriticalPhysicalActivityArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-activity-oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Each mutation invalidates one evidence property while leaving the rest of the synthetic
        // xcresult graph coherent. This proves the validator rejects the intended fault rather
        // than failing incidentally on an unrelated malformed fixture.
        enum FixtureMutation {
            case replacing(String)
            case relocatingAttachment(String)
            case emptyPayload(String)
            case missingPayload(String)
            case malformedPayload(String)
            case malformedUUID(String)
            case zeroTimestamp(String)
            case wrongLifetime(String)
            case swappingAttachments(String, String)
            case relocatingNestedActivity(String)
            case failedActivity(String)
            case zeroActivityStart(String)
            case duplicateTestRun
        }
        typealias AttachmentMapping = (parent: String, name: String)

        // These strings are the exact activity/attachment names emitted by the physical UI test;
        // they form a versioned protocol between the XCTest bundle and the validation script.
        let requiredStrings = [
            "Same-process host restart and reconnect 1",
            "Same-process host restart and reconnect 2",
            "Same-process host restart and reconnect 3",
            "Explicit disconnect and same-process reconnect",
            "Cold-launch saved-pair reconnect",
            "Physical background audio continuity oracle",
            "Physical screen Show-Hide and same-session audio oracle",
            "WebRTC route - host restart reconnect 1",
            "WebRTC route - host restart reconnect 2",
            "WebRTC route - host restart reconnect 3",
            "Raw iPhone microphone continuity - host restart reconnect 1",
            "Raw iPhone microphone continuity - host restart reconnect 2",
            "Raw iPhone microphone continuity - host restart reconnect 3",
            "test iPhone Direct route before host restart 1",
            "test iPhone Direct route before host restart 2",
            "test iPhone Direct route before host restart 3",
            "test iPhone recovered in same process 1",
            "test iPhone recovered in same process 2",
            "test iPhone recovered in same process 3",
            "WebRTC route - before explicit disconnect",
            "Raw iPhone microphone continuity - before explicit disconnect",
            "WebRTC route - same-process reconnect after explicit disconnect",
            "Raw iPhone microphone continuity - same-process reconnect after explicit disconnect",
            "WebRTC route - cold-launch saved-pair reconnect",
            "Raw iPhone microphone continuity - cold-launch saved-pair reconnect",
            "Background native audio continuity evidence",
            "WebRTC route - after background audio proof",
            "test iPhone live Mac screen with authenticated input capability",
            "Decoded screen pixel freshness evidence",
            "Authenticated screen Show-Hide evidence",
            "Same-session audio continuity across screen Show-Hide",
            "WebRTC route - after hiding the cold-launch Mac screen",
        ]
        let criticalAttachmentMappings: [AttachmentMapping] = [
            ("restart-1", "WebRTC route - host restart reconnect 1"),
            (
                "restart-1",
                "Raw iPhone microphone continuity - host restart reconnect 1"
            ),
            ("restart-1", "test iPhone Direct route before host restart 1"),
            ("restart-1", "test iPhone recovered in same process 1"),
            ("restart-2", "WebRTC route - host restart reconnect 2"),
            (
                "restart-2",
                "Raw iPhone microphone continuity - host restart reconnect 2"
            ),
            ("restart-2", "test iPhone Direct route before host restart 2"),
            ("restart-2", "test iPhone recovered in same process 2"),
            ("restart-3", "WebRTC route - host restart reconnect 3"),
            (
                "restart-3",
                "Raw iPhone microphone continuity - host restart reconnect 3"
            ),
            ("restart-3", "test iPhone Direct route before host restart 3"),
            ("restart-3", "test iPhone recovered in same process 3"),
            ("explicit", "WebRTC route - before explicit disconnect"),
            (
                "explicit",
                "Raw iPhone microphone continuity - before explicit disconnect"
            ),
            (
                "explicit",
                "WebRTC route - same-process reconnect after explicit disconnect"
            ),
            (
                "explicit",
                "Raw iPhone microphone continuity - same-process reconnect after explicit disconnect"
            ),
            ("cold", "WebRTC route - cold-launch saved-pair reconnect"),
            (
                "cold",
                "Raw iPhone microphone continuity - cold-launch saved-pair reconnect"
            ),
            ("cold", "WebRTC route - after background audio proof"),
            ("cold", "WebRTC route - after hiding the cold-launch Mac screen"),
            ("background", "Background native audio continuity evidence"),
            (
                "screen",
                "test iPhone live Mac screen with authenticated input capability"
            ),
            ("screen", "Decoded screen pixel freshness evidence"),
            ("screen", "Authenticated screen Show-Hide evidence"),
            ("screen", "Same-session audio continuity across screen Show-Hide"),
        ]
        func fixture(
            mutation: FixtureMutation? = nil,
            useTURNRelay: Bool = false
        ) throws -> URL {
            func value(_ string: String) -> String {
                if case let .replacing(removed)? = mutation, string == removed {
                    return "mutated-away"
                }
                if useTURNRelay {
                    return string.replacingOccurrences(
                        of: "test iPhone Direct route before host restart",
                        with: "test iPhone TURN relay route before host restart"
                    )
                }
                return string
            }
            func effectiveParent(for mapping: AttachmentMapping) -> String {
                switch mutation {
                case let .relocatingAttachment(name)? where mapping.name == name:
                    return mapping.parent == "explicit" ? "restart-1" : "explicit"
                case let .swappingAttachments(first, second)? where mapping.name == first:
                    return criticalAttachmentMappings.first { $0.name == second }!.parent
                case let .swappingAttachments(first, second)? where mapping.name == second:
                    return criticalAttachmentMappings.first { $0.name == first }!.parent
                default:
                    return mapping.parent
                }
            }
            func attachment(for mapping: AttachmentMapping, index: Int) -> [String: Any] {
                var attachment: [String: Any] = [
                    "name": value(mapping.name),
                    "payloadId": "0~FixturePayload_\(index)_abcdefghijklmnop",
                    "uuid": String(
                        format: "00000000-0000-4000-8000-%012d",
                        index + 1
                    ),
                    "timestamp": 1_784_000_000.0 + Double(index),
                    "lifetime": "keepAlways",
                ]
                switch mutation {
                case let .emptyPayload(name)? where mapping.name == name:
                    attachment["payloadId"] = ""
                case let .missingPayload(name)? where mapping.name == name:
                    attachment.removeValue(forKey: "payloadId")
                case let .malformedPayload(name)? where mapping.name == name:
                    attachment["payloadId"] = "not a valid xcresult payload id"
                case let .malformedUUID(name)? where mapping.name == name:
                    attachment["uuid"] = "not-a-uuid"
                case let .zeroTimestamp(name)? where mapping.name == name:
                    attachment["timestamp"] = 0
                case let .wrongLifetime(name)? where mapping.name == name:
                    attachment["lifetime"] = "deleteOnSuccess"
                default:
                    break
                }
                return attachment
            }
            func attachments(for parent: String) -> [[String: Any]] {
                criticalAttachmentMappings.enumerated().compactMap { index, mapping in
                    guard effectiveParent(for: mapping) == parent else { return nil }
                    return attachment(for: mapping, index: index)
                }
            }
            func activity(
                id: String,
                title: String,
                childActivities: [[String: Any]] = []
            ) -> [String: Any] {
                var result: [String: Any] = [
                    "title": value(title),
                    "startTime": 1_784_000_100.0,
                    "isAssociatedWithFailure": false,
                    "attachments": attachments(for: id),
                ]
                if !childActivities.isEmpty {
                    result["childActivities"] = childActivities
                }
                if case let .failedActivity(target)? = mutation, target == id {
                    result["isAssociatedWithFailure"] = true
                }
                if case let .zeroActivityStart(target)? = mutation, target == id {
                    result["startTime"] = 0
                }
                return result
            }
            let background = activity(
                id: "background",
                title: "Physical background audio continuity oracle"
            )
            let screen = activity(
                id: "screen",
                title: "Physical screen Show-Hide and same-session audio oracle"
            )
            var coldChildren = [background, screen]
            var relocatedChildren: [[String: Any]] = []
            if case let .relocatingNestedActivity(id)? = mutation {
                if id == "background" {
                    coldChildren.removeFirst()
                    relocatedChildren.append(background)
                } else if id == "screen" {
                    coldChildren.removeLast()
                    relocatedChildren.append(screen)
                }
            }
            var rootActivities = [
                activity(
                    id: "restart-1",
                    title: "Same-process host restart and reconnect 1"
                ),
                activity(
                    id: "restart-2",
                    title: "Same-process host restart and reconnect 2"
                ),
                activity(
                    id: "restart-3",
                    title: "Same-process host restart and reconnect 3"
                ),
                activity(
                    id: "explicit",
                    title: "Explicit disconnect and same-process reconnect"
                ),
                activity(
                    id: "cold",
                    title: "Cold-launch saved-pair reconnect",
                    childActivities: coldChildren
                ),
            ]
            rootActivities.append(contentsOf: relocatedChildren)
            let testRun: [String: Any] = [
                "activities": rootActivities,
                "device": [
                    "deviceId": "self-test-device",
                    "deviceName": "test iPhone",
                    "architecture": "arm64",
                    "modelName": "test iPhone",
                    "platform": "iOS",
                    "osVersion": "18.x",
                ],
                "testPlanConfiguration": [
                    "configurationId": "1",
                    "configurationName": "Test Scheme Action",
                ],
            ]
            var testRuns: [[String: Any]] = [testRun]
            if case .duplicateTestRun? = mutation {
                testRuns.append(testRun)
            }
            let object: [String: Any] = [
                "testIdentifier":
                    "PairedReconnectPhysicalUITests/" +
                    "testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing()",
                "testIdentifierURL":
                    "test://com.apple.xcode/opensteamer/opensteamerUITests/" +
                    "PairedReconnectPhysicalUITests/" +
                    "testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing",
                "testName":
                    "testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing()",
                "testRuns": testRuns,
            ]
            let url = root.appendingPathComponent("fixture-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return url
        }

        func assertRejected(_ mutation: FixtureMutation, _ message: String) throws {
            let mutantArtifact = root.appendingPathComponent("mutant-\(UUID().uuidString)")
            let mutant = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: "validate-physical-activities",
                artifactDirectory: mutantArtifact,
                timeout: 5,
                additionalEnvironment: [
                    "OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON":
                        try fixture(mutation: mutation).path,
                ]
            )
            XCTAssertTrue(mutant.exitedWithinDeadline, mutant.diagnostic)
            XCTAssertNotEqual(mutant.terminationStatus, 0, message)
        }

        let validArtifact = root.appendingPathComponent("valid-run")
        let valid = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "validate-physical-activities",
            artifactDirectory: validArtifact,
            timeout: 5,
            additionalEnvironment: [
                "OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON": try fixture().path,
            ]
        )
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)

        let turnArtifact = root.appendingPathComponent("valid-turn-run")
        let turn = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "validate-physical-activities",
            artifactDirectory: turnArtifact,
            timeout: 5,
            additionalEnvironment: [
                "OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON":
                    try fixture(useTURNRelay: true).path,
            ]
        )
        XCTAssertTrue(turn.exitedWithinDeadline, turn.diagnostic)
        XCTAssertEqual(turn.terminationStatus, 0, turn.diagnostic)

        for required in requiredStrings {
            try assertRejected(
                .replacing(required),
                "Missing required activity evidence escaped: \(required)"
            )
        }
        for mapping in criticalAttachmentMappings {
            try assertRejected(
                .relocatingAttachment(mapping.name),
                "Relocated evidence escaped its exact XCTActivity: \(mapping.name)"
            )
            try assertRejected(
                .emptyPayload(mapping.name),
                "Empty xcresult payload metadata escaped: \(mapping.name)"
            )
        }
        try assertRejected(
            .swappingAttachments(
                "WebRTC route - host restart reconnect 1",
                "WebRTC route - before explicit disconnect"
            ),
            "Swapped evidence names escaped their exact XCTActivity parents"
        )
        try assertRejected(
            .relocatingNestedActivity("background"),
            "The background oracle escaped after relocation outside the cold-launch activity"
        )
        try assertRejected(
            .relocatingNestedActivity("screen"),
            "The screen oracle escaped after relocation outside the cold-launch activity"
        )
        let metadataSubject = criticalAttachmentMappings[0].name
        try assertRejected(
            .missingPayload(metadataSubject),
            "Missing xcresult payload identity escaped"
        )
        try assertRejected(
            .malformedPayload(metadataSubject),
            "Malformed xcresult payload identity escaped"
        )
        try assertRejected(
            .malformedUUID(metadataSubject),
            "Malformed attachment UUID escaped"
        )
        try assertRejected(
            .zeroTimestamp(metadataSubject),
            "Non-positive attachment timestamp escaped"
        )
        try assertRejected(
            .wrongLifetime(metadataSubject),
            "Non-retained critical attachment escaped"
        )
        try assertRejected(
            .failedActivity("restart-1"),
            "Failure-associated critical activity escaped"
        )
        try assertRejected(
            .zeroActivityStart("restart-1"),
            "Untimestamped critical activity escaped"
        )
        try assertRejected(
            .duplicateTestRun,
            "A second test run made the physical activity evidence ambiguous"
        )
    }

    func testRawAndCallActivityValidatorsRequireUniqueRecursiveAttachments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-direct-activity-oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        enum Mutation {
            case missingFirst
            case missingLast
            case duplicateFirst
            case duplicateLast
            case wrongLifetime
            case wrongName
            case wrongPayload
            case topLevelOnly
            case wrongURL
            case duplicateRun
        }

        let rawURL =
            "test://com.apple.xcode/opensteamer/opensteamerUITests/" +
            "PairedReconnectPhysicalUITests/" +
            "testProductionRawIPhoneMicrophoneOracleSustainsRollingContinuity"
        let callURL =
            "test://com.apple.xcode/opensteamer/opensteamerUITests/" +
            "PairedReconnectPhysicalUITests/" +
            "testRealConnectedCallRecoveryRotatesOrdinaryAudioPolicyAndRequiresFreshProof"
        let rawNames = [
            "Production raw iPhone microphone rolling continuity evidence",
            "Production raw iPhone microphone runtime overlap evidence",
        ]
        let callNames = [
            "Startup connected-call incoming Mac playout continuity evidence",
            "Interruption-origin incoming Mac playout continuity evidence",
            "Fresh ordinary audio proof after final call recovery",
            "Post-call raw iPhone microphone rolling continuity evidence",
            "Post-call raw iPhone microphone runtime overlap evidence",
            "Post-call raw microphone generation evidence",
        ]

        func fixture(
            url: String,
            names: [String],
            mutation: Mutation? = nil
        ) throws -> URL {
            func attachment(_ name: String, index: Int) -> [String: Any] {
                [
                    "name": name,
                    "payloadId":
                        mutation == .wrongPayload && index == names.count - 1
                            ? "invalid-payload"
                            : "0~DirectAttachmentPayload_\(index)_abcdefghijklmnop",
                    "uuid": String(
                        format: "10000000-0000-4000-8000-%012d",
                        index + 1
                    ),
                    "timestamp": 1_784_100_000.0 + Double(index),
                    "lifetime":
                        mutation == .wrongLifetime && index == 0
                            ? "deleteOnSuccess"
                            : "keepAlways",
                ]
            }

            var attachments = names.enumerated().map { entry in
                attachment(entry.element, index: entry.offset)
            }
            if mutation == .missingFirst {
                attachments.removeFirst()
            } else if mutation == .missingLast {
                attachments.removeLast()
            } else if mutation == .duplicateFirst, let first = attachments.first {
                attachments.append(first)
            } else if mutation == .duplicateLast, let last = attachments.last {
                attachments.append(last)
            } else if mutation == .wrongName, !attachments.isEmpty {
                var last = attachments.removeLast()
                last["name"] = "\(names.last ?? "missing")-wrong"
                attachments.append(last)
            }
            let nestedActivity: [String: Any] = [
                "title": "Nested framework activity",
                "startTime": 1_784_100_100.0,
                "isAssociatedWithFailure": false,
                "attachments": mutation == .topLevelOnly ? [] : attachments,
            ]
            let rootActivity: [String: Any] = [
                "title": "Framework root activity",
                "startTime": 1_784_100_090.0,
                "isAssociatedWithFailure": false,
                "attachments": [],
                "childActivities": [nestedActivity],
            ]
            let testRun: [String: Any] = [
                "activities": [rootActivity],
            ]
            var testRuns = [testRun]
            if mutation == .duplicateRun {
                testRuns.append(testRun)
            }
            var object: [String: Any] = [
                "testIdentifierURL":
                    mutation == .wrongURL ? "\(url)-wrong" : url,
                "testRuns": testRuns,
            ]
            if mutation == .topLevelOnly {
                object["attachments"] = attachments
            }
            let output = root.appendingPathComponent(
                "direct-activities-\(UUID().uuidString).json"
            )
            try JSONSerialization.data(withJSONObject: object).write(to: output)
            return output
        }

        func run(
            mode: String,
            url: String,
            names: [String],
            mutation: Mutation? = nil
        ) throws -> ZshProbeResult {
            try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: root.appendingPathComponent(
                    "artifact-\(UUID().uuidString)"
                ),
                timeout: 5,
                additionalEnvironment: [
                    "OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON":
                        try fixture(url: url, names: names, mutation: mutation).path,
                ]
            )
        }

        for (mode, url, names) in [
            ("validate-raw-activities", rawURL, rawNames),
            ("validate-call-activities", callURL, callNames),
        ] {
            let valid = try run(mode: mode, url: url, names: names)
            XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
            XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)
            for mutation in [
                Mutation.missingFirst,
                .missingLast,
                .duplicateFirst,
                .duplicateLast,
                .wrongLifetime,
                .wrongName,
                .wrongPayload,
                .topLevelOnly,
                .wrongURL,
                .duplicateRun,
            ] {
                let rejected = try run(
                    mode: mode,
                    url: url,
                    names: names,
                    mutation: mutation
                )
                XCTAssertTrue(rejected.exitedWithinDeadline, rejected.diagnostic)
                XCTAssertNotEqual(
                    rejected.terminationStatus,
                    0,
                    "\(mode) accepted \(mutation)"
                )
            }
        }
    }

    func testBlackHoleProbeValidatorRequiresExactSchemaAndInvariants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-blackhole-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nonce = "blackhole-json-self-test"

        func invalidProbeChannelMetric(
            channel: Int,
            key: String,
            value: Double
        ) -> (inout [String: Any]) -> Void {
            { object in
                var channels = object["channels"] as! [[String: Any]]
                let targetIndex = channels.firstIndex {
                    ($0["channel"] as? Int) == channel
                }!
                channels[targetIndex][key] = value
                object["channels"] = channels
            }
        }

        func validate(
            _ object: [String: Any],
            expectedNonce: String = nonce,
            outputUID: String = SyntheticPhysicalDevice.physicalOutputUID
        ) throws -> ZshProbeResult {
            let fixture = root.appendingPathComponent(
                "probe-result-\(UUID().uuidString).json"
            )
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: fixture)
            let driver = physicalDrivers[2]
            let overriddenDriver: PhysicalDriver = (
                driver.relativePath,
                { artifactDirectory in
                    [
                        SyntheticPhysicalDevice.coreDeviceIdentifier,
                        SyntheticPhysicalDevice.hardwareUDID,
                        SyntheticPhysicalDevice.expectedBuild,
                        outputUID,
                        artifactDirectory.path,
                    ]
                }
            )
            return try runPhysicalDriverSelfTest(
                overriddenDriver,
                mode: "validate-blackhole-probe-json",
                artifactDirectory: root.appendingPathComponent(
                    "artifact-\(UUID().uuidString)"
                ),
                timeout: 5,
                additionalEnvironment: [
                    "OPENSTEAMER_SELF_TEST_PROBE_JSON": fixture.path,
                    "OPENSTEAMER_SELF_TEST_PROBE_NONCE": expectedNonce,
                ]
            )
        }

        let valid = try validate(passingBlackHoleProbeJSON(nonce: nonce))
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)

        func assertRejected(
            _ object: [String: Any],
            _ name: String,
            expectedNonce: String = nonce,
            outputUID: String = SyntheticPhysicalDevice.physicalOutputUID
        ) throws {
            let result = try validate(
                object,
                expectedNonce: expectedNonce,
                outputUID: outputUID
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(
                result.terminationStatus,
                0,
                "Validator accepted mutation: \(name)"
            )
        }

        let passing = passingBlackHoleProbeJSON(nonce: nonce)
        for key in passing.keys.sorted() {
            var mutant = passing
            mutant.removeValue(forKey: key)
            try assertRejected(mutant, "missing root key \(key)")
        }

        let formatKeys = (passing["format"] as! [String: Any]).keys.sorted()
        for key in formatKeys {
            var mutant = passing
            var format = mutant["format"] as! [String: Any]
            format.removeValue(forKey: key)
            mutant["format"] = format
            try assertRejected(mutant, "missing format key \(key)")
        }

        let progressKeys = (
            (passing["progressSnapshots"] as! [[String: Any]])[0]
        ).keys.sorted()
        for key in progressKeys {
            var mutant = passing
            var progress = mutant["progressSnapshots"] as! [[String: Any]]
            progress[0].removeValue(forKey: key)
            mutant["progressSnapshots"] = progress
            try assertRejected(mutant, "missing progress key \(key)")
        }

        let channelKeys = (
            (passing["channels"] as! [[String: Any]])[0]
        ).keys.sorted()
        for key in channelKeys {
            var mutant = passing
            var channels = mutant["channels"] as! [[String: Any]]
            channels[0].removeValue(forKey: key)
            mutant["channels"] = channels
            try assertRejected(mutant, "missing channel key \(key)")
        }

        func mutateFormat(
            _ object: inout [String: Any],
            _ body: (inout [String: Any]) -> Void
        ) {
            var format = object["format"] as! [String: Any]
            body(&format)
            object["format"] = format
        }

        func mutateProgress(
            _ object: inout [String: Any],
            index: Int = 0,
            _ body: (inout [String: Any]) -> Void
        ) {
            var progress = object["progressSnapshots"] as! [[String: Any]]
            body(&progress[index])
            object["progressSnapshots"] = progress
        }

        func mutateChannel(
            _ object: inout [String: Any],
            index: Int = 0,
            _ body: (inout [String: Any]) -> Void
        ) {
            var channels = object["channels"] as! [[String: Any]]
            body(&channels[index])
            object["channels"] = channels
        }

        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            (
                "missing root key",
                { $0.removeValue(forKey: "schema") }
            ),
            (
                "extra root key",
                { $0["unexpected"] = true }
            ),
            (
                "wrong schema",
                { $0["schema"] = "opensteamer.physical-blackhole-microphone.v1" }
            ),
            (
                "wrong status",
                { $0["status"] = "failed" }
            ),
            (
                "nonce mismatch",
                { $0["runNonce"] = "different-nonce" }
            ),
            (
                "challenge algorithm",
                { $0["challengeAlgorithm"] = "different-algorithm" }
            ),
            (
                "challenge version",
                { $0["challengeVersion"] = 2 }
            ),
            (
                "canonical capture UID",
                { $0["canonicalCaptureUID"] = "DifferentCaptureUID" }
            ),
            (
                "route mismatch",
                { $0["captureUIDMatches"] = false }
            ),
            (
                "physical output not validated",
                { $0["physicalOutputValidated"] = false }
            ),
            (
                "challenge nonce flag",
                { $0["challengeNonceMatches"] = false }
            ),
            (
                "queue aggregate mismatch",
                { $0["queueReadbackMatches"] = false }
            ),
            (
                "capture queue mismatch",
                { $0["captureQueueReadbackMatches"] = false }
            ),
            (
                "physical output queue mismatch",
                { $0["physicalOutputQueueReadbackMatches"] = false }
            ),
            (
                "queue aggregate inconsistent",
                {
                    $0["queueReadbackMatches"] = true
                    $0["captureQueueReadbackMatches"] = false
                }
            ),
            (
                "proof duration",
                { $0["proofWindowSeconds"] = 5.9 }
            ),
            (
                "capture duration non-positive",
                { $0["captureSeconds"] = 0 }
            ),
            (
                "capture duration count mismatch",
                { $0["captureSeconds"] = 5.99 }
            ),
            (
                "callback count non-positive",
                { $0["callbackCount"] = 0 }
            ),
            (
                "captured frame count non-positive",
                { $0["capturedFrameCount"] = 0 }
            ),
            (
                "total callback count non-positive",
                { $0["totalCallbackCount"] = 0 }
            ),
            (
                "total captured frame count non-positive",
                { $0["totalCapturedFrameCount"] = 0 }
            ),
            (
                "callback aggregate exceeds total",
                { $0["totalCallbackCount"] = 599 }
            ),
            (
                "frame aggregate exceeds total",
                { $0["totalCapturedFrameCount"] = 287_999 }
            ),
            (
                "density",
                { $0["frameDensity"] = 0.84 }
            ),
            (
                "density above range",
                { $0["frameDensity"] = 1.16 }
            ),
            (
                "callback gap",
                { $0["maxCallbackGapMs"] = 100.1 }
            ),
            (
                "negative callback gap",
                { $0["maxCallbackGapMs"] = -0.1 }
            ),
            (
                "silent gap",
                { $0["longestNonSilentGapMs"] = 500.1 }
            ),
            (
                "negative silent gap",
                { $0["longestNonSilentGapMs"] = -0.1 }
            ),
            (
                "non-silent ratio",
                { $0["nonSilentFrameRatio"] = 0.19 }
            ),
            (
                "non-silent ratio above one",
                { $0["nonSilentFrameRatio"] = 1.01 }
            ),
            (
                "aggregate clipping",
                { $0["aggregateClippedRatio"] = 0.005 }
            ),
            (
                "negative aggregate clipping",
                { $0["aggregateClippedRatio"] = -0.001 }
            ),
            (
                "aggregate nested clipping mismatch",
                { $0["aggregateClippedRatio"] = 0.001 }
            ),
            (
                "progress observation non-positive",
                { $0["progressObservationCount"] = 0 }
            ),
            (
                "insufficient progress",
                { $0["advancingProgressObservationCount"] = 1 }
            ),
            (
                "negative advancing progress",
                { $0["advancingProgressObservationCount"] = -1 }
            ),
            (
                "channel 0 rms below zero",
                invalidProbeChannelMetric(
                    channel: 0, key: "rms", value: -0.01
                )
            ),
            (
                "channel 0 rms above peak",
                invalidProbeChannelMetric(
                    channel: 0, key: "rms", value: 32_760.0
                )
            ),
            (
                "channel 0 normalized correlation below zero",
                invalidProbeChannelMetric(
                    channel: 0, key: "normalizedCorrelation", value: -0.01
                )
            ),
            (
                "channel 0 normalized correlation above one",
                invalidProbeChannelMetric(
                    channel: 0, key: "normalizedCorrelation", value: 1.01
                )
            ),
            (
                "channel 0 discrimination margin below minus one",
                invalidProbeChannelMetric(
                    channel: 0, key: "discriminationMargin", value: -1.01
                )
            ),
            (
                "channel 0 discrimination margin above one",
                invalidProbeChannelMetric(
                    channel: 0, key: "discriminationMargin", value: 1.01
                )
            ),
            (
                "channel 0 envelope correlation below minus one",
                invalidProbeChannelMetric(
                    channel: 0, key: "envelopeCorrelation", value: -1.01
                )
            ),
            (
                "channel 0 envelope correlation above one",
                invalidProbeChannelMetric(
                    channel: 0, key: "envelopeCorrelation", value: 1.01
                )
            ),
            (
                "progress snapshots too short",
                {
                    let progress = $0["progressSnapshots"] as! [[String: Any]]
                    $0["progressSnapshots"] = Array(progress.prefix(2))
                }
            ),
            (
                "insufficient symbols",
                { $0["symbolCount"] = 15 }
            ),
            (
                "matched symbols exceed aggregate",
                { $0["matchedSymbolCount"] = 21 }
            ),
            (
                "match threshold",
                { $0["matchRatio"] = 0.79 }
            ),
            (
                "aggregate match ratio inconsistency",
                { $0["matchRatio"] = 0.91 }
            ),
            (
                "correlation threshold",
                { $0["normalizedCorrelation"] = 0.59 }
            ),
            (
                "aggregate correlation mismatch",
                { $0["normalizedCorrelation"] = 0.81 }
            ),
            (
                "discrimination threshold",
                { $0["discriminationMargin"] = 0.09 }
            ),
            (
                "aggregate discrimination mismatch",
                { $0["discriminationMargin"] = 0.31 }
            ),
            (
                "aggregate envelope mismatch",
                { $0["envelopeCorrelation"] = 0.71 }
            ),
            (
                "lag below search range",
                { $0["detectedLagMs"] = 39.9 }
            ),
            (
                "lag above search range",
                { $0["detectedLagMs"] = 5_000.1 }
            ),
            (
                "default input changed",
                { $0["defaultInputBeforeAfterEqual"] = false }
            ),
            (
                "default output changed",
                { $0["defaultOutputBeforeAfterEqual"] = false }
            ),
            (
                "default system output changed",
                { $0["defaultSystemOutputBeforeAfterEqual"] = false }
            ),
            (
                "default notification",
                { $0["defaultChangeNotificationCount"] = 1 }
            ),
            (
                "negative default notification",
                { $0["defaultChangeNotificationCount"] = -1 }
            ),
            (
                "failure code",
                { $0["failureCode"] = "synthetic_failure" }
            ),
            (
                "failure reasons",
                { $0["failureReasons"] = ["synthetic_failure"] }
            ),
            (
                "progress aggregate count",
                { $0["progressObservationCount"] = 12 }
            ),
            (
                "format sample rate",
                {
                    mutateFormat(&$0) { format in
                        format["sampleRate"] = 44_100
                    }
                }
            ),
            (
                "format channels",
                {
                    mutateFormat(&$0) { format in
                        format["channels"] = 2
                    }
                }
            ),
            (
                "format signed integer",
                {
                    mutateFormat(&$0) { format in
                        format["signedInt16"] = false
                    }
                }
            ),
            (
                "format interleaving",
                {
                    mutateFormat(&$0) { format in
                        format["interleaved"] = false
                    }
                }
            ),
            (
                "format extra key",
                {
                    var format = $0["format"] as! [String: Any]
                    format["unexpected"] = true
                    $0["format"] = format
                }
            ),
            (
                "channel nested extra key",
                {
                    mutateChannel(&$0) { channel in
                        channel["unexpected"] = true
                    }
                }
            ),
            (
                "progress nested extra key",
                {
                    var progress = $0["progressSnapshots"] as! [[String: Any]]
                    progress[0]["unexpected"] = 1
                    $0["progressSnapshots"] = progress
                }
            ),
            (
                "channel nested missing key",
                {
                    var channels = $0["channels"] as! [[String: Any]]
                    channels[0].removeValue(forKey: "peak")
                    $0["channels"] = channels
                }
            ),
            (
                "first callback delta",
                {
                    mutateProgress(&$0) { progress in
                        progress["callbackDelta"] = 1
                    }
                }
            ),
            (
                "first frame delta",
                {
                    mutateProgress(&$0) { progress in
                        progress["frameDelta"] = 1
                    }
                }
            ),
            (
                "progress elapsed below zero",
                {
                    mutateProgress(&$0) { progress in
                        progress["elapsedSeconds"] = -0.1
                    }
                }
            ),
            (
                "progress elapsed above window",
                {
                    mutateProgress(&$0, index: 12) { progress in
                        progress["elapsedSeconds"] = 6.1
                    }
                }
            ),
            (
                "progress callback negative",
                {
                    mutateProgress(&$0) { progress in
                        progress["callbackCount"] = -1
                    }
                }
            ),
            (
                "progress frame negative",
                {
                    mutateProgress(&$0) { progress in
                        progress["capturedFrameCount"] = -1
                    }
                }
            ),
            (
                "progress callback delta mismatch",
                {
                    mutateProgress(&$0, index: 1) { progress in
                        progress["callbackDelta"] = 49
                    }
                }
            ),
            (
                "progress frame delta mismatch",
                {
                    mutateProgress(&$0, index: 1) { progress in
                        progress["frameDelta"] = 23_999
                    }
                }
            ),
            (
                "progress advancing mismatch",
                {
                    mutateProgress(&$0, index: 1) { progress in
                        progress["advancing"] = false
                    }
                }
            ),
            (
                "progress callback regression",
                {
                    mutateProgress(&$0, index: 2) { progress in
                        progress["callbackCount"] = 49
                    }
                }
            ),
            (
                "progress frame regression",
                {
                    mutateProgress(&$0, index: 2) { progress in
                        progress["capturedFrameCount"] = 23_999
                    }
                }
            ),
            (
                "progress last callback exceeds total",
                {
                    mutateProgress(&$0, index: 12) { progress in
                        progress["callbackCount"] = 601
                    }
                }
            ),
            (
                "progress last frame exceeds total",
                {
                    mutateProgress(&$0, index: 12) { progress in
                        progress["capturedFrameCount"] = 288_001
                    }
                }
            ),
            (
                "channel count",
                {
                    $0["channels"] = []
                }
            ),
            (
                "extra channel identity",
                {
                    var channels = $0["channels"] as! [[String: Any]]
                    channels.append(channels[0])
                    $0["channels"] = channels
                }
            ),
            (
                "negative channel identity",
                {
                    mutateChannel(&$0) { channel in
                        channel["channel"] = -1
                    }
                }
            ),
            (
                "negative channel RMS",
                {
                    mutateChannel(&$0) { channel in
                        channel["rms"] = -0.1
                    }
                }
            ),
            (
                "negative channel clipping",
                {
                    mutateChannel(&$0) { channel in
                        channel["clippedRatio"] = -0.1
                    }
                }
            ),
            (
                "channel clipping threshold",
                {
                    mutateChannel(&$0) { channel in
                        channel["clippedRatio"] = 0.005
                    }
                }
            ),
            (
                "negative channel non-silent ratio",
                {
                    mutateChannel(&$0) { channel in
                        channel["nonSilentRatio"] = -0.1
                    }
                }
            ),
            (
                "channel non-silent ratio above one",
                {
                    mutateChannel(&$0) { channel in
                        channel["nonSilentRatio"] = 1.1
                    }
                }
            ),
            (
                "channel symbol count non-positive",
                {
                    mutateChannel(&$0) { channel in
                        channel["challengeSymbolCount"] = 0
                    }
                }
            ),
            (
                "channel matched count negative",
                {
                    mutateChannel(&$0) { channel in
                        channel["matchedSymbolCount"] = -1
                    }
                }
            ),
            (
                "channel matched count exceeds symbols",
                {
                    mutateChannel(&$0) { channel in
                        channel["matchedSymbolCount"] = 21
                    }
                }
            ),
            (
                "channel match ratio inconsistency",
                {
                    mutateChannel(&$0) { channel in
                        channel["matchRatio"] = 0.91
                    }
                }
            ),
            (
                "channel envelope below range",
                {
                    mutateChannel(&$0) { channel in
                        channel["envelopeCorrelation"] = -1.01
                    }
                }
            ),
            (
                "channel envelope above range",
                {
                    mutateChannel(&$0) { channel in
                        channel["envelopeCorrelation"] = 1.01
                    }
                }
            ),
            (
                "recognized channel out of range",
                { $0["recognizedChannel"] = 2 }
            ),
            (
                "recognized channel aggregate mismatch",
                { $0["recognizedChannel"] = 1 }
            ),
            (
                "recognized peak low",
                {
                    var channels = $0["channels"] as! [[String: Any]]
                    channels[0]["peak"] = 511
                    $0["channels"] = channels
                }
            ),
            (
                "recognized peak high",
                {
                    var channels = $0["channels"] as! [[String: Any]]
                    channels[0]["peak"] = 32_760
                    $0["channels"] = channels
                }
            ),
            (
                "recognized count mismatch",
                { $0["matchedSymbolCount"] = 17 }
            ),
        ]
        for (name, mutate) in mutations {
            var mutant = passingBlackHoleProbeJSON(nonce: nonce)
            mutate(&mutant)
            try assertRejected(mutant, name)
        }

        let leakedUID = SyntheticPhysicalDevice.physicalOutputUID
        let leakedNonce = "nonce-\(leakedUID)"
        let leaked = try validate(
            passingBlackHoleProbeJSON(nonce: leakedNonce),
            expectedNonce: leakedNonce,
            outputUID: leakedUID
        )
        XCTAssertTrue(leaked.exitedWithinDeadline, leaked.diagnostic)
        XCTAssertNotEqual(
            leaked.terminationStatus,
            0,
            "A recursively embedded physical-output UID escaped validation."
        )

        var nestedLeak = passingBlackHoleProbeJSON(nonce: nonce)
        var nestedProgress = nestedLeak["progressSnapshots"] as! [[String: Any]]
        nestedProgress[1]["advancing"] =
            "nested-\(SyntheticPhysicalDevice.physicalOutputUID)"
        nestedLeak["progressSnapshots"] = nestedProgress
        let nestedLeakResult = try validate(
            nestedLeak,
            outputUID: SyntheticPhysicalDevice.physicalOutputUID
        )
        XCTAssertTrue(
            nestedLeakResult.exitedWithinDeadline,
            nestedLeakResult.diagnostic
        )
        XCTAssertNotEqual(
            nestedLeakResult.terminationStatus,
            0,
            "A physical-output UID embedded in a nested schema field escaped validation."
        )
    }

    func testFrozenBlackHoleProbeSyntheticCasesHaveExactPassSet() throws {
        let root = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
            .appendingPathComponent("opensteamer-frozen-blackhole-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"
        )
        let binary = root.appendingPathComponent("physical-blackhole-microphone-probe")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "--sdk",
            "macosx",
            "swiftc",
            source.path,
            "-o",
            binary.path,
            "-framework",
            "AudioToolbox",
            "-framework",
            "CoreAudio",
        ]
        let compilerError = Pipe()
        compiler.standardError = compilerError
        try compiler.run()
        let compilerExited = waitForExit(compiler, timeout: 90)
        if !compilerExited {
            forceStopProcessAndIsolatedGroup(compiler)
        }
        XCTAssertTrue(compilerExited)
        guard !compiler.isRunning else {
            XCTFail("The frozen probe compiler survived cleanup.")
            return
        }
        let compileDiagnostic = String(
            decoding: readAvailableData(from: compilerError),
            as: UTF8.self
        )
        XCTAssertEqual(compiler.terminationStatus, 0, compileDiagnostic)

        let cases = [
            "healthy",
            "all-zero",
            "near-silent",
            "wrong-nonce",
            "unrelated-pattern",
            "repeated-symbol",
            "insufficient-frames",
            "long-stall",
            "clipped-pcm",
            "bad-prefix-healthy-tail",
            "wrong-capture-uid",
            "wrong-readback",
            "default-changed",
            "defaults-restored-notification",
            "stale-nonce",
            "too-few-progress",
            "output-generator",
            "physical-output-policy",
            "route-mutation",
            "default-output-virtual-microphone-input",
            "default-output-virtual-microphone-writer",
            "default-system-output-virtual-microphone-input",
            "default-system-output-virtual-microphone-writer",
            "default-output-legacy-blackhole-visible",
            "default-output-legacy-blackhole-hidden",
            "default-system-output-legacy-blackhole-visible",
            "default-system-output-legacy-blackhole-hidden",
            "digital-delayed-loop",
        ]
        let passingCases: Set<String> = [
            "healthy",
            "output-generator",
            "physical-output-policy",
        ]
        let expectedRouteFailureCodes = [
            "route-mutation":
                "route_identity_changed_during_proof",
            "default-output-virtual-microphone-input":
                "default_output_is_virtual_microphone_input",
            "default-output-virtual-microphone-writer":
                "default_output_is_virtual_microphone_writer",
            "default-system-output-virtual-microphone-input":
                "default_system_output_is_virtual_microphone_input",
            "default-system-output-virtual-microphone-writer":
                "default_system_output_is_virtual_microphone_writer",
            "default-output-legacy-blackhole-visible":
                "default_output_is_legacy_blackhole_visible",
            "default-output-legacy-blackhole-hidden":
                "default_output_is_legacy_blackhole_hidden",
            "default-system-output-legacy-blackhole-visible":
                "default_system_output_is_legacy_blackhole_visible",
            "default-system-output-legacy-blackhole-hidden":
                "default_system_output_is_legacy_blackhole_hidden",
        ]
        for testCase in cases {
            let resultURL = root.appendingPathComponent("\(testCase).json")
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "self-test",
                "--case",
                testCase,
                "--nonce",
                "frozen-probe-self-test",
                "--result",
                resultURL.path,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            let exited = waitForExit(process, timeout: 30)
            if !exited {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(exited, "Frozen probe case \(testCase) timed out.")
            guard !process.isRunning else {
                XCTFail("Frozen probe case \(testCase) survived cleanup.")
                continue
            }
            let diagnostic = String(
                decoding: readAvailableData(from: standardError),
                as: UTF8.self
            )
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: resultURL)
            ) as! [String: Any]
            XCTAssertEqual(
                object["schema"] as? String,
                "opensteamer.physical-virtual-microphone.v2"
            )
            XCTAssertEqual(
                object["canonicalCaptureUID"] as? String,
                "com.elamin.opensteamer.virtual-microphone.input"
            )
            let format = object["format"] as! [String: Any]
            XCTAssertEqual(format["sampleRate"] as? Int, 48_000)
            XCTAssertEqual(format["channels"] as? Int, 1)
            XCTAssertEqual(format["signedInt16"] as? Bool, true)
            XCTAssertEqual(format["interleaved"] as? Bool, true)
            XCTAssertEqual((object["channels"] as! [[String: Any]]).count, 1)
            if passingCases.contains(testCase) {
                XCTAssertEqual(process.terminationStatus, 0, diagnostic)
                XCTAssertEqual(object["status"] as? String, "passed")
            } else {
                XCTAssertEqual(process.terminationStatus, 1, diagnostic)
                XCTAssertEqual(object["status"] as? String, "failed")
                if let expectedFailure =
                    expectedRouteFailureCodes[testCase] {
                    XCTAssertEqual(
                        object["failureCode"] as? String,
                        expectedFailure,
                        "\(testCase) bypassed the production route validator."
                    )
                }
            }
        }

        let measurementCases: [(name: String, status: String, exit: Int32)] = [
            ("dual-mono-tagged", "passed", 0),
            ("left-only-tagged", "passed", 0),
            ("anti-phase-tagged", "passed", 0),
            ("wrong-tag", "failed", 1),
            ("all-zero", "completed", 0),
            ("dc-clipped", "completed", 0),
            ("dc-offset", "completed", 0),
            ("noise", "completed", 0),
            ("near-clip", "completed", 0),
            ("frozen-blocks", "completed", 0),
            ("cadence-gap", "failed", 1),
            ("short-capture", "failed", 1),
            ("startup-delay", "completed", 0),
            ("nonmonotonic-sample-time", "failed", 1),
            ("nonmonotonic-host-time", "failed", 1),
            ("sample-time-gap", "failed", 1),
        ]
        for measurementCase in measurementCases {
            let nonce = "measure-self-test-nonce"
            let resultURL = root.appendingPathComponent(
                "measure-\(measurementCase.name).json"
            )
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "measure-self-test",
                "--case",
                measurementCase.name,
                "--nonce",
                nonce,
                "--result",
                resultURL.path,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            let exited = waitForExit(process, timeout: 30)
            if !exited {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(
                exited,
                "BlackHole measure case \(measurementCase.name) timed out."
            )
            guard !process.isRunning else {
                XCTFail(
                    "BlackHole measure case \(measurementCase.name) survived cleanup."
                )
                continue
            }
            let diagnostic = String(
                decoding: readAvailableData(from: standardError),
                as: UTF8.self
            )
            XCTAssertEqual(
                process.terminationStatus,
                measurementCase.exit,
                diagnostic
            )
            let data = try Data(contentsOf: resultURL)
            let object = try JSONSerialization.jsonObject(with: data)
                as! [String: Any]
            XCTAssertEqual(
                object["schema"] as? String,
                "opensteamer.blackhole-input-measurement.v1"
            )
            XCTAssertEqual(object["status"] as? String, measurementCase.status)
            XCTAssertEqual(object["canonicalCaptureUID"] as? String, "BlackHole2ch_UID")
            XCTAssertEqual(object["rawPCMRetained"] as? Bool, false)
            XCTAssertEqual(object["rawPCMPersisted"] as? Bool, false)
            XCTAssertEqual(object["outputOpened"] as? Bool, false)
            XCTAssertEqual(object["defaultsMutated"] as? Bool, false)
            XCTAssertEqual(object["telemetryWindowLimit"] as? Int, 30)
            let windows = object["telemetryWindows"]
                as! [[String: Any]]
            XCTAssertEqual(
                windows.count,
                measurementCase.name == "short-capture" ? 4 : 8
            )
            XCTAssertLessThanOrEqual(windows.count, 30)
            XCTAssertFalse(
                String(decoding: data, as: UTF8.self).contains(nonce),
                "The measurement artifact persisted its plaintext challenge nonce."
            )

            let aggregate = object["aggregate"] as! [String: Any]
            let channels = aggregate["channels"] as! [[String: Any]]
            let stereo = aggregate["stereo"] as! [String: Any]
            let cadence = aggregate["cadence"] as! [String: Any]
            let challenge = object["taggedChallenge"] as! [String: Any]
            XCTAssertEqual(cadence["sampleTimeMissingCount"] as? Int, 0)
            XCTAssertEqual(cadence["hostTimeMissingCount"] as? Int, 0)
            XCTAssertEqual(
                cadence["sampleTimeValidCount"] as? Int,
                object["callbackCount"] as? Int
            )
            XCTAssertEqual(
                cadence["hostTimeValidCount"] as? Int,
                object["callbackCount"] as? Int
            )
            switch measurementCase.name {
            case "dual-mono-tagged":
                XCTAssertEqual(challenge["recognized"] as? Bool, true)
                XCTAssertGreaterThan(
                    stereo["leftRightCorrelation"] as! Double,
                    0.99
                )
                XCTAssertLessThan(
                    stereo["differenceRMSNormalized"] as! Double,
                    0.000_001
                )
                XCTAssertEqual(stereo["oneSidedFrameFraction"] as? Double, 0)
            case "left-only-tagged":
                XCTAssertEqual(challenge["recognized"] as? Bool, true)
                XCTAssertEqual(challenge["recognizedChannel"] as? Int, 0)
                XCTAssertGreaterThan(
                    stereo["oneSidedFrameFraction"] as! Double,
                    0.90
                )
                XCTAssertEqual(channels[1]["rmsNormalized"] as? Double, 0)
            case "anti-phase-tagged":
                XCTAssertEqual(challenge["recognized"] as? Bool, true)
                XCTAssertLessThan(
                    stereo["leftRightCorrelation"] as! Double,
                    -0.99
                )
                XCTAssertLessThan(
                    stereo["sumRMSNormalized"] as! Double,
                    0.000_001
                )
                XCTAssertGreaterThan(
                    stereo["differenceRMSNormalized"] as! Double,
                    0.05
                )
            case "wrong-tag":
                XCTAssertEqual(challenge["recognized"] as? Bool, false)
                XCTAssertEqual(
                    object["failureCode"] as? String,
                    "tagged_challenge_not_recognized"
                )
            case "all-zero":
                XCTAssertEqual(challenge["enabled"] as? Bool, false)
                XCTAssertEqual(channels[0]["zeroSampleFraction"] as? Double, 1)
                XCTAssertEqual(channels[1]["zeroSampleFraction"] as? Double, 1)
            case "dc-clipped":
                XCTAssertGreaterThan(
                    channels[0]["dcMeanNormalized"] as! Double,
                    0.99
                )
                XCTAssertEqual(channels[0]["clippingFraction"] as? Double, 1)
            case "dc-offset":
                XCTAssertEqual(
                    channels[0]["dcMeanNormalized"] as? Double,
                    0.125
                )
                XCTAssertEqual(channels[0]["clippingFraction"] as? Double, 0)
                XCTAssertEqual(
                    stereo["leftRightCorrelation"] as? Double,
                    0,
                    "Centered Pearson must not report perfect correlation for two constant-DC channels."
                )
            case "noise":
                XCTAssertLessThan(
                    abs(channels[0]["dcMeanNormalized"] as! Double),
                    0.001
                )
                XCTAssertLessThan(
                    abs(stereo["leftRightCorrelation"] as! Double),
                    0.02
                )
                XCTAssertEqual(channels[0]["clippingFraction"] as? Double, 0)
            case "near-clip":
                XCTAssertEqual(
                    channels[0]["peakNormalized"] as? Double,
                    Double(32_759) / 32_768.0
                )
                XCTAssertEqual(
                    channels[0]["clippingFraction"] as? Double,
                    0,
                    "Magnitude 32759 is below the inclusive >=32760 clipping boundary."
                )
                XCTAssertEqual(channels[0]["activeFrameFraction"] as? Double, 1)
            case "frozen-blocks":
                XCTAssertGreaterThan(
                    channels[0]["repeatedBlockCount"] as! Int,
                    700
                )
                XCTAssertGreaterThan(
                    channels[0]["longestRepeatedBlockRun"] as! Int,
                    700
                )
            case "cadence-gap":
                XCTAssertEqual(
                    cadence["callbackGapOver25MsCount"] as? Int,
                    1
                )
                XCTAssertGreaterThan(
                    cadence["maximumCallbackGapMs"] as! Double,
                    200
                )
                XCTAssertEqual(
                    object["failureCode"] as? String,
                    "callback_gap_over_25ms"
                )
            case "short-capture":
                XCTAssertEqual(object["capturedDurationRatio"] as? Double, 0.5)
                XCTAssertEqual(object["frameDensity"] as? Double, 0.5)
                let failures = object["failureReasons"] as! [String]
                XCTAssertTrue(failures.contains("insufficient_capture_duration"))
                XCTAssertTrue(failures.contains("frame_density_out_of_range"))
            case "startup-delay":
                XCTAssertEqual(object["capturedDurationRatio"] as? Double, 1)
                XCTAssertEqual(object["frameDensity"] as? Double, 1)
                XCTAssertEqual(
                    object["measurementStartMonotonicNs"] as? Int64,
                    10_001_750_000_000
                )
                XCTAssertEqual(
                    windows.first?["startMonotonicNs"] as? Int64,
                    10_001_750_000_000
                )
            case "nonmonotonic-sample-time":
                XCTAssertEqual(
                    cadence["nonMonotonicSampleTimeCount"] as? Int,
                    1
                )
                XCTAssertEqual(
                    object["failureCode"] as? String,
                    "nonmonotonic_sample_timestamp"
                )
            case "nonmonotonic-host-time":
                XCTAssertEqual(
                    cadence["nonMonotonicHostTimeCount"] as? Int,
                    1
                )
                XCTAssertEqual(
                    object["failureCode"] as? String,
                    "nonmonotonic_host_timestamp"
                )
            case "sample-time-gap":
                XCTAssertEqual(
                    cadence["sampleFrameDiscontinuityCount"] as? Int,
                    1
                )
                XCTAssertEqual(
                    object["failureCode"] as? String,
                    "sample_timestamp_discontinuity"
                )
            default:
                XCTFail("Unexpected BlackHole measurement self-test case.")
            }
        }

        let mirrorCases: [(
            name: String,
            headroom: String,
            status: String,
            exit: Int32,
            failure: String
        )] = [
            ("healthy", "60", "passed", 0, "none"),
            (
                "captured-overflow", "60", "failed", 1,
                "captured_pcm_overflow"
            ),
            (
                "live-style-overflow", "60", "failed", 1,
                "captured_pcm_overflow"
            ),
            ("cap-boundary-pass", "0", "passed", 0, "none"),
            (
                "cap-boundary-fail", "0", "failed", 1,
                "projected_sample_time_exceeds_signed32"
            ),
            (
                "captured-aged-clock", "60", "failed", 1,
                "projected_sample_time_exceeds_signed32"
            ),
            ("headroom-boundary-pass", "60", "passed", 0, "none"),
            (
                "headroom-boundary-fail", "60", "failed", 1,
                "insufficient_signed32_headroom"
            ),
            (
                "wrong-projection", "60", "failed", 1,
                "projection_evidence_mismatch"
            ),
            (
                "wrong-rounding", "60", "failed", 1,
                "projection_evidence_mismatch"
            ),
            ("dropped-frame", "60", "failed", 1, "exact_pcm_mismatch"),
            (
                "duplicated-frame", "60", "failed", 1,
                "exact_pcm_mismatch"
            ),
            ("bit-flip", "60", "failed", 1, "exact_pcm_mismatch"),
            (
                "gain-change", "60", "failed", 1,
                "challenge_alignment_not_found"
            ),
            (
                "silence", "60", "failed", 1,
                "challenge_alignment_not_found"
            ),
            (
                "short-capture", "60", "failed", 1,
                "exact_pcm_mismatch"
            ),
            (
                "timestamp-flags", "60", "failed", 1,
                "timestamp_flags_missing"
            ),
            (
                "device-time-flags", "60", "failed", 1,
                "device_time_flags_missing"
            ),
            (
                "frozen-device-time", "60", "failed", 1,
                "device_time_not_advancing"
            ),
            (
                "divergent-device-time", "60", "failed", 1,
                "mirror_device_time_mismatch"
            ),
            (
                "nonintegral-sample-time", "60", "failed", 1,
                "nonintegral_sample_timestamp"
            ),
            (
                "unrepresentable-sample-time", "60", "failed", 1,
                "nonintegral_sample_timestamp"
            ),
            (
                "sample-time-regression", "60", "failed", 1,
                "nonmonotonic_sample_timestamp"
            ),
            (
                "sample-time-gap", "60", "failed", 1,
                "sample_timestamp_discontinuity"
            ),
            (
                "host-time-regression", "60", "failed", 1,
                "nonmonotonic_host_timestamp"
            ),
            (
                "transient-host-scheduling-jitter", "60", "passed", 0,
                "none"
            ),
            (
                "host-time-mismatch", "60", "failed", 1,
                "host_sample_clock_mismatch"
            ),
            (
                "format", "60", "failed", 1,
                "queue_format_readback_mismatch"
            ),
            (
                "fractional-format", "60", "failed", 1,
                "queue_format_readback_mismatch"
            ),
            (
                "extra-format-flag", "60", "failed", 1,
                "queue_format_readback_mismatch"
            ),
            (
                "reserved-format", "60", "failed", 1,
                "queue_format_readback_mismatch"
            ),
            (
                "device-format", "60", "failed", 1,
                "device_stream_format_mismatch"
            ),
            (
                "physical-device-format", "60", "failed", 1,
                "device_stream_format_mismatch"
            ),
            (
                "writer-physical-device-format", "60", "failed", 1,
                "device_stream_format_mismatch"
            ),
            (
                "stereo-format", "60", "failed", 1,
                "queue_format_readback_mismatch"
            ),
            (
                "fractional-nominal-rate", "60", "failed", 1,
                "visible_endpoint_identity_mismatch"
            ),
            (
                "wrong-role", "60", "failed", 1,
                "visible_endpoint_identity_mismatch"
            ),
            (
                "clock-domain", "60", "failed", 1,
                "clock_domain_mismatch"
            ),
            (
                "control-mute", "60", "failed", 1,
                "signal_path_muted"
            ),
            (
                "device-volume", "60", "failed", 1,
                "device_volume_not_unity"
            ),
            (
                "queue-volume", "60", "failed", 1,
                "writer_queue_volume_mismatch"
            ),
            (
                "input-not-ready", "60", "failed", 1,
                "input_capture_not_ready"
            ),
            (
                "buffer-contract", "60", "failed", 1,
                "capture_buffer_contract_unproven"
            ),
            (
                "writer-no-progress", "60", "failed", 1,
                "writer_challenge_not_submitted"
            ),
            (
                "post-roll-noise", "60", "failed", 1,
                "post_roll_not_silent"
            ),
            (
                "visible-uid", "60", "failed", 1,
                "visible_endpoint_identity_mismatch"
            ),
            (
                "hidden-uid", "60", "failed", 1,
                "hidden_endpoint_identity_mismatch"
            ),
            (
                "queue-uid", "60", "failed", 1,
                "queue_device_readback_mismatch"
            ),
            (
                "default-mutation", "60", "failed", 1,
                "default_route_changed"
            ),
            (
                "default-notification", "60", "failed", 1,
                "default_change_notification_observed"
            ),
            (
                "hidden-default", "60", "failed", 1,
                "default_route_changed"
            ),
            (
                "legacy-output-default", "60", "failed", 1,
                "virtual_endpoint_became_output_default"
            ),
            (
                "device-notification", "60", "failed", 1,
                "device_change_notification_observed"
            ),
            (
                "teardown-stop", "60", "failed", 1,
                "audio_queue_teardown_failure"
            ),
            (
                "teardown-dispose", "60", "failed", 1,
                "audio_queue_teardown_failure"
            ),
            (
                "teardown-gate", "60", "failed", 1,
                "callback_gate_teardown_failure"
            ),
            ("teardown-post-close", "60", "passed", 0, "none"),
            (
                "cleanup-evidence", "60", "failed", 1,
                "cleanup_evidence_incomplete"
            ),
            (
                "listener-remove", "60", "failed", 1,
                "listener_remove_failed"
            ),
            (
                "running-state", "60", "failed", 1,
                "device_running_state_not_restored"
            ),
        ]
        for mirrorCase in mirrorCases {
            let nonce = "mirror-loopback-self-test-nonce"
            let resultURL = root.appendingPathComponent(
                "mirror-\(mirrorCase.name).json"
            )
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "mirror-loopback-self-test",
                "--case",
                mirrorCase.name,
                "--nonce",
                nonce,
                "--required-headroom-seconds",
                mirrorCase.headroom,
                "--result",
                resultURL.path,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            let exited = waitForExit(process, timeout: 30)
            if !exited {
                forceStopProcessAndIsolatedGroup(process)
            }
            XCTAssertTrue(
                exited,
                "Mirror loopback case \(mirrorCase.name) timed out."
            )
            guard !process.isRunning else {
                XCTFail(
                    "Mirror loopback case \(mirrorCase.name) survived cleanup."
                )
                continue
            }
            let diagnostic = String(
                decoding: readAvailableData(from: standardError),
                as: UTF8.self
            )
            XCTAssertEqual(
                process.terminationStatus,
                mirrorCase.exit,
                "\(mirrorCase.name): \(diagnostic)"
            )
            let data = try Data(contentsOf: resultURL)
            let object = try JSONSerialization.jsonObject(with: data)
                as! [String: Any]
            XCTAssertEqual(
                object["schema"] as? String,
                "opensteamer.virtual-microphone-mirror-loopback.v2"
            )
            XCTAssertEqual(object["status"] as? String, mirrorCase.status)
            XCTAssertEqual(
                object["mode"] as? String,
                "synthetic-self-test"
            )
            XCTAssertEqual(
                object["realQueuePathImplemented"] as? Bool,
                false
            )
            XCTAssertEqual(
                object["failureCode"] as? String,
                mirrorCase.failure
            )
            let failureReasons = object["failureReasons"] as! [String]
            XCTAssertFalse(
                String(decoding: data, as: UTF8.self).contains(nonce),
                "The mirror artifact persisted its plaintext challenge nonce."
            )

            let challenge = object["challenge"] as! [String: Any]
            XCTAssertEqual(
                challenge["algorithm"] as? String,
                "nonce-splitmix64-mono-sentinel-prbs"
            )
            XCTAssertEqual(challenge["version"] as? Int, 2)
            XCTAssertEqual(challenge["frameCount"] as? Int, 96_000)
            XCTAssertEqual(challenge["sampleCount"] as? Int, 96_000)
            XCTAssertEqual(challenge["sentinelFrameCount"] as? Int, 256)

            let endpoints = object["endpointPair"] as! [String: Any]
            let visible = endpoints["visible"] as! [String: Any]
            let hidden = endpoints["hidden"] as! [String: Any]
            XCTAssertEqual(
                visible["expectedUID"] as? String,
                "com.elamin.opensteamer.virtual-microphone.input"
            )
            XCTAssertEqual(
                hidden["expectedUID"] as? String,
                "com.elamin.opensteamer.virtual-microphone.writer"
            )
            XCTAssertEqual(visible["hidden"] as? Bool, false)
            XCTAssertEqual(visible["inputChannels"] as? Int, 1)
            XCTAssertEqual(
                visible["outputChannels"] as? Int,
                mirrorCase.name == "wrong-role" ? 1 : 0
            )
            XCTAssertEqual(hidden["hidden"] as? Bool, true)
            XCTAssertEqual(hidden["inputChannels"] as? Int, 0)
            XCTAssertEqual(hidden["outputChannels"] as? Int, 1)
            XCTAssertEqual(
                visible["modelUIDMatchesExpected"] as? Bool,
                true
            )
            XCTAssertEqual(
                hidden["modelUIDMatchesExpected"] as? Bool,
                true
            )
            XCTAssertEqual(
                visible["clockDomain"] as? Int,
                Int(0x6F73564D)
            )
            XCTAssertEqual(
                hidden["clockDomain"] as? Int,
                mirrorCase.name == "clock-domain"
                    ? Int(0x6F73564D) + 1
                    : Int(0x6F73564D)
            )
            XCTAssertEqual(
                endpoints["clockDomainsMatch"] as? Bool,
                mirrorCase.name != "clock-domain"
            )
            let queue = object["queueContract"] as! [String: Any]
            let requestedFormat = queue["requestedFormat"]
                as! [String: Any]
            XCTAssertEqual(
                requestedFormat["sampleRate"] as? Double,
                48_000
            )
            XCTAssertEqual(
                requestedFormat["formatFlags"] as? Int,
                Int(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
            )
            XCTAssertEqual(requestedFormat["reserved"] as? Int, 0)
            XCTAssertEqual(requestedFormat["channelsPerFrame"] as? Int, 1)
            XCTAssertEqual(requestedFormat["bitsPerChannel"] as? Int, 16)
            XCTAssertEqual(requestedFormat["bytesPerFrame"] as? Int, 2)
            XCTAssertEqual(requestedFormat["interleaved"] as? Bool, true)
            XCTAssertEqual(requestedFormat["signedInteger"] as? Bool, true)
            XCTAssertEqual(requestedFormat["floatingPoint"] as? Bool, false)
            let captureDeviceFormat = queue["captureDeviceVirtualFormat"]
                as! [String: Any]
            let captureDevicePhysicalFormat =
                queue["captureDevicePhysicalFormat"] as! [String: Any]
            XCTAssertEqual(
                captureDeviceFormat["floatingPoint"] as? Bool,
                true
            )
            XCTAssertEqual(
                captureDeviceFormat["channelsPerFrame"] as? Int,
                1
            )
            XCTAssertEqual(
                captureDeviceFormat["bytesPerFrame"] as? Int,
                4
            )
            XCTAssertEqual(
                captureDeviceFormat["bitsPerChannel"] as? Int,
                32
            )
            XCTAssertEqual(
                captureDevicePhysicalFormat["sampleRate"] as? Double,
                mirrorCase.name == "physical-device-format"
                    ? 44_100 : 48_000
            )
            XCTAssertEqual(
                captureDevicePhysicalFormat["floatingPoint"] as? Bool,
                true
            )
            XCTAssertEqual(
                captureDevicePhysicalFormat["channelsPerFrame"] as? Int,
                1
            )
            let writerDeviceFormat = queue["writerDeviceVirtualFormat"]
                as! [String: Any]
            let writerDevicePhysicalFormat =
                queue["writerDevicePhysicalFormat"] as! [String: Any]
            XCTAssertEqual(
                writerDeviceFormat["floatingPoint"] as? Bool,
                true
            )
            XCTAssertEqual(
                writerDeviceFormat["channelsPerFrame"] as? Int,
                1
            )
            XCTAssertEqual(
                writerDeviceFormat["bytesPerFrame"] as? Int,
                4
            )
            XCTAssertEqual(
                writerDeviceFormat["bitsPerChannel"] as? Int,
                32
            )
            XCTAssertEqual(
                writerDevicePhysicalFormat["sampleRate"] as? Double,
                mirrorCase.name == "writer-physical-device-format"
                    ? 44_100 : 48_000
            )
            XCTAssertEqual(
                writerDevicePhysicalFormat["floatingPoint"] as? Bool,
                true
            )
            XCTAssertEqual(
                writerDevicePhysicalFormat["channelsPerFrame"] as? Int,
                1
            )
            XCTAssertEqual(
                queue["writerPrimingFrameCount"] as? Int,
                1_920
            )
            XCTAssertEqual(
                queue["writerChallengeFullySubmitted"] as? Bool,
                mirrorCase.name != "writer-no-progress"
            )
            XCTAssertEqual(
                queue["visibleInputMuted"] as? Bool,
                mirrorCase.name == "control-mute"
            )
            XCTAssertEqual(queue["hiddenOutputMuted"] as? Bool, false)
            XCTAssertEqual(
                queue["hiddenOutputVolumeScalar"] as? Double,
                1.0
            )
            XCTAssertEqual(
                queue["writerQueueVolumeScalar"] as? Double,
                mirrorCase.name == "queue-volume" ? 0.5 : 1.0
            )
            XCTAssertEqual(
                queue["writerQueueVolumeMatches"] as? Bool,
                mirrorCase.name != "queue-volume"
            )
            XCTAssertEqual(
                queue["signalControlsMatch"] as? Bool,
                !["control-mute", "device-volume"]
                    .contains(mirrorCase.name)
            )
            if mirrorCase.name == "device-volume" {
                XCTAssertEqual(
                    queue["visibleInputVolumeScalar"] as! Double,
                    0.841_040_5,
                    accuracy: 0.000_000_1
                )
            } else if mirrorCase.name == "fractional-format" {
                let captureFormat = queue["captureReadbackFormat"]
                    as! [String: Any]
                XCTAssertEqual(
                    captureFormat["sampleRate"] as? Double,
                    48_000.25
                )
            } else if mirrorCase.name == "extra-format-flag" {
                let captureFormat = queue["captureReadbackFormat"]
                    as! [String: Any]
                XCTAssertEqual(
                    captureFormat["formatFlags"] as? Int,
                    Int(
                        kAudioFormatFlagIsSignedInteger
                            | kAudioFormatFlagIsPacked
                            | kAudioFormatFlagIsAlignedHigh
                    )
                )
            } else if mirrorCase.name == "reserved-format" {
                let captureFormat = queue["captureReadbackFormat"]
                    as! [String: Any]
                XCTAssertEqual(captureFormat["reserved"] as? Int, 1)
            } else if mirrorCase.name == "fractional-nominal-rate" {
                XCTAssertEqual(
                    visible["nominalSampleRate"] as? Double,
                    48_000.25
                )
            } else if mirrorCase.name == "stereo-format" {
                let captureFormat = queue["captureReadbackFormat"]
                    as! [String: Any]
                XCTAssertEqual(captureFormat["channelsPerFrame"] as? Int, 2)
                XCTAssertEqual(captureFormat["bytesPerFrame"] as? Int, 4)
                XCTAssertEqual(captureFormat["bytesPerPacket"] as? Int, 4)
            }

            let pcm = object["pcm"] as! [String: Any]
            XCTAssertEqual(pcm["retainedSampleLimit"] as? Int, 145_920)
            XCTAssertLessThanOrEqual(
                min(
                    pcm["capturedSampleCount"] as! Int,
                    pcm["retainedSampleLimit"] as! Int
                ),
                145_920
            )
            XCTAssertEqual(
                pcm["capturedOverflow"] as? Bool,
                failureReasons.contains("captured_pcm_overflow")
            )
            XCTAssertGreaterThanOrEqual(
                pcm["totalObservedSampleCount"] as! Int,
                min(
                    pcm["capturedSampleCount"] as! Int,
                    pcm["retainedSampleLimit"] as! Int
                )
            )
            XCTAssertGreaterThanOrEqual(
                pcm["rawCaptureCallbackCount"] as! Int,
                mirrorCase.name == "input-not-ready" ? 0 : 2
            )
            XCTAssertFalse((pcm["retainedPCMHash"] as! String).isEmpty)
            if pcm["alignmentCount"] as? Int == 0 {
                XCTAssertEqual(pcm["comparisonAvailable"] as? Bool, false)
                XCTAssertFalse(
                    failureReasons.contains("host_sample_clock_mismatch")
                )
                XCTAssertFalse(
                    failureReasons.contains("timestamp_frame_count_mismatch")
                )
            }
            if mirrorCase.name == "healthy" {
                XCTAssertEqual(pcm["alignmentCount"] as? Int, 1)
                XCTAssertEqual(pcm["alignedStartFrame"] as? Int, 480)
                XCTAssertEqual(pcm["exactPCMMatches"] as? Bool, true)
                XCTAssertEqual(pcm["matchedFrameCount"] as? Int, 96_000)
                XCTAssertEqual(
                    pcm["requiredPostRollFrameCount"] as? Int,
                    1_920
                )
                XCTAssertEqual(
                    pcm["capturedPostRollFrameCount"] as? Int,
                    1_920
                )
                XCTAssertEqual(
                    pcm["postRollNonzeroSampleCount"] as? Int,
                    0
                )
                XCTAssertEqual(pcm["postRollAbsolutePeak"] as? Int, 0)
                XCTAssertEqual(pcm["postRollSilenceMatches"] as? Bool, true)
                XCTAssertEqual(
                    pcm["unexpectedTrailingFrameCount"] as? Int,
                    0
                )
                XCTAssertEqual(pcm["signedInt16Compatible"] as? Bool, true)
                XCTAssertGreaterThan(pcm["nonzeroSampleCount"] as! Int, 0)
                XCTAssertGreaterThan(pcm["absolutePeak"] as! Int, 0)
                XCTAssertGreaterThan(pcm["rootMeanSquare"] as! Double, 0)
            } else if mirrorCase.name == "live-style-overflow" {
                XCTAssertEqual(pcm["capturedSampleCount"] as? Int, 145_920)
                XCTAssertEqual(
                    pcm["totalObservedSampleCount"] as? Int,
                    146_400
                )
            } else if [
                "format",
                "fractional-format",
                "extra-format-flag",
                "reserved-format",
                "stereo-format",
                "buffer-contract",
            ].contains(mirrorCase.name) {
                XCTAssertEqual(pcm["signedInt16Compatible"] as? Bool, false)
            } else if mirrorCase.name == "post-roll-noise" {
                XCTAssertEqual(pcm["exactPCMMatches"] as? Bool, true)
                XCTAssertEqual(pcm["postRollSilenceMatches"] as? Bool, false)
                XCTAssertEqual(
                    pcm["postRollNonzeroSampleCount"] as? Int,
                    1
                )
                XCTAssertEqual(
                    pcm["unexpectedTrailingFrameCount"] as? Int,
                    1
                )
                XCTAssertTrue(failureReasons.contains("post_roll_not_silent"))
            } else if mirrorCase.name == "short-capture" {
                XCTAssertEqual(pcm["comparisonAvailable"] as? Bool, true)
                XCTAssertEqual(pcm["missingFrameCount"] as? Int, 480)
                XCTAssertEqual(pcm["capturedPostRollFrameCount"] as? Int, 0)
                XCTAssertTrue(failureReasons.contains("post_roll_incomplete"))
            }

            let defaults = object["defaults"] as! [String: Any]
            XCTAssertEqual(
                defaults["inputBeforeAfterEqual"] as? Bool,
                mirrorCase.name != "hidden-default"
            )
            XCTAssertEqual(
                defaults["outputBeforeAfterEqual"] as? Bool,
                mirrorCase.name != "default-mutation"
            )
            XCTAssertEqual(
                defaults["systemOutputBeforeAfterEqual"] as? Bool,
                true
            )
            XCTAssertEqual(
                defaults["mutated"] as? Bool,
                [
                    "default-mutation",
                    "default-notification",
                    "hidden-default",
                ].contains(mirrorCase.name)
            )
            XCTAssertEqual(
                defaults["hiddenEndpointNeverDefault"] as? Bool,
                mirrorCase.name != "hidden-default"
            )
            XCTAssertEqual(
                defaults["virtualEndpointsNeverOutputDefault"] as? Bool,
                mirrorCase.name != "legacy-output-default"
            )

            let lifecycle = object["lifecycle"] as! [String: Any]
            XCTAssertEqual(
                lifecycle["requiredStartOrders"] as? [String],
                ["visible-first", "hidden-first"]
            )
            XCTAssertEqual(
                lifecycle["zeroTimestampSeedObservableViaPublicAPI"] as? Bool,
                false
            )
            XCTAssertEqual(
                lifecycle["seedChangeClaimed"] as? Bool,
                false
            )
            let cycles = lifecycle["cycles"] as! [[String: Any]]
            XCTAssertEqual(
                cycles.compactMap { $0["startOrder"] as? String },
                ["visible-first", "hidden-first"]
            )
            XCTAssertEqual(cycles.count, 2)
            for cycle in cycles {
                XCTAssertEqual(cycle["quiescentBefore"] as? Bool, true)
                XCTAssertEqual(cycle["quiescentAfter"] as? Bool, true)
                XCTAssertEqual(cycle["nearZeroSharedClock"] as? Bool, true)
                XCTAssertEqual(cycle["timelinesAdvanced"] as? Bool, true)
                XCTAssertEqual(
                    cycle["queuesStoppedAndDisposed"] as? Bool,
                    true
                )
                XCTAssertEqual(
                    cycle["initialVisibleSampleFrame"] as? Int,
                    cycle["initialHiddenSampleFrame"] as? Int
                )
                XCTAssertEqual(
                    cycle["finalVisibleSampleFrame"] as? Int,
                    cycle["finalHiddenSampleFrame"] as? Int
                )
                XCTAssertGreaterThan(
                    cycle["finalVisibleSampleFrame"] as! Int,
                    cycle["initialVisibleSampleFrame"] as! Int
                )
            }
            XCTAssertNotEqual(
                cycles[0]["initialVisibleSampleFrame"] as? Int,
                cycles[1]["initialVisibleSampleFrame"] as? Int
            )

            let timestamps = object["timestamps"] as! [String: Any]
            XCTAssertEqual(
                timestamps["rawCaptureCallbackCount"] as? Int,
                pcm["rawCaptureCallbackCount"] as? Int
            )
            XCTAssertEqual(
                timestamps["alignedEvidenceAvailable"] as? Bool,
                pcm["comparisonAvailable"] as? Bool
            )
            if mirrorCase.name == "transient-host-scheduling-jitter" {
                XCTAssertEqual(
                    timestamps["hostDeltaMismatchCount"] as? Int,
                    2
                )
                XCTAssertEqual(
                    timestamps["maximumHostDeltaErrorNs"] as? Int,
                    7_000_000
                )
                XCTAssertEqual(
                    timestamps["nonMonotonicHostTimeCount"] as? Int,
                    0
                )
                XCTAssertEqual(
                    timestamps["nonMonotonicSampleTimeCount"] as? Int,
                    0
                )
                XCTAssertEqual(
                    timestamps["sampleFrameDiscontinuityCount"] as? Int,
                    0
                )
                XCTAssertEqual(
                    timestamps["measuredSourceSampleRate"] as! Double,
                    48_000,
                    accuracy: 0.000_001
                )
                XCTAssertEqual(
                    timestamps["sourceSampleRateMatches"] as? Bool,
                    true
                )
                XCTAssertEqual(failureReasons, [])
            } else if mirrorCase.name == "host-time-mismatch" {
                XCTAssertEqual(
                    timestamps["hostDeltaMismatchCount"] as? Int,
                    1
                )
                XCTAssertEqual(
                    timestamps["maximumHostDeltaErrorNs"] as? Int,
                    5_000_000
                )
                XCTAssertEqual(
                    timestamps["sourceSampleRateMatches"] as? Bool,
                    false
                )
                XCTAssertEqual(
                    timestamps["measuredSourceSampleRate"] as! Double,
                    47_879.699_248_120_3,
                    accuracy: 0.000_000_001
                )
                XCTAssertEqual(
                    failureReasons,
                    ["host_sample_clock_mismatch"]
                )
            }
            let projection = timestamps["projection"] as! [String: Any]
            XCTAssertEqual(
                projection["schema"] as? String,
                "opensteamer.facetime-timestamp-projection.v1"
            )
            XCTAssertEqual(projection["sourceSampleRate"] as? Int, 48_000)
            XCTAssertEqual(
                projection["consumerSampleRate"] as? Int,
                24_000
            )
            XCTAssertEqual(projection["ratioNumerator"] as? Int, 1)
            XCTAssertEqual(projection["ratioDenominator"] as? Int, 2)
            XCTAssertEqual(
                projection["rounding"] as? String,
                "conservative-ceiling"
            )
            XCTAssertEqual(
                projection["signedMaximum"] as? Int,
                Int(Int32.max)
            )
            if mirrorCase.name == "cap-boundary-pass" {
                XCTAssertEqual(
                    projection["projectedLastFrame"] as? Int,
                    Int(Int32.max)
                )
                XCTAssertEqual(
                    projection["remainingHeadroomFrames"] as? Int,
                    0
                )
            } else if mirrorCase.name == "cap-boundary-fail" {
                XCTAssertEqual(
                    projection["projectedLastFrame"] as? Int,
                    Int(Int32.max) + 1
                )
                XCTAssertEqual(
                    projection["signed32Compatible"] as? Bool,
                    false
                )
            } else if mirrorCase.name == "captured-aged-clock" {
                XCTAssertEqual(
                    projection["projectedLastFrame"] as? Int,
                    3_343_889_722
                )
                XCTAssertEqual(
                    projection["signed32Compatible"] as? Bool,
                    false
                )
            }
        }

        for unsafeLiveHeadroom in ["0", "59.999"] {
            let rejectedResult = root.appendingPathComponent(
                "mirror-live-headroom-(unsafeLiveHeadroom).json"
            )
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "mirror-loopback",
                "--nonce",
                "mirror-loopback-live-cli-mutant",
                "--required-headroom-seconds",
                unsafeLiveHeadroom,
                "--result",
                rejectedResult.path,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            XCTAssertTrue(waitForExit(process, timeout: 5))
            XCTAssertEqual(
                process.terminationStatus,
                64,
                String(
                    decoding: readAvailableData(from: standardError),
                    as: UTF8.self
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: rejectedResult.path),
                "An unsafe live headroom value reached the Core Audio path."
            )
        }
        let probeSource = try String(contentsOf: source, encoding: .utf8)
        for requiredPolicyToken in [
            "BuiltInSpeakerDevice",
            "kAudioDeviceClassID",
            "kAudioDeviceTransportTypeBuiltIn",
            "kAudioAggregateDevicePropertyFullSubDeviceList",
            "queue_device_changed_during_proof",
            "default_route_changed_during_proof",
            "route_identity_changed_during_proof",
            "controlled_host_no_audio_taps_not_acknowledged",
            "controlled-host-no-audio-taps-reviewed",
            "not cryptographic proof",
            "opensteamer.blackhole-input-measurement.v1",
            "rawPCMRetained",
            "outputOpened",
            "defaultsMutated",
            "tagged-challenge-nonce",
            "BlackHoleMeasureInputBufferContractSelfTest",
            "opensteamer.virtual-microphone-mirror-loopback.v2",
            "opensteamer.facetime-timestamp-projection.v1",
            "nonce-splitmix64-mono-sentinel-prbs",
            "com.elamin.opensteamer.virtual-microphone.input",
            "com.elamin.opensteamer.virtual-microphone.writer",
            "com.elamin.opensteamer.virtual-microphone.model",
            "0x6F73564D",
            "static let captureChannels = 1",
            "static let physicalOutputChannels = 2",
            "static let canonicalDeviceFloat",
            "kAudioHardwarePropertyTranslateUIDToDevice",
            "AudioQueueDeviceGetCurrentTime",
            "required-headroom-seconds",
            "minimumProductionHeadroomSeconds",
            "private enum MirrorLoopbackRealRunner",
            "real-dual-audioqueue",
            "mirror_endpoints_not_quiescent",
            "MirrorLoopbackLiveSeamSelfTest.passes",
            "minimumReadyInputCallbacks",
            "fillPrimingSilence",
            "collectorRetainsNonSilentPostRoll",
            "inputBufferContractProofSurvivesEnqueueFailure",
            "stopInducedEmptyInputCallbackIsRejected",
            "writerChallengeFullySubmitted",
            "captureDeviceVirtualFormat",
            "captureDevicePhysicalFormat",
            "writerDevicePhysicalFormat",
            "kAudioStreamPropertyVirtualFormat",
            "kAudioStreamPropertyPhysicalFormat",
            "kAudioDevicePropertyMute",
            "kAudioDevicePropertyVolumeScalar",
            "kAudioQueueParam_Volume",
            "cannot observe the AudioServerPlugIn zero-timestamp",
            "private enum MirrorLoopbackRestartVerifier",
            "zeroTimestampSeedObservableViaPublicAPI: false",
            "seedChangeClaimed: false",
            "both endpoint start orders",
        ] {
            XCTAssertTrue(
                probeSource.contains(requiredPolicyToken),
                "The physical-output policy omitted \(requiredPolicyToken)."
            )
        }

        let mirrorMarker = try XCTUnwrap(
            probeSource.range(
                of: "// MARK: - Deterministic repo-owned virtual-microphone loopback oracle"
            )
        )
        let mirrorSource = probeSource[mirrorMarker.lowerBound...]
        for removedStereoClaim in [
            "nonce-splitmix64-stereo-sentinel-prbs",
            "channel-swap",
            "mono-collapse",
            "channelOrderMatches",
            "channelSwapDetected",
            "channelDistinct",
        ] {
            XCTAssertFalse(
                mirrorSource.contains(removedStereoClaim),
                "The mono mirror oracle retained stale stereo evidence \(removedStereoClaim)."
            )
        }
        for requiredMonoMutant in [
            "stereo-format",
            "wrong-role",
            "clock-domain",
            "short-capture",
            "post-roll-noise",
            "sample-time-gap",
        ] {
            XCTAssertTrue(
                mirrorSource.contains(requiredMonoMutant),
                "The mono mirror oracle omitted mutant \(requiredMonoMutant)."
            )
        }

        let measureQueueStart = try XCTUnwrap(
            probeSource.range(
                of: "private final class BlackHoleMeasureInputQueueSession"
            )
        )
        let measureQueueEnd = try XCTUnwrap(
            probeSource.range(
                of: "private enum CanonicalBlackHoleMeasureResolver",
                range: measureQueueStart.upperBound..<probeSource.endIndex
            )
        )
        let measureQueueSource = probeSource[
            measureQueueStart.lowerBound..<measureQueueEnd.lowerBound
        ]
        XCTAssertTrue(
            measureQueueSource.contains(
                "AudioQueueDispose is terminal once it returns"
            )
        )
        XCTAssertFalse(
            measureQueueSource.contains("if disposeStatus == noErr"),
            "The measurement queue must not retain and re-dispose a terminal AudioQueue after a failed dispose status."
        )
        XCTAssertFalse(
            probeSource.contains("if disposeStatus == noErr"),
            "Every probe AudioQueue teardown path must treat dispose as terminal even when Core Audio reports an error."
        )
        XCTAssertTrue(
            measureQueueSource.contains("private var teardownFailed = false")
        )
        XCTAssertTrue(
            measureQueueSource.contains(
                "guard let queue else { return !teardownFailed }"
            )
        )

        let mirrorInputStart = try XCTUnwrap(
            probeSource.range(
                of: "private enum MirrorLoopbackQueueSupport"
            )
        )
        let mirrorRealEnd = try XCTUnwrap(
            probeSource.range(
                of: "private enum MirrorLoopbackFailureBuilder",
                range: mirrorInputStart.upperBound..<probeSource.endIndex
            )
        )
        let mirrorRealSource = probeSource[
            mirrorInputStart.lowerBound..<mirrorRealEnd.lowerBound
        ]
        XCTAssertTrue(mirrorRealSource.contains("AudioQueueNewInput("))
        XCTAssertTrue(mirrorRealSource.contains("AudioQueueNewOutput("))
        XCTAssertTrue(
            mirrorRealSource.contains("MirrorLoopbackPolicy.visibleUID")
        )
        XCTAssertTrue(
            mirrorRealSource.contains("MirrorLoopbackPolicy.hiddenUID")
        )
        XCTAssertTrue(
            mirrorRealSource.contains("kAudioQueueProperty_StreamDescription")
        )
        XCTAssertTrue(
            mirrorRealSource.contains(
                "BlackHoleMeasureCallbackTimestamp(startTime.pointee)"
            )
        )
        XCTAssertTrue(
            mirrorRealSource.contains(
                "MirrorLoopbackRunningState.bothStopped("
            )
        )
        let restartVerifierStart = try XCTUnwrap(
            mirrorRealSource.range(
                of: "private enum MirrorLoopbackRestartVerifier"
            )
        )
        let mirrorRunnerStart = try XCTUnwrap(
            mirrorRealSource.range(
                of: "private enum MirrorLoopbackRealRunner",
                range: (
                    restartVerifierStart.upperBound..<mirrorRealSource.endIndex
                )
            )
        )
        let restartVerifierSource = mirrorRealSource[
            restartVerifierStart.lowerBound..<mirrorRunnerStart.lowerBound
        ]
        let mirrorRunnerSource = mirrorRealSource[
            mirrorRunnerStart.lowerBound..<mirrorRealSource.endIndex
        ]
        XCTAssertTrue(
            restartVerifierSource.contains(
                "let orders = [\"visible-first\", \"hidden-first\"]"
            )
        )
        XCTAssertTrue(
            restartVerifierSource.contains(
                "nonce: nonce + \":restart:\" + $0"
            ),
            "Each complete restart must receive a distinct challenge seed input."
        )
        XCTAssertTrue(
            restartVerifierSource.contains(
                "case \"visible-first\":\n            try input.start()\n            try output.start()"
            )
        )
        XCTAssertTrue(
            restartVerifierSource.contains(
                "case \"hidden-first\":\n            try output.start()\n            try input.start()"
            )
        )
        XCTAssertTrue(
            restartVerifierSource.contains(
                "let queuesStoppedAndDisposed = input.stopStatus == noErr"
            )
        )
        XCTAssertTrue(
            restartVerifierSource.contains(
                "zeroTimestampSeedObservableViaPublicAPI: false"
            )
        )
        XCTAssertTrue(
            restartVerifierSource.contains("seedChangeClaimed: false")
        )
        let inputStart = try XCTUnwrap(
            mirrorRunnerSource.range(of: "try input.start()")
        )
        let inputReady = try XCTUnwrap(
            mirrorRunnerSource.range(
                of: "let inputReadiness = input.readiness()",
                range: inputStart.upperBound..<mirrorRunnerSource.endIndex
            )
        )
        let outputStart = try XCTUnwrap(
            mirrorRunnerSource.range(
                of: "try output.start()",
                range: inputReady.upperBound..<mirrorRunnerSource.endIndex
            )
        )
        XCTAssertLessThan(inputStart.lowerBound, inputReady.lowerBound)
        XCTAssertLessThan(inputReady.lowerBound, outputStart.lowerBound)
        XCTAssertTrue(
            mirrorRealSource.contains("context.fillPrimingSilence(buffer)")
        )
        XCTAssertTrue(mirrorRealSource.contains("context.enableChallenge()"))
        let mirrorQueueStops = mirrorRealSource.components(
            separatedBy: "func stop() {"
        ).dropFirst()
        XCTAssertEqual(
            mirrorQueueStops.count,
            2,
            "The mirror proof must retain one explicit stop path per queue."
        )
        for stopBody in mirrorQueueStops {
            let gateClose = try XCTUnwrap(
                stopBody.range(of: "context.stopAccepting()")
            )
            let queueStop = try XCTUnwrap(
                stopBody.range(of: "AudioQueueStop(queue, true)")
            )
            XCTAssertLessThan(
                gateClose.lowerBound,
                queueStop.lowerBound,
                "Each mirror callback gate must close before AudioQueueStop can deliver a terminal callback."
            )
        }
        XCTAssertTrue(
            mirrorRealSource.contains(
                "defer {\n            output.stop()\n            input.stop()"
            ),
            "Every real-attempt exception path must explicitly drain and dispose both queues."
        )
        XCTAssertTrue(
            mirrorRealSource.contains("defer { _ = defaultGuard.remove() }")
        )
        XCTAssertTrue(
            mirrorRealSource.contains("defer { _ = deviceGuard.remove() }")
        )
        XCTAssertFalse(
            mirrorRealSource.contains("AudioObjectSetPropertyData("),
            "The real mirror gate must never mutate a system default device."
        )
    }

    func testBlackHoleProbeEnforcesSemanticDefaultSafetyAcrossEveryPhase()
        throws {
        let probeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"
            ),
            encoding: .utf8
        )
        let realRunnerStart = try XCTUnwrap(
            probeSource.range(of: "private extension RealRunner")
        )
        let realRunnerEnd = try XCTUnwrap(
            probeSource.range(
                of: "private enum ProbeProgram",
                range: realRunnerStart.upperBound..<probeSource.endIndex
            )
        )
        let realRunner = probeSource[
            realRunnerStart.lowerBound..<realRunnerEnd.lowerBound
        ]

        let baselineSnapshot = try XCTUnwrap(
            realRunner.range(
                of: "let expectedDefaults = try guardObject.snapshot()"
            )
        )
        let baselineSafety = try XCTUnwrap(
            realRunner.range(
                of: "DefaultRouteSafety.failureCode(",
                range: baselineSnapshot.upperBound..<realRunner.endIndex
            )
        )
        let firstQueueOpen = try XCTUnwrap(
            realRunner.range(
                of: "let capture = InputQueueSession(",
                range: baselineSnapshot.upperBound..<realRunner.endIndex
            )
        )
        XCTAssertLessThan(
            baselineSafety.lowerBound,
            firstQueueOpen.lowerBound,
            "The baseline defaults must be rejected before either AudioQueue can open."
        )
        XCTAssertTrue(
            realRunner.contains("RouteContinuityValidator.failureCode("),
            "The live proof loop stopped invoking the production continuity validator."
        )

        let finalSnapshot = try XCTUnwrap(
            realRunner.range(of: "let afterDefaults = try defaultGuard.snapshot()")
        )
        XCTAssertNotNil(
            realRunner.range(
                of: "DefaultRouteSafety.failureCode(",
                range: finalSnapshot.upperBound..<realRunner.endIndex
            ),
            "Final default-route evidence lost its virtual-microphone and legacy-UID safety check."
        )

        let continuityCoreStart = try XCTUnwrap(
            probeSource.range(
                of: "/// Shared by the live probe and deterministic fake sequences."
            )
        )
        let continuityCoreEnd = try XCTUnwrap(
            probeSource.range(
                of: "private enum SyntheticRouteMutation",
                range: continuityCoreStart.upperBound..<probeSource.endIndex
            )
        )
        let continuityCore = probeSource[
            continuityCoreStart.lowerBound..<continuityCoreEnd.lowerBound
        ]
        XCTAssertTrue(
            continuityCore.contains(
                "DefaultRouteSafety.failureCode(\n            observation.defaults"
            ),
            "Continuity observations must reject unsafe defaults even when identity is unchanged."
        )
        XCTAssertTrue(
            probeSource.contains("RouteContinuitySelfTest.failureCode("),
            "The route-mutation fixtures no longer exercise the production validator core."
        )
    }

    func testProductionAppTerminationUsesFreshStructuredPIDIdentity() throws {
        do {
            var repositoryRoot = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 {
                repositoryRoot.deleteLastPathComponent()
            }
            let driverURL = repositoryRoot
                .appendingPathComponent("iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh")
            let driverSource = try String(contentsOf: driverURL, encoding: .utf8)
            guard
                let functionStart = driverSource.range(
                    of: "function validate_production_app_termination_json() {"
                ),
                let nextFunction = driverSource.range(
                    of: "\nfunction write_production_app_termination_evidence() {",
                    range: functionStart.upperBound..<driverSource.endIndex
                )
            else {
                XCTFail("termination validator function not found")
                return
            }

            let functionSource = String(
                driverSource[functionStart.lowerBound..<nextFunction.lowerBound]
            )
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "opensteamer-termination-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }

            let runnerURL = temporaryDirectory.appendingPathComponent("validate.zsh")
            try """
            set -eu
            EXPECTED_APP_BUNDLE_IDENTIFIER=com.elamin.opensteamer
            \(functionSource)
            validate_production_app_termination_json "$1" "$2"
            """.write(to: runnerURL, atomically: true, encoding: .utf8)

            let fixtures: [(name: String, json: String, shouldPass: Bool)] = [
                ("same-object", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"}}}"#, true),
                ("empty-result", #"{"info":{"outcome":"success"},"result":{}}"#, false),
                ("pid-only", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242}}}"#, false),
                ("bundle-only", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"bundleIdentifier":"com.elamin.opensteamer"}}}"#, false),
                ("split-identity", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242},{"bundleIdentifier":"com.elamin.opensteamer"}]}}"#, false),
                ("malformed", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":"4242","bundleIdentifier":17}}}"#, false),
                ("conflicting-pid-alias", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242,"pid":4243,"bundleIdentifier":"com.elamin.opensteamer"}}}"#, false),
                ("conflicting-bundle-alias", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer","bundleID":"com.elamin.NotAudioStreamer"}}}"#, false),
                ("malformed-secondary-pid-alias", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242,"pid":"4242","bundleIdentifier":"com.elamin.opensteamer"}}}"#, false),
                ("malformed-secondary-bundle-alias", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer","bundleID":17}}}"#, false),
                ("exact-plus-conflicting-candidate", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"},{"processIdentifier":4242,"pid":4243,"bundleIdentifier":"com.elamin.opensteamer"}]}}"#, false),
                ("exact-target-plus-wrong-bundle", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"},{"processIdentifier":4242,"bundleIdentifier":"com.example.Helper"}]}}"#, false),
                ("exact-target-plus-wrong-pid", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"},{"processIdentifier":777,"bundleIdentifier":"com.elamin.opensteamer"}]}}"#, false),
                ("exact-target-plus-pid-only", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"},{"processIdentifier":4242}]}}"#, false),
                ("exact-target-plus-bundle-only", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"},{"bundleIdentifier":"com.elamin.opensteamer"}]}}"#, false),
                ("unrelated-record", #"{"info":{"outcome":"success"},"result":{"records":[{"processIdentifier":4242,"bundleIdentifier":"com.elamin.opensteamer"},{"processIdentifier":777,"bundleIdentifier":"com.example.Helper"}]}}"#, true),
                ("wrong-pid", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4243,"bundleIdentifier":"com.elamin.opensteamer"}}}"#, false),
                ("wrong-bundle", #"{"info":{"outcome":"success"},"result":{"terminationResult":{"processIdentifier":4242,"bundleIdentifier":"com.elamin.NotAudioStreamer"}}}"#, false),
            ]

            for fixture in fixtures {
                let fixtureURL = temporaryDirectory.appendingPathComponent("\(fixture.name).json")
                try fixture.json.write(to: fixtureURL, atomically: true, encoding: .utf8)

                let process = Process()
                let diagnostics = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [runnerURL.path, fixtureURL.path, "4242"]
                process.standardOutput = diagnostics
                process.standardError = diagnostics
                try process.run()
                process.waitUntilExit()
                let output = String(
                    data: diagnostics.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if fixture.shouldPass {
                    XCTAssertEqual(
                        process.terminationStatus,
                        0,
                        "\(fixture.name) should pass: \(output)"
                    )
                } else {
                    XCTAssertNotEqual(
                        process.terminationStatus,
                        0,
                        "\(fixture.name) should fail"
                    )
                }
            }

            let inventoryFunctionStart = try XCTUnwrap(
                driverSource.range(of: "function production_app_pid_from_process_json() {")
            )
            let inventoryFunctionEnd = try XCTUnwrap(
                driverSource.range(
                    of: "\nfunction ",
                    range: inventoryFunctionStart.upperBound..<driverSource.endIndex
                )
            )
            let inventoryFunctionSource = String(
                driverSource[inventoryFunctionStart.lowerBound..<inventoryFunctionEnd.lowerBound]
            )
            let inventoryRunnerURL = temporaryDirectory.appendingPathComponent("inventory.zsh")
            try """
            set -u
            EXPECTED_APP_BUNDLE_IDENTIFIER=com.elamin.opensteamer
            \(inventoryFunctionSource)
            if ! result=$(production_app_pid_from_process_json "$1" "$2"); then
              exit 1
            fi
            print -r -- "${result}" > "$3"
            print -r -- "${result}"
            """.write(to: inventoryRunnerURL, atomically: true, encoding: .utf8)

            let candidateURL = temporaryDirectory.appendingPathComponent("candidate.json")
            try #"{"bundleIdentifier":"com.elamin.opensteamer","bundleURL":"file:///Applications/opensteamer.app"}"#.write(to: candidateURL, atomically: true, encoding: .utf8)
            let emptyResult = #"{"info":{"outcome":"success"},"result":{}}"#
            let missingCollection = #"{"info":{"outcome":"success"},"result":{"devices":[{"identifier":"device","applications":[]}]}}"#
            let inventoryFixtures: [(name: String, json: String, shouldPass: Bool)] = [
                ("valid-empty-process-collection", #"{"info":{"outcome":"success"},"result":{"devices":[{"processes":[]}]}}"#, true),
                ("well-formed-unrelated-process", #"{"info":{"outcome":"success"},"result":{"devices":[{"processes":[{"processIdentifier":777,"bundleIdentifier":"com.example.Helper","name":"Helper","executable":"/Applications/Helper.app/Helper"}]}]}}"#, true),
                ("initial-empty-result", emptyResult, false),
                ("initial-missing-collection", missingCollection, false),
                ("post-termination-empty-result", emptyResult, false),
                ("post-termination-missing-collection", missingCollection, false),
            ]

            for fixture in inventoryFixtures {
                let inventoryURL = temporaryDirectory.appendingPathComponent("\(fixture.name).json")
                let evidenceURL = temporaryDirectory.appendingPathComponent("\(fixture.name)-termination-evidence.txt")
                try fixture.json.write(to: inventoryURL, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: evidenceURL)

                let process = Process()
                let diagnostics = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [inventoryRunnerURL.path, inventoryURL.path, candidateURL.path, evidenceURL.path]
                process.standardOutput = diagnostics
                process.standardError = diagnostics
                try process.run()
                process.waitUntilExit()
                let output = String(
                    data: diagnostics.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if fixture.shouldPass {
                    XCTAssertEqual(process.terminationStatus, 0, "\(fixture.name) should pass: \(output)")
                    let evidence = try String(contentsOf: evidenceURL, encoding: .utf8)
                    XCTAssertEqual(evidence.trimmingCharacters(in: .whitespacesAndNewlines), "absent")
                } else {
                    XCTAssertNotEqual(process.terminationStatus, 0, "\(fixture.name) should fail")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
                }
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-app-termination-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func writeJSON(_ object: Any, name: String) throws -> URL {
            let output = root.appendingPathComponent(
                "\(name)-\(UUID().uuidString).json"
            )
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: output)
            return output
        }

        let candidate = try writeJSON(
            [
                "bundleIdentifier": "com.elamin.opensteamer",
                "bundleVersion": SyntheticPhysicalDevice.expectedBuild,
                "name": "opensteamer",
                "url":
                    "file:///private/var/containers/Bundle/Application/" +
                    "SYNTHETIC/opensteamer.app/",
            ],
            name: "candidate"
        )
        let running = try writeJSON(
            [
                "info": ["outcome": "success"],
                "result": [
                    "runningProcesses": [
                        [
                            "processIdentifier": 4_242,
                            "bundleIdentifier": "com.elamin.opensteamer",
                            "name": "opensteamer",
                            "executable":
                                "file:///private/var/containers/Bundle/Application/" +
                                "SYNTHETIC/opensteamer.app/opensteamer",
                        ],
                    ],
                ],
            ],
            name: "running"
        )
        let absent = try writeJSON(
            [
                "info": ["outcome": "success"],
                "result": [
                    "runningProcesses": [
                        [
                            "processIdentifier": 5_001,
                            "bundleIdentifier": "com.example.Other",
                            "name": "Other",
                            "executable": "file:///private/Other.app/Other",
                        ],
                    ],
                ],
            ],
            name: "absent"
        )
        let malformed = try writeJSON(
            [
                "info": ["outcome": "success"],
                "result": [
                    "runningProcesses": [
                        [
                            "processIdentifier": "not-a-pid",
                            "bundleIdentifier": "com.elamin.opensteamer",
                            "name": "opensteamer",
                        ],
                    ],
                ],
            ],
            name: "malformed"
        )
        let ambiguous = try writeJSON(
            [
                "info": ["outcome": "success"],
                "result": [
                    "runningProcesses": [
                        [
                            "processIdentifier": 4_242,
                            "bundleIdentifier": "com.elamin.opensteamer",
                            "name": "opensteamer",
                        ],
                        [
                            "processIdentifier": 4_243,
                            "bundleIdentifier": "com.elamin.opensteamer",
                            "name": "opensteamer",
                        ],
                    ],
                ],
            ],
            name: "ambiguous"
        )
        let wrongBundle = try writeJSON(
            [
                "info": ["outcome": "success"],
                "result": [
                    "runningProcesses": [
                        [
                            "processIdentifier": 4_242,
                            "bundleIdentifier": "com.example.Wrong",
                            "name": "opensteamer",
                            "executable":
                                "file:///private/var/containers/Bundle/Application/" +
                                "SYNTHETIC/opensteamer.app/opensteamer",
                        ],
                    ],
                ],
            ],
            name: "wrong-bundle"
        )
        let termination = try writeJSON(
            [
                "info": ["outcome": "success"],
                "result": [
                    "processIdentifier": 4_242,
                    "bundleIdentifier": "com.elamin.opensteamer",
                ],
            ],
            name: "termination"
        )

        let cases: [(String, URL, Bool)] = [
            ("production-app-termination-running", running, true),
            ("production-app-termination-absent", absent, true),
            ("production-app-termination-malformed", malformed, false),
            ("production-app-termination-ambiguous", ambiguous, false),
            ("production-app-termination-wrong-bundle", wrongBundle, false),
            ("production-app-termination-stale-json", running, false),
            ("production-app-termination-termination-failure", running, false),
        ]
        for (mode, initial, shouldPass) in cases {
            let artifactDirectory = root.appendingPathComponent(
                "artifact-\(mode)-\(UUID().uuidString)"
            )
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 5,
                additionalEnvironment: [
                    "OPENSTEAMER_SELF_TEST_APP_CANDIDATE_JSON": candidate.path,
                    "OPENSTEAMER_SELF_TEST_APP_PROCESS_INITIAL_JSON": initial.path,
                    "OPENSTEAMER_SELF_TEST_APP_PROCESS_AFTER_JSON": absent.path,
                    "OPENSTEAMER_SELF_TEST_APP_TERMINATION_JSON": termination.path,
                    "OPENSTEAMER_SELF_TEST_EXPECTED_APP_PID": "4242",
                ]
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            if shouldPass {
                XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
                let evidence = try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "phase-3-real-call/production-app-termination.txt"
                    ),
                    encoding: .utf8
                )
                XCTAssertTrue(
                    evidence.contains(
                        mode.hasSuffix("absent")
                            ? "state=already-terminated"
                            : "state=terminated"
                    ),
                    evidence
                )
                XCTAssertFalse(
                    evidence.contains(SyntheticPhysicalDevice.coreDeviceIdentifier)
                )
                XCTAssertFalse(
                    evidence.contains(SyntheticPhysicalDevice.hardwareUDID)
                )
                if !mode.hasSuffix("absent") {
                    XCTAssertTrue(evidence.contains("pid=4242"), evidence)
                    XCTAssertTrue(
                        evidence.contains(
                            "termination=structured-devicectl-json-by-pid"
                        ),
                        evidence
                    )
                }
            } else {
                XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: artifactDirectory.appendingPathComponent(
                            "phase-3-real-call/production-app-termination.txt"
                        ).path
                    )
                )
                XCTAssertEqual(
                    try String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "run-status.txt"
                        ),
                        encoding: .utf8
                    ),
                    "status=failed\n"
                )
            }
        }
    }

    func testReconnectDriverProbeLifecycleIsIndependentAndBounded() throws {
        for mode in [
            "blackhole-probe-exit-failure",
            "blackhole-probe-timeout",
            "blackhole-probe-group-cleanup",
        ] {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 15
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            let runStatus = try String(
                contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
                encoding: .utf8
            )
            XCTAssertEqual(runStatus, "status=self-test-passed\n")
            if let text = try? String(
                contentsOf: artifactDirectory.appendingPathComponent(
                    "blackhole-probe-leader-pid.txt"
                ),
                encoding: .utf8
            ),
               let pid = pid_t(
                   text.trimmingCharacters(in: .whitespacesAndNewlines)
               ) {
                XCTAssertTrue(waitForPIDToDisappear(pid, timeout: 2))
            }
        }
    }

    func testReconnectDriverHasOrderedPhaseArtifactsAndDeletesStaleEvidence() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-phase-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let stalePaths = [
            "phase-1-raw-blackhole/DerivedData/stale.txt",
            "phase-1-raw-blackhole/summary.json",
            "phase-2-reconnect/DerivedData/stale.txt",
            "phase-2-reconnect/activities.json",
            "phase-3-real-call/DerivedData/stale.txt",
            "phase-3-real-call/build-results.json",
            "DerivedData/legacy-stale.txt",
            "production-build-self-test-build-paired-reconnect.xcresult/stale.txt",
        ]
        for path in stalePaths {
            let url = artifactDirectory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stale".utf8).write(to: url)
        }

        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "phase-order",
            artifactDirectory: artifactDirectory,
            timeout: 5
        )
        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        let events = try String(
            contentsOf: artifactDirectory.appendingPathComponent("phase-order.log"),
            encoding: .utf8
        )
        XCTAssertEqual(
            events,
            """
            phase=1 name=raw-iphone-microphone-virtual-microphone state=started
            phase=1 name=raw-iphone-microphone-virtual-microphone state=passed
            phase=2 name=reconnect-background-screen state=started
            phase=2 name=reconnect-background-screen state=passed
            phase=3 name=real-connected-call state=started
            phase=3 name=real-connected-call state=passed

            """
        )
        for path in [
            "phase-1-raw-blackhole/phase-status.txt",
            "phase-2-reconnect/phase-status.txt",
            "phase-3-real-call/phase-status.txt",
        ] {
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(path),
                    encoding: .utf8
                ),
                "status=passed\n"
            )
        }
        for path in stalePaths {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: artifactDirectory.appendingPathComponent(path).path
                ),
                "Stale phase artifact survived: \(path)"
            )
        }
    }

    func testEveryPhaseFailureLeavesFinalRunStatusFailed() throws {
        let cases: [(String, Int32, [String], String)] = [
            (
                "phase-failure-raw",
                11,
                [],
                "phase-1-raw-blackhole/phase-status.txt"
            ),
            (
                "phase-failure-reconnect",
                12,
                ["phase-1-raw-blackhole/phase-status.txt"],
                "phase-2-reconnect/phase-status.txt"
            ),
            (
                "phase-failure-call",
                13,
                [
                    "phase-1-raw-blackhole/phase-status.txt",
                    "phase-2-reconnect/phase-status.txt",
                ],
                "phase-3-real-call/phase-status.txt"
            ),
        ]
        for (mode, expectedStatus, passedPhases, failedPhase) in cases {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 5
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, expectedStatus, result.diagnostic)
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "run-status.txt"
                    ),
                    encoding: .utf8
                ),
                "status=failed\n"
            )
            for path in passedPhases {
                XCTAssertEqual(
                    try String(
                        contentsOf: artifactDirectory.appendingPathComponent(path),
                        encoding: .utf8
                    ),
                    "status=passed\n"
                )
            }
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(failedPhase),
                    encoding: .utf8
                ),
                "status=failed\n"
            )
        }
    }

    func testCriticalConditionalFailuresRemainNonzeroAndPublishFailedStatus() throws {
        let cases: [(String, String)] = [
            ("critical-failure-xcresult-summary", "phase-1-raw-blackhole/phase-status.txt"),
            ("critical-failure-xcresult-tests", "phase-1-raw-blackhole/phase-status.txt"),
            (
                "critical-failure-xcresult-build-results",
                "phase-1-raw-blackhole/phase-status.txt"
            ),
            (
                "critical-failure-xcresult-activities",
                "phase-1-raw-blackhole/phase-status.txt"
            ),
            (
                "critical-failure-unchanged-candidate",
                "phase-1-raw-blackhole/phase-status.txt"
            ),
            ("critical-failure-lock-proof", "phase-1-raw-blackhole/phase-status.txt"),
            (
                "critical-failure-simple-ui-isolation",
                "phase-1-raw-blackhole/phase-status.txt"
            ),
            ("critical-failure-raw-phase", "phase-1-raw-blackhole/phase-status.txt"),
            ("critical-failure-call-phase", "phase-3-real-call/phase-status.txt"),
        ]
        for (mode, phaseStatusPath) in cases {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 5
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        phaseStatusPath
                    ),
                    encoding: .utf8
                ),
                "status=failed\n"
            )
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "run-status.txt"
                    ),
                    encoding: .utf8
                ),
                "status=failed\n"
            )
        }
    }

    func testCallReadyAcknowledgementIsFreshBoundedAndOrdered() throws {
        for mode in [
            "call-ready-success",
            "call-ready-timeout",
            "call-ready-stale",
            "call-ready-late-after-query",
            "call-ready-late-after-read",
        ] {
            let artifactDirectory = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 5
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            let events = try String(
                contentsOf: artifactDirectory.appendingPathComponent("phase-order.log"),
                encoding: .utf8
            )
            let termination = try XCTUnwrap(
                events.range(of: "phase=3 event=production-app-terminated")
            )
            let request = try XCTUnwrap(
                events.range(of: "phase=3 event=call-ready-requested")
            )
            XCTAssertLessThan(termination.lowerBound, request.lowerBound)
            if mode == "call-ready-success" {
                let accepted = try XCTUnwrap(
                    events.range(of: "phase=3 event=call-ready-accepted")
                )
                XCTAssertLessThan(request.lowerBound, accepted.lowerBound)
                XCTAssertEqual(
                    try String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "phase-3-real-call/call-ready-status.txt"
                        ),
                        encoding: .utf8
                    ),
                    "state=accepted\n"
                )
            } else {
                XCTAssertEqual(
                    try String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "phase-3-real-call/call-ready-status.txt"
                        ),
                        encoding: .utf8
                    ),
                    "state=timed-out\n"
                )
            }
        }
    }

    func testCallEndAcknowledgementIsFreshBoundedAndAfterConnectedProof() throws {
        for mode in [
            "call-end-success",
            "call-end-timeout",
            "call-end-stale",
            "call-end-late-after-query",
            "call-end-late-after-read",
        ] {
            let artifactDirectory = URL(
                fileURLWithPath:
                    "/Volumes/t7/opensteamer-\(mode)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 5
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            let events = try String(
                contentsOf: artifactDirectory.appendingPathComponent("phase-order.log"),
                encoding: .utf8
            )
            let connectedProof = try XCTUnwrap(
                events.range(of: "phase=3 event=connected-call-proof-observed")
            )
            let request = try XCTUnwrap(
                events.range(of: "phase=3 event=call-end-requested")
            )
            XCTAssertLessThan(connectedProof.lowerBound, request.lowerBound)
            let status = try String(
                contentsOf: artifactDirectory.appendingPathComponent(
                    "phase-3-real-call/call-end-status.txt"
                ),
                encoding: .utf8
            )
            if mode == "call-end-success" {
                let accepted = try XCTUnwrap(
                    events.range(of: "phase=3 event=call-end-accepted")
                )
                XCTAssertLessThan(request.lowerBound, accepted.lowerBound)
                XCTAssertEqual(status, "state=accepted\n")
            } else {
                XCTAssertEqual(status, "state=timed-out\n")
            }
            if mode == "call-end-stale" {
                XCTAssertEqual(
                    try String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "phase-3-real-call/call-end-stale-acknowledgement.txt"
                        ),
                        encoding: .utf8
                    ),
                    "state=discarded-before-request\n"
                )
            }
        }
    }

    func testInCallAcousticAcknowledgementIsFreshBoundedAndDistinct() throws {
        for mode in [
            "call-acoustic-success",
            "call-acoustic-timeout",
            "call-acoustic-stale",
            "call-acoustic-late-after-query",
            "call-acoustic-late-after-read",
        ] {
            let artifactDirectory = URL(
                fileURLWithPath:
                    "/Volumes/t7/opensteamer-\(mode)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 5
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            let events = try String(
                contentsOf: artifactDirectory.appendingPathComponent("phase-order.log"),
                encoding: .utf8
            )
            let request = try XCTUnwrap(
                events.range(of: "phase=3 event=call-acoustic-requested")
            )
            let status = try String(
                contentsOf: artifactDirectory.appendingPathComponent(
                    "phase-3-real-call/call-acoustic-status.txt"
                ),
                encoding: .utf8
            )
            if mode == "call-acoustic-success" {
                let accepted = try XCTUnwrap(
                    events.range(of: "phase=3 event=call-acoustic-accepted")
                )
                XCTAssertLessThan(request.lowerBound, accepted.lowerBound)
                let acceptedLines = status.split(separator: "\n").map(String.init)
                XCTAssertEqual(acceptedLines.count, 6)
                XCTAssertEqual(
                    Array(acceptedLines.prefix(5)),
                    [
                        "schema=opensteamer.call-acoustic-acknowledgement.v2",
                        "nonce=self-test-call-acoustic-nonce",
                        "sequence=1",
                        "token=self-test-call-acoustic-token",
                        "state=accepted",
                    ]
                )
                let acceptedAtPrefix = "acceptedAtMonotonicNs="
                let acceptedAt = try XCTUnwrap(acceptedLines.last)
                XCTAssertTrue(acceptedAt.hasPrefix(acceptedAtPrefix))
                XCTAssertGreaterThan(
                    UInt64(acceptedAt.dropFirst(acceptedAtPrefix.count)) ?? 0,
                    0
                )
            } else {
                XCTAssertEqual(status, "state=timed-out\n")
            }
            if mode == "call-acoustic-stale" {
                XCTAssertEqual(
                    try String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "phase-3-real-call/call-acoustic-stale-acknowledgement.txt"
                        ),
                        encoding: .utf8
                    ),
                    "state=discarded-before-request\n"
                )
            }
        }
    }

    func testHostDeploymentVerifierReceivesExactGenerationContract() throws {
        for mode in [
            "host-deployment-contract-success",
            "host-deployment-contract-missing",
        ] {
            let artifactDirectory = URL(
                fileURLWithPath:
                    "/Volumes/t7/opensteamer-\(mode)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 8
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            let manifest = try String(
                contentsOf: artifactDirectory.appendingPathComponent(
                    "host-deployment.txt"
                ),
                encoding: .utf8
            )
            if mode.hasSuffix("success") {
                XCTAssertTrue(manifest.contains("verifier-invoked=true"), manifest)
                XCTAssertTrue(manifest.contains("argc=12"), manifest)
                XCTAssertTrue(
                    manifest.contains(
                        "arg1=\(artifactDirectory.path)/fresh-staged.app"
                    ),
                    manifest
                )
                XCTAssertTrue(
                    manifest.contains(
                        "arg2=\(artifactDirectory.path)/offline-legacy-reference"
                    ),
                    manifest
                )
                XCTAssertTrue(
                    manifest.contains(
                        "arg3=\(artifactDirectory.path)/reviewed-launch-agent.plist"
                    ),
                    manifest
                )
                for expected in [
                    "arg4=123",
                    "arg5=456",
                    "arg6=789",
                    "arg7=4242",
                    "arg8=7",
                    "arg9=Mon Aug  3 12:34:56 2026",
                    "arg10=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "arg11=111",
                    "arg12=222",
                ] {
                    XCTAssertTrue(manifest.contains(expected), manifest)
                }
                XCTAssertTrue(manifest.contains("controller=/Volumes/t7/"), manifest)
            } else {
                XCTAssertFalse(manifest.contains("verifier-invoked=true"), manifest)
                let verifierError = try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "host-deployment-stderr.txt"
                    ),
                    encoding: .utf8
                )
                XCTAssertTrue(
                    verifierError.contains(
                        "generation inputs are incomplete or unsafe"
                    ),
                    verifierError
                )
            }
        }
    }

    func testCallPhaseEnforcesStableHostAndPriorPhaseQuiescence() throws {
        for mode in [
            "call-stable-host-pass",
            "call-stable-host-mismatch",
            "call-phase-quiescence-clean",
            "call-phase-quiescence-leak-probe",
            "call-phase-quiescence-leak-screen",
            "call-phase-quiescence-leak-host-watcher",
            "call-phase-quiescence-leak-reconnect-tone",
            "call-phase-quiescence-leak-xcodebuild",
            "call-phase-quiescence-leak-churn-lock",
            "call-phase-quiescence-leak-surviving-child",
        ] {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 8
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        }
    }

    func testDriverSourceOrdersAppTerminationAcknowledgementToneAndCallXcodebuild() throws {
        let driver = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh"
            ),
            encoding: .utf8
        )
        let rawPhase = try XCTUnwrap(
            driver.range(of: "run_raw_microphone_blackhole_phase")
        )
        let reconnectPhase = try XCTUnwrap(
            driver.range(
                of: "begin_phase 2 reconnect-background-screen",
                range: rawPhase.upperBound..<driver.endIndex
            )
        )
        let callPhase = try XCTUnwrap(
            driver.range(
                of: "run_real_connected_call_phase",
                range: reconnectPhase.upperBound..<driver.endIndex
            )
        )
        XCTAssertLessThan(rawPhase.lowerBound, reconnectPhase.lowerBound)
        XCTAssertLessThan(reconnectPhase.lowerBound, callPhase.lowerBound)

        let callFunctionStart = try XCTUnwrap(
            driver.range(of: "function run_real_connected_call_phase()")
        )
        let callFunctionEnd = try XCTUnwrap(
            driver.range(
                of: "\n}\n\n# Read, authenticate",
                range: callFunctionStart.upperBound..<driver.endIndex
            )
        )
        let callFunction = driver[
            callFunctionStart.lowerBound..<callFunctionEnd.upperBound
        ]
        let orderedTokens = [
            "require_phase_three_quiescence",
            "terminate_production_app_for_call_phase",
            "wait_for_fresh_call_ready_acknowledgement",
            "start_physical_audio_oracle_tone",
            "configure_post_call_raw_contract",
            "run_simple_physical_ui_test",
            "run_real_call_operator_and_post_call_probe",
            "validate_blackhole_probe_json",
            "validate_default_input_lifecycle_json",
            "validate_ui_xcresult",
            "validate_post_call_raw_generation_evidence",
            "validate_and_retain_raw_overlap_evidence",
        ]
        var remaining = callFunction[...]
        for token in orderedTokens {
            let range = try XCTUnwrap(remaining.range(of: token))
            remaining = remaining[range.upperBound...]
        }
        XCTAssertTrue(
            driver.contains(
                "testProductionRawIPhoneMicrophoneOracleSustainsRollingContinuity"
            )
        )
        XCTAssertTrue(
            driver.contains(
                "testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing"
            )
        )
        XCTAssertTrue(
            driver.contains(
                "testRealConnectedCallRecoveryRotatesOrdinaryAudioPolicyAndRequiresFreshProof"
            )
        )

        let operatorHookStart = try XCTUnwrap(
            driver.range(of: "function run_real_call_operator_and_post_call_probe()")
        )
        let operatorHookEnd = try XCTUnwrap(
            driver.range(
                of: "\n}\n\nfunction validate_post_call_raw_generation_evidence()",
                range: operatorHookStart.upperBound..<driver.endIndex
            )
        )
        let operatorHook = driver[
            operatorHookStart.lowerBound..<operatorHookEnd.upperBound
        ]
        var remainingHook = operatorHook[...]
        for token in [
            "wait_for_nonce_bound_call_ui_hosted_state",
            "wait_for_fresh_call_acoustic_acknowledgement",
            "wait_for_nonce_bound_call_ui_hosted_state",
            "capture_default_input_snapshot",
            "wait_for_fresh_call_end_acknowledgement",
            "wait_for_fresh_raw_session_readiness_and_start_probe",
        ] {
            let range = try XCTUnwrap(remainingHook.range(of: token))
            remainingHook = remainingHook[range.upperBound...]
        }
        XCTAssertTrue(
            callFunction.contains(
                "\"${RAW_PROBE_COMPLETION_OBSERVATION}\" \\\n    arm_post_call_raw_readiness"
            ),
            "The post-call Mac lower bound must be a pre-XCTest-start hook."
        )
        XCTAssertTrue(
            operatorHook.contains(
                "POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS"
            )
        )
        let simpleStart = try XCTUnwrap(
            driver.range(of: "function run_simple_physical_ui_test()")
        )
        let simpleEnd = try XCTUnwrap(
            driver.range(
                of: "\n}\n\nfunction require_phase_three_quiescence()",
                range: simpleStart.upperBound..<driver.endIndex
            )
        )
        let simpleFunction = driver[simpleStart.lowerBound..<simpleEnd.lowerBound]
        let watchdogStarted = try XCTUnwrap(
            simpleFunction.range(of: "XCODEBUILD_WATCHDOG_PID=$!")
        )
        let afterHook = try XCTUnwrap(
            simpleFunction.range(
                of: "if [[ -n \"${after_start_hook}\" ]]",
                range: watchdogStarted.upperBound..<simpleFunction.endIndex
            )
        )
        XCTAssertLessThan(watchdogStarted.lowerBound, afterHook.lowerBound)
        XCTAssertTrue(callFunction.contains("RAW_PROBE_COMPLETION_OBSERVATION"))
        XCTAssertTrue(callFunction.contains("CALL_ACOUSTIC_STATUS"))
    }

    func testRealCallXCTestRequiresPostCallMicGenerationAndDriverOverlap() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/UITests/PairedReconnectPhysicalUITests.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(
                of: "func testRealConnectedCallRecoveryRotatesOrdinaryAudioPolicyAndRequiresFreshProof()"
            )
        )
        let end = try XCTUnwrap(
            source.range(
                of: "func testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing()",
                range: start.upperBound..<source.endIndex
            )
        )
        let callTest = source[start.lowerBound..<end.lowerBound]
        let hostedMarker = try XCTUnwrap(
            callTest.range(of: "sequence: 1")
        )
        let hostedMarkerGuard = try XCTUnwrap(
            callTest.range(of: "let hostedMarkerRawMicrophone")
        )
        let recoveryWait = try XCTUnwrap(
            callTest.range(of: "waitForFreshPostCallOrdinaryPlayback")
        )
        XCTAssertLessThan(
            hostedMarkerGuard.lowerBound,
            hostedMarker.lowerBound
        )
        XCTAssertLessThan(hostedMarker.lowerBound, recoveryWait.lowerBound)
        let acknowledgementWait = try XCTUnwrap(
            callTest.range(
                of: "waitForAcceptedAcousticAcknowledgementWhileHosted",
                range: hostedMarker.upperBound..<callTest.endIndex
            )
        )
        let postAcknowledgementMarker = try XCTUnwrap(
            callTest.range(
                of: "sequence: 2",
                range: acknowledgementWait.upperBound..<callTest.endIndex
            )
        )
        XCTAssertLessThan(
            hostedMarker.lowerBound,
            acknowledgementWait.lowerBound
        )
        XCTAssertLessThan(
            acknowledgementWait.lowerBound,
            postAcknowledgementMarker.lowerBound
        )
        XCTAssertLessThan(
            postAcknowledgementMarker.lowerBound,
            recoveryWait.lowerBound
        )
        let hostedMarkerGuardSource = callTest[
            hostedMarkerGuard.lowerBound..<hostedMarker.lowerBound
        ]
        for token in [
            "presentationValue == \"active\"",
            "!hasConnectionError",
            "worldwideSessionState",
            "worldwideAudioState",
            "Playing — iPhone call may reduce quality",
            "worldwideMicrophoneState",
            "Muted — iPhone call active",
            "!hostedMarkerRawMicrophone.exists",
            "interruption.finalSnapshot.sessionGeneration",
            "startup.finalSnapshot.sessionGeneration",
            "acceptedRouteValues.contains(interruption.route)",
            "return",
        ] {
            XCTAssertTrue(
                hostedMarkerGuardSource.contains(token),
                "Hosted-state causal marker guard is missing \(token)."
            )
        }
        var remaining = callTest[...]
        for token in [
            "waitForFreshPostCallOrdinaryPlayback",
            "\"On\"",
            "waitForStableRawIPhoneMicrophone",
            "stableFor: postCallRawContinuityDuration",
            "recordingGeneration",
            "Post-call raw iPhone microphone runtime overlap evidence",
            "Post-call raw microphone generation evidence",
            "disconnectWorldwide",
        ] {
            let range = try XCTUnwrap(remaining.range(of: token))
            remaining = remaining[range.upperBound...]
        }
        XCTAssertTrue(
            callTest.contains("OPENSTEAMER_POST_CALL_RAW_CONTINUITY_PROOF_NONCE")
        )
        XCTAssertTrue(
            callTest.contains("OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS")
        )
        XCTAssertTrue(
            callTest.contains("OPENSTEAMER_POST_CALL_RAW_UI_TIMEOUT_SECONDS")
        )
        XCTAssertTrue(callTest.contains("timeout: postCallRawTimeoutDuration"))
        XCTAssertTrue(
            callTest.contains("recovered.ordinaryAudioPolicyGeneration")
        )
        XCTAssertTrue(
            callTest.contains("approvedRecordingGeneration")
        )
        for token in [
            "ordinary playback cannot satisfy the in-call acknowledgement",
            "snapshotAtAcceptance",
            "opensteamer.call-acoustic-acknowledgement.v2",
            "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2",
        ] {
            XCTAssertTrue(
                source.contains(token),
                "Two-stage hosted acoustic handshake is missing \(token)."
            )
        }
    }

    func testRawPhysicalUIOracleOverlapsExternalProbeForAtLeastSixSeconds() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opensteamer-raw-overlap-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let runtimeResult = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "raw-readiness-success",
            artifactDirectory: artifactDirectory,
            timeout: 8
        )
        XCTAssertTrue(runtimeResult.exitedWithinDeadline, runtimeResult.diagnostic)
        XCTAssertEqual(
            runtimeResult.terminationStatus,
            0,
            runtimeResult.diagnostic
        )
        let bounds = try String(
            contentsOf: artifactDirectory.appendingPathComponent(
                "phase-1-raw-blackhole/raw-ui-host-bounds.txt"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(bounds.contains("latestPossibleUIStartNs=7000000000"))
        XCTAssertTrue(bounds.contains("earliestPossibleUIEndNs=31000000000"))
        let interval = try String(
            contentsOf: artifactDirectory.appendingPathComponent(
                "phase-1-raw-blackhole/physical-blackhole-proof-interval.txt"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(interval.contains("durationNs=6000000000"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifactDirectory.appendingPathComponent(
                    "phase-1-raw-blackhole/physical-blackhole-microphone-overlap.txt"
                ).path
            )
        )

        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/UITests/PairedReconnectPhysicalUITests.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(
                of: "func testProductionRawIPhoneMicrophoneOracleSustainsRollingContinuity()"
            )
        )
        let end = try XCTUnwrap(
            source.range(
                of: "func testRealConnectedCallRecoveryRotatesOrdinaryAudioPolicyAndRequiresFreshProof()",
                range: start.upperBound..<source.endIndex
            )
        )
        let rawTest = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(rawTest.contains("stableFor: 30"))
        XCTAssertFalse(rawTest.contains("stableFor: 2"))
        XCTAssertTrue(rawTest.contains("OPENSTEAMER_RAW_CONTINUITY_PROOF_NONCE"))
        XCTAssertTrue(rawTest.contains("continuityDurationNs"))
        XCTAssertFalse(source.contains("app.processID"))
        XCTAssertTrue(source.contains("current.applicationProcessIdentifier"))
        XCTAssertFalse(rawTest.contains("timeIntervalSince1970"))
        XCTAssertTrue(rawTest.contains("Production raw iPhone microphone runtime overlap evidence"))
        XCTAssertTrue(rawTest.contains("opensteamer.raw-ui-continuity.v1"))
        XCTAssertTrue(rawTest.contains("OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1"))
        XCTAssertTrue(rawTest.contains("OPENSTEAMER_RAW_UI_TEARDOWN_BEGIN_V1"))

        let productionOracleSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/Sources/Diagnostics/WorldwidePhysicalOracles.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            productionOracleSource.contains(
                "ProcessInfo.processInfo.processIdentifier"
            )
        )
        XCTAssertTrue(
            productionOracleSource.contains(
                "fields.append(\"pid=\\(applicationProcessIdentifier)\")"
            )
        )
        let parserSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/OracleTestSupport/PhysicalOracleEvaluator.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(parserSource.contains("let applicationProcessIdentifier: Int32"))
        XCTAssertTrue(parserSource.contains("let processIdentifier = Int32(processIdentifierText)"))

        let driver = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh"
            ),
            encoding: .utf8
        )
        let rawFunctionStart = try XCTUnwrap(
            driver.range(of: "function run_raw_microphone_blackhole_phase()")
        )
        let rawFunctionEnd = try XCTUnwrap(
            driver.range(
                of: "\n}\n\nfunction run_real_connected_call_phase()",
                range: rawFunctionStart.upperBound..<driver.endIndex
            )
        )
        let rawFunction = driver[
            rawFunctionStart.lowerBound..<rawFunctionEnd.upperBound
        ]
        let preparation = try XCTUnwrap(
            rawFunction.range(of: "prepare_raw_physical_ui_test")
        )
        let termination = try XCTUnwrap(
            rawFunction.range(of: "terminate_production_app_for_raw_phase")
        )
        let testLaunch = try XCTUnwrap(
            rawFunction.range(of: "run_simple_physical_ui_test")
        )
        XCTAssertLessThan(preparation.lowerBound, termination.lowerBound)
        XCTAssertLessThan(termination.lowerBound, testLaunch.lowerBound)
        XCTAssertTrue(rawFunction.contains("\"test-without-building\""))
        XCTAssertTrue(
            rawFunction.contains("arm_raw_session_readiness_and_start_probe")
        )
        XCTAssertTrue(
            rawFunction.contains(
                "capture_default_input_snapshot"
            )
        )
        XCTAssertTrue(
            rawFunction.contains(
                "validate_default_input_lifecycle_json"
            )
        )
        XCTAssertTrue(
            driver.contains(
                "Worldwide authenticated media route selected virtual microphone default input"
            )
        )
        XCTAssertTrue(
            driver.contains(
                "RAW_DEFAULT_INPUT_HEALTHY"
            )
        )
        XCTAssertFalse(
            rawFunction[
                rawFunction.startIndex..<testLaunch.lowerBound
            ].contains("start_blackhole_probe")
        )
        XCTAssertFalse(
            rawFunction.contains("state=probe-exited-while-ui-running")
        )
        let rustOracle = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/physical-validation-oracle.rs"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(rustOracle.contains("latestPossibleUIStartNs"))
        XCTAssertTrue(rustOracle.contains("earliestPossibleUIEndNs"))
        XCTAssertTrue(rustOracle.contains("probe_start < latest_start"))
        XCTAssertTrue(rustOracle.contains("probe_end > earliest_end"))
        XCTAssertTrue(rustOracle.contains("resumed\n        .checked_add(continuity)"))
        XCTAssertTrue(rustOracle.contains("uiCompletionObservedAtMonotonicNs"))
        XCTAssertFalse(rustOracle.contains("xcodebuildEndedAtMonotonicNs"))
        XCTAssertFalse(driver.contains("sleep 18"))
        XCTAssertTrue(driver.contains("raw-ui-completion-observation.v1"))
        XCTAssertTrue(driver.contains("call-ui-hosted-state-observation.v2"))
        XCTAssertTrue(
            driver.contains("wait_for_nonce_bound_call_ui_hosted_state")
        )
        XCTAssertFalse(driver.contains("RAW_XCODEBUILD_ENDED_NS"))
        XCTAssertTrue(driver.contains("POST_CALL_RAW_CONTINUITY_SECONDS"))
        XCTAssertTrue(driver.contains("POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS"))
        XCTAssertTrue(
            driver.contains("POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS")
        )
        XCTAssertTrue(
            driver.contains(
                "opensteamer_run_physical_validation_oracle monotonic-ns"
            )
        )
    }

    func testRawReadinessHandshakeRejectsStaleTimeoutAndNonOverlap() throws {
        let driver = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                physicalDrivers[2].relativePath
            ),
            encoding: .utf8
        )
        let rustOracle = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/physical-validation-oracle.rs"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            driver.contains(
                "Worldwide iPhone microphone hidden writer selected routingEpoch=${blackhole_routing_epoch} peerGeneration=${blackhole_peer_generation} deviceGeneration=${blackhole_device_generation} pid=${current_process_id}"
            )
        )
        XCTAssertTrue(driver.contains("opensteamer.raw-session-readiness.v5"))
        XCTAssertTrue(driver.contains("opensteamer.raw-session-continuity.v2"))
        XCTAssertTrue(
            driver.contains(
                "blackHoleRoutingEpoch=${blackhole_routing_epoch}"
            )
        )
        XCTAssertTrue(
            driver.contains(
                "blackHoleDeviceGeneration=${blackhole_device_generation}"
            )
        )
        XCTAssertTrue(
            rustOracle.contains(
                "readiness[\"schema\"] != \"opensteamer.raw-session-readiness.v5\""
            )
        )
        XCTAssertTrue(
            rustOracle.contains(
                "continuity_record[\"schema\"] != \"opensteamer.raw-session-continuity.v2\""
            )
        )
        XCTAssertTrue(rustOracle.contains("\"blackHoleRoutingEpoch\""))
        XCTAssertTrue(rustOracle.contains("\"blackHoleDeviceGeneration\""))
        XCTAssertTrue(
            driver.contains(
                "hidden_writer_selection_observed != 0"
            )
        )
        for mode in [
            "raw-readiness-success",
            "raw-readiness-stale",
            "raw-readiness-timeout",
            "raw-readiness-non-overlap",
            "raw-readiness-exact-start",
            "raw-readiness-exact-end",
            "raw-readiness-exact-six",
            "raw-readiness-delayed-call-end",
            "raw-readiness-delayed-call-end-short-continuity",
            "raw-readiness-one-ns-short",
            "raw-readiness-outside-start",
            "raw-readiness-equal-window",
            "raw-readiness-inverted",
            "raw-readiness-stale-evidence",
            "raw-readiness-future-evidence",
            "raw-readiness-underflow",
            "raw-readiness-overflow",
            "raw-readiness-mismatch",
            "raw-readiness-pid-mismatch",
            "raw-readiness-status-mismatch",
            "raw-readiness-wait-status-mismatch",
            "raw-readiness-completion-success",
            "raw-readiness-completion-missing-hidden-writer",
            "raw-readiness-completion-mismatched-hidden-writer-generation",
            "raw-readiness-completion-mismatched-hidden-writer-peer-generation",
            "raw-readiness-completion-mismatched-hidden-writer-routing-epoch",
            "raw-readiness-completion-mismatched-hidden-writer-pid",
            "raw-readiness-completion-stale-hidden-writer-after-pair-change",
            "raw-readiness-completion-stale-hidden-writer-after-routing-epoch-change",
            "raw-readiness-completion-post-launch-device-generation-change",
            "raw-readiness-completion-post-launch-peer-generation-change",
            "raw-readiness-completion-post-launch-routing-epoch-change",
            "raw-readiness-completion-post-launch-writer-revoked",
            "raw-readiness-completion-post-launch-disconnect",
            "raw-readiness-completion-nonce-mismatch",
            "raw-readiness-completion-inverted",
            "raw-readiness-completion-nonzero",
            "raw-readiness-completion-malformed",
            "raw-readiness-completion-wait-status-mismatch",
            "raw-readiness-completion-absent-pid",
            "raw-readiness-completion-changed-pid",
            "raw-readiness-runner-alive-without-completion",
            "raw-readiness-stale-export",
            "raw-readiness-invalid-export-payload",
            "raw-ui-completion-handshake-success",
            "raw-ui-completion-handshake-late",
            "raw-ui-completion-handshake-nonce-mismatch",
        ] {
            let artifactDirectory = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 15
            )
            let diagnostic = "Mode \(mode): \(result.diagnostic)"
            XCTAssertTrue(result.exitedWithinDeadline, diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, diagnostic)
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "run-status.txt"
                    ),
                    encoding: .utf8
                ),
                "status=self-test-passed\n",
                diagnostic
            )
        }
    }

    func testRawUICausalStateHandshakeIsFreshUniqueAndNonceBound() throws {
        for mode in [
            "raw-ui-causal-state-handshake-success",
            "raw-ui-causal-state-handshake-nonce-mismatch",
            "raw-ui-causal-state-handshake-duplicate",
            "raw-ui-causal-state-handshake-ordinary-before-heard",
        ] {
            let artifactDirectory = URL(
                fileURLWithPath:
                    "/Volumes/t7/opensteamer-\(mode)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 8
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "run-status.txt"
                    ),
                    encoding: .utf8
                ),
                "status=self-test-passed\n",
                result.diagnostic
            )
        }
    }

    func testPostCallTimingContractCoversDelayedAcknowledgementAndRejectsShortWindow() throws {
        let validArtifacts = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
            .appendingPathComponent(
                "opensteamer-delayed-call-timing-\(UUID().uuidString)"
            )
        let invalidArtifacts = URL(fileURLWithPath: "/Volumes/t7", isDirectory: true)
            .appendingPathComponent(
                "opensteamer-short-call-timing-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: validArtifacts)
            try? FileManager.default.removeItem(at: invalidArtifacts)
        }

        let valid = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "raw-readiness-delayed-call-end",
            artifactDirectory: validArtifacts,
            timeout: 8
        )
        XCTAssertTrue(valid.exitedWithinDeadline, valid.diagnostic)
        XCTAssertEqual(valid.terminationStatus, 0, valid.diagnostic)
        let bounds = try String(
            contentsOf: validArtifacts.appendingPathComponent(
                "phase-1-raw-blackhole/raw-ui-host-bounds.txt"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(bounds.contains("continuityDurationNs=330000000000"))
        XCTAssertTrue(bounds.contains("latestPossibleUIStartNs=290000000000"))
        XCTAssertTrue(bounds.contains("earliestPossibleUIEndNs=331000000000"))
        let probeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"
            ),
            encoding: .utf8
        )
        let normalizedProbeSource = probeSource
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        XCTAssertTrue(normalizedProbeSource.contains("static let proofSeconds = 6.0"))
        XCTAssertTrue(
            normalizedProbeSource.contains(
                "var nextEvaluation = challengeStart + Policy.proofSeconds"
            )
        )
        XCTAssertTrue(
            normalizedProbeSource.contains(
                "if candidate.status == \"passed\" { break }"
            )
        )
        XCTAssertTrue(
            normalizedProbeSource.contains(
                "forcedFailures.append(\"timeout\")"
            )
        )

        let invalid = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "raw-readiness-delayed-call-end",
            artifactDirectory: invalidArtifacts,
            timeout: 8,
            additionalEnvironment: [
                "OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS": "329",
            ]
        )
        XCTAssertTrue(invalid.exitedWithinDeadline, invalid.diagnostic)
        XCTAssertEqual(invalid.terminationStatus, 2, invalid.diagnostic)
        XCTAssertTrue(
            invalid.standardError.contains("minimum 330"),
            invalid.diagnostic
        )
    }

    func testReconnectDriverStartsOneLongLivedDeterministicToneProcess() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-tone-oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "audio-oracle-tone",
            artifactDirectory: artifactDirectory,
            timeout: 8,
            additionalEnvironment: [
                "OPENSTEAMER_AUDIO_ORACLE_DURATION_SECONDS": "2",
            ]
        )
        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        let tone = artifactDirectory.appendingPathComponent(
            "phase-2-reconnect/physical-audio-oracle-tone.wav"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: tone.path)
        XCTAssertGreaterThan(attributes[.size] as? UInt64 ?? 0, 380_000)
        let audioFile = try AVAudioFile(forReading: tone)
        XCTAssertEqual(audioFile.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(audioFile.processingFormat.channelCount, 2)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            )
        )
        try audioFile.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 96_000)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        // Four half-second segments alternate low/high frequency and amplitude independently on
        // each channel. Crossing rate verifies frequency; mean magnitude verifies gain without a
        // perceptual or hardware-dependent audio assertion.
        let segmentFrames = 24_000
        func segmentMean(_ channel: Int, _ segment: Int) -> Double {
            let range = (segment * segmentFrames)..<((segment + 1) * segmentFrames)
            return range.reduce(0.0) { $0 + abs(Double(channels[channel][$1])) }
                / Double(segmentFrames)
        }
        func segmentCrossingRate(_ channel: Int, _ segment: Int) -> Double {
            let start = segment * segmentFrames
            let end = (segment + 1) * segmentFrames
            var previousSign = 0
            var crossings = 0
            for frame in start..<end {
                let sample = channels[channel][frame]
                guard sample != 0 else { continue }
                let sign = sample < 0 ? -1 : 1
                if previousSign != 0, sign != previousSign {
                    crossings += 1
                }
                previousSign = sign
            }
            return Double(crossings) / 0.5
        }
        for lowSegment in [0, 2] {
            XCTAssertTrue((1_500...2_500).contains(segmentCrossingRate(0, lowSegment)))
            XCTAssertTrue((2_300...3_700).contains(segmentCrossingRate(1, lowSegment)))
        }
        for highSegment in [1, 3] {
            XCTAssertTrue((15_000...17_000).contains(segmentCrossingRate(0, highSegment)))
            XCTAssertTrue((21_000...23_000).contains(segmentCrossingRate(1, highSegment)))
        }
        XCTAssertGreaterThan(segmentMean(0, 0), segmentMean(0, 1) * 2.5)
        XCTAssertLessThan(segmentMean(0, 0), segmentMean(0, 1) * 3.5)
        XCTAssertGreaterThan(segmentMean(1, 2), segmentMean(1, 3) * 2.5)
        XCTAssertLessThan(segmentMean(1, 2), segmentMean(1, 3) * 3.5)
        XCTAssertEqual(
            try String(
                contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
                encoding: .utf8
            ),
            "status=self-test-passed\n"
        )
    }

    func testProbeDiagnosticsAreBoundedFailureOnlyAndRejectRuntimeUID() throws {
        for mode in [
            "blackhole-probe-diagnostic-success",
            "blackhole-probe-diagnostic-failure",
            "blackhole-probe-diagnostic-uid-leak",
            "blackhole-probe-diagnostic-wedged-after-completion",
        ] {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-\(mode)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: mode,
                artifactDirectory: artifactDirectory,
                timeout: 8
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
            let diagnostics = artifactDirectory.appendingPathComponent(
                "phase-1-raw-blackhole/physical-blackhole-microphone-diagnostics.txt"
            )
            if mode.hasSuffix("success")
                || mode.hasSuffix("wedged-after-completion") {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: diagnostics.path)
                )
                if mode.hasSuffix("wedged-after-completion") {
                    let cleanup = try String(
                        contentsOf: artifactDirectory.appendingPathComponent(
                            "phase-1-raw-blackhole/physical-blackhole-microphone-cleanup.txt"
                        ),
                        encoding: .utf8
                    )
                    XCTAssertEqual(
                        cleanup,
                        "state=wrapper-timed-out-after-completion status=124\n"
                    )
                }
            } else {
                let data = try Data(contentsOf: diagnostics)
                XCTAssertLessThanOrEqual(data.count, 65_536)
                XCTAssertFalse(
                    data.range(
                        of: Data(SyntheticPhysicalDevice.physicalOutputUID.utf8)
                    ) != nil
                )
                if mode.hasSuffix("uid-leak") {
                    XCTAssertEqual(
                        String(decoding: data, as: UTF8.self),
                        "diagnostic=runtime-uid-output-rejected\n"
                    )
                }
            }
        }
    }

    func testRetainedUIDScannerFindsBoundarySpanningAndNestedLeaks() throws {
        enum Mutation {
            case boundary
            case nested
        }
        for mutation in [Mutation.boundary, .nested] {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "opensteamer-uid-scan-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let retained = artifactDirectory.appendingPathComponent(
                "retained/deeply/nested"
            )
            try FileManager.default.createDirectory(
                at: retained,
                withIntermediateDirectories: true
            )
            let uidData = Data(SyntheticPhysicalDevice.physicalOutputUID.utf8)
            switch mutation {
            case .boundary:
                let prefixCount = 1_048_576 - max(1, uidData.count / 2)
                var payload = Data(repeating: 0x41, count: prefixCount)
                payload.append(uidData)
                payload.append(Data(repeating: 0x42, count: 128))
                try payload.write(
                    to: retained.appendingPathComponent("boundary.bin")
                )
            case .nested:
                try JSONSerialization.data(
                    withJSONObject: [
                        "outer": [
                            "middle": [
                                "inner": SyntheticPhysicalDevice.physicalOutputUID,
                            ],
                        ],
                    ],
                    options: [.sortedKeys]
                ).write(to: retained.appendingPathComponent("nested.json"))
            }

            let result = try runPhysicalDriverSelfTest(
                physicalDrivers[2],
                mode: "reject-runtime-uid",
                artifactDirectory: artifactDirectory,
                timeout: 5
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
            XCTAssertEqual(
                try String(
                    contentsOf: artifactDirectory.appendingPathComponent(
                        "run-status.txt"
                    ),
                    encoding: .utf8
                ),
                "status=failed\n"
            )
        }
    }

    func testReconnectDriverStartsAndCleansUpChangingScreenChallenge() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-screen-oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "screen-oracle-challenge",
            artifactDirectory: artifactDirectory,
            // This is only XCTest's outer observation envelope. The driver still enforces its
            // reviewed five-second process-group, heartbeat, and termination bounds internally.
            // Account for both pinned Rust/Swift compilations when the complete mutation suite
            // has just exercised the external build volume.
            timeout: 20
        )
        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        let heartbeat = try String(
            contentsOf: artifactDirectory.appendingPathComponent(
                "phase-2-reconnect/physical-screen-oracle-heartbeat.txt"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(heartbeat.hasPrefix("counter="), heartbeat)
        let cleanup = try String(
            contentsOf: artifactDirectory.appendingPathComponent(
                "phase-2-reconnect/physical-screen-oracle-cleanup.txt"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(cleanup.hasPrefix("state=terminated pid="), cleanup)
        XCTAssertTrue(cleanup.contains(" first="), cleanup)
        XCTAssertTrue(cleanup.contains(" last="), cleanup)
        XCTAssertEqual(
            try String(
                contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
                encoding: .utf8
            ),
            "status=self-test-passed\n"
        )
    }

    func testBaselineAndReconnectDeleteStaleDerivedDataBeforeSelfTests() throws {
        let drivers: [PhysicalDriver] = [physicalDrivers[0], physicalDrivers[2]]
        for driver in drivers {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-stale-derived-data-\(UUID().uuidString)")
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

    // MARK: - Host-log provenance and incremental parsing

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

    func testReconnectRejectsReusedPIDAndAcceptsSixAuditedConnections() throws {
        try assertReconnectProvenanceSelfTestPasses("reused-pid")
        try assertReconnectProvenanceSelfTestPasses("unique-pids")
    }

    func testReconnectRawMicrophoneProofInterlockMutationsInRealZsh() throws {
        for scenario in [
            "proof-missing",
            "proof-duplicate",
            "proof-reused-uuid",
            "proof-reused-fingerprint",
            "proof-out-of-order",
            "proof-zero-generation",
            "proof-max-generation",
            "proof-max-plus-one-generation",
            "proof-timeout",
            "proof-projection-command-failure",
            "proof-projection-noisy",
            "proof-all-six",
        ] {
            try assertReconnectProvenanceSelfTestPasses(scenario)
        }
    }

    func testReconnectFinalWatcherWaitCoversVerifierStabilityWindow() throws {
        try assertReconnectProvenanceSelfTestPasses("watcher-final-delay")
    }

    func testReconnectRawMicrophoneProofTimeoutCannotUndercutPhysicalCeiling() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-proof-timeout-bound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "host-provenance-proof-all-six",
            artifactDirectory: artifactDirectory,
            timeout: 5,
            additionalEnvironment: [
                "OPENSTEAMER_RECONNECT_RAW_MICROPHONE_PROOF_TIMEOUT_SECONDS": "59",
            ]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 2, result.diagnostic)
        XCTAssertTrue(
            result.diagnostic.contains(
                "OPENSTEAMER_RECONNECT_RAW_MICROPHONE_PROOF_TIMEOUT_SECONDS " +
                    "must be between 60 and 120."
            ),
            result.diagnostic
        )
    }

    func testReconnectFinalAuditRejectsLateLineWithoutPostEndKickstart() throws {
        try assertReconnectProvenanceSelfTestPasses("final-audit-mismatch")
        try assertReconnectProvenanceSelfTestPasses("final-partial-mismatch")
        try assertReconnectProvenanceSelfTestPasses(
            "final-events-reused-generation-pid"
        )
        try assertReconnectProvenanceSelfTestPasses("final-events-final-pid-drift")
        try assertReconnectProvenanceSelfTestPasses("final-events-host-log-mismatch")
    }

    func testCoherentLogSnapshotRejectsRewriteDuringOpenedDescriptorRead() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-log-snapshot-race-\(UUID().uuidString)")
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
            "empty=$(opensteamer_empty_sha256); " +
                "opensteamer_capture_log_snapshot \"$1\" \"\" 0 \"$empty\" \"$2\"; " +
                "identity=$OPENSTEAMER_LOG_SNAPSHOT_ID; " +
                "offset=$OPENSTEAMER_LOG_SNAPSHOT_OFFSET; " +
                "digest=$OPENSTEAMER_LOG_SNAPSHOT_DIGEST; " +
                "export OPENSTEAMER_LOG_SNAPSHOT_TEST_READY=\"$4\"; " +
                "export OPENSTEAMER_LOG_SNAPSHOT_TEST_PROCEED=\"$5\"; " +
                "opensteamer_capture_log_snapshot \"$1\" \"$identity\" " +
                "\"$offset\" \"$digest\" \"$3\" & snapshot=$!; " +
                "for poll in {1..200}; do [[ -f \"$4\" ]] && break; sleep 0.01; done; " +
                "[[ -f \"$4\" ]]; " +
                "print -rn -- B | /bin/dd of=\"$1\" bs=1 seek=0 " +
                "conv=notrunc 2>/dev/null; " +
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
            .appendingPathComponent("opensteamer-partial-log-line-\(UUID().uuidString)")
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
            "opensteamer_split_completed_log_lines \"$1\" \"$3\" \"$4\"; " +
                "[[ ! -s \"$4\" ]]; " +
                "opensteamer_split_completed_log_lines \"$2\" \"$3\" \"$4\"; " +
                "opensteamer_audit_connected_log_lines \"$4\" 100 100; " +
                "print -r -- \"$OPENSTEAMER_AUDITED_CONNECTION_COUNT\"",
            arguments: [first.path, second.path, partial.path, completed.path]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertEqual(result.standardOutput, "1\n")
    }

    func testConnectedLineAuditorRejectsMultipleMarkersOnOneLineInRealZsh() throws {
        let completed = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-multiple-markers-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: completed) }
        try Data(
            (
                "Worldwide WebRTC peer state: connected pid=999 " +
                    "Worldwide WebRTC peer state: connected pid=100\n"
            ).utf8
        ).write(to: completed)

        let result = try runPhysicalValidationHelperProbe(
            "opensteamer_audit_connected_log_lines \"$1\" 100 100",
            arguments: [completed.path]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
    }

    func testReconnectCancellationKillsStoppedWatcherBeforeValidationGroup() throws {
        let script = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-cancel-churn-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            script.path,
            SyntheticPhysicalDevice.coreDeviceIdentifier,
            SyntheticPhysicalDevice.hardwareUDID,
            SyntheticPhysicalDevice.expectedBuild,
            SyntheticPhysicalDevice.physicalOutputUID,
            artifactDirectory.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SCRIPT_SELF_TEST"] = "cancel-stopped-churn"
        environment["OPENSTEAMER_HOST_CHURN_LOCK_ATTEMPTS"] = "5"
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

    // MARK: - Process-tree and process-group cleanup

    func testPhysicalValidationHelperForceTerminatesTermIgnoringProcessTree() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh"
        )
        let stubbornProcess = Process()
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-child-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        let leafPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-leaf-pids-\(UUID().uuidString)")
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
            "source \"$1\"; opensteamer_terminate_process_tree \"$2\" 1",
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
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-reparent-probe-\(UUID().uuidString)")
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
            "source \"$1\"; opensteamer_terminate_process_tree \"$2\" 1",
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
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh"
        )
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-group-handler-probe-\(UUID().uuidString)")
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
          "$OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE" \
            self-test-ignore-signals "$child_file" &
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
            "source \"$1\"; opensteamer_exec_in_isolated_process_group " +
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
            "source \"$1\"; opensteamer_require_isolated_process_group \"$2\" 3; " +
                "opensteamer_terminate_isolated_process_group \"$2\" 1",
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
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh"
        )
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-fast-leader-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        let harness = """
        "$OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE" self-test-ignore-signals "$1" &
        exit 0
        """
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/zsh")
        leader.arguments = [
            "-c",
            "source \"$1\"; opensteamer_exec_in_isolated_process_group " +
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
            "source \"$1\"; opensteamer_terminate_isolated_process_group \"$2\" 1",
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

    // MARK: - Shell parser and lifecycle primitives

    func testHostPIDParserAcceptsValidConnectedLogLineInRealZsh() throws {
        let result = try runPhysicalValidationHelperProbe(
            "opensteamer_connected_host_pid_from_log_line \"$1\"",
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
                "opensteamer_connected_host_pid_from_log_line \"$1\"",
                arguments: [logLine]
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
            XCTAssertEqual(result.standardOutput, "")
        }
    }

    func testSameHostProcessRejectsPIDMismatchAndMalformedPIDInRealZsh() throws {
        let valid = try runPhysicalValidationHelperProbe(
            "opensteamer_require_same_host_process \"$1\" \"$2\" \"$3\"",
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
                "opensteamer_require_same_host_process \"$1\" \"$2\" \"$3\"",
                arguments: arguments
            )
            XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
            XCTAssertNotEqual(result.terminationStatus, 0, result.diagnostic)
        }
    }

    func testIsolatedValidationGroupCanBeProvenStoppedThenResumed() throws {
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh"
        )
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-suspend-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyFile) }

        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/zsh")
        leader.arguments = [
            "-c",
            "source \"$1\"; opensteamer_exec_in_isolated_process_group " +
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
            "opensteamer_suspend_isolated_process_group \"$1\" 3; " +
                "state=$(ps -o state= -p \"$1\" | tr -d '[:space:]'); " +
                "[[ \"$state\" == T* ]]; " +
                "opensteamer_resume_process_group \"$1\"",
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
                    "opensteamer_wait_for_final_process_status \"$child\"; " +
                    "wait \"$transition\" 2>/dev/null || true; " +
                    "print -r -- \"$OPENSTEAMER_FINAL_PROCESS_STATUS\"",
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
                "opensteamer_wait_for_final_process_status \"$child\"; " +
                "wait \"$transition\" 2>/dev/null || true; " +
                "print -r -- \"$OPENSTEAMER_FINAL_PROCESS_STATUS\"",
            arguments: []
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        XCTAssertEqual(result.standardOutput, "143\n")
    }

    func testBoundedCriticalCommandTimesOut() throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-timeout-descendant-\(UUID().uuidString)")
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
            "opensteamer_run_with_timeout 0.1 /bin/zsh -c " +
                "'trap \"exit 0\" TERM; " +
                "\"$OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE\" " +
                "self-test-ignore-signals \"$1\" & " +
                "while true; do sleep 30; done' " +
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

    func testBoundedCriticalCommandRejectsCleanLeaderThatLeavesDescendant() throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opensteamer-clean-leader-descendant-\(UUID().uuidString)"
            )
        defer {
            if let text = try? String(
                contentsOf: descendantPIDFile,
                encoding: .utf8
            ),
               let descendantPID = pid_t(
                text.trimmingCharacters(in: .whitespacesAndNewlines)
               ),
               kill(descendantPID, 0) == 0 {
                kill(descendantPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: descendantPIDFile)
        }
        let result = try runPhysicalValidationHelperProbe(
            "opensteamer_run_with_timeout 2 /bin/zsh -c " +
                "'\"$OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE\" " +
                "self-test-ignore-signals \"$1\" & " +
                "while [[ ! -s \"$1\" ]]; do sleep 0.01; done; exit 0' " +
                "clean-leader \"$1\"",
            arguments: [descendantPIDFile.path]
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 1, result.diagnostic)
        let descendantPID = try XCTUnwrap(
            pid_t(
                String(contentsOf: descendantPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertTrue(
            waitForPIDToDisappear(descendantPID, timeout: 2),
            "A clean leader exit orphaned descendant PID \(descendantPID)."
        )
    }

    // MARK: - Cross-driver failure contracts

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
            let artifactDirectory = URL(
                fileURLWithPath: "/Volumes/t7",
                isDirectory: true
            )
                .appendingPathComponent("opensteamer-startup-failure-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )
            XCTAssertEqual(chmod(artifactDirectory.path, S_IRWXU), 0)
            let staleName = driver.relativePath.contains("update-keychain")
                ? "seed-summary.json"
                : "summary.json"
            let staleURL = artifactDirectory.appendingPathComponent(staleName)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: staleURL.path
                )
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: artifactDirectory.path
                )
                try? FileManager.default.removeItem(at: artifactDirectory)
            }
            let runStatusURL = artifactDirectory.appendingPathComponent("run-status.txt")
            try Data("status=passed\n".utf8).write(to: runStatusURL)
            try FileManager.default.createDirectory(
                at: staleURL,
                withIntermediateDirectories: false
            )
            try Data("stale".utf8).write(
                to: staleURL.appendingPathComponent("retained.txt")
            )
            XCTAssertEqual(chmod(staleURL.path, S_IRUSR | S_IXUSR), 0)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                repositoryRoot.appendingPathComponent(driver.relativePath).path,
            ] + driver.arguments(artifactDirectory)
            var environment = ProcessInfo.processInfo.environment
            environment["OPENSTEAMER_CONTROLLED_HOST_NO_AUDIO_TAPS_ACK"] =
                "controlled-host-no-audio-taps-reviewed"
            process.environment = environment
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
                .appendingPathComponent("opensteamer-driver-fast-group-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                repositoryRoot.appendingPathComponent(driver.relativePath).path,
            ] + driver.arguments(artifactDirectory)
            var environment = ProcessInfo.processInfo.environment
            environment["OPENSTEAMER_SCRIPT_SELF_TEST"] = "fast-group-failure"
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

    private func passingBlackHoleProbeJSON(nonce: String) -> [String: Any] {
        let progress: [[String: Any]] = (0...12).map { index in
            let callbackCount = index * 50
            let capturedFrameCount = index * 24_000
            return [
                "elapsedSeconds": Double(index) * 0.5,
                "callbackCount": callbackCount,
                "capturedFrameCount": capturedFrameCount,
                "callbackDelta": index == 0 ? 0 : 50,
                "frameDelta": index == 0 ? 0 : 24_000,
                "advancing": index != 0,
            ]
        }
        let channels: [[String: Any]] = [
            [
                "channel": 0,
                "rms": 4_000.0,
                "peak": 7_000,
                "clippedRatio": 0.0,
                "nonSilentRatio": 0.90,
                "challengeSymbolCount": 20,
                "matchedSymbolCount": 18,
                "matchRatio": 0.90,
                "normalizedCorrelation": 0.80,
                "discriminationMargin": 0.30,
                "envelopeCorrelation": 0.70,
            ],
        ]
        return [
            "schema": "opensteamer.physical-virtual-microphone.v2",
            "status": "passed",
            "runNonce": nonce,
            "challengeAlgorithm": "nonce-splitmix64-frequency-hop-raised-envelope",
            "challengeVersion": 1,
            "canonicalCaptureUID":
                "com.elamin.opensteamer.virtual-microphone.input",
            "captureUIDMatches": true,
            "physicalOutputValidated": true,
            "challengeNonceMatches": true,
            "queueReadbackMatches": true,
            "captureQueueReadbackMatches": true,
            "physicalOutputQueueReadbackMatches": true,
            "format": [
                "sampleRate": 48_000,
                "channels": 1,
                "signedInt16": true,
                "interleaved": true,
            ],
            "proofWindowSeconds": 6.0,
            "captureSeconds": 6.0,
            "callbackCount": 600,
            "capturedFrameCount": 288_000,
            "totalCallbackCount": 600,
            "totalCapturedFrameCount": 288_000,
            "frameDensity": 1.0,
            "maxCallbackGapMs": 10.0,
            "longestNonSilentGapMs": 20.0,
            "nonSilentFrameRatio": 0.90,
            "aggregateClippedRatio": 0.0,
            "progressObservationCount": 13,
            "advancingProgressObservationCount": 12,
            "progressSnapshots": progress,
            "channels": channels,
            "recognizedChannel": 0,
            "symbolCount": 20,
            "matchedSymbolCount": 18,
            "matchRatio": 0.90,
            "normalizedCorrelation": 0.80,
            "discriminationMargin": 0.30,
            "envelopeCorrelation": 0.70,
            "detectedLagMs": 280.0,
            "defaultInputBeforeAfterEqual": true,
            "defaultOutputBeforeAfterEqual": true,
            "defaultSystemOutputBeforeAfterEqual": true,
            "defaultChangeNotificationCount": 0,
            "failureCode": "none",
            "failureReasons": [],
        ]
    }

    private func assertEveryPhysicalDriverFailsRuntimeSelfTest(
        mode: String,
        expectedStatus: Int32
    ) throws {
        // All drivers must publish the same terminal status semantics even though their normal
        // device workflows and artifact names differ.
        for driver in physicalDrivers {
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensteamer-\(mode)-probe-\(UUID().uuidString)")
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
            environment["OPENSTEAMER_SCRIPT_SELF_TEST"] = mode
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
        // Scenario names select deterministic mutants implemented by the reconnect driver itself.
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-host-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let result = try runPhysicalDriverSelfTest(
            physicalDrivers[2],
            mode: "host-provenance-\(scenario)",
            artifactDirectory: artifactDirectory,
            timeout: scenario == "watcher-final-delay" ? 20 : 8
        )

        XCTAssertTrue(result.exitedWithinDeadline, result.diagnostic)
        XCTAssertEqual(result.terminationStatus, 0, result.diagnostic)
        let runStatus = try String(
            contentsOf: artifactDirectory.appendingPathComponent("run-status.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(runStatus, "status=self-test-passed\n", result.diagnostic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    private func runPhysicalDriverSelfTest(
        _ driver: PhysicalDriver,
        mode: String,
        artifactDirectory: URL,
        timeout: TimeInterval,
        additionalEnvironment: [String: String] = [:]
    ) throws -> ZshProbeResult {
        // Self-test is selected exclusively through the environment; the normal positional CLI
        // remains intact so startup, traps, artifact initialization, and cleanup all execute.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repositoryRoot.appendingPathComponent(driver.relativePath).path,
        ] + driver.arguments(artifactDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SCRIPT_SELF_TEST"] = mode
        environment.merge(additionalEnvironment) { _, replacement in replacement }
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
        // `$1` is reserved for the sourced helper path; `shift` preserves the helper functions'
        // production-style positional argument numbering for the supplied command fragment.
        let helper = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/physical-validation-helpers.zsh"
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
        // A child may keep the pipe inherited after the direct Process exits. Nonblocking reads
        // collect currently available diagnostics without letting such a descendant hang XCTest.
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
        // Twenty-millisecond polling keeps the deadlines bounded while tolerating scheduler jitter.
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
        // ESRCH, rather than a completed parent Process alone, proves the OS no longer exposes the
        // descendant and guards against cleanup that silently reparents children.
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
