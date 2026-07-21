import Foundation
import XCTest

/// Exercises the release host builder and bundle verifier as one artifact-identity contract.
///
/// The positive fixture is a freshly built, ad-hoc-signed app. Independent clones then mutate one
/// identity boundary at a time—metadata, basename, signature seal, rpath, embedded framework, and
/// path indirection—so the verifier must reject artifacts that merely resemble the approved host.
final class MacHostBundleIdentityTests: XCTestCase {
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

    func testBuiltHostArtifactAndVerifierRejectIdentityMutations() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-host-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        let outputDirectory = temporaryRoot.appendingPathComponent("build")
        var buildEnvironment = ProcessInfo.processInfo.environment
        // `-` requests an ad-hoc signature. That keeps the test independent of developer
        // credentials and intentionally produces no TeamIdentifier for the negative team check.
        buildEnvironment["MAC_CAPTURE_CODESIGN_IDENTITY"] = "-"
        buildEnvironment["MAC_CAPTURE_APP_OUTPUT_DIR"] = outputDirectory.path
        buildEnvironment["MAC_CAPTURE_PREBUILT_BIN_DIR"] = Bundle(
            for: MacHostBundleIdentityTests.self
        ).bundleURL.deletingLastPathComponent().path
        buildEnvironment.removeValue(forKey: "MAC_CAPTURE_EXPECTED_TEAM_ID")

        let build = try run(
            executable: repositoryRoot.appendingPathComponent(
                "macOS/scripts/build-mac-capture-host-app.sh"
            ),
            environment: buildEnvironment
        )
        XCTAssertEqual(build.status, 0, build.diagnostic)

        let builtApp = outputDirectory.appendingPathComponent("AudioStreamer Host.app")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: builtApp.path,
                isDirectory: &isDirectory
            ),
            build.diagnostic
        )
        XCTAssertTrue(isDirectory.boolValue, build.diagnostic)
        XCTAssertEqual(
            build.standardOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init),
            builtApp.path,
            build.diagnostic
        )

        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-mac-host-bundle.sh"
        )
        let pristineVerification = try run(
            executable: verifier,
            arguments: [builtApp.path]
        )
        XCTAssertEqual(pristineVerification.status, 0, pristineVerification.diagnostic)

        let teamRejection = try run(
            executable: verifier,
            arguments: [builtApp.path, "A1B2C3D4E5"]
        )
        XCTAssertNotEqual(teamRejection.status, 0, teamRejection.diagnostic)
        XCTAssertTrue(
            teamRejection.standardError.contains(
                "TeamIdentifier: expected 'A1B2C3D4E5', found 'not set'"
            ),
            teamRejection.diagnostic
        )

        let displayNameMutation = try makeAPFSClone(
            of: builtApp,
            named: "AudioStreamer Host.app",
            under: temporaryRoot.appendingPathComponent("wrong-display-name")
        )
        let plistMutation = try run(
            executable: URL(fileURLWithPath: "/usr/libexec/PlistBuddy"),
            arguments: [
                "-c",
                "Set :CFBundleDisplayName Wrong Host",
                displayNameMutation.appendingPathComponent("Contents/Info.plist").path,
            ]
        )
        XCTAssertEqual(plistMutation.status, 0, plistMutation.diagnostic)
        let displayNameRejection = try run(
            executable: verifier,
            arguments: [displayNameMutation.path]
        )
        XCTAssertNotEqual(displayNameRejection.status, 0, displayNameRejection.diagnostic)
        XCTAssertTrue(
            displayNameRejection.standardError.contains(
                "CFBundleDisplayName: expected 'AudioStreamer Host', found 'Wrong Host'"
            ),
            displayNameRejection.diagnostic
        )

        let basenameMutation = try makeAPFSClone(
            of: builtApp,
            named: "MacCaptureHost.app",
            under: temporaryRoot.appendingPathComponent("wrong-basename")
        )
        let basenameRejection = try run(
            executable: verifier,
            arguments: [basenameMutation.path]
        )
        XCTAssertNotEqual(basenameRejection.status, 0, basenameRejection.diagnostic)
        XCTAssertTrue(
            basenameRejection.standardError.contains(
                "bundle basename: expected 'AudioStreamer Host.app', found 'MacCaptureHost.app'"
            ),
            basenameRejection.diagnostic
        )

        let signatureMutation = try makeAPFSClone(
            of: builtApp,
            named: "AudioStreamer Host.app",
            under: temporaryRoot.appendingPathComponent("invalid-signature")
        )
        let sealMutation = try run(
            executable: URL(fileURLWithPath: "/usr/libexec/PlistBuddy"),
            arguments: [
                "-c",
                "Set :CFBundleVersion 999",
                signatureMutation.appendingPathComponent("Contents/Info.plist").path,
            ]
        )
        XCTAssertEqual(sealMutation.status, 0, sealMutation.diagnostic)
        let signatureRejection = try run(
            executable: verifier,
            arguments: [signatureMutation.path]
        )
        XCTAssertNotEqual(signatureRejection.status, 0, signatureRejection.diagnostic)
        XCTAssertTrue(
            signatureRejection.standardError.contains(
                "strict code-signature verification failed for the main executable"
            ),
            signatureRejection.diagnostic
        )

        let rpathMutation = try makeAPFSClone(
            of: builtApp,
            named: "AudioStreamer Host.app",
            under: temporaryRoot.appendingPathComponent("missing-rpath")
        )
        let rpathEdit = try run(
            executable: URL(fileURLWithPath: "/usr/bin/install_name_tool"),
            arguments: [
                "-delete_rpath",
                "@executable_path/../Frameworks",
                rpathMutation.appendingPathComponent("Contents/MacOS/CaptureServer").path,
            ]
        )
        XCTAssertEqual(rpathEdit.status, 0, rpathEdit.diagnostic)
        let rpathRejection = try run(
            executable: verifier,
            arguments: [rpathMutation.path]
        )
        XCTAssertNotEqual(rpathRejection.status, 0, rpathRejection.diagnostic)
        XCTAssertTrue(
            rpathRejection.standardError.contains(
                "main executable is missing LC_RPATH '@executable_path/../Frameworks'"
            ),
            rpathRejection.diagnostic
        )

        let missingFrameworkMutation = try makeAPFSClone(
            of: builtApp,
            named: "AudioStreamer Host.app",
            under: temporaryRoot.appendingPathComponent("missing-framework")
        )
        try FileManager.default.removeItem(
            at: missingFrameworkMutation.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework"
            )
        )
        let frameworkRejection = try run(
            executable: verifier,
            arguments: [missingFrameworkMutation.path]
        )
        XCTAssertNotEqual(frameworkRejection.status, 0, frameworkRejection.diagnostic)
        XCTAssertTrue(
            frameworkRejection.standardError.contains("LiveKitWebRTC.framework is missing"),
            frameworkRejection.diagnostic
        )

        let symlinkParent = temporaryRoot.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(
            at: symlinkParent,
            withIntermediateDirectories: true
        )
        let symlink = symlinkParent.appendingPathComponent("AudioStreamer Host.app")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: builtApp)
        let symlinkRejection = try run(executable: verifier, arguments: [symlink.path])
        XCTAssertNotEqual(symlinkRejection.status, 0, symlinkRejection.diagnostic)
        XCTAssertTrue(
            symlinkRejection.standardError.contains(
                "bundle path must not be a symbolic link"
            ),
            symlinkRejection.diagnostic
        )

        for disguisedSymlinkPath in [
            // Lexical suffixes must not let URL normalization hide the symlink boundary.
            symlink.appendingPathComponent(".").path,
            symlink.appendingPathComponent("Contents/..").path,
        ] {
            let disguisedSymlinkRejection = try run(
                executable: verifier,
                arguments: [disguisedSymlinkPath]
            )
            XCTAssertNotEqual(
                disguisedSymlinkRejection.status,
                0,
                disguisedSymlinkRejection.diagnostic
            )
            XCTAssertTrue(
                disguisedSymlinkRejection.standardError.contains(
                    "bundle path must not be a symbolic link"
                ),
                disguisedSymlinkRejection.diagnostic
            )
        }
    }

    private func makeAPFSClone(
        of source: URL,
        named name: String,
        under parent: URL
    ) throws -> URL {
        // Clone-on-write keeps each destructive mutation isolated without rebuilding the app.
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let destination = parent.appendingPathComponent(name)
        let clone = try run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-cR", source.path, destination.path]
        )
        XCTAssertEqual(clone.status, 0, clone.diagnostic)
        return destination
    }

    private func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamer-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let standardOutputURL = captureDirectory.appendingPathComponent("stdout")
        let standardErrorURL = captureDirectory.appendingPathComponent("stderr")
        // Files avoid the bounded-buffer deadlock that can occur when a verbose child writes to
        // `Pipe` while this synchronous helper is blocked in `waitUntilExit`.
        XCTAssertTrue(
            FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        )
        XCTAssertTrue(
            FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
        )
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
